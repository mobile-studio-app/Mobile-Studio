import Foundation

/// A breakpoint: a line, optionally with a condition (stop only when it's true) or a log
/// message (a logpoint: print it and carry on). `{expression}` in a log message is evaluated.
struct Breakpoint: Codable, Equatable {
    var line: Int
    var condition: String?
    var logMessage: String?
    var enabled: Bool = true

    var json: [String: Any] {
        var out: [String: Any] = ["line": line]
        if let condition, !condition.isEmpty { out["condition"] = condition }
        if let logMessage, !logMessage.isEmpty { out["logMessage"] = logMessage }
        return out
    }
}

/// The open project's breakpoints, kept in .duocode/breakpoints.json.
final class BreakpointStore {
    static let shared = BreakpointStore()
    /// Posted on the main queue when breakpoints change.
    static let didChange = Notification.Name("DuoCodeBreakpointsDidChange")

    private(set) var byFile: [String: [Breakpoint]] = [:]
    /// Stop when the program hits an error it doesn't handle (VS Code's "Uncaught Exceptions").
    var stopOnErrors = true { didSet { save() } }
    private var project: URL?

    private struct Stored: Codable {
        var breakpoints: [String: [Breakpoint]]
        var stopOnErrors: Bool?
    }

    private func fileURL(_ project: URL) -> URL {
        project.appendingPathComponent(".duocode/breakpoints.json")
    }

