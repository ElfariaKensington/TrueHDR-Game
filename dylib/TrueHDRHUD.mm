#import "TrueHDRHUD.h"
#import <Carbon/Carbon.h>
#include <math.h>
#include <algorithm>
#include <vector>

static constexpr CGFloat kPanelW = 410.0;
static constexpr CGFloat kPanelH = 576.0;
static constexpr CGFloat kBannerMaxW = 620.0;
static constexpr CGFloat kBannerH = 30.0;
static constexpr CGFloat kScale = 2.0;

struct HUDSliderSpec {
    const char *label;
    float minVal;
    float maxVal;
    BOOL isPercent;
    const char *fmt;
};

static const HUDSliderSpec kSliders[8] = {
    {"Peak Boost (EDR)",     1.0f,  12.0f, NO,  "%.2fx"},
    {"Highlight Threshold",  0.15f, 0.88f, NO,  "%.2f"},
    {"Local Detail Punch",   0.00f, 1.50f, NO,  "%.2f"},
    {"P3 Gamut Expansion",   0.00f, 1.00f, NO,  "%.2f"},
    {"Shadow Toe Depth",     0.00f, 0.50f, NO,  "%.2f"},
    {"APL Headroom Guard",   0.00f, 1.00f, NO,  "%.2f"},
    {"Upscale Sharpness",    0.00f, 1.00f, YES, "%d%%"},
    {"Split Wipe Position",  0.05f, 0.95f, YES, "%d%%"},
};

static float GetSliderValue(const TrueHDRSettings &s, int idx) {
    switch (idx) {
        case 0: return s.peakBoost;
        case 1: return s.threshold;
        case 2: return s.localPunch;
        case 3: return s.gamutBoost;
        case 4: return s.shadowDepth;
        case 5: return s.aplGuard;
        case 6: return s.upscaleSharpness;
        case 7: return s.splitPos;
        default: return 0.0f;
    }
}

static void SetSliderValue(TrueHDRSettings &s, int idx, float v) {
    float c = fminf(kSliders[idx].maxVal, fmaxf(kSliders[idx].minVal, v));
    switch (idx) {
        case 0: s.peakBoost = c; break;
        case 1: s.threshold = c; break;
        case 2: s.localPunch = c; break;
        case 3: s.gamutBoost = c; break;
        case 4: s.shadowDepth = c; break;
        case 5: s.aplGuard = c; break;
        case 6: s.upscaleSharpness = c; return;
        case 7: s.splitPos = c; return;
        default: return;
    }
    strlcpy(s.preset, "custom", sizeof(s.preset));
}

static const char *ShortFormatName(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatBGRA8Unorm: return "BGRA8";
        case MTLPixelFormatBGRA8Unorm_sRGB: return "BGRA8_sRGB";
        case MTLPixelFormatRGBA8Unorm: return "RGBA8";
        case MTLPixelFormatRGBA8Unorm_sRGB: return "RGBA8_sRGB";
        case MTLPixelFormatBGR10A2Unorm: return "BGR10A2";
        case MTLPixelFormatRGB10A2Unorm: return "RGB10A2";
        case MTLPixelFormatRGBA16Float: return "RGBA16F";
        default: return "Metal";
    }
}

@implementation TrueHDRHUD {
    id<MTLDevice> _device;
    id<MTLTexture> _panelTex;
    id<MTLTexture> _panelTexRing[3];
    int _panelRingIdx;
    id<MTLTexture> _bannerTex;
    BOOL _overlayOpen;
    BOOL _panelDirty;
    BOOL _bannerDirty;
    CFAbsoluteTime _bannerUntil;
    CFAbsoluteTime _lastTelemetryRedraw;
    NSString *_bannerText;

    // Telemetry
    uint32_t _texW, _texH;
    uint32_t _outW, _outH;
    MTLPixelFormat _texFmt;
    float _fps;
    float _gpuMs;
    float _apl;
    float _effPeak;
    float _edrHeadroom;
    BOOL _upscaleActive;
    int32_t _upscaleMode;
    NSString *_iniPath;
    NSString *_appName;

    // Interaction state
    int _dragTarget; // -1 none, -2 move panel, 0..7 slider
    CGPoint _dragStartMouse;
    CGPoint _dragStartHudPos;
    TrueHDRSettings _lastRenderedSettings;
}

