#pragma once
#import <Foundation/Foundation.h>
#include "TrueHDRConfig.h"

NS_ASSUME_NONNULL_BEGIN

/// Resolves active TrueHDR.ini path in ReShade order:
/// $TRUEHDR_INI -> <exeDir>/TrueHDR.ini -> <cwd>/TrueHDR.ini -> global Application Support ini.
NSString *TrueHDRResolveIniPath(void);

/// Loads settings from the resolved INI file (creating global defaults if needed).
BOOL TrueHDRLoadIni(TrueHDRSettings *settings, uint64_t * _Nullable outMtimeNs, BOOL applyEnv);

/// Reloads settings if the active INI file changed on disk since *inOutMtimeNs.
BOOL TrueHDRReloadIniIfChanged(TrueHDRSettings *settings, uint64_t *inOutMtimeNs);

/// Atomically writes settings to the active INI file and broadcasts Darwin config change notification.
BOOL TrueHDRSaveIni(const TrueHDRSettings *settings, uint64_t * _Nullable outMtimeNs);

NS_ASSUME_NONNULL_END
