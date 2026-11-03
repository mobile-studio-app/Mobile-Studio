import Foundation

/// How much of a VS Code extension can work in DuoCode, decided from its package.json and the
/// platforms Open VSX publishes it for, before anything is downloaded.
///
/// DuoCode runs an extension's declarative parts (themes, grammars, snippets, language settings),
/// its browser code (the "browser" entry, in a Web Worker) and its Node.js code ("main", in
/// DuoCode's Node.js, where child processes that are Node.js scripts run as worker threads).
/// It can't run native modules, other programs, or desktop-only features like terminals, except
/// the macOS programs an extension ships in its darwin-arm64 build, which DuoCode signs with the
/// user's certificate and runs in the app (`macPrograms`, App/NativeTools).
/// For Node.js code, `nodeCode` (the extension's main file and the files it loads, when they
/// could be fetched) is checked for native modules and the programs it starts, and
/// `nativePackages` names the packages shipped with it that build native code.
struct ExtensionCompatibility: Equatable {
    enum Level: String, Codable {
        /// Everything the extension provides is supported.
        case full
        /// It installs, but some of it won't work (see `notes`).
        case partial
        /// Nothing useful would work; installing is blocked.
        case unsupported
    }

    let level: Level
    /// What works, and what doesn't and why, in plain words.
    let notes: [String]

    var canInstall: Bool { level != .unsupported }

    /// Contribution points DuoCode implements.
    static let supportedContributions: Set<String> = [
        "themes", "grammars", "snippets", "languages", "configuration", "configurationDefaults",
        "commands", "keybindings", "menus", "iconThemes",
        "views", "viewsContainers", "viewsWelcome", "customEditors", "taskDefinitions",
    ]

    /// Contribution points that only make sense in desktop VS Code; they're ignored.
    static let desktopOnlyContributions: [String: String] = [
        "debuggers": "debugging", "breakpoints": "debugging",
        "terminal": "terminal profiles", "problemMatchers": "task problem matchers",
        "notebooks": "notebooks", "notebookRenderer": "notebook renderers",
        "walkthroughs": "walkthroughs", "authentication": "sign-in providers",
        "localizations": "translations of VS Code", "remoteHelp": "remote development",
        "productIconThemes": "product icon themes", "chatParticipants": "Copilot Chat",
        "languageModelTools": "Copilot tools", "mcpServerDefinitionProviders": "MCP servers",
    ]

    /// `platforms`: the target platforms Open VSX has builds for ("universal", "web",
    /// "darwin-arm64", ...). Empty when unknown.
    /// Packages with native code; an extension that depends on one won't fully work.
    static let nativePackages: Set<String> = [
        "keytar", "node-pty", "sqlite3", "@vscode/sqlite3", "better-sqlite3", "fsevents", "@parcel/watcher",
        "cpu-features", "ssh2", "serialport", "usb", "node-hid", "robotjs", "sharp", "canvas", "native-keymap",
        "@vscode/windows-registry", "bufferutil", "utf-8-validate", "@vscode/spdlog", "node-addon-api", "nsfw",
        "chokidar-fsevents", "zeromq", "ffi-napi", "ref-napi", "node-sass", "@vscode/policy-watcher", "kerberos",
    ]

    /// Whether a package (its package.json) builds or downloads native code when it's installed.
    static func buildsNativeCode(_ package: [String: Any]) -> Bool {
        if package["gypfile"] as? Bool == true || package["binary"] != nil { return true }
        let scripts = package["scripts"] as? [String: Any] ?? [:]
        let install = ["preinstall", "install", "postinstall"].compactMap { scripts[$0] as? String }.joined(separator: " ")
        return ["node-gyp", "prebuild-install", "node-pre-gyp", "cmake-js", "node-gyp-build"].contains { install.contains($0) }
    }

    static let helperPrograms: Set<String> = [
        "taskkill", "taskkill.exe", "kill", "ps", "wmic", "wmic.exe", "cmd", "cmd.exe", "open", "xdg-open", "explorer",
        "explorer.exe", "start", "which", "where", "where.exe", "reg", "reg.exe", "powershell", "powershell.exe", "pgrep",
    ]

    /// What Node.js code needs that iOS can't give it: native modules, and programs it starts
    /// (other than Node.js scripts, which run as worker threads).
    static func scanNodeCode(_ code: String, manifest: [String: Any], nativeDependencies: [String] = []) -> (native: Bool, programs: [String]) {
        let dependencies = Set(((manifest["dependencies"] as? [String: Any]) ?? [:]).keys)
        var native = !dependencies.intersection(nativePackages).isEmpty || !nativeDependencies.isEmpty
        let nativePatterns = [#"\.node["'\)]"#, #"require\(\s*["']bindings["']\s*\)"#, #"node-gyp-build"#, #"node-pre-gyp"#, #"prebuild-install"#]
        if !native {
            native = nativePatterns.contains { code.range(of: $0, options: .regularExpression) != nil }
        }
        var programs = Set<String>()
        let spawnPattern = #"\b(?:spawn|spawnSync|execFile|execFileSync|exec|execSync)\(\s*["'`]([A-Za-z0-9_./-]+)"#
        let commandPattern = #"\bcommand\s*:\s*["']([A-Za-z0-9_./-]+)["']"#
        for pattern in [spawnPattern, commandPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                let program = (String(code[range]) as NSString).lastPathComponent
                // Node.js scripts run; extension commands ("ext.doThing") aren't programs.
                if ["node", "node.exe"].contains(program) || program.contains(".") && !program.hasSuffix(".exe") && !program.hasSuffix(".sh") { continue }
                // Platform helpers libraries call for housekeeping (vscode-languageclient's taskkill on
                // Windows, opening links), not features.
                if helperPrograms.contains(program.lowercased()) { continue }
                programs.insert(program)
            }
        }
        return (native, programs.sorted())
    }

