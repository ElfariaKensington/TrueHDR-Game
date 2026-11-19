#import "TrueHDRRenderer.h"
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#include <os/lock.h>
#include <math.h>
#include <algorithm>
#include "TrueHDRMetallib.h"
#include "TrueHDRSRWeights.h"

static constexpr uint32_t kCellSize = 8;
static constexpr size_t kStateBytes = 176;
static constexpr size_t kPartialBytes = 144;

struct FrameU {
    float tone[4];
    float extra[4];
    float info[4];
    float outp[4];
    float stat[4];
    float upsc[4];
};

struct SRLayerU {
    int32_t srcW;
    int32_t srcH;
    int32_t k;
    int32_t cin;
    int32_t cout;
    int32_t hasPrelu;
    int32_t skipFrom;
    uint32_t wVec4Off;
    uint32_t bVec4Off;
    uint32_t aVec4Off;
    uint32_t flags;
};

struct HUDUniforms {
    float rect[4];
    float gain[4];
};

BOOL TrueHDRPixelFormatIsLinear(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatRGBA16Float:
            return YES;
        default:
            return NO;
    }
}

BOOL TrueHDRPixelFormatIsSupportedSwapchain(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm:
        case MTLPixelFormatBGR10A2Unorm:
        case MTLPixelFormatRGBA16Float:
            return YES;
        default:
            return NO;
    }
}

@interface TrueHDRDevicePipelines : NSObject
@property (nonatomic, strong) id<MTLComputePipelineState> analyzePipe;
@property (nonatomic, strong) id<MTLComputePipelineState> statsPipe;
@property (nonatomic, strong) id<MTLComputePipelineState> mapPipe;
@property (nonatomic, strong) id<MTLComputePipelineState> srInPipe;
@property (nonatomic, strong) id<MTLComputePipelineState> srMidPipe;
@property (nonatomic, strong) id<MTLComputePipelineState> srOutPipe;
@property (nonatomic, strong) id<MTLRenderPipelineState> finalPipe;
@property (nonatomic, strong) id<MTLRenderPipelineState> hudPipe;
@property (nonatomic, strong) id<MTLBuffer> srFastWeights;
@property (nonatomic, strong) id<MTLBuffer> srQualWeights;
@end

@implementation TrueHDRDevicePipelines
@end

static os_unfair_lock gPipeLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<id<MTLDevice>, TrueHDRDevicePipelines *> *gPipelinesByDevice = nil;

