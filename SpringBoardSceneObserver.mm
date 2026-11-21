// SPDX-License-Identifier: MIT
//
// H504 read-only SpringBoard scene observer. It is injected through the
// owner-provided LaunchDaemon overlay and logs through the A540 ABI. The
// observer only runs in SpringBoard; inherited DYLD_INSERT_LIBRARIES values in
// child processes are ignored.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <sys/proc.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "NativeAdrenoABI.h"

extern "C" const char *getprogname(void);

static const uint32_t kTunnelMagic = 0x4e544e4c; /* 'NTNL' */
static const uint32_t kMethodLog = 17;
static const uint32_t kMaxLog = 184;

static io_connect_t gConnection;
static uint32_t gSelector;
static unsigned gBudget = 1024;
static int gConsole = -2;
static unsigned gViewBudget;
static unsigned gLayerBudget;
static uint32_t gHostContextIds[8];
static unsigned gHostContextCount;
static uintptr_t gLayerTrail[16];

extern "C" {
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
}

static bool connect_accelerator(void)
{
    if (gConnection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                        IOServiceMatching("IOAcceleratorES"));
    if (!service) return false;
    io_connect_t connection = 0;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS || !connection) return false;
    uint32_t probe[2] = { kTunnelMagic, 0xffffffffu };
    for (uint32_t selector = 0; selector < 256; ++selector) {
        if (IOConnectCallStructMethod(connection, selector, probe, sizeof probe, NULL, NULL) ==
            KERN_SUCCESS) {
            gConnection = connection;
            gSelector = selector;
            return true;
        }
    }
    IOServiceClose(connection);
    return false;
}

static void emit(const char *text)
{
    if (!text || gBudget == 0) return;
    --gBudget;

    if (gConsole == -2) gConsole = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (gConsole >= 0) {
        char output[kMaxLog + 24];
        int length = snprintf(output, sizeof output, "H436_SBSCENE: %s\n", text);
        if (length > 0) {
            size_t count = (size_t) length;
            if (count >= sizeof output) count = sizeof output - 1;
            (void) write(gConsole, output, count);
        }
    }

    if (!connect_accelerator()) return;
    struct {
        uint32_t magic, method, bytes, reserved;
        char text[kMaxLog];
    } request;
    memset(&request, 0, sizeof request);
    request.magic = kTunnelMagic;
    request.method = kMethodLog;
    size_t n = strlen(text);
    if (n > kMaxLog) n = kMaxLog;
    request.bytes = (uint32_t) n;
    memcpy(request.text, text, n);
    IOConnectCallStructMethod(gConnection, gSelector, &request, sizeof request, NULL, NULL);
}

static void line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void line(const char *format, ...)
{
    char text[kMaxLog + 1];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    emit(text);
}

static Method instance_method(id object, const char *name)
{
    if (!object || !name) return NULL;
    return class_getInstanceMethod(object_getClass(object), sel_getUid(name));
}

static const char *instance_encoding(id object, const char *name)
{
    Method method = instance_method(object, name);
    return method ? method_getTypeEncoding(method) : NULL;
}

static id read_object(id object, const char *name)
{
    const char *encoding = instance_encoding(object, name);
    if (!encoding || encoding[0] != '@') return nil;
    @try {
        return ((id (*)(id, SEL)) objc_msgSend)(object, sel_getUid(name));
    } @catch (id ignored) {
        return nil;
    }
}

static bool read_integer(id object, const char *name, unsigned long long *value)
{
    const char *encoding = instance_encoding(object, name);
    if (!encoding || !value || !strchr("cCsSiIlLqQBb", encoding[0])) return false;
    @try {
        *value = ((unsigned long long (*)(id, SEL)) objc_msgSend)(object, sel_getUid(name));
        return true;
    } @catch (id ignored) {
        return false;
    }
}

static void copy_utf8(id value, char *out, size_t size)
{
    if (!out || !size) return;
    out[0] = 0;
    if (!value || ![value isKindOfClass:[NSString class]]) {
        snprintf(out, size, "-");
        return;
    }
    const char *text = [(NSString *) value UTF8String];
    snprintf(out, size, "%s", text ? text : "-");
}

