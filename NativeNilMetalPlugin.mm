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
// H185-H187 could not prove whether the bundle image ever executed: launchd
// sends a job's stderr to /dev/null and user-space /dev/console writes do not
// reach the kernel console on this port.  H188 uses the exit status as the
// channel: the constructor exits the loading process with code 42, which the
// kernel logs as "NATIVE_EXIT ... status=0x2a".  A SIGSEGV with no such exit
// means the image never ran (dyld/mmap/AMFI stage); status 0x2a means it did.
#import <Foundation/Foundation.h>
#include <unistd.h>

// The real _MTLDevice lives in Metal.framework and is already loaded in the
// process that loads this bundle; only the name is needed here.
@interface _MTLDevice : NSObject
@end

@interface NativeNilMetalDevice : _MTLDevice
- (id)initWithAcceleratorPort:(unsigned)port;
@end

__attribute__((constructor)) static void nilmetal_constructor(void) {
    _exit(42);
}

@implementation NativeNilMetalDevice
- (id)initWithAcceleratorPort:(unsigned)port {
    (void)port;
    [self release];
    return nil;
}
@end
