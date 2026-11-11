// SPDX-License-Identifier: MIT
// A540 standalone Metal trace plugin (H236gm).
//
// A deliberately dependency-free bundle: it links only Foundation, IOKit and
// Metal, so a load failure can only mean "the bundle was not accepted", never a
// missing bridge/Turnip artefact. Metal loads it through MetalPluginName=A540Trace
// and drives the principal class through the original discovery path
// (IOAcceleratorES -> MetalPluginName -> NSBundle -> principal class). Every
// message Metal sends is reported through the native Adreno ABI's Log method,
// which the kernel prints as "NATIVE_MTL: ...".
//
// History that shaped the code (see build-environment-2026-11-10.md §45):
//  * an ad-hoc bundle is refused for backboardd ("unsuitable CT policy 0" and
//    "Library Validation failed") unless its CDHash is in the boot trust cache;
//  * the accelerator port Metal passes to -initWithAcceleratorPort: is not the
//    connection the ABI answers on, and using it kills the calling process, so
//    the trace opens its own connection through IOServiceOpen;
//  * a device that never answers leaves Metal retrying, which is exactly the
//    abandon point the inventory below has to capture.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

@interface _MTLDevice : NSObject
// The selector Metal sends to the principal class: declaring it lets the plugin
// ask the real class what it does with the accelerator port (H236gn).
- (instancetype)initWithAcceleratorPort:(unsigned)port;
@end

static const uint32_t kTunnelMagic = 0x4e544e4c;   /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;

static io_connect_t gConnection;
static uint32_t gSelector;
static unsigned gSequence;
static unsigned gBudget = 800;
static bool gLoaded;
static id gDeviceInstance;

static bool connectAccelerator(void);

static void emit(const char *text)
{
    if (!gConnection && !connectAccelerator()) return;
    if (!gConnection || !gBudget) return;
    --gBudget;
    struct { uint32_t magic, method, bytes, reserved; char text[kMaxLog]; } request;
    memset(&request, 0, sizeof request);
    request.magic = kTunnelMagic;
    request.method = kMethodLog;
    size_t n = strlen(text);
    if (n > kMaxLog) n = kMaxLog;
    request.bytes = (uint32_t) n;
    memcpy(request.text, text, n);
    IOConnectCallStructMethod(gConnection, gSelector, &request, sizeof request, NULL, NULL);
}

static void caller(const char *cls, const char *sel, const char *detail)
{
    char line[256];
    snprintf(line, sizeof line, "%s#%u %s %s", cls, ++gSequence, sel, detail ? detail : "");
    emit(line);
}

static void value(const char *cls, const char *sel, const char *name, unsigned long long v)
{
    char detail[64];
    snprintf(detail, sizeof detail, "%s=%llu", name, v);
    caller(cls, sel, detail);
}

static bool connectAccelerator(void)
{
    if (gConnection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOAcceleratorES"));
    if (!service) return false;
    io_connect_t connection = 0;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS || !connection) return false;
    gConnection = connection;
    uint32_t probe[2] = { kTunnelMagic, 0xffffffffu };
    for (uint32_t selector = 0; selector < 256; ++selector) {
        if (IOConnectCallStructMethod(connection, selector, probe, sizeof probe, NULL, NULL) == KERN_SUCCESS) {
            gSelector = selector;
            return true;
        }
    }
    return false;
}

/** H236gt: the abandon point is newCommandQueue, so the queue itself has to be
 *  traced too.  It is an opaque object for Metal (a plugin builds both), and
 *  every selector the renderer sends that is not implemented is reported. */
@interface A540TraceQueue : NSObject
@end

@implementation A540TraceQueue

- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("queue", "doesNotRecognize:", sel_getName(selector));
}

