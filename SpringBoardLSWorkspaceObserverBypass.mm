// SPDX-License-Identifier: MIT
//
// H539: skip the synchronous LaunchServices paths reached during
// FBSApplicationLibrary initialization. The three replacements are installed
// independently so a later class or selector cannot prevent the earlier H537
// bypasses from being applied. The installation state is published through
// the observer ABI so it remains observable after CDC attaches.

#import <objc/runtime.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

enum : uint32_t {
    kH539WorkerStarted = 1u << 0,
    kH539CoreServicesLoaded = 1u << 1,
    kH539WorkspaceClassFound = 1u << 2,
    kH539AddObserverInstalled = 1u << 3,
    kH539EnumerateInstalled = 1u << 4,
    kH539FrontBoardServicesLoaded = 1u << 5,
    kH539ApplicationLibraryClassFound = 1u << 6,
    kH539CurrentProxyMethodFound = 1u << 7,
    kH539CurrentProxyInstalled = 1u << 8,
    kH539InstallerDone = 1u << 9,
    kH539InstallerFailed = 1u << 10,
};

static uint32_t h539_state;
static Method h539_workspace_method;
static Method h539_enumerate_method;
static Method h539_current_process_proxy_method;

static void h539_set_state(uint32_t bits)
{
    (void) __atomic_fetch_or(&h539_state, bits, __ATOMIC_RELEASE);
}

extern "C" uint32_t h539_installer_state(void)
{
    return __atomic_load_n(&h539_state, __ATOMIC_ACQUIRE);
}

static void h539_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H539_LS: ", 9);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h539_skip_add_observer(id self __unused, SEL command __unused,
    id observer)
{
    h539_line("observer bypass pid=%d observer=%s",
              getpid(), observer ? object_getClassName(observer) : "nil");
}

static void h539_skip_application_enumeration(
    id self __unused, SEL command __unused, unsigned long type __unused,
    signed char legacy_spi __unused, id block __unused)
{
    h539_line("application enumeration skipped pid=%d", getpid());
}

static id h539_skip_current_process_proxy(
    id self __unused, SEL command __unused, id *outURL)
{
    if (outURL) *outURL = nil;
    h539_line("current process proxy skipped pid=%d", getpid());
    return nil;
}

static bool h539_method_has_replacement(Method method, IMP replacement)
{
    return method && method_getImplementation(method) == replacement;
}

static bool h539_all_methods_installed(void)
{
    Method workspace_method =
        __atomic_load_n(&h539_workspace_method, __ATOMIC_ACQUIRE);
    Method enumerate_method =
        __atomic_load_n(&h539_enumerate_method, __ATOMIC_ACQUIRE);
    Method current_process_proxy_method =
        __atomic_load_n(&h539_current_process_proxy_method, __ATOMIC_ACQUIRE);
    return h539_method_has_replacement(
               workspace_method, (IMP) h539_skip_add_observer) &&
        h539_method_has_replacement(
               enumerate_method, (IMP) h539_skip_application_enumeration) &&
        h539_method_has_replacement(
               current_process_proxy_method,
               (IMP) h539_skip_current_process_proxy);
}