static TrueHDRDevicePipelines *GetPipelinesForDevice(id<MTLDevice> device) {
    if (!device) return nil;
    os_unfair_lock_lock(&gPipeLock);
    if (!gPipelinesByDevice) {
        gPipelinesByDevice = [NSMapTable strongToStrongObjectsMapTable];
    }
    TrueHDRDevicePipelines *p = [gPipelinesByDevice objectForKey:device];
    os_unfair_lock_unlock(&gPipeLock);
    if (p) return p;

    NSError *err = nil;
    dispatch_data_t data = dispatch_data_create(kTrueHDRMetallibBytes, kTrueHDRMetallibLength,
                                                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> lib = [device newLibraryWithData:data error:&err];
    if (!lib) {
        NSLog(@"[TrueHDR-Game] Failed to load metallib: %@", err);
        return nil;
    }

    id<MTLFunction> fnAna = [lib newFunctionWithName:@"csAnalyze"];
    id<MTLFunction> fnStats = [lib newFunctionWithName:@"csStats"];
    id<MTLFunction> fnMap = [lib newFunctionWithName:@"csMap"];
    id<MTLFunction> fnVS = [lib newFunctionWithName:@"vsMain"];
    id<MTLFunction> fnFS = [lib newFunctionWithName:@"fsTrueHDR"];
    if (!fnAna || !fnStats || !fnMap || !fnVS || !fnFS) {
        NSLog(@"[TrueHDR-Game] Missing shader function(s) in metallib");
        return nil;
    }

    TrueHDRDevicePipelines *created = [[TrueHDRDevicePipelines alloc] init];
    created.analyzePipe = [device newComputePipelineStateWithFunction:fnAna error:&err];
    if (!created.analyzePipe) { NSLog(@"[TrueHDR-Game] csAnalyze PSO error: %@", err); return nil; }
    created.statsPipe = [device newComputePipelineStateWithFunction:fnStats error:&err];
    if (!created.statsPipe) { NSLog(@"[TrueHDR-Game] csStats PSO error: %@", err); return nil; }
    created.mapPipe = [device newComputePipelineStateWithFunction:fnMap error:&err];
    if (!created.mapPipe) { NSLog(@"[TrueHDR-Game] csMap PSO error: %@", err); return nil; }

    id<MTLFunction> fnSRIn = [lib newFunctionWithName:@"csSRIn"];
    id<MTLFunction> fnSRMid = [lib newFunctionWithName:@"csSRMid"];
    id<MTLFunction> fnSROut = [lib newFunctionWithName:@"csSROut"];
    if (fnSRIn && fnSRMid && fnSROut) {
        created.srInPipe = [device newComputePipelineStateWithFunction:fnSRIn error:&err];
        created.srMidPipe = [device newComputePipelineStateWithFunction:fnSRMid error:&err];
        created.srOutPipe = [device newComputePipelineStateWithFunction:fnSROut error:&err];
        created.srFastWeights = [device newBufferWithBytes:kTrueHDRSRFastWeights
                                                    length:sizeof(kTrueHDRSRFastWeights)
                                                   options:MTLResourceStorageModeShared];
        created.srQualWeights = [device newBufferWithBytes:kTrueHDRSRQualityWeights
                                                    length:sizeof(kTrueHDRSRQualityWeights)
                                                   options:MTLResourceStorageModeShared];
    }

    MTLRenderPipelineDescriptor *rpd = [[MTLRenderPipelineDescriptor alloc] init];
    rpd.label = @"TrueHDR-Final";
    rpd.vertexFunction = fnVS;
    rpd.fragmentFunction = fnFS;
    rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    created.finalPipe = [device newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!created.finalPipe) { NSLog(@"[TrueHDR-Game] fsTrueHDR PSO error: %@", err); return nil; }

    id<MTLFunction> fnHudVS = [lib newFunctionWithName:@"vsHUD"];
    id<MTLFunction> fnHudFS = [lib newFunctionWithName:@"fsHUD"];
    if (fnHudVS && fnHudFS) {
        MTLRenderPipelineDescriptor *hrd = [[MTLRenderPipelineDescriptor alloc] init];
        hrd.label = @"TrueHDR-HUD";
        hrd.vertexFunction = fnHudVS;
        hrd.fragmentFunction = fnHudFS;
        hrd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        hrd.colorAttachments[0].blendingEnabled = YES;
        hrd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        hrd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        hrd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        hrd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        hrd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        hrd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        created.hudPipe = [device newRenderPipelineStateWithDescriptor:hrd error:&err];
    }

    os_unfair_lock_lock(&gPipeLock);
    TrueHDRDevicePipelines *existing = [gPipelinesByDevice objectForKey:device];
    if (!existing) {
        [gPipelinesByDevice setObject:created forKey:device];
        existing = created;
    }
    os_unfair_lock_unlock(&gPipeLock);
    return existing;
}

@implementation TrueHDRLayerContext {
    os_unfair_lock _lock;
    NSMutableArray<id<MTLTexture>> *_freeTexs;
    id<MTLBuffer> _stateBuf;
    id<MTLBuffer> _sceneBuf;
    id<MTLBuffer> _partialsBuf;
    id<MTLTexture> _lutTex;
    id<MTLTexture> _cellTex;
    id<MTLTexture> _mapTex[2];
    id<MTLTexture> _srFeatTex[5];
    id<MTLTexture> _srOutTex;
    uint32_t _srW, _srH;
    int32_t _srSlices;
    uint32_t _srcW, _srcH;
    uint32_t _cellsW, _cellsH;
    uint32_t _groupsW, _groupsH;
    int _mapIdx;
    BOOL _needReset;
    CFAbsoluteTime _lastFrameTime;
    uint32_t _frameSeed;
    float _fpsEma;
    float _gpuMsEma;
    float _lastApl;
    float _lastEffPeak;
    BOOL _bannerShown;
    id<MTLBuffer> _readbackBuf;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _device = device;
        _desiredPixelFormat = MTLPixelFormatBGRA8Unorm;
        _desiredFramebufferOnly = YES;
        _desiredEDR = NO;
        _edrHeadroom = 1.0f;
        _fpsEma = 60.0f;
        _freeTexs = [NSMutableArray array];
        _needReset = YES;
        _lastFrameTime = 0;
        _frameSeed = 0;
        if (device) _hud = [[TrueHDRHUD alloc] initWithDevice:device];
    }
    return self;
}