    /// Reloads when the project changed.
    private func ensureLoaded() {
        let current = ProjectStore.shared.currentProject
        guard current != project else { return }
        project = current
        if let data = try? Data(contentsOf: fileURL(current)), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            byFile = stored.breakpoints
            stopOnErrors = stored.stopOnErrors ?? true
        } else {
            byFile = [:]
        }
    }

    private func save() {
        guard let project else { return }
        let url = fileURL(project)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(breakpoints: byFile.filter { !$0.value.isEmpty }, stopOnErrors: stopOnErrors)) {
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    var all: [(file: String, breakpoint: Breakpoint)] {
        ensureLoaded()
        return byFile.keys.sorted().flatMap { file in byFile[file]!.sorted { $0.line < $1.line }.map { (file, $0) } }
    }

    func breakpoints(in file: String) -> [Breakpoint] {
        ensureLoaded()
        return byFile[file] ?? []
    }

    /// The editor's breakpoints for a file (after a toggle, or lines moving as the file is edited).
    func set(_ list: [Breakpoint], in file: String) {
        ensureLoaded()
        let sorted = list.sorted { $0.line < $1.line }
        guard byFile[file] ?? [] != sorted else { return }
        byFile[file] = sorted
        save()
    }

    func update(_ breakpoint: Breakpoint, in file: String) {
        ensureLoaded()
        var list = byFile[file] ?? []
        if let i = list.firstIndex(where: { $0.line == breakpoint.line }) { list[i] = breakpoint } else { list.append(breakpoint) }
        set(list, in: file)
    }

    func remove(line: Int, in file: String) {
        ensureLoaded()
        set((byFile[file] ?? []).filter { $0.line != line }, in: file)
    }

    /// Breakpoints follow a renamed file or folder (`to` nil: it was deleted).
    func move(_ from: String, to: String?) {
        ensureLoaded()
        var changed = false
        for file in byFile.keys where file == from || file.hasPrefix(from + "/") {
            let list = byFile.removeValue(forKey: file)
            if let to, let list { byFile[to + file.dropFirst(from.count)] = list }
            changed = true
        }
        if changed { save() }
    }

    func removeAll() {
        ensureLoaded()
        byFile = [:]
        save()
    }

    func setAllEnabled(_ enabled: Bool) {
        ensureLoaded()
        byFile = byFile.mapValues { $0.map { var b = $0; b.enabled = enabled; return b } }
        save()
    }

    /// Enabled breakpoints in the protocol's shape: { file: [{ line, condition, logMessage }] }.
    var protocolBreakpoints: [String: Any] {
        ensureLoaded()
        var out: [String: Any] = [:]
        for (file, list) in byFile {
            let enabled = list.filter(\.enabled).map(\.json)
            if !enabled.isEmpty { out[file] = enabled }
        }
        return out
    }

    /// dc_run_options.debug_config for a debugged run.
    var debugConfig: String {
        let config: [String: Any] = ["breakpoints": protocolBreakpoints, "stopOnErrors": stopOnErrors]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A debugging session with a running program, over the runtime's debug channel (see
/// Runtimes/common/DebugChannel.h): run control, the paused program's call stack, variables,
/// watch expressions and the debug console.
final class DebugSession {
    static let shared = DebugSession()
    /// Posted on the main queue when the session starts, stops, pauses or continues.
    static let didChange = Notification.Name("DuoCodeDebugSessionDidChange")

    enum State { case inactive, running, paused }

    struct Frame {
        let id: Int
        let name: String
        let file: String
        let line: Int
    }

    struct Variable {
        let name: String
        let value: String
        let type: String
        let ref: Int?
    }

    private(set) var state: State = .inactive
    private(set) var frames: [Frame] = []
    private(set) var stopReason = ""
    private(set) var stopText: String?
    /// The frame whose variables show, and where the debug console evaluates.
    var selectedFrame = 1 {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
    /// Watch expressions, kept across sessions.
    var watches: [String] {
        get { UserDefaults.standard.stringArray(forKey: "debug.watches") ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "debug.watches")
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Sends a command (JSON) to the runtime.
    var transport: ((String) -> Void)?
    /// Logpoint output and debug console results, for the console.
    var onOutput: ((String) -> Void)?
    /// The program stopped at a place in the code; the IDE shows it.
    var onStopped: ((Frame?) -> Void)?
    var onContinued: (() -> Void)?

    private var nextId = 1
    private var pending: [Int: (Any?, String?) -> Void] = [:]
    private var breakpointObserver: NSObjectProtocol?

    var isActive: Bool { state != .inactive }

    func begin() {
        state = .running
        frames = []
        pending = [:]
        breakpointObserver = NotificationCenter.default.addObserver(forName: BreakpointStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.sendBreakpoints()
        }
        changed()
    }

    func end() {
        guard state != .inactive else { return }
        state = .inactive
        frames = []
        for (_, completion) in pending { completion(nil, "The program ended.") }
        pending = [:]
        if let breakpointObserver { NotificationCenter.default.removeObserver(breakpointObserver) }
        breakpointObserver = nil
        onContinued?()
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Events from the runtime

    func handle(event json: String) {
        guard let data = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = message["response"] as? Int {
            let completion = pending.removeValue(forKey: id)
            completion?(message["body"], message["error"] as? String)
            return
        }
        switch message["event"] as? String {
        case "stopped":
            frames = (message["frames"] as? [[String: Any]] ?? []).compactMap { f in
                guard let id = f["id"] as? Int, let file = f["file"] as? String else { return nil }
                return Frame(id: id, name: f["name"] as? String ?? "?", file: file, line: f["line"] as? Int ?? 0)
            }
            stopReason = message["reason"] as? String ?? "pause"
            stopText = message["text"] as? String
            state = .paused
            selectedFrame = frames.first?.id ?? 1
            onStopped?(frames.first)
            changed()
        case "continued":
            state = .running
            frames = []
            onContinued?()
            changed()
        case "output":
            if let text = message["text"] as? String { onOutput?(text) }
        default:
            break
        }
    }

    // MARK: - Commands

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        transport?(String(decoding: data, as: UTF8.self))
    }

    private func request(_ command: String, _ arguments: [String: Any] = [:], completion: @escaping (Any?, String?) -> Void) {
        guard state == .paused || command == "setBreakpoints" else { completion(nil, "The program isn't paused."); return }
        let id = nextId
        nextId += 1
        pending[id] = completion
        var message = arguments
        message["command"] = command
        message["id"] = id
        send(message)
    }

    func resume() { send(["command": "continue"]) }
    func stepOver() { send(["command": "next"]) }
    func stepInto() { send(["command": "stepIn"]) }
    func stepOut() { send(["command": "stepOut"]) }
    func pause() { send(["command": "pause"]) }

    private func sendBreakpoints() {
        guard state != .inactive else { return }
        send(["command": "setBreakpoints", "breakpoints": BreakpointStore.shared.protocolBreakpoints,
              "stopOnErrors": BreakpointStore.shared.stopOnErrors])
    }

    /// Scopes of the selected frame (Locals, Upvalues, Globals) as expandable variables.
    func scopes(completion: @escaping ([Variable]) -> Void) {
        request("scopes", ["frame": selectedFrame]) { body, _ in
            let list = (body as? [[String: Any]] ?? []).map {
                Variable(name: $0["name"] as? String ?? "", value: "", type: "scope", ref: $0["ref"] as? Int)
            }
            completion(list)
        }
    }

    func variables(_ ref: Int, completion: @escaping ([Variable]) -> Void) {
        request("variables", ["ref": ref]) { body, _ in
            completion((body as? [[String: Any]] ?? []).map(Self.variable))
        }
    }

    /// Evaluates in the selected frame. `context` is "watch", "hover" or "repl" (the debug console).
    func evaluate(_ expression: String, context: String, completion: @escaping (Variable?, String?) -> Void) {
        request("evaluate", ["expression": expression, "frame": selectedFrame, "context": context]) { body, error in
            if let error { completion(nil, error); return }
            guard let body = body as? [String: Any] else { completion(nil, "No value"); return }
            completion(Self.variable(body.merging(["name": expression]) { a, _ in a }), nil)
        }
    }

    private static func variable(_ json: [String: Any]) -> Variable {
        Variable(name: json["name"] as? String ?? "", value: json["value"] as? String ?? "",
                 type: json["type"] as? String ?? "", ref: json["ref"] as? Int)
    }
}
