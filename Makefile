BUILD := build
METALLIB := $(BUILD)/TrueHDR.metallib
METALLIB_H := $(BUILD)/TrueHDRMetallib.h
DYLIB := $(BUILD)/libTrueHDR.dylib
CLI := $(BUILD)/truehdr-run
APP := $(BUILD)/TrueHDR-Game.app
APP_BIN := $(APP)/Contents/MacOS/TrueHDRGame
TEST_BIN := $(BUILD)/sdr_metal_test

OBJCFLAGS := -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -I$(BUILD) -Idylib
FRAMEWORKS := -framework Foundation -framework AppKit -framework Metal -framework QuartzCore -framework Carbon -framework OpenGL -framework IOSurface

.PHONY: all clean test

all: $(DYLIB) $(CLI) $(APP_BIN) $(TEST_BIN)

$(BUILD):
	mkdir -p $(BUILD)

$(METALLIB): shaders/TrueHDR.metal | $(BUILD)
	xcrun -sdk macosx metal -std=metal3.0 -c shaders/TrueHDR.metal -o $(BUILD)/TrueHDR.air
	xcrun -sdk macosx metallib $(BUILD)/TrueHDR.air -o $(METALLIB)

$(METALLIB_H): $(METALLIB)
	python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); open(sys.argv[2],"w").write("#pragma once\n#include <stddef.h>\nstatic const unsigned char kTrueHDRMetallibBytes[] = {" + ",".join(str(b) for b in d) + "};\nstatic const size_t kTrueHDRMetallibLength = " + str(len(d)) + ";\n")' $(METALLIB) $(METALLIB_H)

$(DYLIB): dylib/TrueHDRHook.mm dylib/TrueHDRRenderer.mm dylib/TrueHDRIni.mm dylib/TrueHDRHUD.mm dylib/TrueHDRRenderer.h dylib/TrueHDRIni.h dylib/TrueHDRHUD.h dylib/TrueHDRConfig.h dylib/TrueHDRSRWeights.h $(METALLIB_H) | $(BUILD)
	clang++ -arch arm64 -arch x86_64 -shared $(OBJCFLAGS) $(FRAMEWORKS) dylib/TrueHDRHook.mm dylib/TrueHDRRenderer.mm dylib/TrueHDRIni.mm dylib/TrueHDRHUD.mm -o $(DYLIB)
	codesign --force --sign - $(DYLIB)

$(CLI): cli/truehdr-run.swift | $(BUILD)
	swiftc -O cli/truehdr-run.swift -o $(CLI)
	codesign --force --sign - $(CLI)

$(APP_BIN): app/TrueHDRGameApp.swift $(DYLIB) | $(BUILD)
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(DYLIB) "$(APP)/Contents/Resources/libTrueHDR.dylib"
	swiftc -O -parse-as-library app/TrueHDRGameApp.swift -o "$(APP_BIN)"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>TrueHDRGame</string><key>CFBundleIdentifier</key><string>com.elfaria.TrueHDRGame</string><key>CFBundleName</key><string>TrueHDR Game</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0.0</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>\n' > "$(APP)/Contents/Info.plist"
	codesign --force --deep --sign - "$(APP)"

$(TEST_BIN): tests/sdr_metal_test.swift | $(BUILD)
	swiftc -O tests/sdr_metal_test.swift -o $(TEST_BIN)
	codesign --force --sign - $(TEST_BIN)

clean:
	rm -rf $(BUILD)
