// SPDX-License-Identifier: MIT
// Minimal Metal driver plugin used to test the renderer fallback.
//
// CoreAnimation's Metal discovery loads
// /System/Library/Extensions/<MetalPluginName>.bundle, takes its principal
// class, requires an _MTLDevice subclass, and then asks that class for a
// device with initWithAcceleratorPort:.  The owner Adreno plugin documents that
// a plugin which registers no device ("returns nil") keeps the original
// software renderer running; this bundle does exactly that without any GPU
// driver, so we can see whether the compositor falls back and presents a first
// frame.
//
// H185/H186: the H184 run crashed backboardd with SIGSEGV while this bundle was
// reachable through the bindfs union, but stderr of a launchd job goes to
// /dev/null, so the traces never reached the boot log.  Write to /dev/console
// instead: this separates "the image never loaded" (no ctor line) from "the
// device request crashed" (ctor printed, init missing).
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <unistd.h>

// The real _MTLDevice lives in Metal.framework and is already loaded in the
// process that loads this bundle; only the name is needed here.
@interface _MTLDevice : NSObject
@end

@interface NativeNilMetalDevice : _MTLDevice
- (id)initWithAcceleratorPort:(unsigned)port;
@end

static void nilmetal_log(const char *format, ...) {
    FILE *console = fopen("/dev/console", "w");
    if (console == NULL) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    fprintf(console, "NILMETAL: ");
    vfprintf(console, format, arguments);
    fprintf(console, "\n");
    va_end(arguments);
    fclose(console);
}

__attribute__((constructor)) static void nilmetal_constructor(void) {
    nilmetal_log("ctor pid=%d", (int)getpid());
}

@implementation NativeNilMetalDevice
- (id)initWithAcceleratorPort:(unsigned)port {
    nilmetal_log("init port=%u self=%p", port, self);
    [self release];
    return nil;
}
@end