@synthesize overlayOpen = _overlayOpen;

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _device = device;
        _dragTarget = -1;
        _panelDirty = YES;
        _bannerDirty = YES;
        _edrHeadroom = 1.0f;
        _appName = [[NSProcessInfo processInfo] processName] ?: @"Game";
        _iniPath = @"TrueHDR.ini";
    }
    return self;
}

- (void)showBannerText:(NSString *)text duration:(NSTimeInterval)duration {
    if (!text) return;
    @synchronized (self) {
        _bannerText = [text copy];
        _bannerUntil = CFAbsoluteTimeGetCurrent() + duration;
        _bannerDirty = YES;
    }
}

- (void)toggleOverlay {
    BOOL opened = NO;
    @synchronized (self) {
        _overlayOpen = !_overlayOpen;
        _panelDirty = YES;
        opened = _overlayOpen;
    }
    if (opened) {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
    }
}

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
                         iniPath:(NSString *)iniPath {
    @synchronized (self) {
        _texW = w;
        _texH = h;
        _outW = outW;
        _outH = outH;
        _texFmt = fmt;
        _fps = fps;
        _gpuMs = gpuMs;
        _apl = apl;
        _effPeak = effPeak;
        _edrHeadroom = headroom;
        _upscaleActive = upscaleActive;
        _upscaleMode = upscaleMode;
        if (iniPath) _iniPath = iniPath;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_overlayOpen && now - _lastTelemetryRedraw >= 0.35) {
            _lastTelemetryRedraw = now;
            _panelDirty = YES;
        }
    }
}

- (id<MTLTexture>)ensureTexture:(id<MTLTexture>)tex width:(NSUInteger)w height:(NSUInteger)h {
    if (!_device) return nil;
    if (tex && tex.width == w && tex.height == h) return tex;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    return [_device newTextureWithDescriptor:td];
}

- (void)drawRect:(CGRect)r radius:(CGFloat)rad fill:(NSColor *)fill stroke:(NSColor *)stroke lineWidth:(CGFloat)lw {
    NSBezierPath *p = rad > 0.1
        ? [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad]
        : [NSBezierPath bezierPathWithRect:r];
    if (fill) { [fill setFill]; [p fill]; }
    if (stroke && lw > 0) { [stroke setStroke]; [p setLineWidth:lw]; [p stroke]; }
}

- (void)drawText:(NSString *)str inRect:(CGRect)r font:(NSFont *)font color:(NSColor *)color align:(NSTextAlignment)align {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = align;
    ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps};
    CGSize sz = [str sizeWithAttributes:attrs];
    CGRect tr = CGRectMake(r.origin.x, r.origin.y + (r.size.height - sz.height) * 0.5, r.size.width, sz.height);
    [str drawInRect:tr withAttributes:attrs];
}

- (void)drawCheckbox:(CGRect)box checked:(BOOL)on frameCol:(NSColor *)frameCol bgCol:(NSColor *)bgCol checkCol:(NSColor *)checkCol {
    [self drawRect:box radius:2 fill:bgCol stroke:frameCol lineWidth:1.0];
    if (on) {
        NSBezierPath *ck = [NSBezierPath bezierPath];
        [ck moveToPoint:CGPointMake(box.origin.x + 3.0, box.origin.y + box.size.height * 0.52)];
        [ck lineToPoint:CGPointMake(box.origin.x + box.size.width * 0.42, box.origin.y + box.size.height - 3.2)];
        [ck lineToPoint:CGPointMake(box.origin.x + box.size.width - 2.8, box.origin.y + 3.2)];
        [checkCol setStroke];
        [ck setLineWidth:1.8];
        [ck stroke];
    }
}

- (CGContextRef)beginTopDownBitmap:(std::vector<uint8_t> &)pixels width:(NSUInteger)pw height:(NSUInteger)ph {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), pw, ph, 8, pw * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    // Flip CTM so y=0 is top row in buffer memory (matches Metal UV top=0) and text renders upright.
    CGContextTranslateCTM(ctx, 0.0, (CGFloat)ph);
    CGContextScaleCTM(ctx, kScale, -kScale);
    return ctx;
}

