// SPDX-License-Identifier: MIT
// H236hx: CADisplay probe for the SpringBoard session (staged as
// /private/var/ngpu/bin/cadprobe and launched by /private/var/ngpu/daemons/com.unixnu.cadprobe.plist
// through the kernel's addon mount over /System/Library/LaunchDaemons).
//
// Why: QuartzCore's ensure_displays caches the first +[CADisplay displays] answer for the life of
// the process (QuartzCore 0x18948d2c0), and query_displays returns an empty list with no log when
// CARenderServerGetServerPort(0) is 0.  SpringBoard starts before backboardd's render server on
// this board, so it caches "no display" and never submits a layer.  Restarting SpringBoard after the
// server published LCD/primary did not make it connect either, so the question is now whether a
// process in the system session can see the render server at all: the reference port (sagit, iOS 18)
// found the system lookup returning BOOTSTRAP_UNKNOWN_SERVICE while the per-user lookup succeeded.
//
// The probe reports through the A540 ABI's Log method (the "NATIVE_MTL:" lines of the kernel log),
// because the Data volume is APFS and cannot be read from the recovery environment.
//
// Lines, once per session view:
//   cad uid=... euid=...
//   cad system port=0x... kr=0x...        bootstrap_look_up("com.apple.CARenderServer")
//   cad peruser uid=501 port=... kr=...   bootstrap_look_up_per_user(...)
//   cad displays class=1 list=N main=0/1  QuartzCore's answer in this process
//   cad first name=LCD                    the first display's name
// The binary re-executes itself once with CA_SYSTEM_SESSION_CLIENT=1 (the switch the reference port
// needed before its first QuartzCore query) and repeats the lines with the "sys/" prefix.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach/task_special_ports.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>

extern "C" kern_return_t bootstrap_look_up(mach_port_t bootstrapPort, const char *name, mach_port_t *service);

static const uint32_t kTunnelMagic = 0x4e544e4c;   /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;
static const char kProbePath[] = "/private/var/ngpu/bin/cadprobe";

static io_connect_t gConnection;
static uint32_t gSelector;

/* Same discovery as the trace plugin: the accelerator the driver publishes is matched through the
 * original class name, and the tunnel selector is the one that accepts the magic word. */
static bool connect_accelerator(void)
{
    if (gConnection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAcceleratorES"));
    if (!service) return false;
    io_connect_t connection = 0;
    const kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS || !connection) return false;
    uint32_t probe[2] = { kTunnelMagic, 0xffffffffu };
    for (uint32_t selector = 0; selector < 256; ++selector) {
        if (IOConnectCallStructMethod(connection, selector, probe, sizeof probe, NULL, NULL) == KERN_SUCCESS) {
            gConnection = connection;
            gSelector = selector;
            return true;
        }
    }
    return false;
}

static void emit(const char *text)
{
    if (!connect_accelerator()) return;
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

static void line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    emit(text);
}

typedef kern_return_t (*PerUserLookup)(mach_port_t, const char *, uid_t, mach_port_t *);

static void report(const char *prefix)
{
    mach_port_t bootstrap = MACH_PORT_NULL, service = MACH_PORT_NULL;
    kern_return_t status = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap);
    if (status == KERN_SUCCESS) status = bootstrap_look_up(bootstrap, "com.apple.CARenderServer", &service);
    line("cad %suid=%u euid=%u accel=%d", prefix, (unsigned) getuid(), (unsigned) geteuid(), gConnection ? 1 : 0);
    line("cad %ssystem port=0x%x kr=0x%x", prefix, (unsigned) service, (unsigned) status);
    if (service != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), service);
    PerUserLookup perUser = (PerUserLookup) dlsym(RTLD_DEFAULT, "bootstrap_look_up_per_user");
    if (perUser && status != -1) {
        const uid_t ids[] = { 501, 0 };
        for (unsigned index = 0; index < 2; ++index) {
            mach_port_t port = MACH_PORT_NULL;
            const kern_return_t result = perUser(bootstrap, "com.apple.CARenderServer", ids[index], &port);
            line("cad %speruser uid=%u port=0x%x kr=0x%x", prefix, (unsigned) ids[index], (unsigned) port, (unsigned) result);
            if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
        }
    } else {
        line("cad %speruser=unavailable", prefix);
    }
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    Class displayClass = NSClassFromString(@"CADisplay");
    unsigned long long count = 0;
    id mainDisplay = nil, list = nil;
    @try {
        if (displayClass) {
            list = ((id (*)(id, SEL)) objc_msgSend)(displayClass, @selector(displays));
            if (list) count = ((unsigned long long (*)(id, SEL)) objc_msgSend)(list, @selector(count));
            mainDisplay = ((id (*)(id, SEL)) objc_msgSend)(displayClass, @selector(mainDisplay));
        }
    } @catch (id exception) { count = 0; }
    line("cad %sdisplays class=%d list=%llu main=%d", prefix, displayClass ? 1 : 0, count, mainDisplay ? 1 : 0);
    if (list && count) {
        id first = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(list, @selector(objectAtIndex:), 0ULL);
        NSString *name = first ? ((id (*)(id, SEL)) objc_msgSend)(first, @selector(name)) : nil;
        line("cad %sfirst name=%s", prefix, name ? [name UTF8String] : "nil");
    }
}

/* QuartzCore caches the first answer for the life of the process, so every sample is a fresh
 * process: each round re-execs itself, and the second chain repeats the rounds with
 * CA_SYSTEM_SESSION_CLIENT=1 (the switch the reference port needed before its first query). */
enum { kRounds = 3, kStep = 40 };

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    const bool systemSession = getenv("CA_SYSTEM_SESSION_CLIENT") != NULL;
    const int round = getenv("CADPROBE_ROUND") ? atoi(getenv("CADPROBE_ROUND")) : 0;
    if (round > 0) sleep((unsigned) kStep);
    report(systemSession ? "sys/" : "");
    char next[8];
    char *const arguments[] = { (char *) kProbePath, NULL };
    if (round + 1 < kRounds) {
        snprintf(next, sizeof next, "%d", round + 1);
        setenv("CADPROBE_ROUND", next, 1);
        execv(kProbePath, arguments);
    } else if (!systemSession) {
        setenv("CADPROBE_ROUND", "0", 1);
        setenv("CA_SYSTEM_SESSION_CLIENT", "1", 1);
        execv(kProbePath, arguments);
    }
    line("cad exec failed errno=%d", errno);
    [pool drain];
    return 0;
}