- (void)setDevice:(id<MTLDevice>)device {
    _device = device;
    if (device && !_hud) {
        _hud = [[TrueHDRHUD alloc] initWithDevice:device];
    }
}

- (void)dealloc {
    if (_desiredColorspace) {
        CGColorSpaceRelease(_desiredColorspace);
        _desiredColorspace = NULL;
    }
}

- (void)setDesiredColorspace:(CGColorSpaceRef)cs {
    if (_desiredColorspace == cs) return;
    if (_desiredColorspace) CGColorSpaceRelease(_desiredColorspace);
    _desiredColorspace = cs ? CGColorSpaceRetain(cs) : NULL;
}

- (void)ensureBaseResourcesLocked {
    if (!_device) return;
    if (!_stateBuf) {
        _stateBuf = [_device newBufferWithLength:kStateBytes options:MTLResourceStorageModeShared];
        _stateBuf.label = @"TrueHDR-State";
        memset(_stateBuf.contents, 0, kStateBytes);
    }
    if (!_sceneBuf) {
        _sceneBuf = [_device newBufferWithLength:16 options:MTLResourceStorageModePrivate];
        _sceneBuf.label = @"TrueHDR-SceneU";
    }
    if (!_readbackBuf) {
        _readbackBuf = [_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        _readbackBuf.label = @"TrueHDR-Readback";
    }
    if (!_lutTex) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                      width:256
                                                                                     height:1
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        _lutTex = [_device newTextureWithDescriptor:td];
        _lutTex.label = @"TrueHDR-LUT";
    }
}

- (void)ensureSizedLocked:(uint32_t)w height:(uint32_t)h {
    [self ensureBaseResourcesLocked];
    if (_cellTex && _srcW == w && _srcH == h) return;

    uint32_t cw = (w + kCellSize - 1) / kCellSize;
    uint32_t ch = (h + kCellSize - 1) / kCellSize;
    uint32_t gw = (cw + 7) / 8;
    uint32_t gh = (ch + 7) / 8;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:cw
                                                                                 height:ch
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;

    _cellTex = [_device newTextureWithDescriptor:td];
    _cellTex.label = @"TrueHDR-Cells";
    for (int i = 0; i < 2; i++) {
        _mapTex[i] = [_device newTextureWithDescriptor:td];
        _mapTex[i].label = i == 0 ? @"TrueHDR-Map0" : @"TrueHDR-Map1";
    }
    _partialsBuf = [_device newBufferWithLength:(size_t)gw * gh * kPartialBytes
                                        options:MTLResourceStorageModePrivate];
    _partialsBuf.label = @"TrueHDR-Partials";
    _srcW = w;
    _srcH = h;
    _cellsW = cw;
    _cellsH = ch;
    _groupsW = gw;
    _groupsH = gh;
    _needReset = YES;
}

- (void)ensureSrSizedLocked:(uint32_t)w height:(uint32_t)h slices:(int32_t)slices {
    if (_srOutTex && _srW == w && _srH == h && _srSlices == slices) return;
    MTLTextureDescriptor *fd = [[MTLTextureDescriptor alloc] init];
    fd.textureType = MTLTextureType2DArray;
    fd.pixelFormat = MTLPixelFormatRGBA16Float;
    fd.width = w;
    fd.height = h;
    fd.arrayLength = (NSUInteger)slices;
    fd.mipmapLevelCount = 1;
    fd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    fd.storageMode = MTLStorageModePrivate;
    for (int i = 0; i < 5; i++) {
        _srFeatTex[i] = [_device newTextureWithDescriptor:fd];
        _srFeatTex[i].label = [NSString stringWithFormat:@"TrueHDR-SRFeat%d", i];
    }
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:w * 2u
                                                                                 height:h * 2u
                                                                              mipmapped:NO];
    od.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    od.storageMode = MTLStorageModePrivate;
    _srOutTex = [_device newTextureWithDescriptor:od];
    _srOutTex.label = @"TrueHDR-SROut";
    _srW = w;
    _srH = h;
    _srSlices = slices;
}

