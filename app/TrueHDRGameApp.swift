import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConfigModel: Codable, Equatable {
    var enabled: Bool = true
    var hdrEnabled: Bool = true
    var upscaleEnabled: Bool = true
    var upscaleMode: String = "spatial"
    var upscaleSharpness: Double = 0.50
    var peakBoost: Double = 6.0
    var threshold: Double = 0.46
    var localPunch: Double = 0.70
    var gamutBoost: Double = 0.45
    var shadowDepth: Double = 0.14
    var aplGuard: Double = 0.45
    var bypassNativeHdr: Bool = true
    var splitEnabled: Bool = false
    var splitPos: Double = 0.5
    var preset: String = "vivid"
}

struct StatusModel: Codable {
    var pid: Int = 0
    var app: String = ""
    var width: Int = 0
    var height: Int = 0
    var outputWidth: Int?
    var outputHeight: Int?
    var pixelFormat: Int = 0
    var active: Bool = false
    var upscaleActive: Bool?
    var upscaleMode: String?
    var gpuMs: Double?
    var updatedAt: Double = 0
}

final class TrueHDRController: ObservableObject {
    @Published var cfg = ConfigModel()
    @Published var status: StatusModel?
    @Published var lastLaunchNote: String = ""

    private let configURL: URL
    private let statusURL: URL
    private let notifyCfg = CFNotificationName("com.elfaria.TrueHDRGame.configChanged" as CFString)
    private let notifyStat = CFNotificationName("com.elfaria.TrueHDRGame.statusChanged" as CFString)
    private var suppressSave = false

