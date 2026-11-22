// SPDX-License-Identifier: MIT
//
// H537: skip the synchronous LaunchServices policy-observer setup performed by
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

static Method h537_workspace_method;
static Method h537_enumerate_method;

static void h537_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H537_LS: ", 9);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h537_skip_add_observer(id self __unused, SEL command __unused,
    id observer)
{
    h537_line("observer bypass pid=%d observer=%s",
              getpid(), observer ? object_getClassName(observer) : "nil");
}

static void h537_skip_application_enumeration(
    id self __unused, SEL command __unused, unsigned long type __unused,
    signed char legacy_spi __unused, id block __unused)
{
    h537_line("application enumeration skipped pid=%d", getpid());
}

static int h537_install_methods(void)
{
    Method workspace_method =
        __atomic_load_n(&h537_workspace_method, __ATOMIC_ACQUIRE);
    Method enumerate_method =
        __atomic_load_n(&h537_enumerate_method, __ATOMIC_ACQUIRE);
    int workspace_installed = workspace_method &&
        method_getImplementation(workspace_method) ==
            (IMP) h537_skip_add_observer;
    int enumerate_installed = enumerate_method &&
        method_getImplementation(enumerate_method) ==
            (IMP) h537_skip_application_enumeration;
    if (workspace_installed && enumerate_installed) {
        return 1;
    }

    static void *core_services;
    if (!core_services) {
        core_services = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    Class workspace = (Class) objc_getClass("LSApplicationWorkspace");
    Method add_observer = workspace
        ? class_getInstanceMethod(workspace, sel_registerName("addObserver:"))
        : NULL;
    Method enumerate = workspace
        ? class_getInstanceMethod(
            workspace,
            sel_registerName("enumerateBundlesOfType:legacySPI:block:"))
        : NULL;
    if (!add_observer || !enumerate) return 0;

    IMP previous_add = method_setImplementation(
        add_observer, (IMP) h537_skip_add_observer);
    IMP previous_enumerate = method_setImplementation(
        enumerate, (IMP) h537_skip_application_enumeration);
    __atomic_store_n(
        &h537_workspace_method, add_observer, __ATOMIC_RELEASE);
    __atomic_store_n(
        &h537_enumerate_method, enumerate, __ATOMIC_RELEASE);
    h537_line(
        "methods installed add=%p previousAdd=%p enumerate=%p "
        "previousEnumerate=%p coreServices=%p class=%p pid=%d",
        add_observer, previous_add, enumerate, previous_enumerate,
        core_services, workspace, getpid());
    return 1;
}

static void *h537_install_worker(void *context __unused)
{
    h537_line("installer worker started pid=%d", getpid());
    sleep(5);
    for (unsigned attempt = 1; attempt <= 30; attempt++) {
        if (h537_install_methods()) break;
        if (attempt == 1 || (attempt % 5) == 0) {
            h537_line("installer waiting attempt=%u class=%p pid=%d",
                      attempt, objc_getClass("LSApplicationWorkspace"),
                      getpid());
        }
        sleep(10);
    }

    Method workspace_method =
        __atomic_load_n(&h537_workspace_method, __ATOMIC_ACQUIRE);
    Method enumerate_method =
        __atomic_load_n(&h537_enumerate_method, __ATOMIC_ACQUIRE);
    if (!workspace_method || !enumerate_method ||
        method_getImplementation(workspace_method) !=
            (IMP) h537_skip_add_observer ||
        method_getImplementation(enumerate_method) !=
            (IMP) h537_skip_application_enumeration) {
        h537_line("installer failed pid=%d", getpid());
        return NULL;
    }

    for (unsigned interval = 1; interval <= 5; interval++) {
        sleep(120);
        workspace_method =
            __atomic_load_n(&h537_workspace_method, __ATOMIC_ACQUIRE);
        enumerate_method =
            __atomic_load_n(&h537_enumerate_method, __ATOMIC_ACQUIRE);
        IMP add_implementation =
            method_getImplementation(workspace_method);
        IMP enumerate_implementation =
            method_getImplementation(enumerate_method);
        h537_line(
            "verify elapsed=%u add=%p addImplementation=%p "
            "enumerate=%p enumerateImplementation=%p installed=%d pid=%d",
            interval * 120, workspace_method, add_implementation,
            enumerate_method, enumerate_implementation,
            add_implementation == (IMP) h537_skip_add_observer &&
                enumerate_implementation ==
                    (IMP) h537_skip_application_enumeration,
            getpid());
    }
    return NULL;
}

__attribute__((constructor)) static void h537_ls_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    pthread_t verifier;
    int error = pthread_create(&verifier, NULL, h537_install_worker, NULL);
    if (!error) {
        (void) pthread_detach(verifier);
    } else {
        h537_line("installer thread failed error=%d", error);
    }
}
