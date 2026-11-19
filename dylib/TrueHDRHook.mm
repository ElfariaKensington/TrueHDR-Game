#define GL_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Carbon/Carbon.h>
#import <OpenGL/OpenGL.h>
#import <IOSurface/IOSurface.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include "TrueHDRConfig.h"
#include "TrueHDRIni.h"
#include "TrueHDRRenderer.h"

// ---------------------------------------------------------------------------
// Global settings, status, and active layer tracking
// ---------------------------------------------------------------------------

static os_unfair_lock gCfgLock = OS_UNFAIR_LOCK_INIT;
static TrueHDRSettings gSettings;
static BOOL gSettingsInitialized = NO;
static uint64_t gIniMtimeNs = 0;
static CFAbsoluteTime gLastIniPoll = 0;
static _Atomic float gCachedHeadroom = 1.0f;

static os_unfair_lock gHookLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<Class> *gHookedCmdBufClasses = nil;
static NSMutableSet<Class> *gHookedDeviceClasses = nil;
static NSMapTable<id<MTLDevice>, id<MTLCommandQueue>> *gDeviceQueues = nil;
static NSHashTable<CAMetalLayer *> *gActiveLayers = nil;
static CFAbsoluteTime gLastStatusWrite = 0;

static __thread BOOL tInLayerConfig = NO;

static NSString *ExpandPath(NSString *p) {
    return [p stringByExpandingTildeInPath];
}

static void EnsureConfigDefaults(void) {
    os_unfair_lock_lock(&gCfgLock);
    if (!gSettingsInitialized) {
        gSettings = TrueHDRDefaultSettings();
        gSettingsInitialized = YES;
    }
    os_unfair_lock_unlock(&gCfgLock);
}

static void SaveConfigFromSettings(const TrueHDRSettings &s) {
    uint64_t mtime = 0;
    if (TrueHDRSaveIni(&s, &mtime)) {
        os_unfair_lock_lock(&gCfgLock);
        gIniMtimeNs = mtime;
        os_unfair_lock_unlock(&gCfgLock);
    }
}

static void LoadConfig(BOOL applyEnv) {
    EnsureConfigDefaults();
    TrueHDRSettings s = TrueHDRDefaultSettings();
    uint64_t mtime = 0;
    TrueHDRLoadIni(&s, &mtime, applyEnv);
    os_unfair_lock_lock(&gCfgLock);
    gSettings = s;
    gIniMtimeNs = mtime;
    gLastIniPoll = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&gCfgLock);
}

static TrueHDRSettings SnapshotSettings(void) {
    EnsureConfigDefaults();
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&gCfgLock);
    if (now - gLastIniPoll >= 0.4) {
        gLastIniPoll = now;
        TrueHDRSettings updated = gSettings;
        uint64_t mtime = gIniMtimeNs;
        os_unfair_lock_unlock(&gCfgLock);
        if (TrueHDRReloadIniIfChanged(&updated, &mtime)) {
            os_unfair_lock_lock(&gCfgLock);
            gSettings = updated;
            gIniMtimeNs = mtime;
            os_unfair_lock_unlock(&gCfgLock);
            return updated;
        }
        os_unfair_lock_lock(&gCfgLock);
    }
    TrueHDRSettings s = gSettings;
    os_unfair_lock_unlock(&gCfgLock);
    return s;
}

static void ConfigNotificationCallback(CFNotificationCenterRef, void *, CFNotificationName, const void *, CFDictionaryRef) {
    LoadConfig(NO);
}

static void MaybeWriteStatus(uint32_t width,
                              uint32_t height,
                              uint32_t outWidth,
                              uint32_t outHeight,
                              MTLPixelFormat fmt,
                              BOOL upscaleActive,
                              int32_t upscaleMode,
                              float gpuMs,
                              const TrueHDRSettings &s) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&gHookLock);
    if (now - gLastStatusWrite < 1.0) {
        os_unfair_lock_unlock(&gHookLock);
        return;
    }
    gLastStatusWrite = now;
    os_unfair_lock_unlock(&gHookLock);

    // Disk I/O off the render thread (it previously stalled a frame every second).
    static dispatch_queue_t statusQ = dispatch_queue_create("truehdr.status", DISPATCH_QUEUE_SERIAL);
    BOOL active = s.enabled && s.hdrEnabled;
    dispatch_async(statusQ, ^{ @autoreleasepool {
    NSString *appName = [[NSProcessInfo processInfo] processName] ?: @"Game";
    NSString *dir = ExpandPath(TRUEHDR_CONFIG_DIR);
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *st = @{
        @"pid": @(getpid()),
        @"app": appName,
        @"width": @(width),
        @"height": @(height),
        @"outputWidth": @(outWidth),
        @"outputHeight": @(outHeight),
        @"pixelFormat": @(fmt),
        @"active": @(active),
        @"upscaleActive": @(upscaleActive),
        @"upscaleMode": @(TrueHDRUpscaleModeKey(upscaleMode)),
        @"gpuMs": @(gpuMs),
        @"updatedAt": @((double)[[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
    if (data) {
        [data writeToFile:ExpandPath(TRUEHDR_STATUS_FILE) atomically:YES];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)TRUEHDR_NOTIFY_STAT,
                                             NULL, NULL, TRUE);
    }
    }});
}

static void RegisterLayer(CAMetalLayer *layer) {
    if (!layer) return;
    os_unfair_lock_lock(&gHookLock);
    if (!gActiveLayers) gActiveLayers = [NSHashTable weakObjectsHashTable];
    [gActiveLayers addObject:layer];
    os_unfair_lock_unlock(&gHookLock);
}

static void ShowToastOnAllLayers(NSString *msg);

// ---------------------------------------------------------------------------
// Associated context & Proxy CAMetalDrawable
// ---------------------------------------------------------------------------

static const void *kLayerCtxKey = &kLayerCtxKey;

static TrueHDRLayerContext *GetOrCreateLayerContext(CAMetalLayer *layer) {
    if (!layer || ![layer isKindOfClass:[CAMetalLayer class]]) return nil;
    TrueHDRLayerContext *ctx = objc_getAssociatedObject(layer, kLayerCtxKey);
    if (!ctx) {
        ctx = [[TrueHDRLayerContext alloc] initWithDevice:layer.device];
        objc_setAssociatedObject(layer, kLayerCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RegisterLayer(layer);
    }
    return ctx;
}

static void ShowToastOnAllLayers(NSString *msg) {
    os_unfair_lock_lock(&gHookLock);
    NSArray<CAMetalLayer *> *layers = gActiveLayers ? [gActiveLayers allObjects] : @[];
    os_unfair_lock_unlock(&gHookLock);
    for (CAMetalLayer *l in layers) {
        TrueHDRLayerContext *ctx = objc_getAssociatedObject(l, kLayerCtxKey);
        if (ctx) [ctx showToast:msg onLayer:l];
    }
}

static void (*orig_presentDrawable)(id, SEL, id<MTLDrawable>) = nullptr;
static void (*orig_presentDrawableAtTime)(id, SEL, id<MTLDrawable>, CFTimeInterval) = nullptr;
static void (*orig_presentDrawableAfterMinDur)(id, SEL, id<MTLDrawable>, CFTimeInterval) = nullptr;
static void (*orig_mtl4SignalDrawable)(id, SEL, id) = nullptr;
static void (*orig_mtl4WaitForDrawable)(id, SEL, id) = nullptr;
// `new*` methods return +1; the annotations keep ARC ownership balanced through the swizzle.
static NS_RETURNS_RETAINED id (*orig_newMTL4Queue)(id, SEL) = nullptr;
static NS_RETURNS_RETAINED id (*orig_newMTL4QueueDesc)(id, SEL, id, NSError **) = nullptr;
static NSMapTable<id<MTLDevice>, id<MTLEvent>> *gDeviceEvents = nil;
static NSMutableSet<Class> *gHookedMTL4QueueClasses = nil;
static atomic_uint_fast64_t gEventSeq = 0;
static BOOL gDebug = NO;
#define THLog(fmt, ...) do { if (gDebug) NSLog(@"[TrueHDR-Game] " fmt, ##__VA_ARGS__); } while(0)

@interface TrueHDRDrawable : NSObject <CAMetalDrawable>
@property (nonatomic, strong) id<CAMetalDrawable> realDrawable;
@property (nonatomic, strong) id<MTLTexture> gameTexture;
@property (nonatomic, weak) CAMetalLayer *metalLayer;
@property (nonatomic, strong) TrueHDRLayerContext *ctx;
@property (nonatomic, assign) BOOL presentedViaCmdBuf;
@property (nonatomic, assign) BOOL recycled;
@property (nonatomic, strong, nullable) id<MTLEvent> waitEvent;
@property (nonatomic, assign) uint64_t waitValue;
@end

static id<MTLEvent> GetEventForDevice(id<MTLDevice> dev) {
    if (!dev) return nil;
    os_unfair_lock_lock(&gHookLock);
    if (!gDeviceEvents) gDeviceEvents = [NSMapTable strongToStrongObjectsMapTable];
    id<MTLEvent> ev = [gDeviceEvents objectForKey:dev];
    os_unfair_lock_unlock(&gHookLock);
    if (!ev) {
        ev = [dev newEvent];
        if (ev) {
            os_unfair_lock_lock(&gHookLock);
            if (![gDeviceEvents objectForKey:dev]) [gDeviceEvents setObject:ev forKey:dev];
            else ev = [gDeviceEvents objectForKey:dev];
            os_unfair_lock_unlock(&gHookLock);
        }
    }
    return ev;
}

static void EncodeProxyIntoCommandBuffer(id<MTLCommandBuffer> cb, TrueHDRDrawable *proxy) {
    if (!cb || !proxy) return;
    // Game/Wine render threads often have no draining autorelease pool; keep per-frame
    // encoders/descriptors from piling up for the life of the process.
    @autoreleasepool {
    if (proxy.waitEvent && proxy.waitValue > 0) {
        [cb encodeWaitForEvent:proxy.waitEvent value:proxy.waitValue];
        proxy.waitEvent = nil;
        proxy.waitValue = 0;
    }
    TrueHDRSettings s = SnapshotSettings();
    id<MTLTexture> dstTex = proxy.realDrawable.texture;
    [proxy.ctx encodeTrueHDR:cb
                   sourceTex:proxy.gameTexture
                     destTex:dstTex
                    settings:s
               isLinearInput:TrueHDRPixelFormatIsLinear(proxy.ctx.desiredPixelFormat)];
    MaybeWriteStatus((uint32_t)proxy.gameTexture.width,
                     (uint32_t)proxy.gameTexture.height,
                     (uint32_t)dstTex.width,
                     (uint32_t)dstTex.height,
                     proxy.ctx.desiredPixelFormat,
                     proxy.ctx.lastUpscaleActive,
                     proxy.ctx.lastUpscaleMode,
                     proxy.ctx.lastGpuMs,
                     s);
    }
}

static id<MTLCommandQueue> GetQueueForDevice(id<MTLDevice> dev) {
    if (!dev) return nil;
    os_unfair_lock_lock(&gHookLock);
    if (!gDeviceQueues) gDeviceQueues = [NSMapTable strongToStrongObjectsMapTable];
    id<MTLCommandQueue> q = [gDeviceQueues objectForKey:dev];
    os_unfair_lock_unlock(&gHookLock);
    if (!q) {
        id<MTLCommandQueue> created = [dev newCommandQueue];
        if (created) created.label = @"TrueHDR-SyncQueue";
        os_unfair_lock_lock(&gHookLock);
        q = [gDeviceQueues objectForKey:dev];
        if (!q && created) {
            [gDeviceQueues setObject:created forKey:dev];
            q = created;
        }
        os_unfair_lock_unlock(&gHookLock);
    }
    return q;
}

@implementation TrueHDRDrawable

- (void)dealloc {
    if (!_recycled && _ctx && _gameTexture) {
        [_ctx recycleGameTexture:_gameTexture];
    }
}

- (id<MTLTexture>)texture {
    return _gameTexture;
}

- (CAMetalLayer *)layer {
    return _metalLayer ?: _realDrawable.layer;
}

- (NSUInteger)drawableID {
    return _realDrawable.drawableID;
}

- (CFTimeInterval)presentedTime {
    return _realDrawable.presentedTime;
}

- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block {
    [_realDrawable addPresentedHandler:block];
}

- (void)encodeAndPresentWithMode:(int)mode time:(CFTimeInterval)t {
    if (_presentedViaCmdBuf) return;
    _presentedViaCmdBuf = YES;
    static BOOL loggedPresent = NO;
    if (!loggedPresent) {
        loggedPresent = YES;
        THLog(@"encodeAndPresentWithMode mode=%d waitVal=%llu fmt=%lu", mode, _waitValue, (unsigned long)_ctx.desiredPixelFormat);
    }
    @autoreleasepool {
    id<MTLDevice> dev = _gameTexture.device ?: _realDrawable.texture.device;
    id<MTLCommandQueue> q = GetQueueForDevice(dev);
    if (!q) {
        [_realDrawable present];
        return;
    }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    cb.label = @"TrueHDR-Present";
    EncodeProxyIntoCommandBuffer(cb, self);
    __weak TrueHDRLayerContext *weakCtx = _ctx;
    id<MTLTexture> gTex = _gameTexture;
    if (weakCtx && gTex) {
        [cb addCompletedHandler:^(id<MTLCommandBuffer> _) {
            [weakCtx recycleGameTexture:gTex];
        }];
    }
    _recycled = YES;
    if (mode == 1 && orig_presentDrawableAtTime && [cb respondsToSelector:@selector(presentDrawable:atTime:)]) {
        orig_presentDrawableAtTime(cb, @selector(presentDrawable:atTime:), _realDrawable, t);
    } else if (mode == 2 && orig_presentDrawableAfterMinDur && [cb respondsToSelector:@selector(presentDrawable:afterMinimumDuration:)]) {
        orig_presentDrawableAfterMinDur(cb, @selector(presentDrawable:afterMinimumDuration:), _realDrawable, t);
    } else if (orig_presentDrawable) {
        orig_presentDrawable(cb, @selector(presentDrawable:), _realDrawable);
    } else {
        [cb presentDrawable:_realDrawable];
    }
    [cb commit];
    }
}

- (void)present {
    [self encodeAndPresentWithMode:0 time:0];
}

- (void)presentAtTime:(CFTimeInterval)presentationTime {
    [self encodeAndPresentWithMode:1 time:presentationTime];
}

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    [self encodeAndPresentWithMode:2 time:duration];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return _realDrawable;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [_realDrawable respondsToSelector:aSelector];
}

@end

// ---------------------------------------------------------------------------
// MTLCommandBuffer & MTLDevice swizzling
// ---------------------------------------------------------------------------

static void FinishProxyCommandBuffer(id<MTLCommandBuffer> cb, TrueHDRDrawable *proxy) {
    proxy.presentedViaCmdBuf = YES;
    EncodeProxyIntoCommandBuffer(cb, proxy);
    __weak TrueHDRLayerContext *weakCtx = proxy.ctx;
    id<MTLTexture> gTex = proxy.gameTexture;
    if (weakCtx && gTex && !proxy.recycled) {
        proxy.recycled = YES;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> _) {
            [weakCtx recycleGameTexture:gTex];
        }];
    }
}

