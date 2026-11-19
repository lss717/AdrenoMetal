// SPDX-License-Identifier: MIT
//
// H432 SpringBoard launch wrapper. Launchd runs this as the SpringBoard job.
// The wrapper records that the overlaid job was consumed, installs the
// observer only in its own environment, and execs the original binary.

#include <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
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
extern "C" {
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
}

#define H432_PROC_ALL_PIDS 1

static const char kObserver[] =
    "/private/var/ngpu/lib/SpringBoardSceneObserver.dylib";
static const char kSpringBoard[] =
    "/System/Library/CoreServices/SpringBoard.app/SpringBoard";
static const char kOnce[] = "/tmp/h432-scenebootstrap.done";
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
        int n = snprintf(output, sizeof output, "H432_SBWRAP: %s\n", text);
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

static int find_process(const char *name)
{
    int pids[4096];
    int count = proc_listpids(H432_PROC_ALL_PIDS, 0, pids, sizeof pids);
    if (count <= 0) return 0;
    count /= sizeof pids[0];
    for (int i = 0; i < count; ++i) {
        if (pids[i] <= 0) continue;
        char comm[64] = {};
        if (proc_name(pids[i], comm, sizeof comm) > 0 && !strcmp(comm, name)) return pids[i];
    }
    return 0;
}

static int run(const char *path, char *const arguments[])
{
    pid_t child = 0;
    int status = posix_spawn(&child, path, NULL, NULL, arguments, environ);
    if (status || child <= 0) return status ? status : -1;
    int result = 0;
    while (waitpid(child, &result, 0) < 0 && errno == EINTR) {}
    return result;
}

static void set_global_environment(void)
{
    char *insert[] = { (char *) "/bin/launchctl", (char *) "setenv",
                       (char *) "DYLD_INSERT_LIBRARIES", (char *) kObserver, NULL };
    char *flat[] = { (char *) "/bin/launchctl", (char *) "setenv",
                     (char *) "DYLD_FORCE_FLAT_NAMESPACE", (char *) "1", NULL };
    line("launchctl insert begin");
    line("launchctl insert status=%d", run("/bin/launchctl", insert));
    line("launchctl flat status=%d", run("/bin/launchctl", flat));
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
    line("wrapper exec target=%s", kSpringBoard);
    char *arguments[] = { (char *) kSpringBoard, NULL };
    execv(kSpringBoard, arguments);
    line("wrapper exec failed errno=%d", errno);
    return 1;
}

static bool terminate_springboard(int pid)
{
    if (pid > 0 && kill(pid, SIGTERM) == 0) {
        line("kill sent pid=%d signal=%d", pid, SIGTERM);
        return true;
    }
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
           RTLD_NOW);
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    if (!serviceClass) {
        line("terminate service class missing");
        return false;
    }
    SEL shared = @selector(sharedService);
    id service = [(id) serviceClass respondsToSelector:shared]
        ? ((id (*)(id, SEL)) objc_msgSend)((id) serviceClass, shared) : nil;
    SEL terminate = NSSelectorFromString(
        @"terminateApplication:forReason:andReport:withDescription:");
    if (!service || ![(id) service respondsToSelector:terminate]) {
        line("terminate service unavailable");
        return false;
    }
    @try {
        ((void (*)(id, SEL, id, unsigned long long, BOOL, id)) objc_msgSend)(
            service, terminate, @"com.apple.springboard", 1ull, YES,
            @"H432 install SpringBoard scene observer");
        line("terminate service sent");
        return true;
    } @catch (id exception) {
        line("terminate service exception class=%s", object_getClassName(exception));
        return false;
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--launch-springboard")) {
            return launch_springboard();
        }
        line("bootstrap enter uid=%u euid=%u pid=%d", getuid(), geteuid(), getpid());
        int once = open(kOnce, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (once < 0) {
            line("bootstrap already claimed errno=%d", errno);
            return 0;
        }
        (void) write(once, "H432\n", 5);
        close(once);

        for (unsigned second = 0; second < 300; ++second) {
            int pid = find_process("SpringBoard");
            if (pid > 0) {
                line("SpringBoard found pid=%d", pid);
                set_global_environment();
                if (!terminate_springboard(pid)) return 1;
                for (unsigned wait = 0; wait < 60; ++wait) {
                    sleep(1);
                    int next = find_process("SpringBoard");
                    if (next > 0 && next != pid) {
                        line("SpringBoard restarted old=%d new=%d", pid, next);
                        return 0;
                    }
                }
                line("SpringBoard restart timeout old=%d", pid);
                return 2;
            }
            sleep(1);
        }
        line("SpringBoard wait timeout");
        return 3;
    }
}
