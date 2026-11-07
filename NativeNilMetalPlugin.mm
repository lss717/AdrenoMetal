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
// H188 proved with _exit(42) in the constructor that the image loads through
// the union and its code runs.  H189 moves the marker into the device request:
// initWithAcceleratorPort: exits with 43.  "status=0x2b00" in the boot log means
// the class check and messenger call succeeded and the H184-H186 SIGSEGV happens
// after this method returns nil; a SIGSEGV without it means the crash is in the
// principalClass/isSubclassOfClass stage before the method.
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
}

@implementation NativeNilMetalDevice
- (id)initWithAcceleratorPort:(unsigned)port {
    (void)port;
    _exit(43);
    return nil;
}
@end
