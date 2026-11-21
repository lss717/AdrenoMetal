// SPDX-License-Identifier: MIT
//
// H518 launchd wrapper for the original signed lsd executable.
// The cached com.apple.lsd job points at this wrapper. The wrapper starts the
// original binary from the owner addon with argv[0]="lsd" and injects only the
// journal-recovery shim.

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char kShim[] =
    "/private/var/ngpu/lib/LsdRecoveryAsync.dylib";
static const char kLsd[] =
    "/private/var/ngpu/bin/lsd.real";

static void line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void line(const char *format, ...)
{
    char text[256];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, "H518_LSDWRAP: ", 14);
    (void) write(console, text, strlen(text));
    (void) write(console, "\n", 1);
    close(console);
}

int main(int argc, char **argv)
{
    line("wrapper enter uid=%u euid=%u pid=%d argc=%d",
         getuid(), geteuid(), getpid(), argc);
    if (setenv("DYLD_INSERT_LIBRARIES", kShim, 1) != 0) {
        line("setenv insert failed errno=%d", errno);
        return 1;
    }
    if (setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1) != 0) {
        line("setenv flat failed errno=%d", errno);
        return 1;
    }
    line("env insert=%s", kShim);
    line("exec target=%s argv0=lsd", kLsd);

    char **arguments =
        static_cast<char **>(calloc((size_t) argc + 1, sizeof(*arguments)));
    if (!arguments) {
        line("calloc failed");
        return 1;
    }
    arguments[0] = (char *) "lsd";
    for (int index = 1; index < argc; ++index) {
        arguments[index] = argv[index];
    }
    execv(kLsd, arguments);
    line("exec failed errno=%d", errno);
    return 1;
}
