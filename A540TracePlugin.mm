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
#define _XOPEN_SOURCE 700   /* ucontext.h: the crash reporter reads pc/lr/sp/fp */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
#include <signal.h>
#include <ucontext.h>
#include <mach-o/dyld.h>

#include "NativeAdrenoABI.h"

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

/** H236hi: Metal's assertion fires with no message we can see (backboardd is a
 *  platform process; its stderr is not in the kernel log).  The plugin installs
 *  a signal handler that reports the fault address and the frame-pointer chain
 *  through the ABI log, so the aborting image and offset can be resolved
 *  offline against the extracted dyld cache. */
static void report_signal(int number, siginfo_t *info, void *context)
{
    ucontext_t *state = (ucontext_t *) context;
    char line[184];
    unsigned long long pc = state ? (unsigned long long) state->uc_mcontext->__ss.__pc : 0;
    unsigned long long lr = state ? (unsigned long long) state->uc_mcontext->__ss.__lr : 0;
    unsigned long long sp = state ? (unsigned long long) state->uc_mcontext->__ss.__sp : 0;
    unsigned long long fp = state ? (unsigned long long) state->uc_mcontext->__ss.__fp : 0;
    snprintf(line, sizeof line, "signal=%d addr=0x%llx pc=0x%llx lr=0x%llx sp=0x%llx",
             number, (unsigned long long) (info ? (unsigned long long) (uintptr_t) info->si_addr : 0), pc, lr, sp);
    emit(line);
    for (unsigned depth = 0; depth < 6 && fp; ++depth) {
        const unsigned long long *frame = (const unsigned long long *) (uintptr_t) fp;
        snprintf(line, sizeof line, "frame%d fp=0x%llx ret=0x%llx", depth, fp,
                 frame ? (unsigned long long) frame[1] : 0);
        emit(line);
        fp = frame ? frame[0] : 0;
        if (sp && (fp < sp || fp - sp > 0x20000)) break;
    }
    signal(number, SIG_DFL);
    raise(number);
}

static void install_crash_reporter(void)
{
    static bool installed;
    if (installed) return;
    installed = true;
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = report_signal;
    action.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGABRT, &action, NULL);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGILL, &action, NULL);
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

/* H236hb: the plugin's own path to the GPU.  This is the first half of C6a:
 *  the device Metal builds has to be able to allocate, map, submit and fence
 *  real work through the native Adreno ABI from inside the hosting process
 *  (backboardd), under its sandbox.  The sequence mirrors the userspace test
 *  that runs from the probe daemon, but every step reports its own failure so
 *  the kernel log shows exactly where it stops. */
static int abi_call(uint32_t method, const void *input, size_t inputSize, void *output, size_t outputSize)
{
    struct { uint32_t magic, method; uint8_t payload[512]; } request;
    if (inputSize > sizeof request.payload) return -1;
    memset(&request, 0, sizeof request);
    request.magic = kTunnelMagic;
    request.method = method;
    if (inputSize) memcpy(request.payload, input, inputSize);
    size_t size = outputSize;
    return IOConnectCallStructMethod(gConnection, gSelector, &request, 8 + inputSize, output, &size) == KERN_SUCCESS ? 0 : -1;
}

static uint32_t pm4_type7(uint32_t opcode, uint32_t count)
{
    return (3u << 30) | ((opcode & 0x7fu) << 16) | (count & 0x3fffu);
}

