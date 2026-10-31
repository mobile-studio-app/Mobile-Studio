import Foundation

/// Metadata read from a runtime framework's `runtime.json`.
struct RuntimeManifest: Decodable {
    let id: String
    let displayName: String
    let abi: Int
    let language: String?
    /// Files whose presence in a project suggests this runtime (e.g. "main.lua").
    let detect: [String]?
    let priority: Int?
    /// "game" draws in the game pane; "console" prints to the console and reads its input.
    let kind: String?
    /// false for a runtime that's listed but not bundled yet.
    let available: Bool?
}

/// A discovered (not necessarily loaded) runtime framework.
final class RuntimeDescriptor {
    let manifest: RuntimeManifest
    let frameworkURL: URL
    private(set) var vtable: UnsafePointer<dc_runtime>?
    private var handle: UnsafeMutableRawPointer?

    init(manifest: RuntimeManifest, frameworkURL: URL) {
        self.manifest = manifest
        self.frameworkURL = frameworkURL
    }

    var isLoaded: Bool { vtable != nil }
    var isConsole: Bool { manifest.kind == "console" }
    var isAvailable: Bool { manifest.available ?? true }
    /// Shown in the interpreter pickers (the demo runtime is for testing only).
    var isSelectable: Bool { manifest.kind == "game" || manifest.kind == "console" }

    /// dlopen the framework with RTLD_LOCAL and resolve the single entry symbol.
    func load() throws -> UnsafePointer<dc_runtime> {
        if let vtable { return vtable }
        guard let bundle = Bundle(url: frameworkURL), let exe = bundle.executableURL else {
            throw RuntimeError.loadFailed("No executable in \(frameworkURL.lastPathComponent)")
        }
        guard let h = dlopen(exe.path, RTLD_NOW | RTLD_LOCAL) else {
            throw RuntimeError.loadFailed(String(cString: dlerror()))
        }
        guard let sym = dlsym(h, "duocode_runtime_entry") else {
            throw RuntimeError.loadFailed("Missing duocode_runtime_entry in \(manifest.id)")
        }
        let entry = unsafeBitCast(sym, to: dc_runtime_entry_fn.self)
        guard let vt = entry() else { throw RuntimeError.loadFailed("Entry returned NULL") }
        guard vt.pointee.abi_version == UInt32(DC_RUNTIME_ABI_VERSION) else {
            throw RuntimeError.loadFailed("ABI mismatch: runtime \(vt.pointee.abi_version), host \(DC_RUNTIME_ABI_VERSION)")
        }
        handle = h
        vtable = vt
        return vt
    }
}

enum RuntimeError: LocalizedError {
    case loadFailed(String)
    case initFailed(Int32)
    case busy
    case notFound(String)
    case cannotDebug

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): return "Runtime load failed: \(m)"
        case .initFailed(let c): return "Runtime init failed (code \(c))"
        case .busy: return "A game is already running"
        case .cannotDebug: return "This interpreter can't be debugged yet"
        case .notFound(let id): return "Runtime '\(id)' not found"
        }
    }
}

/// Discovers runtime frameworks in the app bundle (`Frameworks/*.framework`
/// containing a `runtime.json`) and picks one per project.
final class RuntimeManager {
    static let shared = RuntimeManager()
    private(set) var runtimes: [RuntimeDescriptor] = []

    func discover() {
        runtimes.removeAll()
        guard let dir = Bundle.main.privateFrameworksURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for fw in items where fw.pathExtension == "framework" {
            let manifestURL = Bundle(url: fw)?.url(forResource: "runtime", withExtension: "json")
                ?? fw.appendingPathComponent("runtime.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { continue }
            runtimes.append(RuntimeDescriptor(manifest: manifest, frameworkURL: fw))
        }
        runtimes.sort { ($0.manifest.priority ?? 0) > ($1.manifest.priority ?? 0) }
    }

    /// The interpreters a project can use, in the order the pickers show them.
    var selectableRuntimes: [RuntimeDescriptor] {
        let order = ["love-12.0", "love-11.5", "lua-5.4", "python-3", "node"]
        func rank(_ id: String) -> Int { order.firstIndex { id.hasPrefix($0) } ?? order.count }
        return runtimes.filter(\.isSelectable).sorted { rank($0.manifest.id) < rank($1.manifest.id) }
    }

    private func settingsURL(for project: URL) -> URL {
        project.appendingPathComponent(".duocode/settings.json")
    }

    /// The interpreter chosen for the project, if one was (otherwise it's detected from its files).
    func chosenRuntimeID(for project: URL) -> String? {
        guard let data = try? Data(contentsOf: settingsURL(for: project)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["runtime"] as? String
    }

    /// Picks the interpreter for a project (nil goes back to detecting it), keeping other settings.
    func setRuntime(_ id: String?, for project: URL) throws {
        let url = settingsURL(for: project)
        var object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        object["runtime"] = id
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    func runtime(id: String) -> RuntimeDescriptor? {
        runtimes.first { $0.manifest.id == id }
    }

    /// Resolution order: `.duocode/settings.json` "runtime" key → manifest detection → first.
    func resolve(for project: URL) -> RuntimeDescriptor? {
        // 1. Explicit project setting
        let settings = project.appendingPathComponent(".duocode/settings.json")
        if let data = try? Data(contentsOf: settings),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["runtime"] as? String, let rt = runtime(id: id) {
            return rt
        }

        // 2. Check conf.lua for t.version = "11.5" or "12.0"
        let confURL = project.appendingPathComponent("conf.lua")
        if let confStr = try? String(contentsOf: confURL, encoding: .utf8) {
            if confStr.contains("\"11.5\"") || confStr.contains("'11.5'") {
                // Until LÖVE 11.5 is bundled, 11.5 games run on 12.0, which runs most of them.
                if let rt = runtime(id: "love-11.5"), rt.isAvailable { return rt }
                if let rt = runtime(id: "love-12.0") { return rt }
            } else if confStr.contains("\"12.0\"") || confStr.contains("'12.0'") {
                if let rt = runtime(id: "love-12.0") { return rt }
            }
        }
        let fm = FileManager.default
        for rt in runtimes {
            if rt.isAvailable, let detect = rt.manifest.detect, !detect.isEmpty,
               detect.allSatisfy({ fm.fileExists(atPath: project.appendingPathComponent($0).path) }) {
                return rt
            }
        }
        return runtimes.first
    }

    /// Parses conf.lua to determine fixed internal resolution and resizable settings.
    func parseWindowConfig(for project: URL) -> LoveWindowConfig {
        let confURL = project.appendingPathComponent("conf.lua")
        var w: CGFloat = 800
        var h: CGFloat = 600
        var resizable = false

        if let conf = try? String(contentsOf: confURL, encoding: .utf8) {
            if let match = conf.range(of: #"t\.window\.width\s*=\s*(\d+)"#, options: .regularExpression) {
                let digits = conf[match].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if let val = Double(digits), val > 0 { w = CGFloat(val) }
            }
            if let match = conf.range(of: #"t\.window\.height\s*=\s*(\d+)"#, options: .regularExpression) {
                let digits = conf[match].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if let val = Double(digits), val > 0 { h = CGFloat(val) }
            }
            if let match = conf.range(of: #"t\.window\.resizable\s*=\s*(true|false)"#, options: .regularExpression) {
                if conf[match].contains("true") { resizable = true }
            }
        }
        return LoveWindowConfig(width: w, height: h, resizable: resizable)
    }
}
