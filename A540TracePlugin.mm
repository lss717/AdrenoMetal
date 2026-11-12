// SPDX-License-Identifier: MIT
// A540 standalone Metal trace plugin (H236gm).
//
// A deliberately dependency-free bundle: it links only Foundation, IOKit and
// Metal, so a load failure can only mean "the bundle was not accepted", never a
// missing bridge/Turnip artefact. Metal loads it through MetalPluginName=A540Trace
// and drives the principal class through the original discovery path
// (IOAcceleratorES -> MetalPluginName -> NSBundle -> principal class). Every
// message Metal sends is reported through the native Adreno ABI's Log method,
// which the kernel prints as "NATIVE_MTL: ...".
//
// History that shaped the code (see build-environment-2026-11-10.md §45):
//  * an ad-hoc bundle is refused for backboardd ("unsuitable CT policy 0" and
//    "Library Validation failed") unless its CDHash is in the boot trust cache;
//  * the accelerator port Metal passes to -initWithAcceleratorPort: is not the
//    connection the ABI answers on, and using it kills the calling process, so
//    the trace opens its own connection through IOServiceOpen;
//  * a device that never answers leaves Metal retrying, which is exactly the
//    abandon point the inventory below has to capture.
#define _XOPEN_SOURCE 700   /* ucontext.h: the crash reporter reads pc/lr/sp/fp */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>   /* getprogname */
#include <unistd.h>
#include <mach/mach.h>
#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0x0100   /* Darwin; _XOPEN_SOURCE hides it */
#endif
#include <ucontext.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <mach/task_special_ports.h>
#include <signal.h>
/* <libproc.h> is not in the iOS SDK; these two libSystem calls are all the pid
 * scan needs. */
extern "C" int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern "C" int proc_name(int pid, void *buffer, uint32_t buffersize);
#define A540_PROC_ALL_PIDS 1
/* <servers/bootstrap.h> is not in the iOS SDK; the call and the task's own
 * bootstrap port are all this probe needs. */
extern "C" kern_return_t bootstrap_look_up(mach_port_t bootstrapPort, const char *name, mach_port_t *service);
#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *) -2)   /* _XOPEN_SOURCE hides Darwin's definition */
#endif

#include "NativeAdrenoABI.h"

@interface _MTLDevice : NSObject
// The selector Metal sends to the principal class: declaring it lets the plugin
// ask the real class what it does with the accelerator port (H236gn).
- (instancetype)initWithAcceleratorPort:(unsigned)port;
@end

static const uint32_t kTunnelMagic = 0x4e544e4c;   /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;

static io_connect_t gConnection;
static uint32_t gSelector;
static unsigned gSequence;
static unsigned gBudget = 800;
static bool gLoaded;
static id gDeviceInstance;
static id gQueueInstance;

static bool connectAccelerator(void);

/* H272h: everything logged before the accelerator connection exists used to be
 * dropped silently - that is why the H272g builder line was missing and why
 * "zero output" was ambiguous.  Early lines go to a small ring and are flushed
 * on the first successful emit. */
#define kPendingLines 16
static char gPending[kPendingLines][kMaxLog + 1];
static unsigned gPendingCount;

static void emit_raw(const char *text)
{
    struct { uint32_t magic, method, bytes, reserved; char text[kMaxLog]; } request;
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
    if (!gConnection && !connectAccelerator()) {
        if (gPendingCount < kPendingLines) {
            snprintf(gPending[gPendingCount], kMaxLog + 1, "%s", text);
            gPendingCount++;
        }
        return;
    }
    if (!gConnection) return;
    if (gPendingCount) {
        const unsigned pending = gPendingCount;
        gPendingCount = 0;
        for (unsigned i = 0; i < pending; i++) {
            emit_raw(gPending[i]);
        }
    }
    if (!gBudget) return;
    --gBudget;
    emit_raw(text);
}

static void caller(const char *cls, const char *sel, const char *detail)
{
    char line[256];
    snprintf(line, sizeof line, "%s#%u %s %s", cls, ++gSequence, sel, detail ? detail : "");
    emit(line);
}

static void value(const char *cls, const char *sel, const char *name, unsigned long long v)
{
    char detail[64];
    snprintf(detail, sizeof detail, "%s=%llu", name, v);
    caller(cls, sel, detail);
}

/* H236ht: the headless decision is two Objective-C return values inside
 * backboardd (BKDisplayStartWindowServer 0x10003472c): +[CADisplay mainDisplay]
 * and -[CAWindowServer displayWithDisplayId:].  Static analysis proved that none
 * of the nine IOMobileFramebuffer selectors can change them; the list comes from
 * the render server over "com.apple.CARenderServer".  Asking QuartzCore from here
 * answers both open questions in one line: whether the bootstrap service exists,
 * and how many displays the server publishes. */
static void probe_displays(const char *why)
{
    mach_port_t service = MACH_PORT_NULL, bootstrap = MACH_PORT_NULL;
    kern_return_t lookup = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap);
    if (lookup == KERN_SUCCESS) lookup = bootstrap_look_up(bootstrap, "com.apple.CARenderServer", &service);
    const unsigned portNumber = (unsigned) service;
    if (service != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), service);
    Class displayClass = NSClassFromString(@"CADisplay");
    Class serverClass = NSClassFromString(@"CAWindowServer");
    id mainDisplay = nil, displayList = nil, server = nil;
    unsigned long long displayCount = 0, serverCount = 0;
    const char *failure = NULL;
    @try {
        if (displayClass) {
            mainDisplay = ((id (*)(id, SEL)) objc_msgSend)(displayClass, @selector(mainDisplay));
            displayList = ((id (*)(id, SEL)) objc_msgSend)(displayClass, @selector(displays));
            if (displayList) displayCount = ((unsigned long long (*)(id, SEL)) objc_msgSend)(displayList, @selector(count));
        }
        if (serverClass) {
            server = ((id (*)(id, SEL)) objc_msgSend)(serverClass, @selector(serverIfRunning));
            if (server) {
                id list = ((id (*)(id, SEL)) objc_msgSend)(server, @selector(displays));
                if (list) serverCount = ((unsigned long long (*)(id, SEL)) objc_msgSend)(list, @selector(count));
            }
        }
    } @catch (id exception) {
        failure = "exception";
    }
    char detail[180];
    snprintf(detail, sizeof detail, "%s class=%d main=%d list=%llu server=%llu port=0x%x kr=0x%x%s",
             why, displayClass ? 1 : 0, mainDisplay ? 1 : 0, displayCount, serverCount,
             portNumber, (unsigned) lookup, failure ? failure : "");
    caller("ca", "probe", detail);
    /* H236hu: which displays the server publishes, by name.  mainDisplay is the
     * one called "LCD" (QuartzCore query_displays), so the names say whether the
     * panel really is in the list or only the external/TV entries are. */
    /* H236id: the reference port's SpringBoard aborted in FBSDisplayMode validation with
     * preferredScale == 0 while the hardware is 1080x1920, so the mode numbers our display publishes
     * are a prime suspect here too.  KVC keeps this readable whatever the private classes are. */
    if (!failure && displayList && displayCount) {
        @try {
            id entry = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(displayList, @selector(objectAtIndex:), 0ULL);
            const SEL currentMode = NSSelectorFromString(@"currentMode");
            id mode = nil;
            if (entry && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(entry, @selector(respondsToSelector:), currentMode))
                mode = ((id (*)(id, SEL)) objc_msgSend)(entry, currentMode);
            if (!mode) { caller("ca", "mode", "no-mode-object"); }
            else {
                /* CADisplayMode's getters, asked for one by one: the type of each is fixed but the
                 * object may not implement all of them on every build. */
                unsigned long long width = 0, height = 0, pixelWidth = 0, pixelHeight = 0;
                double hz = 0;
                for (NSString *name in @[@"width", @"height", @"pixelWidth", @"pixelHeight"]) {
                    SEL sel = NSSelectorFromString(name);
                    if (!((BOOL (*)(id, SEL, SEL)) objc_msgSend)(mode, @selector(respondsToSelector:), sel)) continue;
                    const unsigned long long value = ((unsigned long long (*)(id, SEL)) objc_msgSend)(mode, sel);
                    if ([name isEqualToString:@"width"]) width = value;
                    else if ([name isEqualToString:@"height"]) height = value;
                    else if ([name isEqualToString:@"pixelWidth"]) pixelWidth = value;
                    else pixelHeight = value;
                }
                const SEL refresh = NSSelectorFromString(@"refreshRate");
                if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(mode, @selector(respondsToSelector:), refresh))
                    hz = ((double (*)(id, SEL)) objc_msgSend)(mode, refresh);
                snprintf(detail, sizeof detail, "mode %llux%llu px=%llux%llu hz=%.3f",
                         width, height, pixelWidth, pixelHeight, hz);
                caller("ca", "mode", detail);
            }
        } @catch (NSException *exception) {
            snprintf(detail, sizeof detail, "exception %.100s: %.60s",
                     exception.name ? [exception.name UTF8String] : "?",
                     exception.reason ? [exception.reason UTF8String] : "?");
            caller("ca", "mode", detail);
        }
        /* H236ih: ask only what is safe to ask.  MobileGestalt is not usable from this process: a C-string
         * key segfaults, a CFString key blocks the calling thread forever, so scale comes from QuartzCore
         * alone and the driver's published properties are read through IOKit. */
        @try {
            id entry = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(displayList, @selector(objectAtIndex:), 0ULL);
            double pointScale = -1.0;
            const SEL pointScaleSel = NSSelectorFromString(@"pointScale");
            if (entry && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(entry, @selector(respondsToSelector:), pointScaleSel))
                pointScale = ((double (*)(id, SEL)) objc_msgSend)(entry, pointScaleSel);
            snprintf(detail, sizeof detail, "displayScale=%.3f", pointScale);
            caller("ca", "scale", detail);
        } @catch (id ignored) { caller("ca", "scale", "exception"); }
        /* H236ih: whether the display driver published a default framebuffer surface.  A surface is what
         * gives the compositor something to draw into; its absence also explains pixelWidth == 0.
         * Reading the service's properties needs no driver call and no kernel change. */
        @try {
            io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NativeLegacyDisplay"));
            if (!service) { caller("ca", "props", "no-service"); }
            else {
                CFMutableDictionaryRef properties = NULL;
                if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties) {
                    caller("ca", "props", "no-properties");
                } else {
                    NSDictionary *values = (__bridge_transfer NSDictionary *) properties;
                    const bool surface = values[@"default_fb_surface"] != nil;
                    NSString *names = [[values.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
                    snprintf(detail, sizeof detail, "n=%llu surface=%d keys=%.120s",
                             (unsigned long long) values.count, surface ? 1 : 0, names ? [names UTF8String] : "");
                    caller("ca", "props", detail);
                }
                IOObjectRelease(service);
            }
        } @catch (id ignored) { caller("ca", "props", "exception"); }
    }
    /* H236ic: +[CADisplay displays] answers with CADisplay objects (client side); the window-server
     * side objects are -[CAWindowServer displays], and the client/context counters live there. */
    if (!failure && server) {
        @try {
            id serverList = ((id (*)(id, SEL)) objc_msgSend)(server, @selector(displays));
            id displayed = serverList ? ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(serverList, @selector(objectAtIndex:), 0ULL) : nil;
            if (displayed) {
                NSString *counters = nil;
                for (NSString *selectorName in @[@"contexts", @"contextIds", @"clients", @"currentState"]) {
                    SEL sel = NSSelectorFromString(selectorName);
                    if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(displayed, @selector(respondsToSelector:), sel)) {
                        id value = ((id (*)(id, SEL)) objc_msgSend)(displayed, sel);
                        unsigned long long n = 0;
                        if (value && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(value, @selector(respondsToSelector:), @selector(count)))
                            n = ((unsigned long long (*)(id, SEL)) objc_msgSend)(value, @selector(count));
                        counters = [NSString stringWithFormat:@"%@ %@=%llu", counters ?: @"", selectorName, n];
                    }
                }
                snprintf(detail, sizeof detail, "server%s", counters ? [counters UTF8String] : " none");
                caller("ca", "clients", detail);
            }
        } @catch (id ignored) { caller("ca", "clients", "exception"); }
    }
    if (!failure && displayList) {
        const unsigned long long shown = displayCount < 6 ? displayCount : 6;
        for (unsigned long long index = 0; index < shown; ++index) {
            id item = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(displayList, @selector(objectAtIndex:), index);
            if (!item) continue;
            NSString *displayName = ((id (*)(id, SEL)) objc_msgSend)(item, @selector(name));
            NSString *deviceName = nil;
            if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(item, @selector(respondsToSelector:), @selector(deviceName)))
                deviceName = ((id (*)(id, SEL)) objc_msgSend)(item, @selector(deviceName));
            NSString *boundsText = nil;
            if ([item respondsToSelector:NSSelectorFromString(@"valueForKey:")]) {
                @try {
                    NSValue *bounds = [item valueForKey:@"bounds"];
                    if ([bounds isKindOfClass:[NSValue class]]) {
                        CGRect rect;
                        memset(&rect, 0, sizeof rect);
                        [bounds getValue:&rect];
                        boundsText = [NSString stringWithFormat:@"%.0fx%.0f", rect.size.width, rect.size.height];
                    }
                } @catch (id ignored) { boundsText = nil; }
            }
            snprintf(detail, sizeof detail, "list[%llu] name=%s device=%s bounds=%s",
                     index, displayName ? [displayName UTF8String] : "nil",
                     deviceName ? [deviceName UTF8String] : "nil",
                     boundsText ? [boundsText UTF8String] : "?");
            caller("ca", "display", detail);
        }
    }
}

/* H236ic: SpringBoard's stderr goes nowhere we can see (it is a launchd job, not a tty), but the
 * unified log keeps it and OSLogStore reads that back from any process.  This is the only way to
 * learn where a relaunched SpringBoard stops without touching the kernel. */