    /// `macPrograms`: a signing certificate is imported, so a darwin-arm64 build's macOS
    /// programs can run.
    static func analyze(manifest: [String: Any], platforms: [String], nodeCode: String? = nil,
                        nativePackages: [String] = [], macPrograms: Bool = false) -> ExtensionCompatibility {
        var notes: [String] = []

        let portable = platforms.isEmpty || platforms.contains("universal") || platforms.contains("web")
        // Builds for each platform mean bundled programs (Claude Code's, Codex's), which iOS doesn't
        // load yet even when they're signed (`macPrograms` doesn't change that for now). They can
        // still be installed anyway, as an experiment.
        if !portable {
            return ExtensionCompatibility(level: .unsupported, notes: [
                platforms.contains("darwin-arm64")
                    ? "It comes with macOS programs, which iOS can't run yet. You can install it anyway as an experiment; the parts that need its programs won't work."
                    : "This extension includes native applications which cannot run on this device.",
            ])
        }

        let categories = (manifest["categories"] as? [String] ?? []).map { $0.lowercased() }
        if categories.contains("language packs") {
            return ExtensionCompatibility(level: .unsupported, notes: ["It translates VS Code's interface, which Mobile Studio doesn't use."])
        }

        let contributes = manifest["contributes"] as? [String: Any] ?? [:]
        let hasBrowserCode = (manifest["browser"] as? String).map { !$0.isEmpty } ?? false
        let hasNodeCode = (manifest["main"] as? String).map { !$0.isEmpty } ?? false
        let pack = manifest["extensionPack"] as? [String] ?? []

        // What adds something by itself (views and the like need the extension's code).
        let needsCode: Set<String> = ["commands", "menus", "keybindings", "views", "viewsContainers", "viewsWelcome", "customEditors", "taskDefinitions"]
        let useful = contributes.keys.filter { supportedContributions.contains($0) && !needsCode.contains($0) }
        let ignored = Set(contributes.keys.compactMap { desktopOnlyContributions[$0] }).sorted()

        if hasBrowserCode {
            notes.append("Its code runs in Mobile Studio as a web extension.")
        }
        var nodeLimited = false
        if !hasBrowserCode && hasNodeCode {
            if let nodeCode {
                let scan = scanNodeCode(nodeCode, manifest: manifest, nativeDependencies: nativePackages)
                if scan.native {
                    let named = nativePackages.isEmpty ? "" : " (\(nativePackages.prefix(4).joined(separator: ", ")))"
                    notes.append("It uses native modules\(named), which can't load on iOS; anything that needs them won't work.")
                    nodeLimited = true
                }
                if !scan.programs.isEmpty {
                    notes.append("It starts other programs (\(scan.programs.prefix(4).joined(separator: ", "))), which iOS can't run; anything that needs them won't work.")
                    nodeLimited = true
                }
                if !nodeLimited { notes.append("Its code runs in Mobile Studio's Node.js.") }
            } else {
                notes.append("Its code runs in Mobile Studio's Node.js. Anything that starts other programs or uses native modules won't work.")
                nodeLimited = true
            }
        }

        if !useful.isEmpty {
            notes.append("Adds \(describe(useful)).")
        }
        if !pack.isEmpty {
            notes.append("It's a pack of \(pack.count) extension\(pack.count == 1 ? "" : "s"); each is checked when it's installed.")
        }
        if !ignored.isEmpty {
            notes.append("Not available in Mobile Studio: \(ignored.joined(separator: ", ")).")
        }
        if useful.isEmpty && !hasBrowserCode && !hasNodeCode && pack.isEmpty {
            return ExtensionCompatibility(level: .unsupported, notes: notes + ["It doesn't contribute anything Mobile Studio supports."])
        }

        let level: Level = nodeLimited || !ignored.isEmpty ? .partial : .full
        return ExtensionCompatibility(level: level, notes: notes)
    }

    private static func describe(_ contributions: [String]) -> String {
        let names: [String: String] = [
            "themes": "colour themes", "iconThemes": "file icon themes", "grammars": "syntax highlighting",
            "snippets": "snippets", "languages": "language settings", "configuration": "settings",
            "configurationDefaults": "default settings", "jsonValidation": "JSON schemas",
        ]
        let words = Array(Set(contributions.compactMap { names[$0] })).sorted()
        switch words.count {
        case 0: return "contributions"
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words.last!
        }
    }
}
