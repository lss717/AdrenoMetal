// SPDX-License-Identifier: MIT
//
// H492: skip the synchronous LaunchServices lookup performed by
// -[CCSModuleRepository _queue_filterModuleMetadataByAssociatedBundleAvailability:].
// The module collection is returned unchanged; no scene or display object is
// created or mutated by this shim.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

static void ccs_line(const char *format, ...)
{
    char text[192];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H492_CCS: ", 10);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

static id h492_return_input(id self __unused, SEL command __unused, id value)
{
    ccs_line("filter bypass pid=%d", getpid());
    return value;
}

__attribute__((constructor)) static void h492_ccs_bypass_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;

    Class repository = NSClassFromString(@"CCSModuleRepository");
    SEL selector = NSSelectorFromString(
        @"_queue_filterModuleMetadataByAssociatedBundleAvailability:");
    Method method = repository ? class_getInstanceMethod(repository, selector) : NULL;
    if (!method) {
        ccs_line("filter method missing");
        return;
    }
    method_setImplementation(method, (IMP) h492_return_input);
    ccs_line("filter bypass installed method=%p pid=%d",
             (void *) method, getpid());
}
