// SPDX-License-Identifier: MIT
//
// H516 SpringBoard scene observer. It is injected through the
// owner-provided LaunchDaemon overlay and logs through the A540 ABI. The
// observer only runs in SpringBoard; inherited DYLD_INSERT_LIBRARIES values in
// child processes are ignored.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <mach/thread_act.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
// servers/bootstrap.h is not in the public SDK; the prototype is stable.
extern "C" kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
#include <sys/proc.h>
#include <cxxabi.h>
#include <dlfcn.h>
#include <errno.h>
#include <exception>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

#include "NativeAdrenoABI.h"

extern "C" const char *getprogname(void);
extern "C" uint32_t h539_installer_state(void);
extern "C" BOOL BYSetupAssistantNeedsToRun(void);
extern "C" void BYSetupAssistantPrepareLaunchSentinel(void);
extern "C" id objc_msgSendSuper2(struct objc_super *, SEL);

static const uint32_t kTunnelMagic = 0x4e544e4c; /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMethodSetMetadata = 9;
static const uint32_t kMaxLog = 184;

static io_connect_t gConnection;
static uint32_t gSelector;
static unsigned gBudget = 1024;
static int gConsole = -2;
static unsigned gViewBudget;
static unsigned gLayerBudget;
static uint32_t gHostContextIds[8];
static unsigned gHostContextCount;
static uintptr_t gLayerTrail[16];
static unsigned gHostContextEventCount;
static unsigned gContextLayerEventCount;
static unsigned gTransactionEventCount;
static unsigned gWindowContentsEventCount;
static unsigned gLayerCommitEventCount;
static unsigned gWindowCommitCount[2];
static unsigned gWindowVisibilityEventCount;
static unsigned gPostDidFinishContentsEventCount;
static unsigned gPostDidFinishCommitEventCount;
static unsigned gPostDidFinishTransactionEventCount;
static bool gVisibilitySnapshotScheduled;
static bool gApplicationSceneProbeStarted;
static bool gDidFinishReturned;
static bool gPostDidFinishSnapshotStarted;
static bool gH557PostRunSnapshotScheduled;
static std::terminate_handler gPreviousTerminateHandler;
static struct sigaction gPreviousAbortAction;
static volatile sig_atomic_t gAbortActionSaved;
static volatile sig_atomic_t gInAbortReport;
static struct sigaction gPreviousSegvAction;
static struct sigaction gPreviousIllAction;
static volatile sig_atomic_t gSegvActionSaved;
static volatile sig_atomic_t gIllActionSaved;
static volatile sig_atomic_t gInFatalSignalReport;
static void (*gOriginalObjcExceptionThrow)(id exception);
static IMP gApplicationSharedApplication;
static IMP gSpringBoardCompleteStartupOriginal;
static IMP gSpringBoardUIControllerSharedOriginal;
static IMP gSpringBoardIconControllerInitOriginal;
static IMP gChronoServicesSubscribeOriginal;
static IMP gApplicationRunOriginal;
static IMP gSpringBoardApplicationDidFinishLaunching;
static IMP gSpringBoardStartSystemStatusServer;
static IMP gMCProfileConnectionWaitForMigration;
static IMP gMCProfileConnectionShouldShowCloudConfigurationUI;
static IMP gSpringBoardSetupManagerInitOriginal;
static IMP gSpringBoardSetupHUDOriginal;
static IMP gSoundControllerSharedInstanceOriginal;
static IMP gSoundControllerInitOriginal;
static IMP gRingerControlInitOriginal;
static IMP gStatusDomainDataChangeLogInitOriginal;
static IMP gTelephonyManagerSharedOriginal;
static IMP gTelephonyManagerSharedCreatingOriginal;
static IMP gTelephonyManagerInitOriginal;
static IMP gApplicationControllerInitOriginal;
static IMP gApplicationLibraryInstalledApplicationOriginal;
static IMP gApplicationLibraryInstalledApplicationsOriginal;
static IMP gApplicationLibraryAllInstalledApplicationsOriginal;
static IMP gMutableSetRemoveObjectOriginal;
static IMP gConcreteMutableSetRemoveObjectOriginal;
static IMP gBSServiceProxyCreateOriginal;
static IMP gBSXPCServiceMessageSendSynchronouslyOriginal;
static IMP gACActivityCenterInitOriginal;
static IMP gACActivityCenterObserveDescriptorsOriginal;
static IMP gACActivityCenterObserveContentUpdatesOriginal;
static IMP gACActivityCenterObserveReducedPushBudgetOriginal;
static IMP gACActivityCenterIsActivityActiveOriginal;
static IMP gACActivityCenterAreActivitiesEnabledOriginal;
static IMP gACActivityAuthorizationInitOriginal;
static IMP gSBHIconManagerLocalizedFolderNameOriginal;
static IMP gSBHIconManagerDefaultWidgetIntentOriginal;
static IMP gSBHIconModelSaveStateOriginal;
static IMP gSBIconControllerPrepareTodayOriginal;
static id gObservedApplication;
static id gDidFinishLaunchingObserver;
static id gWillEnterForegroundObserver;
static id gDidBecomeActiveObserver;
static bool gSetupReturnSamplerStarted;

static void snapshot(const char *phase, unsigned sample) __attribute__((unused));
static void line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void line_reserved(const char *format, ...)
    __attribute__((format(printf, 1, 2)));
static const char *class_name_or_nil(id object);
static void copy_utf8(id value, char *out, size_t size);
static const char *instance_encoding(id object, const char *name);
static id read_object(id object, const char *name);
static bool read_integer(id object, const char *name, unsigned long long *value);
static void trace_uncaught_exception(NSException *exception);
static void trace_cxx_terminate();
static void rearm_exception_reporters(const char *site);
static void schedule_application_scene_probe(unsigned tick);
static void log_application_scene_state(const char *phase);
static void snapshot_windows(const char *scope, id owner, unsigned sample);
static void schedule_h557_post_run_snapshot(void);
static void census_ca_contexts(const char *why);
static void census_once(const char *site);

