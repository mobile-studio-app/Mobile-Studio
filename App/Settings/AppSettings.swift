import Foundation

/// Which AI a feature uses: none, Apple Intelligence, or a model from AIModelCatalog, by its id
/// (Fast AI and Regular AI are "fast" and "regular"; models from Settings → Advanced have their own).
struct AIModelChoice: Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    private init(_ rawValue: String) { self.rawValue = rawValue }

    static let off = AIModelChoice("off")
    static let appleIntelligence = AIModelChoice("apple")
    static let fast = AIModelChoice("fast")
    static let regular = AIModelChoice("regular")

    /// A model that downloads and runs with llama.cpp.
    var isLocal: Bool { self != .off && self != .appleIntelligence }
}

/// User preferences, stored in UserDefaults. Changing any of them posts `didChange`.
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("DuoCodeSettingsDidChange")

    static let editorThemes: [(id: String, name: String)] = [
        ("dark-plus", "Dark+ (default)"),
        ("light-plus", "Light+"),
        ("monokai", "Monokai"),
        ("one-dark", "One Dark"),
        ("solarized-dark", "Solarized Dark"),
    ]

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.editorTheme: "dark-plus",
            Key.fontSize: 13,
            Key.tabSize: 4,
            Key.wordWrap: false,
            Key.autoSave: true,
            Key.formatOnSave: false,
            Key.codeSuggestions: true,
            Key.aiModel: AIModelChoice.off.rawValue,
            Key.aiMergeModel: "",
            Key.chatModel: AIModelChoice.appleIntelligence.rawValue,
            Key.useJIT: true,
            Key.downloadOverCellular: false,
            Key.smartCommit: false,
            Key.fileIconTheme: "",
            Key.testAutomation: false,
        ])
    }

    private enum Key {
        static let editorTheme = "settings.editor.theme"
        static let fontSize = "settings.editor.fontSize"
        static let tabSize = "settings.editor.tabSize"
        static let wordWrap = "settings.editor.wordWrap"
        static let autoSave = "settings.editor.autoSave"
        static let formatOnSave = "settings.editor.formatOnSave"
        static let codeSuggestions = "settings.editor.suggestions"
        static let aiModel = "settings.ai.model"
        static let aiMergeModel = "settings.ai.mergeModel"
        static let chatModel = "settings.ai.chatModel"
        static let useJIT = "settings.run.jit"
        static let downloadOverCellular = "settings.ai.cellular"
        static let smartCommit = "settings.git.smartCommit"
        static let fileIconTheme = "settings.workbench.iconTheme"
        static let testAutomation = "settings.dev.automation"
    }

    var editorTheme: String {
        get { defaults.string(forKey: Key.editorTheme) ?? "dark-plus" }
        set { set(newValue, Key.editorTheme) }
    }

    var fontSize: Int {
        get { defaults.integer(forKey: Key.fontSize) }
        set { set(min(max(newValue, 9), 24), Key.fontSize) }
    }

    var tabSize: Int {
        get { defaults.integer(forKey: Key.tabSize) }
        set { set(newValue, Key.tabSize) }
    }

    var wordWrap: Bool {
        get { defaults.bool(forKey: Key.wordWrap) }
        set { set(newValue, Key.wordWrap) }
    }

    var autoSave: Bool {
        get { defaults.bool(forKey: Key.autoSave) }
        set { set(newValue, Key.autoSave) }
    }

    /// Format Document on every save (VS Code's editor.formatOnSave).
    var formatOnSave: Bool {
        get { defaults.bool(forKey: Key.formatOnSave) }
        set { set(newValue, Key.formatOnSave) }
    }

    /// The standard (non-AI) completion popup and signature help.
    var codeSuggestions: Bool {
        get { defaults.bool(forKey: Key.codeSuggestions) }
        set { set(newValue, Key.codeSuggestions) }
    }

    var aiModel: AIModelChoice {
        get { AIModelChoice(rawValue: defaults.string(forKey: Key.aiModel) ?? "") ?? .off }
        set { set(newValue.rawValue, Key.aiModel) }
    }

    /// The model "Resolve for me" uses for merge conflicts; nil means the same one as AI Suggestions.
    var aiMergeModel: AIModelChoice? {
        get { defaults.string(forKey: Key.aiMergeModel).flatMap(AIModelChoice.init(rawValue:)) }
        set { set(newValue?.rawValue ?? "", Key.aiMergeModel) }
    }

    var effectiveMergeModel: AIModelChoice { aiMergeModel ?? aiModel }

    /// The model the Chat panel talks to.
    var chatModel: AIModelChoice {
        get { AIModelChoice(rawValue: defaults.string(forKey: Key.chatModel) ?? "") ?? .appleIntelligence }
        set { set(newValue.rawValue, Key.chatModel) }
    }

    var useJIT: Bool {
        get { defaults.bool(forKey: Key.useJIT) }
        set { set(newValue, Key.useJIT) }
    }

    /// Lets model downloads use mobile data and personal hotspots. Low Data Mode always pauses them.
    var downloadOverCellular: Bool {
        get { defaults.bool(forKey: Key.downloadOverCellular) }
        set { set(newValue, Key.downloadOverCellular) }
    }

    /// Commit every change when nothing is staged, without asking (VS Code's git.enableSmartCommit).
    /// The file icon theme (FileIconTheme): "<extension id>/<theme id>", or "" for the built-in icons.
    var fileIconTheme: String {
        get { defaults.string(forKey: Key.fileIconTheme) ?? "" }
        set { set(newValue, Key.fileIconTheme) }
    }

    var smartCommit: Bool {
        get { defaults.bool(forKey: Key.smartCommit) }
        set { set(newValue, Key.smartCommit) }
    }

    /// Lets a computer on the same Wi-Fi drive DuoCode for testing (AutomationServer).
    var testAutomation: Bool {
        get { defaults.bool(forKey: Key.testAutomation) }
        set { set(newValue, Key.testAutomation) }
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// What the editor page needs (see Editor/src/settings.js).
    func editorPayload(aiReady: Bool, aiMergeReady: Bool) -> [String: Any] {
        [
            "theme": editorTheme,
            "fontSize": fontSize,
            "tabSize": tabSize,
            "wordWrap": wordWrap,
            "autoSave": autoSave,
            "formatOnSave": formatOnSave,
            "suggestions": codeSuggestions,
            "ai": aiReady,
            "aiMerge": aiMergeReady,
        ]
    }
}