- (void)renderBannerTextureLocked {
    NSUInteger pw = (NSUInteger)(kBannerMaxW * kScale);
    NSUInteger ph = (NSUInteger)(kBannerH * kScale);
    _bannerTex = [self ensureTexture:_bannerTex width:pw height:ph];
    if (!_bannerTex) return;

    std::vector<uint8_t> pixels(pw * ph * 4, 0);
    CGContextRef ctx = [self beginTopDownBitmap:pixels width:pw height:ph];
    if (!ctx) return;

    NSGraphicsContext *nsg = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsg];

    NSString *msg = _bannerText ?: @"TrueHDR 1.0  |  Press Home or Shift+F2 for HUD";
    NSFont *font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    CGFloat tw = ceil([msg sizeWithAttributes:@{NSFontAttributeName: font}].width) + 26.0;
    CGFloat boxW = fmin(kBannerMaxW - 2.0, fmax(200.0, tw));

    [self drawRect:CGRectMake(0.5, 0.5, boxW, kBannerH - 1.0)
            radius:2
              fill:[NSColor colorWithSRGBRed:0.08 green:0.09 blue:0.12 alpha:0.93]
            stroke:[NSColor colorWithSRGBRed:0.24 green:0.29 blue:0.38 alpha:1.0]
         lineWidth:1.0];
    // Classic ReShade steel-blue bottom accent bar
    [self drawRect:CGRectMake(0.5, kBannerH - 2.5, boxW, 2.0)
            radius:0
              fill:[NSColor colorWithSRGBRed:0.26 green:0.59 blue:0.98 alpha:1.0]
            stroke:nil
         lineWidth:0];
    [self drawText:msg
            inRect:CGRectMake(12, 0, boxW - 22, kBannerH - 2)
              font:font
             color:[NSColor colorWithSRGBRed:0.93 green:0.95 blue:0.98 alpha:1.0]
             align:NSTextAlignmentLeft];

    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(ctx);

    [_bannerTex replaceRegion:MTLRegionMake2D(0, 0, pw, ph) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:pw * 4];
    _bannerDirty = NO;
}

