// SPDX-License-Identifier: MIT
//
// H536: keep LaunchServices journal recovery off lsd's startup thread.
// The original recovery still executes, on a utility queue, after
// -[_LSInstallProgressService performJournalRecovery] returns.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

static Method gRecoveryMethod;

static void h536_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H536_LSD: ", 10);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h536_recovery_skip(id self __unused, SEL command __unused)
{
    h536_line("recovery skipped pid=%d", getpid());
}

static int h536_install_recovery_skip(void)
{
    Method current = __atomic_load_n(&gRecoveryMethod, __ATOMIC_ACQUIRE);
    if (current &&
        method_getImplementation(current) == (IMP) h536_recovery_skip) {
        return 1;
    }

    static void *core_services;
    if (!core_services) {
        core_services = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    Class service = (Class) objc_getClass("_LSInstallProgressService");
    Method method = service
        ? class_getInstanceMethod(
            service, sel_registerName("performJournalRecovery"))
        : NULL;
    if (!method) return 0;

    IMP previous = method_setImplementation(method, (IMP) h536_recovery_skip);
    __atomic_store_n(&gRecoveryMethod, method, __ATOMIC_RELEASE);
    h536_line(
        "recovery skip installed method=%p previous=%p coreServices=%p class=%p pid=%d",
        method, previous, core_services, service, getpid());
    return 1;
}

static void *h536_recovery_worker(void *context __unused)
{
    usleep(100000);
    for (unsigned attempt = 1; attempt <= 300; attempt++) {
        if (h536_install_recovery_skip()) break;
        if (attempt == 1 || (attempt % 50) == 0) {
            h536_line("recovery waiting attempt=%u class=%p pid=%d",
                      attempt, objc_getClass("_LSInstallProgressService"),
                      getpid());
        }
        usleep(100000);
    }

    Method method = __atomic_load_n(&gRecoveryMethod, __ATOMIC_ACQUIRE);
    if (!method ||
        method_getImplementation(method) != (IMP) h536_recovery_skip) {
        h536_line("recovery install failed pid=%d", getpid());
    }
    return NULL;
}

__attribute__((constructor)) static void h536_lsd_recovery_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "lsd", 3)) return;

    pthread_t worker;
    int error = pthread_create(&worker, NULL, h536_recovery_worker, NULL);
    if (!error) {
        (void) pthread_detach(worker);
    } else {
        h536_line("recovery worker failed error=%d", error);
    }
}