static void th_presentDrawable(id self, SEL _cmd, id<MTLDrawable> drawable) {
    static int gPresentDbg = 0;
    if (gDebug && gPresentDbg < 5) {
        gPresentDbg++;
        THLog(@"presentDrawable called on %@ with drawable %@", NSStringFromClass([self class]), NSStringFromClass([drawable class]));
    }
    if ([drawable isKindOfClass:[TrueHDRDrawable class]]) {
        TrueHDRDrawable *proxy = (TrueHDRDrawable *)drawable;
        FinishProxyCommandBuffer((id<MTLCommandBuffer>)self, proxy);
        orig_presentDrawable(self, _cmd, proxy.realDrawable);
        return;
    }
    orig_presentDrawable(self, _cmd, drawable);
}

static void th_presentDrawableAtTime(id self, SEL _cmd, id<MTLDrawable> drawable, CFTimeInterval t) {
    if ([drawable isKindOfClass:[TrueHDRDrawable class]]) {
        TrueHDRDrawable *proxy = (TrueHDRDrawable *)drawable;
        FinishProxyCommandBuffer((id<MTLCommandBuffer>)self, proxy);
        orig_presentDrawableAtTime(self, _cmd, proxy.realDrawable, t);
        return;
    }
    orig_presentDrawableAtTime(self, _cmd, drawable, t);
}

static void th_presentDrawableAfterMinDur(id self, SEL _cmd, id<MTLDrawable> drawable, CFTimeInterval dur) {
    if ([drawable isKindOfClass:[TrueHDRDrawable class]]) {
        TrueHDRDrawable *proxy = (TrueHDRDrawable *)drawable;
        FinishProxyCommandBuffer((id<MTLCommandBuffer>)self, proxy);
        orig_presentDrawableAfterMinDur(self, _cmd, proxy.realDrawable, dur);
        return;
    }
    orig_presentDrawableAfterMinDur(self, _cmd, drawable, dur);
}

static void th_mtl4SignalDrawable(id self, SEL _cmd, id drawable) {
    if ([drawable isKindOfClass:[TrueHDRDrawable class]]) {
        TrueHDRDrawable *proxy = (TrueHDRDrawable *)drawable;
        id<MTLDevice> dev = [self respondsToSelector:@selector(device)] ? [self device] : proxy.gameTexture.device;
        id<MTLEvent> ev = GetEventForDevice(dev);
        SEL sigSel = @selector(signalEvent:value:);
        static BOOL loggedSignal = NO;
        if (ev && [self respondsToSelector:sigSel]) {
            uint64_t val = atomic_fetch_add(&gEventSeq, 1) + 1;
            ((void (*)(id, SEL, id<MTLEvent>, uint64_t))objc_msgSend)(self, sigSel, ev, val);
            proxy.waitEvent = ev;
            proxy.waitValue = val;
            if (!loggedSignal) { loggedSignal = YES; THLog(@"mtl4SignalDrawable synced via MTLEvent val=%llu", val); }
            return;
        }
        if (!loggedSignal) { loggedSignal = YES; THLog(@"mtl4SignalDrawable fallback (ev=%@ responds=%d)", ev, (int)[self respondsToSelector:sigSel]); }
    }
    if (orig_mtl4SignalDrawable) {
        orig_mtl4SignalDrawable(self, _cmd, drawable);
    }
}

static void th_mtl4WaitForDrawable(id self, SEL _cmd, id drawable) {
    id target = [drawable isKindOfClass:[TrueHDRDrawable class]] ? ((TrueHDRDrawable *)drawable).realDrawable : drawable;
    if (orig_mtl4WaitForDrawable) {
        orig_mtl4WaitForDrawable(self, _cmd, target);
    }
}

