import Foundation

/// VS Code's settings.json and keybindings.json, which the editor opens as "@user/settings.json"
/// and "@user/keybindings.json", and a project's .vscode/settings.json.
///
/// settings.json shows the app's settings under VS Code's names (editor.fontSize,
/// workbench.colorTheme, files.autoSave...) and extensions' settings beside them; saving it
/// applies them. The file keeps your comments while what it says is still what's set; after a
/// change in the Settings screen it's written again. keybindings.json is read by the editor.
/// A project's .vscode/settings.json overrides both for that project.
enum UserSettingsFiles {
    static let prefix = "@user/"

    static func isUserPath(_ path: String) -> Bool { path.hasPrefix(prefix) }

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("User", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func url(_ path: String) -> URL? {
        let name = String(path.dropFirst(prefix.count))
        guard ["settings.json", "keybindings.json"].contains(name) else { return nil }
        return folder.appendingPathComponent(name)
    }

    static func read(_ path: String) throws -> String {
        guard let url = url(path) else { throw CocoaError(.fileNoSuchFile) }
        if url.lastPathComponent == "keybindings.json" {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? defaultKeybindings
        }
        // The saved text, while it still says what's set; otherwise written afresh.
        if let text = try? String(contentsOf: url, encoding: .utf8), let values = JSONC.object(text),
           NSDictionary(dictionary: values).isEqual(to: userValues()) {
            return text
        }
        return settingsText(userValues())
    }

    /// Saves the file; settings.json is applied if it's valid. Throws why it wasn't.
    static func write(_ path: String, _ text: String) throws {
        guard let url = url(path) else { throw CocoaError(.fileNoSuchFile) }
        try Data(text.utf8).write(to: url, options: .atomic)
        let parsed: Any
        do {
            parsed = try JSONC.parse(text)
        } catch {
            throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(url.lastPathComponent) was saved, but it isn't valid JSON, so it wasn't applied."])
        }
        if url.lastPathComponent == "settings.json" {
            guard let values = parsed as? [String: Any] else {
                throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json should be an object ({ ... })."])
            }
            apply(values)
        } else if !(parsed is [Any]) {
            throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "keybindings.json should be a list ([ ... ])."])
        }
    }

    static let defaultKeybindings = """
        // Keyboard shortcuts: each entry binds a key to a command, as in VS Code.
        // Commands are those in the Command Palette and extensions'; "-command" removes a shortcut.
        [
            // { "key": "ctrl+shift+t", "command": "workbench.action.terminal.toggleTerminal" }
        ]

        """

    // MARK: - Values

    /// The app's settings under VS Code's names.
    private static let appKeys: Set<String> = [
        "workbench.colorTheme", "workbench.iconTheme", "editor.fontSize", "editor.tabSize", "editor.wordWrap", "files.autoSave",
        "editor.formatOnSave", "mobileStudio.codeSuggestions", "mobileStudio.ai.model", "mobileStudio.ai.mergeModel", "mobileStudio.ai.chatModel", "mobileStudio.ai.chat.contextSize",
        "mobileStudio.ai.chat.subagentModel", "mobileStudio.ai.chat.parallelSubagents", "mobileStudio.ai.chat.mode",
        "mobileStudio.ai.downloadOverMobileData", "mobileStudio.luajit.jit", "git.enableSmartCommit",
    ]

    static func appValues() -> [String: Any] {
        let s = AppSettings.shared
        var values: [String: Any] = [
            "workbench.colorTheme": s.editorTheme,
            "workbench.iconTheme": s.fileIconTheme,
            "editor.fontSize": s.fontSize,
            "editor.tabSize": s.tabSize,
            "editor.wordWrap": s.wordWrap ? "on" : "off",
            "files.autoSave": s.autoSave ? "afterDelay" : "off",
            "editor.formatOnSave": s.formatOnSave,
            "mobileStudio.codeSuggestions": s.codeSuggestions,
            "mobileStudio.ai.model": s.aiModel.rawValue,
            "mobileStudio.ai.chatModel": s.chatModel.rawValue,
            "mobileStudio.ai.chat.contextSize": s.chatContextSize,
            "mobileStudio.ai.chat.subagentModel": s.subagentModel?.rawValue ?? "",
            "mobileStudio.ai.chat.parallelSubagents": s.subagentParallel,
            "mobileStudio.ai.chat.mode": s.chatMode,
            "mobileStudio.ai.downloadOverMobileData": s.downloadOverCellular,
            "mobileStudio.luajit.jit": s.useJIT,
            "git.enableSmartCommit": s.smartCommit,
        ]
        if let merge = s.aiMergeModel { values["mobileStudio.ai.mergeModel"] = merge.rawValue }
        return values
    }

    /// Everything settings.json says: the app's settings and extensions'.
    static func userValues() -> [String: Any] {
        ExtensionHostBridge.configuration.merging(appValues()) { _, app in app }
    }

    static func settingsText(_ values: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Applies a settings.json: the app's settings, and the rest as extensions' settings.
    static func apply(_ values: [String: Any]) {
        let s = AppSettings.shared
        let bool = { (key: String) -> Bool? in (values[key] as? NSNumber)?.boolValue }
        let int = { (key: String) -> Int? in (values[key] as? NSNumber)?.intValue }
        if let theme = values["workbench.colorTheme"] as? String, theme != s.editorTheme { s.editorTheme = theme }
        if let theme = values["workbench.iconTheme"] as? String, theme != s.fileIconTheme { s.fileIconTheme = theme }
        if let size = int("editor.fontSize"), size != s.fontSize { s.fontSize = max(6, min(48, size)) }
        if let size = int("editor.tabSize"), size != s.tabSize { s.tabSize = max(1, min(16, size)) }
        if let wrap = values["editor.wordWrap"] {
            let on = (wrap as? String).map { $0 != "off" } ?? ((wrap as? NSNumber)?.boolValue ?? s.wordWrap)
            if on != s.wordWrap { s.wordWrap = on }
        }
        if let save = values["files.autoSave"] {
            let on = (save as? String).map { $0 != "off" } ?? ((save as? NSNumber)?.boolValue ?? s.autoSave)
            if on != s.autoSave { s.autoSave = on }
        }
        if let on = bool("editor.formatOnSave"), on != s.formatOnSave { s.formatOnSave = on }
        if let on = bool("mobileStudio.codeSuggestions"), on != s.codeSuggestions { s.codeSuggestions = on }
        if let raw = values["mobileStudio.ai.model"] as? String, let choice = AIModelChoice(rawValue: raw), choice != s.aiModel { s.aiModel = choice }
        if let raw = values["mobileStudio.ai.mergeModel"] as? String, let choice = AIModelChoice(rawValue: raw) { s.aiMergeModel = choice }
        if let raw = values["mobileStudio.ai.chatModel"] as? String, let choice = AIModelChoice(rawValue: raw), choice != s.chatModel { s.chatModel = choice }
        if let size = int("mobileStudio.ai.chat.contextSize"), size != s.chatContextSize { s.chatContextSize = size }
        if let raw = values["mobileStudio.ai.chat.subagentModel"] as? String, AIModelChoice(rawValue: raw) != s.subagentModel { s.subagentModel = AIModelChoice(rawValue: raw) }
        if let count = int("mobileStudio.ai.chat.parallelSubagents"), count != s.subagentParallel { s.subagentParallel = count }
        if let mode = values["mobileStudio.ai.chat.mode"] as? String, ["manual", "edit", "auto", "turbo"].contains(mode), mode != s.chatMode { s.chatMode = mode }
        if let on = bool("mobileStudio.ai.downloadOverMobileData"), on != s.downloadOverCellular { s.downloadOverCellular = on }
        if let on = bool("mobileStudio.luajit.jit"), on != s.useJIT { s.useJIT = on }
        if let on = bool("git.enableSmartCommit"), on != s.smartCommit { s.smartCommit = on }
        let extensionValues = values.filter { !appKeys.contains($0.key) }
        if !NSDictionary(dictionary: extensionValues).isEqual(to: ExtensionHostBridge.configuration) {
            ExtensionHostBridge.configuration = extensionValues
        }
    }

    // MARK: - Workspace settings (.vscode/settings.json)

    static func workspaceValues(in project: URL) -> [String: Any] {
        let url = project.appendingPathComponent(".vscode/settings.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return JSONC.object(text) ?? [:]
    }

    /// Extensions' settings with the project's on top.
    static func effectiveConfiguration(in project: URL) -> [String: Any] {
        let workspace = workspaceValues(in: project).filter { !appKeys.contains($0.key) }
        return ExtensionHostBridge.configuration.merging(workspace) { _, project in project }
    }

    /// The editor's settings (AppSettings.editorPayload) with the project's overrides.
    static func editorOverrides(in project: URL) -> [String: Any] {
        let values = workspaceValues(in: project)
        var out: [String: Any] = [:]
        if let theme = values["workbench.colorTheme"] as? String { out["theme"] = theme }
        if let size = (values["editor.fontSize"] as? NSNumber)?.intValue { out["fontSize"] = size }
        if let size = (values["editor.tabSize"] as? NSNumber)?.intValue { out["tabSize"] = size }
        if let wrap = values["editor.wordWrap"] { out["wordWrap"] = (wrap as? String).map { $0 != "off" } ?? (wrap as? NSNumber)?.boolValue ?? false }
        if let save = values["files.autoSave"] { out["autoSave"] = (save as? String).map { $0 != "off" } ?? (save as? NSNumber)?.boolValue ?? false }
        if let on = (values["editor.formatOnSave"] as? NSNumber)?.boolValue { out["formatOnSave"] = on }
        // Editor features with no switch in Settings: from settings.json, the project's over the user's.
        let both = userValues().merging(values) { _, project in project }
        if let on = (both["editor.minimap.enabled"] as? NSNumber)?.boolValue { out["minimap"] = on }
        if let on = (both["editor.stickyScroll.enabled"] as? NSNumber)?.boolValue { out["stickyScroll"] = on }
        if let on = (both["git.blame.editorDecoration.enabled"] as? NSNumber)?.boolValue { out["blame"] = on }
        if let hints = both["editor.inlayHints.enabled"] {
            out["inlayHints"] = (hints as? String).map { $0 == "on" || $0 == "onUnlessPressed" } ?? (hints as? NSNumber)?.boolValue ?? true
        }
        return out
    }
}
