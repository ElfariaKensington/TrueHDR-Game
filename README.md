# TrueHDR Game (Wine & macOS Native Metal Auto-HDR)

Real-time hardware EDR/HDR inverse tone-mapping for **Wine / CrossOver / GPTK (D3DMetal & DXVK/MoltenVK)** and **macOS native Metal games** via an in-process `CAMetalLayer` + `MTLCommandBuffer` swapchain hook (`libTrueHDR.dylib`).

## Build
```sh
make
```
Produces in `build/`:
- `libTrueHDR.dylib` — Universal (`arm64` + `x86_64`) Metal hook library with embedded `TrueHDR.metallib`.
- `truehdr-run` — CLI launcher that injects `libTrueHDR.dylib` into `.app` bundles, macOS executables, or `wine`/`wine64`.
- `TrueHDR-Game.app` — Menu-bar & control window app with live sliders, presets, game launcher, and status monitor.
- `sdr_metal_test` — Standalone `BGRA8Unorm` SDR Metal test app for verifying EDR output.

## Usage
```sh
# Launch menu-bar control app
open build/TrueHDR-Game.app

# Launch via CLI (Wine / GPTK / CrossOver or native Metal app)
./build/truehdr-run wine64 /path/to/game.exe
./build/truehdr-run /Applications/NativeGame.app
./build/truehdr-run --preset cinema --peak 8.0 --split /path/to/game
```

## In-Game Hotkeys
- `⌥M`: Toggle TrueHDR master switch
- `⌥H`: Toggle HDR tone-mapping
- `⌥S`: Toggle Split Compare (`SDR | EDR`)
- `⌥P`: Cycle Preset (`vivid` / `natural` / `cinema` / `comfort`)
- `⌥↑` / `⌥↓`: Adjust Peak Boost `±0.5×`
- `⌥←` / `⌥→` or `⌥` + Left-Drag: Move Split Wipe position