static void HookMTL4QueueInstance(id queue) {
    if (!queue) return;
    Class qCls = [queue class];
    os_unfair_lock_lock(&gHookLock);
    if (!gHookedMTL4QueueClasses) gHookedMTL4QueueClasses = [NSMutableSet set];
    BOOL needHook = ![gHookedMTL4QueueClasses containsObject:qCls];
    if (needHook) [gHookedMTL4QueueClasses addObject:qCls];
    os_unfair_lock_unlock(&gHookLock);
    if (needHook) {
        Method m = class_getInstanceMethod(qCls, @selector(signalDrawable:));
        if (m) {
            orig_mtl4SignalDrawable = (decltype(orig_mtl4SignalDrawable))method_setImplementation(m, (IMP)th_mtl4SignalDrawable);
            THLog(@"Hooked MTL4 queue class %@", NSStringFromClass(qCls));
        }
        Method mw = class_getInstanceMethod(qCls, @selector(waitForDrawable:));
        if (mw) {
            orig_mtl4WaitForDrawable = (decltype(orig_mtl4WaitForDrawable))method_setImplementation(mw, (IMP)th_mtl4WaitForDrawable);
        }
    }
}

static NS_RETURNS_RETAINED id th_newMTL4Queue(id self, SEL _cmd) {
    id q = orig_newMTL4Queue(self, _cmd);
    HookMTL4QueueInstance(q);
    return q;
}

static NS_RETURNS_RETAINED id th_newMTL4QueueDesc(id self, SEL _cmd, id desc, NSError **err) {
    id q = orig_newMTL4QueueDesc(self, _cmd, desc, err);
    HookMTL4QueueInstance(q);
    return q;
}

static NSHashTable *gProbedDevices = nil;

// Called from nextDrawable every frame: must be a no-op after the first call per device.
// (Previously it created a new MTL4CommandQueue + MTLCommandBuffer every frame and leaked the
// queue, which grew GPU/driver memory without bound and corrupted textures / froze games.)
static void HookMetalClassesForDevice(id<MTLDevice> dev) {
    if (!dev) return;
    os_unfair_lock_lock(&gHookLock);
    if (!gProbedDevices) gProbedDevices = [NSHashTable weakObjectsHashTable];
    BOOL alreadyProbed = [gProbedDevices containsObject:dev];
    if (!alreadyProbed) [gProbedDevices addObject:dev];
    os_unfair_lock_unlock(&gHookLock);
    if (alreadyProbed) return;

    @autoreleasepool {
    Class devCls = [dev class];
    os_unfair_lock_lock(&gHookLock);
    if (!gHookedDeviceClasses) gHookedDeviceClasses = [NSMutableSet set];
    BOOL needDevHook = ![gHookedDeviceClasses containsObject:devCls];
    if (needDevHook) [gHookedDeviceClasses addObject:devCls];
    os_unfair_lock_unlock(&gHookLock);

    if (needDevHook) {
        Method m3 = class_getInstanceMethod(devCls, @selector(newMTL4CommandQueue));
        if (m3) orig_newMTL4Queue = (decltype(orig_newMTL4Queue))method_setImplementation(m3, (IMP)th_newMTL4Queue);
        Method m4 = class_getInstanceMethod(devCls, @selector(newMTL4CommandQueueWithDescriptor:error:));
        if (m4) orig_newMTL4QueueDesc = (decltype(orig_newMTL4QueueDesc))method_setImplementation(m4, (IMP)th_newMTL4QueueDesc);
    }

    if ([dev respondsToSelector:@selector(newMTL4CommandQueue)]) {
        // `new` returns +1; tell ARC so the probe queue is released right after hooking its class.
        id q4 = ((NS_RETURNS_RETAINED id (*)(id, SEL))objc_msgSend)(dev, @selector(newMTL4CommandQueue));
        HookMTL4QueueInstance(q4);
    }

    id<MTLCommandQueue> q = GetQueueForDevice(dev);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    if (!cb) return;
    Class cbCls = [cb class];

    os_unfair_lock_lock(&gHookLock);
    if (!gHookedCmdBufClasses) gHookedCmdBufClasses = [NSMutableSet set];
    BOOL needCBHook = ![gHookedCmdBufClasses containsObject:cbCls];
    if (needCBHook) [gHookedCmdBufClasses addObject:cbCls];
    os_unfair_lock_unlock(&gHookLock);

    if (needCBHook) {
        Method p1 = class_getInstanceMethod(cbCls, @selector(presentDrawable:));
        if (p1) orig_presentDrawable = (decltype(orig_presentDrawable))method_setImplementation(p1, (IMP)th_presentDrawable);
        Method p2 = class_getInstanceMethod(cbCls, @selector(presentDrawable:atTime:));
        if (p2) orig_presentDrawableAtTime = (decltype(orig_presentDrawableAtTime))method_setImplementation(p2, (IMP)th_presentDrawableAtTime);
        Method p3 = class_getInstanceMethod(cbCls, @selector(presentDrawable:afterMinimumDuration:));
        if (p3) orig_presentDrawableAfterMinDur = (decltype(orig_presentDrawableAfterMinDur))method_setImplementation(p3, (IMP)th_presentDrawableAfterMinDur);
        THLog(@"Hooked cmdBuf class %@ (p1=%p p2=%p p3=%p)", NSStringFromClass(cbCls), p1, p2, p3);
    }
    }
}

// ---------------------------------------------------------------------------
// CAMetalLayer swizzling
// ---------------------------------------------------------------------------

static void (*orig_setDevice)(id, SEL, id<MTLDevice>) = nullptr;
static void (*orig_setPixelFormat)(id, SEL, MTLPixelFormat) = nullptr;
static MTLPixelFormat (*orig_pixelFormat)(id, SEL) = nullptr;
static void (*orig_setFramebufferOnly)(id, SEL, BOOL) = nullptr;
static BOOL (*orig_framebufferOnly)(id, SEL) = nullptr;
static void (*orig_setColorspace)(id, SEL, CGColorSpaceRef) = nullptr;
static void (*orig_setWantsEDR)(id, SEL, BOOL) = nullptr;
static void (*orig_setEDRMetadata)(id, SEL, id) = nullptr;
static void (*orig_setDrawableSize)(id, SEL, CGSize) = nullptr;
static CGSize (*orig_drawableSize)(id, SEL) = nullptr;
static id<CAMetalDrawable> (*orig_nextDrawable)(id, SEL) = nullptr;
static void HookWineApplicationIfNeeded(void);

static CGSize ComputeGameSizeForLayer(CAMetalLayer *layer, TrueHDRLayerContext *ctx) {
    if (ctx && ctx.hasDesiredDrawableSize && ctx.desiredDrawableSize.width >= 64.0 && ctx.desiredDrawableSize.height >= 64.0) {
        return ctx.desiredDrawableSize;
    }
    CGFloat sc = fmax(1.0, layer.contentsScale);
    CGSize bsz = layer.bounds.size;
    if (bsz.width >= 32.0 && bsz.height >= 32.0) {
        return CGSizeMake(round(bsz.width * sc), round(bsz.height * sc));
    }
    return orig_drawableSize ? orig_drawableSize(layer, @selector(drawableSize)) : CGSizeZero;
}

static CGSize ComputeUpscaledDrawableSize(CGSize gameSz, const TrueHDRSettings &s) {
    if (!(s.enabled && s.upscaleEnabled) || gameSz.width < 64.0 || gameSz.height < 64.0) {
        return gameSz;
    }
    double scale = fmin(3840.0 / gameSz.width, 2400.0 / gameSz.height);
    if (scale <= 1.02) return gameSz;
    CGFloat w = (CGFloat)fmin(4096.0, fmax(64.0, round(gameSz.width * scale)));
    CGFloat h = (CGFloat)fmin(2400.0, fmax(64.0, round(gameSz.height * scale)));
    return CGSizeMake(w, h);
}

static CGColorSpaceRef ExtendedLinearDisplayP3(void) {
    static CGColorSpaceRef cs = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    });
    return cs;
}

static void EnforceEDROnLayer(CAMetalLayer *layer) {
    if (!layer || tInLayerConfig) return;
    CGColorSpaceRef targetCS = ExtendedLinearDisplayP3();
    BOOL needFmt = orig_pixelFormat && (orig_pixelFormat(layer, @selector(pixelFormat)) != MTLPixelFormatRGBA16Float);
    BOOL needFB  = orig_framebufferOnly && (orig_framebufferOnly(layer, @selector(framebufferOnly)) != NO);
    BOOL needEDR = !layer.wantsExtendedDynamicRangeContent;
    BOOL needCS  = (layer.colorspace != targetCS);
    BOOL needMeta = (layer.EDRMetadata != nil);
    if (!needFmt && !needFB && !needEDR && !needCS && !needMeta) return;

    tInLayerConfig = YES;
    if (needFmt && orig_setPixelFormat) orig_setPixelFormat(layer, @selector(setPixelFormat:), MTLPixelFormatRGBA16Float);
    if (needFB && orig_setFramebufferOnly) orig_setFramebufferOnly(layer, @selector(setFramebufferOnly:), NO);
    if (needEDR && orig_setWantsEDR) orig_setWantsEDR(layer, @selector(setWantsExtendedDynamicRangeContent:), YES);
    if (needCS && orig_setColorspace) orig_setColorspace(layer, @selector(setColorspace:), targetCS);
    if (needMeta && orig_setEDRMetadata) orig_setEDRMetadata(layer, @selector(setEDRMetadata:), nil);
    tInLayerConfig = NO;
}