- (id)commandBuffer { caller("queue", "commandBuffer", ""); return nil; }
- (id)newCommandBuffer { caller("queue", "newCommandBuffer", ""); return nil; }
- (id)commandBufferWithDescriptor:(id)descriptor
{
    caller("queue", "commandBufferWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return nil;
}
- (void)setLabel:(id)label { caller("queue", "setLabel:", label ? "label=1" : "label=0"); }
- (id)device { caller("queue", "device", ""); return gDeviceInstance; }
- (unsigned long long)maxCommandBufferCount { caller("queue", "maxCommandBufferCount", ""); return 64; }
/** H236gv: after -setLabel: Metal hands the queue its IO submission queue
 *  through this private setter; returning nil here (unimplemented) is exactly
 *  where it gave up.  The argument is recorded, nothing else. */
- (void)setSubmissionQueue:(id)submission
{
    caller("queue", "setSubmissionQueue:", submission ? "submission=1" : "submission=0");
}

/** H236gw: the renderer installs the queue's IO mailboxes one setter at a time
 *  (submission queue, then completion queue); each unimplemented one ends the
 *  attempt.  Every void setter is accepted and recorded in one place. */
- (void)setCompletionQueue:(id)completion
{
    caller("queue", "setCompletionQueue:", completion ? "completion=1" : "completion=0");
}

- (void)setCommandBufferQueue:(id)value { caller("queue", "setCommandBufferQueue:", value ? "value=1" : "value=0"); }
- (void)setPriority:(id)value { caller("queue", "setPriority:", value ? "value=1" : "value=0"); }
- (void)setPurgeableState:(id)value { caller("queue", "setPurgeableState:", value ? "value=1" : "value=0"); }

- (void)insertDebugCaptureBoundary { caller("queue", "insertDebugCaptureBoundary", ""); }
- (void)dealloc { caller("queue", "dealloc", ""); }

@end

@interface A540TraceDevice : _MTLDevice
@end

@implementation A540TraceDevice

/** H236gu: an empty featureProfile dictionary makes Metal reject the device
 *  before it asks anything else (gt), so the selector is left unimplemented:
 *  it reaches -doesNotRecognizeSelector:, returns nil, and Metal carries on to
 *  -maxBufferLength and -newCommandQueue (gs). */

/** Runs when the image is loaded: the only proof that the bundle was accepted.
 *  It must not call the ABI (+load did, and backboardd aborted each time). */
+ (void)load
{
    gLoaded = true;
    // H236gs: Metal's device registration asserts that the plugin's device
    // conforms to MTLDevice and to the private MTLDeviceSPI.  The target's own
    // drivers inherit that from their IOGPU base; a plugin class has to declare
    // it, and without it the assertion aborts the hosting process (gl).
    class_addProtocol(self, @protocol(MTLDevice));
    if (Protocol *spi = objc_getProtocol("MTLDeviceSPI")) class_addProtocol(self, spi);
}

+ (void)initialize
{
    if (self != [A540TraceDevice class]) return;
    caller("dev", "initialize", gLoaded ? "loaded=1" : "loaded=0");
}

+ (id)alloc
{
    caller("cls", "alloc", "");
    return [super alloc];
}

/** Report instead of aborting: the message Metal sends when it gives up is the
 *  most valuable line of the whole inventory. */
- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("dev", "doesNotRecognize:", sel_getName(selector));
}

+ (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("cls", "doesNotRecognize:", sel_getName(selector));
}

- (instancetype)init
{
    caller("dev", "init", "");
    return self;
}

- (instancetype)initWithAcceleratorPort:(unsigned)port
{
    char detail[64];
    snprintf(detail, sizeof detail, "port=0x%x", port);
    caller("dev", "initWithAcceleratorPort:", detail);
    if (!connectAccelerator()) caller("dev", "initWithAcceleratorPort:", "no-tunnel");
    // H236go: _MTLDevice has no -initWithAcceleratorPort: of its own (gn proved
    // it); the plugin builds the device.  H236gq: the class must be a registered
    // _MTLDevice subclass that conforms to MTLDevice and MTLDeviceSPI, which is
    // what trace_device_class() builds.
    // H236gm showed that handing this instance back aborts Metal's registration;
    // H236gs adds the MTLDeviceSPI conformance the assertion asks for, so the
    // instance is offered again and the inventory follows if it is accepted.
    gDeviceInstance = self;
    caller("dev", "initWithAcceleratorPort:", "device=returned");
    return self;
}