- (void)renderPanelTextureLocked:(const TrueHDRSettings &)s {
    NSUInteger pw = (NSUInteger)(kPanelW * kScale);
    NSUInteger ph = (NSUInteger)(kPanelH * kScale);
    _panelRingIdx = (_panelRingIdx + 1) % 3;
    _panelTexRing[_panelRingIdx] = [self ensureTexture:_panelTexRing[_panelRingIdx] width:pw height:ph];
    _panelTex = _panelTexRing[_panelRingIdx];
    if (!_panelTex) return;

    std::vector<uint8_t> pixels(pw * ph * 4, 0);
    CGContextRef ctx = [self beginTopDownBitmap:pixels width:pw height:ph];
    if (!ctx) return;

    NSGraphicsContext *nsg = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsg];

    // ReShade / OptiScaler ImGui Dark Steel Palette
    NSColor *winBg     = [NSColor colorWithSRGBRed:0.085 green:0.095 blue:0.120 alpha:0.94];
    NSColor *titleBg   = [NSColor colorWithSRGBRed:0.115 green:0.175 blue:0.285 alpha:0.98];
    NSColor *childBg   = [NSColor colorWithSRGBRed:0.110 green:0.125 blue:0.155 alpha:0.95];
    NSColor *frameBg   = [NSColor colorWithSRGBRed:0.155 green:0.175 blue:0.215 alpha:1.00];
    NSColor *borderCol = [NSColor colorWithSRGBRed:0.250 green:0.295 blue:0.375 alpha:0.95];
    NSColor *blueAc    = [NSColor colorWithSRGBRed:0.255 green:0.560 blue:0.945 alpha:1.00];
    NSColor *blueFill  = [NSColor colorWithSRGBRed:0.195 green:0.435 blue:0.760 alpha:0.95];
    NSColor *hdrTag    = [NSColor colorWithSRGBRed:0.200 green:0.750 blue:0.550 alpha:1.00];
    NSColor *txtMain   = [NSColor colorWithSRGBRed:0.920 green:0.940 blue:0.970 alpha:1.00];
    NSColor *txtDim    = [NSColor colorWithSRGBRed:0.620 green:0.665 blue:0.740 alpha:1.00];

    [self drawRect:CGRectMake(0.5, 0.5, kPanelW - 1.0, kPanelH - 1.0) radius:3 fill:winBg stroke:borderCol lineWidth:1.0];

    // Title Bar (y=1..27)
    [self drawRect:CGRectMake(1, 1, kPanelW - 2, 26) radius:2 fill:titleBg stroke:nil lineWidth:0];
    [self drawText:@"TrueHDR 1.0.0  —  Metal EDR + 4K"
            inRect:CGRectMake(10, 1, 290, 26)
              font:[NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]
             color:txtMain
             align:NSTextAlignmentLeft];
    NSString *fpsStr = s.showFps ? [NSString stringWithFormat:@"%.0f fps", _fps] : @"HDR";
    [self drawText:fpsStr
            inRect:CGRectMake(kPanelW - 88, 1, 56, 26)
              font:[NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium]
             color:hdrTag
             align:NSTextAlignmentRight];
    [self drawRect:CGRectMake(kPanelW - 25, 4, 19, 19) radius:2 fill:[NSColor colorWithSRGBRed:0.16 green:0.22 blue:0.34 alpha:1.0] stroke:borderCol lineWidth:0.8];
    [self drawText:@"×" inRect:CGRectMake(kPanelW - 25, 3, 19, 19) font:[NSFont systemFontOfSize:13 weight:NSFontWeightBold] color:txtMain align:NSTextAlignmentCenter];

    // Info / Statistics strip (y=32..68)
    [self drawRect:CGRectMake(10, 32, kPanelW - 20, 36) radius:2 fill:childBg stroke:borderCol lineWidth:0.8];
    float ms = _fps > 1.0f ? (1000.0f / _fps) : 16.6f;
    NSString *resStr = (_outW > _texW || _outH > _texH)
        ? [NSString stringWithFormat:@"%ux%u→%ux%u", _texW, _texH, _outW, _outH]
        : [NSString stringWithFormat:@"%ux%u", _texW, _texH];
    NSString *upTag = _upscaleActive ? [NSString stringWithUTF8String:TrueHDRUpscaleModeTitle(_upscaleMode)] : @"1:1";
    NSString *line1 = [NSString stringWithFormat:@"%@ | %@ | %s → P3 EDR", _appName, resStr, ShortFormatName(_texFmt)];
    NSString *line2 = [NSString stringWithFormat:@"%.1f ms (GPU %.1f ms) | %@ | Headroom %.1fx", ms, _gpuMs, upTag, _edrHeadroom];
    [self drawText:line1 inRect:CGRectMake(16, 34, kPanelW - 32, 16) font:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium] color:txtMain align:NSTextAlignmentLeft];
    [self drawText:line2 inRect:CGRectMake(16, 50, kPanelW - 32, 15) font:[NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightRegular] color:txtDim align:NSTextAlignmentLeft];

    // Section Header: Presets (y=75..94)
    [self drawRect:CGRectMake(10, 75, kPanelW - 20, 19) radius:2 fill:[NSColor colorWithSRGBRed:0.14 green:0.18 blue:0.26 alpha:1.0] stroke:nil lineWidth:0];
    [self drawText:@"▼  Preset Profile" inRect:CGRectMake(16, 75, 200, 19) font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold] color:txtMain align:NSTextAlignmentLeft];
    [self drawText:[NSString stringWithUTF8String:s.preset] inRect:CGRectMake(kPanelW - 110, 75, 94, 19) font:[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium] color:blueAc align:NSTextAlignmentRight];

    // Preset Tabs (y=98..120)
    const char *presets[4] = {"vivid", "natural", "cinema", "comfort"};
    const char *presetTitles[4] = {"Vivid", "Natural", "Cinema", "Comfort"};
    CGFloat btnW = (kPanelW - 20 - 12) / 4.0;
    for (int i = 0; i < 4; i++) {
        BOOL sel = (strcmp(s.preset, presets[i]) == 0);
        CGRect br = CGRectMake(10 + i * (btnW + 4), 98, btnW, 22);
        [self drawRect:br radius:2 fill:sel ? blueFill : frameBg stroke:sel ? blueAc : borderCol lineWidth:0.8];
        [self drawText:[NSString stringWithUTF8String:presetTitles[i]]
                inRect:br
                  font:[NSFont systemFontOfSize:11 weight:sel ? NSFontWeightSemibold : NSFontWeightRegular]
                 color:txtMain
                 align:NSTextAlignmentCenter];
    }

    // Checkboxes (y=128..233, 5 x 21pt)
    const char *tLabels[5] = {
        "Master Switch  (Opt+M)",
        "TrueHDR Tone Expansion  (Opt+H)",
        "4K Upscaling + Sharpening  (Opt+U)",
        "Split Compare Wipe  SDR | EDR  (Opt+S)",
        "Bypass Native HDR Content"
    };
    bool tVals[5] = {s.enabled, s.hdrEnabled, s.upscaleEnabled, s.splitEnabled, s.bypassNativeHdr};
    for (int i = 0; i < 5; i++) {
        CGFloat y = 128 + i * 21;
        CGRect box = CGRectMake(14, y + 3, 14, 14);
        [self drawCheckbox:box checked:tVals[i] frameCol:borderCol bgCol:frameBg checkCol:blueAc];
        [self drawText:[NSString stringWithUTF8String:tLabels[i]]
                inRect:CGRectMake(35, y, kPanelW - 50, 20)
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                 color:txtMain
                 align:NSTextAlignmentLeft];
    }

    // Upscale Mode selector (y=237..261)
    [self drawText:@"Upscale Mode"
            inRect:CGRectMake(14, 237, 96, 22)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
             color:txtDim
             align:NSTextAlignmentLeft];
    const char *upTitles[3] = {"Spatial 4K", "AI Fast", "AI Quality"};
    CGFloat modeW = (kPanelW - 122 - 8) / 3.0;
    for (int i = 0; i < 3; i++) {
        BOOL sel = (s.upscaleMode == i);
        CGRect mr = CGRectMake(112 + i * (modeW + 4), 237, modeW, 22);
        [self drawRect:mr radius:2 fill:sel ? blueFill : frameBg stroke:sel ? blueAc : borderCol lineWidth:0.8];
        [self drawText:[NSString stringWithUTF8String:upTitles[i]]
                inRect:mr
                  font:[NSFont systemFontOfSize:10.5 weight:sel ? NSFontWeightSemibold : NSFontWeightRegular]
                 color:txtMain
                 align:NSTextAlignmentCenter];
    }

    // Section Header: Uniform Parameters (y=269..288)
    [self drawRect:CGRectMake(10, 269, kPanelW - 20, 19) radius:2 fill:[NSColor colorWithSRGBRed:0.14 green:0.18 blue:0.26 alpha:1.0] stroke:nil lineWidth:0];
    [self drawText:@"▼  Uniform Parameters" inRect:CGRectMake(16, 269, 220, 19) font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold] color:txtMain align:NSTextAlignmentLeft];
    [self drawText:(s.enabled && (s.hdrEnabled || s.upscaleEnabled)) ? @"ACTIVE" : @"BYPASS"
            inRect:CGRectMake(kPanelW - 90, 269, 74, 19)
              font:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold]
             color:(s.enabled && (s.hdrEnabled || s.upscaleEnabled)) ? hdrTag : txtDim
             align:NSTextAlignmentRight];

    // ImGui-style Sliders (y=293..501, 8 x 26pt: bar on left 224pt, label on right)
    for (int i = 0; i < 8; i++) {
        CGFloat y = 293 + i * 26;
        float val = GetSliderValue(s, i);
        float t = (val - kSliders[i].minVal) / (kSliders[i].maxVal - kSliders[i].minVal);
        t = fminf(1.0f, fmaxf(0.0f, t));

        NSString *valStr = kSliders[i].isPercent
            ? [NSString stringWithFormat:@"%d%%", (int)roundf(val * 100.0f)]
            : [NSString stringWithFormat:[NSString stringWithUTF8String:kSliders[i].fmt], val];

        CGRect track = CGRectMake(12, y + 2, 224, 19);
        [self drawRect:track radius:2 fill:frameBg stroke:borderCol lineWidth:0.8];
        CGFloat fillW = fmax(2.0, (track.size.width - 2.0) * t);
        [self drawRect:CGRectMake(track.origin.x + 1, track.origin.y + 1, fillW, track.size.height - 2)
                radius:1
                  fill:blueFill
                stroke:nil
             lineWidth:0];
        CGFloat grabX = track.origin.x + 2.0 + (track.size.width - 10.0) * t;
        [self drawRect:CGRectMake(grabX, track.origin.y + 2, 6, track.size.height - 4)
                radius:1
                  fill:blueAc
                stroke:nil
             lineWidth:0];

        [self drawText:valStr
                inRect:track
                  font:[NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightSemibold]
                 color:txtMain
                 align:NSTextAlignmentCenter];
        [self drawText:[NSString stringWithUTF8String:kSliders[i].label]
                inRect:CGRectMake(244, y + 1, kPanelW - 254, 20)
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                 color:txtMain
                 align:NSTextAlignmentLeft];
    }

    // Footer action buttons (y=508..532)
    const char *actTitles[3] = {"Reload INI", "Save INI", "Reset Defaults"};
    CGFloat actW = (kPanelW - 20 - 8) / 3.0;
    for (int i = 0; i < 3; i++) {
        CGRect ar = CGRectMake(10 + i * (actW + 4), 508, actW, 24);
        [self drawRect:ar radius:2 fill:frameBg stroke:borderCol lineWidth:0.8];
        [self drawText:[NSString stringWithUTF8String:actTitles[i]]
                inRect:ar
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
                 color:txtMain
                 align:NSTextAlignmentCenter];
    }

    // INI Path + Key Hint (y=538..568)
    [self drawText:[NSString stringWithFormat:@"INI: %@", _iniPath]
            inRect:CGRectMake(12, 538, kPanelW - 24, 15)
              font:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightRegular]
             color:txtDim
             align:NSTextAlignmentLeft];
    [self drawText:@"Home / Shift+F2 / Opt+G: HUD   •   Opt+U: 4K   •   Opt+Drag: Split Wipe"
            inRect:CGRectMake(12, 553, kPanelW - 24, 14)
              font:[NSFont systemFontOfSize:9.5 weight:NSFontWeightRegular]
             color:txtDim
             align:NSTextAlignmentLeft];

    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(ctx);

    [_panelTex replaceRegion:MTLRegionMake2D(0, 0, pw, ph) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:pw * 4];
    _lastRenderedSettings = s;
    _panelDirty = NO;
}

