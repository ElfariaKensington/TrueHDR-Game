#import "TrueHDRIni.h"
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

static uint64_t FileMtimeNs(NSString *path) {
    struct stat st;
    if (!path || stat(path.fileSystemRepresentation, &st) != 0) return 0;
    return (uint64_t)st.st_mtimespec.tv_sec * 1000000000ULL + (uint64_t)st.st_mtimespec.tv_nsec;
}

static BOOL ParseBoolValue(NSString *val) {
    NSString *low = [[val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return [low isEqualToString:@"1"] || [low isEqualToString:@"true"] || [low isEqualToString:@"yes"] || [low isEqualToString:@"on"];
}

static float ClampF(float v, float lo, float hi) {
    return fminf(hi, fmaxf(lo, v));
}

NSString *TrueHDRResolveIniPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *envIni = getenv("TRUEHDR_INI");
    if (envIni && envIni[0]) {
        return [[NSString stringWithUTF8String:envIni] stringByExpandingTildeInPath];
    }

    char exeBuf[4096];
    uint32_t exeSize = sizeof(exeBuf);
    if (_NSGetExecutablePath(exeBuf, &exeSize) == 0) {
        NSString *exeDir = [[NSString stringWithUTF8String:exeBuf] stringByDeletingLastPathComponent];
        NSString *candidate = [exeDir stringByAppendingPathComponent:@"TrueHDR.ini"];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }

    const char *gameCwd = getenv("NOTPROTON_GAME_CWD");
    if (gameCwd && gameCwd[0]) {
        NSString *candidate = [[NSString stringWithUTF8String:gameCwd] stringByAppendingPathComponent:@"TrueHDR.ini"];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }

    char cwdBuf[4096];
    if (getcwd(cwdBuf, sizeof(cwdBuf))) {
        NSString *candidate = [[NSString stringWithUTF8String:cwdBuf] stringByAppendingPathComponent:@"TrueHDR.ini"];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }

    return [TRUEHDR_INI_FILE stringByExpandingTildeInPath];
}

static int32_t ParseUpscaleMode(NSString *val) {
    NSString *low = [[val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([low isEqualToString:@"quality"] || [low isEqualToString:@"ai_quality"] || [low isEqualToString:@"2"]) {
        return TRUEHDR_UPSCALE_AI_QUAL;
    }
    if ([low isEqualToString:@"fast"] || [low isEqualToString:@"ai_fast"] || [low isEqualToString:@"1"]) {
        return TRUEHDR_UPSCALE_AI_FAST;
    }
    return TRUEHDR_UPSCALE_SPATIAL;
}

static void ApplyIniKeyValue(TrueHDRSettings *s, NSString *section, NSString *key, NSString *val) {
    NSString *sk = [NSString stringWithFormat:@"%@.%@", section.lowercaseString, key.lowercaseString];
    float fv = val.floatValue;

    if ([sk isEqualToString:@"general.enabled"]) {
        s->enabled = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"general.preset"]) {
        NSString *p = [[val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (p.length > 0 && ![p isEqualToString:@"custom"]) {
            TrueHDRApplyPreset(s, p.UTF8String);
        } else {
            strlcpy(s->preset, p.UTF8String, sizeof(s->preset));
        }
    } else if ([sk isEqualToString:@"upscale.enabled"]) {
        s->upscaleEnabled = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"upscale.mode"]) {
        s->upscaleMode = ParseUpscaleMode(val);
    } else if ([sk isEqualToString:@"upscale.sharpness"]) {
        s->upscaleSharpness = ClampF(fv, 0.0f, 1.0f);
    } else if ([sk isEqualToString:@"hdr.enabled"]) {
        s->hdrEnabled = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"hdr.peakboost"]) {
        s->peakBoost = ClampF(fv, 1.0f, 12.0f);
    } else if ([sk isEqualToString:@"hdr.threshold"]) {
        s->threshold = ClampF(fv, 0.15f, 0.88f);
    } else if ([sk isEqualToString:@"hdr.localpunch"]) {
        s->localPunch = ClampF(fv, 0.0f, 1.5f);
    } else if ([sk isEqualToString:@"hdr.gamutboost"]) {
        s->gamutBoost = ClampF(fv, 0.0f, 1.0f);
    } else if ([sk isEqualToString:@"hdr.shadowdepth"]) {
        s->shadowDepth = ClampF(fv, 0.0f, 0.5f);
    } else if ([sk isEqualToString:@"hdr.aplguard"]) {
        s->aplGuard = ClampF(fv, 0.0f, 1.0f);
    } else if ([sk isEqualToString:@"hdr.bypassnativehdr"]) {
        s->bypassNativeHdr = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"splitter.enabled"]) {
        s->splitEnabled = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"splitter.position"]) {
        s->splitPos = ClampF(fv, 0.05f, 0.95f);
    } else if ([sk isEqualToString:@"hud.showbanner"]) {
        s->showBanner = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"hud.showfps"]) {
        s->showFps = ParseBoolValue(val);
    } else if ([sk isEqualToString:@"hud.hudposx"]) {
        s->hudX = fmaxf(8.0f, fv);
    } else if ([sk isEqualToString:@"hud.hudposy"]) {
        s->hudY = fmaxf(8.0f, fv);
    }
}