static void gpu_selftest(void)
{
    char line[160];
    NativeAdrenoAbiParams params;
    if (abi_call(NativeAdrenoMethodQuery, NULL, 0, &params, sizeof params)) { caller("gpu", "query", "failed"); return; }
    snprintf(line, sizeof line, "abi=0x%x in=%u out=%u maxbo=%llu", params.abi_version,
             params.input_bits, params.output_bits, (unsigned long long) params.max_bo_bytes);
    caller("gpu", "query", line);

    NativeAdrenoAbiDeviceInfo info;
    if (abi_call(NativeAdrenoMethodGetDeviceInfo, NULL, 0, &info, sizeof info)) { caller("gpu", "info", "failed"); return; }
    snprintf(line, sizeof line, "chip=0x%x gmem=%u va=0x%llx+0x%llx",
             info.chip_id, info.gmem_bytes, (unsigned long long) info.va_start, (unsigned long long) info.va_size);
    caller("gpu", "info", line);

    NativeAdrenoAbiBoAlloc request = { 4096, 12, 0 };
    NativeAdrenoAbiBoAllocReply ib, target;
    if (abi_call(NativeAdrenoMethodBoAlloc, &request, sizeof request, &ib, sizeof ib)) { caller("gpu", "boalloc-ib", "failed"); return; }
    if (abi_call(NativeAdrenoMethodBoAlloc, &request, sizeof request, &target, sizeof target)) { caller("gpu", "boalloc-target", "failed"); return; }

    const uint64_t ibIova = info.va_start;
    const uint64_t targetIova = info.va_start + 0x1000;
    NativeAdrenoAbiBoMap mapIb = { ib.handle, ibIova, 1, 0, 2, 0 };
    NativeAdrenoAbiBoMap mapTarget = { target.handle, targetIova, 3, 0, 2, 0 };
    NativeAdrenoAbiBoMapReply mapped;
    if (abi_call(NativeAdrenoMethodBoMap, &mapIb, sizeof mapIb, &mapped, sizeof mapped)) { caller("gpu", "bomap-ib", "failed"); return; }
    if (abi_call(NativeAdrenoMethodBoMap, &mapTarget, sizeof mapTarget, &mapped, sizeof mapped)) { caller("gpu", "bomap-target", "failed"); return; }

    NativeAdrenoAbiBoCpuMap cpuIb = { ib.handle }, cpuTarget = { target.handle };
    NativeAdrenoAbiBoCpuMapReply tokenIb, tokenTarget;
    if (abi_call(NativeAdrenoMethodBoCpuMap, &cpuIb, sizeof cpuIb, &tokenIb, sizeof tokenIb)) { caller("gpu", "cpumap-ib", "failed"); return; }
    if (abi_call(NativeAdrenoMethodBoCpuMap, &cpuTarget, sizeof cpuTarget, &tokenTarget, sizeof tokenTarget)) { caller("gpu", "cpumap-target", "failed"); return; }

    mach_vm_address_t ibAddress = 0, targetAddress = 0;
    mach_vm_size_t ibLength = 0, targetLength = 0;
    // The driver hands back an uncached view of the BO's raw spans, which is
    // what the userspace test maps: kIOMapAnywhere | kIOMapInhibitCache.
    const IOOptionBits mapOptions = kIOMapAnywhere | kIOMapInhibitCache;
    kern_return_t mapStatus = IOConnectMapMemory64(gConnection, tokenIb.token, mach_task_self(), &ibAddress, &ibLength, mapOptions);
    if (mapStatus != KERN_SUCCESS) {
        snprintf(line, sizeof line, "kr=0x%x options=0x%x", mapStatus, (unsigned) mapOptions);
        caller("gpu", "map-ib", line);
        return;
    }
    mapStatus = IOConnectMapMemory64(gConnection, tokenTarget.token, mach_task_self(), &targetAddress, &targetLength, mapOptions);
    if (mapStatus != KERN_SUCCESS) {
        snprintf(line, sizeof line, "kr=0x%x options=0x%x", mapStatus, (unsigned) mapOptions);
        caller("gpu", "map-target", line);
        return;
    }
    snprintf(line, sizeof line, "ib=%llu target=%llu", (unsigned long long) ibLength, (unsigned long long) targetLength);
    caller("gpu", "mapped", line);

    volatile uint32_t *targetWords = (volatile uint32_t *) (uintptr_t) targetAddress;
    volatile uint32_t *ibWords = (volatile uint32_t *) (uintptr_t) ibAddress;
    for (unsigned i = 0; i < 1024; ++i) targetWords[i] = 0xdeadbeefu;

    const uint32_t values[3] = { 0x0adc0de1u, 0xfeed0002u, 0x600d0003u };
    unsigned w = 0;
    for (unsigned i = 0; i < 3; ++i) {
        ibWords[w++] = pm4_type7(0x3d /* CP_MEM_WRITE */, 3);
        ibWords[w++] = (uint32_t) (targetIova + i * 4);
        ibWords[w++] = (uint32_t) ((targetIova + i * 4) >> 32);
        ibWords[w++] = values[i];
    }
    __asm__ volatile("dsb sy" ::: "memory");   // the mapping is non-cacheable; the GPU is an outer-shareable observer

    NativeAdrenoAbiSubmit submit;
    memset(&submit, 0, sizeof submit);
    submit.buffer_count = 1;
    submit.buffers[0].handle = ib.handle;
    submit.buffers[0].iova = ibIova;
    submit.buffers[0].bytes = w * 4;
    NativeAdrenoAbiSubmitReply reply;
    if (abi_call(NativeAdrenoMethodSubmit, &submit, sizeof submit, &reply, sizeof reply)) { caller("gpu", "submit", "failed"); return; }

    NativeAdrenoAbiTimestamp before, after;
    const bool haveBefore = abi_call(NativeAdrenoMethodGetTimestamp, NULL, 0, &before, sizeof before) == 0;
    NativeAdrenoAbiWaitFence wait = { reply.fence, 200000000ull };
    if (abi_call(NativeAdrenoMethodWaitFence, &wait, sizeof wait, NULL, 0)) {
        // A fence that never completes means the CP did not run the buffer.
        // The GPU clock and the fault counters say whether the CP is alive at
        // all (NaN: the timestamp method itself is unsupported).
        const bool haveAfter = abi_call(NativeAdrenoMethodGetTimestamp, NULL, 0, &after, sizeof after) == 0;
        NativeAdrenoAbiStatus status = { 0, 0 };
        abi_call(NativeAdrenoMethodGetStatus, NULL, 0, &status, sizeof status);
        snprintf(line, sizeof line, "fence=%llu ticks=%llu->%llu faults=%llu suspends=%llu",
                 (unsigned long long) reply.fence,
                 (unsigned long long) (haveBefore ? before.ticks : 0),
                 (unsigned long long) (haveAfter ? after.ticks : 0),
                 (unsigned long long) status.faults, (unsigned long long) status.suspends);
        caller("gpu", "fence", line);
        return;
    }

    __asm__ volatile("dsb sy" ::: "memory");
    const unsigned hits = (targetWords[0] == values[0]) + (targetWords[1] == values[1]) +
                          (targetWords[2] == values[2]) + (targetWords[3] == 0xdeadbeefu);
    snprintf(line, sizeof line, "hits=%u/%u fence=%llu t0=%08x t3=%08x", hits, 4u,
             (unsigned long long) reply.fence, targetWords[0], targetWords[3]);
    caller("gpu", "selftest", line);
}