__attribute__((unused))
static void read_springboard_log(void)
{
    static bool once;
    if (once) return;
    once = true;
    @try {
        dlopen("/System/Library/Frameworks/OSLog.framework/OSLog", RTLD_NOW);
        Class storeClass = NSClassFromString(@"OSLogStore");
        if (!storeClass) { caller("sblog", "oslog", "no-class"); return; }
        NSError *error = nil;
        /* This OS only carries +storeWithScope:error: (scope 0 = the system store, 1 = this process);
         * the macOS-only +localStoreAndReturnError: is absent, which is what the first attempt hit. */
        id store = nil;
        SEL factory = NSSelectorFromString(@"storeWithScope:error:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(storeClass, @selector(respondsToSelector:), factory))
            store = ((id (*)(id, SEL, long long, NSError **)) objc_msgSend)(storeClass, factory, 0LL, &error);
        if (!store) { caller("sblog", "oslog", "no-store"); return; }
        NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-420];
        id position = ((id (*)(id, SEL, id)) objc_msgSend)(store, NSSelectorFromString(@"positionWithDate:"), since);
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"process == %@", @"SpringBoard"];
        id entries = ((id (*)(id, SEL, unsigned long long, id, id, NSError **)) objc_msgSend)(store,
            NSSelectorFromString(@"entriesEnumeratorWithOptions:position:predicate:error:"), 0ULL, position, predicate, &error);
        if (!entries) {
            char why[184];
            snprintf(why, sizeof why, "no-enumerator %.140s",
                     error ? [[error localizedDescription] UTF8String] : "no-error");
            caller("sblog", "oslog", why);
            return;
        }
        char text[184];
        unsigned long long shown = 0, total = 0;
        for (id entry = ((id (*)(id, SEL)) objc_msgSend)(entries, @selector(nextObject)); entry && shown < 48;
             entry = ((id (*)(id, SEL)) objc_msgSend)(entries, @selector(nextObject))) {
            ++total;
            SEL composed = NSSelectorFromString(@"composedMessage");
            if (!((BOOL (*)(id, SEL, SEL)) objc_msgSend)(entry, @selector(respondsToSelector:), composed)) continue;
            NSString *message = ((id (*)(id, SEL)) objc_msgSend)(entry, composed);
            if (!message) continue;
            const char *utf8 = [message UTF8String];
            if (!utf8) continue;
            snprintf(text, sizeof text, "%.150s", utf8);
            caller("sblog", "sb", text);
            ++shown;
        }
        snprintf(text, sizeof text, "total=%llu shown=%llu", total, shown);
        caller("sblog", "oslog", text);
    } @catch (NSException *exception) {
        char text[184];
        snprintf(text, sizeof text, "exception %s: %.120s",
                 exception.name ? [exception.name UTF8String] : "?",
                 exception.reason ? [exception.reason UTF8String] : "?");
        caller("sblog", "oslog", text);
    }
}

/* H236ii: MobileGestalt cannot be called from this process (a C-string key segfaults, a CFString key
 * blocks the thread), but its persistent cache is an ordinary file on the Data volume and root can read
 * it.  The reference port found that a cached screen record with scale 0 keeps both the mode's
 * preferredScale and the primary display's pointScale at 0 even after the device tree says 3, so the
 * question "what does MG believe" is answered by looking at the file, not by calling MG. */
static void probe_gestalt_cache(void)
{
    static bool once;
    if (once) return;
    once = true;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *paths = @[
        @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache",
        @"/private/var/db/com.apple.mobilegestalt.plist",
        @"/private/var/mobile/Library/Preferences/com.apple.MobileGestalt.plist",
        @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
    ];
    char detail[184];
    for (NSString *path in paths) {
        const char *shown = [path.lastPathComponent UTF8String];
        BOOL directory = NO;
        if (![manager fileExistsAtPath:path isDirectory:&directory]) {
            snprintf(detail, sizeof detail, "absent %.140s", [path UTF8String]);
            caller("mgcache", shown ? shown : "?", detail);
            continue;
        }
        if (directory) {
            NSArray *items = [manager contentsOfDirectoryAtPath:path error:nil];
            NSString *list = items ? [items componentsJoinedByString:@","] : @"?";
            snprintf(detail, sizeof detail, "dir n=%llu %.120s", (unsigned long long) items.count,
                     list ? [list UTF8String] : "");
            caller("mgcache", shown ? shown : "?", detail);
            for (NSString *item in items ?: @[]) {
                NSString *child = [path stringByAppendingPathComponent:item];
                NSDictionary *attributes = [manager attributesOfItemAtPath:child error:nil];
                if (!attributes) continue;
                snprintf(detail, sizeof detail, "item %s %.100s bytes=%llu",
                         [[attributes fileType] UTF8String] ?: "?", [item UTF8String],
                         (unsigned long long) [attributes fileSize]);
                caller("mgcache", shown ? shown : "?", detail);
            }
        } else {
            NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
            snprintf(detail, sizeof detail, "file bytes=%llu", (unsigned long long) [attributes fileSize]);
            caller("mgcache", shown ? shown : "?", detail);
        }
    }
}

/* H236ip: SpringBoard's only abnormal wait is a synchronous Mach reply (mach_msg2_trap, §45.77) and
 * no daemon shows an abnormal kernel wait (§45.80), so the question is whether the service it is
 * calling is registered at all.  A missing bootstrap name answers that without touching the kernel:
 * BOOTSTRAP_UNKNOWN_SERVICE (0x44e) means the name was never registered in this namespace. */
static void probe_services(void)
{
    static bool once;
    if (once) return;
    once = true;
    static const char *const names[] = {
        "com.apple.runningboard",
        "com.apple.lsd.xpc",
        "com.apple.lsd.open",
        "com.apple.lsd.installation",
        "com.apple.lsd.personaobserver",
        "com.apple.containermanagerd",
        "com.apple.containermanagerd.system",
        "com.apple.mobile.usermanagerd.xpc",
        "com.apple.frontboard.systemappservices",
        "com.apple.backboard.hid",
        "com.apple.CARenderServer",
        "com.apple.CoreDisplay",
        "com.apple.system.logger",
        "com.apple.mobile.keybagd",
        "com.apple.springboard.services",
        "com.apple.UIKit.keyboard-management-service",
        "com.apple.distributed_notifications@1v3",
    };
    /* H236ir: the reference port's userland chain failed on the missing persona manifest, so report
     * whether this Data volume has one (read-only: a stat, no container or persona call). */
    {
        static const char *const paths[] = {
            "/private/var/keybags/persona.kb",
            "/private/var/keybags",
            "/private/var/db/com.apple.xpc.launchd/disabled.plist",
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache",
        };
        struct stat info;
        char pathDetail[128];
        for (unsigned index = 0; index < sizeof paths / sizeof paths[0]; ++index) {
            const int status = stat(paths[index], &info);
            snprintf(pathDetail, sizeof pathDetail, "path %s rc=%d bytes=%lld", paths[index], status,
                     status == 0 ? (long long) info.st_size : -1LL);
            caller("svc", "file", pathDetail);
        }
    }
    mach_port_t bootstrap = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap) != KERN_SUCCESS) {
        caller("svc", "bootstrap", "no-port");
        return;
    }
    char detail[128];
    for (unsigned index = 0; index < sizeof names / sizeof names[0]; ++index) {
        mach_port_t port = MACH_PORT_NULL;
        const kern_return_t status = bootstrap_look_up(bootstrap, names[index], &port);
        if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
        snprintf(detail, sizeof detail, "%s kr=0x%x", names[index], (unsigned) status);
        caller("svc", "lookup", detail);
    }
}

/* H236iq: com.apple.lsd is the one candidate that is not registered (0x44e) at ~220 s while lsd
 * itself runs with runnable threads, and SpringBoard waits on a synchronous reply.  This samples it
 * repeatedly so the log says whether the name ever appears, and when. */
static void probe_lsd(unsigned round)
{
    static const char *const names[] = {
        "com.apple.lsd",
        "com.apple.lsd.mapdb",
        "com.apple.lsd.modifydb",
        "com.apple.iconservices",
        "com.apple.iconservices.store",
    };
    mach_port_t bootstrap = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap) != KERN_SUCCESS) return;
    char detail[128];
    for (unsigned index = 0; index < sizeof names / sizeof names[0]; ++index) {
        mach_port_t port = MACH_PORT_NULL;
        const kern_return_t status = bootstrap_look_up(bootstrap, names[index], &port);
        if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
        snprintf(detail, sizeof detail, "round=%u %s kr=0x%x", round, names[index], (unsigned) status);
        caller("lsd", "lookup", detail);
    }
}

/* H236is: the reference port (sagit, iOS 18) traced its userland stall to the missing initial
 * persona manifest at /private/var/keybags/persona.kb: usermanagerd reported ENOENT and launchd kept
 * respawning it, and backboardd waited in the native Sandbox container RPC.  Here the directory
 * exists but the file does not (§45.81), and no candidate Mach service is missing, so this creates the
 * same initial metadata — only when absent, never overwriting — and reports the result.  It is persona
 * metadata, not a keybag secret. */
static void fix_persona(void)
{
    static bool once;
    if (once) return;
    once = true;
    const char *directory = "/private/var/keybags";
    const char *path = "/private/var/keybags/persona.kb";
    struct stat info;
    char detail[160];
    if (stat(path, &info) == 0) {
        snprintf(detail, sizeof detail, "exists bytes=%lld", (long long) info.st_size);
        caller("persona", "present", detail);
        return;
    }
    mkdir(directory, 0700);
    NSDictionary *manifest = @{
        @"UsePersonaManifestVersion": @1,
        @"UsePersonaGenerationID": @1,
        @"UserPersonaDictionary": @{},
    };
    NSError *error = nil;
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:manifest
                                                                format:NSPropertyListBinaryFormat_v1_0
                                                               options:0
                                                                 error:&error];
    if (!encoded) { caller("persona", "encode", "failed"); return; }
    const int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        snprintf(detail, sizeof detail, "create failed errno=%d", errno);
        caller("persona", "create", detail);
        return;
    }
    const ssize_t written = write(descriptor, encoded.bytes, encoded.length);
    close(descriptor);
    chmod(path, 0600);
    chown(path, 0, 0);
    snprintf(detail, sizeof detail, "written=%lld of %llu mode=0600", (long long) written,
             (unsigned long long) encoded.length);
    caller("persona", "create", detail);
}

/* H236hu: ordering experiment.  SpringBoard launched at 126.5 s while backboardd
 * only exec'd at 142.8 s and opened the display at 150.5 s, so SpringBoard asked
 * for the main CADisplay before the render server existed (query_displays returns
 * an empty list with no log when CARenderServerGetServerPort is 0).  If the empty
 * list is cached, restarting SpringBoard now that the server publishes six
 * displays is the cheapest possible test: a relaunched SpringBoard either gets a
 * display and starts submitting layers, or it does not. */
/* H236hv: proc_listpids is refused by backboardd's sandbox
 * ("deny(1) process-info-listpids"), so the list is asked one pid at a time
 * instead: proc_name() is a different check and may be admitted.  Both counts
 * are reported, so a refusal is visible rather than silent. */
static int gScanRefused;

static int find_process(const char *name)
{
    gScanRefused = 0;
    int found = 0;
    for (int pid = 1; pid <= 400 && !found; ++pid) {
        char comm[64];
        memset(comm, 0, sizeof comm);
        const int got = proc_name(pid, comm, (uint32_t) sizeof comm);
        if (got <= 0) {
            if (got < 0 && gScanRefused < 1000) ++gScanRefused;
            continue;
        }
        if (!strcmp(comm, name)) found = pid;
    }
    return found;
}

/* H236hw: backboardd cannot enumerate processes (process-info-listpids is denied by its
 * sandbox), so the restart goes through the frameworks it already talks to: FrontBoardServices
 * owns application termination, RunningBoardServices the same in its newer form.  Both are
 * private, so they are loaded by name and every call is guarded and logged. */
static void __attribute__((unused)) restart_springboard(const char *why)
{
    char detail[160];
    const int pid = find_process("SpringBoard");
    snprintf(detail, sizeof detail, "%s scan=%d refused=%d", why, pid, gScanRefused);
    caller("ca", "restart", detail);
    if (pid > 0) {
        const int status = kill(pid, SIGTERM);
        snprintf(detail, sizeof detail, "%s kill pid=%d status=%d", why, pid, status);
        caller("ca", "restart", detail);
        if (status == 0) return;
    }
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    if (!serviceClass) { caller("ca", "restart", "fbs=no-class"); return; }
    id service = ((id (*)(id, SEL)) objc_msgSend)(serviceClass, @selector(sharedService));
    if (!service) service = ((id (*)(id, SEL)) objc_msgSend)(((id (*)(id, SEL)) objc_msgSend)(serviceClass, @selector(alloc)),
                                                            @selector(init));
    if (!service) { caller("ca", "restart", "fbs=no-service"); return; }
    const SEL terminate = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if (!((BOOL (*)(id, SEL, SEL)) objc_msgSend)(service, @selector(respondsToSelector:), terminate)) {
        caller("ca", "restart", "fbs=no-terminate");
        return;
    }
    @try {
        ((void (*)(id, SEL, id, unsigned long long, BOOL, id)) objc_msgSend)(
            service, terminate, @"com.apple.springboard", 1ull, YES, @"bring-up: render server was late");
        caller("ca", "restart", "fbs=sent");
    } @catch (id exception) {
        caller("ca", "restart", "fbs=exception");
    }
}

/* H272 (P1): CADisplay reports px=0x0 and pointScale=0 while the driver publishes
 * scale 3, so the standing hypothesis is that CAMetalLayer computes a degenerate
 * drawableSize and the renderer drops every pass for lack of a drawable.  Until now
 * that was inference: every number came from the display object, never from a layer.
 * This probe asks the layer itself - bounds, contentsScale, the derived drawableSize
 * and whether nextDrawable returns anything - and it is pure observation.
 *
 * nextDrawable is called last and on a utility queue: a layer that is not attached to
 * a CAContext has no presentation source, so a nil answer is expected here and says
 * nothing about the render server's own layers.  A non-degenerate drawableSize is the
 * part that carries information, because that is geometry CA also computes. */