static void th_setDevice(id self, SEL _cmd, id<MTLDevice> dev) {
    orig_setDevice(self, _cmd, dev);
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) return;
    CAMetalLayer *layer = (CAMetalLayer *)self;
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext(layer);
    if (!ctx) return;
    ctx.device = dev;
    HookMetalClassesForDevice(dev);
    if (TrueHDRPixelFormatIsSupportedSwapchain(ctx.desiredPixelFormat)) {
        EnforceEDROnLayer(layer);
    }
}

static void th_setPixelFormat(id self, SEL _cmd, MTLPixelFormat fmt) {
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) { orig_setPixelFormat(self, _cmd, fmt); return; }
    CAMetalLayer *layer = (CAMetalLayer *)self;
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext(layer);
    if (!ctx) { orig_setPixelFormat(self, _cmd, fmt); return; }
    ctx.desiredPixelFormat = fmt;
    if (TrueHDRPixelFormatIsSupportedSwapchain(fmt)) {
        EnforceEDROnLayer(layer);
    } else {
        orig_setPixelFormat(self, _cmd, fmt);
    }
}

static MTLPixelFormat th_pixelFormat(id self, SEL _cmd) {
    if (![self isKindOfClass:[CAMetalLayer class]]) return orig_pixelFormat(self, _cmd);
    TrueHDRLayerContext *ctx = objc_getAssociatedObject(self, kLayerCtxKey);
    return ctx ? ctx.desiredPixelFormat : orig_pixelFormat(self, _cmd);
}

static void th_setFramebufferOnly(id self, SEL _cmd, BOOL fbOnly) {
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) { orig_setFramebufferOnly(self, _cmd, fbOnly); return; }
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext((CAMetalLayer *)self);
    if (!ctx) { orig_setFramebufferOnly(self, _cmd, fbOnly); return; }
    ctx.desiredFramebufferOnly = fbOnly;
    orig_setFramebufferOnly(self, _cmd, NO);
}

static BOOL th_framebufferOnly(id self, SEL _cmd) {
    if (![self isKindOfClass:[CAMetalLayer class]]) return orig_framebufferOnly(self, _cmd);
    TrueHDRLayerContext *ctx = objc_getAssociatedObject(self, kLayerCtxKey);
    return ctx ? ctx.desiredFramebufferOnly : orig_framebufferOnly(self, _cmd);
}

static void th_setColorspace(id self, SEL _cmd, CGColorSpaceRef cs) {
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) { orig_setColorspace(self, _cmd, cs); return; }
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext((CAMetalLayer *)self);
    if (!ctx) { orig_setColorspace(self, _cmd, cs); return; }
    ctx.desiredColorspace = cs;
    if (TrueHDRPixelFormatIsSupportedSwapchain(ctx.desiredPixelFormat)) {
        orig_setColorspace(self, _cmd, ExtendedLinearDisplayP3());
    } else {
        orig_setColorspace(self, _cmd, cs);
    }
}

static void th_setWantsEDR(id self, SEL _cmd, BOOL edr) {
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) { orig_setWantsEDR(self, _cmd, edr); return; }
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext((CAMetalLayer *)self);
    if (!ctx) { orig_setWantsEDR(self, _cmd, edr); return; }
    ctx.desiredEDR = edr;
    orig_setWantsEDR(self, _cmd, YES);
}

static void th_setEDRMetadata(id self, SEL _cmd, id meta) {
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) { orig_setEDRMetadata(self, _cmd, meta); return; }
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext((CAMetalLayer *)self);
    if (!ctx) { orig_setEDRMetadata(self, _cmd, meta); return; }
    ctx.desiredEDRMetadata = meta;
    orig_setEDRMetadata(self, _cmd, nil);
}

static void th_setDrawableSize(id self, SEL _cmd, CGSize size) {
    if (tInLayerConfig || ![self isKindOfClass:[CAMetalLayer class]]) {
        orig_setDrawableSize(self, _cmd, size);
        return;
    }
    CAMetalLayer *layer = (CAMetalLayer *)self;
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext(layer);
    if (!ctx) {
        orig_setDrawableSize(self, _cmd, size);
        return;
    }
    ctx.desiredDrawableSize = size;
    ctx.hasDesiredDrawableSize = (size.width >= 64.0 && size.height >= 64.0);
    TrueHDRSettings s = SnapshotSettings();
    CGSize target = ctx.hasDesiredDrawableSize ? ComputeUpscaledDrawableSize(size, s) : size;
    tInLayerConfig = YES;
    orig_setDrawableSize(self, _cmd, target);
    tInLayerConfig = NO;
}

static CGSize th_drawableSize(id self, SEL _cmd) {
    if (![self isKindOfClass:[CAMetalLayer class]]) return orig_drawableSize(self, _cmd);
    CAMetalLayer *layer = (CAMetalLayer *)self;
    TrueHDRLayerContext *ctx = objc_getAssociatedObject(layer, kLayerCtxKey);
    if (ctx) {
        if (ctx.hasDesiredDrawableSize) return ctx.desiredDrawableSize;
        if (ctx.lastUpscaleActive) {
            CGSize g = ComputeGameSizeForLayer(layer, ctx);
            if (g.width >= 64.0 && g.height >= 64.0) return g;
        }
    }
    return orig_drawableSize(self, _cmd);
}

static id<CAMetalDrawable> th_nextDrawable(id self, SEL _cmd) {
    if (![self isKindOfClass:[CAMetalLayer class]]) return orig_nextDrawable(self, _cmd);
    CAMetalLayer *layer = (CAMetalLayer *)self;
    TrueHDRLayerContext *ctx = GetOrCreateLayerContext(layer);
    if (!ctx) return orig_nextDrawable(self, _cmd);
    if (layer.device) {
        HookMetalClassesForDevice(layer.device);
    }
    if (TrueHDRPixelFormatIsSupportedSwapchain(ctx.desiredPixelFormat)) {
        EnforceEDROnLayer(layer);
    }
    TrueHDRSettings s = SnapshotSettings();
    CGSize gameSz = ComputeGameSizeForLayer(layer, ctx);
    if (orig_setDrawableSize && orig_drawableSize && gameSz.width >= 64.0 && gameSz.height >= 64.0) {
        CGSize targetSz = ComputeUpscaledDrawableSize(gameSz, s);
        CGSize curSz = orig_drawableSize(layer, @selector(drawableSize));
        if (fabs(curSz.width - targetSz.width) > 0.5 || fabs(curSz.height - targetSz.height) > 0.5) {
            tInLayerConfig = YES;
            orig_setDrawableSize(layer, @selector(setDrawableSize:), targetSz);
            tInLayerConfig = NO;
        }
    }
    id<CAMetalDrawable> real = orig_nextDrawable(self, _cmd);
    THLog(@"nextDrawable -> real=%@ fmt=%lu", real, (unsigned long)ctx.desiredPixelFormat);
    if (!real) return nil;
    HookWineApplicationIfNeeded();
    ctx.viewSize = layer.bounds.size;
    ctx.iniPath = TrueHDRResolveIniPath();
    ctx.edrHeadroom = atomic_load(&gCachedHeadroom);
    if (!TrueHDRPixelFormatIsSupportedSwapchain(ctx.desiredPixelFormat)) {
        return real;
    }
    id<MTLTexture> gameTex = [ctx acquireGameTextureForDrawable:real pixelFormat:ctx.desiredPixelFormat gameSize:gameSz];
    if (!gameTex) return real;

    TrueHDRDrawable *proxy = [[TrueHDRDrawable alloc] init];
    proxy.realDrawable = real;
    proxy.gameTexture = gameTex;
    proxy.metalLayer = layer;
    proxy.ctx = ctx;
    return proxy;
}

// ---------------------------------------------------------------------------
// OpenGL (NSOpenGLContext / WineOpenGLContext) -> Metal EDR + 4K Bridge
// ---------------------------------------------------------------------------

struct GLFns {
    bool ready;
    void (*genFramebuffers)(int, uint32_t *);
    void (*deleteFramebuffers)(int, const uint32_t *);
    void (*bindFramebuffer)(uint32_t, uint32_t);
    void (*framebufferTexture2D)(uint32_t, uint32_t, uint32_t, uint32_t, int);
    void (*blitFramebuffer)(int, int, int, int, int, int, int, int, uint32_t, uint32_t);
    void (*genTextures)(int, uint32_t *);
    void (*deleteTextures)(int, const uint32_t *);
    void (*bindTexture)(uint32_t, uint32_t);
    void (*getIntegerv)(uint32_t, int32_t *);
    uint8_t (*isEnabled)(uint32_t);
    void (*enable)(uint32_t);
    void (*disable)(uint32_t);
    void (*readBuffer)(uint32_t);
    void (*flush)(void);
    uint32_t (*getError)(void);
};