    init() {
        let appSup = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TrueHDR-Game")
        try? FileManager.default.createDirectory(at: appSup, withIntermediateDirectories: true)
        configURL = appSup.appendingPathComponent("TrueHDR.ini")
        statusURL = appSup.appendingPathComponent("status.json")
        loadConfig()
        loadStatus()

        let nc = CFNotificationCenterGetDarwinNotifyCenter()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(nc, selfPtr, { _, obs, _, _, _ in
            guard let obs else { return }
            let ctrl = Unmanaged<TrueHDRController>.fromOpaque(obs).takeUnretainedValue()
            DispatchQueue.main.async { ctrl.loadConfig() }
        }, notifyCfg.rawValue, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(nc, selfPtr, { _, obs, _, _, _ in
            guard let obs else { return }
            let ctrl = Unmanaged<TrueHDRController>.fromOpaque(obs).takeUnretainedValue()
            DispatchQueue.main.async { ctrl.loadStatus() }
        }, notifyStat.rawValue, nil, .deliverImmediately)
    }

    func loadConfig() {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            saveConfig()
            return
        }
        var parsed = ConfigModel()
        var section = "general"
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let vRaw = line[line.index(after: eq)...].split(separator: ";", maxSplits: 1).first ?? ""
            let v = String(vRaw).trimmingCharacters(in: .whitespaces)
            let b = ["1", "true", "yes", "on"].contains(v.lowercased())
            let d = Double(v) ?? 0.0
            switch "\(section).\(k)" {
            case "general.enabled": parsed.enabled = b
            case "general.preset": parsed.preset = v.lowercased()
            case "upscale.enabled": parsed.upscaleEnabled = b
            case "upscale.mode":
                let ml = v.lowercased()
                parsed.upscaleMode = (ml == "fast" || ml == "quality" || ml == "spatial") ? ml : "spatial"
            case "upscale.sharpness": parsed.upscaleSharpness = min(1.0, max(0.0, d))
            case "hdr.enabled": parsed.hdrEnabled = b
            case "hdr.peakboost": parsed.peakBoost = min(12.0, max(1.0, d))
            case "hdr.threshold": parsed.threshold = min(0.88, max(0.15, d))
            case "hdr.localpunch": parsed.localPunch = min(1.5, max(0.0, d))
            case "hdr.gamutboost": parsed.gamutBoost = min(1.0, max(0.0, d))
            case "hdr.shadowdepth": parsed.shadowDepth = min(0.5, max(0.0, d))
            case "hdr.aplguard": parsed.aplGuard = min(1.0, max(0.0, d))
            case "hdr.bypassnativehdr": parsed.bypassNativeHdr = b
            case "splitter.enabled": parsed.splitEnabled = b
            case "splitter.position": parsed.splitPos = min(0.95, max(0.05, d))
            default: break
            }
        }
        suppressSave = true
        cfg = parsed
        suppressSave = false
    }

    func saveConfig() {
        guard !suppressSave else { return }
        let ini = """
        ; TrueHDR-Game Configuration (ReShade-style live hot-reload)
        ; Press Home, Shift+F2, or Opt+G in-game for the interactive overlay HUD.

        [GENERAL]
        Enabled=\(cfg.enabled ? 1 : 0)
        Preset=\(cfg.preset)

        [UPSCALE]
        Enabled=\(cfg.upscaleEnabled ? 1 : 0)
        Mode=\(cfg.upscaleMode)
        Sharpness=\(String(format: "%.2f", cfg.upscaleSharpness))

        [HDR]
        Enabled=\(cfg.hdrEnabled ? 1 : 0)
        PeakBoost=\(String(format: "%.2f", cfg.peakBoost))
        Threshold=\(String(format: "%.2f", cfg.threshold))
        LocalPunch=\(String(format: "%.2f", cfg.localPunch))
        GamutBoost=\(String(format: "%.2f", cfg.gamutBoost))
        ShadowDepth=\(String(format: "%.2f", cfg.shadowDepth))
        AplGuard=\(String(format: "%.2f", cfg.aplGuard))
        BypassNativeHdr=\(cfg.bypassNativeHdr ? 1 : 0)

        [SPLITTER]
        Enabled=\(cfg.splitEnabled ? 1 : 0)
        Position=\(String(format: "%.2f", cfg.splitPos))
        """
        try? ini.write(to: configURL, atomically: true, encoding: .utf8)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notifyCfg, nil, nil, true)
    }

    func loadStatus() {
        guard let data = try? Data(contentsOf: statusURL),
              let st = try? JSONDecoder().decode(StatusModel.self, from: data) else { return }
        if Date().timeIntervalSince1970 - st.updatedAt < 5.0 {
            status = st
        } else {
            status = nil
        }
    }

    func applyPreset(_ name: String) {
        cfg.preset = name
        switch name {
        case "natural":
            cfg.peakBoost = 4.0; cfg.threshold = 0.52; cfg.localPunch = 0.50
            cfg.gamutBoost = 0.30; cfg.shadowDepth = 0.15; cfg.aplGuard = 0.60
        case "cinema":
            cfg.peakBoost = 10.0; cfg.threshold = 0.38; cfg.localPunch = 0.95
            cfg.gamutBoost = 0.70; cfg.shadowDepth = 0.18; cfg.aplGuard = 0.30
        case "comfort":
            cfg.peakBoost = 2.6; cfg.threshold = 0.58; cfg.localPunch = 0.35
            cfg.gamutBoost = 0.20; cfg.shadowDepth = 0.08; cfg.aplGuard = 0.70
        default:
            cfg.preset = "vivid"
            cfg.peakBoost = 6.0; cfg.threshold = 0.46; cfg.localPunch = 0.70
            cfg.gamutBoost = 0.45; cfg.shadowDepth = 0.14; cfg.aplGuard = 0.45
        }
        saveConfig()
    }

    func reset() {
        cfg = ConfigModel()
        saveConfig()
    }

    func locateDylib() -> String? {
        let bundleRes = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/libTrueHDR.dylib").path
        let exeSibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libTrueHDR.dylib").path
        let candidates = [bundleRes, exeSibling].compactMap { $0 } + [
            "/Users/elfaria/.gemini/antigravity/scratch/TrueHDR-Game/build/libTrueHDR.dylib",
            "/usr/local/lib/libTrueHDR.dylib"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func pickAndLaunchGame() {
        let panel = NSOpenPanel()
        panel.title = "Launch macOS Game (.app) or Windows Game (.exe via Wine)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle, UTType(filenameExtension: "exe") ?? .data, .unixExecutable]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launch(url: url)
    }

    func launch(url: URL) {
        guard let dylib = locateDylib() else {
            lastLaunchNote = "libTrueHDR.dylib not found"
            return
        }
        var targetBin = url.path
        var launchArgs: [String] = []

        if url.pathExtension == "app" {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let exe = dict["CFBundleExecutable"] as? String {
                targetBin = url.appendingPathComponent("Contents/MacOS/\(exe)").path
            }
        } else if url.pathExtension.lowercased() == "exe" {
            let wineCandidates = [
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine",
                "/opt/homebrew/bin/wine64",
                "/opt/homebrew/bin/wine",
                "/usr/local/bin/wine64",
                "/usr/local/bin/wine"
            ]
            guard let wine = wineCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                lastLaunchNote = "No wine64/CrossOver binary found in standard paths. Use CLI: truehdr-run <wine> \(url.lastPathComponent)"
                return
            }
            launchArgs = [url.path]
            targetBin = wine
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: targetBin)
        proc.arguments = launchArgs
        var env = ProcessInfo.processInfo.environment
        for key in ["DYLD_INSERT_LIBRARIES", "STEAM_DYLD_INSERT_LIBRARIES"] {
            if let existing = env[key], !existing.isEmpty {
                let parts = existing.split(separator: ":").map(String.init)
                if !parts.contains(dylib) {
                    env[key] = existing + ":" + dylib
                }
            } else {
                env[key] = dylib
            }
        }
        proc.environment = env
        do {
            try proc.run()
            lastLaunchNote = "Launched \(url.lastPathComponent) with TrueHDR"
        } catch {
            lastLaunchNote = "Launch failed: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @ObservedObject var ctrl: TrueHDRController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TrueHDR Game").font(.headline)
                    if let st = ctrl.status {
                        let ow = st.outputWidth ?? st.width
                        let oh = st.outputHeight ?? st.height
                        let res = (ow > st.width || oh > st.height) ? "\(st.width)×\(st.height) → \(ow)×\(oh)" : "\(st.width)×\(st.height)"
                        let hdrTxt = st.active ? "EDR" : "SDR"
                        let upTxt = (st.upscaleActive == true) ? " • \(st.upscaleMode ?? "spatial")" : ""
                        Text("\(st.app) • \(res) • \(hdrTxt)\(upTxt)")
                            .font(.caption).foregroundColor(.green)
                    } else {
                        Text("No hooked Metal game detected")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { ctrl.cfg.enabled },
                    set: { ctrl.cfg.enabled = $0; ctrl.saveConfig() }
                )).toggleStyle(.switch).labelsHidden()
            }

            HStack {
                Button("Launch Game (.app / .exe)…") { ctrl.pickAndLaunchGame() }
                    .buttonStyle(.borderedProminent)
                Toggle("HDR", isOn: Binding(
                    get: { ctrl.cfg.hdrEnabled },
                    set: { ctrl.cfg.hdrEnabled = $0; ctrl.saveConfig() }
                ))
                Toggle("4K Upscale", isOn: Binding(
                    get: { ctrl.cfg.upscaleEnabled },
                    set: { ctrl.cfg.upscaleEnabled = $0; ctrl.saveConfig() }
                ))
            }
            if ctrl.cfg.upscaleEnabled {
                HStack(spacing: 8) {
                    Text("Upscaler").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { ctrl.cfg.upscaleMode },
                        set: { ctrl.cfg.upscaleMode = $0; ctrl.saveConfig() }
                    )) {
                        Text("Spatial 4K").tag("spatial")
                        Text("AI Fast").tag("fast")
                        Text("AI Quality").tag("quality")
                    }
                    .pickerStyle(.segmented)
                }
                VStack(spacing: 2) {
                    HStack {
                        Text("Upscale Sharpness").font(.caption)
                        Spacer()
                        Text(String(format: "%.0f%%", ctrl.cfg.upscaleSharpness * 100)).font(.caption.monospacedDigit()).foregroundColor(.orange)
                    }
                    Slider(value: Binding(
                        get: { ctrl.cfg.upscaleSharpness },
                        set: { ctrl.cfg.upscaleSharpness = $0; ctrl.saveConfig() }
                    ), in: 0.0...1.0, step: 0.02)
                }
            }
            if !ctrl.lastLaunchNote.isEmpty {
                Text(ctrl.lastLaunchNote).font(.caption2).foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 6) {
                ForEach(["cinema", "vivid", "natural", "comfort"], id: \.self) { p in
                    Button(p.capitalized) { ctrl.applyPreset(p) }
                        .buttonStyle(.bordered)
                        .tint(ctrl.cfg.preset == p ? .orange : .gray)
                }
            }

            sliderRow("Peak Brightness", value: $ctrl.cfg.peakBoost, range: 1.0...12.0, step: 0.1, fmt: "%.1fx")
            sliderRow("Highlight Knee", value: $ctrl.cfg.threshold, range: 0.15...0.85, step: 0.01, fmt: "%.2f")
            sliderRow("Specular Punch", value: $ctrl.cfg.localPunch, range: 0.0...1.5, step: 0.02, fmt: "%.0f%%", scale: 100)
            sliderRow("Wide Gamut (P3)", value: $ctrl.cfg.gamutBoost, range: 0.0...1.0, step: 0.02, fmt: "%.0f%%", scale: 100)
            sliderRow("Shadow Depth", value: $ctrl.cfg.shadowDepth, range: 0.0...0.5, step: 0.01, fmt: "%.0f%%", scale: 100)
            sliderRow("White-Screen Guard", value: $ctrl.cfg.aplGuard, range: 0.0...1.0, step: 0.02, fmt: "%.0f%%", scale: 100)

            Divider()

            Toggle("Split Compare (SDR | EDR)", isOn: Binding(
                get: { ctrl.cfg.splitEnabled },
                set: { ctrl.cfg.splitEnabled = $0; ctrl.saveConfig() }
            ))
            if ctrl.cfg.splitEnabled {
                sliderRow("Wipe Position", value: $ctrl.cfg.splitPos, range: 0.05...0.95, step: 0.01, fmt: "%.0f%%", scale: 100)
            }
            Toggle("Auto-bypass native HDR games", isOn: Binding(
                get: { ctrl.cfg.bypassNativeHdr },
                set: { ctrl.cfg.bypassNativeHdr = $0; ctrl.saveConfig() }
            ))

            HStack {
                Text("⌥M Master • ⌥H HDR • ⌥U 4K • ⌥S Split • ⌥P Preset • ⌥↑↓ Peak")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button("Reset") { ctrl.reset() }.buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, fmt: String, scale: Double = 1.0) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: fmt, value.wrappedValue * scale)).font(.caption.monospacedDigit()).foregroundColor(.orange)
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; ctrl.cfg.preset = "custom"; ctrl.saveConfig() }
            ), in: range, step: step)
        }
    }
}

@main
struct TrueHDRGameApp: App {
    @StateObject private var ctrl = TrueHDRController()
    var body: some Scene {
        MenuBarExtra("TrueHDR", systemImage: "sun.max.fill") {
            ContentView(ctrl: ctrl)
        }
        .menuBarExtraStyle(.window)
        Window("TrueHDR Game", id: "main") {
            ContentView(ctrl: ctrl)
        }
        .windowResizability(.contentSize)
    }
}