static const char *probe_self_name(void)
{
    static char name[32];
    static bool known;
    if (!known) {
        NSString *text = [[NSProcessInfo processInfo] processName];
        snprintf(name, sizeof name, "%s", text ? [text UTF8String] : "?");
        known = true;
    }
    return name;
}

static void probe_drawable(const char *why)
{
    Class layerClass = NSClassFromString(@"CAMetalLayer");
    if (!layerClass) {
        caller("draw", why, "no-CAMetalLayer");
        return;
    }
    id device = nil;
    id (*createDevice)(void) = (id (*)(void)) dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
    if (createDevice) {
        @try { device = createDevice(); } @catch (id ignored) { device = nil; }
    }
    @try {
        id layer = ((id (*)(id, SEL)) objc_msgSend)(((id (*)(id, SEL)) objc_msgSend)(layerClass, @selector(alloc)), @selector(init));
        if (!layer) {
            caller("draw", why, "alloc-nil");
            return;
        }
        if (device) {
            ((void (*)(id, SEL, id)) objc_msgSend)(layer, @selector(setDevice:), device);
        }
        const SEL setScale = NSSelectorFromString(@"setContentsScale:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setScale)) {
            ((void (*)(id, SEL, double)) objc_msgSend)(layer, setScale, 3.0);
        }
        const SEL setBounds = NSSelectorFromString(@"setBounds:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setBounds)) {
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(layer, setBounds, CGRectMake(0, 0, 360, 640));
        }
        const CGRect bounds = ((CGRect (*)(id, SEL)) objc_msgSend)(layer, @selector(bounds));
        const CGSize drawable = ((CGSize (*)(id, SEL)) objc_msgSend)(layer, @selector(drawableSize));
        double scale = -1.0;
        const SEL scaleSel = NSSelectorFromString(@"contentsScale");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), scaleSel)) {
            scale = ((double (*)(id, SEL)) objc_msgSend)(layer, scaleSel);
        }
        unsigned long long maxCount = 0;
        const SEL maxSel = NSSelectorFromString(@"maximumDrawableCount");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), maxSel)) {
            maxCount = ((unsigned long long (*)(id, SEL)) objc_msgSend)(layer, maxSel);
        }
        char detail[180];
        snprintf(detail, sizeof detail, "%s comm=%s device=%d bounds=%.0fx%.0f scale=%.2f ds=%.0fx%.0f max=%llu",
                 why, probe_self_name(), device ? 1 : 0, bounds.size.width, bounds.size.height, scale,
                 drawable.width, drawable.height, maxCount);
        caller("draw", "layer", detail);
        id drawableObject = nil;
        @try {
            drawableObject = ((id (*)(id, SEL)) objc_msgSend)(layer, @selector(nextDrawable));
        } @catch (NSException *exception) {
            snprintf(detail, sizeof detail, "%s nextDrawable exception %.60s",
                     why, exception.name ? [exception.name UTF8String] : "?");
            caller("draw", "next", detail);
        }
        if (drawableObject) {
            const SEL textureSel = NSSelectorFromString(@"texture");
            id texture = nil;
            if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(drawableObject, @selector(respondsToSelector:), textureSel)) {
                texture = ((id (*)(id, SEL)) objc_msgSend)(drawableObject, textureSel);
            }
            unsigned long long texW = 0, texH = 0;
            if (texture) {
                const SEL widthSel = NSSelectorFromString(@"width");
                const SEL heightSel = NSSelectorFromString(@"height");
                if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(texture, @selector(respondsToSelector:), widthSel)) {
                    texW = ((unsigned long long (*)(id, SEL)) objc_msgSend)(texture, widthSel);
                }
                if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(texture, @selector(respondsToSelector:), heightSel)) {
                    texH = ((unsigned long long (*)(id, SEL)) objc_msgSend)(texture, heightSel);
                }
            }
            snprintf(detail, sizeof detail, "%s comm=%s drawable=1 texture=%d %llux%llu",
                     why, probe_self_name(), texture ? 1 : 0, texW, texH);
        } else {
            snprintf(detail, sizeof detail, "%s comm=%s drawable=nil", why, probe_self_name());
        }
        caller("draw", "next", detail);
    } @catch (NSException *exception) {
        char detail[160];
        snprintf(detail, sizeof detail, "%s exception %.80s: %.60s", why,
                 exception.name ? [exception.name UTF8String] : "?",
                 exception.reason ? [exception.reason UTF8String] : "?");
        caller("draw", "layer", detail);
    }
}

/* H272b (P1'): the layer probe read drawableSize before nextDrawable and on a
 * layer that belonged to no context, so 0x0 could be laziness rather than a real
 * defect.  This probe fixes both weaknesses and then walks the whole way to a
 * presented frame: attach the layer to a real CAContext, read drawableSize before
 * and after attaching, take a drawable, fill its storage directly (the texture is
 * an IOSurface, so no shader and no render pass is needed), and present it.
 *
 * Every step is guarded: a context that will not build, a nil drawable or a
 * texture without a surface each produce one log line instead of an abort. */
static void probe_first_frame(const char *why)
{
    Class layerClass = NSClassFromString(@"CAMetalLayer");
    Class contextClass = NSClassFromString(@"CAContext");
    if (!layerClass) {
        caller("frame", why, "no-CAMetalLayer");
        return;
    }
    id device = nil;
    id (*createDevice)(void) = (id (*)(void)) dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
    if (createDevice) {
        @try { device = createDevice(); } @catch (id ignored) { device = nil; }
    }
    @try {
        id layer = ((id (*)(id, SEL)) objc_msgSend)(((id (*)(id, SEL)) objc_msgSend)(layerClass, @selector(alloc)), @selector(init));
        if (!layer) {
            caller("frame", why, "alloc-nil");
            return;
        }
        /* H272b: the first run died on `-[CAMetalLayer setBounds]` even though the
         * plain layer probe had set the same property, so no setter may be assumed:
         * each one is tried alone and its outcome is reported.  Whether the class
         * really is CALayer-shaped is itself part of the answer, hence class-name
         * and respondsToSelector in the same line. */
        const SEL setDeviceSel = @selector(setDevice:);
        const SEL setScaleSel = NSSelectorFromString(@"setContentsScale:");
        const SEL setBoundsSel = NSSelectorFromString(@"setBounds:");
        const SEL setFrameSel = NSSelectorFromString(@"setFrame:");
        const bool hasDevice = ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setDeviceSel);
        const bool hasScale = ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setScaleSel);
        const bool hasBounds = ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setBoundsSel);
        const bool hasFrame = ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setFrameSel);
        char detail[190];
        snprintf(detail, sizeof detail, "%s comm=%s class=%.40s device=%d scale=%d bounds=%d frame=%d",
                 why, probe_self_name(), class_getName(object_getClass(layer)),
                 hasDevice ? 1 : 0, hasScale ? 1 : 0, hasBounds ? 1 : 0, hasFrame ? 1 : 0);
        caller("frame", "class", detail);
        if (device && hasDevice) {
            @try { ((void (*)(id, SEL, id)) objc_msgSend)(layer, setDeviceSel, device); }
            @catch (NSException *exception) { caller("frame", "setDevice", "exception"); }
        }
        if (hasScale) {
            @try { ((void (*)(id, SEL, double)) objc_msgSend)(layer, setScaleSel, 3.0); }
            @catch (NSException *exception) { caller("frame", "setContentsScale", "exception"); }
        }
        const CGRect wanted = CGRectMake(0, 0, 360, 640);
        if (hasBounds) {
            @try { ((void (*)(id, SEL, CGRect)) objc_msgSend)(layer, setBoundsSel, wanted); }
            @catch (NSException *exception) { caller("frame", "setBounds", "exception"); }
        } else if (hasFrame) {
            @try { ((void (*)(id, SEL, CGRect)) objc_msgSend)(layer, setFrameSel, wanted); }
            @catch (NSException *exception) { caller("frame", "setFrame", "exception"); }
        } else {
            caller("frame", "geometry", "no-setter");
        }
        const CGSize before = ((CGSize (*)(id, SEL)) objc_msgSend)(layer, @selector(drawableSize));

        id context = nil;
        const SEL factory = NSSelectorFromString(@"contextWithOptions:");
        if (contextClass && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(contextClass, @selector(respondsToSelector:), factory)) {
            @try {
                context = ((id (*)(id, SEL, id)) objc_msgSend)(contextClass, factory, @{});
            } @catch (NSException *exception) {
                char detail[160];
                snprintf(detail, sizeof detail, "%s context exception %.60s", why,
                         exception.reason ? [exception.reason UTF8String] : "?");
                caller("frame", "context", detail);
                context = nil;
            }
        }
        if (context) {
            const SEL setLayer = NSSelectorFromString(@"setLayer:");
            if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(context, @selector(respondsToSelector:), setLayer)) {
                ((void (*)(id, SEL, id)) objc_msgSend)(context, setLayer, layer);
            }
        }
        const CGSize after = ((CGSize (*)(id, SEL)) objc_msgSend)(layer, @selector(drawableSize));
        snprintf(detail, sizeof detail, "%s comm=%s ctx=%d ds_before=%.0fx%.0f ds_after=%.0fx%.0f",
                 why, probe_self_name(), context ? 1 : 0,
                 before.width, before.height, after.width, after.height);
        caller("frame", "context", detail);

        id drawable = nil;
        @try {
            drawable = ((id (*)(id, SEL)) objc_msgSend)(layer, @selector(nextDrawable));
        } @catch (NSException *exception) {
            caller("frame", "drawable", "exception");
        }
        if (!drawable) {
            caller("frame", "drawable", "nil");
            return;
        }
        id texture = nil;
        const SEL textureSel = NSSelectorFromString(@"texture");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(drawable, @selector(respondsToSelector:), textureSel)) {
            texture = ((id (*)(id, SEL)) objc_msgSend)(drawable, textureSel);
        }
        void *surface = NULL;
        if (texture && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(texture, @selector(respondsToSelector:), @selector(iosurface))) {
            surface = (void *) (uintptr_t) [texture iosurface];
        }
        unsigned long long filled = 0;
        /* Resolved here rather than through load_surface_queries(): that helper and
         * its typedefs are defined further down the file, after this probe. */
        void *(*surfaceBase)(void *) = (void *(*)(void *)) dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
        size_t (*surfaceAlloc)(void *) = (size_t (*)(void *)) dlsym(RTLD_DEFAULT, "IOSurfaceGetAllocSize");
        if (surface && surfaceBase && surfaceAlloc) {
            void *base = surfaceBase(surface);
            const size_t bytes = surfaceAlloc(surface);
            if (base && bytes) {
                /* 0x80 is deliberate: a mid-grey frame is distinguishable from the
                 * black the panel shows when nothing ever reaches it. */
                memset(base, 0x80, bytes);
                filled = (unsigned long long) bytes;
            }
        }
        const CGSize now = ((CGSize (*)(id, SEL)) objc_msgSend)(layer, @selector(drawableSize));
        snprintf(detail, sizeof detail, "%s comm=%s surface=%d bytes=%llu ds_now=%.0fx%.0f",
                 why, probe_self_name(), surface ? 1 : 0, filled, now.width, now.height);
        caller("frame", "fill", detail);

        @try {
            ((void (*)(id, SEL)) objc_msgSend)(drawable, @selector(present));
            caller("frame", "present", "sent");
        } @catch (NSException *exception) {
            caller("frame", "present", "exception");
        }
    } @catch (NSException *exception) {
        char detail[160];
        snprintf(detail, sizeof detail, "%s exception %.80s", why,
                 exception.reason ? [exception.reason UTF8String] : "?");
        caller("frame", why, detail);
    }
}

/* H272d (P1", option a): a client CAContext cannot exist inside backboardd (H272c
 * ctx=0), so the only context that can present anything here is the display's own
 * server-side context.  This walk asks the window server for display 0, takes its
 * context and root layer, attaches a fresh CAMetalLayer as a sublayer, then fills a
 * drawable and presents.  A grey frame on the panel proves the whole
 * drawable -> present -> swap -> panel chain at once.
 *
 * This touches the live display for the duration of one boot; nothing is written to
 * the device and a reboot restores the previous state. */
static void dump_class(const char *tag, id object)
{
    if (!object) {
        caller("dump", tag, "nil");
        return;
    }
    Class cls = object_getClass(object);
    const char *image = class_getImageName(cls);
    const char *base = image ? strrchr(image, '/') : NULL;
    char detail[190];
    snprintf(detail, sizeof detail, "%s class=%.48s image=%.48s", tag, class_getName(cls),
             base ? base + 1 : (image ? image : "-"));
    caller("dump", "class", detail);
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    char names[150];
    size_t used = 0;
    names[0] = 0;
    for (unsigned i = 0; methods && i < count && used + 2 < sizeof names; i++) {
        const char *sel = sel_getName(method_getName(methods[i]));
        const int written = snprintf(names + used, sizeof names - used, "%s,", sel);
        if (written < 0) break;
        used += (size_t) written;
    }
    if (methods) {
        free(methods);
    }
    snprintf(detail, sizeof detail, "%s own=%u [%.140s]", tag, count, names);
    caller("dump", "methods", detail);
}

/* H272i: print names, not a prefix of them.  with words == NULL every method is
 * printed (chunked, one line per ~5 names); otherwise only names containing one of
 * the words are, and the match count is printed too, so "no match" and "filter never
 * ran" cannot be confused. */
static void dump_methods(const char *tag, Class cls, const char **words, unsigned wordCount)
{
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    char line[190];
    unsigned inLine = 0;
    unsigned matches = 0;
    size_t used = 0;
    snprintf(line, sizeof line, "%s : ", tag);
    used = strlen(line);
    for (unsigned i = 0; methods && i < count; i++) {
        const char *sel = sel_getName(method_getName(methods[i]));
        bool keep = (words == NULL);
        for (unsigned w = 0; !keep && w < wordCount; w++) {
            if (strstr(sel, words[w]) != NULL) keep = true;
        }
        if (!keep) continue;
        matches++;
        if (inLine >= 5 || used + strlen(sel) + 3 >= sizeof line) {
            caller("dump", "names", line);
            snprintf(line, sizeof line, "%s : ", tag);
            used = strlen(line);
            inLine = 0;
        }
        used += (size_t) snprintf(line + used, sizeof line - used, "%s,", sel);
        inLine++;
    }
    if (methods) {
        free(methods);
    }
    snprintf(line, sizeof line, "%s total=%u matched=%u filter=%s", tag, count, matches,
             words ? "on" : "off");
    caller("dump", "count", line);
}