- (TrueHDRHUDDrawQuad)prepareQuadForSettings:(const TrueHDRSettings &)settings
                                  viewWidth:(CGFloat)viewW
                                 viewHeight:(CGFloat)viewH {
    TrueHDRHUDDrawQuad q = {};
    if (viewW <= 1.0 || viewH <= 1.0) return q;

    @synchronized (self) {
        if (_overlayOpen) {
            if (_panelDirty || memcmp(&_lastRenderedSettings, &settings, sizeof(TrueHDRSettings)) != 0) {
                [self renderPanelTextureLocked:settings];
            }
            if (!_panelTex) return q;
            CGFloat scaleFit = fmin(1.0, fmin((viewW - 16.0) / kPanelW, (viewH - 16.0) / kPanelH));
            CGFloat drawW = kPanelW * scaleFit;
            CGFloat drawH = kPanelH * scaleFit;
            CGFloat x = fmin(fmax(8.0, (CGFloat)settings.hudX), fmax(8.0, viewW - drawW - 8.0));
            CGFloat y = fmin(fmax(8.0, (CGFloat)settings.hudY), fmax(8.0, viewH - drawH - 8.0));
            q.visible = YES;
            q.normX = (float)(x / viewW);
            q.normY = (float)(y / viewH);
            q.normW = (float)(drawW / viewW);
            q.normH = (float)(drawH / viewH);
            q.gain = 1.25f;
            q.texture = _panelTex;
            return q;
        }

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now < _bannerUntil) {
            if (_bannerDirty || !_bannerTex) {
                [self renderBannerTextureLocked];
            }
            if (!_bannerTex) return q;
            q.visible = YES;
            q.normX = (float)(14.0 / viewW);
            q.normY = (float)(14.0 / viewH);
            q.normW = (float)(kBannerMaxW / viewW);
            q.normH = (float)(kBannerH / viewH);
            q.gain = 1.25f;
            q.texture = _bannerTex;
            return q;
        }
    }
    return q;
}