static void copy_description(id value, char *out, size_t size)
{
    if (!out || !size) return;
    out[0] = 0;
    if (!value) {
        snprintf(out, size, "nil");
        return;
    }
    if ([value isKindOfClass:[NSString class]]) {
        copy_utf8(value, out, size);
        return;
    }
    if ([value respondsToSelector:@selector(description)]) {
        @try {
            id description = ((id (*)(id, SEL)) objc_msgSend)(
                value, @selector(description));
            copy_utf8(description, out, size);
            return;
        } @catch (id ignored) {
        }
    }
    snprintf(out, size, "<%s>", object_getClassName(value));
}

static const char *class_name_or_nil(id object)
{
    return object ? object_getClassName(object) : "nil";
}

static bool selector_name_is_relevant(const char *name)
{
    static const char *const tokens[] = {
        "shared", "main", "scene", "workspace", "window", "display"
    };
    if (!name) return false;
    for (unsigned index = 0; index < sizeof tokens / sizeof tokens[0]; ++index) {
        if (strstr(name, tokens[index])) return true;
    }
    return false;
}

static void inventory_class(const char *name)
{
    Class cls = NSClassFromString([NSString stringWithUTF8String:name]);
    line("sbclass name=%s exists=%d", name, cls ? 1 : 0);
    if (!cls) return;
    unsigned methodCount = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &methodCount);
    unsigned shown = 0;
    line("sbclass name=%s classMethods=%u", name, methodCount);
    for (unsigned index = 0; methods && index < methodCount && shown < 32; ++index) {
        const char *selector = sel_getName(method_getName(methods[index]));
        if (!selector_name_is_relevant(selector)) continue;
        line("sbclass name=%s classSelector=%s", name, selector);
        ++shown;
    }
    free(methods);
}

static void inventory_springboard_classes(void)
{
    static const char *const classes[] = {
        "SBMainWorkspace",
        "SBSceneManagerCoordinator",
        "SBMainDisplaySceneManager",
        "SBWindowSceneManager",
        "SBApplicationController",
        "FBSceneManager",
        "SpringBoard"
    };
    line("sbinventory begin");
    for (unsigned index = 0; index < sizeof classes / sizeof classes[0]; ++index)
        inventory_class(classes[index]);
    line("sbinventory end");
}

static id call_checked_class_selector(const char *className, const char *selectorName)
{
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) return nil;
    SEL selector = sel_getUid(selectorName);
    if (![(id) cls respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL)) objc_msgSend)((id) cls, selector);
    } @catch (id ignored) {
        return nil;
    }
}

static void inventory_instance_methods(const char *label, id object)
{
    if (!object) return;
    unsigned methodCount = 0;
    Class cls = object_getClass(object);
    Method *methods = class_copyMethodList(cls, &methodCount);
    unsigned shown = 0;
    line("sbinstance name=%s class=%s methods=%u",
         label, object_getClassName(object), methodCount);
    for (unsigned index = 0; methods && index < methodCount && shown < 32; ++index) {
        const char *selector = sel_getName(method_getName(methods[index]));
        if (!selector_name_is_relevant(selector)) continue;
        line("sbinstance name=%s selector=%s", label, selector);
        ++shown;
    }
    free(methods);
}

static void probe_nonblocking_shared_instances(void)
{
    id mainWorkspace = call_checked_class_selector(
        "SBMainWorkspace", "sharedInstanceIfExists");
    id applicationController = call_checked_class_selector(
        "SBApplicationController", "sharedInstanceIfExists");
    line("sbexists name=SBMainWorkspace value=%d class=%s",
         mainWorkspace ? 1 : 0, class_name_or_nil(mainWorkspace));
    line("sbexists name=SBApplicationController value=%d class=%s",
         applicationController ? 1 : 0, class_name_or_nil(applicationController));
    if (mainWorkspace) inventory_instance_methods("SBMainWorkspace", mainWorkspace);
}

static id normalized_collection(id collection)
{
    if (!collection) return nil;
    if ([collection isKindOfClass:[NSDictionary class]]) return [collection allValues];
    if ([collection isKindOfClass:[NSSet class]]) return [collection allObjects];
    return collection;
}

static unsigned long long collection_count(id collection)
{
    collection = normalized_collection(collection);
    if (!collection || ![collection respondsToSelector:@selector(count)]) return 0;
    return ((unsigned long long (*)(id, SEL)) objc_msgSend)(
        collection, @selector(count));
}

static id collection_object_at(id collection, unsigned long long index)
{
    collection = normalized_collection(collection);
    if (!collection || ![collection respondsToSelector:@selector(objectAtIndex:)])
        return nil;
    return ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
        collection, @selector(objectAtIndex:), index);
}