static void probe_display_frame(const char *why)
{
    /* H272f: the display walk must run before the boot dies (209 s in the last two
     * runs), but the Metal device is only initialised at 213-289 s.  So it is also
     * driven from the bundle constructor, and once a layer is attached it stops. */
    static bool attachedOnce;
    if (attachedOnce) {
        return;
    }
    Class serverClass = NSClassFromString(@"CAWindowServer");
    Class layerClass = NSClassFromString(@"CAMetalLayer");
    if (!serverClass || !layerClass) {
        caller("disp", why, "no-class");
        return;
    }
    id device = nil;
    id (*createDevice)(void) = (id (*)(void)) dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
    if (createDevice) {
        @try { device = createDevice(); } @catch (id ignored) { device = nil; }
    }
    @try {
        id server = ((id (*)(id, SEL)) objc_msgSend)(serverClass, @selector(serverIfRunning));
        if (!server) {
            caller("disp", why, "server=nil");
            return;
        }
        id displays = ((id (*)(id, SEL)) objc_msgSend)(server, @selector(displays));
        const unsigned long long count = displays ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(displays, @selector(count)) : 0;
        if (!count) {
            caller("disp", why, "displays=0");
            return;
        }
        id display = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(displays, @selector(objectAtIndex:), 0ULL);
        CGRect bounds = CGRectMake(0, 0, 0, 0);
        const SEL boundsSel = NSSelectorFromString(@"bounds");
        if (display && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(display, @selector(respondsToSelector:), boundsSel)) {
            bounds = ((CGRect (*)(id, SEL)) objc_msgSend)(display, boundsSel);
        }
        id context = nil;
        const SEL contextSel = NSSelectorFromString(@"context");
        if (display && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(display, @selector(respondsToSelector:), contextSel)) {
            @try { context = ((id (*)(id, SEL)) objc_msgSend)(display, contextSel); }
            @catch (NSException *exception) { caller("disp", "context", "exception"); }
        }
        char detail[190];
        snprintf(detail, sizeof detail, "%s comm=%s displays=%llu bounds=%.0fx%.0f ctx=%d",
                 why, probe_self_name(), count, bounds.size.width, bounds.size.height, context ? 1 : 0);
        caller("disp", "server", detail);
        /* H272h: stop guessing.  Print what the real classes expose, then verify
         * behaviour for each candidate - existence in the list and a non-nil answer
         * are different things and the difference is the whole answer. */
        dump_class("disp", display);
        dump_class("server", server);
        {
            static const char *words[] = {
                "ontext", "ayer", "urface", "resent", "wap", "oot", "ost",
                "ree", "uffer", "rawable", "indow", "ort", "rame", "_"
            };
            dump_methods("server", object_getClass(server), NULL, 0);
            dump_methods("disp", object_getClass(display), words,
                         (unsigned) (sizeof words / sizeof words[0]));
            Class ctxClass = NSClassFromString(@"CAContext");
            dump_class("ctxcls", (id) ctxClass);
            if (ctxClass) {
                dump_methods("ctxmaker", object_getClass((id) ctxClass), NULL, 0);
            }
        }
        {
            static const char *candidates[] = {
                "context", "contextId", "layer", "rootLayer", "displayLayer",
                "surface", "mainDisplay", "contexts"
            };
            for (unsigned i = 0; i < sizeof candidates / sizeof candidates[0]; i++) {
                const SEL sel = NSSelectorFromString([NSString stringWithUTF8String:candidates[i]]);
                const BOOL has = ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(display, @selector(respondsToSelector:), sel);
                id value = nil;
                if (has) {
                    @try { value = ((id (*)(id, SEL)) objc_msgSend)(display, sel); }
                    @catch (NSException *exception) { value = nil; }
                }
                snprintf(detail, sizeof detail, "%s has=%d value=%d", candidates[i], has ? 1 : 0, value ? 1 : 0);
                caller("disp", "cand", detail);
            }
        }
        if (!context) {
            /* H272n: ctx is always 0 inside backboardd, and the old `return` here meant
             * presentSurface:/allContexts were never reached in any round.  Keep walking
             * - the direct-present path needs no context at all. */
            caller("disp", "context", "none, continue");
        }
        id root = nil;
        const SEL layerSel = NSSelectorFromString(@"layer");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(context, @selector(respondsToSelector:), layerSel)) {
            root = ((id (*)(id, SEL)) objc_msgSend)(context, layerSel);
        }
        snprintf(detail, sizeof detail, "%s root=%d rootclass=%.40s", why, root ? 1 : 0,
                 root ? object_getClassName(root) : "-");
        caller("disp", "root", detail);

        id layer = ((id (*)(id, SEL)) objc_msgSend)(((id (*)(id, SEL)) objc_msgSend)(layerClass, @selector(alloc)), @selector(init));
        if (!layer) {
            caller("disp", why, "layer=nil");
            return;
        }
        if (device) {
            ((void (*)(id, SEL, id)) objc_msgSend)(layer, @selector(setDevice:), device);
        }
        const SEL setScale = NSSelectorFromString(@"setContentsScale:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setScale)) {
            ((void (*)(id, SEL, double)) objc_msgSend)(layer, setScale, 3.0);
        }
        /* The layer has to cover the display in the display's own coordinates. */
        const CGRect frame = bounds.size.width > 0 ? bounds : CGRectMake(0, 0, 360, 640);
        const SEL setFrame = NSSelectorFromString(@"setFrame:");
        const SEL setBounds = NSSelectorFromString(@"setBounds:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setFrame)) {
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(layer, setFrame, frame);
        } else if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setBounds)) {
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(layer, setBounds, CGRectMake(0, 0, frame.size.width, frame.size.height));
        }
        const SEL setOpaque = NSSelectorFromString(@"setOpaque:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setOpaque)) {
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(layer, setOpaque, YES);
        }
        const SEL setGravity = NSSelectorFromString(@"setContentsGravity:");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setGravity)) {
            ((void (*)(id, SEL, id)) objc_msgSend)(layer, setGravity, @"resizeAspect");
        }

        /* Attach.  addSublayer: on the display's own layer is preferred: the context's
         * -setLayer: would replace the root and is the more invasive of the two. */
        bool attached = false;
        const SEL addSublayer = NSSelectorFromString(@"addSublayer:");
        if (root && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(root, @selector(respondsToSelector:), addSublayer)) {
            @try { ((void (*)(id, SEL, id)) objc_msgSend)(root, addSublayer, layer); attached = true; }
            @catch (NSException *exception) { caller("disp", "sublayer", "exception"); }
        }
        if (!attached && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(context, @selector(respondsToSelector:), NSSelectorFromString(@"setLayer:"))) {
            @try { ((void (*)(id, SEL, id)) objc_msgSend)(context, NSSelectorFromString(@"setLayer:"), layer); attached = true; }
            @catch (NSException *exception) { caller("disp", "setLayer", "exception"); }
        }
        snprintf(detail, sizeof detail, "%s attached=%d frame=%.0fx%.0f opaque=1", why, attached ? 1 : 0,
                 frame.size.width, frame.size.height);
        caller("disp", "attach", detail);
        if (attached) {
            attachedOnce = true;
        }
        if (!attached) {
            /* H272m: keep going anyway.  presentSurface: does not need a layer, so a
             * failed attach must not stop the direct-present path below. */
            caller("disp", "attach", "none, continue");
        }

        id drawable = nil;
        @try { drawable = ((id (*)(id, SEL)) objc_msgSend)(layer, @selector(nextDrawable)); }
        @catch (NSException *exception) { caller("disp", "drawable", "exception"); }
        if (!drawable) {
            caller("disp", "drawable", "nil");
            return;
        }
        id texture = nil;
        const SEL textureSel = NSSelectorFromString(@"texture");
        if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(drawable, @selector(respondsToSelector:), textureSel)) {
            texture = ((id (*)(id, SEL)) objc_msgSend)(drawable, textureSel);
        }
        void *surface = NULL;
        if (texture && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(texture, @selector(respondsToSelector:), @selector(iosurface))) {
            surface = (void *) (uintptr_t) [texture iosurface];
        }
        unsigned long long filled = 0;
        void *(*surfaceBase)(void *) = (void *(*)(void *)) dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
        size_t (*surfaceAlloc)(void *) = (size_t (*)(void *)) dlsym(RTLD_DEFAULT, "IOSurfaceGetAllocSize");
        if (surface && surfaceBase && surfaceAlloc) {
            void *base = surfaceBase(surface);
            const size_t bytes = surfaceAlloc(surface);
            if (base && bytes) {
                memset(base, 0x80, bytes);
                filled = (unsigned long long) bytes;
            }
        }
        snprintf(detail, sizeof detail, "%s surface=%d bytes=%llu", why, surface ? 1 : 0, filled);
        caller("disp", "fill", detail);

        /* H272m path 1: hand the filled surface straight to the display.  This is the
         * shortest route to the panel and does not involve any CA context, layer tree
         * or compositor pass.  Options are passed as an empty dictionary first; the
         * answer (accepted / exception / no-such-selector) is the whole point. */
        if (surface) {
            const SEL presentSel = NSSelectorFromString(@"presentSurface:withOptions:");
            if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(display, @selector(respondsToSelector:), presentSel)) {
                @try {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(display, presentSel, (__bridge id) surface, @{});
                    caller("disp", "presentsurface", "sent");
                } @catch (NSException *exception) {
                    char reason[110];
                    snprintf(reason, sizeof reason, "exception %.90s",
                             exception.reason ? [exception.reason UTF8String] : "?");
                    caller("disp", "presentsurface", reason);
                }
            } else {
                caller("disp", "presentsurface", "no-selector");
            }
        } else {
            caller("disp", "presentsurface", "no-surface");
        }

        /* H272m path 2: enumerate existing contexts.  +allContexts answers whether the
         * render server keeps any client context at all; if one exists, its -layer is a
         * real mount point even though the display object has none. */
        {
            Class ctxClass = NSClassFromString(@"CAContext");
            const SEL allSel = NSSelectorFromString(@"allContexts");
            id all = nil;
            if (ctxClass && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(ctxClass, @selector(respondsToSelector:), allSel)) {
                @try { all = ((id (*)(id, SEL)) objc_msgSend)(ctxClass, allSel); }
                @catch (id ignored) { all = nil; }
            }
            const unsigned long long n = all ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(all, @selector(count)) : 0;
            snprintf(detail, sizeof detail, "%s allctx=%llu", why, all ? n : 0ULL);
            caller("disp", "allcontexts", detail);
            for (unsigned long long i = 0; all && i < n && i < 2; i++) {
                id ctx = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(all, @selector(objectAtIndex:), i);
                id root = nil;
                const SEL layerSel = NSSelectorFromString(@"layer");
                if (ctx && ((BOOL (*)(id, SEL, SEL)) objc_msgSend)(ctx, @selector(respondsToSelector:), layerSel)) {
                    root = ((id (*)(id, SEL)) objc_msgSend)(ctx, layerSel);
                }
                snprintf(detail, sizeof detail, "%s ctx[%llu]=%d root=%d rootcls=%.30s", why, i,
                         ctx ? 1 : 0, root ? 1 : 0, root ? object_getClassName(root) : "-");
                caller("disp", "allcontexts", detail);
                if (root) {
                    const SEL addSublayer = NSSelectorFromString(@"addSublayer:");
                    if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(root, @selector(respondsToSelector:), addSublayer)) {
                        @try {
                            ((void (*)(id, SEL, id)) objc_msgSend)(root, addSublayer, layer);
                            caller("disp", "allcontexts", "sublayer=added");
                        } @catch (NSException *exception) {
                            caller("disp", "allcontexts", "sublayer=exception");
                        }
                    }
                }
            }
        }

        /* Two paths to the panel: the drawable's own present, and -setContents: with the
         * surface, which is what a plain CALayer would use.  Either landing on the panel
         * answers the question. */
        @try {
            ((void (*)(id, SEL)) objc_msgSend)(drawable, @selector(present));
            caller("disp", "present", "sent");
        } @catch (NSException *exception) {
            caller("disp", "present", "exception");
        }
        if (surface) {
            const SEL setContents = NSSelectorFromString(@"setContents:");
            if (((BOOL (*)(id, SEL, SEL)) objc_msgSend)(layer, @selector(respondsToSelector:), setContents)) {
                @try {
                    ((void (*)(id, SEL, id)) objc_msgSend)(layer, setContents, (__bridge id) surface);
                    caller("disp", "contents", "set");
                } @catch (NSException *exception) {
                    caller("disp", "contents", "exception");
                }
            }
        }
    } @catch (NSException *exception) {
        char detail[170];
        snprintf(detail, sizeof detail, "%s exception %.80s: %.50s", why,
                 exception.name ? [exception.name UTF8String] : "?",
                 exception.reason ? [exception.reason UTF8String] : "?");
        caller("disp", why, detail);
    }
}

/* H272f: drive the display walk from bundle load, not from device init.  The last
 * three runs died at ~157-209 s while the Metal device was only built at 213-289 s,
 * so a device-init-scheduled probe can never be reached.  Five attempts, 30 s apart,
 * all before the death window. */
/* libSystem exports getprogname(), but the stdlib declaration is hidden behind
 * __DARWIN_C_FULL and this bundle builds with -std=c++17.  Declare it directly. */
extern "C" const char *getprogname(void);