static int h539_install_methods(void)
{
    if (h539_all_methods_installed()) {
        h539_set_state(kH539InstallerDone);
        return 1;
    }

    static void *core_services;
    if (!core_services) {
        core_services = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    if (core_services) h539_set_state(kH539CoreServicesLoaded);

    Class workspace = (Class) objc_getClass("LSApplicationWorkspace");
    if (workspace) h539_set_state(kH539WorkspaceClassFound);

    Method add_observer = workspace
        ? class_getInstanceMethod(workspace, sel_registerName("addObserver:"))
        : NULL;
    if (add_observer &&
        method_getImplementation(add_observer) !=
            (IMP) h539_skip_add_observer) {
        IMP previous = method_setImplementation(
            add_observer, (IMP) h539_skip_add_observer);
        __atomic_store_n(
            &h539_workspace_method, add_observer, __ATOMIC_RELEASE);
        h539_line("addObserver installed method=%p previous=%p pid=%d",
                  add_observer, previous, getpid());
    }
    if (h539_method_has_replacement(
            add_observer, (IMP) h539_skip_add_observer)) {
        h539_set_state(kH539AddObserverInstalled);
    }

    Method enumerate = workspace
        ? class_getInstanceMethod(
            workspace,
            sel_registerName("enumerateBundlesOfType:legacySPI:block:"))
        : NULL;
    if (enumerate &&
        method_getImplementation(enumerate) !=
            (IMP) h539_skip_application_enumeration) {
        IMP previous = method_setImplementation(
            enumerate, (IMP) h539_skip_application_enumeration);
        __atomic_store_n(
            &h539_enumerate_method, enumerate, __ATOMIC_RELEASE);
        h539_line("application enumeration installed method=%p previous=%p pid=%d",
                  enumerate, previous, getpid());
    }
    if (h539_method_has_replacement(
            enumerate, (IMP) h539_skip_application_enumeration)) {
        h539_set_state(kH539EnumerateInstalled);
    }

    static void *front_board_services;
    if (!front_board_services) {
        front_board_services = dlopen(
            "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            RTLD_NOW | RTLD_GLOBAL);
    }
    if (front_board_services) {
        h539_set_state(kH539FrontBoardServicesLoaded);
    }

    Class application_library = (Class) objc_getClass("FBSApplicationLibrary");
    if (application_library) {
        h539_set_state(kH539ApplicationLibraryClassFound);
    }
    Method current_process_proxy = application_library
        ? class_getInstanceMethod(
            application_library,
            sel_registerName("_workQueue_currentProcessProxyWithOutURL:"))
        : NULL;
    if (current_process_proxy) {
        h539_set_state(kH539CurrentProxyMethodFound);
    }
    if (current_process_proxy &&
        method_getImplementation(current_process_proxy) !=
            (IMP) h539_skip_current_process_proxy) {
        IMP previous = method_setImplementation(
            current_process_proxy, (IMP) h539_skip_current_process_proxy);
        __atomic_store_n(
            &h539_current_process_proxy_method, current_process_proxy,
            __ATOMIC_RELEASE);
        h539_line(
            "current process proxy installed method=%p previous=%p pid=%d",
            current_process_proxy, previous, getpid());
    }
    if (h539_method_has_replacement(
            current_process_proxy, (IMP) h539_skip_current_process_proxy)) {
        h539_set_state(kH539CurrentProxyInstalled);
    }

    if (h539_all_methods_installed()) {
        h539_set_state(kH539InstallerDone);
        h539_line("methods installed add=independent state=0x%x pid=%d",
                  h539_installer_state(), getpid());
        return 1;
    }
    return 0;
}

static void *h539_install_worker(void *context __unused)
{
    h539_set_state(kH539WorkerStarted);
    h539_line("installer worker started pid=%d", getpid());
    sleep(5);
    for (unsigned attempt = 1; attempt <= 60; attempt++) {
        if (h539_install_methods()) break;
        if (attempt == 1 || (attempt % 5) == 0) {
            h539_line(
                "installer waiting attempt=%u state=0x%x workspace=%p "
                "applicationLibrary=%p pid=%d",
                attempt, h539_installer_state(),
                objc_getClass("LSApplicationWorkspace"),
                objc_getClass("FBSApplicationLibrary"), getpid());
        }
        sleep(10);
    }

    if (!h539_all_methods_installed()) {
        h539_set_state(kH539InstallerFailed);
    }

    for (unsigned interval = 1; interval <= 5; interval++) {
        sleep(120);
        h539_line(
            "verify elapsed=%u state=0x%x add=%p enumerate=%p currentProxy=%p "
            "installed=%d pid=%d",
            interval * 120, h539_installer_state(),
            __atomic_load_n(&h539_workspace_method, __ATOMIC_ACQUIRE),
            __atomic_load_n(&h539_enumerate_method, __ATOMIC_ACQUIRE),
            __atomic_load_n(
                &h539_current_process_proxy_method, __ATOMIC_ACQUIRE),
            h539_all_methods_installed(), getpid());
    }
    return NULL;
}

__attribute__((constructor)) static void h539_ls_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    h539_set_state(kH539WorkerStarted);
    pthread_t verifier;
    int error = pthread_create(&verifier, NULL, h539_install_worker, NULL);
    if (!error) {
        (void) pthread_detach(verifier);
    } else {
        h539_set_state(kH539InstallerFailed);
        h539_line("installer thread failed error=%d", error);
    }
}
