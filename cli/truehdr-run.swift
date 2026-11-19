import Foundation

func findDylib() -> String {
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let dir = execURL.deletingLastPathComponent()
    let candidates = [
        dir.appendingPathComponent("libTrueHDR.dylib").path,
        dir.appendingPathComponent("../lib/libTrueHDR.dylib").path,
        dir.deletingLastPathComponent().appendingPathComponent("build/libTrueHDR.dylib").path,
        "/usr/local/lib/libTrueHDR.dylib"
    ]
    for c in candidates where FileManager.default.fileExists(atPath: c) {
        return c
    }
    fputs("error: could not locate libTrueHDR.dylib\n", stderr)
    exit(1)
}

func resolveAppExecutable(_ appPath: String) -> String? {
    let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let exe = dict["CFBundleExecutable"] as? String else { return nil }
    return URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/\(exe)").path
}

func hasBlockingHardenedRuntime(_ binaryPath: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["-dv", binaryPath]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    let info = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard info.contains("flags=") && info.contains("(runtime)") else { return false }

    let e = Process()
    e.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    e.arguments = ["-d", "--entitlements", "-", "--xml", binaryPath]
    let outPipe = Pipe()
    e.standardOutput = outPipe
    e.standardError = Pipe()
    guard (try? e.run()) != nil else { return true }
    e.waitUntilExit()
    let ent = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if ent.contains("com.apple.security.cs.disable-library-validation") {
        return false
    }
    return true
}

func usage() -> Never {
    let msg = """
    Usage: truehdr-run [options] <App.app | executable> [args...]

    Options:
      --preset <vivid|natural|cinema|comfort>
      --peak <1.0..12.0>
      --split                  Start with split compare enabled
      --no-hdr                 Start with HDR disabled (passthrough)
      --dylib <path>           Override path to libTrueHDR.dylib

    Examples:
      truehdr-run /Applications/Game.app
      truehdr-run wine64 /path/to/game.exe
      truehdr-run --preset cinema --peak 8.0 /path/to/native-game
    """
    fputs(msg + "\n", stderr)
    exit(64)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty { usage() }

var env = ProcessInfo.processInfo.environment
var dylibPath: String? = nil

while let first = args.first, first.hasPrefix("-") {
    args.removeFirst()
    switch first {
    case "--help", "-h":
        usage()
    case "--preset":
        guard !args.isEmpty else { usage() }
        env["TRUEHDR_PRESET"] = args.removeFirst()
    case "--peak":
        guard !args.isEmpty else { usage() }
        env["TRUEHDR_PEAK"] = args.removeFirst()
    case "--split":
        env["TRUEHDR_SPLIT"] = "1"
    case "--no-hdr":
        env["TRUEHDR_HDR"] = "0"
    case "--dylib":
        guard !args.isEmpty else { usage() }
        dylibPath = args.removeFirst()
    default:
        fputs("unknown option: \(first)\n", stderr)
        usage()
    }
}

guard let targetArg = args.first else { usage() }
let gameArgs = Array(args.dropFirst())

let resolvedBin: String
if targetArg.hasSuffix(".app") || targetArg.hasSuffix(".app/") {
    let trimmed = targetArg.hasSuffix("/") ? String(targetArg.dropLast()) : targetArg
    guard let exe = resolveAppExecutable(trimmed) else {
        fputs("error: failed to find CFBundleExecutable in \(trimmed)\n", stderr)
        exit(1)
    }
    resolvedBin = exe
} else if targetArg.contains("/") {
    resolvedBin = targetArg
} else {
    // Search PATH for commands like `wine64`
    let pathDirs = (env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init)
    if let hit = pathDirs.map({ "\($0)/\(targetArg)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        resolvedBin = hit
    } else {
        resolvedBin = targetArg
    }
}

func isShebangOrShell(_ path: String) -> Bool {
    let base = (path as NSString).lastPathComponent
    if ["sh", "bash", "zsh", "dash", "env", "run"].contains(base) {
        return true
    }
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    let head = fh.readData(ofLength: 2)
    return head.count == 2 && head[0] == 0x23 && head[1] == 0x21 // "#!"
}

let dylib = dylibPath ?? findDylib()
if hasBlockingHardenedRuntime(resolvedBin) {
    fputs("warning: \(resolvedBin) has Hardened Runtime without disable-library-validation; macOS dyld may block DYLD_INSERT_LIBRARIES.\n", stderr)
}

if !isShebangOrShell(resolvedBin) {
    if let prev = env["DYLD_INSERT_LIBRARIES"], !prev.isEmpty {
        env["DYLD_INSERT_LIBRARIES"] = "\(dylib):\(prev)"
    } else {
        env["DYLD_INSERT_LIBRARIES"] = dylib
    }
}

// Preserve/append to STEAM_DYLD_INSERT_LIBRARIES so Steam/NotProton compatibility runners
// (which run via arm64e /bin/sh and forward STEAM_DYLD_INSERT_LIBRARIES to Wine/FEX)
// still load libTrueHDR.dylib into the game process without crashing /bin/sh.
if let prevSteam = env["STEAM_DYLD_INSERT_LIBRARIES"], !prevSteam.isEmpty {
    if !prevSteam.split(separator: ":").contains(Substring(dylib)) {
        env["STEAM_DYLD_INSERT_LIBRARIES"] = "\(prevSteam):\(dylib)"
    }
} else {
    env["STEAM_DYLD_INSERT_LIBRARIES"] = dylib
}

// Replace this process directly via execve so signals/Dock lifecycle belong to the game itself.
let argvStrings = [resolvedBin] + gameArgs
var cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
cArgv.append(nil)

let envStrings = env.map { "\($0.key)=\($0.value)" }
var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
cEnv.append(nil)

execve(resolvedBin, &cArgv, &cEnv)
perror("truehdr-run execve")
exit(1)