__attribute__((constructor)) static void a540_early_display_probe(void)
{
    /* H272g: no process gate.  +[CAWindowServer serverIfRunning] already returns nil
     * outside the render server, so the name check was redundant - and it was the
     * reason H272f produced five silent early returns (NSProcessInfo is not reliable
     * this early).  getprogname() is pure libc and works at construction time.
     * Every path logs: a zero-line round must never be ambiguous again. */
    const char *name = getprogname();
    char detail[120];
    snprintf(detail, sizeof detail, "comm=%s repeats=60..200/15s", name ? name : "?");
    caller("builder", "load", detail);
    /* H272j: dump the menus synchronously here.  The queues flush once the
     * accelerator connection exists, so these lines survive even when the boot dies
     * before the first timer would have fired (191-215 s in the last two runs). */
    Class serverClass = NSClassFromString(@"CAWindowServer");
    Class ctxClass = NSClassFromString(@"CAContext");
    snprintf(detail, sizeof detail, "early server=%d ctx=%d", serverClass ? 1 : 0, ctxClass ? 1 : 0);
    caller("builder", "early", detail);
    if (serverClass) {
        dump_class("server", (id) serverClass);
        dump_methods("server", serverClass, NULL, 0);
        id srv = nil;
        @try { srv = ((id (*)(id, SEL)) objc_msgSend)(serverClass, @selector(serverIfRunning)); }
        @catch (id ignored) { srv = nil; }
        if (srv) {
            id list = nil;
            @try { list = ((id (*)(id, SEL)) objc_msgSend)(srv, @selector(displays)); }
            @catch (id ignored) { list = nil; }
            const unsigned long long n = list ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(list, @selector(count)) : 0;
            snprintf(detail, sizeof detail, "early srv=1 displays=%llu", n);
            caller("builder", "early", detail);
            if (n) {
                id display = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(list, @selector(objectAtIndex:), 0ULL);
                static const char *words[] = {
                    "ontext", "ayer", "urface", "resent", "wap", "oot", "ost",
                    "ree", "uffer", "rawable", "indow", "ort", "rame", "_"
                };
                dump_class("disp", display);
                dump_methods("disp", object_getClass(display), words,
                             (unsigned) (sizeof words / sizeof words[0]));
            }
        } else {
            caller("builder", "early", "srv=nil");
        }
    }
    if (ctxClass) {
        dump_class("ctxcls", (id) ctxClass);
        dump_methods("ctxmaker", object_getClass((id) ctxClass), NULL, 0);
    }
    for (double delay = 60.0; delay <= 200.0; delay += 15.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            /* Stops by itself once a layer is attached (idempotent latch inside). */
            probe_display_frame("early");
        });
    }
}

static void schedule_display_probes(void)
{
    static bool scheduled;
    if (scheduled) return;
    scheduled = true;
    for (double delay = 2.0; delay <= 50.0; delay += 16.0) {
        const int64_t nanos = (int64_t) (delay * 1e9);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nanos), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            probe_displays("timer");
            probe_services();
        });
    }
    // H236iq: ten rounds ten seconds apart, so the log shows whether com.apple.lsd appears at all.
    for (unsigned round = 0; round < 10; ++round) {
        const int64_t lateness = (int64_t) ((30.0 + round * 10.0) * 1e9);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, lateness), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            probe_lsd(round);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (45.0 * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        fix_persona();
    });
    /* H272: the layer question, asked three times: before the render server is up,
     * while backboardd is stable, and past the ~192 s mark where the scene request
     * sometimes appears. */
    for (double delay = 40.0; delay <= 200.0; delay += 80.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            probe_drawable("timer");
        });
    }
    /* H272b: the context/present walk starts later, once the render server has had
     * a chance to publish a display, and repeats past the 189 s mark where
     * SpringBoard only begins to talk. */
    for (double delay = 120.0; delay <= 280.0; delay += 80.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            probe_first_frame("frame");
            /* H272e: the display walk used to have its own dispatch_after(240 s), but
             * the Metal device is only initialised at 213-289 s depending on the boot,
             * so that timer landed past the end of the run.  Chain it instead: if the
             * frame probe fired at all, the display probe fires in the same breath. */
            probe_display_frame("disp");
        });
    }
    /* H272d: the display-context walk.  Two attempts, both after the ~190 s mark where
     * SpringBoard starts talking, so a failure is not confused with "not yet ready". */
    for (double delay = 90.0; delay <= 170.0; delay += 80.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            probe_display_frame("disp");
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (60.0 * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        probe_gestalt_cache();
        /* H247: the forced restart resets SpringBoard's own startup at ~237 s and
         * makes the natural boot sequence unobservable.  Disabled for this round. */
        caller("ca", "restart", "skipped-h247");
        for (double delay = 12.0; delay <= 60.0; delay += 16.0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * 1e9)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                probe_displays("after");
            });
        }
    });
}

/** H236hi: Metal's assertion fires with no message we can see (backboardd is a
 *  platform process; its stderr is not in the kernel log).  The plugin installs
 *  a signal handler that reports the fault address and the frame-pointer chain
 *  through the ABI log, so the aborting image and offset can be resolved
 *  offline against the extracted dyld cache. */
static void report_signal(int number, siginfo_t *info, void *context)
{
    ucontext_t *state = (ucontext_t *) context;
    char line[184];
    unsigned long long pc = state ? (unsigned long long) state->uc_mcontext->__ss.__pc : 0;
    unsigned long long lr = state ? (unsigned long long) state->uc_mcontext->__ss.__lr : 0;
    unsigned long long sp = state ? (unsigned long long) state->uc_mcontext->__ss.__sp : 0;
    unsigned long long fp = state ? (unsigned long long) state->uc_mcontext->__ss.__fp : 0;
    snprintf(line, sizeof line, "signal=%d addr=0x%llx pc=0x%llx lr=0x%llx sp=0x%llx",
             number, (unsigned long long) (info ? (unsigned long long) (uintptr_t) info->si_addr : 0), pc, lr, sp);
    emit(line);
    for (unsigned depth = 0; depth < 6 && fp; ++depth) {
        const unsigned long long *frame = (const unsigned long long *) (uintptr_t) fp;
        snprintf(line, sizeof line, "frame%d fp=0x%llx ret=0x%llx", depth, fp,
                 frame ? (unsigned long long) frame[1] : 0);
        emit(line);
        fp = frame ? frame[0] : 0;
        if (sp && (fp < sp || fp - sp > 0x20000)) break;
    }
    signal(number, SIG_DFL);
    raise(number);
}

static void install_crash_reporter(void)
{
    static bool installed;
    if (installed) return;
    installed = true;
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = report_signal;
    action.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGABRT, &action, NULL);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGILL, &action, NULL);
}

static bool connectAccelerator(void)
{
    if (gConnection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOAcceleratorES"));
    if (!service) return false;
    io_connect_t connection = 0;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS || !connection) return false;
    gConnection = connection;
    uint32_t probe[2] = { kTunnelMagic, 0xffffffffu };
    for (uint32_t selector = 0; selector < 256; ++selector) {
        if (IOConnectCallStructMethod(connection, selector, probe, sizeof probe, NULL, NULL) == KERN_SUCCESS) {
            gSelector = selector;
            return true;
        }
    }
    return false;
}

/* H236hb: the plugin's own path to the GPU.  This is the first half of C6a:
 *  the device Metal builds has to be able to allocate, map, submit and fence
 *  real work through the native Adreno ABI from inside the hosting process
 *  (backboardd), under its sandbox.  The sequence mirrors the userspace test
 *  that runs from the probe daemon, but every step reports its own failure so
 *  the kernel log shows exactly where it stops. */
static uint32_t abi_call_rc(uint32_t method, const void *input, size_t inputSize, void *output, size_t outputSize)
{
    struct { uint32_t magic, method; uint8_t payload[512]; } request;
    if (inputSize > sizeof request.payload) return 0xe00002c2u; /* kIOReturnBadArgument */
    memset(&request, 0, sizeof request);
    request.magic = kTunnelMagic;
    request.method = method;
    if (inputSize) memcpy(request.payload, input, inputSize);
    size_t size = outputSize;
    return (uint32_t) IOConnectCallStructMethod(gConnection, gSelector, &request, 8 + inputSize, output, &size);
}

static int abi_call(uint32_t method, const void *input, size_t inputSize, void *output, size_t outputSize)
{
    return abi_call_rc(method, input, inputSize, output, outputSize) == KERN_SUCCESS ? 0 : -1;
}

static uint32_t pm4_type7(uint32_t opcode, uint32_t count)
{
    return (3u << 30) | ((opcode & 0x7fu) << 16) | (count & 0x3fffu);
}

static void gpu_selftest(void)
{
    char line[160];
    NativeAdrenoAbiParams params;
    if (abi_call(NativeAdrenoMethodQuery, NULL, 0, &params, sizeof params)) { caller("gpu", "query", "failed"); return; }
    snprintf(line, sizeof line, "abi=0x%x in=%u out=%u maxbo=%llu", params.abi_version,
             params.input_bits, params.output_bits, (unsigned long long) params.max_bo_bytes);
    caller("gpu", "query", line);

    NativeAdrenoAbiDeviceInfo info;
    if (abi_call(NativeAdrenoMethodGetDeviceInfo, NULL, 0, &info, sizeof info)) { caller("gpu", "info", "failed"); return; }
    snprintf(line, sizeof line, "chip=0x%x gmem=%u va=0x%llx+0x%llx",
             info.chip_id, info.gmem_bytes, (unsigned long long) info.va_start, (unsigned long long) info.va_size);
    caller("gpu", "info", line);

    NativeAdrenoAbiBoAlloc request = { 4096, 12, 0 };
    NativeAdrenoAbiBoAllocReply ib, target;
    if (abi_call(NativeAdrenoMethodBoAlloc, &request, sizeof request, &ib, sizeof ib)) { caller("gpu", "boalloc-ib", "failed"); return; }
    if (abi_call(NativeAdrenoMethodBoAlloc, &request, sizeof request, &target, sizeof target)) { caller("gpu", "boalloc-target", "failed"); return; }

    const uint64_t ibIova = info.va_start;
    const uint64_t targetIova = info.va_start + 0x1000;
    NativeAdrenoAbiBoMap mapIb = { ib.handle, ibIova, 1, 0, 2, 0 };
    NativeAdrenoAbiBoMap mapTarget = { target.handle, targetIova, 3, 0, 2, 0 };
    NativeAdrenoAbiBoMapReply mapped;
    if (abi_call(NativeAdrenoMethodBoMap, &mapIb, sizeof mapIb, &mapped, sizeof mapped)) { caller("gpu", "bomap-ib", "failed"); return; }
    if (abi_call(NativeAdrenoMethodBoMap, &mapTarget, sizeof mapTarget, &mapped, sizeof mapped)) { caller("gpu", "bomap-target", "failed"); return; }

    NativeAdrenoAbiBoCpuMap cpuIb = { ib.handle }, cpuTarget = { target.handle };
    NativeAdrenoAbiBoCpuMapReply tokenIb, tokenTarget;
    if (abi_call(NativeAdrenoMethodBoCpuMap, &cpuIb, sizeof cpuIb, &tokenIb, sizeof tokenIb)) { caller("gpu", "cpumap-ib", "failed"); return; }
    if (abi_call(NativeAdrenoMethodBoCpuMap, &cpuTarget, sizeof cpuTarget, &tokenTarget, sizeof tokenTarget)) { caller("gpu", "cpumap-target", "failed"); return; }

    mach_vm_address_t ibAddress = 0, targetAddress = 0;
    mach_vm_size_t ibLength = 0, targetLength = 0;
    // The driver hands back an uncached view of the BO's raw spans, which is
    // what the userspace test maps: kIOMapAnywhere | kIOMapInhibitCache.
    const IOOptionBits mapOptions = kIOMapAnywhere | kIOMapInhibitCache;
    kern_return_t mapStatus = IOConnectMapMemory64(gConnection, tokenIb.token, mach_task_self(), &ibAddress, &ibLength, mapOptions);
    if (mapStatus != KERN_SUCCESS) {
        snprintf(line, sizeof line, "kr=0x%x options=0x%x", mapStatus, (unsigned) mapOptions);
        caller("gpu", "map-ib", line);
        return;
    }
    mapStatus = IOConnectMapMemory64(gConnection, tokenTarget.token, mach_task_self(), &targetAddress, &targetLength, mapOptions);
    if (mapStatus != KERN_SUCCESS) {
        snprintf(line, sizeof line, "kr=0x%x options=0x%x", mapStatus, (unsigned) mapOptions);
        caller("gpu", "map-target", line);
        return;
    }
    snprintf(line, sizeof line, "ib=%llu target=%llu", (unsigned long long) ibLength, (unsigned long long) targetLength);
    caller("gpu", "mapped", line);

    volatile uint32_t *targetWords = (volatile uint32_t *) (uintptr_t) targetAddress;
    volatile uint32_t *ibWords = (volatile uint32_t *) (uintptr_t) ibAddress;
    for (unsigned i = 0; i < 1024; ++i) targetWords[i] = 0xdeadbeefu;

    const uint32_t values[3] = { 0x0adc0de1u, 0xfeed0002u, 0x600d0003u };
    unsigned w = 0;
    for (unsigned i = 0; i < 3; ++i) {
        ibWords[w++] = pm4_type7(0x3d /* CP_MEM_WRITE */, 3);
        ibWords[w++] = (uint32_t) (targetIova + i * 4);
        ibWords[w++] = (uint32_t) ((targetIova + i * 4) >> 32);
        ibWords[w++] = values[i];
    }
    __asm__ volatile("dsb sy" ::: "memory");   // the mapping is non-cacheable; the GPU is an outer-shareable observer

    NativeAdrenoAbiSubmit submit;
    memset(&submit, 0, sizeof submit);
    submit.buffer_count = 1;
    submit.buffers[0].handle = ib.handle;
    submit.buffers[0].iova = ibIova;
    submit.buffers[0].bytes = w * 4;
    NativeAdrenoAbiSubmitReply reply;
    if (abi_call(NativeAdrenoMethodSubmit, &submit, sizeof submit, &reply, sizeof reply)) { caller("gpu", "submit", "failed"); return; }

    NativeAdrenoAbiTimestamp before, after;
    const bool haveBefore = abi_call(NativeAdrenoMethodGetTimestamp, NULL, 0, &before, sizeof before) == 0;
    NativeAdrenoAbiWaitFence wait = { reply.fence, 200000000ull };
    if (abi_call(NativeAdrenoMethodWaitFence, &wait, sizeof wait, NULL, 0)) {
        // A fence that never completes means the CP did not run the buffer.
        // The GPU clock and the fault counters say whether the CP is alive at
        // all (NaN: the timestamp method itself is unsupported).
        const bool haveAfter = abi_call(NativeAdrenoMethodGetTimestamp, NULL, 0, &after, sizeof after) == 0;
        NativeAdrenoAbiStatus status = { 0, 0 };
        abi_call(NativeAdrenoMethodGetStatus, NULL, 0, &status, sizeof status);
        snprintf(line, sizeof line, "fence=%llu ticks=%llu->%llu faults=%llu suspends=%llu",
                 (unsigned long long) reply.fence,
                 (unsigned long long) (haveBefore ? before.ticks : 0),
                 (unsigned long long) (haveAfter ? after.ticks : 0),
                 (unsigned long long) status.faults, (unsigned long long) status.suspends);
        caller("gpu", "fence", line);
        return;
    }

    __asm__ volatile("dsb sy" ::: "memory");
    const unsigned hits = (targetWords[0] == values[0]) + (targetWords[1] == values[1]) +
                          (targetWords[2] == values[2]) + (targetWords[3] == 0xdeadbeefu);
    snprintf(line, sizeof line, "hits=%u/%u fence=%llu t0=%08x t3=%08x", hits, 4u,
             (unsigned long long) reply.fence, targetWords[0], targetWords[3]);
    caller("gpu", "selftest", line);
}

