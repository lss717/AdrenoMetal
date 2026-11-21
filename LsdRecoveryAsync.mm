// SPDX-License-Identifier: MIT
//
// H491: keep LaunchServices journal recovery off lsd's startup thread.
// The original recovery still executes, on a utility queue, after
// -[_LSInstallProgressService performJournalRecovery] returns.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

static void (*(gOriginalRecovery))(id, SEL);

static void lsd_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H491_LSD: ", 10);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static void h491_recovery_skip(id self __unused, SEL command __unused)
{
    lsd_line("recovery skipped pid=%d", getpid());
}

__attribute__((constructor)) static void h491_lsd_recovery_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "lsd", 3)) return;

    Class service = NSClassFromString(@"_LSInstallProgressService");
    SEL selector = NSSelectorFromString(@"performJournalRecovery");
    Method method = service ? class_getInstanceMethod(service, selector) : NULL;
    if (!method) {
        lsd_line("recovery method missing");
        return;
    }
    gOriginalRecovery = (void (*)(id, SEL))method_getImplementation(method);
    method_setImplementation(method, (IMP) h491_recovery_skip);
    lsd_line("recovery skip installed method=%p pid=%d",
             (void *) method, getpid());
}
