import Foundation
import UIKit

/// The native half of the web extension host (Editor/src/ext/host.js): the files, settings,
/// state and clipboard that extensions reach through the `vscode` API.
enum ExtensionHostBridge {
    private static var stateURL: URL { ExtensionManager.shared.root.appendingPathComponent("state.json") }
    private static var settingsURL: URL { ExtensionManager.shared.root.appendingPathComponent("settings.json") }

    private static func loadJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func saveJSON(_ object: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Extensions' settings ("contributes.configuration" values the user or an extension changed).
    static var configuration: [String: Any] {
        get { loadJSON(settingsURL) }
        set {
            saveJSON(newValue, to: settingsURL)
            NotificationCenter.default.post(name: didChangeConfiguration, object: nil)
        }
    }

    static let didChangeConfiguration = Notification.Name("DuoCodeExtensionConfigurationDidChange")

    /// globalState / workspaceState mementos, as JSON strings keyed "global:<id>" and
    /// "workspace:<id>:<project>".
    static func state(project: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in loadJSON(stateURL) {
            if key.hasPrefix("global:") { out[key] = value }
            let suffix = ":" + project
            if key.hasPrefix("workspace:"), key.hasSuffix(suffix) { out[String(key.dropLast(suffix.count))] = value }
        }
        return out
    }

    static func saveState(key: String, value: String, project: String) {
        var all = loadJSON(stateURL)
        all[key.hasPrefix("workspace:") ? key + ":" + project : key] = value
        saveJSON(all, to: stateURL)
    }

    /// Handles a host command. Returns false when `cmd` isn't one of the host's.
    static func handle(_ cmd: String, _ body: [String: Any], reply: @escaping (Any?, String?) -> Void) -> Bool {
        let store = ProjectStore.shared
        let project = store.currentProject.lastPathComponent
        switch cmd {
        case "extHostInit":
            let payload: [String: Any] = ["configuration": UserSettingsFiles.effectiveConfiguration(in: store.currentProject),
                                          "state": state(project: project), "project": project,
                                          "projectPath": store.currentProject.path]
            reply(payload, nil)
        case "nodeHostStart":
            // Extensions whose code needs Node.js run there; the page connects to this port.
            reply((NodeExtensionHost.shared.start() as Any?) ?? NSNull(), nil)
        case "extSaveState":
            saveState(key: body["key"] as? String ?? "", value: body["value"] as? String ?? "", project: project)
            reply(true, nil)
        case "extSaveConfiguration":
            configuration = body["values"] as? [String: Any] ?? [:]
            reply(true, nil)
        case "clipboardRead":
            reply(UIPasteboard.general.string ?? "", nil)
        case "clipboardWrite":
            UIPasteboard.general.string = body["text"] as? String ?? ""
            reply(true, nil)
        case "openExternal":
            if let url = URL(string: body["uri"] as? String ?? ""), ["http", "https", "mailto"].contains(url.scheme) {
                UIApplication.shared.open(url)
                reply(true, nil)
            } else {
                reply(false, nil)
            }
        case "fs":
            do { reply(try fileOperation(body, store: store), nil) } catch { reply(nil, error.localizedDescription) }
        case "extSecret":
            reply(secret(body), nil)
        default:
            return false
        }
        return true
    }

    /// context.secrets: an extension's secrets, in the Keychain. Each extension's key names are kept
    /// too (under one more entry), for keys().
    private static func secret(_ body: [String: Any]) -> Any {
        let id = body["id"] as? String ?? ""
        let key = body["key"] as? String ?? ""
        let account = "ext-secret.\(id).\(key)"
        let indexAccount = "ext-secret-keys.\(id)"
        var keys = (KeychainStore.string(for: indexAccount).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String]) ?? []
        let saveKeys = {
            if let data = try? JSONSerialization.data(withJSONObject: keys), let text = String(data: data, encoding: .utf8) {
                KeychainStore.set(text, for: indexAccount)
            }
        }
        switch body["op"] as? String ?? "" {
        case "get":
            return KeychainStore.string(for: account) ?? NSNull()
        case "store":
            KeychainStore.set(body["value"] as? String ?? "", for: account)
            if !keys.contains(key) { keys.append(key); saveKeys() }
            return true
        case "delete":
            KeychainStore.remove(account)
            keys.removeAll { $0 == key }
            saveKeys()
            return true
        case "keys":
            return keys
        default:
            return NSNull()
        }
    }

    /// workspace.fs, sandboxed to the open project. Paths are project-relative.
    private static func fileOperation(_ body: [String: Any], store: ProjectStore) throws -> Any {
        let fm = FileManager.default
        let url = try store.resolve(body["path"] as? String ?? "")
        let changed = { NotificationCenter.default.post(name: ProjectStore.filesDidChange, object: store) }
        switch body["op"] as? String ?? "" {
        case "read":
            return try Data(contentsOf: url).base64EncodedString()
        case "write":
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(base64Encoded: body["base64"] as? String ?? "")?.write(to: url, options: .atomic)
            changed()
            return true
        case "stat":
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
            guard fm.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            return ["type": values.isDirectory == true ? 2 : 1, "size": values.fileSize ?? 0,
                    "mtime": Int((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000),
                    "ctime": Int((values.creationDate?.timeIntervalSince1970 ?? 0) * 1000)]
        case "list":
            return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).map { child in
                [child.lastPathComponent, (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? 2 : 1] as [Any]
            }
        case "mkdir":
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            changed()
            return true
        case "delete":
            try fm.removeItem(at: url)
            changed()
            return true
        case "rename":
            let target = try store.resolve(body["to"] as? String ?? "")
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: url, to: target)
            changed()
            return true
        default:
            throw CocoaError(.featureUnsupported)
        }
    }
}