static id trace_object(const char *kind);
static id trace_object_of(const char *className, const char *kind);

/** H236gt: the abandon point is newCommandQueue, so the queue itself has to be
 *  traced too.  It is an opaque object for Metal (a plugin builds both), and
 *  every selector the renderer sends that is not implemented is reported. */
@interface A540TraceQueue : NSObject
@end

@implementation A540TraceQueue

/** H236hl: Metal sends a stream of private void setters (setSubmissionQueue:,
 *  setCompletionQueue:, setGPUPriority:, …).  Answering one by letting
 *  -doesNotRecognizeSelector: return leaves the caller with a value it does not
 *  expect and CoreFoundation traps (SIGILL right after setGPUPriority:), so a
 *  generic void setter forwarder answers all of them and logs the name. */
/** H236hn: after the depth/stencil state the renderer's stream is not only
 *  `set…:` (the blit pass sends copyFromTexture:…).  Every unimplemented
 *  selector with arguments is answered as a void method taking that many
 *  objects — the colon count is the argument count — and logged. */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    static char types[16][64];
    static unsigned slot;
    const char *name = sel_getName(selector);
    unsigned arguments = 0;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == ':') ++arguments;
    if (arguments && arguments <= 12) {
        char *text = types[slot++ & 15];
        unsigned at = 0;
        text[at++] = 'v';
        text[at++] = '@';
        text[at++] = ':';
        for (unsigned index = 0; index < arguments; ++index) text[at++] = '@';
        text[at] = 0;
        return [NSMethodSignature signatureWithObjCTypes:text];
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    caller("queue", "forward:", sel_getName([invocation selector]));
}

- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller("queue", "doesNotRecognize:", sel_getName(selector));
}

