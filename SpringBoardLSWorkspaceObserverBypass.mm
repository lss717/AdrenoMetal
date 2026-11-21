// SPDX-License-Identifier: MIT
//
// H534: skip the synchronous LaunchServices policy-observer setup performed by
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

static Method h534_workspace_method;

static void h534_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H534_LS: ", 9);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h534_skip_add_observer(id self __unused, SEL command __unused,
    id observer)
{
    h534_line("observer bypass pid=%d observer=%s",
              getpid(), observer ? object_getClassName(observer) : "nil");
}

static void *h534_verify_worker(void *context __unused)
{
    for (unsigned interval = 1; interval <= 5; interval++) {
        sleep(120);
        Method method = __atomic_load_n(&h534_workspace_method, __ATOMIC_ACQUIRE);
        IMP implementation = method ? method_getImplementation(method) : NULL;
        h534_line(
            "verify elapsed=%u method=%p implementation=%p installed=%d pid=%d",
            interval * 120, method, implementation,
            implementation == (IMP) h534_skip_add_observer, getpid());
    }
    return NULL;
}

__attribute__((constructor)) static void h534_ls_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    void *coreServices = dlopen(
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        RTLD_NOW | RTLD_GLOBAL);
    Class workspace = (Class) objc_getClass("LSApplicationWorkspace");
    SEL selector = sel_registerName("addObserver:");
    Method method = workspace ? class_getInstanceMethod(workspace, selector) : NULL;
    h534_line("coreServices=%p class=%p method=%p pid=%d",
              coreServices, workspace, method, getpid());
    if (!method) {
        h534_line("observer method missing class=%p error=%s",
                  workspace, coreServices ? "none" : dlerror());
        return;
    }
    IMP previous = method_setImplementation(method, (IMP) h534_skip_add_observer);
    __atomic_store_n(&h534_workspace_method, method, __ATOMIC_RELEASE);
    h534_line("observer bypass installed method=%p previous=%p pid=%d",
              (void *) method, (void *) previous, getpid());

    pthread_t verifier;
    int error = pthread_create(&verifier, NULL, h534_verify_worker, NULL);
    if (!error) {
        (void) pthread_detach(verifier);
    } else {
        h534_line("verify thread failed error=%d", error);
    }
}