static void log_object_field(const char *scope, unsigned index, id scene, const char *field)
{
    id value = read_object(scene, field);
    line("scene=%s/%u field=%s present=%d class=%s", scope, index, field,
         value ? 1 : 0, class_name_or_nil(value));
}

static bool first_host_context(uint32_t contextId)
{
    if (!contextId) return false;
    for (unsigned index = 0; index < gHostContextCount; ++index) {
        if (gHostContextIds[index] == contextId) return false;
    }
    if (gHostContextCount == sizeof gHostContextIds / sizeof gHostContextIds[0])
        return false;
    gHostContextIds[gHostContextCount++] = contextId;
    return true;
}

static void snapshot_dictionary(const char *scope, id dictionary)
{
    if (!dictionary || ![dictionary isKindOfClass:[NSDictionary class]]) {
        line("hierarchy=dictionary scope=%s present=0", scope);
        return;
    }
    NSArray *allKeys = ((NSDictionary *) dictionary).allKeys;
    line("hierarchy=dictionary scope=%s count=%llu", scope,
         collection_count(allKeys));
    unsigned long long count = collection_count(allKeys);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        id key = collection_object_at(allKeys, index);
        id value = key ? [dictionary objectForKey:key] : nil;
        char keyText[48], valueText[72];
        copy_description(key, keyText, sizeof keyText);
        copy_description(value, valueText, sizeof valueText);
        line("hierarchy=dictionary scope=%s item=%llu key=%.44s value=%.68s",
             scope, index, keyText, valueText);
    }
}

static void snapshot_layer_tree(const char *scope, unsigned windowIndex,
                                unsigned viewIndex, id layer, unsigned depth,
                                unsigned *budget)
{
    if (!layer || depth > 12 || !budget || *budget == 0) return;
    const uintptr_t address = (uintptr_t) layer;
    for (unsigned index = 0; index < depth; ++index) {
        if (gLayerTrail[index] == address) {
            line("hierarchy=layer scope=%s/%u view=%u depth=%u class=%s cycle=1",
                 scope, windowIndex, viewIndex, depth,
                 object_getClassName(layer));
            return;
        }
    }
    gLayerTrail[depth] = address;
    --*budget;
    const char *layerClass = object_getClassName(layer);
    id contents = read_object(layer, "contents");
    id sublayers = normalized_collection(read_object(layer, "sublayers"));
    unsigned long long count = collection_count(sublayers);
    line("hierarchy=layer scope=%s/%u view=%u depth=%u class=%s contents=%d sublayers=%llu",
         scope, windowIndex, viewIndex, depth, layerClass,
         contents ? 1 : 0, count);
    if (strstr(layerClass, "LayerHost")) {
        unsigned long long contextId = 0;
        const bool hasContextId = read_integer(layer, "contextId", &contextId);
        id context = read_object(layer, "context");
        line("hierarchy=host scope=%s/%u view=%u depth=%u class=%.32s contextId=0x%x hasContextId=%d context=%d class=%.24s",
             scope, windowIndex, viewIndex, depth, layerClass,
             (unsigned) contextId, hasContextId ? 1 : 0,
             context ? 1 : 0, class_name_or_nil(context));
        unsigned long long inheritsSecurity = 0;
        unsigned long long preservesFlip = 0;
        const bool hasInheritsSecurity = read_integer(
            layer, "inheritsSecurity", &inheritsSecurity);
        const bool hasPreservesFlip = read_integer(
            layer, "preservesFlip", &preservesFlip);
        line("hierarchy=hostprops scope=%s/%u inheritsSecurity=%llu hasInherits=%d preservesFlip=%llu hasPreservesFlip=%d",
             scope, windowIndex, inheritsSecurity,
             hasInheritsSecurity ? 1 : 0, preservesFlip,
             hasPreservesFlip ? 1 : 0);
        if (context && first_host_context((uint32_t) contextId)) {
            unsigned long long observedId = 0;
            unsigned long long observedDisplay = 0;
            unsigned long long observedMask = 0;
            unsigned long long valid = 0;
            unsigned long long frozen = 0;
            const bool hasObservedId = read_integer(context, "contextId", &observedId);
            const bool hasObservedDisplay = read_integer(context, "displayId", &observedDisplay);
            const bool hasObservedMask = read_integer(context, "displayMask", &observedMask);
            const bool hasValid = read_integer(context, "isValid", &valid);
            const bool hasFrozen = read_integer(context, "isFrozen", &frozen);
            id contextLayer = read_object(context, "layer");
            id renderContext = read_object(context, "renderContext");
            id options = read_object(context, "options");
            line("hierarchy=context scope=%s/%u host=0x%x id=0x%x hasId=%d display=0x%x hasDisplay=%d mask=0x%x hasMask=%d valid=%llu hasValid=%d frozen=%llu hasFrozen=%d",
                 scope, windowIndex, (unsigned) contextId,
                 (unsigned) observedId, hasObservedId ? 1 : 0,
                 (unsigned) observedDisplay, hasObservedDisplay ? 1 : 0,
                 (unsigned) observedMask, hasObservedMask ? 1 : 0,
                 valid, hasValid ? 1 : 0, frozen, hasFrozen ? 1 : 0);
            line("hierarchy=contextfields scope=%s/%u layer=%d class=%.28s renderContext=%d class=%.28s options=%d class=%.24s",
                 scope, windowIndex, contextLayer ? 1 : 0,
                 class_name_or_nil(contextLayer), renderContext ? 1 : 0,
                 class_name_or_nil(renderContext), options ? 1 : 0,
                 class_name_or_nil(options));
            snapshot_dictionary("contextoptions", options);
            snapshot_layer_tree("context", windowIndex, 0, contextLayer, 0,
                                &gLayerBudget);
        }
    }
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        snapshot_layer_tree(scope, windowIndex, viewIndex,
                            collection_object_at(sublayers, index),
                            depth + 1, budget);
    }
}

