#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum TrueHDRUpscaleMode {
    TRUEHDR_UPSCALE_SPATIAL = 0, // FSR-style 12-tap EASU + RCAS (fastest, <0.5ms)
    TRUEHDR_UPSCALE_AI_FAST = 1, // 2x Neural SR (f12x5) + EASU/Lanczos + RCAS
    TRUEHDR_UPSCALE_AI_QUAL = 2  // 2x Neural SR (q16x6 Crisp4K) + EASU/Lanczos + RCAS
} TrueHDRUpscaleMode;

typedef struct TrueHDRSettings {
    bool enabled;
    bool hdrEnabled;
    bool upscaleEnabled;    // default true (4K output + EASU/RCAS or AI SR)
    int32_t upscaleMode;    // TrueHDRUpscaleMode (default TRUEHDR_UPSCALE_SPATIAL)
    float upscaleSharpness; // 0.0 .. 1.0 (default 0.50)
    float peakBoost;        // 1.0 .. 12.0 (default 6.0)
    float threshold;        // 0.15 .. 0.88 (default 0.46)
    float localPunch;       // 0.0 .. 1.5 (default 0.70)
    float gamutBoost;       // 0.0 .. 1.0 (default 0.45)
    float shadowDepth;      // 0.0 .. 0.5 (default 0.14)
    float aplGuard;         // 0.0 .. 1.0 (default 0.45)
    bool bypassNativeHdr;   // default true
    bool splitEnabled;      // default false
    float splitPos;         // 0.05 .. 0.95 (default 0.5)
    bool showBanner;        // default true
    bool showFps;           // default true
    float hudX;             // points from left (default 24)
    float hudY;             // points from top (default 24)
    char preset[32];        // "vivid" | "natural" | "cinema" | "comfort" | "custom"
} TrueHDRSettings;

static inline const char *TrueHDRUpscaleModeKey(int32_t mode) {
    switch (mode) {
        case TRUEHDR_UPSCALE_AI_FAST: return "fast";
        case TRUEHDR_UPSCALE_AI_QUAL: return "quality";
        default: return "spatial";
    }
}

static inline const char *TrueHDRUpscaleModeTitle(int32_t mode) {
    switch (mode) {
        case TRUEHDR_UPSCALE_AI_FAST: return "AI Fast";
        case TRUEHDR_UPSCALE_AI_QUAL: return "AI Quality";
        default: return "Spatial 4K";
    }
}

static inline TrueHDRSettings TrueHDRDefaultSettings(void) {
    TrueHDRSettings s = {};
    s.enabled = true;
    s.hdrEnabled = true;
    s.upscaleEnabled = true;
    s.upscaleMode = TRUEHDR_UPSCALE_SPATIAL;
    s.upscaleSharpness = 0.50f;
    s.peakBoost = 6.0f;
    s.threshold = 0.46f;
    s.localPunch = 0.70f;
    s.gamutBoost = 0.45f;
    s.shadowDepth = 0.14f;
    s.aplGuard = 0.45f;
    s.bypassNativeHdr = true;
    s.splitEnabled = false;
    s.splitPos = 0.5f;
    s.showBanner = true;
    s.showFps = true;
    s.hudX = 24.0f;
    s.hudY = 24.0f;
    strlcpy(s.preset, "vivid", sizeof(s.preset));
    return s;
}

static inline void TrueHDRApplyPreset(TrueHDRSettings *s, const char *name) {
    if (!s || !name) return;
    if (strcmp(name, "natural") == 0) {
        s->peakBoost = 4.0f; s->threshold = 0.52f; s->localPunch = 0.50f;
        s->gamutBoost = 0.30f; s->shadowDepth = 0.15f; s->aplGuard = 0.60f;
        strlcpy(s->preset, "natural", sizeof(s->preset));
    } else if (strcmp(name, "cinema") == 0) {
        s->peakBoost = 10.0f; s->threshold = 0.38f; s->localPunch = 0.95f;
        s->gamutBoost = 0.70f; s->shadowDepth = 0.18f; s->aplGuard = 0.30f;
        strlcpy(s->preset, "cinema", sizeof(s->preset));
    } else if (strcmp(name, "comfort") == 0) {
        s->peakBoost = 2.6f; s->threshold = 0.58f; s->localPunch = 0.35f;
        s->gamutBoost = 0.20f; s->shadowDepth = 0.08f; s->aplGuard = 0.70f;
        strlcpy(s->preset, "comfort", sizeof(s->preset));
    } else {
        s->peakBoost = 6.0f; s->threshold = 0.46f; s->localPunch = 0.70f;
        s->gamutBoost = 0.45f; s->shadowDepth = 0.14f; s->aplGuard = 0.45f;
        strlcpy(s->preset, "vivid", sizeof(s->preset));
    }
}

#define TRUEHDR_CONFIG_DIR  @"~/Library/Application Support/TrueHDR-Game"
#define TRUEHDR_INI_FILE    @"~/Library/Application Support/TrueHDR-Game/TrueHDR.ini"
#define TRUEHDR_STATUS_FILE @"~/Library/Application Support/TrueHDR-Game/status.json"
#define TRUEHDR_NOTIFY_CFG  @"com.elfaria.TrueHDRGame.configChanged"
#define TRUEHDR_NOTIFY_STAT @"com.elfaria.TrueHDRGame.statusChanged"

#ifdef __cplusplus
}
#endif
