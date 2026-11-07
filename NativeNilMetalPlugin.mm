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
#import <Foundation/Foundation.h>

// The real _MTLDevice lives in Metal.framework and is already loaded in the
// process that loads this bundle; only the name is needed here.
@interface _MTLDevice : NSObject
@end

@interface NativeNilMetalDevice : _MTLDevice
- (id)initWithAcceleratorPort:(unsigned)port;
@end

@implementation NativeNilMetalDevice
- (id)initWithAcceleratorPort:(unsigned)port {
    (void)port;
    [self release];
    return nil;
}
@end