static const GLFns *GetGLFns(void) {
    static GLFns fn = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
        auto sym = [h](const char *n) -> void * {
            void *p = dlsym(RTLD_DEFAULT, n);
            return p ? p : (h ? dlsym(h, n) : nullptr);
        };
        fn.genFramebuffers = (decltype(fn.genFramebuffers))sym("glGenFramebuffers");
        fn.deleteFramebuffers = (decltype(fn.deleteFramebuffers))sym("glDeleteFramebuffers");
        fn.bindFramebuffer = (decltype(fn.bindFramebuffer))sym("glBindFramebuffer");
        fn.framebufferTexture2D = (decltype(fn.framebufferTexture2D))sym("glFramebufferTexture2D");
        fn.blitFramebuffer = (decltype(fn.blitFramebuffer))sym("glBlitFramebuffer");
        fn.genTextures = (decltype(fn.genTextures))sym("glGenTextures");
        fn.deleteTextures = (decltype(fn.deleteTextures))sym("glDeleteTextures");
        fn.bindTexture = (decltype(fn.bindTexture))sym("glBindTexture");
        fn.getIntegerv = (decltype(fn.getIntegerv))sym("glGetIntegerv");
        fn.isEnabled = (decltype(fn.isEnabled))sym("glIsEnabled");
        fn.enable = (decltype(fn.enable))sym("glEnable");
        fn.disable = (decltype(fn.disable))sym("glDisable");
        fn.readBuffer = (decltype(fn.readBuffer))sym("glReadBuffer");
        fn.flush = (decltype(fn.flush))sym("glFlush");
        fn.getError = (decltype(fn.getError))sym("glGetError");
        fn.ready = fn.genFramebuffers && fn.bindFramebuffer && fn.framebufferTexture2D &&
                   fn.blitFramebuffer && fn.genTextures && fn.bindTexture &&
                   fn.getIntegerv && fn.flush;
    });
    return fn.ready ? &fn : nullptr;
}

@interface TrueHDRMetalView : NSView
@end

@implementation TrueHDRMetalView
- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

@interface TrueHDRGLBridge : NSObject {
@public
    os_unfair_lock _lock;
}
@property (nonatomic, strong, nullable) NSWindow *overlayWindow;
@property (nonatomic, strong, nullable) CAMetalLayer *metalLayer;
@property (nonatomic, strong, nullable) TrueHDRLayerContext *ctx;
@property (nonatomic, strong, nullable) id<MTLDevice> device;
@property (nonatomic, strong, nullable) id<MTLTexture> srcTex;
@property (nonatomic, weak, nullable) NSView *attachedView;
@property (nonatomic, assign) IOSurfaceRef ioSurf;
@property (nonatomic, assign) uint32_t glTex;
@property (nonatomic, assign) uint32_t glFbo;
@property (nonatomic, assign) uint32_t texW;
@property (nonatomic, assign) uint32_t texH;
@property (nonatomic, assign) CGSize viewPts;
@property (nonatomic, assign) CGFloat viewScale;
@property (nonatomic, assign) BOOL wantsBestRes;
@property (nonatomic, assign) BOOL setupQueued;
@property (nonatomic, assign) CFAbsoluteTime lastSyncTime;
@end

@implementation TrueHDRGLBridge
- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _viewScale = 1.0;
    }
    return self;
}
- (void)dealloc {
    if (_ioSurf) { CFRelease(_ioSurf); _ioSurf = NULL; }
    NSWindow *ow = _overlayWindow;
    _overlayWindow = nil;
    CAMetalLayer *ml = _metalLayer;
    _metalLayer = nil;
    if (ow || ml) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ow) {
                [ow.parentWindow removeChildWindow:ow];
                [ow orderOut:nil];
                [ow close];
            }
            if (ml && ml.superlayer && !ow) {
                [ml removeFromSuperlayer];
            }
        });
    }
}
@end

static const void *kGLBridgeKey = &kGLBridgeKey;
static void (*orig_glFlushBuffer)(id, SEL) = nullptr;
static void (*orig_wineGlFlushBuffer)(id, SEL) = nullptr;
static __thread BOOL tInGLFlush = NO;

static TrueHDRGLBridge *GetOrCreateGLBridge(NSOpenGLContext *glCtx) {
    TrueHDRGLBridge *b = objc_getAssociatedObject(glCtx, kGLBridgeKey);
    if (!b) {
        b = [[TrueHDRGLBridge alloc] init];
        objc_setAssociatedObject(glCtx, kGLBridgeKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return b;
}

static void EnsureGLSurfaceLocked(TrueHDRGLBridge *b, CGLContextObj cgl, uint32_t w, uint32_t h, const GLFns *gl) {
    if (!b.device) {
        b.device = MTLCreateSystemDefaultDevice();
    }
    if (b.ioSurf && b.srcTex && b.texW == w && b.texH == h && b.glFbo != 0) return;

    if (b.ioSurf) { CFRelease(b.ioSurf); b.ioSurf = NULL; }
    b.srcTex = nil;
    if (b.glFbo && gl->deleteFramebuffers) { uint32_t f = b.glFbo; gl->deleteFramebuffers(1, &f); b.glFbo = 0; }
    if (b.glTex && gl->deleteTextures) { uint32_t t = b.glTex; gl->deleteTextures(1, &t); b.glTex = 0; }

    NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceWidth: @(w),
        (__bridge NSString *)kIOSurfaceHeight: @(h),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
        (__bridge NSString *)kIOSurfacePixelFormat: @((unsigned int)0x42475241u)
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) return;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> mtlTex = [b.device newTextureWithDescriptor:td iosurface:surf plane:0];
    if (!mtlTex) { CFRelease(surf); return; }
    mtlTex.label = @"TrueHDR-GLSource";

    constexpr uint32_t GL_TEXTURE_RECTANGLE_ARB = 0x84F5;
    constexpr uint32_t GL_TEXTURE_BINDING_RECTANGLE_ARB = 0x84F6;
    constexpr uint32_t GL_DRAW_FRAMEBUFFER_VAL = 0x8CA9;
    constexpr uint32_t GL_DRAW_FRAMEBUFFER_BINDING_VAL = 0x8CA6;
    constexpr uint32_t GL_COLOR_ATTACHMENT0_VAL = 0x8CE0;
    constexpr uint32_t GL_RGBA_VAL = 0x1908;
    constexpr uint32_t GL_BGRA_VAL = 0x80E1;
    constexpr uint32_t GL_UNSIGNED_INT_8_8_8_8_REV_VAL = 0x8367;

    int32_t prevTex = 0, prevDrawFbo = 0;
    gl->getIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &prevTex);
    gl->getIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_VAL, &prevDrawFbo);

    uint32_t tex = 0, fbo = 0;
    gl->genTextures(1, &tex);
    gl->bindTexture(GL_TEXTURE_RECTANGLE_ARB, tex);
    CGLError cerr = CGLTexImageIOSurface2D(cgl, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA_VAL,
                                           (GLsizei)w, (GLsizei)h, GL_BGRA_VAL,
                                           GL_UNSIGNED_INT_8_8_8_8_REV_VAL, surf, 0);
    if (cerr != kCGLNoError) {
        gl->bindTexture(GL_TEXTURE_RECTANGLE_ARB, (uint32_t)prevTex);
        gl->deleteTextures(1, &tex);
        CFRelease(surf);
        return;
    }
    gl->genFramebuffers(1, &fbo);
    gl->bindFramebuffer(GL_DRAW_FRAMEBUFFER_VAL, fbo);
    gl->framebufferTexture2D(GL_DRAW_FRAMEBUFFER_VAL, GL_COLOR_ATTACHMENT0_VAL, GL_TEXTURE_RECTANGLE_ARB, tex, 0);

    gl->bindFramebuffer(GL_DRAW_FRAMEBUFFER_VAL, (uint32_t)prevDrawFbo);
    gl->bindTexture(GL_TEXTURE_RECTANGLE_ARB, (uint32_t)prevTex);
    if (gl->getError) { while (gl->getError() != 0) {} }

    b.ioSurf = surf;
    b.srcTex = mtlTex;
    b.glTex = tex;
    b.glFbo = fbo;
    b.texW = w;
    b.texH = h;
}

