// SPDX-License-Identifier: MIT
//
// H533: skip the synchronous LaunchServices policy-observer setup performed by
// -[LSApplicationWorkspace addObserver:]. SpringBoard reaches this through
// SBApplicationController -> FBSApplicationLibrary initialization. The bypass
// only runs in SpringBoard and does not mutate the observer or workspace.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

static void h533_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H533_LS: ", 9);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h533_skip_add_observer(id self __unused, SEL command __unused,
    id observer)
{
    h533_line("observer bypass pid=%d observer=%s",
              getpid(), observer ? object_getClassName(observer) : "nil");
}

__attribute__((constructor)) static void h533_ls_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    SEL selector = NSSelectorFromString(@"addObserver:");
    Method method = workspace ? class_getInstanceMethod(workspace, selector) : NULL;
    if (!method) {
        h533_line("observer method missing");
        return;
    }
    method_setImplementation(method, (IMP) h533_skip_add_observer);
    h533_line("observer bypass installed method=%p pid=%d",
              (void *) method, getpid());
}