static id trace_object(const char *kind);
static id trace_object_of(const char *className, const char *kind);

/** H236gt: the abandon point is newCommandQueue, so the queue itself has to be
 *  traced too.  It is an opaque object for Metal (a plugin builds both), and
 *  every selector the renderer sends that is not implemented is reported. */
@interface A540TraceQueue : NSObject
@end

/* Private initialiser of _MTLCommandBuffer (Metal 0x187A7C318): the only place
 * that writes _queue, without which -commit is a silent no-op. */
@interface NSObject (A540TraceCommandBufferInit)
- (id)initWithQueue:(id)queue retainedReferences:(BOOL)retained synchronousDebugMode:(BOOL)synchronous;
@end

@implementation A540TraceQueue

/** H236hq: the base _MTLCommandBuffer writes _queue only in
 *  -initWithQueue:retainedReferences:synchronousDebugMode: (Metal 0x187A7C318);
 *  without it -commit/-enqueue are silent no-ops and -waitUntilCompleted waits
 *  forever (0x187AC6180).  The queue hands out buffers created through that
 *  initialiser and answers the two messages the base -commit sends. */
- (id)commandBuffer
{
    /* H236hq: the private initialiser dereferences Metal state at +0x30 that only
     * a real _MTLCommandBuffer owns, so calling it on a runtime subclass
     * segfaults (addr=0x30 right after this method).  The self-completing stub
     * that kept ho's composition path alive is therefore kept; -commit's
     * semantics can only be exercised once a real buffer exists. */
    id buffer = trace_object_of("_MTLCommandBuffer", "cmdbuf");
    caller("queue", "commandBuffer", "self-completing");
    return buffer;
}

- (void)enqueueCommandBuffer:(id)buffer
{
    caller("queue", "enqueueCommandBuffer:", buffer ? "buffer=1" : "buffer=0");
}

- (void)commitCommandBuffer:(id)buffer wake:(BOOL)wake
{
    caller("queue", "commitCommandBuffer:wake:", wake ? "wake=1" : "wake=0");
    if ([buffer respondsToSelector:@selector(commandBufferDidComplete:startTime:completionTime:error:)])
        [self commandBufferDidComplete:buffer startTime:0 completionTime:0 error:nil];
}

/* Signature confirmed from Metal 0x187A8A380: the two times arrive in x3/x4,
 * i.e. uint64_t, not double. */
- (void)commandBufferDidComplete:(id)buffer
                       startTime:(unsigned long long)start
                  completionTime:(unsigned long long)completion
                           error:(id)error
{
    char detail[96];
    snprintf(detail, sizeof detail, "buffer=%d start=%llu end=%llu",
             buffer ? 1 : 0, start, completion);
    caller("queue", "commandBufferDidComplete:", detail);
}

/** H236hl: Metal sends a stream of private void setters (setSubmissionQueue:,
 *  setCompletionQueue:, setGPUPriority:, …).  Answering one by letting
 *  -doesNotRecognizeSelector: return leaves the caller with a value it does not
 *  expect and CoreFoundation traps (SIGILL right after setGPUPriority:), so a
 *  generic void setter forwarder answers all of them and logs the name. */
/** H236hn: after the depth/stencil state the renderer's stream is not only
 *  `set…:` (the blit pass sends copyFromTexture:…).  Every unimplemented
 *  selector with arguments is answered as a void method taking that many
 *  objects — the colon count is the argument count — and logged. */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    static char types[16][64];
    static unsigned slot;
    const char *name = sel_getName(selector);
    unsigned arguments = 0;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == ':') ++arguments;
    if (arguments && arguments <= 12) {
        char *text = types[slot++ & 15];
        unsigned at = 0;
        text[at++] = 'v';
        text[at++] = '@';
        text[at++] = ':';
        for (unsigned index = 0; index < arguments; ++index) text[at++] = '@';
        text[at] = 0;
        return [NSMethodSignature signatureWithObjCTypes:text];
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    caller("queue", "forward:", sel_getName([invocation selector]));
}

- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("queue", "doesNotRecognize:", sel_getName(selector));
}

- (id)newCommandBuffer { caller("queue", "newCommandBuffer", ""); return trace_object_of("_MTLCommandBuffer", "cmdbuf"); }
- (id)commandBufferWithDescriptor:(id)descriptor
{
    caller("queue", "commandBufferWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLCommandBuffer", "cmdbuf");
}
- (void)setLabel:(id)label { caller("queue", "setLabel:", label ? "label=1" : "label=0"); }
- (id)device { caller("queue", "device", ""); return gDeviceInstance; }
- (unsigned long long)maxCommandBufferCount { caller("queue", "maxCommandBufferCount", ""); return 64; }
/** H236gv: after -setLabel: Metal hands the queue its IO submission queue
 *  through this private setter; returning nil here (unimplemented) is exactly
 *  where it gave up.  The argument is recorded, nothing else. */
- (void)setSubmissionQueue:(id)submission
{
    caller("queue", "setSubmissionQueue:", submission ? "submission=1" : "submission=0");
}

/** H236gw: the renderer installs the queue's IO mailboxes one setter at a time
 *  (submission queue, then completion queue); each unimplemented one ends the
 *  attempt.  Every void setter is accepted and recorded in one place. */
- (void)setCompletionQueue:(id)completion
{
    caller("queue", "setCompletionQueue:", completion ? "completion=1" : "completion=0");
}

- (void)setCommandBufferQueue:(id)value { caller("queue", "setCommandBufferQueue:", value ? "value=1" : "value=0"); }
- (void)setPriority:(id)value { caller("queue", "setPriority:", value ? "value=1" : "value=0"); }
- (void)setPurgeableState:(id)value { caller("queue", "setPurgeableState:", value ? "value=1" : "value=0"); }

- (void)insertDebugCaptureBoundary { caller("queue", "insertDebugCaptureBoundary", ""); }
- (void)dealloc { caller("queue", "dealloc", ""); }

@end

/** H236ha: every creation call must answer an object.  The published bridge
 *  device does the same (nmb_* handles) and Metal then carries on to its device
 *  information queries; answering nil instead makes Metal dereference NULL in
 *  its own bookkeeping (gz: SIGSEGV 38 ms after the depth/stencil state). */
/* H236hp: the stub objects derive from the real Metal classes but cannot carry
 * our own ivars, so their scalar answers live in a side table filled from the
 * descriptors they were created with.  Without this, -width/-pixelFormat/etc.
 * run the real (uninitialised) implementations and return garbage with no log
 * line, which is what made CoreAnimation drop every frame in ho. */
struct TraceStorage {
    __unsafe_unretained id object;
    unsigned long long length, width, height, pixelFormat, textureType, storageMode;
    unsigned long long mipmaps, samples, usage, arrayLength, gpuAddress;
    void *contents;
    void *iosurface;             /* H236hs: the drawable's surface, when there is one */
    unsigned long long plane, bytesPerRow;
};

static struct TraceStorage gStorage[512];
static unsigned gStorageCount;

static struct TraceStorage *storage_for(id object, bool create)
{
    for (unsigned index = 0; index < gStorageCount; ++index)
        if (gStorage[index].object == object) return &gStorage[index];
    if (!create || gStorageCount >= 512) return NULL;
    struct TraceStorage *entry = &gStorage[gStorageCount++];
    memset(entry, 0, sizeof *entry);
    entry->object = object;
    return entry;
}

/* H236hs: the presentable surface.  CoreAnimation hands the render server a
 * drawable only through -newTextureWithDescriptor:iosurface:plane:, and the
 * surface behind it is what a present would put on the panel.  The plugin
 * records the surface on the texture it made, and offers it once to the display
 * hand-off (boot-arg sheng-fb-gpu=1) so the log answers whether the plugin can
 * reach the panel at all.  The IOSurface queries are resolved by name: this
 * bundle links no IOSurface framework. */
typedef struct __IOSurface *A540Surface;
typedef size_t (*A540SurfaceQuery)(A540Surface);

static A540SurfaceQuery gSurfaceWidth, gSurfaceHeight, gSurfaceRowBytes, gSurfaceAllocSize;
static void *(*gSurfaceBase)(A540Surface);
static uint32_t (*gSurfaceID)(A540Surface);