- (void)releaseSrLocked {
    for (int i = 0; i < 5; i++) _srFeatTex[i] = nil;
    _srOutTex = nil;
    _srW = 0;
    _srH = 0;
    _srSlices = 0;
}

- (id<MTLTexture>)acquireGameTextureForDrawable:(id<CAMetalDrawable>)realDrawable
                                    pixelFormat:(MTLPixelFormat)fmt
                                       gameSize:(CGSize)gameSize {
    id<MTLTexture> realTex = realDrawable.texture;
    if (!realTex) return nil;
    id<MTLDevice> dev = _device ?: realTex.device;
    if (!dev) return nil;

    NSUInteger w = realTex.width;
    NSUInteger h = realTex.height;
    if (gameSize.width >= 64.0 && gameSize.height >= 64.0) {
        w = (NSUInteger)llround(gameSize.width);
        h = (NSUInteger)llround(gameSize.height);
    }

    os_unfair_lock_lock(&_lock);
    if (!_device) {
        _device = dev;
        if (!_hud) _hud = [[TrueHDRHUD alloc] initWithDevice:dev];
    }
    id<MTLTexture> reused = nil;
    for (NSInteger i = (NSInteger)_freeTexs.count - 1; i >= 0; i--) {
        id<MTLTexture> cand = _freeTexs[(NSUInteger)i];
        if (cand.width == w && cand.height == h && cand.pixelFormat == fmt) {
            reused = cand;
            [_freeTexs removeObjectAtIndex:(NSUInteger)i];
            break;
        } else {
            // Drop stale size/format textures immediately on resize
            [_freeTexs removeObjectAtIndex:(NSUInteger)i];
        }
    }
    os_unfair_lock_unlock(&_lock);
    if (reused) return reused;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    BOOL isSRGB = (fmt == MTLPixelFormatBGRA8Unorm_sRGB || fmt == MTLPixelFormatRGBA8Unorm_sRGB);
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead
             | (isSRGB ? 0 : MTLTextureUsageShaderWrite);
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    tex.label = @"TrueHDR-GameBackbuffer";
    return tex;
}