- (id)commandBuffer { caller("queue", "commandBuffer", ""); return trace_object_of("_MTLCommandBuffer", "cmdbuf"); }
- (id)newCommandBuffer { caller("queue", "newCommandBuffer", ""); return trace_object_of("_MTLCommandBuffer", "cmdbuf"); }
- (id)commandBufferWithDescriptor:(id)descriptor
{
    caller("queue", "commandBufferWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLCommandBuffer", "cmdbuf");
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

/** H236ha: every creation call must answer an object.  The published bridge
 *  device does the same (nmb_* handles) and Metal then carries on to its device
 *  information queries; answering nil instead makes Metal dereference NULL in
 *  its own bookkeeping (gz: SIGSEGV 38 ms after the depth/stencil state). */
@interface A540TraceObject : NSObject
{
@public
    const char *kind;
}
@end

@implementation A540TraceObject

/** H236hl: Metal sends a stream of private void setters (setSubmissionQueue:,
 *  setCompletionQueue:, setGPUPriority:, …).  Answering one by letting
 *  -doesNotRecognizeSelector: return leaves the caller with a value it does not
 *  expect and CoreFoundation traps (SIGILL right after setGPUPriority:), so a
 *  generic void setter forwarder answers all of them and logs the name. */
/** H236hn: after the depth/stencil state the renderer's stream is not only
 *  `set…:` (the blit pass sends copyFromTexture:…).  Every unimplemented
 *  selector with arguments is answered as a void method taking that many
 *  objects — the colon count is the argument count — and logged. */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    static char types[16][64];
    static unsigned slot;
    const char *name = sel_getName(selector);
    unsigned arguments = 0;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == ':') ++arguments;
    if (arguments && arguments <= 12) {
        char *text = types[slot++ & 15];
        unsigned at = 0;
        text[at++] = 'v';
        text[at++] = '@';
        text[at++] = ':';
        for (unsigned index = 0; index < arguments; ++index) text[at++] = '@';
        text[at] = 0;
        return [NSMethodSignature signatureWithObjCTypes:text];
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    caller("kind", "forward:", sel_getName([invocation selector]));
}

- (void)doesNotRecognizeSelector:(SEL)selector
{
    caller(kind, "doesNotRecognize:", sel_getName(selector));
}

/** H236hm: the render path itself.  After the depth/stencil state and the
 *  textures, CA asks the command buffer for a render command encoder; answering
 *  nothing there ended the run.  The encoders are stubs and the encoding
 *  setters are answered by the generic forwarder, so the first frame reaches
 *  -commit, which is where the driver's own submission will go. */
- (id)renderCommandEncoderWithDescriptor:(id)descriptor
{
    caller(kind, "renderCommandEncoderWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLRenderCommandEncoder", "encoder");
}

- (id)computeCommandEncoderWithDescriptor:(id)descriptor
{
    caller(kind, "computeCommandEncoderWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLComputeCommandEncoder", "encoder");
}

- (id)blitCommandEncoder
{
    caller(kind, "blitCommandEncoder", "");
    return trace_object_of("_MTLBlitCommandEncoder", "encoder");
}

- (id)parallelRenderCommandEncoderWithDescriptor:(id)descriptor
{
    caller(kind, "parallelRenderCommandEncoderWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLParallelRenderCommandEncoder", "encoder");
}

- (void)endEncoding { caller(kind, "endEncoding", ""); }
- (void)presentDrawable:(id)drawable { caller(kind, "presentDrawable:", drawable ? "drawable=1" : "drawable=0"); }
- (void)presentDrawable:(id)drawable atTime:(double)time
{
    char detail[64];
    snprintf(detail, sizeof detail, "drawable=%d at=%llu", drawable ? 1 : 0, (unsigned long long) (time * 1e9));
    caller(kind, "presentDrawable:atTime:", detail);
}
- (void)commit { caller(kind, "commit", ""); }
- (void)waitUntilCompleted { caller(kind, "waitUntilCompleted", ""); }
- (void)waitUntilScheduled { caller(kind, "waitUntilScheduled", ""); }

- (void)dealloc { caller(kind, "dealloc", ""); }

@end

static id trace_object(const char *kind)
{
    A540TraceObject *object = [[A540TraceObject alloc] init];
    object->kind = kind;
    return object;
}

/** H236hh: Metal's own objects are class-gated (the device itself had to pass
 *  `isSubclassOfClass:`), so a plain NSObject handed back from a creation call
 *  is refused with an assertion (backboardd SIGABRT right after the depth/
 *  stencil state was made).  The stub is therefore built as a runtime subclass
 *  of the real class Metal expects, with the logging methods copied over. */