static void ApplyEnvOverridesToSettings(TrueHDRSettings *s) {
    if (const char *p = getenv("TRUEHDR_PRESET")) TrueHDRApplyPreset(s, p);
    if (const char *b = getenv("TRUEHDR_PEAK_BOOST")) s->peakBoost = ClampF((float)atof(b), 1.0f, 12.0f);
    if (const char *sp = getenv("TRUEHDR_SPLIT")) s->splitEnabled = atoi(sp) != 0;
    if (const char *bn = getenv("TRUEHDR_BYPASS_NATIVE")) s->bypassNativeHdr = atoi(bn) != 0;
    if (const char *up = getenv("TRUEHDR_UPSCALE")) s->upscaleEnabled = atoi(up) != 0;
    if (const char *um = getenv("TRUEHDR_UPSCALE_MODE")) s->upscaleMode = ParseUpscaleMode([NSString stringWithUTF8String:um]);
    if (const char *us = getenv("TRUEHDR_UPSCALE_SHARPNESS")) s->upscaleSharpness = ClampF((float)atof(us), 0.0f, 1.0f);
}

BOOL TrueHDRLoadIni(TrueHDRSettings *settings, uint64_t * _Nullable outMtimeNs, BOOL applyEnv) {
    if (!settings) return NO;
    *settings = TrueHDRDefaultSettings();
    NSString *path = TrueHDRResolveIniPath();
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];

    if (!text) {
        TrueHDRSaveIni(settings, outMtimeNs);
        if (applyEnv) ApplyEnvOverridesToSettings(settings);
        return NO;
    }

    NSString *section = @"general";
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];
        if (line.length == 0 || [line hasPrefix:@";"] || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"] && line.length > 2) {
            section = [[line substringWithRange:NSMakeRange(1, line.length - 2)] stringByTrimmingCharactersInSet:ws];
            continue;
        }
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        NSRange comment = [val rangeOfString:@";"];
        if (comment.location != NSNotFound) {
            val = [[val substringToIndex:comment.location] stringByTrimmingCharactersInSet:ws];
        }
        ApplyIniKeyValue(settings, section, key, val);
    }

    if (outMtimeNs) *outMtimeNs = FileMtimeNs(path);
    if (applyEnv) ApplyEnvOverridesToSettings(settings);
    return YES;
}

BOOL TrueHDRReloadIniIfChanged(TrueHDRSettings *settings, uint64_t *inOutMtimeNs) {
    if (!settings || !inOutMtimeNs) return NO;
    NSString *path = TrueHDRResolveIniPath();
    uint64_t mtime = FileMtimeNs(path);
    if (mtime == 0 || mtime == *inOutMtimeNs) return NO;
    return TrueHDRLoadIni(settings, inOutMtimeNs, NO);
}

BOOL TrueHDRSaveIni(const TrueHDRSettings *settings, uint64_t * _Nullable outMtimeNs) {
    if (!settings) return NO;
    NSString *path = TrueHDRResolveIniPath();
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *ini = [NSString stringWithFormat:
        @"; TrueHDR-Game Configuration (ReShade-style live hot-reload)\n"
        @"; Press Home, Shift+F2, or Opt+G in-game for the interactive overlay HUD.\n\n"
        @"[GENERAL]\n"
        @"Enabled=%d\n"
        @"Preset=%s\n\n"
        @"[UPSCALE]\n"
        @"Enabled=%d\n"
        @"Mode=%s\n"
        @"Sharpness=%.2f\n\n"
        @"[HDR]\n"
        @"Enabled=%d\n"
        @"PeakBoost=%.2f\n"
        @"Threshold=%.2f\n"
        @"LocalPunch=%.2f\n"
        @"GamutBoost=%.2f\n"
        @"ShadowDepth=%.2f\n"
        @"AplGuard=%.2f\n"
        @"BypassNativeHdr=%d\n\n"
        @"[SPLITTER]\n"
        @"Enabled=%d\n"
        @"Position=%.2f\n\n"
        @"[HUD]\n"
        @"ShowBanner=%d\n"
        @"ShowFps=%d\n"
        @"HudPosX=%.0f\n"
        @"HudPosY=%.0f\n",
        settings->enabled ? 1 : 0,
        settings->preset,
        settings->upscaleEnabled ? 1 : 0,
        TrueHDRUpscaleModeKey(settings->upscaleMode),
        settings->upscaleSharpness,
        settings->hdrEnabled ? 1 : 0,
        settings->peakBoost,
        settings->threshold,
        settings->localPunch,
        settings->gamutBoost,
        settings->shadowDepth,
        settings->aplGuard,
        settings->bypassNativeHdr ? 1 : 0,
        settings->splitEnabled ? 1 : 0,
        settings->splitPos,
        settings->showBanner ? 1 : 0,
        settings->showFps ? 1 : 0,
        settings->hudX,
        settings->hudY];

    BOOL ok = [ini writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (ok) {
        if (outMtimeNs) *outMtimeNs = FileMtimeNs(path);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)TRUEHDR_NOTIFY_CFG,
                                             NULL, NULL, TRUE);
    }
    return ok;
}