static void snapshot_view_tree(const char *scope, unsigned windowIndex,
                               unsigned *viewIndex, id view, unsigned depth,
                               unsigned *viewBudget, unsigned *layerBudget)
{
    if (!view || depth > 6 || !viewBudget || *viewBudget == 0) return;
    --*viewBudget;
    const unsigned currentView = (*viewIndex)++;
    unsigned long long hidden = 0;
    const bool hasHidden = read_integer(view, "isHidden", &hidden);
    id layer = read_object(view, "layer");
    id subviews = normalized_collection(read_object(view, "subviews"));
    unsigned long long count = collection_count(subviews);
    line("hierarchy=view scope=%s/%u view=%u depth=%u class=%s hidden=%llu hasHidden=%d layer=%d class=%s subviews=%llu",
         scope, windowIndex, currentView, depth, class_name_or_nil(view),
         hidden, hasHidden, layer ? 1 : 0, class_name_or_nil(layer), count);
    snapshot_layer_tree(scope, windowIndex, currentView, layer, depth, layerBudget);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        snapshot_view_tree(scope, windowIndex, viewIndex,
                           collection_object_at(subviews, index), depth + 1,
                           viewBudget, layerBudget);
    }
}

static void snapshot_window_views(const char *scope, unsigned windowIndex,
                                  id window, id rootViewController)
{
    if (!gViewBudget || !gLayerBudget) return;

    unsigned viewIndex = 0;
    id rootView = read_object(rootViewController, "view");
    id windowSubviews = normalized_collection(read_object(window, "subviews"));
    unsigned long long subviewCount = collection_count(windowSubviews);
    line("hierarchy=window scope=%s/%u rootVCView=%d class=%s subviews=%llu remainingView=%u remainingLayer=%u",
         scope, windowIndex, rootView ? 1 : 0, class_name_or_nil(rootView),
         subviewCount, gViewBudget, gLayerBudget);

    if (rootView) {
        snapshot_view_tree(scope, windowIndex, &viewIndex, rootView, 0,
                           &gViewBudget, &gLayerBudget);
    } else {
        for (unsigned long long index = 0; index < subviewCount && index < 8; ++index) {
            snapshot_view_tree(scope, windowIndex, &viewIndex,
                               collection_object_at(windowSubviews, index), 0,
                               &gViewBudget, &gLayerBudget);
        }
    }

    id windowLayer = read_object(window, "layer");
    snapshot_layer_tree(scope, windowIndex, viewIndex, windowLayer, 0,
                        &gLayerBudget);
}

