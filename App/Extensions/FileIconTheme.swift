import UIKit

/// The file icon theme picked in Settings (VS Code's workbench.iconTheme): an installed extension's
/// contributes.iconThemes, such as Material Icon Theme. It decides each file's and folder's icon by
/// VS Code's rules, and turns icons into images: they're SVG or PNG files or a font's characters,
/// which the editor page draws (UIKit can't read SVG), cached on disk per theme.
final class FileIconTheme {
    static let shared = FileIconTheme()
    /// Posted when the theme changes or more of its icons are ready: lists redraw their rows.
    static let didChange = Notification.Name("MobileStudioFileIconThemeDidChange")

    /// An icon theme an installed extension offers. `id` is "<extension id>/<theme id>".
    struct Option {
        let id: String
        let label: String
        let extensionID: String
        /// The theme's JSON file, in the extension.
        let path: String
    }

    /// Runs JavaScript in the editor page (set by IDEViewController).
    var callEditor: ((String, [String: Any], @escaping (Any?) -> Void) -> Void)?

    private struct Loaded {
        let option: Option
        let definitions: [String: [String: Any]]
        let fonts: [[String: Any]]
        let file: String?
        let folder: String?
        let folderExpanded: String?
        let rootFolder: String?
        let rootFolderExpanded: String?
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let folderNames: [String: String]
        let folderNamesExpanded: [String: String]
        let languageIds: [String: String]
        let cacheFolder: URL
    }

    private var loaded: Loaded?
    private var images: [String: UIImage] = [:]
    private var waiting: Set<String> = []
    private var failed: Set<String> = []
    private var flushScheduled = false
    private var notifyScheduled = false
    private static let size = 16
    private static let scale = 3