static void load_surface_queries(void)
{
    static bool tried;
    if (tried) return;
    tried = true;
    gSurfaceWidth = (A540SurfaceQuery) dlsym(RTLD_DEFAULT, "IOSurfaceGetWidth");
    gSurfaceHeight = (A540SurfaceQuery) dlsym(RTLD_DEFAULT, "IOSurfaceGetHeight");
    gSurfaceRowBytes = (A540SurfaceQuery) dlsym(RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
    gSurfaceAllocSize = (A540SurfaceQuery) dlsym(RTLD_DEFAULT, "IOSurfaceGetAllocSize");
    gSurfaceBase = (void *(*)(A540Surface)) dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
    gSurfaceID = (uint32_t (*)(A540Surface)) dlsym(RTLD_DEFAULT, "IOSurfaceGetID");
}

/* One attempt per boot: whether the display driver's GPU hand-off answers on this
 * connection decides whether a presented surface can reach the panel from here. */
static void offer_surface_to_display(void *surface, const char *sel)
{
    if (!surface) { caller("cmdbuf", sel, "display=no-surface"); return; }
    static bool probed;
    if (probed) return;
    probed = true;
    load_surface_queries();
    if (!gSurfaceBase || !gSurfaceWidth || !gSurfaceHeight || !gSurfaceRowBytes || !gSurfaceAllocSize) {
        caller("cmdbuf", sel, "display=no-iosurface-api");
        return;
    }
    struct { uint32_t version, format; uint64_t width, height, stride, bytes; } mode;
    memset(&mode, 0, sizeof mode);
    uint32_t status = abi_call_rc(0x7000, NULL, 0, &mode, sizeof mode);
    char detail[180];
    if (status) {
        snprintf(detail, sizeof detail, "display=no-handoff rc=0x%x", status);
        caller("cmdbuf", sel, detail);
        return;
    }
    snprintf(detail, sizeof detail, "display mode=%ux%u stride=%llu bytes=%llu fmt=%u",
             (unsigned) mode.width, (unsigned) mode.height, mode.stride, mode.bytes, mode.format);
    caller("cmdbuf", sel, detail);
    struct { uint64_t address, bytes; uint32_t width, height, stride, format; } present;
    memset(&present, 0, sizeof present);
    present.address = (uint64_t) (uintptr_t) gSurfaceBase((A540Surface) surface);
    present.bytes = (uint64_t) gSurfaceAllocSize((A540Surface) surface);
    present.width = (uint32_t) gSurfaceWidth((A540Surface) surface);
    present.height = (uint32_t) gSurfaceHeight((A540Surface) surface);
    present.stride = (uint32_t) gSurfaceRowBytes((A540Surface) surface);
    present.format = 1;   /* NGP_BGRX8888 */
    struct { uint64_t sequence, bytes; } transfer;
    memset(&transfer, 0, sizeof transfer);
    status = abi_call_rc(0x7001, &present, sizeof present, &transfer, sizeof transfer);
    snprintf(detail, sizeof detail, "display present rc=0x%x seq=%llu bytes=%llu src=%ux%u stride=%u",
             status, transfer.sequence, transfer.bytes, present.width, present.height, present.stride);
    caller("cmdbuf", sel, detail);
}

/* The drawable is CoreAnimation's object: its texture is the surface's texture. */
static void present_drawable(id drawable, const char *sel)
{
    char detail[180];
    if (!drawable) { caller("cmdbuf", sel, "drawable=0"); return; }
    id texture = [drawable respondsToSelector:@selector(texture)] ? [drawable texture] : nil;
    void *surface = nil;
    if (texture && [texture respondsToSelector:@selector(iosurface)])
        surface = (void *) (uintptr_t) [texture iosurface];
    load_surface_queries();
    if (!surface) {
        snprintf(detail, sizeof detail, "drawable=1 texture=%d surface=0", texture ? 1 : 0);
        caller("cmdbuf", sel, detail);
        return;
    }
    snprintf(detail, sizeof detail, "drawable=1 texture=%d surface=1 id=%u %llux%llu stride=%llu bytes=%llu",
             texture ? 1 : 0, gSurfaceID ? gSurfaceID((A540Surface) surface) : 0,
             gSurfaceWidth ? (unsigned long long) gSurfaceWidth((A540Surface) surface) : 0,
             gSurfaceHeight ? (unsigned long long) gSurfaceHeight((A540Surface) surface) : 0,
             gSurfaceRowBytes ? (unsigned long long) gSurfaceRowBytes((A540Surface) surface) : 0,
             gSurfaceAllocSize ? (unsigned long long) gSurfaceAllocSize((A540Surface) surface) : 0);
    caller("cmdbuf", sel, detail);
    offer_surface_to_display(surface, sel);
}

@interface A540TraceObject : NSObject
{
@public
    const char *kind;
}
@end

@implementation A540TraceObject

- (unsigned long long)width { struct TraceStorage *e = storage_for(self, false); return e ? e->width : 0; }
- (unsigned long long)height { struct TraceStorage *e = storage_for(self, false); return e ? e->height : 0; }
- (unsigned long long)depth { return 1; }
- (unsigned long long)pixelFormat { struct TraceStorage *e = storage_for(self, false); return e ? e->pixelFormat : 0; }
- (unsigned long long)textureType { struct TraceStorage *e = storage_for(self, false); return e ? e->textureType : 0; }
- (unsigned long long)storageMode { struct TraceStorage *e = storage_for(self, false); return e ? e->storageMode : 0; }
- (unsigned long long)mipmapLevelCount { struct TraceStorage *e = storage_for(self, false); return (e && e->mipmaps) ? e->mipmaps : 1; }
- (unsigned long long)sampleCount { struct TraceStorage *e = storage_for(self, false); return (e && e->samples) ? e->samples : 1; }
- (unsigned long long)usage { struct TraceStorage *e = storage_for(self, false); return e ? e->usage : 0; }
- (unsigned long long)arrayLength { struct TraceStorage *e = storage_for(self, false); return (e && e->arrayLength) ? e->arrayLength : 1; }
- (unsigned long long)length { struct TraceStorage *e = storage_for(self, false); return e ? e->length : 0; }
- (unsigned long long)gpuAddress { struct TraceStorage *e = storage_for(self, false); return e ? e->gpuAddress : 0; }
- (void *)contents { struct TraceStorage *e = storage_for(self, false); return e ? e->contents : NULL; }
- (void *)iosurface { struct TraceStorage *e = storage_for(self, false); return e ? e->iosurface : NULL; }
- (unsigned long long)iosurfacePlane { struct TraceStorage *e = storage_for(self, false); return e ? e->plane : 0; }
- (unsigned long long)bytesPerRow { struct TraceStorage *e = storage_for(self, false); return e ? e->bytesPerRow : 0; }
- (unsigned long long)bufferOffset { return 0; }
- (unsigned long long)bufferBytesPerRow { struct TraceStorage *e = storage_for(self, false); return e ? e->bytesPerRow : 0; }

/* H260: backboardd asks the render command encoder for its tile geometry every
 * frame (-tileWidth/-tileHeight/-tileDepth; CoreFoundation ____forwarding___
 * + 0x520 with x0=0 was the SIGTRAP that killed it 11 times per boot).  Apple's
 * TBDR tile is 32x32; the values are also logged on first use. */
- (unsigned long long)tileWidth
{
    static unsigned logged;
    if (logged < 4) { logged++; caller("tile", "tileWidth", "32"); }
    return 32;
}
- (unsigned long long)tileHeight
{
    static unsigned logged;
    if (logged < 4) { logged++; caller("tile", "tileHeight", "32"); }
    return 32;
}
/* H268: the draw path is where "a frame exists" becomes measurable.  Count
 * every draw the renderer issues and log the first few plus a summary on commit. */
static unsigned gDrawCalls;
static unsigned long long gDrawPrimitives;

- (void)drawPrimitives:(NSUInteger)type vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount
{
    char detail[80];
    gDrawCalls++;
    gDrawPrimitives += (unsigned long long)vertexCount;
    if (gDrawCalls <= 8 || (gDrawCalls % 32) == 0) {
        snprintf(detail, sizeof detail, "type=%llu count=%llu total=%u prims=%llu",
                 (unsigned long long)type, (unsigned long long)vertexCount,
                 gDrawCalls, gDrawPrimitives);
        caller(kind, "drawPrimitives:vertexStart:vertexCount:", detail);
    }
}

- (void)drawPrimitives:(NSUInteger)type vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount
{
    char detail[80];
    gDrawCalls++;
    gDrawPrimitives += (unsigned long long)vertexCount;
    if (gDrawCalls <= 8 || (gDrawCalls % 32) == 0) {
        snprintf(detail, sizeof detail, "type=%llu count=%llu inst=%llu total=%u",
                 (unsigned long long)type, (unsigned long long)vertexCount,
                 (unsigned long long)instanceCount, gDrawCalls);
        caller(kind, "drawPrimitives:...instanceCount:", detail);
    }
}

- (void)drawIndexedPrimitives:(NSUInteger)type indexCount:(NSUInteger)indexCount indexType:(NSUInteger)indexType indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset
{
    char detail[80];
    gDrawCalls++;
    gDrawPrimitives += (unsigned long long)indexCount;
    if (gDrawCalls <= 8 || (gDrawCalls % 32) == 0) {
        snprintf(detail, sizeof detail, "type=%llu idx=%llu total=%u prims=%llu",
                 (unsigned long long)type, (unsigned long long)indexCount,
                 gDrawCalls, gDrawPrimitives);
        caller(kind, "drawIndexedPrimitives:...", detail);
    }
}

- (void)drawIndexedPrimitives:(NSUInteger)type indexCount:(NSUInteger)indexCount indexType:(NSUInteger)indexType indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount
{
    char detail[80];
    gDrawCalls++;
    gDrawPrimitives += (unsigned long long)indexCount;
    if (gDrawCalls <= 8 || (gDrawCalls % 32) == 0) {
        snprintf(detail, sizeof detail, "type=%llu idx=%llu inst=%llu total=%u",
                 (unsigned long long)type, (unsigned long long)indexCount,
                 (unsigned long long)instanceCount, gDrawCalls);
        caller(kind, "drawIndexedPrimitives:...instanceCount:", detail);
    }
}

- (unsigned long long)tileDepth
{
    static unsigned logged;
    if (logged < 4) { logged++; caller("tile", "tileDepth", "1"); }
    return 1;
}

/** H236hl: Metal sends a stream of private void setters (setSubmissionQueue:,
 *  setCompletionQueue:, setGPUPriority:, …).  Answering one by letting
 *  -doesNotRecognizeSelector: return leaves the caller with a value it does not
 *  expect and CoreFoundation traps (SIGILL right after setGPUPriority:), so a
 *  generic void setter forwarder answers all of them and logs the name. */
/** H236hn: after the depth/stencil state the renderer's stream is not only
 *  `set…:` (the blit pass sends copyFromTexture:…).  Every unimplemented
 *  selector with arguments is answered as a void method taking that many
 *  objects — the colon count is the argument count — and logged. */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    static char types[16][64];
    static unsigned slot;
    const char *name = sel_getName(selector);
    unsigned arguments = 0;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == ':') ++arguments;
    if (arguments && arguments <= 12) {
        char *text = types[slot++ & 15];
        unsigned at = 0;
        text[at++] = 'v';
        text[at++] = '@';
        text[at++] = ':';
        for (unsigned index = 0; index < arguments; ++index) text[at++] = '@';
        text[at] = 0;
        return [NSMethodSignature signatureWithObjCTypes:text];
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    caller("kind", "forward:", sel_getName([invocation selector]));
}

- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller(kind, "doesNotRecognize:", sel_getName(selector));
}

/** H236hm: the render path itself.  After the depth/stencil state and the
 *  textures, CA asks the command buffer for a render command encoder; answering
 *  nothing there ended the run.  The encoders are stubs and the encoding
 *  setters are answered by the generic forwarder, so the first frame reaches
 *  -commit, which is where the driver's own submission will go. */
- (id)renderCommandEncoderWithDescriptor:(id)descriptor
{
    caller(kind, "renderCommandEncoderWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLRenderCommandEncoder", "encoder");
}

- (id)computeCommandEncoderWithDescriptor:(id)descriptor
{
    caller(kind, "computeCommandEncoderWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLComputeCommandEncoder", "encoder");
}

- (id)blitCommandEncoder
{
    caller(kind, "blitCommandEncoder", "");
    return trace_object_of("_MTLBlitCommandEncoder", "encoder");
}

- (id)parallelRenderCommandEncoderWithDescriptor:(id)descriptor
{
    caller(kind, "parallelRenderCommandEncoderWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLParallelRenderCommandEncoder", "encoder");
}

- (void)endEncoding { caller(kind, "endEncoding", ""); }
/** H236hs: the present point.  The drawable's surface is recorded, offered to
 *  the display hand-off, and the frame is completed through the queue, whose
 *  -commandBufferDidComplete: takes uint64_t times (Metal 0x187A8A380: x3/x4). */
- (void)presentDrawable:(id)drawable
{
    present_drawable(drawable, "presentDrawable:");
    if (gQueueInstance && [gQueueInstance respondsToSelector:@selector(commandBufferDidComplete:startTime:completionTime:error:)])
        [gQueueInstance commandBufferDidComplete:self startTime:0 completionTime:0 error:nil];
}
- (void)presentDrawable:(id)drawable atTime:(double)time
{
    char detail[64];
    snprintf(detail, sizeof detail, "at=%llu", (unsigned long long) (time * 1e9));
    caller(kind, "presentDrawable:atTime:", detail);
    [self presentDrawable:drawable];
}
- (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration
{
    char detail[64];
    snprintf(detail, sizeof detail, "after=%llu", (unsigned long long) (duration * 1e9));
    caller(kind, "presentDrawable:afterMinimumDuration:", detail);
    [self presentDrawable:drawable];
}
/* H236ho: Metal's own -commit/-waitUntilCompleted are unusable here.  The base
 * _MTLCommandBuffer keeps _queue only if -initWithQueue:retainedReferences:
 * synchronousDebugMode: ran, and without a queue -commit is a silent no-op
 * while -waitUntilCompleted blocks forever on _status (Metal 0x187AC6180), which
 * is exactly the silent stop after the third render encoder.  The stub is
 * therefore self-completing: it reports status 2 and returns immediately, so the
 * frame pipeline keeps running and the draw path is exercised. */
- (void)commit
{
    caller(kind, "commit", "self-completed");
}

- (void)waitUntilCompleted { caller(kind, "waitUntilCompleted", "immediate"); }
- (void)waitUntilScheduled { caller(kind, "waitUntilScheduled", "immediate"); }
- (unsigned long long)status { caller(kind, "status", "completed"); return 2; }
- (id)error { return nil; }
- (id)device { return gDeviceInstance; }
- (id)commandQueue { return gDeviceInstance ? (id) gQueueInstance : nil; }

- (void)dealloc { caller(kind, "dealloc", ""); }

@end

static id trace_object(const char *kind)
{
    A540TraceObject *object = [[A540TraceObject alloc] init];
    object->kind = kind;
    return object;
}

/** H236hh: Metal's own objects are class-gated (the device itself had to pass
 *  `isSubclassOfClass:`), so a plain NSObject handed back from a creation call
 *  is refused with an assertion (backboardd SIGABRT right after the depth/
 *  stencil state was made).  The stub is therefore built as a runtime subclass
 *  of the real class Metal expects, with the logging methods copied over. */
static id trace_object_of(const char *className, const char *kind)
{
    static struct { const char *name; Class cls; } cache[24];
    static unsigned cached;
    Class base = objc_getClass(className);
    if (!base) return trace_object(kind);
    Class cls = Nil;
    for (unsigned i = 0; i < cached; ++i)
        if (!strcmp(cache[i].name, className)) { cls = cache[i].cls; break; }
    if (!cls) {
        char name[96];
        snprintf(name, sizeof name, "A540Trace_%s", className);
        cls = objc_allocateClassPair(base, name, 0);
        if (!cls) return trace_object(kind);
        unsigned count = 0;
        Method *methods = class_copyMethodList([A540TraceObject class], &count);
        for (unsigned index = 0; index < count; ++index)
            class_addMethod(cls, method_getName(methods[index]),
                            method_getImplementation(methods[index]), method_getTypeEncoding(methods[index]));
        free(methods);
        objc_registerClassPair(cls);
        if (cached < sizeof cache / sizeof cache[0]) { cache[cached].name = className; cache[cached].cls = cls; ++cached; }
    }
    A540TraceObject *object = [[cls alloc] init];
    object->kind = kind;
    return object;
}

/** H236hk: the abort came from +[MTLLoader sliceIDForDevice:...] line 666,
 *  which is `MTLReportFailure` after `[device targetDeviceArchitecture]`
 *  returned nil (Metal +0xa3e4 -> +0x14ef54 = _MTLReportFailure.cold.1).
 *  CA loads a pre-compiled metallib (MTLBinaryArchive) and needs that
 *  architecture object to pick a slice.  The plugin supplies one. */
@interface A540TraceArchitecture : NSObject
@end

@implementation A540TraceArchitecture

- (unsigned)cpuType { caller("arch", "cpuType", ""); return 0x0100000Cu; } /* CPU_TYPE_ARM64 */
- (unsigned)subType { caller("arch", "subType", ""); return 0; }
- (unsigned long long)driverVersion { caller("arch", "driverVersion", ""); return 0; }
- (unsigned)versionCombined { caller("arch", "versionCombined", ""); return 0; }
- (void)doesNotRecognizeSelector:(SEL)selector { caller("arch", "doesNotRecognize:", sel_getName(selector)); }
- (void)dealloc { caller("arch", "dealloc", ""); }

@end

static id trace_architecture(void)
{
    static Class cls;
    static bool tried;
    if (!tried) {
        tried = true;
        Class base = objc_getClass("MTLTargetDeviceArchitecture");
        if (base) {
            cls = objc_allocateClassPair(base, "A540TraceArch", 0);
            if (cls) {
                unsigned count = 0;
                Method *methods = class_copyMethodList([A540TraceArchitecture class], &count);
                for (unsigned index = 0; index < count; ++index)
                    class_addMethod(cls, method_getName(methods[index]),
                                    method_getImplementation(methods[index]), method_getTypeEncoding(methods[index]));
                free(methods);
                objc_registerClassPair(cls);
            }
        }
    }
    id object = cls ? [[cls alloc] init] : [[A540TraceArchitecture alloc] init];
    caller("dev", "targetDeviceArchitecture", cls ? "real-base" : "plain-base");
    return object;
}

@interface A540TraceDevice : _MTLDevice
@end

@implementation A540TraceDevice

/** H236gu: an empty featureProfile dictionary makes Metal reject the device
 *  before it asks anything else (gt), so the selector is left unimplemented:
 *  it reaches -doesNotRecognizeSelector:, returns nil, and Metal carries on to
 *  -maxBufferLength and -newCommandQueue (gs). */

/** Runs when the image is loaded: the only proof that the bundle was accepted.
 *  It must not call the ABI (+load did, and backboardd aborted each time). */
+ (void)load
{
    gLoaded = true;
    install_crash_reporter();
    // The crash address is only meaningful with the ASLR slide: every image in
    // the process (shared cache included) is moved by the same amount.
    {
        char line[96];
        snprintf(line, sizeof line, "slide=0x%llx", (unsigned long long) _dyld_get_image_vmaddr_slide(0));
        emit(line);
    }
    // H236gs: Metal's device registration asserts that the plugin's device
    // conforms to MTLDevice and to the private MTLDeviceSPI.  The target's own
    // drivers inherit that from their IOGPU base; a plugin class has to declare
    // it, and without it the assertion aborts the hosting process (gl).
    class_addProtocol(self, @protocol(MTLDevice));
    if (Protocol *spi = objc_getProtocol("MTLDeviceSPI")) class_addProtocol(self, spi);
}

+ (void)initialize
{
    if (self != [A540TraceDevice class]) return;
    caller("dev", "initialize", gLoaded ? "loaded=1" : "loaded=0");
}

+ (id)alloc
{
    caller("cls", "alloc", "");
    return [super alloc];
}

/** Report instead of aborting: the message Metal sends when it gives up is the
 *  most valuable line of the whole inventory. */
- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("dev", "doesNotRecognize:", sel_getName(selector));
}

