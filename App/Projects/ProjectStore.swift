import Foundation
import UIKit
import UniformTypeIdentifiers

/// A project folder under Documents/Projects, or a folder elsewhere opened from the Files app.
struct ProjectInfo {
    let url: URL
    var name: String { url.lastPathComponent }
    /// When DuoCode last opened it, or the folder's modification date if never.
    let lastUsed: Date
    /// Opened from Files (iCloud Drive, On My iPad, another app's folder): edited where it is.
    var isExternal = false
}

/// Projects live in Documents/Projects so they're visible in the Files app
/// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
final class ProjectStore {
    static let shared = ProjectStore()
    /// Posted on the main queue after `write` saves a file.
    static let filesDidChange = Notification.Name("DuoCodeProjectFilesDidChange")

    let projectsRoot: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("Projects", isDirectory: true)
    }()

    private let lastProjectKey = "duocode.lastProject"
    private let lastOpenedKey = "duocode.projectLastOpened"
    /// Folders opened from Files: security-scoped bookmarks, so they can be opened again later.
    private let externalKey = "mobilestudio.externalFolders"
    private var accessing: Set<URL> = []

    private var _currentProject: URL?
    var currentProject: URL {
        if let p = _currentProject { return p }
        bootstrap()
        return _currentProject ?? projectsRoot.appendingPathComponent("hello", isDirectory: true)
    }

    func setCurrentProject(_ url: URL) {
        _currentProject = url
    }

    /// Makes `url` the current project and remembers it for the next launch and the Recent list.
    func openProject(_ url: URL) {
        _currentProject = url
        let defaults = UserDefaults.standard
        defaults.set(projectKey(url), forKey: lastProjectKey)
        var opened = defaults.dictionary(forKey: lastOpenedKey) as? [String: Double] ?? [:]
        opened[projectKey(url)] = Date().timeIntervalSince1970
        defaults.set(opened, forKey: lastOpenedKey)
    }

    func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let hello = projectsRoot.appendingPathComponent("hello", isDirectory: true)
        if !fm.fileExists(atPath: hello.path) {
            let sample = Bundle.main.url(forResource: "hello", withExtension: nil, subdirectory: "SampleProjects")
                ?? Bundle.main.url(forResource: "hello", withExtension: nil)
            if let sample {
                try? fm.copyItem(at: sample, to: hello)
            } else {
                try? fm.createDirectory(at: hello, withIntermediateDirectories: true)
                let mainLua = hello.appendingPathComponent("main.lua")
                let code = "function love.draw()\n    love.graphics.print('Hello Mobile Studio!', 40, 40)\nend\n"
                try? code.write(to: mainLua, atomically: true, encoding: .utf8)
            }
        }
        // Reopen the last project if it still exists.
        if let last = UserDefaults.standard.string(forKey: lastProjectKey) {
            if last.hasPrefix("/"), let external = externalFolders().first(where: { $0.path == last }) {
                _currentProject = external
                return
            }
            let url = projectsRoot.appendingPathComponent(last, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                _currentProject = url
                return
            }
        }
        _currentProject = hello
    }

    // MARK: - Projects

    /// All project folders, most recently used first.
    func listProjects() -> [ProjectInfo] {
        let fm = FileManager.default
        let opened = UserDefaults.standard.dictionary(forKey: lastOpenedKey) as? [String: Double] ?? [:]
        let urls = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let projects = urls.compactMap { url -> ProjectInfo? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            let lastUsed = opened[url.lastPathComponent].map { Date(timeIntervalSince1970: $0) }
                ?? values?.contentModificationDate ?? .distantPast
            return ProjectInfo(url: url, lastUsed: lastUsed)
        }
        let external = externalFolders().map { url in
            ProjectInfo(url: url, lastUsed: opened[url.path].map { Date(timeIntervalSince1970: $0) } ?? .distantPast, isExternal: true)
        }
        return (projects + external).sorted { $0.lastUsed > $1.lastUsed }
    }

    // MARK: - Folders from Files

    /// Projects under Documents/Projects are known by name; folders from Files by their path.
    private func projectKey(_ url: URL) -> String {
        url.standardizedFileURL.deletingLastPathComponent().path == projectsRoot.standardizedFileURL.path ? url.lastPathComponent : url.path
    }

    /// Adds a folder picked in Files (UIDocumentPickerViewController for .folder) and returns it.
    /// It's edited in place: files aren't copied.
    func addExternalFolder(_ picked: URL) throws -> URL {
        guard picked.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        accessing.insert(picked)
        let bookmark = try picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var saved = UserDefaults.standard.array(forKey: externalKey) as? [Data] ?? []
        let known = externalFolders()
        if let index = known.firstIndex(where: { $0.standardizedFileURL == picked.standardizedFileURL }), index < saved.count {
            saved[index] = bookmark
        } else {
            saved.append(bookmark)
        }
        UserDefaults.standard.set(saved, forKey: externalKey)
        return picked
    }

    /// Folders opened from Files that can still be reached (each is kept accessible while the app runs).
    func externalFolders() -> [URL] {
        let saved = UserDefaults.standard.array(forKey: externalKey) as? [Data] ?? []
        var refreshed = saved
        var urls: [URL] = []
        for (index, data) in saved.enumerated() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if !accessing.contains(url) {
                guard url.startAccessingSecurityScopedResource() else { continue }
                accessing.insert(url)
            }
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshed[index] = fresh
            }
            urls.append(url)
        }
        if refreshed != saved { UserDefaults.standard.set(refreshed, forKey: externalKey) }
        return urls
    }

    /// Takes a folder from Files off the list (its files stay where they are).
    @discardableResult
    func forgetExternalFolder(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        let saved = UserDefaults.standard.array(forKey: externalKey) as? [Data] ?? []
        let kept = saved.filter { data in
            var stale = false
            let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            return resolved?.standardizedFileURL != target
        }
        UserDefaults.standard.set(kept, forKey: externalKey)
        if let held = accessing.first(where: { $0.standardizedFileURL == target }) {
            held.stopAccessingSecurityScopedResource()
            accessing.remove(held)
        }
        guard _currentProject?.standardizedFileURL == target else { return false }
        _currentProject = nil
        UserDefaults.standard.removeObject(forKey: lastProjectKey)
        if let next = listProjects().first { openProject(next.url) } else { bootstrap(); openProject(currentProject) }
        return true
    }

    /// Deletes a project folder and forgets it. If it was the open project, the most recently used
    /// remaining one becomes current (or the "hello" sample, recreated if needed).
    /// Returns true when the current project changed.
    @discardableResult
    func deleteProject(_ url: URL) throws -> Bool {
        let target = url.standardizedFileURL
        guard target.deletingLastPathComponent().path == projectsRoot.standardizedFileURL.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: target)
        let defaults = UserDefaults.standard
        var opened = defaults.dictionary(forKey: lastOpenedKey) as? [String: Double] ?? [:]
        opened[target.lastPathComponent] = nil
        defaults.set(opened, forKey: lastOpenedKey)
        defaults.removeObject(forKey: "duocode.explorer.expanded." + target.lastPathComponent)

        guard _currentProject?.standardizedFileURL == target else { return false }
        if let next = listProjects().first {
            openProject(next.url)
        } else {
            defaults.removeObject(forKey: lastProjectKey)
            _currentProject = nil
            bootstrap()
            openProject(currentProject)
        }
        return true
    }

    /// A folder URL for `name` that doesn't exist yet: "name", then "name 2", "name 3"…
    func uniqueProjectURL(named name: String) -> URL {
        let fm = FileManager.default
        var candidate = projectsRoot.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = projectsRoot.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Creates a new LÖVE 12 project from the starter template. Does not open it.
    /// Creates a project for `runtime` (an interpreter id such as "love-12.0", "lua-5.4" or
    /// "python-3.13") from its starter template, and records the interpreter in its settings.
    func createProject(named rawName: String, runtime: String = "love-12.0") throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        guard !name.isEmpty, !name.hasPrefix("."), name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw NSError(domain: "ProjectStore", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Use letters, numbers, spaces, - or _ for the project name."])
        }
        let url = projectsRoot.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "ProjectStore", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "A project named “\(name)” already exists."])
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        if runtime.hasPrefix("lua-") {
            let main = """
            -- A Lua program. print() shows in the console; io.read() reads what you type there.
            print("Hello from \(name)!")
            io.write("What's your name? ")
            local who = io.read()
            print("Nice to meet you, " .. (who or "stranger") .. "!")

            """
            try main.write(to: url.appendingPathComponent("main.lua"), atomically: true, encoding: .utf8)
            try RuntimeManager.shared.setRuntime(runtime, for: url)
            return url
        }
        if runtime.hasPrefix("node") {
            let main = """
            // A JavaScript program, run by Node.js. console.log() shows in the console; readline
            // reads what you type there.
            const readline = require('readline');

            console.log('Hello from \(name)!');
            const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
            rl.question("What's your name? ", (who) => {
              console.log(`Nice to meet you, ${who || 'stranger'}!`);
              rl.close();
            });

            """
            try main.write(to: url.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            try RuntimeManager.shared.setRuntime(runtime, for: url)
            return url
        }
        if runtime.hasPrefix("python") {
            let main = """
            # A Python program. print() shows in the console; input() reads what you type there.
            print("Hello from \(name)!")
            who = input("What's your name? ")
            print(f"Nice to meet you, {who or 'stranger'}!")

            """
            try main.write(to: url.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
            try RuntimeManager.shared.setRuntime(runtime, for: url)
            return url
        }

        let loveVersion = runtime.hasPrefix("love-11") ? "11.5" : "12.0"
        let identity = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let conf = """
        function love.conf(t)
            t.identity = "\(identity)"
            t.version = "\(loveVersion)"
            t.window.title = "\(name)"
        end

        """
        let main = """
        function love.load()
        end

        function love.update(dt)
        end

        function love.draw()
            love.graphics.print("Hello from \(name)!", 20, 20)
        end

        """
        try conf.write(to: url.appendingPathComponent("conf.lua"), atomically: true, encoding: .utf8)
        try main.write(to: url.appendingPathComponent("main.lua"), atomically: true, encoding: .utf8)
        try RuntimeManager.shared.setRuntime(runtime, for: url)
        return url
    }

    /// The file to open when a project is opened: main.lua, else the first Lua file.
    func entryFile(in project: URL) -> String? {
        for entry in ["main.lua", "main.py", "main.js"] where FileManager.default.fileExists(atPath: project.appendingPathComponent(entry).path) {
            return entry
        }
        return list(in: project).first { $0.hasSuffix(".lua") || $0.hasSuffix(".py") }
    }

    /// Imports a .love game file into a new folder under Documents/Projects. Does not open it.
    func importLoveArchive(from sourceURL: URL) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        // Never overwrite an existing project with the same name.
        let targetDir = uniqueProjectURL(named: sourceURL.deletingPathExtension().lastPathComponent)

        var error: NSError?
        let ok = dc_extract_love_archive(sourceURL.path, targetDir.path, &error)
        if !ok {
            try? FileManager.default.removeItem(at: targetDir)
            throw error ?? NSError(domain: "LoveImporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract .love archive"])
        }
        return targetDir
    }

    // MARK: - File operations used by the editor bridge (sandboxed to projectsRoot)

    func resolve(_ relative: String) throws -> URL {
        // Checked by component, not by comparing standardized paths: standardizing drops the
        // "/private" prefix only from paths that exist, so a new file's path wouldn't match.
        let parts = relative.split(separator: "/")
        guard !relative.hasPrefix("/"), !parts.contains("..") else {
            throw CocoaError(.fileReadNoPermission)
        }
        return parts.filter { $0 != "." }.reduce(currentProject) { $0.appendingPathComponent(String($1)) }
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: resolve(relative), encoding: .utf8)
    }

    func write(_ relative: String, contents: String) throws {
        let url = try resolve(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let post = { NotificationCenter.default.post(name: Self.filesDidChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    func list() -> [String] {
        list(in: currentProject)
    }

    /// Every folder in the project (relative paths), so empty ones show in the Explorer too.
    func listFolders() -> [String] {
        let project = currentProject
        guard let e = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = project.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            out.append(url.standardizedFileURL.path.replacingOccurrences(of: base, with: ""))
        }
        return out
    }

    func createFolder(_ relative: String) throws {
        try FileManager.default.createDirectory(at: resolve(relative), withIntermediateDirectories: true)
        postFilesChanged()
    }

    /// Renames or moves a file or folder within the project.
    func move(_ from: String, to: String) throws {
        let source = try resolve(from), target = try resolve(to)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        postFilesChanged()
    }

    /// Copies a file to "name copy.ext" (then "name copy 2.ext", ...) and returns the copy's path.
    func duplicate(_ relative: String) throws -> String {
        let source = try resolve(relative)
        let folder = (relative as NSString).deletingLastPathComponent
        let ext = (relative as NSString).pathExtension
        let stem = ((relative as NSString).lastPathComponent as NSString).deletingPathExtension
        var n = 1
        var candidate: String
        repeat {
            let name = stem + (n == 1 ? " copy" : " copy \(n)") + (ext.isEmpty ? "" : "." + ext)
            candidate = folder.isEmpty ? name : folder + "/" + name
            n += 1
        } while FileManager.default.fileExists(atPath: try resolve(candidate).path)
        try FileManager.default.copyItem(at: source, to: try resolve(candidate))
        postFilesChanged()
        return candidate
    }

    func delete(_ relative: String) throws {
        try FileManager.default.removeItem(at: resolve(relative))
        postFilesChanged()
    }

    private func postFilesChanged() {
        let post = { NotificationCenter.default.post(name: Self.filesDidChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    private func list(in project: URL) -> [String] {
        // Hidden entries (.git bookkeeping, .duocode settings) stay out of the Explorer.
        guard let e = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = project.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(url.standardizedFileURL.path.replacingOccurrences(of: base, with: ""))
            }
        }
        return out.sorted()
    }
}