static BOOL trace_by_setup_assistant_needs_to_run(void)
{
    line("event=h547_by_setup_assistant_needs_to_run_bypass pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
    return NO;
}

static void trace_by_setup_assistant_prepare_launch_sentinel(void)
{
    line("event=h548_by_setup_prepare_launch_sentinel_bypass pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
}

struct DyldInterpose {
    const void *replacement;
    const void *replacee;
};

__attribute__((used, section("__DATA,__interpose")))
static const DyldInterpose gSetupAssistantInterpose[] = {
    {
        (const void *) trace_by_setup_assistant_needs_to_run,
        (const void *) BYSetupAssistantNeedsToRun,
    },
    {
        (const void *) trace_by_setup_assistant_prepare_launch_sentinel,
        (const void *) BYSetupAssistantPrepareLaunchSentinel,
    },
};

static id trace_application_shared_application(id self, SEL selector)
{
    line("event=h515_shared_application_enter receiver=%s thread=%p main=%d",
         class_name_or_nil(self), (void *) pthread_self(), pthread_main_np());
    id application = gApplicationSharedApplication
        ? ((id (*)(id, SEL)) gApplicationSharedApplication)(self, selector) : nil;
    if (application) gObservedApplication = application;
    line("event=h515_shared_application_return app=%p class=%s",
         (__bridge void *) application, class_name_or_nil(application));
    return application;
}

static void trace_springboard_application_did_finish(
    id self, SEL selector, id notification)
{
    line("event=h541_did_finish_enter pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
    ((void (*)(id, SEL, id)) gSpringBoardApplicationDidFinishLaunching)(
        self, selector, notification);
    line("event=h541_did_finish_return pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
    gDidFinishReturned = true;
    schedule_application_scene_probe(0);
    log_application_scene_state("h542_after_did_finish");

    if (!gPostDidFinishSnapshotStarted) {
        gPostDidFinishSnapshotStarted = true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            Class applicationClass = NSClassFromString(@"UIApplication");
            id application = applicationClass
                ? ((id (*)(id, SEL)) objc_msgSend)(
                      (id) applicationClass, @selector(sharedApplication))
                : nil;
            line("event=h556_post_did_finish_snapshot_enter pid=%d thread=%p main=%d app=%d",
                 getpid(), (void *) pthread_self(), pthread_main_np(),
                 application ? 1 : 0);
            gViewBudget = 48;
            gLayerBudget = 160;
            gHostContextCount = 0;
            snapshot_windows("h556_post_did_finish", application, 5);
            log_application_scene_state("h556_post_did_finish");
            line("event=h556_post_did_finish_snapshot_exit pid=%d", getpid());
        });
    }
}

static void trace_springboard_complete_startup(id self, SEL selector, id scene)
{
    rearm_exception_reporters("complete-startup-enter");
    line("event=h557_complete_startup_enter pid=%d thread=%p main=%d scene=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) scene);
    @try {
        ((void (*)(id, SEL, id)) gSpringBoardCompleteStartupOriginal)(
            self, selector, scene);
    } @catch (NSException *exception) {
        char name[80];
        char reason[160];
        copy_utf8([exception name], name, sizeof name);
        copy_utf8([exception reason], reason, sizeof reason);
        line_reserved(
            "event=h583_complete_startup_exception_caught pid=%d main=%d class=%s name=%.72s reason=%.144s",
            getpid(), pthread_main_np(), class_name_or_nil(exception), name, reason);
    }
    rearm_exception_reporters("complete-startup-return");
    line("event=h557_complete_startup_return pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
}

static id trace_springboard_ui_controller_shared(id self, SEL selector)
{
    line("event=h557_ui_controller_shared_enter pid=%d main=%d",
         getpid(), pthread_main_np());
    id controller = ((id (*)(id, SEL)) gSpringBoardUIControllerSharedOriginal)(
        self, selector);
    line("event=h557_ui_controller_shared_return pid=%d main=%d object=%p class=%s",
         getpid(), pthread_main_np(), (__bridge void *) controller,
         class_name_or_nil(controller));
    return controller;
}

static id trace_springboard_icon_controller_init(
    id self, SEL selector, id scene)
{
    line("event=h557_icon_controller_init_enter pid=%d main=%d scene=%p",
         getpid(), pthread_main_np(), (__bridge void *) scene);
    id controller = nil;
    @try {
        controller = ((id (*)(id, SEL, id))
            gSpringBoardIconControllerInitOriginal)(self, selector, scene);
    } @catch (NSException *exception) {
        char name[80];
        char reason[160];
        copy_utf8([exception name], name, sizeof name);
        copy_utf8([exception reason], reason, sizeof reason);
        line_reserved(
            "event=h582_icon_init_exception_caught pid=%d main=%d class=%s name=%.72s reason=%.144s",
            getpid(), pthread_main_np(), class_name_or_nil(exception), name, reason);
    }
    line("event=h557_icon_controller_init_return pid=%d main=%d object=%p class=%s",
         getpid(), pthread_main_np(), (__bridge void *) controller,
         class_name_or_nil(controller));
    return controller;
}

static id trace_chrono_services_subscribe(id self, SEL selector)
{
    (void)selector;
    rearm_exception_reporters("chrono");
    line("event=h557_chrono_subscribe_enter pid=%d main=%d object=%p",
         getpid(), pthread_main_np(), (__bridge void *) self);
    line("event=h577_chrono_subscribe_skip pid=%d main=%d object=%p",
         getpid(), pthread_main_np(), (__bridge void *) self);
    line("event=h557_chrono_subscribe_return pid=%d main=%d object=%p skipped=1 result=0",
         getpid(), pthread_main_np(), (__bridge void *) self);
    line("event=h584_chrono_subscribe_skip_return_nil pid=%d main=%d",
         getpid(), pthread_main_np());
    return nil;
}

static id trace_chrono_assertion(id self, SEL selector)
{
    (void)selector;
    line("event=h579_chrono_assertion_stub pid=%d main=%d object=%p",
         getpid(), pthread_main_np(), (__bridge void *) self);
    return nil;
}

static id trace_bsservice_proxy_create(
    id self, SEL selector, Protocol *protocol, Class remoteClass, id name)
{
    char protocolName[96];
    char serviceName[128];
    const char *sourceProtocol = protocol ? protocol_getName(protocol) : NULL;
    snprintf(protocolName, sizeof protocolName, "%.88s",
             sourceProtocol ? sourceProtocol : "-");
    copy_utf8(name, serviceName, sizeof serviceName);
    line("event=h585_bs_proxy_create pid=%d main=%d protocol=%.88s class=%.32s name=%.112s",
         getpid(), pthread_main_np(), protocolName,
         remoteClass ? class_getName(remoteClass) : "-", serviceName);
    return ((id (*)(id, SEL, Protocol *, Class, id))
        gBSServiceProxyCreateOriginal)(self, selector, protocol, remoteClass, name);
}

static id trace_bsxpc_message_send_synchronously(
    id self, SEL selector, id *error)
{
    const char *encoding = instance_encoding(self, "sendSynchronouslyWithError:");
    id selectorName = read_object(self, "selectorName");
    unsigned long long messageID = 0;
    unsigned long long expectsReply = 0;
    char selectorText[128];
    copy_utf8(selectorName, selectorText, sizeof selectorText);
    read_integer(self, "messageID", &messageID);
    read_integer(self, "expectsReply", &expectsReply);
    line("event=h585_bs_message_send_sync_enter pid=%d main=%d object=%p class=%s encoding=%s selector=%.112s msgid=%llu reply=%llu",
         getpid(), pthread_main_np(), (__bridge void *) self,
         class_name_or_nil(self), encoding ? encoding : "-",
         selectorText, messageID, expectsReply);
    id result = ((id (*)(id, SEL, id *))
        gBSXPCServiceMessageSendSynchronouslyOriginal)(self, selector, error);
    id errorObject = error ? *error : nil;
    char reason[128];
    copy_utf8(errorObject, reason, sizeof reason);
    line("event=h585_bs_message_send_sync_return pid=%d main=%d result=%p error=%d class=%s reason=%.112s",
         getpid(), pthread_main_np(), (__bridge void *) result,
         errorObject ? 1 : 0,
         class_name_or_nil(errorObject), reason);
    return result;
}

static id trace_ac_activity_center_init(id self, SEL selector)
{
    line("event=h585_activity_center_init_enter pid=%d main=%d", getpid(),
         pthread_main_np());
    line("event=h587_activity_center_service_skip pid=%d main=%d", getpid(),
         pthread_main_np());
    struct objc_super superInfo = {
        .receiver = self,
        .super_class = object_getClass(self),
    };
    id object = ((id (*)(struct objc_super *, SEL))
        objc_msgSendSuper2)(&superInfo, selector);
    line("event=h585_activity_center_init_return pid=%d main=%d object=%p class=%s",
         getpid(), pthread_main_np(), (__bridge void *) object,
         class_name_or_nil(object));
    return object;
}

static void trace_ac_activity_center_observe_descriptors(
    id self, SEL selector, id handler)
{
    line("event=h585_activity_center_observe_descriptors_enter pid=%d main=%d object=%p handler=%d",
         getpid(), pthread_main_np(), (__bridge void *) self, handler ? 1 : 0);
    ((void (*)(id, SEL, id)) gACActivityCenterObserveDescriptorsOriginal)(
        self, selector, handler);
    line("event=h585_activity_center_observe_descriptors_return pid=%d main=%d",
         getpid(), pthread_main_np());
}

static void trace_ac_activity_center_observe_content_updates(
    id self, SEL selector, id handler)
{
    line("event=h585_activity_center_observe_content_updates_enter pid=%d main=%d object=%p handler=%d",
         getpid(), pthread_main_np(), (__bridge void *) self, handler ? 1 : 0);
    ((void (*)(id, SEL, id)) gACActivityCenterObserveContentUpdatesOriginal)(
        self, selector, handler);
    line("event=h585_activity_center_observe_content_updates_return pid=%d main=%d",
         getpid(), pthread_main_np());
}

static void trace_ac_activity_center_observe_reduced_push_budget(
    id self, SEL selector, id handler)
{
    line("event=h585_activity_center_observe_reduced_push_budget_enter pid=%d main=%d object=%p handler=%d",
         getpid(), pthread_main_np(), (__bridge void *) self, handler ? 1 : 0);
    ((void (*)(id, SEL, id)) gACActivityCenterObserveReducedPushBudgetOriginal)(
        self, selector, handler);
    line("event=h585_activity_center_observe_reduced_push_budget_return pid=%d main=%d",
         getpid(), pthread_main_np());
}

static BOOL trace_ac_activity_center_is_activity_active(
    id self, SEL selector, id activity)
{
    BOOL result = ((BOOL (*)(id, SEL, id))
        gACActivityCenterIsActivityActiveOriginal)(self, selector, activity);
    line("event=h585_activity_center_is_activity_active pid=%d main=%d object=%p activity=%p result=%d",
         getpid(), pthread_main_np(), (__bridge void *) self,
         (__bridge void *) activity, result ? 1 : 0);
    return result;
}

static BOOL trace_ac_activity_center_are_activities_enabled(
    id self, SEL selector)
{
    BOOL result = ((BOOL (*)(id, SEL))
        gACActivityCenterAreActivitiesEnabledOriginal)(self, selector);
    line("event=h585_activity_center_are_activities_enabled pid=%d main=%d object=%p result=%d",
         getpid(), pthread_main_np(), (__bridge void *) self, result ? 1 : 0);
    return result;
}

static id trace_ac_activity_authorization_init(id self, SEL selector)
{
    line("event=h585_activity_authorization_init_enter pid=%d main=%d",
         getpid(), pthread_main_np());
    id object = ((id (*)(id, SEL))
        gACActivityAuthorizationInitOriginal)(self, selector);
    line("event=h585_activity_authorization_init_return pid=%d main=%d object=%p class=%s",
         getpid(), pthread_main_np(), (__bridge void *) object,
         class_name_or_nil(object));
    return object;
}

static id trace_sbhiconmanager_localized_folder_name(
    id self, SEL selector, id displayName)
{
    (void)selector;
    line("event=h588_folder_name_localization_bypass pid=%d main=%d object=%p name=%.112s",
         getpid(), pthread_main_np(), (__bridge void *) self,
         displayName ? [(NSString *)displayName UTF8String] : "-");
    return displayName;
}

static void trace_sbhiconmanager_default_widget_intent(
    id self, SEL selector, id widget, id icon, id viewController)
{
    (void)selector;
    (void)widget;
    (void)icon;
    (void)viewController;
    line("event=h589_default_widget_intent_skip pid=%d main=%d object=%p widget=%p icon=%p controller=%p",
         getpid(), pthread_main_np(), (__bridge void *) self,
         (__bridge void *) widget, (__bridge void *) icon,
         (__bridge void *) viewController);
}

static void trace_sbhiconmodel_save_icon_state(id self, SEL selector)
{
    (void)selector;
    line("event=h590_icon_state_save_skip pid=%d main=%d object=%p",
         getpid(), pthread_main_np(), (__bridge void *) self);
}

static void trace_sbiconcontroller_prepare_today(id self, SEL selector)
{
    (void)selector;
    line("event=h591_today_layout_prepare_skip pid=%d main=%d object=%p",
         getpid(), pthread_main_np(), (__bridge void *) self);
}

static void trace_application_run(id self, SEL selector)
{
    rearm_exception_reporters("ui-run-enter");
    line("event=h557_ui_run_enter pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
    gDidFinishReturned = true;
    schedule_h557_post_run_snapshot();
    ((void (*)(id, SEL)) gApplicationRunOriginal)(self, selector);
    line("event=h557_ui_run_return pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
}

static void trace_springboard_start_system_status_server(id self, SEL selector)
{
    line("event=h542_status_server_bypass_enter pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
    ((void (*)(id, SEL)) gSpringBoardStartSystemStatusServer)(self, selector);
    line("event=h542_status_server_bypass_return pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
}

static void trace_mc_wait_for_migration(
    id self, SEL selector, BOOL includingPostRestore,
    BOOL waitUntilCompleted, id completion)
{
    (void) self;
    (void) selector;
    line("event=h543_mc_wait_bypass_enter pid=%d thread=%p main=%d include=%d wait=%d completion=%d",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         includingPostRestore ? 1 : 0, waitUntilCompleted ? 1 : 0,
         completion ? 1 : 0);
    line("event=h543_mc_wait_bypass_return pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
}

static BOOL trace_mc_should_show_cloud_configuration_ui(id self, SEL selector)
{
    (void) selector;
    line("event=h545_cloud_config_ui_bypass pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
    return NO;
}

/* H655: name the instruction the main thread is parked on.
 *
 * The sampler has printed the same pc/lr pair in every recent round, and lr is always
 * pc + 0x36cc, so the park site is one fixed call in one image. Only the load address of
 * that image changes each boot, which is why the address has never been identified.
 * dladdr resolves it inside this process, and the frame records chain the frames above it.
 * Stack words are read through vm_read_overwrite so a bad pointer returns an error here
 * instead of faulting the process being observed. */
static const uint64_t kH655PointerMask = 0x0000FFFFFFFFFFFFull;

static bool h655_read_word(uint64_t address, uint64_t *word)
{
    vm_size_t moved = 0;
    const kern_return_t status = vm_read_overwrite(
        mach_task_self(), (vm_address_t)address, sizeof(uint64_t),
        (vm_address_t)word, &moved);
    return status == KERN_SUCCESS && moved == sizeof(uint64_t);
}

static void h655_frame(unsigned delay, unsigned index, uint64_t address)
{
    Dl_info info;
    char image[80];
    address &= kH655PointerMask;
    if (dladdr((const void *)address, &info) && info.dli_fname && info.dli_fbase) {
        snprintf(image, sizeof image, "%.64s+0x%llx", info.dli_fname,
                 (unsigned long long)(address - (uint64_t)(uintptr_t)info.dli_fbase));
    } else {
        snprintf(image, sizeof image, "unmapped");
    }
    line("event=h655_stall_frame delay=%u i=%u addr=0x%llx image=%s",
         delay, index, (unsigned long long)address, image);
}

/* Walk the frame records of the sampled thread. The first two entries are pc and lr,
 * because a thread blocked in a leaf function has already stored its own frame, and the
 * chain then names each caller. The walk stops at the first frame record that does not
 * move forward, which is the normal end of a stack. */
static void h655_walk(unsigned delay, uint64_t pc, uint64_t lr, uint64_t fp)
{
    unsigned index = 0;
    const char *stop = "limit";
    h655_frame(delay, index++, pc);
    h655_frame(delay, index++, lr);
    fp &= kH655PointerMask;
    while (index < 16) {
        uint64_t next = 0;
        uint64_t ret = 0;
        if (!fp || (fp & 0x7)) { stop = "fp"; break; }
        if (!h655_read_word(fp, &next) || !h655_read_word(fp + 8, &ret)) { stop = "read"; break; }
        /* H656: the saved frame pointer is itself pointer-authenticated on arm64e, so the
         * continuity test has to run on the masked value. Without this the walk stopped at
         * _mach_msg every round and never named the caller that is waiting. */
        next &= kH655PointerMask;
        if (next <= fp || next - fp > 0x4000) { stop = "chain"; break; }
        h655_frame(delay, index++, ret);
        fp = next;
    }
    line("event=h655_stall_walk delay=%u frames=%u stop=%s", delay, index, stop);
}
/* H657: name the Mach call the sampled thread is sitting inside.
 *
 * The frame chain cannot leave _mach_msg, but thread_get_state already returned every
 * general-purpose register, and while the thread waits on the SVC the arguments are still
 * in them: x0 message buffer, x1 send size, x2 receive size, x3 options, x4 receive port,
 * x5 timeout, x6 send port. The 24-byte header at x0 is read in this process, so nothing
 * here changes what the thread is doing. */
static void h657_pending_ipc(unsigned delay, const arm_thread_state64_t *state)
{
    line("event=h657_stall_args delay=%u x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx x4=0x%llx x5=0x%llx x6=0x%llx",
         delay,
         (unsigned long long)state->__x[0], (unsigned long long)state->__x[1],
         (unsigned long long)state->__x[2], (unsigned long long)state->__x[3],
         (unsigned long long)state->__x[4], (unsigned long long)state->__x[5],
         (unsigned long long)state->__x[6]);

    const uint64_t buffer = state->__x[0] & kH655PointerMask;
    uint64_t words[3] = { 0, 0, 0 };
    unsigned read = 0;
    for (unsigned index = 0; index < 3; ++index) {
        if (!h655_read_word(buffer + index * sizeof(uint64_t), &words[index])) {
            break;
        }
        ++read;
    }
    line("event=h657_stall_msg delay=%u buffer=0x%llx read=%u bits=0x%x size=%u remote=0x%x local=0x%x reserved=0x%x id=%d",
         delay, (unsigned long long)buffer, read,
         (unsigned)(words[0] & 0xFFFFFFFFull), (unsigned)(words[0] >> 32),
         (unsigned)(words[1] & 0xFFFFFFFFull), (unsigned)(words[1] >> 32),
         (unsigned)(words[2] & 0xFFFFFFFFull), (int)(words[2] >> 32));
}
static void *sample_main_thread_after_setup_return(void *context)
{
    mach_port_t thread = (mach_port_t)(uintptr_t)context;
    static const unsigned delays[] = { 1, 2, 4, 7, 15, 30, 60, 120 };
    unsigned previous = 0;
    uint64_t lastPc = 0;
    unsigned walks = 0;
    for (unsigned index = 0; index < sizeof delays / sizeof delays[0]; ++index) {
        usleep((useconds_t)(delays[index] - previous) * 1000000);
        previous = delays[index];

        arm_thread_state64_t state;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        kern_return_t status = thread_get_state(
            thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
        line("event=h549_setup_return_main_sample delay=%u kr=0x%x count=%u pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx",
             delays[index], status, (unsigned)count,
             (unsigned long long)state.__pc,
             (unsigned long long)state.__lr,
             (unsigned long long)state.__sp,
             (unsigned long long)state.__fp);
        if (status != KERN_SUCCESS) {
            continue;
        }

        /* H655: walk the stack once the same pc has been seen twice, which is what a
         * park looks like, and once at 30 s if nothing repeated. Observer output stops
         * mid-session in every round, so the 60 s and 120 s samples have never arrived. */
        const bool repeated = state.__pc == lastPc;
        lastPc = state.__pc;
        if (walks < 2 && (repeated || (delays[index] == 30 && walks == 0))) {
            ++walks;
            h657_pending_ipc(delays[index], &state);
            h655_walk(delays[index], state.__pc, state.__lr, state.__fp);
        }
    }
    return NULL;
}

static void start_setup_return_sampler(void)
{
    if (gSetupReturnSamplerStarted) return;
    gSetupReturnSamplerStarted = true;

    mach_port_t mainThread = pthread_mach_thread_np(pthread_self());
    pthread_t sampler;
    if (pthread_create(&sampler, NULL, sample_main_thread_after_setup_return,
                       (void *)(uintptr_t)mainThread) == 0) {
        (void) pthread_detach(sampler);
        line("event=h549_setup_return_sampler_start pid=%d thread_port=0x%x",
             getpid(), mainThread);
    } else {
        line("event=h549_setup_return_sampler_start_failed pid=%d", getpid());
    }
}

static void trace_springboard_setup_hud(id self, SEL selector)
{
    line("event=h550_setup_hud_enter pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
    ((void (*)(id, SEL)) gSpringBoardSetupHUDOriginal)(self, selector);
    line("event=h550_setup_hud_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
}

static id trace_sound_controller_shared_instance(id self, SEL selector)
{
    line("event=h550_sound_shared_enter pid=%d thread=%p main=%d receiver=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         class_name_or_nil(self));
    id controller = ((id (*)(id, SEL)) gSoundControllerSharedInstanceOriginal)(
        self, selector);
    line("event=h550_sound_shared_return pid=%d thread=%p main=%d object=%p class=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) controller, class_name_or_nil(controller));
    return controller;
}

static id trace_sound_controller_init(id self, SEL selector)
{
    line("event=h550_sound_init_enter pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
    id controller = ((id (*)(id, SEL)) gSoundControllerInitOriginal)(
        self, selector);
    line("event=h550_sound_init_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) controller);
    return controller;
}

static id trace_ringer_control_init(id self, SEL selector,
                                    id bannerManager, id soundController)
{
    line("event=h550_ringer_init_enter pid=%d thread=%p main=%d object=%p banner=%p sound=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self, (__bridge void *) bannerManager,
         (__bridge void *) soundController);
    id control = ((id (*)(id, SEL, id, id)) gRingerControlInitOriginal)(
        self, selector, bannerManager, soundController);
    line("event=h550_ringer_init_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) control);
    return control;
}

static id trace_springboard_setup_manager_init(id self, SEL selector)
{
    line("event=h546_setup_manager_init_enter pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
    id manager = ((id (*)(id, SEL)) gSpringBoardSetupManagerInitOriginal)(
        self, selector);
    line("event=h546_setup_manager_init_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) manager);
    start_setup_return_sampler();
    return manager;
}

static id trace_status_domain_data_change_log_init(
    id self, SEL selector, id recordKeys)
{
    line("event=h551_status_data_log_empty_init_enter pid=%d thread=%p main=%d object=%p keys=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self, class_name_or_nil(recordKeys));
    id changeLog = ((id (*)(id, SEL, id)) gStatusDomainDataChangeLogInitOriginal)(
        self, selector, [NSArray array]);
    line("event=h551_status_data_log_empty_init_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) changeLog);
    return changeLog;
}

static id trace_telephony_manager_shared(id self, SEL selector)
{
    line("event=h552_telephony_shared_enter pid=%d thread=%p main=%d receiver=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         class_name_or_nil(self));
    id manager = ((id (*)(id, SEL)) gTelephonyManagerSharedOriginal)(
        self, selector);
    line("event=h552_telephony_shared_return pid=%d thread=%p main=%d object=%p class=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) manager, class_name_or_nil(manager));
    return manager;
}

static id trace_telephony_manager_shared_creating(
    id self, SEL selector, BOOL creatingIfNecessary)
{
    line("event=h552_telephony_shared_creating_enter pid=%d thread=%p main=%d create=%d",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         creatingIfNecessary ? 1 : 0);
    id manager = ((id (*)(id, SEL, BOOL))
        gTelephonyManagerSharedCreatingOriginal)(
            self, selector, creatingIfNecessary);
    line("event=h552_telephony_shared_creating_return pid=%d thread=%p main=%d object=%p class=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) manager, class_name_or_nil(manager));
    return manager;
}

static id trace_telephony_manager_init(id self, SEL selector)
{
    line("event=h552_telephony_init_enter pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
    id manager = ((id (*)(id, SEL)) gTelephonyManagerInitOriginal)(
        self, selector);
    line("event=h552_telephony_init_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) manager);
    return manager;
}

static id trace_application_controller_init(id self, SEL selector)
{
    line("event=h553_application_controller_init_enter pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) self);
    id controller = ((id (*)(id, SEL)) gApplicationControllerInitOriginal)(
        self, selector);
    line("event=h553_application_controller_init_return pid=%d thread=%p main=%d object=%p",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) controller);
    return controller;
}

static id trace_application_library_installed_application(
    id self, SEL selector, id bundleIdentifier)
{
    char identifier[128];
    copy_utf8(bundleIdentifier, identifier, sizeof identifier);
    line("event=h553_application_library_installed_application_enter pid=%d thread=%p main=%d bundle=%.112s",
         getpid(), (void *) pthread_self(), pthread_main_np(), identifier);
    id application = ((id (*)(id, SEL, id))
        gApplicationLibraryInstalledApplicationOriginal)(
            self, selector, bundleIdentifier);
    line("event=h553_application_library_installed_application_return pid=%d thread=%p main=%d object=%p class=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) application, class_name_or_nil(application));
    return application;
}

static id trace_application_library_installed_applications(
    id self, SEL selector, id bundleIdentifier)
{
    char identifier[128];
    copy_utf8(bundleIdentifier, identifier, sizeof identifier);
    line("event=h553_application_library_installed_applications_enter pid=%d thread=%p main=%d bundle=%.112s",
         getpid(), (void *) pthread_self(), pthread_main_np(), identifier);
    id applications = ((id (*)(id, SEL, id))
        gApplicationLibraryInstalledApplicationsOriginal)(
            self, selector, bundleIdentifier);
    line("event=h553_application_library_installed_applications_return pid=%d thread=%p main=%d object=%p class=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) applications, class_name_or_nil(applications));
    return applications;
}

static id trace_application_library_all_installed_applications(id self, SEL selector)
{
    line("event=h553_application_library_all_installed_enter pid=%d thread=%p main=%d",
         getpid(), (void *) pthread_self(), pthread_main_np());
    id applications = ((id (*)(id, SEL))
        gApplicationLibraryAllInstalledApplicationsOriginal)(self, selector);
    line("event=h553_application_library_all_installed_return pid=%d thread=%p main=%d object=%p class=%s",
         getpid(), (void *) pthread_self(), pthread_main_np(),
         (__bridge void *) applications, class_name_or_nil(applications));
    return applications;
}

static void trace_mutable_set_remove_object(id self, SEL selector, id object)
{
    if (!object) {
        line("event=h554_mutable_set_remove_nil_ignored pid=%d thread=%p main=%d set=%p class=%s",
             getpid(), (void *) pthread_self(), pthread_main_np(),
             (__bridge void *) self, class_name_or_nil(self));
        return;
    }
    ((void (*)(id, SEL, id)) gMutableSetRemoveObjectOriginal)(
        self, selector, object);
}

static void trace_concrete_mutable_set_remove_object(
    id self, SEL selector, id object)
{
    if (!object) {
        line("event=h554_mutable_set_remove_nil_ignored pid=%d thread=%p main=%d set=%p class=%s",
             getpid(), (void *) pthread_self(), pthread_main_np(),
             (__bridge void *) self, class_name_or_nil(self));
        return;
    }
    ((void (*)(id, SEL, id)) gConcreteMutableSetRemoveObjectOriginal)(
        self, selector, object);
}

extern "C" {
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
}

static bool connect_accelerator(void)
{
    if (gConnection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                        IOServiceMatching("IOAcceleratorES"));
    if (!service) return false;
    io_connect_t connection = 0;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS || !connection) return false;
    uint32_t probe[2] = { kTunnelMagic, 0xffffffffu };
    for (uint32_t selector = 0; selector < 256; ++selector) {
        if (IOConnectCallStructMethod(connection, selector, probe, sizeof probe, NULL, NULL) ==
            KERN_SUCCESS) {
            gConnection = connection;
            gSelector = selector;
            return true;
        }
    }
    IOServiceClose(connection);
    return false;
}

/* H648: hand this boot's desktop context id to the render server process.

 * The position probe in backboardd cannot answer whether the server knows the desktop context,
 * because a zero there is ambiguous between "not attached" and "sampled outside its coverage".
 * The one thing that would settle it is asking the server about the exact id the desktop process
 * created. That id only exists inside SpringBoard, so it has to cross over.
 *
 * The channel is not new: both processes already call into the same AGXDeviceUserClient tunnel on
 * every log line, and SetMetadata is already implemented there and already stores its text in the
 * kernel. This only uses that existing path, once, and reports the kern_return so a failure is a
 * stated fact rather than a silent absence. */
/* H652: report every context this process creates, not just the first.

 * H651 showed SpringBoard created three remote contexts at 515.4, 654.0 and 663.0s while
 * publish_desktop_context_id fired once, so what was proven is only that some SpringBoard context
 * sits in the server port table, not that it is the desktop one. The fields that matter for the
 * first frame - which display the context points at, whether it has a layer, whether that layer
 * carries contents - are plain properties of the context object and are readable right here, in
 * the process that created it. +[CAContext contextWithId:] returns nil in backboardd for a foreign
 * id, so the server side object is not reachable; the client side one is.
 *
 * Each context therefore gets its own line with the full fields, and the 64 byte SetMetadata slot
 * gets a cumulative summary so the render server side query keeps working without silently
 * reporting only the oldest context. */
static IMP gTransactionFlushPublicOriginal;
static IMP gTransactionCommitPublicOriginal;
static unsigned gTxFlushCount;
static unsigned gTxCommitCount;
static int gTxControlHit;

/* control block shared with the H674 asm stubs (layout documented at the
 * install_h674_got_rebinding definition below) */
extern "C" uint64_t gH674Ctl[12] __attribute__((aligned(64))) = { 0 };

/* H672: observe the transaction commit entry and the real send boundary from
 * inside SpringBoard WITHOUT touching any page. The 21H461 audit (STATUS 379/
 * 381/383) fixed the map: the CFRunLoop observer QuartzCore registers is the
 * C function CA::Transaction::observer_callback (static vm 0x189452974); it
 * tail-branches flush_as_runloop_observer, which calls CA::Transaction::
 * commit() (and flush(), whose body tail-branches commit()). Every run-loop
 * driven commit therefore crosses observer_callback, which no ObjC hook can
 * see - that is exactly the blind spot that left H670 at tx=1/0. The payload
 * leaves the process as mach messages sent to the CARenderServer connection
 * port obtained through bootstrap_look_up. All three points sit on exported
 * C functions, so DYLD interposition covers them with no inline patching;
 * H671 proved the page-protect route kills SpringBoard (STATUS 383). */
static volatile uint64_t gH672ObserverFires;
static volatile uint64_t gH672MachSends;
static volatile uint64_t gH672MachTotal;
static volatile uint64_t gH672Flags; /* 1 observer captured, 2 mach live, 4 render port */
static uintptr_t gH672CaObserverCallback;
static CFRunLoopObserverCallBack gH672RealObserverCallback;
static mach_port_t gH672RenderPort = MACH_PORT_NULL;

static void h672_ca_observer_wrapper(CFRunLoopObserverRef observer,
                                     CFOptionFlags activity, void *info)
{
    ++gH672ObserverFires;
    if (gH672RealObserverCallback) gH672RealObserverCallback(observer, activity, info);
}

static void h672_install_ca_observer_anchor(void)
{
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && strncmp(name, "/System/", 8) == 0 &&
            strstr(name, "/QuartzCore.framework/QuartzCore")) {
            gH672CaObserverCallback =
                (uintptr_t)0x189452974ULL + (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            return;
        }
    }
}

static CFRunLoopObserverRef h672_obs_create(CFAllocatorRef allocator,
    CFOptionFlags activities, Boolean repeats, CFIndex order,
    CFRunLoopObserverCallBack callback, CFRunLoopObserverContext *context)
{
    __atomic_add_fetch(&gH674Ctl[0], 1, __ATOMIC_RELAXED);
    if (callback && gH672CaObserverCallback &&
        (uintptr_t)callback == gH672CaObserverCallback) {
        gH672RealObserverCallback = callback;
        gH672Flags |= 1;
        callback = h672_ca_observer_wrapper;
    }
    return CFRunLoopObserverCreate(allocator, activities, repeats, order, callback, context);
}


static kern_return_t h672_bootstrap_look_up(mach_port_t bp, const char *service_name,
                                            mach_port_t *sp)
{
    __atomic_add_fetch(&gH674Ctl[1], 1, __ATOMIC_RELAXED);
    const kern_return_t kr = bootstrap_look_up(bp, service_name, sp);
    if (kr == KERN_SUCCESS && service_name && sp &&
        strstr(service_name, "CARenderServer") != NULL) {
        gH672RenderPort = *sp;
        gH674Ctl[8] = (uint64_t)*sp;
        gH672Flags |= 4;
    }
    return kr;
}

static inline void h672_count_send(const mach_msg_header_t *msg, mach_msg_option_t option)
{
    /* Only calls from other images reach this wrapper: dyld keeps the
     * replacement own binding to the original, so a nonzero total here is
     * itself the proof that the interpose is live. */
    ++gH672MachTotal;
    gH672Flags |= 2;
    if (gH672RenderPort != MACH_PORT_NULL && (option & MACH_SEND_MSG) &&
        msg && msg->msgh_remote_port == gH672RenderPort) {
        ++gH672MachSends;
    }
}

static mach_msg_return_t h672_mach_msg(mach_msg_header_t *msg, mach_msg_option_t option,
    mach_msg_size_t send_size, mach_msg_size_t rcv_size, mach_port_name_t rcv_name,
    mach_msg_timeout_t timeout, mach_port_name_t notify)
{
    h672_count_send(msg, option);
    return mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
}

static mach_msg_return_t h672_mach_msg_overwrite(mach_msg_header_t *msg,
    mach_msg_option_t option, mach_msg_size_t send_size, mach_msg_size_t rcv_size,
    mach_port_name_t rcv_name, mach_msg_timeout_t timeout, mach_port_name_t notify,
    mach_msg_header_t *rcv_msg, mach_msg_size_t rcv_limit)
{
    h672_count_send(msg, option);
    return mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name,
                              timeout, notify, rcv_msg, rcv_limit);
}


/* H674: H673 proved the data-slot rebinding itself is safe (21 slots
 * rewritten, SpringBoard untouched) but the __got-only scan never met the
 * hot paths: every wrapper stayed at zero. STATUS 385 lists the two
 * candidate explanations (the swapped slots belong to cold callers, or the
 * cache images reach these imports through data outside the named __got
 * sections) and this round is built to separate them: the scan now walks
 * every section of every writable data segment, targets the full mach_msg
 * family including the iOS 17 hot pair mach_msg2/mach_msg2_trap (installed
 * as prototype-free asm pass-through stubs that keep all argument
 * registers), counts every wrapper entry unconditionally, and records for
 * each swap which image and section it landed in. */
static uint64_t gH674Swapped[6];
static uint64_t gH674ScanPass;
static uint64_t gH674Reported;
/* control block shared with the asm stubs:
 * 0 observer entries, 8 bootstrap entries, 16 mach_msg2 entries,
 * 24 mach_msg2_trap entries, 32 mach_msg2 render-port sends,
 * 40 mach_msg2_trap render-port sends, 48 real mach_msg2,
 * 56 real mach_msg2_trap, 64 render port mirror */
extern "C" void h674_msg2_stub(void);
extern "C" void h674_msg2trap_stub(void);

__asm__(
".text\n"
".p2align 2\n"
".globl _h674_msg2_stub\n"
"_h674_msg2_stub:\n"
"    adrp x16, _gH674Ctl@PAGE\n"
"    add  x16, x16, _gH674Ctl@PAGEOFF\n"
"    ldr  x17, [x16, #16]\n"
"    add  x17, x17, #1\n"
"    str  x17, [x16, #16]\n"
"    cbz  x0, 1f\n"
"    ldr  x8, [x16, #64]\n"
"    cbz  x8, 1f\n"
"    ldr  w17, [x0, #8]\n"
"    cmp  w17, w8\n"
"    b.ne 1f\n"
"    ldr  x17, [x16, #32]\n"
"    add  x17, x17, #1\n"
"    str  x17, [x16, #32]\n"
"1:  ldr  x16, [x16, #48]\n"
"    cbz  x16, 2f\n"
"    br   x16\n"
"2:  mov  w0, #0x4\n"
"    ret\n"
".p2align 2\n"
".globl _h674_msg2trap_stub\n"
"_h674_msg2trap_stub:\n"
"    adrp x16, _gH674Ctl@PAGE\n"
"    add  x16, x16, _gH674Ctl@PAGEOFF\n"
"    ldr  x17, [x16, #24]\n"
"    add  x17, x17, #1\n"
"    str  x17, [x16, #24]\n"
"    cbz  x0, 1f\n"
"    ldr  x8, [x16, #64]\n"
"    cbz  x8, 1f\n"
"    ldr  w17, [x0, #8]\n"
"    cmp  w17, w8\n"
"    b.ne 1f\n"
"    ldr  x17, [x16, #40]\n"
"    add  x17, x17, #1\n"
"    str  x17, [x16, #40]\n"
"1:  ldr  x16, [x16, #56]\n"
"    cbz  x16, 2f\n"
"    br   x16\n"
"2:  mov  w0, #0x4\n"
"    ret\n"
);

static const char kH674Letters[6] = { 'o', 'b', 'm', 'w', '2', '3' };
static char gH674Log[8][40];
static uint64_t gH674LogCount;

static void h674_scan_image(const struct mach_header_64 *mh, intptr_t slide,
                            const char *imageName,
                            const void *targets[6], const void *replacements[6])
{
    const uint8_t *cursor = (const uint8_t *)mh + sizeof (struct mach_header_64);
    for (uint32_t command = 0; command < mh->ncmds; ++command) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strncmp(seg->segname, "__DATA", 16) != 0 &&
            strncmp(seg->segname, "__DATA_CONST", 16) != 0 &&
            strncmp(seg->segname, "__DATA_DIRTY", 16) != 0) continue;
        const struct section_64 *sections = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; ++s) {
            const struct section_64 *sec = &sections[s];
            if (sec->size < 8 || sec->size > (16u << 20)) continue;
            const uintptr_t base = (uintptr_t)(sec->addr) + (uintptr_t)slide;
            const size_t count = sec->size / 8;
            void **slots = (void **)base;
            bool writable = false;
            for (size_t i = 0; i < count; ++i) {
                void *value = __atomic_load_n(&slots[i], __ATOMIC_ACQUIRE);
                for (int t = 0; t < 6; ++t) {
                    if (!targets[t] || value != targets[t]) continue;
                    if (!writable) {
                        const uintptr_t page = base & ~(uintptr_t)0xFFF;
                        const vm_size_t span = (vm_size_t)
                            (((base + sec->size) - page + 0xFFF) & ~(uintptr_t)0xFFF);
                        if (vm_protect(mach_task_self(), (vm_address_t)page, span,
                                       FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS &&
                            vm_protect(mach_task_self(), (vm_address_t)page, span,
                                       FALSE, VM_PROT_READ | VM_PROT_WRITE |
                                              VM_PROT_COPY) != KERN_SUCCESS)
                            t = 6;
                        else
                            writable = true;
                    }
                    if (!writable) continue;
                    __atomic_store_n(&slots[i], (void *)replacements[t],
                                     __ATOMIC_RELEASE);
                    ++gH674Swapped[t];
                    if (gH674LogCount < 8)
                        snprintf(gH674Log[gH674LogCount++], 40, "%c:%s/%s",
                                 kH674Letters[t], imageName, sec->sectname);
                }
            }
        }
    }
}

static void install_h674_got_rebinding(void)
{
    if (gH674ScanPass >= 2) return;
    ++gH674ScanPass;
    Dl_info self;
    const void *selfBase =
        dladdr((const void *)&h672_mach_msg, &self) ? self.dli_fbase : NULL;
    const void *targets[6] = {
        dlsym(RTLD_DEFAULT, "CFRunLoopObserverCreate"),
        dlsym(RTLD_DEFAULT, "bootstrap_look_up"),
        dlsym(RTLD_DEFAULT, "mach_msg"),
        dlsym(RTLD_DEFAULT, "mach_msg_overwrite"),
        dlsym(RTLD_DEFAULT, "mach_msg2"),
        dlsym(RTLD_DEFAULT, "mach_msg2_trap"),
    };
    const void *replacements[6] = {
        (const void *)h672_obs_create,
        (const void *)h672_bootstrap_look_up,
        (const void *)h672_mach_msg,
        (const void *)h672_mach_msg_overwrite,
        (const void *)&h674_msg2_stub,
        (const void *)&h674_msg2trap_stub,
    };
    gH674Ctl[6] = (uint64_t)(uintptr_t)targets[4];
    gH674Ctl[7] = (uint64_t)(uintptr_t)targets[5];
    if (gH672RenderPort != MACH_PORT_NULL)
        gH674Ctl[8] = (uint64_t)gH672RenderPort;
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || (const void *)mh == selfBase) continue;
        if (mh->magic != MH_MAGIC_64) continue;
        const char *name = _dyld_get_image_name(i);
        if (name) {
            const char *leaf = strrchr(name, '/');
            name = leaf ? leaf + 1 : name;
        } else {
            name = "?";
        }
        h674_scan_image(mh, _dyld_get_image_vmaddr_slide(i), name,
                        targets, replacements);
    }
    for (int t = 0; t < 6; ++t)
        if (gH674Swapped[t]) {
            gH672Flags |= 8;
            break;
        }
}

static void publish_desktop_context_summary(unsigned created, unsigned onDisplay, unsigned withLayer,
                                            unsigned withContents, uint64_t lastId)
{
    install_h674_got_rebinding();
    if (!connect_accelerator()) {
        line_reserved("event=h652_publish n=%u d1=%u lc=%u ct=%u id=0x%llx result=no-accelerator",
                      created, onDisplay, withLayer, withContents, lastId);
        return;
    }
    struct {
        uint64_t handle;
        uint32_t bytes;
        uint32_t reserved;
        char text[64];
    } meta;
    memset(&meta, 0, sizeof meta);
    const int length = snprintf(meta.text, sizeof meta.text,
                                "sb n=%u d1=%u id=0x%llx tx=%u/%u c=%d of=%u mm=%u ok=%u",
                                created, onDisplay, lastId,
                                gTxFlushCount, gTxCommitCount, gTxControlHit,
                                (unsigned)(gH672ObserverFires > 99999ULL ? 99999ULL : gH672ObserverFires),
                                (unsigned)(gH672MachSends > 99999ULL ? 99999ULL : gH672MachSends),
                                (unsigned)gH672Flags);
    if (length <= 0 || (size_t) length >= sizeof meta.text) {
        line_reserved("event=h652_publish n=%u result=format", created);
        return;
    }
    meta.bytes = (uint32_t) length;
    struct {
        uint32_t magic, method;
        uint64_t handle;
        uint32_t bytes, reserved;
        char text[64];
    } request;
    memset(&request, 0, sizeof request);
    request.magic = kTunnelMagic;
    request.method = kMethodSetMetadata;
    request.handle = meta.handle;
    request.bytes = meta.bytes;
    memcpy(request.text, meta.text, sizeof meta.text);
    const kern_return_t status = IOConnectCallStructMethod(
        gConnection, gSelector, &request, sizeof request, NULL, NULL);
    line_reserved("event=h652_publish n=%u d1=%u lc=%u ct=%u id=0x%llx bytes=%u st=0x%x h672 of=%llu mm=%llu mt=%llu ok=%llu sw=%llu/%llu/%llu/%llu/%llu/%llu",
                  created, onDisplay, withLayer, withContents, lastId,
                  (unsigned) length, (unsigned) status,
                  (unsigned long long)gH672ObserverFires, (unsigned long long)gH672MachSends,
                  (unsigned long long)gH672MachTotal, (unsigned long long)gH672Flags,
                  (unsigned long long)gH674Swapped[0], (unsigned long long)gH674Swapped[1],
                  (unsigned long long)gH674Swapped[2], (unsigned long long)gH674Swapped[3],
                  (unsigned long long)gH674Swapped[4], (unsigned long long)gH674Swapped[5]);
    if (!gH674Reported && (gH674Ctl[0] || gH674Ctl[1] || gH674Ctl[2] || gH674Ctl[3]))
        gH672Flags |= 16;
    if (!gH674Reported) {
        gH674Reported = 1;
        line_reserved("event=h674_state e=%llu,%llu,%llu,%llu s=%llu,%llu p=0x%llx ok=%llu",
                      (unsigned long long)gH674Ctl[0], (unsigned long long)gH674Ctl[1],
                      (unsigned long long)gH674Ctl[2], (unsigned long long)gH674Ctl[3],
                      (unsigned long long)gH674Ctl[4], (unsigned long long)gH674Ctl[5],
                      (unsigned long long)gH674Ctl[8], (unsigned long long)gH672Flags);
        for (uint64_t i = 0; i < gH674LogCount; ++i)
            line_reserved("event=h674_at %s", gH674Log[i]);
    }
}

static void emit_internal(const char *text, bool reserved)
{
    if (!text || (!reserved && gBudget == 0)) return;
    if (!reserved) --gBudget;

    if (gConsole == -2) gConsole = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (gConsole >= 0) {
        char output[kMaxLog + 24];
        int length = snprintf(output, sizeof output, "H436_SBSCENE: %s\n", text);
        if (length > 0) {
            size_t count = (size_t) length;
            if (count >= sizeof output) count = sizeof output - 1;
            (void) write(gConsole, output, count);
        }
    }

    if (!connect_accelerator()) return;
    struct {
        uint32_t magic, method, bytes, reserved;
        char text[kMaxLog];
    } request;
    memset(&request, 0, sizeof request);
    request.magic = kTunnelMagic;
    request.method = kMethodLog;
    size_t n = strlen(text);
    if (n > kMaxLog) n = kMaxLog;
    request.bytes = (uint32_t) n;
    memcpy(request.text, text, n);
    IOConnectCallStructMethod(gConnection, gSelector, &request, sizeof request, NULL, NULL);
}

static void emit(const char *text)
{
    emit_internal(text, false);
}

static void line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void line(const char *format, ...)
{
    char text[kMaxLog + 1];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    emit(text);
}

static void line_reserved(const char *format, ...)
    __attribute__((format(printf, 1, 2)));
static void line_reserved(const char *format, ...)
{
    char text[kMaxLog + 1];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    emit_internal(text, true);
}

static Method instance_method(id object, const char *name)
{
    if (!object || !name) return NULL;
    return class_getInstanceMethod(object_getClass(object), sel_getUid(name));
}

static const char *instance_encoding(id object, const char *name)
{
    Method method = instance_method(object, name);
    return method ? method_getTypeEncoding(method) : NULL;
}

static id read_object(id object, const char *name)
{
    const char *encoding = instance_encoding(object, name);
    if (!encoding || encoding[0] != '@') return nil;
    @try {
        return ((id (*)(id, SEL)) objc_msgSend)(object, sel_getUid(name));
    } @catch (id ignored) {
        return nil;
    }
}

static bool read_integer(id object, const char *name, unsigned long long *value)
{
    const char *encoding = instance_encoding(object, name);
    if (!encoding || !value || !strchr("cCsSiIlLqQBb", encoding[0])) return false;
    @try {
        *value = ((unsigned long long (*)(id, SEL)) objc_msgSend)(object, sel_getUid(name));
        return true;
    } @catch (id ignored) {
        return false;
    }
}

static void copy_utf8(id value, char *out, size_t size)
{
    if (!out || !size) return;
    out[0] = 0;
    if (!value || ![value isKindOfClass:[NSString class]]) {
        snprintf(out, size, "-");
        return;
    }
    const char *text = [(NSString *) value UTF8String];
    snprintf(out, size, "%s", text ? text : "-");
}

static void copy_description(id value, char *out, size_t size)
{
    if (!out || !size) return;
    out[0] = 0;
    if (!value) {
        snprintf(out, size, "nil");
        return;
    }
    if ([value isKindOfClass:[NSString class]]) {
        copy_utf8(value, out, size);
        return;
    }
    if ([value respondsToSelector:@selector(description)]) {
        @try {
            id description = ((id (*)(id, SEL)) objc_msgSend)(
                value, @selector(description));
            copy_utf8(description, out, size);
            return;
        } @catch (id ignored) {
        }
    }
    snprintf(out, size, "<%s>", object_getClassName(value));
}

static void trace_uncaught_exception(NSException *exception)
{
    char name[80];
    char reason[160];
    copy_utf8([exception name], name, sizeof name);
    copy_utf8([exception reason], reason, sizeof reason);
    line("event=h550_uncaught_exception pid=%d name=%.72s reason=%.144s",
         getpid(), name, reason);

    NSArray<NSString *> *symbols = [exception callStackSymbols];
    unsigned long long count = symbols ? [symbols count] : 0;
    for (unsigned long long index = 0; index < count && index < 24; ++index) {
        char symbol[160];
        copy_utf8([symbols objectAtIndex:index], symbol, sizeof symbol);
        line("event=h550_uncaught_exception_frame index=%llu symbol=%.144s",
             index, symbol);
    }
}

extern "C" void objc_exception_throw(id exception);

[[noreturn]] static void trace_objc_exception_throw(id exception)
{
    char name[80] = "-";
    char reason[160] = "-";
    copy_utf8([exception name], name, sizeof name);
    copy_utf8([exception reason], reason, sizeof reason);
    line_reserved(
        "event=h580_objc_exception pid=%d main=%d class=%s name=%.72s reason=%.144s caller=%p",
        getpid(), pthread_main_np(), class_name_or_nil(exception), name, reason,
        __builtin_return_address(0));
    if (!gOriginalObjcExceptionThrow) {
        void *library = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW | RTLD_LOCAL);
        if (library) {
            gOriginalObjcExceptionThrow =
                (void (*)(id)) dlsym(library, "objc_exception_throw");
        }
    }
    if (gOriginalObjcExceptionThrow) gOriginalObjcExceptionThrow(exception);
    std::abort();
}

__attribute__((used, section("__DATA,__interpose")))
static const DyldInterpose gObjcExceptionThrowInterpose[] = {
    {
        (const void *) trace_objc_exception_throw,
        (const void *) objc_exception_throw,
    },
};

static void trace_cxx_terminate()
{
    const std::type_info *type = abi::__cxa_current_exception_type();
    char what[160] = "<no-current-exception>";
    std::exception_ptr current = std::current_exception();
    if (current) {
        try {
            std::rethrow_exception(current);
        } catch (const std::exception &exception) {
            const char *value = exception.what();
            if (value && *value) {
                snprintf(what, sizeof what, "%.144s", value);
            } else {
                strlcpy(what, "<empty>", sizeof what);
            }
        } catch (...) {
            strlcpy(what, "<non-std-exception>", sizeof what);
        }
    }

    line_reserved(
        "event=h572_cxx_terminate pid=%d thread=%p main=%d type=%.96s what=%.144s",
        getpid(), (void *) pthread_self(), pthread_main_np(),
        type ? type->name() : "<no-type>", what);

    std::terminate_handler previous = gPreviousTerminateHandler;
    gPreviousTerminateHandler = NULL;
    if (previous && previous != trace_cxx_terminate) previous();
    std::abort();
}

static void trace_abort_signal(int number, siginfo_t *info, void *context)
{
    if (gInAbortReport) {
        signal(number, SIG_DFL);
        raise(number);
        _exit(128 + number);
    }
    gInAbortReport = 1;
    ucontext_t *state = (ucontext_t *) context;
    unsigned long long pc = state ? (unsigned long long) state->uc_mcontext->__ss.__pc : 0;
    unsigned long long lr = state ? (unsigned long long) state->uc_mcontext->__ss.__lr : 0;
    unsigned long long sp = state ? (unsigned long long) state->uc_mcontext->__ss.__sp : 0;
    unsigned long long fp = state ? (unsigned long long) state->uc_mcontext->__ss.__fp : 0;
    line_reserved(
        "event=h578_abort_signal pid=%d number=%d addr=%p pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx",
        getpid(), number, info ? info->si_addr : NULL, pc, lr, sp, fp);
    for (unsigned depth = 0; depth < 16 && fp; ++depth) {
        const unsigned long long *frame = (const unsigned long long *) (uintptr_t) fp;
        unsigned long long next = frame ? frame[0] : 0;
        unsigned long long ret = frame ? frame[1] : 0;
        line_reserved("event=h578_abort_frame index=%u fp=0x%llx ret=0x%llx",
                      depth, fp, ret);
        if ((next & 7) || (sp && (next < sp || next - sp > 0x40000))) break;
        fp = next;
    }
    if (gAbortActionSaved) {
        sigaction(number, &gPreviousAbortAction, NULL);
    } else {
        signal(number, SIG_DFL);
    }
    raise(number);
    _exit(128 + number);
}

static void trace_fatal_signal(int number, siginfo_t *info, void *context)
{
    if (gInFatalSignalReport) {
        signal(number, SIG_DFL);
        raise(number);
        _exit(128 + number);
    }
    gInFatalSignalReport = 1;
    ucontext_t *state = (ucontext_t *) context;
    unsigned long long pc = state ? (unsigned long long) state->uc_mcontext->__ss.__pc : 0;
    unsigned long long lr = state ? (unsigned long long) state->uc_mcontext->__ss.__lr : 0;
    unsigned long long sp = state ? (unsigned long long) state->uc_mcontext->__ss.__sp : 0;
    unsigned long long fp = state ? (unsigned long long) state->uc_mcontext->__ss.__fp : 0;
    line_reserved(
        "event=h593_fatal_signal pid=%d number=%d addr=%p pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx",
        getpid(), number, info ? info->si_addr : NULL, pc, lr, sp, fp);
    for (unsigned depth = 0; depth < 16 && fp; ++depth) {
        const unsigned long long *frame = (const unsigned long long *) (uintptr_t) fp;
        unsigned long long next = frame ? frame[0] : 0;
        unsigned long long ret = frame ? frame[1] : 0;
        line_reserved("event=h593_fatal_frame index=%u fp=0x%llx ret=0x%llx",
                      depth, fp, ret);
        if ((next & 7) || (sp && (next < sp || next - sp > 0x40000))) break;
        fp = next;
    }
    if (number == SIGSEGV && gSegvActionSaved) {
        sigaction(number, &gPreviousSegvAction, NULL);
    } else if (number == SIGILL && gIllActionSaved) {
        sigaction(number, &gPreviousIllAction, NULL);
    } else {
        signal(number, SIG_DFL);
    }
    raise(number);
    _exit(128 + number);
}

static void install_fatal_signal_reporters(void)
{
    if (!gSegvActionSaved) {
        struct sigaction action;
        memset(&action, 0, sizeof action);
        action.sa_sigaction = trace_fatal_signal;
        action.sa_flags = SA_SIGINFO | SA_NODEFER;
        if (sigaction(SIGSEGV, NULL, &gPreviousSegvAction) == 0) {
            gSegvActionSaved = 1;
        }
        sigaction(SIGSEGV, &action, NULL);
    }
    if (!gIllActionSaved) {
        struct sigaction action;
        memset(&action, 0, sizeof action);
        action.sa_sigaction = trace_fatal_signal;
        action.sa_flags = SA_SIGINFO | SA_NODEFER;
        if (sigaction(SIGILL, NULL, &gPreviousIllAction) == 0) {
            gIllActionSaved = 1;
        }
        sigaction(SIGILL, &action, NULL);
    }
    line_reserved("event=h593_signal_hooks pid=%d segv=%d ill=%d",
                  getpid(), gSegvActionSaved ? 1 : 0, gIllActionSaved ? 1 : 0);
}

static void rearm_exception_reporters(const char *site)
{
    gPreviousTerminateHandler = std::set_terminate(trace_cxx_terminate);
    NSSetUncaughtExceptionHandler(trace_uncaught_exception);
    if (!gAbortActionSaved) {
        struct sigaction action;
        memset(&action, 0, sizeof action);
        action.sa_sigaction = trace_abort_signal;
        action.sa_flags = SA_SIGINFO | SA_NODEFER;
        if (sigaction(SIGABRT, NULL, &gPreviousAbortAction) == 0) {
            gAbortActionSaved = 1;
        }
        sigaction(SIGABRT, &action, NULL);
    }
    install_fatal_signal_reporters();
    line_reserved(
        "event=h578_exception_reporters_rearmed pid=%d main=%d site=%s terminate=%d abort_saved=%d segv_saved=%d ill_saved=%d",
        getpid(), pthread_main_np(), site ? site : "?",
        gPreviousTerminateHandler ? 1 : 0, gAbortActionSaved ? 1 : 0,
        gSegvActionSaved ? 1 : 0, gIllActionSaved ? 1 : 0);

}

[[noreturn]] static void h575_cxa_throw(
    void *exception, std::type_info *type, void (*destructor)(void *))
{
    if (type && !strcmp(type->name(), "NSException")) {
        id object = (__bridge id) exception;
        char name[80] = "-";
        char reason[160] = "-";
        copy_utf8([object name], name, sizeof name);
        copy_utf8([object reason], reason, sizeof reason);
        line_reserved(
            "event=h581_nsexception pid=%d main=%d class=%s name=%.72s reason=%.144s caller=%p",
            getpid(), pthread_main_np(), class_name_or_nil(object), name, reason,
            __builtin_return_address(0));
    }
    line_reserved(
        "event=h575_cxx_throw pid=%d thread=%p main=%d type=%.112s exception=%p caller=%p",
        getpid(), (void *) pthread_self(), pthread_main_np(),
        type ? type->name() : "<no-type>", exception,
        __builtin_return_address(0));
    abi::__cxa_throw(exception, type, destructor);
}

__attribute__((used, section("__DATA,__interpose")))
static const DyldInterpose gCxaThrowInterpose[] = {
    {
        (const void *) h575_cxa_throw,
        (const void *) &abi::__cxa_throw,
    },
};

static const char *class_name_or_nil(id object)
{
    return object ? object_getClassName(object) : "nil";
}

static bool selector_name_is_relevant(const char *name)
{
    static const char *const tokens[] = {
        "shared", "main", "scene", "workspace", "window", "display"
    };
    if (!name) return false;
    for (unsigned index = 0; index < sizeof tokens / sizeof tokens[0]; ++index) {
        if (strstr(name, tokens[index])) return true;
    }
    return false;
}

static void inventory_class(const char *name)
{
    Class cls = NSClassFromString([NSString stringWithUTF8String:name]);
    line("sbclass name=%s exists=%d", name, cls ? 1 : 0);
    if (!cls) return;
    unsigned methodCount = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &methodCount);
    unsigned shown = 0;
    line("sbclass name=%s classMethods=%u", name, methodCount);
    for (unsigned index = 0; methods && index < methodCount && shown < 32; ++index) {
        const char *selector = sel_getName(method_getName(methods[index]));
        if (!selector_name_is_relevant(selector)) continue;
        line("sbclass name=%s classSelector=%s", name, selector);
        ++shown;
    }
    free(methods);
}

static void inventory_springboard_classes(void)
{
    static const char *const classes[] = {
        "SBMainWorkspace",
        "SBSceneManagerCoordinator",
        "SBMainDisplaySceneManager",
        "SBWindowSceneManager",
        "SBApplicationController",
        "FBSceneManager",
        "SpringBoard"
    };
    line("sbinventory begin");
    for (unsigned index = 0; index < sizeof classes / sizeof classes[0]; ++index)
        inventory_class(classes[index]);
    line("sbinventory end");
}

static id call_checked_class_selector(const char *className, const char *selectorName)
{
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) return nil;
    SEL selector = sel_getUid(selectorName);
    if (![(id) cls respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL)) objc_msgSend)((id) cls, selector);
    } @catch (id ignored) {
        return nil;
    }
}

static void inventory_instance_methods(const char *label, id object)
{
    if (!object) return;
    unsigned methodCount = 0;
    Class cls = object_getClass(object);
    Method *methods = class_copyMethodList(cls, &methodCount);
    unsigned shown = 0;
    line("sbinstance name=%s class=%s methods=%u",
         label, object_getClassName(object), methodCount);
    for (unsigned index = 0; methods && index < methodCount && shown < 32; ++index) {
        const char *selector = sel_getName(method_getName(methods[index]));
        if (!selector_name_is_relevant(selector)) continue;
        line("sbinstance name=%s selector=%s", label, selector);
        ++shown;
    }
    free(methods);
}

static void probe_nonblocking_shared_instances(void)
{
    id mainWorkspace = call_checked_class_selector(
        "SBMainWorkspace", "sharedInstanceIfExists");
    id applicationController = call_checked_class_selector(
        "SBApplicationController", "sharedInstanceIfExists");
    line("sbexists name=SBMainWorkspace value=%d class=%s",
         mainWorkspace ? 1 : 0, class_name_or_nil(mainWorkspace));
    line("sbexists name=SBApplicationController value=%d class=%s",
         applicationController ? 1 : 0, class_name_or_nil(applicationController));
    if (mainWorkspace) inventory_instance_methods("SBMainWorkspace", mainWorkspace);
}

static id normalized_collection(id collection)
{
    if (!collection) return nil;
    if ([collection isKindOfClass:[NSDictionary class]]) return [collection allValues];
    if ([collection isKindOfClass:[NSSet class]]) return [collection allObjects];
    return collection;
}

static unsigned long long collection_count(id collection)
{
    collection = normalized_collection(collection);
    if (!collection || ![collection respondsToSelector:@selector(count)]) return 0;
    return ((unsigned long long (*)(id, SEL)) objc_msgSend)(
        collection, @selector(count));
}

static id collection_object_at(id collection, unsigned long long index)
{
    collection = normalized_collection(collection);
    if (!collection || ![collection respondsToSelector:@selector(objectAtIndex:)])
        return nil;
    return ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
        collection, @selector(objectAtIndex:), index);
}

static void log_object_field(const char *scope, unsigned index, id scene, const char *field)
{
    id value = read_object(scene, field);
    line("scene=%s/%u field=%s present=%d class=%s", scope, index, field,
         value ? 1 : 0, class_name_or_nil(value));
}

static bool first_host_context(uint32_t contextId)
{
    if (!contextId) return false;
    for (unsigned index = 0; index < gHostContextCount; ++index) {
        if (gHostContextIds[index] == contextId) return false;
    }
    if (gHostContextCount == sizeof gHostContextIds / sizeof gHostContextIds[0])
        return false;
    gHostContextIds[gHostContextCount++] = contextId;
    return true;
}

static void snapshot_dictionary(const char *scope, id dictionary)
{
    if (!dictionary || ![dictionary isKindOfClass:[NSDictionary class]]) {
        line("hierarchy=dictionary scope=%s present=0", scope);
        return;
    }
    NSArray *allKeys = ((NSDictionary *) dictionary).allKeys;
    line("hierarchy=dictionary scope=%s count=%llu", scope,
         collection_count(allKeys));
    unsigned long long count = collection_count(allKeys);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        id key = collection_object_at(allKeys, index);
        id value = key ? [dictionary objectForKey:key] : nil;
        char keyText[48], valueText[72];
        copy_description(key, keyText, sizeof keyText);
        copy_description(value, valueText, sizeof valueText);
        line("hierarchy=dictionary scope=%s item=%llu key=%.44s value=%.68s",
             scope, index, keyText, valueText);
    }
}

static void snapshot_layer_tree(const char *scope, unsigned windowIndex,
                                unsigned viewIndex, id layer, unsigned depth,
                                unsigned *budget)
{
    if (!layer || depth > 12 || !budget || *budget == 0) return;
    const uintptr_t address = (uintptr_t) layer;
    for (unsigned index = 0; index < depth; ++index) {
        if (gLayerTrail[index] == address) {
            line("hierarchy=layer scope=%s/%u view=%u depth=%u class=%s cycle=1",
                 scope, windowIndex, viewIndex, depth,
                 object_getClassName(layer));
            return;
        }
    }
    gLayerTrail[depth] = address;
    --*budget;
    const char *layerClass = object_getClassName(layer);
    id contents = read_object(layer, "contents");
    id sublayers = normalized_collection(read_object(layer, "sublayers"));
    unsigned long long count = collection_count(sublayers);
    line("hierarchy=layer scope=%s/%u view=%u depth=%u class=%s contents=%d sublayers=%llu",
         scope, windowIndex, viewIndex, depth, layerClass,
         contents ? 1 : 0, count);
    if (strstr(layerClass, "LayerHost")) {
        unsigned long long contextId = 0;
        const bool hasContextId = read_integer(layer, "contextId", &contextId);
        id context = read_object(layer, "context");
        line("hierarchy=host scope=%s/%u view=%u depth=%u class=%.32s contextId=0x%x hasContextId=%d context=%d class=%.24s",
             scope, windowIndex, viewIndex, depth, layerClass,
             (unsigned) contextId, hasContextId ? 1 : 0,
             context ? 1 : 0, class_name_or_nil(context));
        unsigned long long inheritsSecurity = 0;
        unsigned long long preservesFlip = 0;
        const bool hasInheritsSecurity = read_integer(
            layer, "inheritsSecurity", &inheritsSecurity);
        const bool hasPreservesFlip = read_integer(
            layer, "preservesFlip", &preservesFlip);
        line("hierarchy=hostprops scope=%s/%u inheritsSecurity=%llu hasInherits=%d preservesFlip=%llu hasPreservesFlip=%d",
             scope, windowIndex, inheritsSecurity,
             hasInheritsSecurity ? 1 : 0, preservesFlip,
             hasPreservesFlip ? 1 : 0);
        if (context && first_host_context((uint32_t) contextId)) {
            unsigned long long observedId = 0;
            unsigned long long observedDisplay = 0;
            unsigned long long observedMask = 0;
            unsigned long long valid = 0;
            unsigned long long frozen = 0;
            const bool hasObservedId = read_integer(context, "contextId", &observedId);
            const bool hasObservedDisplay = read_integer(context, "displayId", &observedDisplay);
            const bool hasObservedMask = read_integer(context, "displayMask", &observedMask);
            const bool hasValid = read_integer(context, "isValid", &valid);
            const bool hasFrozen = read_integer(context, "isFrozen", &frozen);
            id contextLayer = read_object(context, "layer");
            id renderContext = read_object(context, "renderContext");
            id options = read_object(context, "options");
            line("hierarchy=context scope=%s/%u host=0x%x id=0x%x hasId=%d display=0x%x hasDisplay=%d mask=0x%x hasMask=%d valid=%llu hasValid=%d frozen=%llu hasFrozen=%d",
                 scope, windowIndex, (unsigned) contextId,
                 (unsigned) observedId, hasObservedId ? 1 : 0,
                 (unsigned) observedDisplay, hasObservedDisplay ? 1 : 0,
                 (unsigned) observedMask, hasObservedMask ? 1 : 0,
                 valid, hasValid ? 1 : 0, frozen, hasFrozen ? 1 : 0);
            line("hierarchy=contextfields scope=%s/%u layer=%d class=%.28s renderContext=%d class=%.28s options=%d class=%.24s",
                 scope, windowIndex, contextLayer ? 1 : 0,
                 class_name_or_nil(contextLayer), renderContext ? 1 : 0,
                 class_name_or_nil(renderContext), options ? 1 : 0,
                 class_name_or_nil(options));
            snapshot_dictionary("contextoptions", options);
            snapshot_layer_tree("context", windowIndex, 0, contextLayer, 0,
                                &gLayerBudget);
        }
    }
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        snapshot_layer_tree(scope, windowIndex, viewIndex,
                            collection_object_at(sublayers, index),
                            depth + 1, budget);
    }
}

static const char *window_kind_for_layer(id layer)
{
    id current = layer;
    for (unsigned depth = 0; current && depth < 14; ++depth) {
        id delegate = read_object(current, "delegate");
        const char *name = class_name_or_nil(delegate);
        if (strstr(name, "RootSceneWindow")) return "root";
        if (strstr(name, "StatusBarWindow")) return "status";
        current = read_object(current, "superlayer");
    }
    return "-";
}

static unsigned window_kind_index(const char *kind)
{
    if (!strcmp(kind, "root")) return 0;
    if (!strcmp(kind, "status")) return 1;
    return 2;
}

static void log_layer_event(const char *event, const char *kind, id layer)
{
    unsigned long long hasCommitted = 0;
    const bool committed = read_integer(layer, "hasBeenCommitted", &hasCommitted);
    id contents = read_object(layer, "contents");
    id delegate = read_object(layer, "delegate");
    id superlayer = read_object(layer, "superlayer");
    id sublayers = normalized_collection(read_object(layer, "sublayers"));
    line("event=%s window=%s pid=%d layer=%p class=%s contents=%d class=%.24s delegate=%.24s super=%.24s sublayers=%llu committed=%llu hasCommitted=%d",
         event, kind, getpid(), (__bridge void *) layer, class_name_or_nil(layer),
         contents ? 1 : 0, class_name_or_nil(contents),
         class_name_or_nil(delegate), class_name_or_nil(superlayer),
         collection_count(sublayers), hasCommitted, committed ? 1 : 0);
}

static bool remember_context_event(uint32_t contextId)
{
    static uint32_t ids[8];
    static unsigned count;
    if (!contextId || count == sizeof ids / sizeof ids[0]) return false;
    for (unsigned index = 0; index < count; ++index)
        if (ids[index] == contextId) return false;
    ids[count++] = contextId;
    return true;
}

static IMP gLayerHostSetContextId;
static IMP gLayerHostDidBecomeVisible;
static IMP gContextSetLayer;
static IMP gContextRemoteWithOptions;
static IMP gLayerSetContents;
static IMP gLayerDidCommit;
static IMP gTransactionFlushAsRunLoopObserver;
static IMP gWindowSetHidden;
static IMP gWindowMakeKeyAndVisible;
static IMP gWindowSceneDidBecomeVisible;

static void trace_layer_host_context_id(id self, SEL selector, uint32_t contextId)
{
    ((void (*)(id, SEL, uint32_t)) gLayerHostSetContextId)(self, selector, contextId);
    if (gHostContextEventCount >= 16 || !remember_context_event(contextId)) return;
    ++gHostContextEventCount;
    id context = read_object(self, "context");
    unsigned long long contextObjectId = 0;
    const bool hasContextObjectId = read_integer(context, "contextId", &contextObjectId);
    line("event=ca_host_context_bind pid=%d layer=%p host=0x%x context=%d contextId=0x%x hasContextId=%d contextLayer=%.24s",
         getpid(), (__bridge void *) self, (unsigned) contextId, context ? 1 : 0,
         (unsigned) contextObjectId, hasContextObjectId ? 1 : 0,
         class_name_or_nil(read_object(context, "layer")));
    log_layer_event("ca_host_context_layer", window_kind_for_layer(self), self);
}

static void trace_layer_host_visible(id self, SEL selector, BOOL visible)
{
    ((void (*)(id, SEL, BOOL)) gLayerHostDidBecomeVisible)(
        self, selector, visible);
    unsigned long long contextId = 0;
    const bool hasContextId = read_integer(self, "contextId", &contextId);
    const char *kind = window_kind_for_layer(self);
    line("event=ca_host_visible pid=%d visible=%d layer=%p host=0x%x hasContextId=%d window=%s",
         getpid(), visible ? 1 : 0, (__bridge void *) self, (unsigned) contextId,
         hasContextId ? 1 : 0, kind);
    (void) visible;
}

static void trace_context_set_layer(id self, SEL selector, id layer)
{
    ((void (*)(id, SEL, id)) gContextSetLayer)(self, selector, layer);
    if (gContextLayerEventCount >= 16) return;
    ++gContextLayerEventCount;
    unsigned long long contextId = 0;
    const bool hasContextId = read_integer(self, "contextId", &contextId);
    line("event=ca_context_set_layer pid=%d context=%p contextId=0x%x hasContextId=%d layer=%.28s",
         getpid(), (__bridge void *) self, (unsigned) contextId, hasContextId ? 1 : 0,
         class_name_or_nil(layer));
    log_layer_event("ca_context_layer", window_kind_for_layer(layer), layer);
    if (layer) {
        census_once("set-layer");
    }
}

/* H654: record_created_context below reads the dictionary the context itself holds, and the
 * helper that describes it is defined further down this file, so declare it before use. */
static void describe_context_options(const char *source, id options);

/* H652: read the fields that decide the first frame, from the process that owns them.

 * displayId says which display this context points at, layer says whether anything is mounted on
 * it, and the layer contents and sublayer count say whether the desktop has actually put pixels
 * into it. All four are ordinary properties here, and none of them is reachable in backboardd,
 * where +[CAContext contextWithId:] returns nil for a foreign id. */
static void record_created_context(id context)
{
    static unsigned created, onDisplay, withLayer, withContents;
    unsigned long long contextId = 0;
    const bool hasId = read_integer(context, "contextId", &contextId);
    unsigned long long displayId = 0;
    const bool hasDisplay = read_integer(context, "displayId", &displayId);
    id layer = read_object(context, "layer");
    id contents = read_object(layer, "contents");
    unsigned long long subs = 0;
    read_integer(read_object(layer, "sublayers"), "count", &subs);

    ++created;
    if (hasDisplay && displayId == 1u) {
        ++onDisplay;
    }
    if (layer) {
        ++withLayer;
    }
    if (contents) {
        ++withContents;
    }

    /* H654: cross-check the criterion field.

     * H653 found the request asks for displayId 1 while -[CAContext displayId] reads back 0, and
     * said the two possible readings cannot be told apart. They can, using properties that are
     * already on this object. The request dictionary carries secure=1, displayId=1 and
     * displayable=1, and CAContext exposes -isSecure and -displayId but no displayable accessor.
     * So if -isSecure reports the requested 1 while -displayId reports 0, the properties do
     * mirror the request and displayId specifically was not applied. If -isSecure is 0 as well,
     * then these properties say nothing about the request at all and the criterion field is
     * wrong, which is the other reading.
     *
     * -[CAContext options] is also listed, so the dictionary the context itself holds is read
     * and described the same way as the one passed in, side by side. */
    unsigned long long secure = 0, ctxValid = 0;
    const bool hasSecure = read_integer(context, "isSecure", &secure);
    read_integer(context, "valid", &ctxValid);
    id ownOptions = read_object(context, "options");
    line("event=h654_mirror n=%u idval=0x%llx displayId=0x%llx secure=%d secureVal=%llu valid=%llu ownOptions=%d",
         created, contextId, displayId, hasSecure ? 1 : 0, secure, ctxValid,
         ownOptions ? 1 : 0);
    if (ownOptions) {
        describe_context_options("context", ownOptions);
    }

    line("event=h652_ctx n=%u id=%d idval=0x%llx display=%d displayId=0x%llx layer=%s contents=%s subs=%llu d1=%u lc=%u ct=%u",
         created, hasId ? 1 : 0, contextId, hasDisplay ? 1 : 0, displayId,
         class_name_or_nil(layer), class_name_or_nil(contents), subs,
         onDisplay, withLayer, withContents);

    if (hasId) {
        publish_desktop_context_summary(created, onDisplay, withLayer, withContents, contextId);
    }
}

/* H653: say what SpringBoard actually asked for.

 * H652 narrowed the desktop blocker to a context whose displayId is 0 while the display reports
 * 1, and whose layer is nil. The first thing to settle is whether that 0 came in through this
 * call, because +[CAContext remoteContextWithOptions:] takes exactly such a dictionary. The
 * existing line only printed the options class name, which cannot answer that.
 *
 * This reads the dictionary through plain public NSDictionary API, before the real method runs so
 * the values are the ones the caller passed rather than anything the implementation may have
 * changed. Values are described only when they are strings or numbers, so no unknown -description
 * implementation is invoked, and the entry count is capped. */

static void describe_context_options(const char *source, id options)
{
    static unsigned calls;
    if (calls >= 8) {
        return;
    }
    ++calls;
    if (!options) {
        line_reserved("event=h653_options src=%.8s idx=%u nil=1", source, calls - 1);
        return;
    }
    const SEL respondsSel = sel_getUid("respondsToSelector:");
    BOOL (*responds)(id, SEL, SEL) = (BOOL (*)(id, SEL, SEL)) objc_msgSend;
    if (!responds(options, respondsSel, sel_getUid("count"))) {
        line_reserved("event=h653_options src=%.8s idx=%u cls=%.24s no-count=1", source,
                      calls - 1, object_getClassName(options));
        return;
    }
    const unsigned long long n = ((unsigned long long (*)(id, SEL)) objc_msgSend)(
        options, sel_getUid("count"));
    id keys = nil;
    if (responds(options, respondsSel, sel_getUid("allKeys"))) {
        @try {
            keys = ((id (*)(id, SEL)) objc_msgSend)(options, sel_getUid("allKeys"));
        } @catch (id ignored) { keys = nil; }
    }
    line_reserved("event=h653_options src=%.8s idx=%u cls=%.24s entries=%llu keys=%d", source,
                  calls - 1, object_getClassName(options), n, keys ? 1 : 0);
    if (!keys) {
        return;
    }
    const unsigned long long kn = ((unsigned long long (*)(id, SEL)) objc_msgSend)(
        keys, sel_getUid("count"));
    for (unsigned long long i = 0; i < kn && i < 8; ++i) {
        id key = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
            keys, sel_getUid("objectAtIndex:"), i);
        id value = nil;
        if (responds(options, respondsSel, sel_getUid("objectForKey:"))) {
            @try {
                value = ((id (*)(id, SEL, id)) objc_msgSend)(
                    options, sel_getUid("objectForKey:"), key);
            } @catch (id ignored) { value = nil; }
        }
        BOOL (*isKind)(id, SEL, Class) = (BOOL (*)(id, SEL, Class)) objc_msgSend;
        const char * (*toUtf8)(id, SEL) = (const char * (*)(id, SEL)) objc_msgSend;
        const Class stringClass = [NSString class];
        const Class numberClass = [NSNumber class];

        char keyText[48] = "-";
        if (key && isKind(key, sel_getUid("isKindOfClass:"), stringClass)) {
            const char *s = toUtf8(key, sel_getUid("UTF8String"));
            snprintf(keyText, sizeof keyText, "%.40s", s ? s : "-");
        }

        const char *valueClass = value ? object_getClassName(value) : "-";
        char valueText[48] = "-";
        if (value && isKind(value, sel_getUid("isKindOfClass:"), stringClass)) {
            const char *s = toUtf8(value, sel_getUid("UTF8String"));
            snprintf(valueText, sizeof valueText, "s:%.30s", s ? s : "-");
        } else if (value && isKind(value, sel_getUid("isKindOfClass:"), numberClass)) {
            id desc = ((id (*)(id, SEL)) objc_msgSend)(value, sel_getUid("description"));
            const char *s = desc ? toUtf8(desc, sel_getUid("UTF8String")) : NULL;
            snprintf(valueText, sizeof valueText, "n:%.30s", s ? s : "-");
        } else if (value) {
            snprintf(valueText, sizeof valueText, "not-described");
        }
        line_reserved("event=h653_entry src=%.8s idx=%u i=%llu key=%.40s vcls=%.20s val=%.40s",
                      source, calls - 1, i, keyText, valueClass, valueText);
    }
}

static id trace_context_remote_with_options(id self, SEL selector, id options)
{
    describe_context_options("request", options);
    id context = ((id (*)(id, SEL, id)) gContextRemoteWithOptions)(
        self, selector, options);
    unsigned long long contextId = 0;
    const bool hasContextId = read_integer(context, "contextId", &contextId);
    id layer = read_object(context, "layer");
    census_once("remote-create");
    record_created_context(context);
    line("event=ca_context_remote_create pid=%d context=%p contextId=0x%x hasContextId=%d layer=%.24s options=%.24s",
         getpid(), (__bridge void *) context, (unsigned) contextId,
         hasContextId ? 1 : 0, class_name_or_nil(layer),
         class_name_or_nil(options));
    return context;
}

static void trace_layer_set_contents(id self, SEL selector, id contents)
{
    ((void (*)(id, SEL, id)) gLayerSetContents)(self, selector, contents);
    const char *kind = window_kind_for_layer(self);
    if (!strcmp(kind, "-")) return;
    if (gDidFinishReturned) {
        if (gPostDidFinishContentsEventCount >= 16) return;
        ++gPostDidFinishContentsEventCount;
    } else {
        if (gWindowContentsEventCount >= 12) return;
        ++gWindowContentsEventCount;
    }
    id resolved = read_object(self, "contents");
    line("event=ca_layer_set_contents window=%s pid=%d layer=%p class=%s input=%.24s contents=%d resolved=%.24s",
         kind, getpid(), (__bridge void *) self, class_name_or_nil(self),
         class_name_or_nil(contents), resolved ? 1 : 0,
         class_name_or_nil(resolved));
}

static void trace_layer_did_commit(id self, SEL selector, id layer)
{
    ((void (*)(id, SEL, id)) gLayerDidCommit)(self, selector, layer);
    const char *kind = window_kind_for_layer(self);
    const unsigned kindIndex = window_kind_index(kind);
    const bool target = kindIndex < 2;
    if (gDidFinishReturned) {
        if (gPostDidFinishCommitEventCount >= 16) return;
        ++gPostDidFinishCommitEventCount;
    } else {
        if (target && gWindowCommitCount[kindIndex] < 12)
            ++gWindowCommitCount[kindIndex];
        else if (!target && gLayerCommitEventCount >= 24)
            return;
        ++gLayerCommitEventCount;
    }
    log_layer_event("ca_layer_commit", kind, self);
}

/* H670: the public transaction entry points.
 *
 * The existing hook is on +[CATransaction flushAsRunLoopObserver], a private selector, so its
 * zero hits never proved that no transaction was flushed - only that this one path was not taken.
 * +flush and +commit are real selectors in this build, so both are hooked and counted here.
 * A local positive control calls +flush once right after installation: without it, a count of
 * zero would be indeterminate rather than evidence. */
static void trace_transaction_flush_public(id self, SEL selector)
{
    ++gTxFlushCount;
    ((void (*)(id, SEL)) gTransactionFlushPublicOriginal)(self, selector);
}

static void trace_transaction_commit_public(id self, SEL selector)
{
    ++gTxCommitCount;
    ((void (*)(id, SEL)) gTransactionCommitPublicOriginal)(self, selector);
}


static void trace_transaction_flush(id self, SEL selector)
{
    ((void (*)(id, SEL)) gTransactionFlushAsRunLoopObserver)(self, selector);
    if (gDidFinishReturned) {
        if (gPostDidFinishTransactionEventCount >= 16) return;
        ++gPostDidFinishTransactionEventCount;
        line("event=h556_post_transaction_flush pid=%d transaction=%p thread=%p main=%d contentsEvents=%u commitEvents=%u",
             getpid(), (__bridge void *) self, (void *) pthread_self(),
             pthread_main_np(), gPostDidFinishContentsEventCount,
             gPostDidFinishCommitEventCount);
    } else {
        if (gTransactionEventCount >= 12) return;
        ++gTransactionEventCount;
        line("event=ca_transaction_flush pid=%d transaction=%p thread=%p contexts=%u hostEvents=%u layerCommits=%u",
             getpid(), (__bridge void *) self, (void *) pthread_self(),
             gContextLayerEventCount, gHostContextEventCount,
             gLayerCommitEventCount);
    }
}

static void log_window_visibility(const char *event, id window, BOOL visible)
{
    if (gWindowVisibilityEventCount >= 16) return;
    ++gWindowVisibilityEventCount;
    unsigned long long hidden = 0;
    unsigned long long windowVisible = 0;
    const bool hasHidden = read_integer(window, "isHidden", &hidden);
    const bool hasVisible = read_integer(window, "_isVisible", &windowVisible);
    id layer = read_object(window, "layer");
    id windowScene = read_object(window, "windowScene");
    const char *kind = window_kind_for_layer(layer);
    line("event=%s window=%s pid=%d object=%p visible=%d hidden=%llu hasHidden=%d _isVisible=%llu hasVisible=%d layer=%.24s scene=%.24s",
         event, kind, getpid(), (__bridge void *) window,
         visible ? 1 : 0, hidden, hasHidden ? 1 : 0, windowVisible,
         hasVisible ? 1 : 0, class_name_or_nil(layer),
         class_name_or_nil(windowScene));
    if (layer) log_layer_event(event, kind, layer);
    (void) visible;
}

static void trace_window_set_hidden(id self, SEL selector,
                                    BOOL hidden, BOOL forced)
{
    ((void (*)(id, SEL, BOOL, BOOL)) gWindowSetHidden)(
        self, selector, hidden, forced);
    log_window_visibility("uiwindow_set_hidden", self, !hidden);
}

static void trace_window_make_key_visible(id self, SEL selector)
{
    ((void (*)(id, SEL)) gWindowMakeKeyAndVisible)(self, selector);
    log_window_visibility("uiwindow_make_key_visible", self, YES);
}

static void trace_window_scene_visible(id self, SEL selector, id window)
{
    ((void (*)(id, SEL, id)) gWindowSceneDidBecomeVisible)(
        self, selector, window);
    log_window_visibility("uiwindow_scene_visible", window, YES);
}

static void log_root_window_state(const char *phase) __attribute__((unused));
static void log_root_window_state(const char *phase)
{
    Class applicationClass = NSClassFromString(@"UIApplication");
    id application = applicationClass
        ? ((id (*)(id, SEL)) objc_msgSend)(
              (id) applicationClass, @selector(sharedApplication))
        : nil;
    id windows = normalized_collection(read_object(application, "windows"));
    const unsigned long long count = collection_count(windows);
    line("event=root_visibility_state phase=%s pid=%d windows=%llu scheduled=%d",
         phase, getpid(), count, gVisibilitySnapshotScheduled ? 1 : 0);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        id window = collection_object_at(windows, index);
        const char *name = class_name_or_nil(window);
        if (!strstr(name, "RootSceneWindow") &&
            !strstr(name, "StatusBarWindow")) continue;
        unsigned long long hidden = 0;
        unsigned long long visible = 0;
        const bool hasHidden = read_integer(window, "isHidden", &hidden);
        const bool hasVisible = read_integer(window, "_isVisible", &visible);
        id layer = read_object(window, "layer");
        id windowScene = read_object(window, "windowScene");
        unsigned long long activation = 0;
        const bool hasActivation = read_integer(
            windowScene, "activationState", &activation);
        line("event=root_visibility_window phase=%s window=%s object=%p hidden=%llu hasHidden=%d _isVisible=%llu hasVisible=%d layer=%.24s scene=%.24s activation=%llu hasActivation=%d",
             phase, name, (__bridge void *) window, hidden, hasHidden ? 1 : 0,
             visible, hasVisible ? 1 : 0, class_name_or_nil(layer),
             class_name_or_nil(windowScene), activation,
             hasActivation ? 1 : 0);
        id contents = read_object(layer, "contents");
        unsigned long long hostContextId = 0;
        const bool hasHostContextId = read_integer(
            layer, "contextId", &hostContextId);
        line("event=root_visibility_layer phase=%s window=%s layer=%p class=%.28s contents=%d contentsClass=%.20s contextId=0x%x hasContextId=%d",
             phase, name, (__bridge void *) layer, class_name_or_nil(layer),
             contents ? 1 : 0, class_name_or_nil(contents),
             (unsigned) hostContextId, hasHostContextId ? 1 : 0);
    }
}

static void log_application_scene_state(const char *phase)
{
    Class applicationClass = NSClassFromString(@"UIApplication");
    id application = applicationClass
        ? ((id (*)(id, SEL)) objc_msgSend)(
              (id) applicationClass, @selector(sharedApplication))
        : nil;
    id windows = normalized_collection(read_object(application, "windows"));
    id scenes = normalized_collection(read_object(application, "connectedScenes"));
    const unsigned long long windowCount = collection_count(windows);
    const unsigned long long sceneCount = collection_count(scenes);
    line("event=h541_application_state phase=%s pid=%d app=%d windows=%llu scenes=%llu",
         phase, getpid(), application ? 1 : 0, windowCount, sceneCount);

    for (unsigned long long index = 0; index < windowCount && index < 8; ++index) {
        id window = collection_object_at(windows, index);
        unsigned long long hidden = 0;
        unsigned long long visible = 0;
        const bool hasHidden = read_integer(window, "isHidden", &hidden);
        const bool hasVisible = read_integer(window, "_isVisible", &visible);
        id layer = read_object(window, "layer");
        id windowScene = read_object(window, "windowScene");
        unsigned long long activation = 0;
        const bool hasActivation = read_integer(
            windowScene, "activationState", &activation);
        line("event=h541_window phase=%s index=%llu class=%.40s hidden=%llu hasHidden=%d visible=%llu hasVisible=%d layer=%.24s scene=%.28s activation=%llu hasActivation=%d",
             phase, index, class_name_or_nil(window), hidden, hasHidden ? 1 : 0,
             visible, hasVisible ? 1 : 0, class_name_or_nil(layer),
             class_name_or_nil(windowScene), activation,
             hasActivation ? 1 : 0);
        id contents = read_object(layer, "contents");
        unsigned long long hostContextId = 0;
        const bool hasHostContextId = read_integer(
            layer, "contextId", &hostContextId);
        line("event=h541_window_layer phase=%s index=%llu layer=%p class=%.28s contents=%d contentsClass=%.20s contextId=0x%x hasContextId=%d",
             phase, index, (__bridge void *) layer, class_name_or_nil(layer),
             contents ? 1 : 0, class_name_or_nil(contents),
             (unsigned) hostContextId, hasHostContextId ? 1 : 0);
    }

    for (unsigned long long index = 0; index < sceneCount && index < 8; ++index) {
        id scene = collection_object_at(scenes, index);
        unsigned long long activation = 0;
        const bool hasActivation = read_integer(
            scene, "activationState", &activation);
        id delegate = read_object(scene, "delegate");
        char identifier[48];
        copy_utf8(read_object(scene, "identifier"), identifier, sizeof identifier);
        line("event=h541_scene phase=%s index=%llu class=%.32s id=%.44s activation=%llu hasActivation=%d delegate=%.32s",
             phase, index, class_name_or_nil(scene), identifier, activation,
             hasActivation ? 1 : 0, class_name_or_nil(delegate));
    }
    log_root_window_state(phase);
}

static void schedule_application_scene_probe(unsigned tick)
{
    if (tick == 0) {
        if (gApplicationSceneProbeStarted) return;
        gApplicationSceneProbeStarted = true;
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            line("event=h541_application_probe tick=%u pid=%d thread=%p main=%d",
                 tick, getpid(), (void *) pthread_self(), pthread_main_np());
            if (tick == 0) {
                log_application_scene_state("h541_first");
            } else if (tick == 5 || tick == 10 || tick == 20) {
                char phase[24];
                snprintf(phase, sizeof phase, "h541_tick_%u", tick);
                log_application_scene_state(phase);
            }
            if (tick < 20) schedule_application_scene_probe(tick + 1);
        });
}

static bool install_instance_hook(Class cls, const char *name,
                                  IMP replacement, IMP *original)
{
    if (!cls || !original) return false;
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) return false;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return true;
}

static bool install_class_hook(Class cls, const char *name,
                               IMP replacement, IMP *original)
{
    if (!cls || !original) return false;
    Method method = class_getClassMethod(cls, sel_registerName(name));
    if (!method) return false;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return true;
}

static void install_ca_event_hooks(void)
{
    Class layerHost = NSClassFromString(@"CALayerHost");
    Class context = NSClassFromString(@"CAContext");
    Class layer = NSClassFromString(@"CALayer");
    Class transaction = NSClassFromString(@"CATransaction");
    Class window = NSClassFromString(@"UIWindow");
    Class windowScene = NSClassFromString(@"UIWindowScene");
    Class applicationClass = NSClassFromString(@"UIApplication");
    const bool hostId = install_instance_hook(
        layerHost, "setContextId:", (IMP) trace_layer_host_context_id,
        &gLayerHostSetContextId);
    const bool hostVisible = install_instance_hook(
        layerHost, "layerDidBecomeVisible:", (IMP) trace_layer_host_visible,
        &gLayerHostDidBecomeVisible);
    const bool contextLayer = install_instance_hook(
        context, "setLayer:", (IMP) trace_context_set_layer, &gContextSetLayer);
    const bool contextRemote = install_class_hook(
        context, "remoteContextWithOptions:",
        (IMP) trace_context_remote_with_options, &gContextRemoteWithOptions);
    const bool contents = install_instance_hook(
        layer, "setContents:", (IMP) trace_layer_set_contents, &gLayerSetContents);
    const bool commit = install_instance_hook(
        layer, "_didCommitLayer:", (IMP) trace_layer_did_commit, &gLayerDidCommit);
    const bool flush = install_class_hook(
        transaction, "flushAsRunLoopObserver",
        (IMP) trace_transaction_flush, &gTransactionFlushAsRunLoopObserver);
    /* H670: the public entries, plus the local positive control described above. */
    const bool flushPublic = install_class_hook(
        transaction, "flush", (IMP) trace_transaction_flush_public,
        &gTransactionFlushPublicOriginal);
    const bool commitPublic = install_class_hook(
        transaction, "commit", (IMP) trace_transaction_commit_public,
        &gTransactionCommitPublicOriginal);
    line_reserved("event=h670_tx_hooks flush_public=%d commit_public=%d loopback=%d control=%d", flushPublic ? 1 : 0, commitPublic ? 1 : 0, (flushPublic && transaction) ? 1 : 0, gTxControlHit);
    if (flushPublic && transaction) {
        ((void (*)(id, SEL)) objc_msgSend)((id)transaction, sel_registerName("flush"));
        gTxControlHit = gTxFlushCount > 0 ? 1 : 0;
        line_reserved("event=h670_tx_control flushes=%u control=%d", gTxFlushCount, gTxControlHit);
    }
    const bool windowHidden = install_instance_hook(
        window, "_setHidden:forced:", (IMP) trace_window_set_hidden,
        &gWindowSetHidden);
    const bool windowMakeVisible = install_instance_hook(
        window, "makeKeyAndVisible", (IMP) trace_window_make_key_visible,
        &gWindowMakeKeyAndVisible);
    const bool windowSceneVisible = install_instance_hook(
        windowScene, "_delegate_windowDidBecomeVisible:",
        (IMP) trace_window_scene_visible, &gWindowSceneDidBecomeVisible);
    const bool applicationShared = install_class_hook(
        applicationClass, "sharedApplication",
        (IMP) trace_application_shared_application,
        &gApplicationSharedApplication);
    Class springboard = NSClassFromString(@"SpringBoard");
    const bool springboardStatusServerSkipped = install_instance_hook(
        springboard, "_startSystemStatusServerAndFriends",
        (IMP) trace_springboard_start_system_status_server,
        &gSpringBoardStartSystemStatusServer);
    const bool springboardDidFinish = install_instance_hook(
        springboard, "applicationDidFinishLaunching:",
        (IMP) trace_springboard_application_did_finish,
        &gSpringBoardApplicationDidFinishLaunching);
    Class profileConnection = NSClassFromString(@"MCProfileConnection");
    const bool mcWaitForMigrationSkipped = install_instance_hook(
        profileConnection,
        "waitForMigrationIncludingPostRestoreMigration:waitUntilCompleted:completion:",
        (IMP) trace_mc_wait_for_migration,
        &gMCProfileConnectionWaitForMigration);
    const bool mcShouldShowCloudConfigurationUISkipped = install_instance_hook(
        profileConnection, "shouldShowCloudConfigurationUI",
        (IMP) trace_mc_should_show_cloud_configuration_ui,
        &gMCProfileConnectionShouldShowCloudConfigurationUI);
    Class setupManager = NSClassFromString(@"SBSetupManager");
    const bool setupManagerInitObserved = install_instance_hook(
        setupManager, "init", (IMP) trace_springboard_setup_manager_init,
        &gSpringBoardSetupManagerInitOriginal);
    const bool setupHUDObserved = install_instance_hook(
        springboard, "_setUpHUDControllerAndFriends",
        (IMP) trace_springboard_setup_hud, &gSpringBoardSetupHUDOriginal);
    Class soundController = NSClassFromString(@"SBSoundController");
    const bool soundSharedObserved = install_class_hook(
        soundController, "sharedInstance",
        (IMP) trace_sound_controller_shared_instance,
        &gSoundControllerSharedInstanceOriginal);
    const bool soundInitObserved = install_instance_hook(
        soundController, "init", (IMP) trace_sound_controller_init,
        &gSoundControllerInitOriginal);
    Class ringerControl = NSClassFromString(@"SBRingerControl");
    const bool ringerInitObserved = install_instance_hook(
        ringerControl, "initWithBannerManager:soundController:",
        (IMP) trace_ringer_control_init, &gRingerControlInitOriginal);
    Class statusDataChangeLog = NSClassFromString(@"STStatusDomainDataChangeLog");
    const bool statusDataLogObserved = install_instance_hook(
        statusDataChangeLog, "initWithRecordKeys:",
        (IMP) trace_status_domain_data_change_log_init,
        &gStatusDomainDataChangeLogInitOriginal);
    Class telephonyManager = NSClassFromString(@"SBTelephonyManager");
    const bool telephonySharedObserved = install_class_hook(
        telephonyManager, "sharedTelephonyManager",
        (IMP) trace_telephony_manager_shared,
        &gTelephonyManagerSharedOriginal);
    const bool telephonySharedCreatingObserved = install_class_hook(
        telephonyManager, "sharedTelephonyManagerCreatingIfNecessary:",
        (IMP) trace_telephony_manager_shared_creating,
        &gTelephonyManagerSharedCreatingOriginal);
    const bool telephonyInitObserved = install_instance_hook(
        telephonyManager, "init", (IMP) trace_telephony_manager_init,
        &gTelephonyManagerInitOriginal);
    Class applicationController = NSClassFromString(@"SBApplicationController");
    const bool applicationControllerInitObserved = install_instance_hook(
        applicationController, "init", (IMP) trace_application_controller_init,
        &gApplicationControllerInitOriginal);
    Class applicationLibrary = NSClassFromString(@"FBSApplicationLibrary");
    const bool installedApplicationObserved = install_instance_hook(
        applicationLibrary, "installedApplicationWithBundleIdentifier:",
        (IMP) trace_application_library_installed_application,
        &gApplicationLibraryInstalledApplicationOriginal);
    const bool installedApplicationsObserved = install_instance_hook(
        applicationLibrary, "installedApplicationsForBundleIdentifier:",
        (IMP) trace_application_library_installed_applications,
        &gApplicationLibraryInstalledApplicationsOriginal);
    const bool allInstalledApplicationsObserved = install_instance_hook(
        applicationLibrary, "allInstalledApplications",
        (IMP) trace_application_library_all_installed_applications,
        &gApplicationLibraryAllInstalledApplicationsOriginal);
    const bool mutableSetNilRemovalIgnored = install_instance_hook(
        NSClassFromString(@"NSMutableSet"), "removeObject:",
        (IMP) trace_mutable_set_remove_object, &gMutableSetRemoveObjectOriginal);
    const bool concreteMutableSetNilRemovalIgnored = install_instance_hook(
        NSClassFromString(@"__NSSetM"), "removeObject:",
        (IMP) trace_concrete_mutable_set_remove_object,
        &gConcreteMutableSetRemoveObjectOriginal);
    line("h550_hud_hooks pid=%d setupHUD=%d soundShared=%d soundInit=%d ringerInit=%d",
         getpid(), setupHUDObserved ? 1 : 0, soundSharedObserved ? 1 : 0,
         soundInitObserved ? 1 : 0, ringerInitObserved ? 1 : 0);
    line("h551_status_hooks pid=%d statusDataLog=%d", getpid(),
         statusDataLogObserved ? 1 : 0);
    line("h552_telephony_hooks pid=%d shared=%d creating=%d init=%d",
         getpid(), telephonySharedObserved ? 1 : 0,
         telephonySharedCreatingObserved ? 1 : 0,
         telephonyInitObserved ? 1 : 0);
    line("h553_application_hooks pid=%d controllerInit=%d installedApp=%d installedApps=%d allInstalled=%d",
         getpid(), applicationControllerInitObserved ? 1 : 0,
         installedApplicationObserved ? 1 : 0,
         installedApplicationsObserved ? 1 : 0,
         allInstalledApplicationsObserved ? 1 : 0);
    line("h554_mutable_set_remove_guard pid=%d installed=%d", getpid(),
         mutableSetNilRemovalIgnored ? 1 : 0);
    line("h555_concrete_set_remove_guard pid=%d installed=%d", getpid(),
         concreteMutableSetNilRemovalIgnored ? 1 : 0);
    line("ca_event_hooks pid=%d hostId=%d hostVisible=%d contextLayer=%d contextRemote=%d contents=%d commit=%d flush=%d windowHidden=%d windowMakeVisible=%d windowSceneVisible=%d applicationShared=%d springboardStatusServerObserved=%d springboardDidFinish=%d mcWaitForMigrationSkipped=%d mcShouldShowCloudConfigurationUISkipped=%d setupManagerInitObserved=%d",
         getpid(), hostId ? 1 : 0, hostVisible ? 1 : 0, contextLayer ? 1 : 0,
         contextRemote ? 1 : 0, contents ? 1 : 0, commit ? 1 : 0,
         flush ? 1 : 0, windowHidden ? 1 : 0, windowMakeVisible ? 1 : 0,
         windowSceneVisible ? 1 : 0, applicationShared ? 1 : 0,
         springboardStatusServerSkipped ? 1 : 0, springboardDidFinish ? 1 : 0,
         mcWaitForMigrationSkipped ? 1 : 0,
         mcShouldShowCloudConfigurationUISkipped ? 1 : 0,
         setupManagerInitObserved ? 1 : 0);
}

static void install_h557_startup_hooks(void)
{
    Class chronoServicesClass = NSClassFromString(@"CHSChronoServicesConnection");
    const bool completeStartup = install_instance_hook(
        NSClassFromString(@"SpringBoard"),
        "_completeStartupAfterMainSceneConnect:",
        (IMP) trace_springboard_complete_startup,
        &gSpringBoardCompleteStartupOriginal);
    const bool uiControllerShared = install_class_hook(
        NSClassFromString(@"SBUIController"), "sharedInstance",
        (IMP) trace_springboard_ui_controller_shared,
        &gSpringBoardUIControllerSharedOriginal);
    const bool iconControllerInit = install_instance_hook(
        NSClassFromString(@"SBIconController"),
        "initWithMainDisplayWindowScene:",
        (IMP) trace_springboard_icon_controller_init,
        &gSpringBoardIconControllerInitOriginal);
    const bool chronoSubscribe = install_instance_hook(
        chronoServicesClass,
        "_subscribeToExtensions",
        (IMP) trace_chrono_services_subscribe,
        &gChronoServicesSubscribeOriginal);
    const bool chronoAssertion = chronoServicesClass &&
        class_addMethod(chronoServicesClass, sel_registerName("assertion"),
                        (IMP) trace_chrono_assertion, "@@:");
    const bool applicationRun = install_instance_hook(
        NSClassFromString(@"UIApplication"), "_run",
        (IMP) trace_application_run, &gApplicationRunOriginal);
    Class bsServiceProxy = NSClassFromString(@"BSXPCServiceConnectionProxy");
    const bool bsProxyCreateObserved = install_class_hook(
        bsServiceProxy, "createImplementationOfProtocol:forClass:withName:",
        (IMP) trace_bsservice_proxy_create, &gBSServiceProxyCreateOriginal);
    Class bsMessage = NSClassFromString(@"BSXPCServiceConnectionMessage");
    const bool bsSendObserved = install_instance_hook(
        bsMessage, "sendSynchronouslyWithError:",
        (IMP) trace_bsxpc_message_send_synchronously,
        &gBSXPCServiceMessageSendSynchronouslyOriginal);
    Class activityCenter = NSClassFromString(@"ACActivityCenter");
    const bool activityCenterInitObserved = install_instance_hook(
        activityCenter, "init", (IMP) trace_ac_activity_center_init,
        &gACActivityCenterInitOriginal);
    const bool activityDescriptorsObserved = install_instance_hook(
        activityCenter, "observeDescriptorsWithHandler:",
        (IMP) trace_ac_activity_center_observe_descriptors,
        &gACActivityCenterObserveDescriptorsOriginal);
    const bool activityContentUpdatesObserved = install_instance_hook(
        activityCenter, "observeContentUpdatesWithHandler:",
        (IMP) trace_ac_activity_center_observe_content_updates,
        &gACActivityCenterObserveContentUpdatesOriginal);
    const bool activityReducedPushBudgetObserved = install_instance_hook(
        activityCenter, "observeActivitiesExceedingReducedPushBudgetWithHandler:",
        (IMP) trace_ac_activity_center_observe_reduced_push_budget,
        &gACActivityCenterObserveReducedPushBudgetOriginal);
    const bool activityIsActiveObserved = install_instance_hook(
        activityCenter, "isActivityActive:",
        (IMP) trace_ac_activity_center_is_activity_active,
        &gACActivityCenterIsActivityActiveOriginal);
    const bool activitiesEnabledObserved = install_instance_hook(
        activityCenter, "areActivitiesEnabled",
        (IMP) trace_ac_activity_center_are_activities_enabled,
        &gACActivityCenterAreActivitiesEnabledOriginal);
    Class activityAuthorization = NSClassFromString(@"ACActivityAuthorization");
    const bool activityAuthorizationInitObserved = install_instance_hook(
        activityAuthorization, "init",
        (IMP) trace_ac_activity_authorization_init,
        &gACActivityAuthorizationInitOriginal);
    const bool folderNameLocalizationObserved = install_instance_hook(
        NSClassFromString(@"SBHIconManager"),
        "localizedFolderNameForDefaultDisplayName:",
        (IMP) trace_sbhiconmanager_localized_folder_name,
        &gSBHIconManagerLocalizedFolderNameOriginal);
    const bool defaultWidgetIntentObserved = install_instance_hook(
        NSClassFromString(@"SBHIconManager"),
        "_loadAndSaveDefaultIntentIfNecessaryForWidget:ofIcon:viewController:",
        (IMP) trace_sbhiconmanager_default_widget_intent,
        &gSBHIconManagerDefaultWidgetIntentOriginal);
    const bool iconStateSaveObserved = install_instance_hook(
        NSClassFromString(@"SBHIconModel"),
        "saveIconStateIfNeeded",
        (IMP) trace_sbhiconmodel_save_icon_state,
        &gSBHIconModelSaveStateOriginal);
    const bool todayLayoutPrepareObserved = install_instance_hook(
        NSClassFromString(@"SBIconController"),
        "_prepareDefaultTodayLayoutIfNecessary",
        (IMP) trace_sbiconcontroller_prepare_today,
        &gSBIconControllerPrepareTodayOriginal);
    line("h557_startup_hooks pid=%d complete=%d uiShared=%d iconInit=%d chronoSubscribe=%d appRun=%d",
         getpid(), completeStartup ? 1 : 0, uiControllerShared ? 1 : 0,
         iconControllerInit ? 1 : 0, chronoSubscribe ? 1 : 0,
         applicationRun ? 1 : 0);
    line("event=h579_chrono_assertion_stub_installed pid=%d class=%d added=%d",
         getpid(), chronoServicesClass ? 1 : 0, chronoAssertion ? 1 : 0);
    line("event=h585_activity_hooks pid=%d bsProxy=%d bsSend=%d centerInit=%d descriptors=%d content=%d budget=%d active=%d enabled=%d authInit=%d",
         getpid(), bsProxyCreateObserved ? 1 : 0, bsSendObserved ? 1 : 0,
         activityCenterInitObserved ? 1 : 0, activityDescriptorsObserved ? 1 : 0,
         activityContentUpdatesObserved ? 1 : 0,
         activityReducedPushBudgetObserved ? 1 : 0,
         activityIsActiveObserved ? 1 : 0, activitiesEnabledObserved ? 1 : 0,
         activityAuthorizationInitObserved ? 1 : 0);
    line("event=h588_folder_name_localization_hook pid=%d installed=%d",
         getpid(), folderNameLocalizationObserved ? 1 : 0);
    line("event=h589_default_widget_intent_hook pid=%d installed=%d",
         getpid(), defaultWidgetIntentObserved ? 1 : 0);
    line("event=h590_icon_state_save_hook pid=%d installed=%d",
         getpid(), iconStateSaveObserved ? 1 : 0);
    line("event=h591_today_layout_prepare_hook pid=%d installed=%d",
         getpid(), todayLayoutPrepareObserved ? 1 : 0);
}

static void install_application_notifications(void)
{
    if (gDidFinishLaunchingObserver) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    gDidFinishLaunchingObserver = [center
        addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification * __unused notification) {
        gObservedApplication = notification.object;
        line("event=h515_application_notification name=did_finish_launching pid=%d thread=%p main=%d app=%p",
             getpid(), (void *) pthread_self(), pthread_main_np(),
             (__bridge void *) notification.object);
    }];
    gWillEnterForegroundObserver = [center
        addObserverForName:@"UIApplicationWillEnterForegroundNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification * __unused notification) {
        line("event=h515_application_notification name=will_enter_foreground pid=%d thread=%p main=%d",
             getpid(), (void *) pthread_self(), pthread_main_np());
    }];
    gDidBecomeActiveObserver = [center
        addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification * __unused notification) {
        line("event=h515_application_notification name=did_become_active pid=%d thread=%p main=%d",
             getpid(), (void *) pthread_self(), pthread_main_np());
    }];
}

static void snapshot_view_tree(const char *scope, unsigned windowIndex,
                               unsigned *viewIndex, id view, unsigned depth,
                               unsigned *viewBudget, unsigned *layerBudget)
{
    if (!view || depth > 6 || !viewBudget || *viewBudget == 0) return;
    --*viewBudget;
    const unsigned currentView = (*viewIndex)++;
    unsigned long long hidden = 0;
    const bool hasHidden = read_integer(view, "isHidden", &hidden);
    id layer = read_object(view, "layer");
    id subviews = normalized_collection(read_object(view, "subviews"));
    unsigned long long count = collection_count(subviews);
    line("hierarchy=view scope=%s/%u view=%u depth=%u class=%s hidden=%llu hasHidden=%d layer=%d class=%s subviews=%llu",
         scope, windowIndex, currentView, depth, class_name_or_nil(view),
         hidden, hasHidden, layer ? 1 : 0, class_name_or_nil(layer), count);
    snapshot_layer_tree(scope, windowIndex, currentView, layer, depth, layerBudget);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        snapshot_view_tree(scope, windowIndex, viewIndex,
                           collection_object_at(subviews, index), depth + 1,
                           viewBudget, layerBudget);
    }
}

static void snapshot_window_views(const char *scope, unsigned windowIndex,
                                  id window, id rootViewController)
{
    if (!gViewBudget || !gLayerBudget) return;

    unsigned viewIndex = 0;
    id rootView = read_object(rootViewController, "view");
    id windowSubviews = normalized_collection(read_object(window, "subviews"));
    unsigned long long subviewCount = collection_count(windowSubviews);
    line("hierarchy=window scope=%s/%u rootVCView=%d class=%s subviews=%llu remainingView=%u remainingLayer=%u",
         scope, windowIndex, rootView ? 1 : 0, class_name_or_nil(rootView),
         subviewCount, gViewBudget, gLayerBudget);

    if (rootView) {
        snapshot_view_tree(scope, windowIndex, &viewIndex, rootView, 0,
                           &gViewBudget, &gLayerBudget);
    } else {
        for (unsigned long long index = 0; index < subviewCount && index < 8; ++index) {
            snapshot_view_tree(scope, windowIndex, &viewIndex,
                               collection_object_at(windowSubviews, index), 0,
                               &gViewBudget, &gLayerBudget);
        }
    }

    id windowLayer = read_object(window, "layer");
    snapshot_layer_tree(scope, windowIndex, viewIndex, windowLayer, 0,
                        &gLayerBudget);
}

static void snapshot_window(const char *scope, unsigned index, id window,
                            unsigned sample)
{
    unsigned long long hidden = 0;
    unsigned long long level = 0;
    const bool hasHidden = read_integer(window, "isHidden", &hidden);
    const bool hasLevel = read_integer(window, "windowLevel", &level);
    id layer = read_object(window, "layer");
    id rootViewController = read_object(window, "rootViewController");
    id windowScene = read_object(window, "windowScene");
    line("window=%s/%u class=%s hidden=%llu hasHidden=%d level=%llu hasLevel=%d",
         scope, index, class_name_or_nil(window), hidden, hasHidden, level, hasLevel);
    line("window=%s/%u layer=%d class=%s rootVC=%d class=%s windowScene=%d",
         scope, index, layer ? 1 : 0, class_name_or_nil(layer),
         rootViewController ? 1 : 0, class_name_or_nil(rootViewController),
         windowScene ? 1 : 0);
    if (windowScene) {
        unsigned long long activation = 0;
        unsigned long long orientation = 0;
        const bool hasActivation = read_integer(
            windowScene, "activationState", &activation);
        const bool hasOrientation = read_integer(
            windowScene, "interfaceOrientation", &orientation);
        line("window=%s/%u sceneClass=%s activationState=%llu hasActivation=%d interfaceOrientation=%llu hasOrientation=%d",
             scope, index, class_name_or_nil(windowScene), activation,
             hasActivation ? 1 : 0, orientation, hasOrientation ? 1 : 0);
    }
    if (layer) log_object_field("window", index, layer, "contents");
    if (sample == 4 || sample == 5 || sample == 6)
        snapshot_window_views(scope, index, window, rootViewController);
}

static void snapshot_windows(const char *scope, id owner, unsigned sample)
{
    id windows = normalized_collection(read_object(owner, "windows"));
    if (!windows) windows = normalized_collection(read_object(owner, "_windows"));
    if (!windows) {
        line("windows=%s present=0", scope);
        return;
    }
    unsigned long long count = 0;
    if ([windows respondsToSelector:@selector(count)])
        count = ((unsigned long long (*)(id, SEL)) objc_msgSend)(windows, @selector(count));
    line("windows=%s present=1 class=%s count=%llu",
         scope, class_name_or_nil(windows), count);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        id window = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
            windows, @selector(objectAtIndex:), index);
        if (window) snapshot_window(scope, (unsigned) index, window, sample);
    }
}

static void h557_capture_post_run_state(const char *phase)
{
    Class applicationClass = NSClassFromString(@"UIApplication");
    id application = applicationClass
        ? ((id (*)(id, SEL)) objc_msgSend)(
              (id) applicationClass, @selector(sharedApplication))
        : nil;
    line("event=h557_post_run_snapshot phase=%s pid=%d main=%d app=%d",
         phase, getpid(), pthread_main_np(), application ? 1 : 0);
    gViewBudget = 48;
    gLayerBudget = 160;
    gHostContextCount = 0;
    snapshot_windows(phase, application, 5);
    log_application_scene_state(phase);
}

static void schedule_h557_post_run_snapshot(void)
{
    if (gH557PostRunSnapshotScheduled) return;
    gH557PostRunSnapshotScheduled = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1LL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        h557_capture_post_run_state("h557_ui_run_plus_1");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        h557_capture_post_run_state("h557_ui_run_plus_30");
    });
}

static void snapshot(const char *phase, unsigned sample)
{
    line("event=h513_snapshot_enter sample=%u phase=%s pid=%d pre_dlopen=1",
         sample, phase, getpid());
    line("ls_installer sample=%u state=0x%x",
         sample, h539_installer_state());
    void *frontBoard = dlopen(
        "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        RTLD_NOW);
    line("event=h513_dlopen name=FrontBoardServices sample=%u ok=%d", sample,
         frontBoard ? 1 : 0);
    void *quartzCore = dlopen(
        "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    line("event=h513_dlopen name=QuartzCore sample=%u ok=%d", sample,
         quartzCore ? 1 : 0);

    Class workspaceClass = NSClassFromString(@"FBSWorkspace");
    Class sceneClass = NSClassFromString(@"FBScene");
    if (sample == 0) {
        inventory_springboard_classes();
        probe_nonblocking_shared_instances();
    }
    if (sample == 4 || sample == 5 || sample == 6) {
        gViewBudget = 96;
        gLayerBudget = 240;
        gHostContextCount = 0;
    }
    line("sample=%u phase=%s pid=%d workspaceClass=%d sceneClass=%d",
         sample, phase, getpid(), workspaceClass ? 1 : 0, sceneClass ? 1 : 0);

    id workspace = nil;
    @try {
        if (workspaceClass) {
            SEL existing = NSSelectorFromString(@"_sharedWorkspaceIfExists");
            if ([(id) workspaceClass respondsToSelector:existing])
                workspace = ((id (*)(id, SEL)) objc_msgSend)((id) workspaceClass, existing);
            if (!workspace) {
                SEL shared = NSSelectorFromString(@"sharedWorkspace");
                if ([(id) workspaceClass respondsToSelector:shared])
                    workspace = ((id (*)(id, SEL)) objc_msgSend)((id) workspaceClass, shared);
            }
        }
    } @catch (id ignored) {
        workspace = nil;
    }

    line("sample=%u workspace=%d class=%s", sample, workspace ? 1 : 0,
         class_name_or_nil(workspace));

    id scenes = normalized_collection(read_object(workspace, "scenes"));
    unsigned long long count = 0;
    if (scenes && [scenes respondsToSelector:@selector(count)])
        count = ((unsigned long long (*)(id, SEL)) objc_msgSend)(scenes, @selector(count));
    line("sample=%u scenes=%llu class=%s", sample, count, class_name_or_nil(scenes));

    for (unsigned long long i = 0; scenes && i < count && i < 8; ++i) {
        id scene = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
            scenes, @selector(objectAtIndex:), i);
        if (!scene) continue;
        char identifier[72];
        copy_utf8(read_object(scene, "identifier"), identifier, sizeof identifier);
        unsigned long long valid = 0;
        unsigned long long state = 0;
        const bool hasValid = read_integer(scene, "isValid", &valid);
        const bool hasState = read_integer(scene, "activationState", &state);
        line("scene=%u class=%s id=%.64s valid=%d hasValid=%d state=%llu hasState=%d",
             (unsigned) i, class_name_or_nil(scene), identifier,
             valid ? 1 : 0, hasValid ? 1 : 0, state, hasState ? 1 : 0);
        static const char *fields[] = {
            "context", "layer", "layerManager", "definition", "settings",
            "clientSettings", "uiSettings", "hostProcess", "workspace", "delegate"
        };
        for (unsigned f = 0; f < sizeof fields / sizeof fields[0]; ++f)
            log_object_field("scene", (unsigned) i, scene, fields[f]);
        id settings = read_object(scene, "settings");
        if (settings) {
            unsigned long long foreground = 0;
            unsigned long long orientation = 0;
            unsigned long long deactivation = 0;
            const bool hasForeground = read_integer(
                settings, "isForeground", &foreground);
            const bool hasOrientation = read_integer(
                settings, "interfaceOrientation", &orientation);
            const bool hasDeactivation = read_integer(
                settings, "deactivationReasons", &deactivation);
            line("scene=%u settings class=%s foreground=%llu hasForeground=%d orientation=%llu hasOrientation=%d deactivation=0x%llx hasDeactivation=%d",
                 (unsigned) i, class_name_or_nil(settings), foreground,
                 hasForeground ? 1 : 0, orientation, hasOrientation ? 1 : 0,
                 deactivation, hasDeactivation ? 1 : 0);
        }
        id delegate = read_object(scene, "delegate");
        if (delegate) {
            line("scene=%u delegateClass=%s", (unsigned) i,
                 class_name_or_nil(delegate));
            snapshot_windows("scene", delegate, sample);
        }
    }

    Class displayClass = NSClassFromString(@"CADisplay");
    id displays = displayClass ? read_object((id) displayClass, "displays") : nil;
    unsigned long long displayCount = 0;
    if (displays)
        displayCount = ((unsigned long long (*)(id, SEL)) objc_msgSend)(displays,
                                                                       @selector(count));
    id mainDisplay = displayClass ? read_object((id) displayClass, "mainDisplay") : nil;
    line("sample=%u cadisplay=%d list=%llu main=%d", sample, displayClass ? 1 : 0,
         displayCount, mainDisplay ? 1 : 0);

    id application = gObservedApplication;
    id delegate = read_object(application, "delegate");
    id connected = normalized_collection(read_object(application, "connectedScenes"));
    id windows = normalized_collection(read_object(application, "windows"));
    unsigned long long connectedCount = connected
        ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(connected, @selector(count)) : 0;
    unsigned long long windowCount = windows
        ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(windows, @selector(count)) : 0;
    line("sample=%u app=%d delegate=%s scenes=%llu windows=%llu",
         sample, application ? 1 : 0, class_name_or_nil(delegate), connectedCount, windowCount);
    unsigned long long applicationState = 0;
    const bool hasApplicationState = read_integer(
        application, "applicationState", &applicationState);
    line("sample=%u appState=%llu hasAppState=%d",
         sample, applicationState, hasApplicationState ? 1 : 0);
    snapshot_windows("application", application, sample);
    line("event=h513_snapshot_exit sample=%u phase=%s pid=%d",
         sample, phase, getpid());
}

/* H639: the render server's context table has only ever been read inside backboardd, where every
 * entry is owned by backboardd itself, so those readings cannot say whether +[CAContext
 * allContexts] is the server's table or merely the calling process's own list.  Read the same
 * selector here, in the desktop process.  There are then only three possible outcomes: the
 * desktop context id seen by ca_context_set_layer appears only in this list, which means the
 * selector is per-process and the server question needs a different probe; it appears in both,
 * which means the server already knows the desktop context; or it appears in neither, which means
 * the desktop context never reached the render server at all.  Read-only. */
static void census_ca_contexts(const char *why)
{
    Class ctxClass = objc_getClass("CAContext");
    if (!ctxClass) {
        line_reserved("event=h639_ctx_census site=%s reason=no-CAContext pid=%d", why, getpid());
        return;
    }
    const SEL allSel = sel_getUid("allContexts");
    if (!((BOOL (*)(id, SEL, SEL)) objc_msgSend)((id) ctxClass, @selector(respondsToSelector:), allSel)) {
        line_reserved("event=h639_ctx_census site=%s reason=no-allContexts pid=%d", why, getpid());
        return;
    }
    id all = nil;
    @try {
        all = ((id (*)(id, SEL)) objc_msgSend)((id) ctxClass, allSel);
    } @catch (id ignored) {
        all = nil;
    }
    unsigned long long count = 0;
    if (all) {
        read_integer(all, "count", &count);
    }
    line_reserved("event=h639_ctx_census site=%s pid=%d count=%llu", why, getpid(), count);
    for (unsigned long long i = 0; all && i < count && i < 12; ++i) {
        id ctx = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
            all, @selector(objectAtIndex:), i);
        if (!ctx) {
            line_reserved("event=h639_ctx_entry site=%s pid=%d idx=%llu ctx=nil", why, getpid(), i);
            continue;
        }
        unsigned long long cid = 0, did = 0, mask = 0, subs = 0;
        read_integer(ctx, "contextId", &cid);
        read_integer(ctx, "displayId", &did);
        read_integer(ctx, "displayMask", &mask);
        id layer = read_object(ctx, "layer");
        id contents = read_object(layer, "contents");
        id sublayers = read_object(layer, "sublayers");
        if (sublayers) {
            read_integer(sublayers, "count", &subs);
        }
        char layerClass[24] = "-";
        char contentsClass[24] = "-";
        if (layer) {
            snprintf(layerClass, sizeof layerClass, "%.20s", object_getClassName(layer));
        }
        if (contents) {
            snprintf(contentsClass, sizeof contentsClass, "%.20s", object_getClassName(contents));
        }
        line_reserved(
            "event=h639_ctx_entry site=%s pid=%d idx=%llu id=0x%llx displayId=0x%llx mask=0x%llx "
            "layer=%s contents=%s subs=%llu",
            why, getpid(), i, cid, did, mask, layerClass, contentsClass, subs);
    }
}

static void census_once(const char *site)
{
    /* H640: H639 attached the census to the periodic reporter, and that thread stops emitting
     * mid-session while SpringBoard itself keeps running (last output 655.2 s here, 706.5 s in
     * H636, 750.9 s in H637, with the kernel alive past 1300 s in all three).  A timer-driven
     * observation is therefore not usable for this question.  Take the census from the two
     * context events that demonstrably fire early instead, once per site. */
    static bool done[2];
    const int slot = (site && site[0] == 'r') ? 1 : 0;
    if (done[slot]) {
        return;
    }
    done[slot] = true;
    census_ca_contexts(site);
}

static void *h539_state_reporter(void *context __unused)
{
    for (unsigned interval = 1; interval <= 40; ++interval) {
        sleep(30);
        rearm_exception_reporters("periodic");
        line_reserved("event=h572_observer_alive sample=%u pid=%d main=%d ls=0x%x",
                      interval * 30, getpid(), pthread_main_np(),
                      h539_installer_state());
    }
    return NULL;
}

__attribute__((constructor)) static void h481_observer_constructor(void)
{
    const char *process = getprogname();
    line("event=h513_constructor_enter process=%s pid=%d",
         process ? process : "?", getpid());
    if (!process || strncmp(process, "SpringBoard", 11)) {
        line("event=h513_constructor_skip process=%s pid=%d reason=process-filter",
             process ? process : "?", getpid());
        return;
    }
    line("event=h513_constructor_accepted process=%s pid=%d",
         process, getpid());
    gPreviousTerminateHandler = std::set_terminate(trace_cxx_terminate);
    line_reserved("event=h572_observer_loaded process=%s pid=%d terminate=%d",
                  process, getpid(), gPreviousTerminateHandler ? 1 : 0);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
           RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration",
           RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SystemStatus.framework/SystemStatus",
           RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SystemStatusServer.framework/SystemStatusServer",
           RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices",
           RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
           RTLD_NOW);
    dlopen("/System/Library/Frameworks/ActivityKit.framework/ActivityKit",
           RTLD_NOW);
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    install_ca_event_hooks();
    h672_install_ca_observer_anchor();
    install_h674_got_rebinding();
    install_h557_startup_hooks();
    NSSetUncaughtExceptionHandler(trace_uncaught_exception);
    install_fatal_signal_reporters();
    line("observer load process=%s pid=%d build=H674", process, getpid());
    install_application_notifications();
    schedule_application_scene_probe(0);

    pthread_t reporter;
    if (pthread_create(&reporter, NULL, h539_state_reporter, NULL) == 0) {
        (void) pthread_detach(reporter);
    } else {
        line_reserved("event=h572_observer_alive_thread_failed pid=%d",
                      getpid());
    }
}
