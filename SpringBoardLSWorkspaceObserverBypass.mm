// SPDX-License-Identifier: MIT
//
// H538: skip synchronous LaunchServices setup reached during
// FBSApplicationLibrary initialization. The caller of
// -[FBSApplicationLibrary _workQueue_currentProcessProxyWithOutURL:] explicitly
// handles a nil proxy and continues loading.

#import <objc/runtime.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

static Method h538_workspace_method;
static Method h538_enumerate_method;
static Method h538_current_process_proxy_method;

static void h538_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H538_LS: ", 9);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h538_skip_add_observer(id self __unused, SEL command __unused,
    id observer)
{
    h538_line("observer bypass pid=%d observer=%s",
              getpid(), observer ? object_getClassName(observer) : "nil");
}

static void h538_skip_application_enumeration(
    id self __unused, SEL command __unused, unsigned long type __unused,
    signed char legacy_spi __unused, id block __unused)
{
    h538_line("application enumeration skipped pid=%d", getpid());
}

static id h538_skip_current_process_proxy(
    id self __unused, SEL command __unused, id *outURL)
{
    if (outURL) *outURL = nil;
    h538_line("current process proxy skipped pid=%d", getpid());
    return nil;
}

static int h538_install_methods(void)
{
    Method workspace_method =
        __atomic_load_n(&h538_workspace_method, __ATOMIC_ACQUIRE);
    Method enumerate_method =
        __atomic_load_n(&h538_enumerate_method, __ATOMIC_ACQUIRE);
    Method current_process_proxy_method =
        __atomic_load_n(&h538_current_process_proxy_method, __ATOMIC_ACQUIRE);
    int workspace_installed = workspace_method &&
        method_getImplementation(workspace_method) ==
            (IMP) h538_skip_add_observer;
    int enumerate_installed = enumerate_method &&
        method_getImplementation(enumerate_method) ==
            (IMP) h538_skip_application_enumeration;
    int current_process_proxy_installed = current_process_proxy_method &&
        method_getImplementation(current_process_proxy_method) ==
            (IMP) h538_skip_current_process_proxy;
    if (workspace_installed && enumerate_installed &&
        current_process_proxy_installed) {
        return 1;
    }

    static void *core_services;
    if (!core_services) {
        core_services = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    static void *front_board_services;
    if (!front_board_services) {
        front_board_services = dlopen(
            "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    Class workspace = (Class) objc_getClass("LSApplicationWorkspace");
    Class application_library = (Class) objc_getClass("FBSApplicationLibrary");
    Method add_observer = workspace
        ? class_getInstanceMethod(workspace, sel_registerName("addObserver:"))
        : NULL;
    Method enumerate = workspace
        ? class_getInstanceMethod(
            workspace,
            sel_registerName("enumerateBundlesOfType:legacySPI:block:"))
        : NULL;
    Method current_process_proxy = application_library
        ? class_getInstanceMethod(
            application_library,
            sel_registerName("_workQueue_currentProcessProxyWithOutURL:"))
        : NULL;
    if (!add_observer || !enumerate || !current_process_proxy) return 0;

    IMP previous_add = method_setImplementation(
        add_observer, (IMP) h538_skip_add_observer);
    IMP previous_enumerate = method_setImplementation(
        enumerate, (IMP) h538_skip_application_enumeration);
    IMP previous_current_process_proxy = method_setImplementation(
        current_process_proxy, (IMP) h538_skip_current_process_proxy);
    __atomic_store_n(
        &h538_workspace_method, add_observer, __ATOMIC_RELEASE);
    __atomic_store_n(
        &h538_enumerate_method, enumerate, __ATOMIC_RELEASE);
    __atomic_store_n(
        &h538_current_process_proxy_method, current_process_proxy,
        __ATOMIC_RELEASE);
    h538_line(
        "methods installed add=%p previousAdd=%p enumerate=%p "
        "previousEnumerate=%p currentProxy=%p previousCurrentProxy=%p "
        "coreServices=%p frontBoardServices=%p class=%p appLibraryClass=%p pid=%d",
        add_observer, previous_add, enumerate, previous_enumerate,
        current_process_proxy, previous_current_process_proxy,
        core_services, front_board_services, workspace, application_library,
        getpid());
    return 1;
}

static void *h538_install_worker(void *context __unused)
{
    h538_line("installer worker started pid=%d", getpid());
    sleep(5);
    for (unsigned attempt = 1; attempt <= 30; attempt++) {
        if (h538_install_methods()) break;
        if (attempt == 1 || (attempt % 5) == 0) {
            h538_line("installer waiting attempt=%u class=%p appLibraryClass=%p pid=%d",
                      attempt, objc_getClass("LSApplicationWorkspace"),
                      objc_getClass("FBSApplicationLibrary"),
                      getpid());
        }
        sleep(10);
    }

    Method workspace_method =
        __atomic_load_n(&h538_workspace_method, __ATOMIC_ACQUIRE);
    Method enumerate_method =
        __atomic_load_n(&h538_enumerate_method, __ATOMIC_ACQUIRE);
    Method current_process_proxy_method =
        __atomic_load_n(&h538_current_process_proxy_method, __ATOMIC_ACQUIRE);
    if (!workspace_method || !enumerate_method ||
        !current_process_proxy_method ||
        method_getImplementation(workspace_method) !=
            (IMP) h538_skip_add_observer ||
        method_getImplementation(enumerate_method) !=
            (IMP) h538_skip_application_enumeration ||
        method_getImplementation(current_process_proxy_method) !=
            (IMP) h538_skip_current_process_proxy) {
        h538_line("installer failed pid=%d", getpid());
        return NULL;
    }

    for (unsigned interval = 1; interval <= 5; interval++) {
        sleep(120);
        workspace_method =
            __atomic_load_n(&h538_workspace_method, __ATOMIC_ACQUIRE);
        enumerate_method =
            __atomic_load_n(&h538_enumerate_method, __ATOMIC_ACQUIRE);
        current_process_proxy_method =
            __atomic_load_n(
                &h538_current_process_proxy_method, __ATOMIC_ACQUIRE);
        IMP add_implementation =
            method_getImplementation(workspace_method);
        IMP enumerate_implementation =
            method_getImplementation(enumerate_method);
        IMP current_process_proxy_implementation =
            method_getImplementation(current_process_proxy_method);
        h538_line(
            "verify elapsed=%u add=%p addImplementation=%p "
            "enumerate=%p enumerateImplementation=%p "
            "currentProxy=%p currentProxyImplementation=%p installed=%d pid=%d",
            interval * 120, workspace_method, add_implementation,
            enumerate_method, enumerate_implementation,
            current_process_proxy_method,
            current_process_proxy_implementation,
            add_implementation == (IMP) h538_skip_add_observer &&
                enumerate_implementation ==
                    (IMP) h538_skip_application_enumeration &&
                current_process_proxy_implementation ==
                    (IMP) h538_skip_current_process_proxy,
            getpid());
    }
    return NULL;
}

__attribute__((constructor)) static void h538_ls_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    pthread_t verifier;
    int error = pthread_create(&verifier, NULL, h538_install_worker, NULL);
    if (!error) {
        (void) pthread_detach(verifier);
    } else {
        h538_line("installer thread failed error=%d", error);
    }
}
