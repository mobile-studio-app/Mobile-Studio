import Foundation

/// The editor's colour themes: DuoCode's own plus those installed extensions contribute.
/// An extension theme's id is "ext:<extension id>/<path of its theme file>"; the editor loads
/// the file and turns it into a CodeMirror theme.
enum EditorThemeCatalog {
    struct Theme {
        let id: String
        let name: String
    }

    static var builtIn: [Theme] {
        AppSettings.editorThemes.map { Theme(id: $0.id, name: $0.name) }
    }

    static func themes(of extensionID: String) -> [Theme] {
        guard let manifest = ExtensionManager.shared.manifest(of: extensionID),
              let contributes = manifest["contributes"] as? [String: Any],
              let list = contributes["themes"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let path = entry["path"] as? String else { return nil }
            let name = (entry["label"] as? String) ?? (entry["id"] as? String) ?? path
            return Theme(id: "ext:\(extensionID)/\(path)", name: name)
        }
    }

    /// Every theme that can be picked now (disabled extensions' themes aren't listed).
    static var all: [Theme] {
        builtIn + ExtensionManager.shared.installed.filter(\.enabled).flatMap { themes(of: $0.id) }
    }

    static func name(of id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}
