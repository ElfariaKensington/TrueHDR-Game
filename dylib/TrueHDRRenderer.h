#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "TrueHDRConfig.h"
#import "TrueHDRHUD.h"

NS_ASSUME_NONNULL_BEGIN

@interface TrueHDRLayerContext : NSObject

@property (nonatomic, strong, nullable) id<MTLDevice> device;
@property (nonatomic, strong, nullable) TrueHDRHUD *hud;
@property (nonatomic, copy, nullable) NSString *iniPath;
@property (nonatomic, assign) CGSize viewSize;
@property (nonatomic, assign) float edrHeadroom;
@property (nonatomic, assign) MTLPixelFormat desiredPixelFormat;
@property (nonatomic, assign) BOOL desiredFramebufferOnly;
@property (nonatomic, assign) BOOL desiredEDR;
@property (nonatomic, assign) CGColorSpaceRef _Nullable desiredColorspace;
@property (nonatomic, strong, nullable) id desiredEDRMetadata;
@property (nonatomic, assign) BOOL hasDesiredDrawableSize;
@property (nonatomic, assign) CGSize desiredDrawableSize;

@property (nonatomic, assign) NSUInteger lastWidth;
@property (nonatomic, assign) NSUInteger lastHeight;
@property (nonatomic, assign) NSUInteger lastOutWidth;
@property (nonatomic, assign) NSUInteger lastOutHeight;
@property (nonatomic, assign) BOOL lastUpscaleActive;
@property (nonatomic, assign) int32_t lastUpscaleMode;
@property (nonatomic, assign) float lastGpuMs;
@property (nonatomic, assign) BOOL lastNativeHDR;

- (instancetype)initWithDevice:(nullable id<MTLDevice>)device;
- (nullable id<MTLTexture>)acquireGameTextureForDrawable:(id<CAMetalDrawable>)realDrawable
                                              pixelFormat:(MTLPixelFormat)fmt
                                                 gameSize:(CGSize)gameSize;
- (void)recycleGameTexture:(nullable id<MTLTexture>)tex;
- (void)encodeTrueHDR:(id<MTLCommandBuffer>)cmdBuf
            sourceTex:(id<MTLTexture>)srcTex
              destTex:(id<MTLTexture>)dstTex
             settings:(const TrueHDRSettings &)s
        isLinearInput:(BOOL)isLinearInput;
- (void)showToast:(NSString *)text onLayer:(CAMetalLayer *)layer;
- (void)releaseResources;

@end

BOOL TrueHDRPixelFormatIsLinear(MTLPixelFormat fmt);
BOOL TrueHDRPixelFormatIsSupportedSwapchain(MTLPixelFormat fmt);

NS_ASSUME_NONNULL_END
