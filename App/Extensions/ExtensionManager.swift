import Foundation
import UIKit

/// An extension listed on Open VSX.
struct MarketplaceExtension: Identifiable, Hashable {
    let namespace: String
    let name: String
    let version: String
    let displayName: String
    let summary: String
    let iconURL: URL?
    let downloadCount: Int
    let rating: Double?
    let verified: Bool

    var id: String { "\(namespace).\(name)".lowercased() }

    init?(json: [String: Any]) {
        guard let namespace = json["namespace"] as? String, let name = json["name"] as? String else { return nil }
        self.namespace = namespace
        self.name = name
        version = json["version"] as? String ?? ""
        displayName = (json["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        summary = json["description"] as? String ?? ""
        iconURL = ((json["files"] as? [String: Any])?["icon"] as? String).flatMap(URL.init(string:))
        downloadCount = json["downloadCount"] as? Int ?? 0
        rating = json["averageRating"] as? Double
        verified = json["verified"] as? Bool ?? false
    }
}

/// An installed extension, as recorded in Extensions/extensions.json.
struct InstalledExtension: Codable, Identifiable, Hashable {
    let id: String              // "publisher.name", lower case
    let version: String
    let displayName: String
    let summary: String
    let publisher: String
    var enabled: Bool
    let level: ExtensionCompatibility.Level
    let notes: [String]
    /// Folder under Extensions/ holding the extension's files (package.json at its root).
    let folder: String
    let hasIcon: Bool
}

/// Finds, installs and manages VS Code extensions from Open VSX (open-vsx.org, the registry
/// VSCodium uses). Every extension is checked with ExtensionCompatibility before it downloads.
final class ExtensionManager {
    static let shared = ExtensionManager()
    /// Posted on the main queue when extensions are installed, removed, enabled or disabled.
    static let didChange = Notification.Name("DuoCodeExtensionsDidChange")

    private let api = URL(string: "https://open-vsx.org/api")!
    private(set) var installed: [InstalledExtension] = []
    private var compatibilityCache: [String: ExtensionCompatibility] = [:]

    let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var registryURL: URL { root.appendingPathComponent("extensions.json") }

    private init() {
        if let data = try? Data(contentsOf: registryURL),
           let list = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            installed = list
        }
        // Extensions an older unpacker left incomplete (no package.json): removed, so they can be
        // installed again.
        let broken = installed.filter { manifest(of: $0.id) == nil }
        if !broken.isEmpty {
            for record in broken { try? FileManager.default.removeItem(at: root.appendingPathComponent(record.folder)) }
            installed.removeAll { record in broken.contains { $0.id == record.id } }
            if let data = try? JSONEncoder().encode(installed) { try? data.write(to: registryURL, options: .atomic) }
        }
    }

    private func saveRegistry() {
        if let data = try? JSONEncoder().encode(installed) { try? data.write(to: registryURL, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id.lowercased() } }

    // MARK: - Open VSX

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Extensions", code: status, userInfo: [NSLocalizedDescriptionKey: "Open VSX answered HTTP \(status)."])
        }
        return data
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let data = try await get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Extensions", code: -1, userInfo: [NSLocalizedDescriptionKey: "Open VSX returned something unexpected."])
        }
        return json
    }

    /// Search results, most relevant first; an empty query lists the most downloaded.
    func search(_ query: String) async throws -> [MarketplaceExtension] {
        var components = URLComponents(url: api.appendingPathComponent("-/search"), resolvingAgainstBaseURL: false)!
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        components.queryItems = [
            URLQueryItem(name: "size", value: "40"),
            URLQueryItem(name: "sortBy", value: trimmed.isEmpty ? "downloadCount" : "relevance"),
            URLQueryItem(name: "sortOrder", value: "desc"),
        ]
        if !trimmed.isEmpty { components.queryItems?.append(URLQueryItem(name: "query", value: trimmed)) }
        let json = try await getJSON(components.url!)
        return (json["extensions"] as? [[String: Any]] ?? []).compactMap(MarketplaceExtension.init(json:))
    }

    /// Everything needed to judge and install an extension.
    struct Details {
        let info: [String: Any]
        let manifest: [String: Any]
        let platforms: [String]
        let download: URL?
        let readme: URL?
        let compatibility: ExtensionCompatibility
    }

    func details(namespace: String, name: String) async throws -> Details {
        let info = try await getJSON(api.appendingPathComponent(namespace).appendingPathComponent(name))
        let downloads = info["downloads"] as? [String: String] ?? [:]
        let files = info["files"] as? [String: Any] ?? [:]
        let platforms = downloads.isEmpty ? [(info["targetPlatform"] as? String) ?? "universal"] : Array(downloads.keys)
        // Prefer the build that runs anywhere; else the macOS one, whose programs DuoCode can sign and run.
        let macPrograms = SigningCertificate.isImported
        let macBuild = macPrograms ? downloads["darwin-arm64"] : nil
        let download = (downloads["universal"] ?? downloads["web"] ?? macBuild ?? (downloads.isEmpty ? files["download"] as? String : nil))
            .flatMap(URL.init(string:))
        var manifest: [String: Any] = [:]
        if let url = (files["manifest"] as? String).flatMap(URL.init(string:)) {
            manifest = (try? JSONSerialization.jsonObject(with: try await get(url)) as? [String: Any]) ?? [:]
        }
        // Node.js-only extensions: read their code to see what it needs.
        var nodeCode: String?
        var nativePackages: [String] = []
        if manifest["browser"] == nil, let main = manifest["main"] as? String, let version = info["version"] as? String {
            (nodeCode, nativePackages) = await fetchNodeCode(namespace: namespace, name: name, version: version, main: main, manifest: manifest)
        }
        let compatibility = ExtensionCompatibility.analyze(manifest: manifest, platforms: platforms, nodeCode: nodeCode,
                                                           nativePackages: nativePackages, macPrograms: macPrograms)
        compatibilityCache["\(namespace).\(name)".lowercased()] = compatibility
        return Details(info: info, manifest: manifest, platforms: platforms, download: download,
                       readme: (files["readme"] as? String).flatMap(URL.init(string:)), compatibility: compatibility)
    }

    func cachedCompatibility(_ id: String) -> ExtensionCompatibility? { compatibilityCache[id.lowercased()] }

    /// A file from a published extension, without downloading the package (Open VSX serves
    /// them individually). For a script, tries "x", "x.js" and "x/index.js". Up to 16 MB.
    /// Returns the file's text and the path it was found at.
    private func fetchExtensionFile(namespace: String, name: String, version: String, path: String) async -> (text: String, path: String)? {
        let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let candidates = clean.hasSuffix(".js") || clean.hasSuffix(".cjs") || clean.hasSuffix(".json") ? [clean] : [clean + ".js", clean, clean + "/index.js"]
        for candidate in candidates {
            guard let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://open-vsx.org/vscode/unpkg/\(namespace)/\(name)/\(version)/extension/\(encoded)"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 16 << 20 else { continue }
            return (String(decoding: data, as: UTF8.self), candidate)
        }
        return nil
    }

    /// An extension's Node.js code for the compatibility check: the main file and the files it
    /// loads (up to 30), and the packages it uses that build native code. Extensions that aren't
    /// bundled into one file keep their code in several files and node_modules.
    private func fetchNodeCode(namespace: String, name: String, version: String, main: String,
                               manifest: [String: Any]) async -> (code: String?, nativePackages: [String]) {
        guard let first = await fetchExtensionFile(namespace: namespace, name: name, version: version, path: main) else { return (nil, []) }
        var code = first.text
        var seen: Set<String> = [first.path]
        var queue = Self.relativeRequires(in: first.text, from: first.path)
        var packages = Self.packageRequires(in: first.text)
        while !queue.isEmpty && seen.count < 30 {
            let batch = Array(queue.filter { !seen.contains($0) }.prefix(6))
            queue.removeAll()
            if batch.isEmpty { break }
            batch.forEach { seen.insert($0) }
            let files = await withTaskGroup(of: (text: String, path: String)?.self) { group in
                for path in batch { group.addTask { await self.fetchExtensionFile(namespace: namespace, name: name, version: version, path: path) } }
                var out: [(text: String, path: String)] = []
                for await file in group { if let file { out.append(file) } }
                return out
            }
            for file in files {
                seen.insert(file.path)
                code += "\n" + file.text
                queue += Self.relativeRequires(in: file.text, from: file.path)
                packages.formUnion(Self.packageRequires(in: file.text))
            }
        }
        // Packages it requires that shipped with it (in its node_modules): do they build native code?
        let dependencies = Set(((manifest["dependencies"] as? [String: Any]) ?? [:]).keys)
        let shipped = Array(packages.intersection(dependencies).subtracting(ExtensionCompatibility.nativePackages).prefix(12))
        let native = await withTaskGroup(of: String?.self) { group in
            for package in shipped {
                group.addTask {
                    guard let file = await self.fetchExtensionFile(namespace: namespace, name: name, version: version,
                                                                   path: "node_modules/\(package)/package.json"),
                          let json = try? JSONSerialization.jsonObject(with: Data(file.text.utf8)) as? [String: Any] else { return nil }
                    return ExtensionCompatibility.buildsNativeCode(json) ? package : nil
                }
            }
            var out: [String] = []
            for await package in group { if let package { out.append(package) } }
            return out.sorted()
        }
        return (code, native)
    }

    /// The files a script loads by relative path, resolved against its folder.
    static func relativeRequires(in code: String, from path: String) -> [String] {
        let pattern = #"(?:require\(\s*|\bfrom\s+|\bimport\(\s*)["'](\.\.?/[^"'\s]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let folder = (path as NSString).deletingLastPathComponent
        var out: [String] = []
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range(at: 1), in: code) else { continue }
            var parts = folder.isEmpty ? [] : folder.components(separatedBy: "/")
            for part in code[range].components(separatedBy: "/") {
                if part == ".." { _ = parts.popLast() } else if part != "." && !part.isEmpty { parts.append(part) }
            }
            out.append(parts.joined(separator: "/"))
        }
        return out
    }

    /// The packages a script requires by name ("lodash", "@scope/pkg"), without Node.js's own modules.
    static func packageRequires(in code: String) -> Set<String> {
        let pattern = #"require\(\s*["']((?:@[\w.-]+/)?[\w.-]+)(?:/[^"']*)?["']\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out = Set<String>()
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            if let range = Range(match.range(at: 1), in: code) { out.insert(String(code[range])) }
        }
        return out
    }

    // MARK: - Checking listed extensions

    private struct CheckedLevel: Codable { let version: String; let level: ExtensionCompatibility.Level }
    /// Answers depend on whether macOS programs can run, so each case has its own file.
    private var checkedLevelsFile: URL {
        root.appendingPathComponent(SigningCertificate.isImported ? "compatibility-5-mac.json" : "compatibility-5.json")
    }
    private var checkedLevelsLoadedFrom: URL?
    private var loadedCheckedLevels: [String: CheckedLevel] = [:]
    private var checkedLevels: [String: CheckedLevel] {
        get {
            if checkedLevelsLoadedFrom != checkedLevelsFile {
                checkedLevelsLoadedFrom = checkedLevelsFile
                loadedCheckedLevels = (try? Data(contentsOf: checkedLevelsFile))
                    .flatMap { try? JSONDecoder().decode([String: CheckedLevel].self, from: $0) } ?? [:]
            }
            return loadedCheckedLevels
        }
        set { loadedCheckedLevels = newValue }
    }

    /// How well a listed extension works in DuoCode, if it's been checked (this version).
    func knownLevel(of ext: MarketplaceExtension) -> ExtensionCompatibility.Level? {
        if let checked = checkedLevels[ext.id], checked.version == ext.version { return checked.level }
        return nil
    }

    /// Checks a listed extension (its manifest and builds) and remembers the answer. Main actor.
    @MainActor
    func checkLevel(of ext: MarketplaceExtension) async -> ExtensionCompatibility.Level? {
        if let level = knownLevel(of: ext) { return level }
        guard let details = try? await details(namespace: ext.namespace, name: ext.name) else { return nil }
        checkedLevels[ext.id] = CheckedLevel(version: ext.version, level: details.compatibility.level)
        if let data = try? JSONEncoder().encode(checkedLevels) {
            try? data.write(to: checkedLevelsFile, options: .atomic)
        }
        return details.compatibility.level
    }

    // MARK: - Install

    /// Installs an extension and the extensions it depends on. Incompatible ones are refused
    /// before downloading. Returns notes on anything that was skipped.
    @discardableResult
    func install(namespace: String, name: String, visited: Set<String> = []) async throws -> [String] {
        let id = "\(namespace).\(name)".lowercased()
        guard !visited.contains(id), !isInstalled(id) else { return [] }
        let details = try await self.details(namespace: namespace, name: name)
        guard details.compatibility.canInstall else {
            throw NSError(domain: "Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(details.info["displayName"] as? String ?? name) can't work in Mobile Studio. " + details.compatibility.notes.joined(separator: " ")])
        }
        guard let download = details.download else {
            throw NSError(domain: "Extensions", code: 2, userInfo: [NSLocalizedDescriptionKey: "Open VSX has no download that runs on iOS."])
        }

        let (file, response) = try await URLSession.shared.download(from: download)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Extensions", code: status, userInfo: [NSLocalizedDescriptionKey: "The download failed (HTTP \(status))."])
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("vsix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var error: NSError?
        guard dc_extract_love_archive(file.path, staging.path, &error) else {
            throw error ?? NSError(domain: "Extensions", code: 3, userInfo: [NSLocalizedDescriptionKey: "The extension package couldn't be unpacked."])
        }
        // A .vsix keeps the extension in extension/.
        let content = staging.appendingPathComponent("extension")
        let source = FileManager.default.fileExists(atPath: content.appendingPathComponent("package.json").path) ? content : staging
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("package.json").path) else {
            throw NSError(domain: "Extensions", code: 3, userInfo: [NSLocalizedDescriptionKey: "The extension package is incomplete (it has no package.json)."])
        }
        let version = details.info["version"] as? String ?? "0"
        let folder = "\(id)-\(version)"
        let target = root.appendingPathComponent(folder)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: source, to: target)
        try resolvePlaceholders(in: target)

        var hasIcon = false
        if let icon = details.manifest["icon"] as? String,
           FileManager.default.fileExists(atPath: target.appendingPathComponent(icon).path) {
            hasIcon = true
        }
        let manifest = self.manifest(in: target) ?? details.manifest
        let record = InstalledExtension(
            id: id, version: version,
            displayName: manifest["displayName"] as? String ?? details.info["displayName"] as? String ?? name,
            summary: manifest["description"] as? String ?? details.info["description"] as? String ?? "",
            publisher: (details.info["namespaceDisplayName"] as? String) ?? namespace,
            enabled: true, level: details.compatibility.level, notes: details.compatibility.notes,
            folder: folder, hasIcon: hasIcon)
        await MainActor.run {
            self.installed.removeAll { $0.id == id }
            self.installed.append(record)
            self.saveRegistry()
        }

        // Dependencies and pack members, each checked on its own.
        var skipped: [String] = []
        let others = (manifest["extensionDependencies"] as? [String] ?? []) + (manifest["extensionPack"] as? [String] ?? [])
        for other in others {
            let parts = other.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            do {
                skipped += try await install(namespace: parts[0], name: parts[1], visited: visited.union([id]))
            } catch {
                skipped.append("\(other): \(error.localizedDescription)")
            }
        }
        return skipped
    }

    func uninstall(_ id: String) {
        guard let record = installed.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(record.folder))
        installed.removeAll { $0.id == id }
        saveRegistry()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        saveRegistry()
    }

    // MARK: - Files

    func folder(of id: String) -> URL? {
        installed.first { $0.id == id }.map { root.appendingPathComponent($0.folder) }
    }

    private func manifest(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func manifest(of id: String) -> [String: Any]? {
        folder(of: id).flatMap(manifest(in:))
    }

    /// A file from an installed extension, kept inside its folder.
    func readFile(_ id: String, path: String) -> Data? {
        guard let folder = folder(of: id) else { return nil }
        let base = folder.standardizedFileURL.path + "/"
        let url = folder.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(base) else { return nil }
        return try? Data(contentsOf: url)
    }

    func iconImage(of record: InstalledExtension) -> UIImage? {
        guard record.hasIcon, let icon = manifest(of: record.id)?["icon"] as? String,
              let data = readFile(record.id, path: icon) else { return nil }
        return UIImage(data: data)
    }

    /// Replaces "%key%" strings in package.json with package.nls.json's values, as VS Code does.
    private func resolvePlaceholders(in folder: URL) throws {
        let packageURL = folder.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nlsData = try? Data(contentsOf: folder.appendingPathComponent("package.nls.json")),
              let nls = try JSONSerialization.jsonObject(with: nlsData) as? [String: Any] else { return }
        func resolve(_ value: Any) -> Any {
            if let text = value as? String, text.count > 2, text.hasPrefix("%"), text.hasSuffix("%") {
                let key = String(text.dropFirst().dropLast())
                if let entry = nls[key] as? String { return entry }
                if let entry = (nls[key] as? [String: Any])?["message"] as? String { return entry }
                return text
            }
            if let dict = value as? [String: Any] { return dict.mapValues(resolve) }
            if let list = value as? [Any] { return list.map(resolve) }
            return value
        }
        let resolved = resolve(manifest)
        try JSONSerialization.data(withJSONObject: resolved, options: [.prettyPrinted]).write(to: packageURL)
    }

    /// What the editor needs to load extensions: enabled ones with their manifests.
    func editorPayload() -> [[String: Any]] {
        installed.filter(\.enabled).compactMap { record in
            guard let manifest = manifest(of: record.id) else { return nil }
            let path: String = folder(of: record.id)?.path ?? ""
            let payload: [String: Any] = ["id": record.id, "level": record.level.rawValue, "manifest": manifest, "path": path]
            return payload
        }
    }
}