static void AttachMetalOverlayOnMain(TrueHDRGLBridge *b, NSView *view) {
    NSWindow *parentWin = view ? view.window : nil;
    if (!view || !parentWin) return;

    NSRect inWin = [view convertRect:view.bounds toView:nil];
    NSRect scrRect = [parentWin convertRectToScreen:inWin];
    if (scrRect.size.width < 16.0 || scrRect.size.height < 16.0) return;

    NSScreen *scr = parentWin.screen ?: [NSScreen mainScreen];
    if (scr) {
        atomic_store(&gCachedHeadroom, (float)fmax(1.0, scr.maximumExtendedDynamicRangeColorComponentValue));
    }
    CGFloat scale = fmax(1.0, parentWin.backingScaleFactor);

    os_unfair_lock_lock(&b->_lock);
    NSWindow *ovWin = b.overlayWindow;
    CAMetalLayer *ml = b.metalLayer;
    if (!ovWin || !ml) {
        ovWin = [[NSWindow alloc] initWithContentRect:scrRect
                                            styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
        ovWin.opaque = NO;
        ovWin.backgroundColor = [NSColor clearColor];
        ovWin.ignoresMouseEvents = YES;
        ovWin.hasShadow = NO;
        ovWin.releasedWhenClosed = NO;
        ovWin.colorSpace = [NSColorSpace extendedSRGBColorSpace];
        ovWin.collectionBehavior = NSWindowCollectionBehaviorTransient
                                 | NSWindowCollectionBehaviorFullScreenAuxiliary
                                 | NSWindowCollectionBehaviorIgnoresCycle;

        TrueHDRMetalView *ovView = [[TrueHDRMetalView alloc] initWithFrame:NSMakeRect(0, 0, scrRect.size.width, scrRect.size.height)];
        ovView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        ovView.wantsLayer = YES;
        ml = (CAMetalLayer *)ovView.layer;
        ml.contentsGravity = kCAGravityResize;
        ml.contentsScale = scale;
        ml.opaque = YES;

        id<MTLDevice> dev = b.device ?: MTLCreateSystemDefaultDevice();
        b.device = dev;
        if (orig_setDevice) orig_setDevice(ml, @selector(setDevice:), dev);
        else ml.device = dev;
        EnforceEDROnLayer(ml);

        TrueHDRLayerContext *ctx = objc_getAssociatedObject(ml, kLayerCtxKey);
        if (!ctx) {
            ctx = [[TrueHDRLayerContext alloc] initWithDevice:dev];
            ctx.desiredPixelFormat = MTLPixelFormatBGRA8Unorm;
            objc_setAssociatedObject(ml, kLayerCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RegisterLayer(ml);
        }
        [ovWin setContentView:ovView];
        b.overlayWindow = ovWin;
        b.ctx = ctx;
        b.metalLayer = ml;
    }
    b.attachedView = view;
    b.viewPts = scrRect.size;
    b.viewScale = scale;
    b.wantsBestRes = [view wantsBestResolutionOpenGLSurface];
    b.setupQueued = NO;
    os_unfair_lock_unlock(&b->_lock);

    if (!parentWin.visible) {
        if (ovWin.parentWindow) [ovWin.parentWindow removeChildWindow:ovWin];
        [ovWin orderOut:nil];
    } else if (ovWin.parentWindow != parentWin) {
        if (ovWin.parentWindow) [ovWin.parentWindow removeChildWindow:ovWin];
        [ovWin setFrame:scrRect display:NO];
        [parentWin addChildWindow:ovWin ordered:NSWindowAbove];
    } else if (!NSEqualRects(ovWin.frame, scrRect)) {
        [ovWin setFrame:scrRect display:NO];
    }
    if (ml && fabs(ml.contentsScale - scale) > 0.01) {
        ml.contentsScale = scale;
    }
    if (ml) EnforceEDROnLayer(ml);

    static uint32_t gAttachDbg = 0;
    static double gLastDbgEdr = -1.0;
    double curEdr = scr ? scr.maximumExtendedDynamicRangeColorComponentValue : -1.0;
    if (gDebug && (gAttachDbg < 6 || fabs(curEdr - gLastDbgEdr) > 0.25)) {
        gAttachDbg++;
        gLastDbgEdr = curEdr;
        CGColorSpaceRef cs = ml.colorspace;
        CFStringRef csName = cs ? CGColorSpaceCopyName(cs) : NULL;
        THLog(@"GL ChildWin attach#%u rect=%.0fx%.0f ovWin(vis=%d space=%d cs=%@) parent=%@(vis=%d) scrMaxEDR=%.2f ml(fmt=%lu edr=%d scale=%.1f cs=%@)",
              gAttachDbg, scrRect.size.width, scrRect.size.height,
              (int)ovWin.visible, (int)ovWin.isOnActiveSpace, ovWin.colorSpace,
              NSStringFromClass([parentWin class]), (int)parentWin.visible,
              curEdr,
              (unsigned long)(orig_pixelFormat ? orig_pixelFormat(ml, @selector(pixelFormat)) : ml.pixelFormat),
              (int)ml.wantsExtendedDynamicRangeContent, (double)ml.contentsScale,
              (__bridge NSString *)csName);
        if (csName) CFRelease(csName);
    }
}

static void HandleGLFlush(id self, SEL _cmd, void (*origFn)(id, SEL)) {
    if (tInGLFlush || ![self isKindOfClass:[NSOpenGLContext class]]) {
        if (origFn) origFn(self, _cmd);
        return;
    }
    NSOpenGLContext *glCtx = (NSOpenGLContext *)self;
    CGLContextObj cgl = (CGLContextObj)[glCtx CGLContextObj];
    const GLFns *gl = GetGLFns();
    if (!cgl || !gl) {
        if (origFn) origFn(self, _cmd);
        return;
    }

    NSView *view = nil;
    CGSize cachedPts = CGSizeZero;
    CGFloat cachedScale = 1.0;
    BOOL cachedBestRes = NO;
    BOOL onMain = [NSThread isMainThread];
    if (onMain) {
        view = [glCtx view];
        if (view && !view.window) view = nil;
    }
    TrueHDRGLBridge *b = GetOrCreateGLBridge(glCtx);
    if (!onMain) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_lock(&b->_lock);
        view = b.attachedView;
        cachedPts = b.viewPts;
        cachedScale = b.viewScale;
        cachedBestRes = b.wantsBestRes;
        BOOL needSync = (!view || (now - b.lastSyncTime >= 0.5)) && !b.setupQueued;
        if (needSync) {
            b.setupQueued = YES;
            b.lastSyncTime = now;
        }
        os_unfair_lock_unlock(&b->_lock);
        if (needSync) {
            __weak NSOpenGLContext *weakGl = glCtx;
            dispatch_async(dispatch_get_main_queue(), ^{
                HookWineApplicationIfNeeded();
                NSOpenGLContext *sg = weakGl;
                if (!sg) return;
                NSView *v = [sg view];
                if (v && v.window) {
                    AttachMetalOverlayOnMain(b, v);
                } else {
                    os_unfair_lock_lock(&b->_lock);
                    b.setupQueued = NO;
                    os_unfair_lock_unlock(&b->_lock);
                }
            });
        }
    }

    if (!view && !onMain) {
        if (origFn) origFn(self, _cmd);
        return;
    }

    uint32_t srcW = 0, srcH = 0;
    GLint hasBS = 0;
    if (CGLIsEnabled(cgl, kCGLCESurfaceBackingSize, &hasBS) == kCGLNoError && hasBS) {
        GLint bsz[2] = {0, 0};
        if (CGLGetParameter(cgl, kCGLCPSurfaceBackingSize, bsz) == kCGLNoError && bsz[0] > 0 && bsz[1] > 0) {
            srcW = (uint32_t)bsz[0];
            srcH = (uint32_t)bsz[1];
        }
    }
    if (srcW == 0 || srcH == 0) {
        if (onMain && view) {
            CGSize pts = view.bounds.size;
            CGSize px = [view wantsBestResolutionOpenGLSurface] ? [view convertSizeToBacking:pts] : pts;
            srcW = (uint32_t)llround(px.width);
            srcH = (uint32_t)llround(px.height);
            cachedPts = pts;
        } else if (cachedPts.width >= 32.0 && cachedPts.height >= 32.0) {
            CGFloat sc = cachedBestRes ? cachedScale : 1.0;
            srcW = (uint32_t)llround(cachedPts.width * sc);
            srcH = (uint32_t)llround(cachedPts.height * sc);
        }
    }
    if (srcW < 64u || srcH < 64u) {
        int32_t vp[4] = {0, 0, 0, 0};
        gl->getIntegerv(0x0BA2 /* GL_VIEWPORT */, vp);
        if (vp[2] >= 64 && vp[3] >= 64) {
            srcW = (uint32_t)vp[2];
            srcH = (uint32_t)vp[3];
        }
    }
    if (srcW < 64u || srcH < 64u) {
        if (origFn) origFn(self, _cmd);
        return;
    }

    if (onMain && view) {
        HookWineApplicationIfNeeded();
        AttachMetalOverlayOnMain(b, view);
    }

    os_unfair_lock_lock(&b->_lock);
    CAMetalLayer *ml = b.metalLayer;
    TrueHDRLayerContext *ctx = b.ctx;
    if (ml && ctx) {
        EnsureGLSurfaceLocked(b, cgl, srcW, srcH, gl);
    }
    IOSurfaceRef surf = b.ioSurf;
    id<MTLTexture> srcMtlTex = b.srcTex;
    uint32_t glFbo = b.glFbo;
    CGSize viewPts = b.viewPts;
    os_unfair_lock_unlock(&b->_lock);

    BOOL captured = NO;
    if (ml && ctx && surf && srcMtlTex && glFbo != 0) {
        constexpr uint32_t GL_READ_FRAMEBUFFER_VAL = 0x8CA8;
        constexpr uint32_t GL_DRAW_FRAMEBUFFER_VAL = 0x8CA9;
        constexpr uint32_t GL_READ_FRAMEBUFFER_BINDING_VAL = 0x8CAA;
        constexpr uint32_t GL_DRAW_FRAMEBUFFER_BINDING_VAL = 0x8CA6;
        constexpr uint32_t GL_READ_BUFFER_VAL = 0x0C02;
        constexpr uint32_t GL_BACK_VAL = 0x0405;
        constexpr uint32_t GL_FRONT_VAL = 0x0404;
        constexpr uint32_t GL_SCISSOR_TEST_VAL = 0x0C11;
        constexpr uint32_t GL_FRAMEBUFFER_SRGB_VAL = 0x8DB9;
        constexpr uint32_t GL_COLOR_BUFFER_BIT_VAL = 0x00004000;
        constexpr uint32_t GL_NEAREST_VAL = 0x2600;

        int32_t prevReadFbo = 0, prevDrawFbo = 0, prevReadBuf = GL_BACK_VAL;
        gl->getIntegerv(GL_READ_FRAMEBUFFER_BINDING_VAL, &prevReadFbo);
        gl->getIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_VAL, &prevDrawFbo);
        gl->getIntegerv(GL_READ_BUFFER_VAL, &prevReadBuf);
        uint8_t scissorOn = gl->isEnabled ? gl->isEnabled(GL_SCISSOR_TEST_VAL) : 0;
        uint8_t srgbOn = gl->isEnabled ? gl->isEnabled(GL_FRAMEBUFFER_SRGB_VAL) : 0;

        if (scissorOn && gl->disable) gl->disable(GL_SCISSOR_TEST_VAL);
        if (srgbOn && gl->disable) gl->disable(GL_FRAMEBUFFER_SRGB_VAL);

        GLint dbl = 1;
        CGLPixelFormatObj pf = CGLGetPixelFormat(cgl);
        if (pf) CGLDescribePixelFormat(pf, 0, kCGLPFADoubleBuffer, &dbl);

        gl->bindFramebuffer(GL_READ_FRAMEBUFFER_VAL, 0);
        if (gl->readBuffer) gl->readBuffer(dbl ? GL_BACK_VAL : GL_FRONT_VAL);
        gl->bindFramebuffer(GL_DRAW_FRAMEBUFFER_VAL, glFbo);
        gl->blitFramebuffer(0, 0, (int)srcW, (int)srcH,
                            0, (int)srcH, (int)srcW, 0,
                            GL_COLOR_BUFFER_BIT_VAL, GL_NEAREST_VAL);
        gl->flush();

        if (srgbOn && gl->enable) gl->enable(GL_FRAMEBUFFER_SRGB_VAL);
        if (scissorOn && gl->enable) gl->enable(GL_SCISSOR_TEST_VAL);
        gl->bindFramebuffer(GL_READ_FRAMEBUFFER_VAL, (uint32_t)prevReadFbo);
        gl->bindFramebuffer(GL_DRAW_FRAMEBUFFER_VAL, (uint32_t)prevDrawFbo);
        if (gl->readBuffer) gl->readBuffer((uint32_t)prevReadBuf);
        if (gl->getError) { while (gl->getError() != 0) {} }
        captured = YES;
    }

    tInGLFlush = YES;
    if (origFn) origFn(self, _cmd);
    tInGLFlush = NO;

    if (!captured) return;

    TrueHDRSettings s = SnapshotSettings();
    CGSize gameSz = CGSizeMake(srcW, srcH);
    CGSize targetSz = ComputeUpscaledDrawableSize(gameSz, s);
    if (orig_setDrawableSize && orig_drawableSize) {
        CGSize curSz = orig_drawableSize(ml, @selector(drawableSize));
        if (fabs(curSz.width - targetSz.width) > 0.5 || fabs(curSz.height - targetSz.height) > 0.5) {
            tInLayerConfig = YES;
            orig_setDrawableSize(ml, @selector(setDrawableSize:), targetSz);
            tInLayerConfig = NO;
        }
    }

    id<CAMetalDrawable> real = orig_nextDrawable ? orig_nextDrawable(ml, @selector(nextDrawable)) : nil;
    id<MTLCommandQueue> q = real ? GetQueueForDevice(ctx.device ?: b.device) : nil;
    if (!real || !q) return;

    ctx.viewSize = (viewPts.width > 1.0 && viewPts.height > 1.0) ? viewPts : CGSizeMake(srcW, srcH);
    ctx.iniPath = TrueHDRResolveIniPath();
    ctx.edrHeadroom = atomic_load(&gCachedHeadroom);

    id<MTLCommandBuffer> cb = [q commandBuffer];
    cb.label = @"TrueHDR-GLPresent";
    [ctx encodeTrueHDR:cb
             sourceTex:srcMtlTex
               destTex:real.texture
              settings:s
         isLinearInput:NO];
    [cb presentDrawable:real];
    [cb commit];

    MaybeWriteStatus(srcW, srcH, (uint32_t)real.texture.width, (uint32_t)real.texture.height,
                     MTLPixelFormatBGRA8Unorm, ctx.lastUpscaleActive, ctx.lastUpscaleMode, ctx.lastGpuMs, s);
}

