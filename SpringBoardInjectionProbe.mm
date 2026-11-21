// SPDX-License-Identifier: MIT
//
// H485: minimal read-only LC_LOAD_DYLIB consumer. It deliberately has no
// Foundation, IOKit, Objective-C or A540 dependency, so it can distinguish a
// generic dyld injection failure from an observer constructor failure.

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" const char *getprogname(void);

__attribute__((constructor)) static void h485_injection_probe_constructor(void)
{
    char output[192];
    const char *process = getprogname();
    int length = snprintf(output, sizeof output,
                          "H485_LCPROBE: load process=%s pid=%d build=H485\n",
                          process ? process : "<null>", getpid());
    if (length <= 0) return;
    size_t count = (size_t) length;
    if (count >= sizeof output) count = sizeof output - 1;
    int console = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console < 0) return;
    (void) write(console, output, count);
    close(console);
}