static id trace_object_of(const char *className, const char *kind)
{
    static struct { const char *name; Class cls; } cache[24];
    static unsigned cached;
    Class base = objc_getClass(className);
    if (!base) return trace_object(kind);
    Class cls = Nil;
    for (unsigned i = 0; i < cached; ++i)
        if (!strcmp(cache[i].name, className)) { cls = cache[i].cls; break; }
    if (!cls) {
        char name[96];
        snprintf(name, sizeof name, "A540Trace_%s", className);
        cls = objc_allocateClassPair(base, name, 0);
        if (!cls) return trace_object(kind);
        unsigned count = 0;
        Method *methods = class_copyMethodList([A540TraceObject class], &count);
        for (unsigned index = 0; index < count; ++index)
            class_addMethod(cls, method_getName(methods[index]),
                            method_getImplementation(methods[index]), method_getTypeEncoding(methods[index]));
        free(methods);
        objc_registerClassPair(cls);
        if (cached < sizeof cache / sizeof cache[0]) { cache[cached].name = className; cache[cached].cls = cls; ++cached; }
    }
    A540TraceObject *object = [[cls alloc] init];
    object->kind = kind;
    return object;
}

/** H236hk: the abort came from +[MTLLoader sliceIDForDevice:...] line 666,
 *  which is `MTLReportFailure` after `[device targetDeviceArchitecture]`
 *  returned nil (Metal +0xa3e4 -> +0x14ef54 = _MTLReportFailure.cold.1).
 *  CA loads a pre-compiled metallib (MTLBinaryArchive) and needs that
 *  architecture object to pick a slice.  The plugin supplies one. */
@interface A540TraceArchitecture : NSObject
@end

@implementation A540TraceArchitecture

- (unsigned)cpuType { caller("arch", "cpuType", ""); return 0x0100000Cu; } /* CPU_TYPE_ARM64 */
- (unsigned)subType { caller("arch", "subType", ""); return 0; }
- (unsigned long long)driverVersion { caller("arch", "driverVersion", ""); return 0; }
- (unsigned)versionCombined { caller("arch", "versionCombined", ""); return 0; }
- (void)doesNotRecognizeSelector:(SEL)selector { caller("arch", "doesNotRecognize:", sel_getName(selector)); }
- (void)dealloc { caller("arch", "dealloc", ""); }

@end

static id trace_architecture(void)
{
    static Class cls;
    static bool tried;
    if (!tried) {
        tried = true;
        Class base = objc_getClass("MTLTargetDeviceArchitecture");
        if (base) {
            cls = objc_allocateClassPair(base, "A540TraceArch", 0);
            if (cls) {
                unsigned count = 0;
                Method *methods = class_copyMethodList([A540TraceArchitecture class], &count);
                for (unsigned index = 0; index < count; ++index)
                    class_addMethod(cls, method_getName(methods[index]),
                                    method_getImplementation(methods[index]), method_getTypeEncoding(methods[index]));
                free(methods);
                objc_registerClassPair(cls);
            }
        }
    }
    id object = cls ? [[cls alloc] init] : [[A540TraceArchitecture alloc] init];
    caller("dev", "targetDeviceArchitecture", cls ? "real-base" : "plain-base");
    return object;
}

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
    install_crash_reporter();
    // The crash address is only meaningful with the ASLR slide: every image in
    // the process (shared cache included) is moved by the same amount.
    {
        char line[96];
        snprintf(line, sizeof line, "slide=0x%llx", (unsigned long long) _dyld_get_image_vmaddr_slide(0));
        emit(line);
    }
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

/** H236hl: Metal sends a stream of private void setters (setSubmissionQueue:,
 *  setCompletionQueue:, setGPUPriority:, …).  Answering one by letting
 *  -doesNotRecognizeSelector: return leaves the caller with a value it does not
 *  expect and CoreFoundation traps (SIGILL right after setGPUPriority:), so a
 *  generic void setter forwarder answers all of them and logs the name. */