/** H236gz: _MTLAddDevice runs these four on every device it registers.  The
 *  target's implementations fill the base class's limits and feature tables
 *  from a hardware profile (featureProfile and the Apple GPU tables); with the
 *  base implementations left in place and no profile, the very next query
 *  (supportsFamily:) dereferenced uninitialised state and killed backboardd
 *  (NATIVE_TRAP sig=11 right after family=1001).  The bridge device overrides
 *  all four with empty bodies for the same reason, so the trace does too. */
- (void)initLimits { caller("dev", "initLimits", "empty"); }
- (void)initFeatureQueries { caller("dev", "initFeatureQueries", "empty"); }
- (void)initGPUFamilySupport { caller("dev", "initGPUFamilySupport", "empty"); }
- (void)initWorkarounds { caller("dev", "initWorkarounds", "empty"); }

- (NSString *)name { caller("dev", "name", ""); return @"A540Trace"; }
- (uint64_t)registryID { caller("dev", "registryID", ""); return 0x540; }
- (unsigned long long)maxBufferLength { caller("dev", "maxBufferLength", ""); return 256ull << 20; }
- (BOOL)isHeadless { caller("dev", "isHeadless", ""); return NO; }
- (BOOL)isLowPower { caller("dev", "isLowPower", ""); return NO; }
- (BOOL)isRemovable { caller("dev", "isRemovable", ""); return NO; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { caller("dev", "depth24", ""); return YES; }

- (BOOL)supportsFeatureSet:(unsigned long long)featureSet
{
    value("dev", "supportsFeatureSet:", "fs", featureSet);
    return YES;
}

/** H236gy: with _MTLDevice as the base, Metal dereferences the base class's
 *  internal state right after -supportsFamily: and dies with SIGSEGV
 *  (NATIVE_TRAP sig=11).  A base that owns no Metal state cannot do that, so
 *  the class is plain NSObject again — this time with the protocol
 *  conformance that go/gp lacked, which is what made Metal skip +alloc then. */

/** H236gx: answering YES to Apple1 sent Metal into a path only a real device
 *  has and killed backboardd.  The stub now reports that it supports no GPU
 *  family, so the renderer takes its compatibility branch and keeps asking
 *  questions instead of dying. */
- (BOOL)supportsFamily:(long long)family
{
    value("dev", "supportsFamily:", "family", (unsigned long long) family);
    return NO;
}

- (unsigned long long)recommendedMaxWorkingSetSize { caller("dev", "recommendedMaxWorkingSetSize", ""); return 0; }
- (unsigned long long)currentAllocatedSize { caller("dev", "currentAllocatedSize", ""); return 0; }

- (id)newCommandQueue
{
    caller("dev", "newCommandQueue", "queue=stub");
    return [[A540TraceQueue alloc] init];
}

- (id)newCommandQueueWithMaxCommandBufferCount:(unsigned long long)count
{
    value("dev", "newCommandQueueWithMaxCommandBufferCount:", "count", count);
    return nil;
}

- (id)newBufferWithLength:(unsigned long long)length options:(unsigned long long)options
{
    char detail[64];
    snprintf(detail, sizeof detail, "length=%llu options=%llu", length, options);
    caller("dev", "newBufferWithLength:options:", detail);
    return nil;
}

- (id)newTextureWithDescriptor:(id)descriptor
{
    caller("dev", "newTextureWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return nil;
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor error:(id *)error
{
    caller("dev", "newRenderPipelineStateWithDescriptor:error:", descriptor ? "descriptor=1" : "descriptor=0");
    return nil;
}

- (id)newDepthStencilStateWithDescriptor:(id)descriptor
{
    caller("dev", "newDepthStencilStateWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return nil;
}

- (id)newSamplerStateWithDescriptor:(id)descriptor
{
    caller("dev", "newSamplerStateWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return nil;
}

- (id)newDefaultLibrary { caller("dev", "newDefaultLibrary", ""); return nil; }
- (id)newFence { caller("dev", "newFence", ""); return nil; }
- (id)newEvent { caller("dev", "newEvent", ""); return nil; }
- (void)dealloc { caller("dev", "dealloc", ""); }

@end