- (BOOL)handleEvent:(NSEvent *)event
             window:(nullable NSWindow *)win
           settings:(TrueHDRSettings &)settings
         outChanged:(BOOL *)outChanged
            outSave:(BOOL *)outSave
          outReload:(BOOL *)outReload
           outReset:(BOOL *)outReset {
    if (outChanged) *outChanged = NO;
    if (outSave) *outSave = NO;
    if (outReload) *outReload = NO;
    if (outReset) *outReset = NO;

    NSEventType type = event.type;
    if (type == NSEventTypeKeyDown && !event.isARepeat) {
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSEventModifierFlags cleanMods = mods & (NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagShift);
        unsigned short kc = event.keyCode;
        BOOL isHome = (kc == kVK_Home) && (cleanMods == 0 || cleanMods == NSEventModifierFlagFunction);
        BOOL isShiftF2 = (kc == kVK_F2) && ((cleanMods & ~NSEventModifierFlagFunction) == NSEventModifierFlagShift);
        BOOL isOptG = (kc == kVK_ANSI_G) && (cleanMods == NSEventModifierFlagOption);
        if (isHome || isShiftF2 || isOptG) {
            [self toggleOverlay];
            return YES;
        }
        if (_overlayOpen && kc == kVK_Escape) {
            [self toggleOverlay];
            return YES;
        }
    }

    if (!_overlayOpen) return NO;
    if (type != NSEventTypeLeftMouseDown && type != NSEventTypeLeftMouseDragged && type != NSEventTypeLeftMouseUp) {
        return NO;
    }

    NSWindow *targetWin = event.window ?: win ?: [NSApp keyWindow] ?: [NSApp mainWindow];
    if (!targetWin || !targetWin.contentView) return NO;
    NSView *cv = targetWin.contentView;
    CGSize vs = cv.bounds.size;
    if (vs.width <= 1.0 || vs.height <= 1.0) return NO;

    CGPoint winPt = event.window ? event.locationInWindow : [targetWin convertPointFromScreen:[NSEvent mouseLocation]];
    CGPoint pt = [cv convertPoint:winPt fromView:nil];
    CGFloat mx = pt.x;
    CGFloat my = cv.isFlipped ? pt.y : (vs.height - pt.y);

    CGFloat scaleFit = fmin(1.0, fmin((vs.width - 16.0) / kPanelW, (vs.height - 16.0) / kPanelH));
    CGFloat drawW = kPanelW * scaleFit;
    CGFloat drawH = kPanelH * scaleFit;
    CGFloat hx = fmin(fmax(8.0, (CGFloat)settings.hudX), fmax(8.0, vs.width - drawW - 8.0));
    CGFloat hy = fmin(fmax(8.0, (CGFloat)settings.hudY), fmax(8.0, vs.height - drawH - 8.0));
    CGFloat lx = (mx - hx) / scaleFit;
    CGFloat ly = (my - hy) / scaleFit;
    BOOL inside = (lx >= 0 && lx <= kPanelW && ly >= 0 && ly <= kPanelH);

    if (type == NSEventTypeLeftMouseUp) {
        BOOL wasDragging = (_dragTarget != -1);
        _dragTarget = -1;
        if (wasDragging && outSave) *outSave = YES;
        return wasDragging || inside;
    }

    if (type == NSEventTypeLeftMouseDragged) {
        if (_dragTarget == -2) {
            settings.hudX = (float)fmin(fmax(8.0, _dragStartHudPos.x + (mx - _dragStartMouse.x)), fmax(8.0, vs.width - drawW - 8.0));
            settings.hudY = (float)fmin(fmax(8.0, _dragStartHudPos.y + (my - _dragStartMouse.y)), fmax(8.0, vs.height - drawH - 8.0));
            if (outChanged) *outChanged = YES;
            return YES;
        }
        if (_dragTarget >= 0 && _dragTarget < 8) {
            float t = (float)((lx - 12.0) / 224.0);
            t = fminf(1.0f, fmaxf(0.0f, t));
            float val = kSliders[_dragTarget].minVal + t * (kSliders[_dragTarget].maxVal - kSliders[_dragTarget].minVal);
            SetSliderValue(settings, _dragTarget, val);
            if (outChanged) *outChanged = YES;
            return YES;
        }
        return inside;
    }

    // LeftMouseDown
    if (!inside) return NO;

    // Close button [×]
    if (lx >= kPanelW - 28 && lx <= kPanelW - 4 && ly >= 2 && ly <= 26) {
        [self toggleOverlay];
        return YES;
    }

    // Titlebar drag
    if (ly <= 28) {
        _dragTarget = -2;
        _dragStartMouse = CGPointMake(mx, my);
        _dragStartHudPos = CGPointMake(hx, hy);
        return YES;
    }

    // Presets (y=98..120)
    if (ly >= 98 && ly <= 122) {
        const char *presets[4] = {"vivid", "natural", "cinema", "comfort"};
        CGFloat btnW = (kPanelW - 20 - 12) / 4.0;
        for (int i = 0; i < 4; i++) {
            CGFloat bx = 10 + i * (btnW + 4);
            if (lx >= bx && lx <= bx + btnW) {
                TrueHDRApplyPreset(&settings, presets[i]);
                if (outChanged) *outChanged = YES;
                if (outSave) *outSave = YES;
                return YES;
            }
        }
    }

    // Checkboxes (y=128..233, 5 items)
    if (ly >= 128 && ly < 233) {
        int idx = (int)((ly - 128) / 21);
        if (idx >= 0 && idx < 5) {
            if (idx == 0) settings.enabled = !settings.enabled;
            else if (idx == 1) settings.hdrEnabled = !settings.hdrEnabled;
            else if (idx == 2) settings.upscaleEnabled = !settings.upscaleEnabled;
            else if (idx == 3) settings.splitEnabled = !settings.splitEnabled;
            else settings.bypassNativeHdr = !settings.bypassNativeHdr;
            if (outChanged) *outChanged = YES;
            if (outSave) *outSave = YES;
            return YES;
        }
    }

    // Upscale Mode selector (y=237..261)
    if (ly >= 237 && ly <= 261) {
        CGFloat modeW = (kPanelW - 122 - 8) / 3.0;
        for (int i = 0; i < 3; i++) {
            CGFloat mx0 = 112 + i * (modeW + 4);
            if (lx >= mx0 && lx <= mx0 + modeW) {
                settings.upscaleMode = i;
                if (outChanged) *outChanged = YES;
                if (outSave) *outSave = YES;
                return YES;
            }
        }
    }

    // Sliders (y=293..501, 8 items)
    if (ly >= 293 && ly < 501 && lx >= 10 && lx <= 242) {
        int idx = (int)((ly - 293) / 26);
        if (idx >= 0 && idx < 8) {
            _dragTarget = idx;
            float t = (float)((lx - 12.0) / 224.0);
            t = fminf(1.0f, fmaxf(0.0f, t));
            float val = kSliders[idx].minVal + t * (kSliders[idx].maxVal - kSliders[idx].minVal);
            SetSliderValue(settings, idx, val);
            if (outChanged) *outChanged = YES;
            return YES;
        }
    }

    // Footer buttons (y=508..534)
    if (ly >= 508 && ly <= 534) {
        CGFloat actW = (kPanelW - 20 - 8) / 3.0;
        for (int i = 0; i < 3; i++) {
            CGFloat ax = 10 + i * (actW + 4);
            if (lx >= ax && lx <= ax + actW) {
                if (i == 0 && outReload) *outReload = YES;
                else if (i == 1 && outSave) *outSave = YES;
                else if (i == 2 && outReset) *outReset = YES;
                return YES;
            }
        }
    }

    return YES;
}

@end
