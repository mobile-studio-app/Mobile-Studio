import UIKit
import WebKit

/// The code editor: a WKWebView hosting `editor.html` and `editor.bundle.js` (CodeMirror 6,
/// built from `Editor/`). The page talks to the app through the "duocode" message handler.
final class EditorWebView: NSObject, WKScriptMessageHandlerWithReply {
    let webView: WKWebView
    var onCommand: ((String, [String: Any]) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        // Extensions' webviews load their files from duocode-res:// URLs; the page knows it can
        // leave those links as they are rather than inlining the files.
        config.setURLSchemeHandler(ExtensionResourceSchemeHandler(), forURLScheme: ExtensionResourceSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: "window.__duocodeResources = true;",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = EditorWKWebView(frame: .zero, configuration: config)
        super.init()
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "duocode")
        #if DEBUG
        webView.isInspectable = true   // Safari Web Inspector from a Mac, if available
        #endif
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        if let url = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "Editor")
            ?? Bundle.main.url(forResource: "editor", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // Settings changes and finished model downloads reach the open editor straight away.
        for name in [AppSettings.didChange, ModelDownloadManager.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(pushSettings), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsChanged), name: ExtensionManager.didChange, object: nil)
        NotificationCenter.default.addObserver(forName: FileIconTheme.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.emit("fileIconsChanged", [:])
        }
        NotificationCenter.default.addObserver(self, selector: #selector(breakpointsChanged), name: BreakpointStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gitIndexChanged), name: GitRepository.didChange, object: nil)
        // Back from the background: the Node.js host's connection may need mending.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.emit("appForeground", [:])
        }
        NotificationCenter.default.addObserver(self, selector: #selector(extensionConfigurationChanged),
                                               name: ExtensionHostBridge.didChangeConfiguration, object: nil)
    }

    @objc private func extensionConfigurationChanged() {
        emit("extensionConfiguration", UserSettingsFiles.effectiveConfiguration(in: ProjectStore.shared.currentProject))
        // Some editor settings (the minimap, sticky scroll, inlay hints) are only in settings.json.
        pushSettings()
    }

    /// The editor's settings, with the project's .vscode/settings.json on top.
    private var settingsPayload: [String: Any] {
        AppSettings.shared.editorPayload(aiReady: AICompletionService.shared.isReady,
                                         aiMergeReady: AICompletionService.shared.isMergeReady)
            .merging(UserSettingsFiles.editorOverrides(in: ProjectStore.shared.currentProject)) { _, project in project }
    }

    private var lastPushedSettings: NSDictionary?

    @objc private func gitIndexChanged() {
        emit("gitChanged", [:])
    }

    private var ignoreBreakpointEcho = false

    /// Breakpoints changed outside the editor (the Run and Debug view): show them in the open file.
    @objc private func breakpointsChanged() {
        guard !ignoreBreakpointEcho else { return }
        emit("breakpoints", [:])   // the editor asks again for the open file's
    }

    /// Where the debugged program is paused (nil: running or ended).
    func showDebugLocation(file: String?, line: Int) {
        if let file {
            emit("debugLocation", ["path": file, "line": line])
        } else {
            emit("debugLocation", [:])
        }
    }

    func setDebugPaused(_ paused: Bool) {
        emit("debugState", ["paused": paused])
    }

    @objc private func extensionsChanged() {
        emit("extensionsChanged", [:])
    }

    @objc private func pushSettings() {
        // Download progress posts often; only tell the page when something it uses changed.
        let payload = settingsPayload as NSDictionary
        guard payload != lastPushedSettings else { return }
        lastPushedSettings = payload
        emit("settings", payload)
    }

    /// Push an event to the page: window.duocode.onEvent(name, payload)
    func emit(_ name: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["name": name, "payload": payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.duocode && window.duocode.onEvent(\(json))")
    }

    /// A file or folder was renamed (`to`) or deleted (`to` nil): open tabs follow it.
    func pathMoved(_ from: String, to: String?) {
        emit("pathMoved", ["from": from, "to": (to as Any?) ?? NSNull()])
    }

    /// Another project opened: its files replace the open tabs.
    func projectChanged() {
        emit("projectChanged", [:])
    }

    /// VS Code's Quick Open (⌘P).
    func showQuickOpen() {
        emit("quickOpen", [:])
    }

    func openFile(_ path: String) {
        emit("openFile", ["path": path])
    }

    /// Opens a file in the split editor, beside the main one.
    func openFileToSide(_ path: String) {
        emit("openFileToSide", ["path": path])
    }

    /// Runs an async function body on the page with `arguments` as its parameters.
    func call(_ body: String, _ arguments: [String: Any], completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case let .success(value) = result { completion(value) } else { completion(nil) }
        }
    }

    func jumpToLine(file: String, line: Int) {
        emit("jumpToLine", ["file": file, "line": line])
    }

    /// Opens a file with a range selected (a search result). Column and length are UTF-16, as in JavaScript.
    func reveal(file: String, line: Int, column: Int, length: Int) {
        emit("reveal", ["file": file, "line": line, "column": column, "length": length])
    }

    /// Shows an inline diff. Without `modified` the working file opens editable against `original`.
    func openDiff(_ request: DiffRequest) {
        var payload: [String: Any] = ["path": request.path, "original": request.original, "title": request.title]
        if let modified = request.modified { payload["modified"] = modified }
        emit("openDiff", payload)
    }

    /// The bar above the keyboard, in place of WebKit's form bar.
    let keyBar = EditorKeyBar()

    func installKeyBar() {
        keyBar.onKey = { [weak self] name in
            if name == "dismiss" { self?.webView.endEditing(true) }
            self?.emit("key", ["name": name])
        }
        webView.useKeyboardAccessory(keyBar)
    }

    /// VS Code's Command Palette, over the editor.
    func showCommandPalette() {
        emit("commandPalette", [:])
    }

    func saveAll() {
        emit("saveAll", [:])
    }

    /// Re-reads the open file after a pull or discard changed it on disk.
    func reloadFromDisk() {
        emit("reload", [:])
    }

    /// Writes any unsaved edits, then calls `completion` once they're on disk.
    /// Use before running the game or switching projects.
    func flushSaves(completion: @escaping () -> Void) {
        webView.callAsyncJavaScript("if (window.duocode && window.duocode.flush) { await window.duocode.flush(); }",
                                    arguments: [:], in: nil, in: .page) { _ in
            completion()
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        let store = ProjectStore.shared
        do {
            switch cmd {
            case "list":
                replyHandler(store.list(), nil)
            case "read":
                let path = body["path"] as? String ?? ""
                // @user/settings.json and @user/keybindings.json (UserSettingsFiles).
                replyHandler(UserSettingsFiles.isUserPath(path) ? try UserSettingsFiles.read(path) : try store.read(path), nil)
            case "readBinary":
                // For the image/audio/font viewer: base64 plus size, capped to keep the bridge responsive.
                let url = try store.resolve(body["path"] as? String ?? "")
                let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 32 * 1024 * 1024 else {
                    replyHandler(["size": size, "tooLarge": true], nil); return
                }
                let data = try Data(contentsOf: url)
                replyHandler(["size": data.count, "base64": data.base64EncodedString()], nil)
            case "openURL":
                // Links from the docs sheet open in Safari rather than navigating the editor away.
                if let url = URL(string: body["url"] as? String ?? ""), ["http", "https"].contains(url.scheme) {
                    UIApplication.shared.open(url)
                }
                replyHandler(true, nil)
            case "stat":
                let path = body["path"] as? String ?? ""
                if UserSettingsFiles.isUserPath(path) { replyHandler(["size": try UserSettingsFiles.read(path).utf8.count], nil); return }
                let url = try store.resolve(path)
                replyHandler(["size": (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0], nil)
            case "getSettings":
                replyHandler(settingsPayload, nil)
            case "aiComplete":
                AICompletionService.shared.complete(prefix: body["prefix"] as? String ?? "",
                                                    suffix: body["suffix"] as? String ?? "",
                                                    path: body["path"] as? String ?? "") { text in
                    replyHandler(text, nil)
                }
            case "aiResolve":
                let request = ConflictRequest(path: body["path"] as? String ?? "",
                                              ours: body["ours"] as? String ?? "",
                                              theirs: body["theirs"] as? String ?? "",
                                              base: body["base"] as? String,
                                              before: body["before"] as? String ?? "",
                                              after: body["after"] as? String ?? "",
                                              oursLabel: body["oursLabel"] as? String ?? "HEAD",
                                              theirsLabel: body["theirsLabel"] as? String ?? "incoming")
                AICompletionService.shared.resolveConflict(request) { text in
                    replyHandler(text, nil)
                }
            case "aiResolveCancel":
                // The review sheet closed: stop, and swap the suggestions model back in if the merge used another.
                AICompletionService.shared.endResolveSession()
                replyHandler(true, nil)
            case "conflictInfo":
                // Whether the file is one of the merge's unresolved files (it gets "Mark as Resolved").
                // With what's being done and the two sides' names, for the merge bar.
                let path = body["path"] as? String ?? ""
                guard let repo = try? GitRepository.open(store.currentProject), repo.conflicts().contains(path) else {
                    replyHandler(["inMerge": false], nil); return
                }
                let (operation, ours, theirs) = repo.conflictLabels()
                replyHandler(["inMerge": true, "operation": operation, "oursLabel": ours, "theirsLabel": theirs], nil)
            case "conflictVersions":
                // A conflicted file's base, current and incoming versions, from the index.
                let path = body["path"] as? String ?? ""
                guard let conflict = (try? GitRepository.open(store.currentProject))?.conflict(path) else { replyHandler(NSNull(), nil); return }
                replyHandler(["base": (conflict.base as Any?) ?? NSNull(), "ours": (conflict.ours as Any?) ?? NSNull(),
                              "theirs": (conflict.theirs as Any?) ?? NSNull()], nil)
            case "markResolved":
                try GitRepository.open(store.currentProject).stage([body["path"] as? String ?? ""])
                NotificationCenter.default.post(name: ProjectStore.filesDidChange, object: store)
                replyHandler(true, nil)
            case "extList":
                replyHandler(ExtensionManager.shared.editorPayload(), nil)
            case "extRead":
                // A file from an installed extension: text, or base64 with "binary".
                let id = body["id"] as? String ?? ""
                guard let data = ExtensionManager.shared.readFile(id, path: body["path"] as? String ?? "") else {
                    replyHandler(nil, "Not found"); return
                }
                if body["binary"] as? Bool == true {
                    replyHandler(data.base64EncodedString(), nil)
                } else {
                    replyHandler(String(decoding: data, as: UTF8.self), nil)
                }
            case "themeColors":
                ThemeColors.apply(body["colors"] as? [String: Any] ?? [:], dark: body["dark"] as? Bool ?? true)
                replyHandler(true, nil)
            case "setTheme":
                // Preferences: Color Theme in the Command Palette.
                if let id = body["id"] as? String { AppSettings.shared.editorTheme = id }
                replyHandler(true, nil)
            case "gitOriginal":
                // The staged (or committed) copy of a file, for the editor's change markers. nil when
                // the project isn't a repository or the file isn't tracked.
                let path = body["path"] as? String ?? ""
                let project = store.currentProject
                guard let repo = try? GitRepository.open(project) else { replyHandler(NSNull(), nil); return }
                replyHandler((repo.text(of: path, at: .index) as Any?) ?? NSNull(), nil)
            case "getBreakpoints":
                let file = body["path"] as? String ?? ""
                replyHandler(BreakpointStore.shared.breakpoints(in: file).map { bp -> [String: Any] in
                    var out = bp.json
                    out["enabled"] = bp.enabled
                    return out
                }, nil)
            case "setBreakpoints":
                // From the editor's gutter: keeps each line's condition and log message.
                let file = body["path"] as? String ?? ""
                let list = (body["breakpoints"] as? [[String: Any]] ?? []).compactMap { entry -> Breakpoint? in
                    guard let line = entry["line"] as? Int else { return nil }
                    return Breakpoint(line: line, condition: entry["condition"] as? String,
                                      logMessage: entry["logMessage"] as? String, enabled: entry["enabled"] as? Bool ?? true)
                }
                ignoreBreakpointEcho = true
                BreakpointStore.shared.set(list, in: file)
                ignoreBreakpointEcho = false
                replyHandler(true, nil)
            case "debugInlineValues":
                // The paused frame's locals (and upvalues), for values shown at the ends of lines.
                let session = DebugSession.shared
                session.scopes { scopes in
                    let wanted = scopes.filter { ["Locals", "Upvalues", "Closure", "Block"].contains($0.name) }.compactMap(\.ref)
                    guard !wanted.isEmpty else { replyHandler([], nil); return }
                    var values: [[String: Any]] = []
                    var remaining = wanted.count
                    for ref in wanted {
                        session.variables(ref) { list in
                            values += list.map { ["name": $0.name, "value": $0.value] }
                            remaining -= 1
                            if remaining == 0 { replyHandler(values, nil) }
                        }
                    }
                }
            case "debugEvaluate":
                // "hover" can't change the program (side effects are refused); the Debug Console's "repl" can.
                let context = body["context"] as? String == "repl" ? "repl" : "hover"
                DebugSession.shared.evaluate(body["expression"] as? String ?? "", context: context) { value, error in
                    if let value {
                        replyHandler(["value": value.value, "type": value.type], nil)
                    } else {
                        replyHandler(["error": error ?? "No value"], nil)
                    }
                }
            case "aiCancel":
                AICompletionService.shared.cancel()
                replyHandler(true, nil)
            case "extViewChanged":
                NotificationCenter.default.post(name: ExtensionViewsPanelView.viewChanged, object: nil,
                                                userInfo: ["viewId": body["viewId"] as? String ?? ""])
                replyHandler(true, nil)
            case "extSetContext":
                // setContext from an extension, for its menus' `when` clauses.
                if let key = body["key"] as? String { ExtensionViewsPanelView.contextKeys[key] = body["value"] ?? NSNull() }
                replyHandler(true, nil)
            case "extFileDecorationsChanged":
                // An extension's file decorations changed: the Explorer asks for them again.
                NotificationCenter.default.post(name: LeftSidebarView.fileDecorationsDidChange, object: nil)
                replyHandler(true, nil)
            case "filesChanged":
                // npm or a task changed the project's files.
                NotificationCenter.default.post(name: ProjectStore.filesDidChange, object: store)
                replyHandler(true, nil)
            case "pipCommand":
                // pip in the Terminal (PythonPackages): runs in the Python runtime, output when it's done.
                PythonPackages.shared.pip(body["args"] as? [String] ?? []) { output, code in
                    replyHandler(["out": output, "code": Int(code)], nil)
                }
            case "gitCommand":
                // `git` in the Terminal (GitCommandLine).
                let root = store.currentProject
                let cwd = (body["cwd"] as? String).map { URL(fileURLWithPath: $0) } ?? root
                let args = body["args"] as? [String] ?? []
                Task { @MainActor in
                    let result = await GitCommandLine.run(args, root: root, cwd: cwd)
                    replyHandler(["out": result.text, "code": Int(result.code)], nil)
                    NotificationCenter.default.post(name: ProjectStore.filesDidChange, object: store)
                }
            case "gitBlame":
                // The editor's blame annotation (blame.js): the commits, and each line's index into them.
                let root = store.currentProject
                let path = body["path"] as? String ?? ""
                let text = body["text"] as? String ?? ""
                guard GitRepository.isRepository(root) else { replyHandler(NSNull(), nil); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let owners = (try? GitRepository.open(root))?.blame(path, contents: text) ?? []
                    var commits: [[String: Any]] = []
                    var index: [String: Int] = [:]
                    let lines: [Int] = owners.map { commit in
                        guard let commit else { return -1 }
                        if let at = index[commit.id] { return at }
                        index[commit.id] = commits.count
                        commits.append(["id": commit.id, "author": commit.author, "date": commit.date.timeIntervalSince1970 * 1000,
                                        "message": commit.message])
                        return commits.count - 1
                    }
                    DispatchQueue.main.async { replyHandler(["commits": commits, "lines": lines], nil) }
                }
            case "fileIconThemes":
                // Preferences: File Icon Theme (the Command Palette).
                replyHandler(["current": AppSettings.shared.fileIconTheme,
                              "themes": FileIconTheme.shared.options.map { ["id": $0.id, "label": $0.label] }], nil)
            case "setFileIconTheme":
                AppSettings.shared.fileIconTheme = body["id"] as? String ?? ""
                replyHandler(true, nil)
            case "fileIcon":
                // A tab's icon from the file icon theme (nil: the built-in one).
                let name = body["name"] as? String ?? ""
                replyHandler(FileIconTheme.shared.dataURL(forFile: name) ?? NSNull(), nil)
            case "nodeHostStatus":
                // Whether Node.js's thread is still running (the page can't reach it after iOS took its socket).
                replyHandler(["running": NodeExtensionHost.shared.isRunning], nil)
            case "nodeHostLog":
                // The end of the Node.js extension host's log (node-host.js writes it to the temp folder).
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-studio-node-host.log")
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                replyHandler(String(text.suffix(6000)), nil)
            case "runProgram":
                // The Chat agent's run_program: run, then the console's output and how it ended.
                let seconds = min(60, max(1, body["seconds"] as? Double ?? 8))
                ProgramRunCapture.shared.run(seconds: seconds, keepRunning: body["keepRunning"] as? Bool ?? false) { result in
                    replyHandler(result, nil)
                }
            case "programConsole":
                let count = body["lines"] as? Int ?? 200
                replyHandler(ProgramRunCapture.shared.recent.suffix(count).joined(separator: "\n"), nil)
            case "aiChatModels":
                // The Chat panel's models and settings (chat.js).
                let s = AppSettings.shared
                replyHandler(["selected": s.chatModel.rawValue,
                              "models": AIChatService.shared.options.map {
                                  ["id": $0.choice.rawValue, "name": $0.name, "detail": $0.detail, "ready": $0.ready, "suggested": $0.suggested, "cloud": $0.cloud,
                                   "agent": $0.agent, "reasoning": $0.reasoning.rawValue,
                                   "contexts": $0.contexts.map { ["tokens": $0.tokens, "bytes": $0.bytes, "fits": $0.fits] }]
                              },
                              "subagentContextSize": s.subagentContextSize,
                              "contextSize": s.chatContextSize, "subagentModel": s.subagentModel?.rawValue ?? "",
                              "subagentParallel": s.subagentParallel, "mode": s.chatMode, "thinking": s.chatThinking, "kvBits": s.chatKVBits], nil)
            case "aiChatSelect":
                if let raw = body["id"] as? String, let choice = AIModelChoice(rawValue: raw) { AppSettings.shared.chatModel = choice }
                replyHandler(true, nil)
            case "aiChatSettings":
                let s = AppSettings.shared
                if let size = body["contextSize"] as? Int { s.chatContextSize = size }
                if let raw = body["subagentModel"] as? String { s.subagentModel = AIModelChoice(rawValue: raw) }
                if let count = body["subagentParallel"] as? Int { s.subagentParallel = count }
                if let size = body["subagentContextSize"] as? Int { s.subagentContextSize = size }
                // A new size takes effect when the model next loads.
                if body["contextSize"] != nil || body["subagentContextSize"] != nil { AIChatService.shared.releaseIdleEngine() }
                if let mode = body["mode"] as? String { s.chatMode = mode }
                if let thinking = body["thinking"] as? Bool { s.chatThinking = thinking }
                // A new precision takes effect when the model next loads.
                if let bits = body["kvBits"] as? Int { s.chatKVBits = bits; AIChatService.shared.releaseIdleEngine() }
                replyHandler(true, nil)
            case "aiChatCancel":
                AIChatService.shared.cancel(body["id"] as? String)
                replyHandler(true, nil)
            case "aiChat":
                // The answer streams back as aiChatText events, then aiChatDone.
                let id = body["id"] as? String ?? ""
                let messages = (body["messages"] as? [[String: Any]] ?? []).compactMap { m -> ChatMessage? in
                    guard let role = m["role"] as? String, let content = m["content"] as? String else { return nil }
                    return ChatMessage(role: role, content: content, keep: m["keep"] as? Bool ?? false)
                }
                // A subagent names its own model; the conversation uses the Chat model.
                let choice = (body["model"] as? String).flatMap(AIModelChoice.init(rawValue:))
                let maxTokens = body["maxTokens"] as? Int ?? 1536
                let contextSize = body["contextSize"] as? Int
                AIChatService.shared.respond(id: id, choice: choice, contextSize: contextSize, messages, maxTokens: maxTokens,
                                             thinking: body["thinking"] as? Bool ?? false, onText: { [weak self] text in
                    self?.emit("aiChatText", ["id": id, "text": text])
                }, completion: { [weak self] result in
                    switch result {
                    case .success(let reply):
                        var payload: [String: Any] = ["id": id, "text": reply.text, "dropped": reply.dropped]
                        if let tokens = reply.promptTokens { payload["promptTokens"] = tokens }
                        self?.emit("aiChatDone", payload)
                    case .failure(let error): self?.emit("aiChatDone", ["id": id, "error": error.localizedDescription])
                    }
                })
                replyHandler(true, nil)
            case "gitFileHistory":
                // Git: View File History: the commits that changed a file, and a commit's change to it.
                let root = store.currentProject
                let path = body["path"] as? String ?? ""
                guard let git = try? GitRepository.open(root) else { replyHandler([Any](), nil); return }
                if let id = body["commit"] as? String {
                    replyHandler(["original": git.text(of: path, at: .parent(of: id)) ?? "",
                                  "modified": git.text(of: path, at: .commit(id)) ?? ""], nil)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // Its own handle: a repository isn't shared between threads.
                    let list = ((try? GitRepository.open(root))?.log(path: path, limit: 300) ?? []).map { commit -> [String: Any] in
                        ["id": commit.id, "author": commit.author, "date": commit.date.timeIntervalSince1970 * 1000, "message": commit.message]
                    }
                    DispatchQueue.main.async { replyHandler(list, nil) }
                }
            case "write":
                let path = body["path"] as? String ?? ""
                let contents = body["contents"] as? String ?? ""
                if UserSettingsFiles.isUserPath(path) {
                    try UserSettingsFiles.write(path, contents)
                    replyHandler(true, nil)
                    return
                }
                try store.write(path, contents: contents)
                // The project's settings: the editor's and extensions' settings change with them.
                if path == ".vscode/settings.json" {
                    NotificationCenter.default.post(name: AppSettings.didChange, object: AppSettings.shared)
                    NotificationCenter.default.post(name: ExtensionHostBridge.didChangeConfiguration, object: nil)
                }
                replyHandler(true, nil)
            default:
                if ExtensionHostBridge.handle(cmd, body, reply: replyHandler) { return }
                onCommand?(cmd, body)
                replyHandler(true, nil)
            }
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }
}
