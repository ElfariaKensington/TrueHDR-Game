#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#include "TrueHDRConfig.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct TrueHDRHUDDrawQuad {
    BOOL visible;
    float normX, normY, normW, normH; // Top-left normalized [0..1]
    float gain;                      // Linear gain boost in HDR space
    id<MTLTexture> __unsafe_unretained texture;
} TrueHDRHUDDrawQuad;

/// ReShade-style in-game Metal HUD + startup/hotkey banner controller.
@interface TrueHDRHUD : NSObject

@property (nonatomic, assign, readonly) BOOL overlayOpen;

- (instancetype)initWithDevice:(id<MTLDevice>)device;

/// Shows a short ReShade banner or hotkey toast for `duration` seconds.
- (void)showBannerText:(NSString *)text duration:(NSTimeInterval)duration;

/// Toggles the interactive ReShade overlay panel open or closed.
- (void)toggleOverlay;

/// Updates frame telemetry (FPS, pixel format, resolution, INI path, EDR headroom, upscale info).
- (void)updateTelemetryWithWidth:(uint32_t)w
                          height:(uint32_t)h
                       outWidth:(uint32_t)outW
                      outHeight:(uint32_t)outH
                     pixelFormat:(MTLPixelFormat)fmt
                             fps:(float)fps
                           gpuMs:(float)gpuMs
                             apl:(float)apl
                         effPeak:(float)effPeak
                     edrHeadroom:(float)headroom
                   upscaleActive:(BOOL)upscaleActive
                     upscaleMode:(int32_t)upscaleMode
                         iniPath:(NSString *)iniPath;

/// Renders HUD / banner into its cached RGBA8Unorm texture if dirty and returns draw quad info.
- (TrueHDRHUDDrawQuad)prepareQuadForSettings:(const TrueHDRSettings &)settings
                                  viewWidth:(CGFloat)viewW
                                 viewHeight:(CGFloat)viewH;

/// Handles NSEvent mouse/keyboard input from NSApplication sendEvent:.
/// Returns YES if the event was consumed by the HUD.
- (BOOL)handleEvent:(NSEvent *)event
             window:(nullable NSWindow *)win
           settings:(TrueHDRSettings &)settings
         outChanged:(BOOL *)outChanged
            outSave:(BOOL *)outSave
          outReload:(BOOL *)outReload
           outReset:(BOOL *)outReset;

@end

NS_ASSUME_NONNULL_END