    private init() {
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadIfNeeded()
        }
        NotificationCenter.default.addObserver(forName: ExtensionManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.loaded = nil
            self?.reloadIfNeeded()
        }
        reloadIfNeeded()
    }

    // MARK: - Themes

    /// The icon themes the enabled extensions offer.
    var options: [Option] {
        ExtensionManager.shared.installed.filter(\.enabled).flatMap { ext -> [Option] in
            let contributes = ExtensionManager.shared.manifest(of: ext.id)?["contributes"] as? [String: Any]
            return (contributes?["iconThemes"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String, let path = entry["path"] as? String else { return nil }
                return Option(id: "\(ext.id)/\(id)", label: entry["label"] as? String ?? id, extensionID: ext.id, path: path)
            }
        }
    }

    /// The theme in use, if it's still installed.
    var current: Option? { loaded?.option }

    /// The name to show for a theme id ("" is none).
    func label(of id: String) -> String {
        id.isEmpty ? "None" : options.first { $0.id == id }?.label ?? id
    }

    private func reloadIfNeeded() {
        let id = AppSettings.shared.fileIconTheme
        guard loaded?.option.id != id || (loaded == nil && !id.isEmpty) else { return }
        images = [:]
        waiting = []
        failed = []
        loaded = options.first { $0.id == id }.flatMap(load)
        notifySoon()
    }

    private func load(_ option: Option) -> Loaded? {
        guard let data = ExtensionManager.shared.readFile(option.extensionID, path: option.path),
              let text = String(data: data, encoding: .utf8), let json = JSONC.object(text) else { return nil }
        // Icon paths are relative to the theme file; make them relative to the extension.
        let base = (Self.clean(option.path) as NSString).deletingLastPathComponent
        var definitions: [String: [String: Any]] = [:]
        for (key, value) in json["iconDefinitions"] as? [String: Any] ?? [:] {
            guard var definition = value as? [String: Any] else { continue }
            if let path = definition["iconPath"] as? String { definition["iconPath"] = Self.join(base, path) }
            definitions[key] = definition
        }
        let fonts = (json["fonts"] as? [[String: Any]] ?? []).map { font -> [String: Any] in
            var font = font
            font["src"] = (font["src"] as? [[String: Any]] ?? []).map { source -> [String: Any] in
                var source = source
                if let path = source["path"] as? String { source["path"] = Self.join(base, path) }
                return source
            }
            return font
        }
        let lowered = { (key: String) -> [String: String] in
            var out: [String: String] = [:]
            for (name, icon) in json[key] as? [String: String] ?? [:] { out[name.lowercased()] = icon }
            return out
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = option.id.replacingOccurrences(of: "/", with: "_")
        let version = ExtensionManager.shared.installed.first { $0.id == option.extensionID }?.folder ?? ""
        let cacheFolder = caches.appendingPathComponent("FileIcons/\(version)-\(safe)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        return Loaded(option: option, definitions: definitions, fonts: fonts,
                      file: json["file"] as? String, folder: json["folder"] as? String,
                      folderExpanded: json["folderExpanded"] as? String,
                      rootFolder: json["rootFolder"] as? String, rootFolderExpanded: json["rootFolderExpanded"] as? String,
                      fileNames: lowered("fileNames"), fileExtensions: lowered("fileExtensions"),
                      folderNames: lowered("folderNames"), folderNamesExpanded: lowered("folderNamesExpanded"),
                      languageIds: json["languageIds"] as? [String: String] ?? [:], cacheFolder: cacheFolder)
    }

    // MARK: - Which icon

    /// The icon for a file, by VS Code's rules: its name, then its extensions (longest first, so
    /// "spec.ts" before "ts"), then its language, then the theme's file icon. Nil without a theme
    /// (the built-in icons are used) or before the icon is drawn.
    func image(forFile name: String) -> UIImage? {
        guard let theme = loaded else { return nil }
        let lower = name.lowercased()
        var key = theme.fileNames[lower]
        if key == nil {
            var rest = lower
            while key == nil, let dot = rest.firstIndex(of: ".") {
                rest = String(rest[rest.index(after: dot)...])
                key = theme.fileExtensions[rest]
            }
        }
        if key == nil, let language = Self.languageId(for: lower) { key = theme.languageIds[language] }
        return image(key ?? theme.file)
    }

    /// The icon for a folder (open or closed).
    func image(forFolder name: String, expanded: Bool, isRoot: Bool = false) -> UIImage? {
        guard let theme = loaded else { return nil }
        let lower = name.lowercased()
        let key = isRoot
            ? (expanded ? theme.rootFolderExpanded ?? theme.folderExpanded : theme.rootFolder ?? theme.folder)
            : expanded
                ? theme.folderNamesExpanded[lower] ?? theme.folderExpanded
                : theme.folderNames[lower] ?? theme.folder
        return image(key)
    }

    /// Whether a theme is in use (rows then show its icons, folders included).
    var isActive: Bool { loaded != nil }

    /// A PNG of the icon for a file, as a data URL, for the editor's tabs (nil without one).
    func dataURL(forFile name: String) -> String? {
        guard let image = image(forFile: name), let png = image.pngData() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func image(_ key: String?) -> UIImage? {
        guard let key, let theme = loaded, theme.definitions[key] != nil else { return nil }
        if let cached = images[key] { return cached }
        if failed.contains(key) { return nil }
        let file = theme.cacheFolder.appendingPathComponent(Self.fileName(key))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data, scale: CGFloat(Self.scale)) {
            images[key] = image
            return image
        }
        waiting.insert(key)
        flushSoon()
        return nil
    }

    // MARK: - Drawing

    private func flushSoon() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.flushScheduled = false
            self?.drawWaiting()
        }
    }

    private func drawWaiting() {
        guard let theme = loaded, let callEditor, !waiting.isEmpty else { return }
        let keys = Array(waiting.prefix(60))
        waiting.subtract(keys)
        let items = keys.compactMap { key -> [String: Any]? in
            guard var definition = theme.definitions[key] else { return nil }
            definition["key"] = key
            return definition
        }
        let arguments: [String: Any] = ["extensionId": theme.option.extensionID, "items": items, "fonts": theme.fonts,
                                        "size": Self.size * Self.scale]
        callEditor("return await window.duocode.renderFileIcons(extensionId, items, fonts, size)", arguments) { [weak self] result in
            guard let self, self.loaded?.option.id == theme.option.id else { return }
            let drawn = result as? [String: String] ?? [:]
            for key in keys {
                guard let base64 = drawn[key], let data = Data(base64Encoded: base64),
                      let image = UIImage(data: data, scale: CGFloat(Self.scale)) else {
                    self.failed.insert(key)
                    continue
                }
                self.images[key] = image
                try? data.write(to: theme.cacheFolder.appendingPathComponent(Self.fileName(key)))
            }
            self.notifySoon()
            if !self.waiting.isEmpty { self.drawWaiting() }
        }
    }

    private func notifySoon() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.notifyScheduled = false
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    // MARK: - Helpers

    private static func fileName(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.prefix(150).appending(".png") ?? "icon.png"
    }

    private static func clean(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    /// `relative` resolved against the folder `base` (both inside the extension), ".." included.
    private static func join(_ base: String, _ relative: String) -> String {
        var parts = base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/").map(String.init) {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else if part != "." && !part.isEmpty { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    /// The VS Code language of a file, for themes that match by language rather than extension.
    private static func languageId(for name: String) -> String? {
        let ext = (name as NSString).pathExtension
        for record in ExtensionManager.shared.installed where record.enabled {
            let languages = (ExtensionManager.shared.manifest(of: record.id)?["contributes"] as? [String: Any])?["languages"] as? [[String: Any]] ?? []
            for language in languages {
                let extensions = (language["extensions"] as? [String] ?? []).map { $0.lowercased() }
                let names = (language["filenames"] as? [String] ?? []).map { $0.lowercased() }
                if names.contains(name) || (!ext.isEmpty && extensions.contains("." + ext)) { return language["id"] as? String }
            }
        }
        return builtInLanguages[ext]
    }

    private static let builtInLanguages: [String: String] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "py": "python", "pyw": "python", "lua": "lua", "json": "json", "jsonc": "jsonc", "md": "markdown",
        "html": "html", "htm": "html", "css": "css", "scss": "scss", "less": "less", "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "m": "objective-c", "mm": "objective-cpp",
        "cs": "csharp", "java": "java", "kt": "kotlin", "swift": "swift", "go": "go", "rs": "rust",
        "rb": "ruby", "php": "php", "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript",
        "yml": "yaml", "yaml": "yaml", "xml": "xml", "sql": "sql", "txt": "plaintext", "toml": "toml",
        "glsl": "glsl", "vue": "vue", "svelte": "svelte", "dart": "dart", "r": "r", "pl": "perl",
    ]
}