static void th_glFlushBuffer(id self, SEL _cmd) {
    @autoreleasepool { HandleGLFlush(self, _cmd, orig_glFlushBuffer); }
}

static void th_wineGlFlushBuffer(id self, SEL _cmd) {
    @autoreleasepool { HandleGLFlush(self, _cmd, orig_wineGlFlushBuffer); }
}

static void HookWineOpenGLContextIfNeeded(void) {
    static BOOL gWineGlHooked = NO;
    os_unfair_lock_lock(&gHookLock);
    if (gWineGlHooked) {
        os_unfair_lock_unlock(&gHookLock);
        return;
    }
    Class wineGl = NSClassFromString(@"WineOpenGLContext");
    Class nsGl = NSClassFromString(@"NSOpenGLContext");
    if (wineGl && nsGl) {
        Method mWine = class_getInstanceMethod(wineGl, @selector(flushBuffer));
        Method mNS = class_getInstanceMethod(nsGl, @selector(flushBuffer));
        if (mWine && mWine != mNS) {
            IMP cur = method_getImplementation(mWine);
            if (cur != (IMP)th_wineGlFlushBuffer && cur != (IMP)th_glFlushBuffer) {
                orig_wineGlFlushBuffer = (decltype(orig_wineGlFlushBuffer))method_setImplementation(mWine, (IMP)th_wineGlFlushBuffer);
                THLog(@"Hooked WineOpenGLContext flushBuffer");
            }
        }
        gWineGlHooked = YES;
    }
    os_unfair_lock_unlock(&gHookLock);
}

static void OnDyldImageAdded(const struct mach_header *, intptr_t) {
    HookWineOpenGLContextIfNeeded();
}

// ---------------------------------------------------------------------------
// NSApplication sendEvent: hook for hotkeys + Option+Drag split wipe
// ---------------------------------------------------------------------------

static void (*orig_sendEvent)(id, SEL, NSEvent *) = nullptr;
static void (*orig_wineSendEvent)(id, SEL, NSEvent *) = nullptr;
static BOOL gWineAppHooked = NO;
static BOOL gDraggingSplit = NO;

static void HandleSplitDragEvent(NSEvent *event) {
    NSWindow *win = event.window ?: [NSApp keyWindow] ?: [NSApp mainWindow];
    if (!win || !win.contentView) return;
    CGFloat w = win.contentView.bounds.size.width;
    if (w <= 0) return;
    float pos = fminf(0.95f, fmaxf(0.05f, (float)(event.locationInWindow.x / w)));
    os_unfair_lock_lock(&gCfgLock);
    gSettings.splitPos = pos;
    TrueHDRSettings s = gSettings;
    os_unfair_lock_unlock(&gCfgLock);
    SaveConfigFromSettings(s);
}

static TrueHDRLayerContext *ActiveHUDContext(void) {
    os_unfair_lock_lock(&gHookLock);
    NSArray<CAMetalLayer *> *layers = gActiveLayers ? [gActiveLayers allObjects] : @[];
    os_unfair_lock_unlock(&gHookLock);
    TrueHDRLayerContext *best = nil;
    for (CAMetalLayer *layer in layers) {
        TrueHDRLayerContext *ctx = objc_getAssociatedObject(layer, kLayerCtxKey);
        if (!ctx || !ctx.hud) continue;
        if (ctx.hud.overlayOpen) return ctx;
        if (!best || layer.bounds.size.width > 100) best = ctx;
    }
    return best;
}

