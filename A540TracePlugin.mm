// SPDX-License-Identifier: MIT
// A540 standalone Metal trace plugin (H236ga).
//
// A deliberately dependency-free bundle: it links only Foundation and IOKit, so
// a load failure can only mean "the bundle was not accepted", never a missing
// bridge/Turnip artefact. Metal loads it through MetalPluginName=A540Trace and
// instantiates the principal class; the device answers the render server's SPI
// with inert values and reports every call through the native Adreno ABI's Log
// method, which the kernel prints as "NATIVE_MTL: ...".
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

@interface _MTLDevice : NSObject
@end

static const uint32_t kTunnelMagic = 0x4e544e4c;   /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;

static io_connect_t gConnection;
static uint32_t gSelector;
static unsigned gSequence;
static unsigned gBudget = 800;

static void emit(const char *text)
{
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

@interface A540TraceDevice : _MTLDevice
@end

@implementation A540TraceDevice

- (instancetype)initWithAcceleratorPort:(unsigned)port
{
    // H236gb: Metal hands over the accelerator connection it already opened.
    // Opening a second one is refused by the platform sandbox, so the trace
    // must travel on the provided connection.
    if (port) gConnection = (io_connect_t) port;
    if (gConnection) {
        uint32_t probe[2] = { kTunnelMagic, 0xffffffffu };
        for (uint32_t selector = 0; selector < 256 && !gSelector; ++selector)
            if (IOConnectCallStructMethod(gConnection, selector, probe, sizeof probe, NULL, NULL) == KERN_SUCCESS)
                gSelector = selector;
    } else {
        connectAccelerator();
    }
    caller("dev", "initWithAcceleratorPort:", gSelector ? "tunnel=ok" : "tunnel=none");
    return self;
}

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

- (BOOL)supportsFamily:(long long)family
{
    value("dev", "supportsFamily:", "family", (unsigned long long) family);
    return YES;
}

- (unsigned long long)recommendedMaxWorkingSetSize { caller("dev", "recommendedMaxWorkingSetSize", ""); return 0; }
- (unsigned long long)currentAllocatedSize { caller("dev", "currentAllocatedSize", ""); return 0; }

- (id)newCommandQueue
{
    caller("dev", "newCommandQueue", "");
    return nil;
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

@end