static void snapshot_window(const char *scope, unsigned index, id window,
                            unsigned sample)
{
    unsigned long long hidden = 0;
    unsigned long long level = 0;
    const bool hasHidden = read_integer(window, "isHidden", &hidden);
    const bool hasLevel = read_integer(window, "windowLevel", &level);
    id layer = read_object(window, "layer");
    id rootViewController = read_object(window, "rootViewController");
    id windowScene = read_object(window, "windowScene");
    line("window=%s/%u class=%s hidden=%llu hasHidden=%d level=%llu hasLevel=%d",
         scope, index, class_name_or_nil(window), hidden, hasHidden, level, hasLevel);
    line("window=%s/%u layer=%d class=%s rootVC=%d class=%s windowScene=%d",
         scope, index, layer ? 1 : 0, class_name_or_nil(layer),
         rootViewController ? 1 : 0, class_name_or_nil(rootViewController),
         windowScene ? 1 : 0);
    if (windowScene) {
        unsigned long long activation = 0;
        unsigned long long orientation = 0;
        const bool hasActivation = read_integer(
            windowScene, "activationState", &activation);
        const bool hasOrientation = read_integer(
            windowScene, "interfaceOrientation", &orientation);
        line("window=%s/%u sceneClass=%s activationState=%llu hasActivation=%d interfaceOrientation=%llu hasOrientation=%d",
             scope, index, class_name_or_nil(windowScene), activation,
             hasActivation ? 1 : 0, orientation, hasOrientation ? 1 : 0);
    }
    if (layer) log_object_field("window", index, layer, "contents");
    if (sample == 5)
        snapshot_window_views(scope, index, window, rootViewController);
}

static void snapshot_windows(const char *scope, id owner, unsigned sample)
{
    id windows = normalized_collection(read_object(owner, "windows"));
    if (!windows) windows = normalized_collection(read_object(owner, "_windows"));
    if (!windows) {
        line("windows=%s present=0", scope);
        return;
    }
    unsigned long long count = 0;
    if ([windows respondsToSelector:@selector(count)])
        count = ((unsigned long long (*)(id, SEL)) objc_msgSend)(windows, @selector(count));
    line("windows=%s present=1 class=%s count=%llu",
         scope, class_name_or_nil(windows), count);
    for (unsigned long long index = 0; index < count && index < 8; ++index) {
        id window = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
            windows, @selector(objectAtIndex:), index);
        if (window) snapshot_window(scope, (unsigned) index, window, sample);
    }
}

