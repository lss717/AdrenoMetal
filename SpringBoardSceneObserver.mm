// SPDX-License-Identifier: MIT
//
// H436 read-only SpringBoard scene observer. It is injected through the
// owner-provided LaunchDaemon overlay and logs through the A540 ABI. The
// observer only runs in SpringBoard; inherited DYLD_INSERT_LIBRARIES values in
// child processes are ignored.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <sys/proc.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "NativeAdrenoABI.h"

extern "C" const char *getprogname(void);

static const uint32_t kTunnelMagic = 0x4e544e4c; /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;

static io_connect_t gConnection;
static uint32_t gSelector;
static unsigned gBudget = 120;
static int gConsole = -2;

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

static void emit(const char *text)
{
    if (!text || gBudget == 0) return;
    --gBudget;

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

static const char *class_name_or_nil(id object)
{
    return object ? object_getClassName(object) : "nil";
}

static id normalized_collection(id collection)
{
    if (!collection) return nil;
    if ([collection isKindOfClass:[NSDictionary class]]) return [collection allValues];
    if ([collection isKindOfClass:[NSSet class]]) return [collection allObjects];
    return collection;
}

static void log_object_field(const char *scope, unsigned index, id scene, const char *field)
{
    id value = read_object(scene, field);
    line("scene=%s/%u field=%s present=%d class=%s", scope, index, field,
         value ? 1 : 0, class_name_or_nil(value));
}

static void snapshot(const char *phase, unsigned sample)
{
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
           RTLD_NOW);
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);

    Class workspaceClass = NSClassFromString(@"FBSWorkspace");
    Class sceneClass = NSClassFromString(@"FBScene");
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
    if (!workspace) return;

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

    Class applicationClass = NSClassFromString(@"UIApplication");
    id application = nil;
    @try {
        if (applicationClass) {
            SEL shared = @selector(sharedApplication);
            if ([(id) applicationClass respondsToSelector:shared])
                application = ((id (*)(id, SEL)) objc_msgSend)((id) applicationClass, shared);
        }
    } @catch (id ignored) {
        application = nil;
    }
    id delegate = read_object(application, "delegate");
    id connected = normalized_collection(read_object(application, "connectedScenes"));
    id windows = normalized_collection(read_object(application, "windows"));
    unsigned long long connectedCount = connected
        ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(connected, @selector(count)) : 0;
    unsigned long long windowCount = windows
        ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(windows, @selector(count)) : 0;
    line("sample=%u app=%d delegate=%s scenes=%llu windows=%llu",
         sample, application ? 1 : 0, class_name_or_nil(delegate), connectedCount, windowCount);
}

__attribute__((constructor)) static void h432_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strcmp(process, "SpringBoard")) return;
    line("observer load process=%s pid=%d build=H436", process, getpid());
    const double delays[] = { 5.0, 30.0, 90.0, 180.0, 300.0, 480.0 };
    for (unsigned index = 0; index < sizeof delays / sizeof delays[0]; ++index) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delays[index] * 1e9)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            snapshot("springboard", index);
        });
    }
}
