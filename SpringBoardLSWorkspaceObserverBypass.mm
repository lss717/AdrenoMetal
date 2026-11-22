// SPDX-License-Identifier: MIT
//
// H535: skip the synchronous LaunchServices policy-observer setup performed by
// -[LSApplicationWorkspace addObserver:]. SpringBoard reaches this through
// SBApplicationController -> FBSApplicationLibrary initialization. The bypass
// only runs in SpringBoard and does not mutate the observer or workspace.

#import <objc/runtime.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

static Method h535_workspace_method;

static void h535_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H535_LS: ", 9);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h535_skip_add_observer(id self __unused, SEL command __unused,
    id observer)
{
    h535_line("observer bypass pid=%d observer=%s",
              getpid(), observer ? object_getClassName(observer) : "nil");
}

static int h535_install_method(void)
{
    Method current = __atomic_load_n(&h535_workspace_method, __ATOMIC_ACQUIRE);
    if (current &&
        method_getImplementation(current) == (IMP) h535_skip_add_observer) {
        return 1;
    }

    static void *core_services;
    if (!core_services) {
        core_services = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    Class workspace = (Class) objc_getClass("LSApplicationWorkspace");
    Method method = workspace
        ? class_getInstanceMethod(workspace, sel_registerName("addObserver:"))
        : NULL;
    if (!method) return 0;

    IMP previous = method_setImplementation(method, (IMP) h535_skip_add_observer);
    __atomic_store_n(&h535_workspace_method, method, __ATOMIC_RELEASE);
    h535_line(
        "observer bypass installed method=%p previous=%p coreServices=%p class=%p pid=%d",
        method, previous, core_services, workspace, getpid());
    return 1;
}

static void *h535_install_worker(void *context __unused)
{
    h535_line("installer worker started pid=%d", getpid());
    sleep(5);
    for (unsigned attempt = 1; attempt <= 30; attempt++) {
        if (h535_install_method()) break;
        if (attempt == 1 || (attempt % 5) == 0) {
            h535_line("installer waiting attempt=%u class=%p pid=%d",
                      attempt, objc_getClass("LSApplicationWorkspace"), getpid());
        }
        sleep(10);
    }

    Method method = __atomic_load_n(&h535_workspace_method, __ATOMIC_ACQUIRE);
    if (!method ||
        method_getImplementation(method) != (IMP) h535_skip_add_observer) {
        h535_line("installer failed pid=%d", getpid());
        return NULL;
    }

    for (unsigned interval = 1; interval <= 5; interval++) {
        sleep(120);
        method = __atomic_load_n(&h535_workspace_method, __ATOMIC_ACQUIRE);
        IMP implementation = method_getImplementation(method);
        h535_line(
            "verify elapsed=%u method=%p implementation=%p installed=%d pid=%d",
            interval * 120, method, implementation,
            implementation == (IMP) h535_skip_add_observer, getpid());
    }
    return NULL;
}

__attribute__((constructor)) static void h535_ls_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    pthread_t verifier;
    int error = pthread_create(&verifier, NULL, h535_install_worker, NULL);
    if (!error) {
        (void) pthread_detach(verifier);
    } else {
        h535_line("installer thread failed error=%d", error);
    }
}