- (void)recycleGameTexture:(id<MTLTexture>)tex {
    if (!tex) return;
    os_unfair_lock_lock(&_lock);
    if (_freeTexs.count < 3 && ![_freeTexs containsObject:tex]) {
        [_freeTexs addObject:tex];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)encodeTrueHDR:(id<MTLCommandBuffer>)cmdBuf
            sourceTex:(id<MTLTexture>)srcTex
              destTex:(id<MTLTexture>)dstTex
             settings:(const TrueHDRSettings &)s
        isLinearInput:(BOOL)isLinearInput {
    if (!cmdBuf || !srcTex || !dstTex) return;
    id<MTLDevice> dev = cmdBuf.device;
    TrueHDRDevicePipelines *pipes = GetPipelinesForDevice(dev);
    if (!pipes) return;

    uint32_t w = (uint32_t)srcTex.width;
    uint32_t h = (uint32_t)srcTex.height;
    if (w == 0 || h == 0) return;

    os_unfair_lock_lock(&_lock);
    if (!_device) {
        _device = dev;
        if (!_hud) _hud = [[TrueHDRHUD alloc] initWithDevice:dev];
    }
    [self ensureSizedLocked:w height:h];

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    float dt = _lastFrameTime > 0 ? (float)(now - _lastFrameTime) : (1.0f / 60.0f);
    dt = std::min(std::max(dt, 1.0f / 240.0f), 0.25f);
    _lastFrameTime = now;
    float instFps = 1.0f / std::max(dt, 1e-4f);
    _fpsEma = _fpsEma * 0.90f + instFps * 0.10f;

    if (!_bannerShown && _hud && s.showBanner) {
        _bannerShown = YES;
        const char *fmtTag = _desiredPixelFormat == MTLPixelFormatBGR10A2Unorm ? "BGR10A2"
                           : _desiredPixelFormat == MTLPixelFormatRGBA16Float ? "RGBA16F" : "SDR8";
        [_hud showBannerText:[NSString stringWithFormat:@"TrueHDR 1.0.0 (%s → EDR)  |  Press Home, Shift+F2, or Opt+G to open HUD", fmtTag]
                    duration:4.5];
        if (getenv("TRUEHDR_HUD") && atoi(getenv("TRUEHDR_HUD")) != 0 && !_hud.overlayOpen) {
            [_hud toggleOverlay];
        }
    }
    if (_readbackBuf) {
        const float *rb = (const float *)_readbackBuf.contents;
        _lastApl = rb[0];
        _lastEffPeak = rb[2] > 0.1f ? rb[2] : s.peakBoost;
    } else {
        _lastEffPeak = s.peakBoost;
    }

    int cur = _mapIdx = 1 - _mapIdx;
    BOOL reset = _needReset;
    _needReset = NO;
    _frameSeed = (_frameSeed + 1) % 256;
    _lastWidth = w;
    _lastHeight = h;
    uint32_t outW = (uint32_t)dstTex.width;
    uint32_t outH = (uint32_t)dstTex.height;
    _lastOutWidth = outW;
    _lastOutHeight = outH;

    BOOL hdrActive = s.enabled && s.hdrEnabled;
    BOOL upEnabled = s.enabled && s.upscaleEnabled;
    BOOL canAISize = (w >= 64u && h >= 64u && w <= 2048u && h <= 1280u && (outW > w || outH > h));
    BOOL wantAI = upEnabled && canAISize
        && (s.upscaleMode == TRUEHDR_UPSCALE_AI_FAST || s.upscaleMode == TRUEHDR_UPSCALE_AI_QUAL)
        && pipes.srInPipe && pipes.srMidPipe && pipes.srOutPipe;
    int32_t activeMode = wantAI ? s.upscaleMode : TRUEHDR_UPSCALE_SPATIAL;
    BOOL useQual = (activeMode == TRUEHDR_UPSCALE_AI_QUAL);
    id<MTLBuffer> weightBuf = useQual ? pipes.srQualWeights : pipes.srFastWeights;
    if (!weightBuf) wantAI = NO;

    id<MTLTexture> srFeat[5] = {};
    id<MTLTexture> srOut = nil;
    if (wantAI) {
        [self ensureSrSizedLocked:w height:h slices:(useQual ? 4 : 3)];
        for (int i = 0; i < 5; i++) srFeat[i] = _srFeatTex[i];
        srOut = _srOutTex;
    } else if (_srOutTex) {
        [self releaseSrLocked];
    }

    _lastUpscaleActive = upEnabled;
    _lastUpscaleMode = activeMode;
    uint32_t flags = (hdrActive ? 1u : 0u)
                   | (s.bypassNativeHdr ? 2u : 0u)
                   | (isLinearInput ? 4u : 0u)
                   | (upEnabled ? 8u : 0u)
                   | (wantAI && srOut ? 16u : 0u);

    FrameU u = {};
    u.tone[0] = s.peakBoost;
    u.tone[1] = s.threshold;
    u.tone[2] = s.localPunch;
    u.tone[3] = s.gamutBoost;
    u.extra[0] = s.shadowDepth;
    u.extra[1] = s.aplGuard;
    u.extra[2] = s.splitEnabled ? s.splitPos : -1.0f;
    u.extra[3] = (float)flags;
    u.info[0] = (float)w;
    u.info[1] = (float)h;
    u.info[2] = (float)_frameSeed;
    u.info[3] = reset ? 1.0f : 0.0f;
    u.outp[0] = (float)outW;
    u.outp[1] = (float)outH;
    u.outp[2] = (float)w / (float)(kCellSize * _cellsW);
    u.outp[3] = (float)h / (float)(kCellSize * _cellsH);
    u.stat[0] = 1.0f - expf(-dt / 0.12f);
    u.stat[1] = 1.0f - expf(-dt / 0.60f);
    u.stat[2] = 1.0f - expf(-dt / 0.06f);
    u.stat[3] = 1.0f - expf(-dt / 0.12f);
    u.upsc[0] = wantAI ? (float)(w * 2u) : (float)w;
    u.upsc[1] = wantAI ? (float)(h * 2u) : (float)h;
    u.upsc[2] = fminf(1.0f, fmaxf(0.0f, s.upscaleSharpness));
    u.upsc[3] = (float)activeMode;

    uint32_t numPartials = _groupsW * _groupsH;
    id<MTLTexture> cellTex = _cellTex;
    id<MTLTexture> prevMap = _mapTex[1 - cur];
    id<MTLTexture> curMap = _mapTex[cur];
    id<MTLTexture> lutTex = _lutTex;
    id<MTLBuffer> partialsBuf = _partialsBuf;
    id<MTLBuffer> stateBuf = _stateBuf;
    id<MTLBuffer> sceneBuf = _sceneBuf;
    uint32_t gw = _groupsW, gh = _groupsH;
    float gpuMsCur = _gpuMsEma;
    os_unfair_lock_unlock(&_lock);

    if (wantAI && srOut) {
        const TrueHDRSRLayerMeta *meta = useQual ? kTrueHDRSRQualityMeta : kTrueHDRSRFastMeta;
        int numLayers = useQual ? 6 : 5;
        MTLSize srGrid = MTLSizeMake((w + 15u) / 16u, (h + 7u) / 8u, 1);
        MTLSize srTg = MTLSizeMake(16, 8, 1);

        id<MTLComputeCommandEncoder> srp = [cmdBuf computeCommandEncoder];
        srp.label = useQual ? @"TrueHDR-SR-Quality" : @"TrueHDR-SR-Fast";
        for (int li = 0; li < numLayers; li++) {
            const TrueHDRSRLayerMeta &m = meta[li];
            SRLayerU lu = {
                (int32_t)w, (int32_t)h,
                m.k, m.cin, m.cout, m.hasPrelu, m.skipFrom,
                m.wVec4Off, m.bVec4Off, m.aVec4Off,
                isLinearInput ? 4u : 0u
            };
            if (li == 0) {
                [srp setComputePipelineState:pipes.srInPipe];
                [srp setTexture:srcTex atIndex:0];
                [srp setTexture:srFeat[0] atIndex:1];
                [srp setBuffer:weightBuf offset:0 atIndex:0];
                [srp setBytes:&lu length:sizeof(SRLayerU) atIndex:1];
            } else if (li == numLayers - 1) {
                [srp setComputePipelineState:pipes.srOutPipe];
                [srp setTexture:srFeat[li - 1] atIndex:0];
                [srp setTexture:srcTex atIndex:1];
                [srp setTexture:srOut atIndex:2];
                [srp setBuffer:weightBuf offset:0 atIndex:0];
                [srp setBytes:&lu length:sizeof(SRLayerU) atIndex:1];
            } else {
                id<MTLTexture> skipT = (m.skipFrom >= 0 && m.skipFrom < 5) ? srFeat[m.skipFrom] : srFeat[li - 1];
                [srp setComputePipelineState:pipes.srMidPipe];
                [srp setTexture:srFeat[li - 1] atIndex:0];
                [srp setTexture:skipT atIndex:1];
                [srp setTexture:srFeat[li] atIndex:2];
                [srp setBuffer:weightBuf offset:0 atIndex:0];
                [srp setBytes:&lu length:sizeof(SRLayerU) atIndex:1];
            }
            [srp dispatchThreadgroups:srGrid threadsPerThreadgroup:srTg];
        }
        [srp endEncoding];
    }

    if (hdrActive) {
        id<MTLComputeCommandEncoder> cp = [cmdBuf computeCommandEncoder];
        cp.label = @"TrueHDR-Analysis";

        [cp setComputePipelineState:pipes.analyzePipe];
        [cp setTexture:srcTex atIndex:0];
        [cp setTexture:cellTex atIndex:1];
        [cp setBuffer:partialsBuf offset:0 atIndex:0];
        [cp setBytes:&u length:sizeof(FrameU) atIndex:1];
        [cp dispatchThreadgroups:MTLSizeMake(gw, gh, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];

        [cp setComputePipelineState:pipes.statsPipe];
        [cp setBuffer:partialsBuf offset:0 atIndex:0];
        [cp setBuffer:stateBuf offset:0 atIndex:1];
        [cp setBytes:&u length:sizeof(FrameU) atIndex:2];
        [cp setBytes:&numPartials length:sizeof(uint32_t) atIndex:3];
        [cp setTexture:lutTex atIndex:0];
        [cp dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];

        [cp setComputePipelineState:pipes.mapPipe];
        [cp setTexture:cellTex atIndex:0];
        [cp setTexture:prevMap atIndex:1];
        [cp setTexture:curMap atIndex:2];
        [cp setBuffer:stateBuf offset:0 atIndex:0];
        [cp setBytes:&u length:sizeof(FrameU) atIndex:1];
        [cp dispatchThreadgroups:MTLSizeMake(gw, gh, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [cp endEncoding];

        id<MTLBlitCommandEncoder> bp = [cmdBuf blitCommandEncoder];
        bp.label = @"TrueHDR-CopyState";
        [bp copyFromBuffer:stateBuf sourceOffset:0 toBuffer:sceneBuf destinationOffset:0 size:16];
        if ((_frameSeed & 15u) == 0u && _readbackBuf) {
            [bp copyFromBuffer:stateBuf sourceOffset:0 toBuffer:_readbackBuf destinationOffset:0 size:16];
        }
        [bp endEncoding];
    }

    if (_hud) {
        [_hud updateTelemetryWithWidth:w
                                height:h
                              outWidth:outW
                             outHeight:outH
                           pixelFormat:_desiredPixelFormat
                                   fps:_fpsEma
                                 gpuMs:gpuMsCur
                                   apl:_lastApl
                               effPeak:_lastEffPeak > 0.1f ? _lastEffPeak : s.peakBoost
                           edrHeadroom:_edrHeadroom
                         upscaleActive:upEnabled
                           upscaleMode:activeMode
                               iniPath:_iniPath ?: @"TrueHDR.ini"];
    }

    CGSize vs = _viewSize;
    if (vs.width <= 1.0 || vs.height <= 1.0) {
        vs = CGSizeMake((CGFloat)dstTex.width * 0.5, (CGFloat)dstTex.height * 0.5);
    }
    TrueHDRHUDDrawQuad hudQuad = _hud ? [_hud prepareQuadForSettings:s viewWidth:vs.width viewHeight:vs.height] : (TrueHDRHUDDrawQuad){};

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = dstTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> rp = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    rp.label = @"TrueHDR-Final";
    [rp setRenderPipelineState:pipes.finalPipe];
    [rp setFragmentTexture:srcTex atIndex:0];
    [rp setFragmentTexture:curMap atIndex:1];
    [rp setFragmentTexture:lutTex atIndex:2];
    [rp setFragmentTexture:(srOut ?: srcTex) atIndex:3];
    [rp setFragmentBytes:&u length:sizeof(FrameU) atIndex:0];
    [rp setFragmentBuffer:sceneBuf offset:0 atIndex:1];
    [rp drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    if (hudQuad.visible && pipes.hudPipe && hudQuad.texture) {
        HUDUniforms hu = {
            {hudQuad.normX, hudQuad.normY, hudQuad.normW, hudQuad.normH},
            {hudQuad.gain, 0.0f, 0.0f, 0.0f}
        };
        [rp setRenderPipelineState:pipes.hudPipe];
        [rp setVertexBytes:&hu length:sizeof(HUDUniforms) atIndex:0];
        [rp setFragmentTexture:hudQuad.texture atIndex:0];
        [rp setFragmentBytes:&hu length:sizeof(HUDUniforms) atIndex:0];
        [rp drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
    [rp endEncoding];

    __weak TrueHDRLayerContext *weakSelf = self;
    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        double dtGpu = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        if (dtGpu > 0.01 && dtGpu < 1000.0) {
            TrueHDRLayerContext *strong = weakSelf;
            if (strong) {
                os_unfair_lock_lock(&strong->_lock);
                strong->_gpuMsEma = strong->_gpuMsEma > 0.0f
                    ? (strong->_gpuMsEma * 0.85f + (float)dtGpu * 0.15f)
                    : (float)dtGpu;
                os_unfair_lock_unlock(&strong->_lock);
            }
        }
    }];

    if (getenv("TRUEHDR_DEBUG") && atoi(getenv("TRUEHDR_DEBUG")) != 0 && _frameSeed == 2) {
        id<MTLBuffer> dbg = [dev newBufferWithLength:sizeof(float) * 8 options:MTLResourceStorageModeShared];
        id<MTLBuffer> dbgPix = [dev newBufferWithLength:96 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> dp = [cmdBuf blitCommandEncoder];
        [dp copyFromBuffer:stateBuf sourceOffset:0 toBuffer:dbg destinationOffset:0 size:sizeof(float) * 8];
        [dp copyFromTexture:lutTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(240, 0, 0) sourceSize:MTLSizeMake(1, 1, 1)
                   toBuffer:dbgPix destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
        uint32_t dw = (uint32_t)dstTex.width;
        uint32_t dh = (uint32_t)dstTex.height;
        uint32_t sx1 = std::min(dw > 0 ? dw - 1 : 0, (uint32_t)(dw * 0.285));
        uint32_t sy1 = std::min(dh > 0 ? dh - 1 : 0, (uint32_t)(dh * 0.455));
        uint32_t sx2 = std::min(dw > 0 ? dw - 1 : 0, (uint32_t)(dw * 0.525));
        uint32_t sy2 = sy1;
        uint32_t sx3 = std::min(dw > 0 ? dw - 1 : 0, (uint32_t)(dw * 0.680));
        uint32_t sy3 = std::min(dh > 0 ? dh - 1 : 0, (uint32_t)(dh * 0.400));
        [dp copyFromTexture:dstTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx1, sy1, 0) sourceSize:MTLSizeMake(1, 1, 1)
                   toBuffer:dbgPix destinationOffset:16 destinationBytesPerRow:16 destinationBytesPerImage:16];
        [dp copyFromTexture:dstTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx2, sy2, 0) sourceSize:MTLSizeMake(1, 1, 1)
                   toBuffer:dbgPix destinationOffset:32 destinationBytesPerRow:16 destinationBytesPerImage:16];
        [dp copyFromTexture:dstTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx3, sy3, 0) sourceSize:MTLSizeMake(1, 1, 1)
                   toBuffer:dbgPix destinationOffset:48 destinationBytesPerRow:16 destinationBytesPerImage:16];
        [dp endEncoding];
        [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer>) {
            const float *f = (const float *)dbg.contents;
            const __fp16 *h = (const __fp16 *)dbgPix.contents;
            NSLog(@"[TrueHDR-Game] DBG state: apl=%.4f hdrFrac=%.4f effPeak=%.4f textCap=%.4f cut=%.1f frames=%.1f | lut240=(%.2f,%.2f,%.2f) leftTxt=(%.2f,%.2f,%.2f) rightTxt=(%.2f,%.2f,%.2f) shoulder=(%.2f,%.2f,%.2f)",
                  f[0], f[1], f[2], f[3], f[5], f[7],
                  (float)h[0], (float)h[1], (float)h[2],
                  (float)h[8], (float)h[9], (float)h[10],
                  (float)h[16], (float)h[17], (float)h[18],
                  (float)h[24], (float)h[25], (float)h[26]);
        }];
    }
}

- (void)showToast:(NSString *)text onLayer:(CAMetalLayer *)layer {
    (void)layer;
    if (!text) return;
    if (_hud) {
        [_hud showBannerText:text duration:2.0];
    }
}

- (void)releaseResources {
    os_unfair_lock_lock(&_lock);
    [_freeTexs removeAllObjects];
    _cellTex = nil;
    _mapTex[0] = nil;
    _mapTex[1] = nil;
    _partialsBuf = nil;
    _stateBuf = nil;
    _sceneBuf = nil;
    _lutTex = nil;
    [self releaseSrLocked];
    os_unfair_lock_unlock(&_lock);
}

@end