static void snapshot(const char *phase, unsigned sample)
{
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
           RTLD_NOW);
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);

    Class workspaceClass = NSClassFromString(@"FBSWorkspace");
    Class sceneClass = NSClassFromString(@"FBScene");
    if (sample == 0) {
        inventory_springboard_classes();
        probe_nonblocking_shared_instances();
    }
    if (sample == 5) {
        gViewBudget = 96;
        gLayerBudget = 240;
        gHostContextCount = 0;
    }
    line("sample=%u phase=%s pid=%d workspaceClass=%d sceneClass=%d",
         sample, phase, getpid(), workspaceClass ? 1 : 0, sceneClass ? 1 : 0);

    id workspace = nil;
    @try {
        if (workspaceClass) {
            SEL existing = NSSelectorFromString(@"_sharedWorkspaceIfExists");
            if ([(id) workspaceClass respondsToSelector:existing])
                workspace = ((id (*)(id, SEL)) objc_msgSend)((id) workspaceClass, existing);
            if (!workspace) {
                SEL shared = NSSelectorFromString(@"sharedWorkspace");
                if ([(id) workspaceClass respondsToSelector:shared])
                    workspace = ((id (*)(id, SEL)) objc_msgSend)((id) workspaceClass, shared);
            }
        }
    } @catch (id ignored) {
        workspace = nil;
    }

    line("sample=%u workspace=%d class=%s", sample, workspace ? 1 : 0,
         class_name_or_nil(workspace));

    id scenes = normalized_collection(read_object(workspace, "scenes"));
    unsigned long long count = 0;
    if (scenes && [scenes respondsToSelector:@selector(count)])
        count = ((unsigned long long (*)(id, SEL)) objc_msgSend)(scenes, @selector(count));
    line("sample=%u scenes=%llu class=%s", sample, count, class_name_or_nil(scenes));

    for (unsigned long long i = 0; scenes && i < count && i < 8; ++i) {
        id scene = ((id (*)(id, SEL, unsigned long long)) objc_msgSend)(
            scenes, @selector(objectAtIndex:), i);
        if (!scene) continue;
        char identifier[72];
        copy_utf8(read_object(scene, "identifier"), identifier, sizeof identifier);
        unsigned long long valid = 0;
        unsigned long long state = 0;
        const bool hasValid = read_integer(scene, "isValid", &valid);
        const bool hasState = read_integer(scene, "activationState", &state);
        line("scene=%u class=%s id=%.64s valid=%d hasValid=%d state=%llu hasState=%d",
             (unsigned) i, class_name_or_nil(scene), identifier,
             valid ? 1 : 0, hasValid ? 1 : 0, state, hasState ? 1 : 0);
        static const char *fields[] = {
            "context", "layer", "layerManager", "definition", "settings",
            "clientSettings", "uiSettings", "hostProcess", "workspace", "delegate"
        };
        for (unsigned f = 0; f < sizeof fields / sizeof fields[0]; ++f)
            log_object_field("scene", (unsigned) i, scene, fields[f]);
        id settings = read_object(scene, "settings");
        if (settings) {
            unsigned long long foreground = 0;
            unsigned long long orientation = 0;
            unsigned long long deactivation = 0;
            const bool hasForeground = read_integer(
                settings, "isForeground", &foreground);
            const bool hasOrientation = read_integer(
                settings, "interfaceOrientation", &orientation);
            const bool hasDeactivation = read_integer(
                settings, "deactivationReasons", &deactivation);
            line("scene=%u settings class=%s foreground=%llu hasForeground=%d orientation=%llu hasOrientation=%d deactivation=0x%llx hasDeactivation=%d",
                 (unsigned) i, class_name_or_nil(settings), foreground,
                 hasForeground ? 1 : 0, orientation, hasOrientation ? 1 : 0,
                 deactivation, hasDeactivation ? 1 : 0);
        }
        id delegate = read_object(scene, "delegate");
        if (delegate) {
            line("scene=%u delegateClass=%s", (unsigned) i,
                 class_name_or_nil(delegate));
            snapshot_windows("scene", delegate, sample);
        }
    }

    Class displayClass = NSClassFromString(@"CADisplay");
    id displays = displayClass ? read_object((id) displayClass, "displays") : nil;
    unsigned long long displayCount = 0;
    if (displays)
        displayCount = ((unsigned long long (*)(id, SEL)) objc_msgSend)(displays,
                                                                       @selector(count));
    id mainDisplay = displayClass ? read_object((id) displayClass, "mainDisplay") : nil;
    line("sample=%u cadisplay=%d list=%llu main=%d", sample, displayClass ? 1 : 0,
         displayCount, mainDisplay ? 1 : 0);

    Class applicationClass = NSClassFromString(@"UIApplication");
    id application = nil;
    @try {
        if (applicationClass) {
            SEL shared = @selector(sharedApplication);
            if ([(id) applicationClass respondsToSelector:shared])
                application = ((id (*)(id, SEL)) objc_msgSend)((id) applicationClass, shared);
        }
    } @catch (id ignored) {
        application = nil;
    }
    id delegate = read_object(application, "delegate");
    id connected = normalized_collection(read_object(application, "connectedScenes"));
    id windows = normalized_collection(read_object(application, "windows"));
    unsigned long long connectedCount = connected
        ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(connected, @selector(count)) : 0;
    unsigned long long windowCount = windows
        ? ((unsigned long long (*)(id, SEL)) objc_msgSend)(windows, @selector(count)) : 0;
    line("sample=%u app=%d delegate=%s scenes=%llu windows=%llu",
         sample, application ? 1 : 0, class_name_or_nil(delegate), connectedCount, windowCount);
    unsigned long long applicationState = 0;
    const bool hasApplicationState = read_integer(
        application, "applicationState", &applicationState);
    line("sample=%u appState=%llu hasAppState=%d",
         sample, applicationState, hasApplicationState ? 1 : 0);
    snapshot_windows("application", application, sample);
}

__attribute__((constructor)) static void h481_observer_constructor(void)
{
    const char *process = getprogname();
    if (!process || strncmp(process, "SpringBoard", 11)) return;
    line("observer load process=%s pid=%d build=H504", process, getpid());
    const double delays[] = { 5.0, 30.0, 90.0, 180.0, 300.0 };
    for (unsigned index = 0; index < sizeof delays / sizeof delays[0]; ++index) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delays[index] * 1e9)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            snapshot("springboard", index);
        });
    }
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 480LL * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        snapshot("springboard", 5);
        dispatch_source_cancel(timer);
    });
    dispatch_resume(timer);
}