+ (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("cls", "doesNotRecognize:", sel_getName(selector));
}

/** H236hl: Metal sends a stream of private void setters (setSubmissionQueue:,
 *  setCompletionQueue:, setGPUPriority:, …).  Answering one by letting
 *  -doesNotRecognizeSelector: return leaves the caller with a value it does not
 *  expect and CoreFoundation traps (SIGILL right after setGPUPriority:), so a
 *  generic void setter forwarder answers all of them and logs the name. */
/** H236hn: after the depth/stencil state the renderer's stream is not only
 *  `set…:` (the blit pass sends copyFromTexture:…).  Every unimplemented
 *  selector with arguments is answered as a void method taking that many
 *  objects — the colon count is the argument count — and logged. */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    static char types[16][64];
    static unsigned slot;
    const char *name = sel_getName(selector);
    unsigned arguments = 0;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == ':') ++arguments;
    if (arguments && arguments <= 12) {
        char *text = types[slot++ & 15];
        unsigned at = 0;
        text[at++] = 'v';
        text[at++] = '@';
        text[at++] = ':';
        for (unsigned index = 0; index < arguments; ++index) text[at++] = '@';
        text[at] = 0;
        return [NSMethodSignature signatureWithObjCTypes:text];
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    caller("dev", "forward:", sel_getName([invocation selector]));
}


- (instancetype)init
{
    caller("dev", "init", "");
    return self;
}

- (instancetype)initWithAcceleratorPort:(unsigned)port
{
    char detail[64];
    snprintf(detail, sizeof detail, "port=0x%x", port);
    caller("dev", "initWithAcceleratorPort:", detail);
    // H236hg: _MTLDevice -init (0x187ACF7C8) is the scaffolding every later
    // library/pipeline path dereferences without a null check: it creates
    // _libraryBuilder (0x178), _pipelineLibraryBuilder (0x180), the three
    // dispatch queues (0x118/0x120/0x128) and _progressTrackBufferStack.
    // Without it Metal segfaults (exc=1 code=1) right after the MSAA and
    // depth-stencil-texture gates, with no further message to the device.
    id base = [super init];
    if (!base) {
        caller("dev", "initWithAcceleratorPort:", "super-init-nil");
        return nil;
    }
    self = base;
    if (!connectAccelerator()) caller("dev", "initWithAcceleratorPort:", "no-tunnel");
    // H236go: _MTLDevice has no -initWithAcceleratorPort: of its own (gn proved
    // it); the plugin builds the device.  H236gq: the class must be a registered
    // _MTLDevice subclass that conforms to MTLDevice and MTLDeviceSPI, which is
    // what trace_device_class() builds.
    // H236gm showed that handing this instance back aborts Metal's registration;
    // H236gs adds the MTLDeviceSPI conformance the assertion asks for, so the
    // instance is offered again and the inventory follows if it is accepted.
    gDeviceInstance = self;
    caller("dev", "initWithAcceleratorPort:", "device=returned");
    // H236hb: prove the plugin itself can drive the GPU from this process.
    static bool tested;
    if (!tested && gConnection) {
        tested = true;
        gpu_selftest();
    }
    schedule_display_probes();
    return self;
}

/** H236hd: disassembly of the target's Metal (see the subagent report,
 *  build-environment §45.32) settles what this protocol actually is:
 *
 *  - `featureProfile` is an NSUInteger profile bitmask, not a dictionary:
 *    Metal has no implementation of it, the plugin supplies it, and
 *    initLimits/initFeatureQueries/initGPUFamilySupport all read it.
 *  - `-[_MTLDevice supportsFamily:]` walks an inline std::vector at ivar
 *    +0x110 with `ldp` and NO null check, so it crashes (SIGSEGV) unless
 *    initFeatureQueries built that vector: gz's empty overrides were the bug.
 *  - initWorkarounds is a bare `ret`.
 *
 *  So the profile is provided and the base implementations are left alone. */
- (NSUInteger)featureProfile
{
    caller("dev", "featureProfile", "profile=1");
    return 1;
}


- (NSString *)name { caller("dev", "name", ""); return @"A540Trace"; }
- (uint64_t)registryID { caller("dev", "registryID", ""); return 0x540; }
- (unsigned long long)maxBufferLength { caller("dev", "maxBufferLength", ""); return 256ull << 20; }
- (BOOL)isHeadless { caller("dev", "isHeadless", ""); return NO; }
- (BOOL)isLowPower { caller("dev", "isLowPower", ""); return NO; }
- (BOOL)isRemovable { caller("dev", "isRemovable", ""); return NO; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { caller("dev", "depth24", ""); return YES; }

- (BOOL)supportsFeatureSet:(unsigned long long)featureSet
{
    value("dev", "supportsFeatureSet:", "fs", featureSet);
    return YES;
}

/** H236gy: with _MTLDevice as the base, Metal dereferences the base class's
 *  internal state right after -supportsFamily: and dies with SIGSEGV
 *  (NATIVE_TRAP sig=11).  A base that owns no Metal state cannot do that, so
 *  the class is plain NSObject again — this time with the protocol
 *  conformance that go/gp lacked, which is what made Metal skip +alloc then. */

/** H236gx: answering YES to Apple1 sent Metal into a path only a real device
 *  has and killed backboardd.  The stub now reports that it supports no GPU
 *  family, so the renderer takes its compatibility branch and keeps asking
 *  questions instead of dying. */
/** H236hg: no override here.  With featureProfile=1 the base class already
 *  keeps a valid _supportedGPUFamilies vector (Apple1/2/4/5/6/7, Mac1,
 *  Common1-3, MacCat1) and answering NO to everything only hides the data
 *  Metal uses to choose its fallbacks. */

- (id)targetDeviceArchitecture
{
    return trace_architecture();
}

- (unsigned long long)recommendedMaxWorkingSetSize { caller("dev", "recommendedMaxWorkingSetSize", ""); return 0; }
- (unsigned long long)currentAllocatedSize { caller("dev", "currentAllocatedSize", ""); return 0; }

- (id)newCommandQueue
{
    A540TraceQueue *queue = [[A540TraceQueue alloc] init];
    gQueueInstance = queue;
    char detail[64];
    snprintf(detail, sizeof detail, "process=%s", [[[NSProcessInfo processInfo] processName] UTF8String]);
    caller("dev", "newCommandQueue", detail);
    return queue;
}

- (id)newCommandQueueWithMaxCommandBufferCount:(unsigned long long)count
{
    value("dev", "newCommandQueueWithMaxCommandBufferCount:", "count", count);
    return nil;
}

- (id)newBufferWithLength:(unsigned long long)length options:(unsigned long long)options
{
    char detail[64];
    snprintf(detail, sizeof detail, "length=%llu options=%llu", length, options);
    caller("dev", "newBufferWithLength:options:", detail);
    id buffer = trace_object_of("_MTLBuffer", "buffer");
    struct TraceStorage *store = storage_for(buffer, true);
    if (store) store->length = length;
    return buffer;
}

/* H236hs: both texture entry points record the same descriptor fields; the
 * surface one also keeps the surface, which is what -iosurface answers and what
 * a present would hand to the display. */
static void capture_texture(id texture, id descriptor)
{
    struct TraceStorage *store = storage_for(texture, true);
    if (!store || !descriptor) return;
    MTLTextureDescriptor *d = (MTLTextureDescriptor *) descriptor;
    store->width = [d width];
    store->height = [d height];
    store->pixelFormat = [d pixelFormat];
    store->textureType = [d textureType];
    store->storageMode = [d storageMode];
    store->mipmaps = [d mipmapLevelCount];
    store->samples = [d sampleCount];
    store->usage = [d usage];
    store->arrayLength = [d arrayLength];
}

- (id)newTextureWithDescriptor:(id)descriptor
{
    id texture = trace_object_of("_MTLTexture", "texture");
    struct TraceStorage *store = storage_for(texture, true);
    if (store && descriptor) {
        capture_texture(texture, descriptor);
        char detail[128];
        snprintf(detail, sizeof detail, "%llux%llu fmt=%llu type=%llu samples=%llu mips=%llu usage=0x%llx",
                 store->width, store->height, store->pixelFormat, store->textureType,
                 store->samples, store->mipmaps, store->usage);
        caller("dev", "newTextureWithDescriptor:", detail);
    } else {
        caller("dev", "newTextureWithDescriptor:", descriptor ? "no-storage" : "descriptor=0");
    }
    return texture;
}

/** H236hs: the drawable's texture.  CoreAnimation reaches this only with a
 *  surface it owns; until it does, no drawable exists and nothing can be
 *  presented.  The surface is recorded so -iosurface answers it and a present
 *  can offer it to the display. */
- (id)newTextureWithDescriptor:(id)descriptor iosurface:(void *)surface plane:(NSUInteger)plane
{
    id texture = trace_object_of("_MTLTexture", "texture");
    struct TraceStorage *store = storage_for(texture, true);
    if (store) {
        capture_texture(texture, descriptor);
        store->iosurface = surface;
        store->plane = plane;
        load_surface_queries();
        char detail[180];
        snprintf(detail, sizeof detail, "iosurface %llux%llu fmt=%llu plane=%llu id=%u stride=%llu bytes=%llu",
                 store->width, store->height, store->pixelFormat, store->plane,
                 (surface && gSurfaceID) ? gSurfaceID((A540Surface) surface) : 0,
                 (surface && gSurfaceRowBytes) ? (unsigned long long) gSurfaceRowBytes((A540Surface) surface) : 0,
                 (surface && gSurfaceAllocSize) ? (unsigned long long) gSurfaceAllocSize((A540Surface) surface) : 0);
        caller("dev", "newTextureWithDescriptor:iosurface:plane:", detail);
    }
    return texture;
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor error:(id *)error
{
    char detail[160];
    if (descriptor) {
        MTLRenderPipelineDescriptor *pipelineDescriptor = (MTLRenderPipelineDescriptor *) descriptor;
        id vertex = [pipelineDescriptor vertexFunction], fragment = [pipelineDescriptor fragmentFunction];
        id attachments = [pipelineDescriptor colorAttachments];
        // colorAttachments is an MTLRenderPipelineColorAttachmentDescriptorArray:
        // its first entry answers pixelFormat.
        unsigned long long format = 0;
        if ([attachments respondsToSelector:@selector(objectAtIndexedSubscript:)])
            format = [[attachments objectAtIndexedSubscript:0] pixelFormat];
        const char *vertexName = vertex ? [[vertex name] UTF8String] : NULL;
        const char *fragmentName = fragment ? [[fragment name] UTF8String] : NULL;
        snprintf(detail, sizeof detail, "vs=%s fs=%s fmt0=%llu samples=%llu",
                 vertexName ? vertexName : "nil", fragmentName ? fragmentName : "nil",
                 format, (unsigned long long) [pipelineDescriptor rasterSampleCount]);
    } else {
        snprintf(detail, sizeof detail, "descriptor=0");
    }
    caller("dev", "newRenderPipelineStateWithDescriptor:error:", detail);
    return trace_object_of("_MTLRenderPipelineState", "pipeline");
}

- (id)newDepthStencilStateWithDescriptor:(id)descriptor
{
    caller("dev", "newDepthStencilStateWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLDepthStencilState", "state");
}

- (id)newSamplerStateWithDescriptor:(id)descriptor
{
    caller("dev", "newSamplerStateWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLSamplerState", "sampler");
}

- (id)newDefaultLibrary { caller("dev", "newDefaultLibrary", ""); return trace_object_of("_MTLLibrary", "library"); }
- (id)newFence { caller("dev", "newFence", ""); return trace_object_of("_MTLFence", "fence"); }
- (id)newEvent { caller("dev", "newEvent", ""); return trace_object_of("_MTLEvent", "event"); }
- (void)dealloc { caller("dev", "dealloc", ""); }

@end