/** H236hn: after the depth/stencil state the renderer's stream is not only
 *  `set…:` (the blit pass sends copyFromTexture:…).  Every unimplemented
 *  selector with arguments is answered as a void method taking that many
 *  objects — the colon count is the argument count — and logged. */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    static char types[16][64];
    static unsigned slot;
    const char *name = sel_getName(selector);
    unsigned arguments = 0;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == ':') ++arguments;
    if (arguments && arguments <= 12) {
        char *text = types[slot++ & 15];
        unsigned at = 0;
        text[at++] = 'v';
        text[at++] = '@';
        text[at++] = ':';
        for (unsigned index = 0; index < arguments; ++index) text[at++] = '@';
        text[at] = 0;
        return [NSMethodSignature signatureWithObjCTypes:text];
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    caller("dev", "forward:", sel_getName([invocation selector]));
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
    // H236hg: _MTLDevice -init (0x187ACF7C8) is the scaffolding every later
    // library/pipeline path dereferences without a null check: it creates
    // _libraryBuilder (0x178), _pipelineLibraryBuilder (0x180), the three
    // dispatch queues (0x118/0x120/0x128) and _progressTrackBufferStack.
    // Without it Metal segfaults (exc=1 code=1) right after the MSAA and
    // depth-stencil-texture gates, with no further message to the device.
    id base = [super init];
    if (!base) {
        caller("dev", "initWithAcceleratorPort:", "super-init-nil");
        return nil;
    }
    self = base;
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
    // H236hb: prove the plugin itself can drive the GPU from this process.
    static bool tested;
    if (!tested && gConnection) {
        tested = true;
        gpu_selftest();
    }
    return self;
}

/** H236hd: disassembly of the target's Metal (see the subagent report,
 *  build-environment §45.32) settles what this protocol actually is:
 *
 *  - `featureProfile` is an NSUInteger profile bitmask, not a dictionary:
 *    Metal has no implementation of it, the plugin supplies it, and
 *    initLimits/initFeatureQueries/initGPUFamilySupport all read it.
 *  - `-[_MTLDevice supportsFamily:]` walks an inline std::vector at ivar
 *    +0x110 with `ldp` and NO null check, so it crashes (SIGSEGV) unless
 *    initFeatureQueries built that vector: gz's empty overrides were the bug.
 *  - initWorkarounds is a bare `ret`.
 *
 *  So the profile is provided and the base implementations are left alone. */
- (NSUInteger)featureProfile
{
    caller("dev", "featureProfile", "profile=1");
    return 1;
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

/** H236gy: with _MTLDevice as the base, Metal dereferences the base class's
 *  internal state right after -supportsFamily: and dies with SIGSEGV
 *  (NATIVE_TRAP sig=11).  A base that owns no Metal state cannot do that, so
 *  the class is plain NSObject again — this time with the protocol
 *  conformance that go/gp lacked, which is what made Metal skip +alloc then. */

/** H236gx: answering YES to Apple1 sent Metal into a path only a real device
 *  has and killed backboardd.  The stub now reports that it supports no GPU
 *  family, so the renderer takes its compatibility branch and keeps asking
 *  questions instead of dying. */
/** H236hg: no override here.  With featureProfile=1 the base class already
 *  keeps a valid _supportedGPUFamilies vector (Apple1/2/4/5/6/7, Mac1,
 *  Common1-3, MacCat1) and answering NO to everything only hides the data
 *  Metal uses to choose its fallbacks. */

- (id)targetDeviceArchitecture
{
    return trace_architecture();
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
    return trace_object_of("_MTLBuffer", "buffer");
}

- (id)newTextureWithDescriptor:(id)descriptor
{
    caller("dev", "newTextureWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLTexture", "texture");
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor error:(id *)error
{
    caller("dev", "newRenderPipelineStateWithDescriptor:error:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLRenderPipelineState", "pipeline");
}

- (id)newDepthStencilStateWithDescriptor:(id)descriptor
{
    caller("dev", "newDepthStencilStateWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLDepthStencilState", "state");
}

- (id)newSamplerStateWithDescriptor:(id)descriptor
{
    caller("dev", "newSamplerStateWithDescriptor:", descriptor ? "descriptor=1" : "descriptor=0");
    return trace_object_of("_MTLSamplerState", "sampler");
}

- (id)newDefaultLibrary { caller("dev", "newDefaultLibrary", ""); return trace_object_of("_MTLLibrary", "library"); }
- (id)newFence { caller("dev", "newFence", ""); return trace_object_of("_MTLFence", "fence"); }
- (id)newEvent { caller("dev", "newEvent", ""); return trace_object_of("_MTLEvent", "event"); }
- (void)dealloc { caller("dev", "dealloc", ""); }

@end
