// SPDX-License-Identifier: MIT
//
// H483 SpringBoard bundle wrapper. The original standard executable path is
// overlaid; the wrapper installs the observer in its own environment, checks
// that the observer can be loaded in this process, and execs the shipped signed
// copy in the same app bundle. It must do this on every launch: launchd will
// respawn this path after a restart.

#include <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <signal.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static const char kObserver[] =
    "/private/var/ngpu/lib/SpringBoardSceneObserver.dylib";
static const char kSpringBoard[] =
    "/System/Library/CoreServices/SpringBoard.app/SpringBoard.real";
static const uint32_t kTunnelMagic = 0x4e544e4c;
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;
static io_connect_t gConnection;
static uint32_t gSelector;
static int gConsole = -2;

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

static void line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void line(const char *format, ...)
{
    char text[kMaxLog + 1];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    if (gConsole == -2) gConsole = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (gConsole >= 0) {
        char output[kMaxLog + 36];
        int n = snprintf(output, sizeof output, "H436_SBWRAP: build=H483 %s\n", text);
        if (n > 0) {
            size_t count = (size_t) n;
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

static int launch_springboard(void)
{
    line("wrapper enter uid=%u euid=%u pid=%d", getuid(), geteuid(), getpid());
    if (setenv("DYLD_INSERT_LIBRARIES", kObserver, 1) != 0) {
        line("wrapper setenv insert failed errno=%d", errno);
        return 1;
    }
    if (setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1) != 0) {
        line("wrapper setenv flat failed errno=%d", errno);
        return 1;
    }
    const char *insert = getenv("DYLD_INSERT_LIBRARIES");
    const char *flat = getenv("DYLD_FORCE_FLAT_NAMESPACE");
    line("wrapper env insert=%s", insert ? insert : "<null>");
    line("wrapper env flat=%s", flat ? flat : "<null>");
    void *observer = dlopen(kObserver, RTLD_NOW | RTLD_LOCAL);
    if (observer) {
        line("wrapper dlopen observer ok");
    } else {
        const char *error = dlerror();
        line("wrapper dlopen observer failed error=%s", error ? error : "<null>");
    }
    line("wrapper exec target=%s", kSpringBoard);
    char *arguments[] = { (char *) kSpringBoard, NULL };
    execv(kSpringBoard, arguments);
    line("wrapper exec failed errno=%d", errno);
    return 1;
}

int main(int argc __unused, char **argv __unused)
{
    @autoreleasepool {
        line("bootstrap enter uid=%u euid=%u pid=%d", getuid(), geteuid(), getpid());
        return launch_springboard();
    }
}