static BOOL DispatchTrueHDREvent(NSEvent *event) {
    NSScreen *scr = (event.window ?: [NSApp mainWindow]).screen ?: [NSScreen mainScreen];
    if (scr) {
        atomic_store(&gCachedHeadroom, (float)fmax(1.0, scr.maximumExtendedDynamicRangeColorComponentValue));
    }

    TrueHDRLayerContext *hudCtx = ActiveHUDContext();
    if (hudCtx && hudCtx.hud) {
        TrueHDRSettings s = SnapshotSettings();
        BOOL changed = NO, doSave = NO, doReload = NO, doReset = NO;
        NSWindow *win = event.window ?: [NSApp keyWindow] ?: [NSApp mainWindow];
        if ([hudCtx.hud handleEvent:event window:win settings:s outChanged:&changed outSave:&doSave outReload:&doReload outReset:&doReset]) {
            if (doReload) {
                uint64_t mtime = 0;
                TrueHDRLoadIni(&s, &mtime, NO);
                os_unfair_lock_lock(&gCfgLock);
                gSettings = s;
                gIniMtimeNs = mtime;
                os_unfair_lock_unlock(&gCfgLock);
                [hudCtx.hud showBannerText:@"TrueHDR: INI Reloaded" duration:1.8];
            } else if (doReset) {
                s = TrueHDRDefaultSettings();
                os_unfair_lock_lock(&gCfgLock);
                gSettings = s;
                os_unfair_lock_unlock(&gCfgLock);
                SaveConfigFromSettings(s);
                [hudCtx.hud showBannerText:@"TrueHDR: Reset to Defaults" duration:1.8];
            } else {
                if (changed) {
                    os_unfair_lock_lock(&gCfgLock);
                    gSettings = s;
                    os_unfair_lock_unlock(&gCfgLock);
                }
                if (doSave) {
                    SaveConfigFromSettings(s);
                }
            }
            return YES;
        }
    }

    if (event.type == NSEventTypeKeyDown) {
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSEventModifierFlags pureOpt = mods & (NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagShift);
        if (pureOpt == NSEventModifierFlagOption && !event.isARepeat) {
            unsigned short kc = event.keyCode;
            BOOL handled = YES;
            NSString *toast = nil;

            os_unfair_lock_lock(&gCfgLock);
            if (kc == kVK_ANSI_M) {
                gSettings.enabled = !gSettings.enabled;
                toast = gSettings.enabled ? @"TrueHDR: ON" : @"TrueHDR: OFF";
            } else if (kc == kVK_ANSI_H) {
                gSettings.hdrEnabled = !gSettings.hdrEnabled;
                toast = gSettings.hdrEnabled
                    ? [NSString stringWithFormat:@"HDR: ON (%.1fx EDR)", gSettings.peakBoost]
                    : @"HDR: OFF";
            } else if (kc == kVK_ANSI_U) {
                gSettings.upscaleEnabled = !gSettings.upscaleEnabled;
                toast = gSettings.upscaleEnabled
                    ? [NSString stringWithFormat:@"4K Upscale: ON (%s)", TrueHDRUpscaleModeTitle(gSettings.upscaleMode)]
                    : @"4K Upscale: OFF";
            } else if (kc == kVK_ANSI_S) {
                gSettings.splitEnabled = !gSettings.splitEnabled;
                toast = gSettings.splitEnabled ? @"Split View: SDR | EDR" : @"Split View: OFF";
            } else if (kc == kVK_ANSI_P) {
                const char *order[] = {"vivid", "natural", "cinema", "comfort"};
                int idx = 0;
                for (int i = 0; i < 4; i++) {
                    if (strcmp(gSettings.preset, order[i]) == 0) { idx = (i + 1) % 4; break; }
                }
                TrueHDRApplyPreset(&gSettings, order[idx]);
                toast = [NSString stringWithFormat:@"Preset: %s (%.1fx)", gSettings.preset, gSettings.peakBoost];
            } else if (kc == kVK_LeftArrow && gSettings.splitEnabled) {
                gSettings.splitPos = fmaxf(0.05f, gSettings.splitPos - 0.05f);
                toast = [NSString stringWithFormat:@"Split: %d%%", (int)roundf(gSettings.splitPos * 100.0f)];
            } else if (kc == kVK_RightArrow && gSettings.splitEnabled) {
                gSettings.splitPos = fminf(0.95f, gSettings.splitPos + 0.05f);
                toast = [NSString stringWithFormat:@"Split: %d%%", (int)roundf(gSettings.splitPos * 100.0f)];
            } else if (kc == kVK_UpArrow) {
                gSettings.peakBoost = fminf(12.0f, gSettings.peakBoost + 0.5f);
                strlcpy(gSettings.preset, "custom", sizeof(gSettings.preset));
                toast = [NSString stringWithFormat:@"Peak Boost: %.1fx", gSettings.peakBoost];
            } else if (kc == kVK_DownArrow) {
                gSettings.peakBoost = fmaxf(1.0f, gSettings.peakBoost - 0.5f);
                strlcpy(gSettings.preset, "custom", sizeof(gSettings.preset));
                toast = [NSString stringWithFormat:@"Peak Boost: %.1fx", gSettings.peakBoost];
            } else {
                handled = NO;
            }
            TrueHDRSettings snap = gSettings;
            os_unfair_lock_unlock(&gCfgLock);

            if (handled) {
                SaveConfigFromSettings(snap);
                if (toast) ShowToastOnAllLayers(toast);
                return YES;
            }
        }
    } else if (event.type == NSEventTypeLeftMouseDown) {
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if ((mods & NSEventModifierFlagOption) && SnapshotSettings().splitEnabled) {
            gDraggingSplit = YES;
            HandleSplitDragEvent(event);
            return YES;
        }
    } else if (event.type == NSEventTypeLeftMouseDragged && gDraggingSplit) {
        HandleSplitDragEvent(event);
        return YES;
    } else if (event.type == NSEventTypeLeftMouseUp && gDraggingSplit) {
        gDraggingSplit = NO;
        HandleSplitDragEvent(event);
        return YES;
    }
    return NO;
}

static __thread BOOL tInTrueHDREvent = NO;

static void th_sendEvent(id self, SEL _cmd, NSEvent *event) {
    if (!tInTrueHDREvent) {
        tInTrueHDREvent = YES;
        BOOL consumed = DispatchTrueHDREvent(event);
        tInTrueHDREvent = NO;
        if (consumed) return;
    }
    orig_sendEvent(self, _cmd, event);
}

static void th_wineSendEvent(id self, SEL _cmd, NSEvent *event) {
    if (!tInTrueHDREvent) {
        tInTrueHDREvent = YES;
        BOOL consumed = DispatchTrueHDREvent(event);
        tInTrueHDREvent = NO;
        if (consumed) return;
    }
    orig_wineSendEvent(self, _cmd, event);
}

static void HookWineApplicationIfNeeded(void) {
    os_unfair_lock_lock(&gHookLock);
    if (gWineAppHooked) {
        os_unfair_lock_unlock(&gHookLock);
        return;
    }
    Class wineCls = NSClassFromString(@"WineApplication");
    Class appCls = NSClassFromString(@"NSApplication");
    if (wineCls && appCls) {
        Method appM = class_getInstanceMethod(appCls, @selector(sendEvent:));
        Method wineM = class_getInstanceMethod(wineCls, @selector(sendEvent:));
        if (wineM && wineM != appM && method_getImplementation(wineM) != (IMP)th_wineSendEvent) {
            orig_wineSendEvent = (decltype(orig_wineSendEvent))method_setImplementation(wineM, (IMP)th_wineSendEvent);
            THLog(@"Hooked WineApplication sendEvent:");
        }
        gWineAppHooked = YES;
    }
    os_unfair_lock_unlock(&gHookLock);
}

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

static void Swizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        *outOrig = method_setImplementation(m, newImp);
    }
}

static bool ShouldSkipProcess(void) {
    const char *prog = getprogname();
    if (!prog) return false;
    static const char *const kSkipNames[] = {
        "sh", "bash", "zsh", "dash", "env", "python", "python3", "perl", "route",
        "wineserver", "wineserver-x86", "wineserver-arm64", "wineboot", "wineboot.exe",
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "explorer.exe", "conhost.exe", "start.exe", "winlogon.exe", "lsass.exe",
        "tabtip.exe", "crashpad_handler.exe", "CrashReportClient.exe", "UnrealCEFSubProcess.exe"
    };
    for (size_t i = 0; i < sizeof(kSkipNames) / sizeof(kSkipNames[0]); i++) {
        if (strcasecmp(prog, kSkipNames[i]) == 0) return true;
    }
    return false;
}

__attribute__((constructor))
static void TrueHDRInit(void) {
    if (getenv("TRUEHDR_DISABLE") && atoi(getenv("TRUEHDR_DISABLE")) != 0) return;
    if (ShouldSkipProcess()) return;
    gDebug = (getenv("TRUEHDR_DEBUG") && atoi(getenv("TRUEHDR_DEBUG")) != 0);

    LoadConfig(YES);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    ConfigNotificationCallback,
                                    (__bridge CFStringRef)TRUEHDR_NOTIFY_CFG,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class layerCls = [CAMetalLayer class];
    if (layerCls) {
        Swizzle(layerCls, @selector(setDevice:), (IMP)th_setDevice, (IMP *)&orig_setDevice);
        Swizzle(layerCls, @selector(setPixelFormat:), (IMP)th_setPixelFormat, (IMP *)&orig_setPixelFormat);
        Swizzle(layerCls, @selector(pixelFormat), (IMP)th_pixelFormat, (IMP *)&orig_pixelFormat);
        Swizzle(layerCls, @selector(setFramebufferOnly:), (IMP)th_setFramebufferOnly, (IMP *)&orig_setFramebufferOnly);
        Swizzle(layerCls, @selector(framebufferOnly), (IMP)th_framebufferOnly, (IMP *)&orig_framebufferOnly);
        Swizzle(layerCls, @selector(setColorspace:), (IMP)th_setColorspace, (IMP *)&orig_setColorspace);
        Swizzle(layerCls, @selector(setWantsExtendedDynamicRangeContent:), (IMP)th_setWantsEDR, (IMP *)&orig_setWantsEDR);
        Swizzle(layerCls, @selector(setEDRMetadata:), (IMP)th_setEDRMetadata, (IMP *)&orig_setEDRMetadata);
        Swizzle(layerCls, @selector(setDrawableSize:), (IMP)th_setDrawableSize, (IMP *)&orig_setDrawableSize);
        Swizzle(layerCls, @selector(drawableSize), (IMP)th_drawableSize, (IMP *)&orig_drawableSize);
        Swizzle(layerCls, @selector(nextDrawable), (IMP)th_nextDrawable, (IMP *)&orig_nextDrawable);
    }

    Class appCls = NSClassFromString(@"NSApplication");
    if (appCls) {
        Swizzle(appCls, @selector(sendEvent:), (IMP)th_sendEvent, (IMP *)&orig_sendEvent);
    }

    Class glCls = NSClassFromString(@"NSOpenGLContext");
    if (glCls) {
        Swizzle(glCls, @selector(flushBuffer), (IMP)th_glFlushBuffer, (IMP *)&orig_glFlushBuffer);
    }
    HookWineOpenGLContextIfNeeded();
    _dyld_register_func_for_add_image(OnDyldImageAdded);

    NSLog(@"[TrueHDR-Game] Metal HDR hook loaded (pid=%d, proc=%s, ini=%s)",
          getpid(), getprogname(), TrueHDRResolveIniPath().UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{
        HookWineApplicationIfNeeded();
        NSScreen *scr = [NSScreen mainScreen];
        if (scr) {
            atomic_store(&gCachedHeadroom, (float)fmax(1.0, scr.maximumExtendedDynamicRangeColorComponentValue));
        }
        [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                              handler:^NSEvent * _Nullable(NSEvent *ev) {
            TrueHDRLayerContext *ctx = ActiveHUDContext();
            if (ctx && ctx.hud && ctx.hud.overlayOpen && DispatchTrueHDREvent(ev)) {
                return nil;
            }
            return ev;
        }];
    });
}
