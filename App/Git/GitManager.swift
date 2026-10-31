import CryptoKit
import Foundation

struct GitCommit: Identifiable {
    let id: String // short hash
    let author: String
    let date: Date
    let message: String
    /// Made here and not yet pushed to GitHub.
    var isOutgoing = false
    /// The commit GitHub had at the last push or pull of this branch.
    var isSynced = false
    /// Has a file snapshot, so its changes can be listed. Commits from older builds don't.
    var hasSnapshot = false
    /// Joins another branch in (has a second parent).
    var isMerge = false
    /// Other local branches whose tip is this commit.
    var branches: [String] = []
}

/// The letters VS Code shows beside a changed file.
enum GitFileStatus: String {
    case modified = "M"
    case untracked = "U"
    case added = "A"
    case deleted = "D"
    case conflicted = "!"
}

struct GitChangedFile: Identifiable {
    var id: String { path }
    let path: String
    let status: GitFileStatus
}

struct GitStatus {
    /// Staged: the next commit's changes against the last commit.
    var stagedFiles: [GitChangedFile] = []
    /// Not staged: the working files against the staged snapshot.
    var changedFiles: [GitChangedFile] = []
    /// Files a merge couldn't combine; staging one marks it resolved.
    var mergeConflicts: [GitChangedFile] = []
    var currentBranch = "main"
    var aheadCount = 0
    var behindCount = 0
    var remoteURL: String?
    /// The branch has been pushed to or pulled from GitHub (VS Code's "upstream").
    var hasUpstream = false
    /// The branch being merged in, while a merge waits for its conflicts to be resolved.
    var mergingBranch: String?
    var stashCount = 0

    var isClean: Bool { stagedFiles.isEmpty && changedFiles.isEmpty && mergeConflicts.isEmpty }
}

/// Which copy of a file to read, for diffs.
enum GitFileVersion {
    case head                 // last commit
    case index                // staged, or the last commit when nothing is staged
    case commit(String)       // as of a commit in the log
    case parent(of: String)   // as of the commit before it
}

struct GitStash {
    let index: Int
    let message: String
    let branch: String
    let date: Date
}

enum GitMergeResult {
    case upToDate
    case fastForward
    case merged
    case conflicts([String])
}

/// In-process Git engine for iOS: snapshots, staging, branches, stash, merge, and
/// push/pull/clone against GitHub's REST API.
///
/// On disk, under .git:
/// - HEAD: "ref: refs/heads/<branch>"
/// - refs/heads/<branch>: the hash of the branch's newest commit (empty before its first commit)
/// - refs/remotes/origin/<branch>: the commit GitHub had at the branch's last push or pull
/// - commits.json: every commit, each with its parent(s), file snapshot ("tree") and, once
///   it's on GitHub, the GitHub commit SHA ("github")
/// - index.json: the snapshot of HEAD's commit; staged.json: staged changes on top of it
/// - objects/<blob id>: file contents; stash.json; MERGE_* while a merge has conflicts
final class GitManager {
    static let shared = GitManager()
    /// Posted (on the main queue) when HEAD's snapshot or the staged changes change, so the
    /// editor's change markers can compare against the new index.
    static let indexDidChange = Notification.Name("DuoCodeGitIndexDidChange")

    private func indexChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.indexDidChange, object: nil) }
    }

    private init() {}

    private typealias Record = [String: Any]

    func isGitRepo(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    func initRepo(at url: URL, branch: String = "main") throws {
        let gitDir = url.appendingPathComponent(".git", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "[]".write(to: gitDir.appendingPathComponent("commits.json"), atomically: true, encoding: .utf8)
        try "".write(to: refURL(branch, in: url), atomically: true, encoding: .utf8)
        try Self.format.write(to: gitDir.appendingPathComponent("format"), atomically: true, encoding: .utf8)
    }

    private func gitError(_ message: String, code: Int = -1) -> NSError {
        NSError(domain: "GitManager", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Remote URL Management

    func getRemoteURL(in url: URL) -> String? {
        let configFile = url.appendingPathComponent(".git/remote.json")
        guard let data = try? Data(contentsOf: configFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict["origin"]
    }

    func setRemoteURL(_ remoteURL: String, in url: URL) {
        let gitDir = url.appendingPathComponent(".git")
        try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let configFile = gitDir.appendingPathComponent("remote.json")
        let dict = ["origin": remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: configFile)
        }
    }

    // MARK: - Refs

    private func refURL(_ branch: String, in root: URL) -> URL {
        root.appendingPathComponent(".git/refs/heads/\(branch)")
    }

    private func upstreamURL(_ branch: String, in root: URL) -> URL {
        root.appendingPathComponent(".git/refs/remotes/origin/\(branch)")
    }

    private func readRef(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeRef(_ value: String?, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (value ?? "").write(to: url, atomically: true, encoding: .utf8)
    }

    func currentBranch(in url: URL) -> String {
        guard let content = readRef(url.appendingPathComponent(".git/HEAD")) else { return "main" }
        if content.hasPrefix("ref: refs/heads/") {
            return String(content.dropFirst("ref: refs/heads/".count))
        }
        return content
    }

    private func setHead(_ branch: String, in url: URL) throws {
        try "ref: refs/heads/\(branch)\n".write(to: url.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    }

    /// The newest commit on `branch`; nil before its first commit.
    func tip(of branch: String, in url: URL) -> String? {
        migrateIfNeeded(url)
        guard let ref = readRef(refURL(branch, in: url)), !ref.isEmpty else { return nil }
        return ref
    }

    private func headTip(in url: URL) -> String? { tip(of: currentBranch(in: url), in: url) }

    private func setTip(_ hash: String?, of branch: String, in url: URL) throws {
        try writeRef(hash, to: refURL(branch, in: url))
    }

    /// The commit GitHub had at the branch's last push or pull.
    func upstream(of branch: String, in url: URL) -> String? {
        migrateIfNeeded(url)
        guard let ref = readRef(upstreamURL(branch, in: url)), !ref.isEmpty else { return nil }
        return ref
    }

    private func pushedCommit(in url: URL) -> String? { upstream(of: currentBranch(in: url), in: url) }

    private func markPushed(_ hash: String, in url: URL) {
        try? writeRef(hash, to: upstreamURL(currentBranch(in: url), in: url))
    }

    // MARK: - Snapshots
    //
    // Files are identified by their git blob id (SHA-1 of "blob <size>\0" + bytes), so a local
    // snapshot compares directly with GitHub's trees. Committed contents live in .git/objects/<id>
    // (APFS clones, so they cost no extra space until a file changes).

    static func blobSHA(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isBlobSHA(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }

    private var hashCache: [String: (size: Int, modified: Date, sha: String)] = [:]
    private let hashLock = NSLock()

    /// Relative paths of the project's files, skipping hidden ones such as .git.
    private func listFiles(in root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base) { out.append(String(path.dropFirst(base.count))) }
        }
        return out.sorted()
    }

    /// Blob ids of every file in the project. Files whose size and date haven't changed reuse their last hash.
    private func workingTree(in root: URL) -> [String: String] {
        var tree: [String: String] = [:]
        for path in listFiles(in: root) {
            let file = root.appendingPathComponent(path)
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = values.fileSize ?? -1
            let modified = values.contentModificationDate ?? .distantPast
            hashLock.lock()
            let cached = hashCache[file.path]
            hashLock.unlock()
            if let cached, cached.size == size, cached.modified == modified {
                tree[path] = cached.sha
                continue
            }
            guard let data = try? Data(contentsOf: file) else { continue }
            let sha = Self.blobSHA(data)
            hashLock.lock()
            hashCache[file.path] = (size, modified, sha)
            hashLock.unlock()
            tree[path] = sha
        }
        return tree
    }

    /// Drops a file's cached hash after DuoCode writes it, so the next status reads it afresh.
    private func forgetHash(_ file: URL) {
        hashLock.lock()
        hashCache[file.path] = nil
        hashLock.unlock()
    }

    private func objectURL(_ sha: String, in root: URL) -> URL {
        root.appendingPathComponent(".git/objects/\(sha)")
    }

    private func hasObject(_ sha: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(sha, in: root).path)
    }

    private func storeObject(copying file: URL, sha: String, in root: URL) throws {
        let target = objectURL(sha, in: root)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: target)
    }

    @discardableResult
    private func storeObject(_ data: Data, in root: URL) throws -> String {
        let sha = Self.blobSHA(data)
        let target = objectURL(sha, in: root)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        return sha
    }

    private func objectText(_ sha: String?, in root: URL) -> String? {
        guard let sha, let data = try? Data(contentsOf: objectURL(sha, in: root)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveIndex(_ index: [String: String], in root: URL) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: root.appendingPathComponent(".git/index.json"))
        indexChanged()
    }

    /// The snapshot of HEAD's commit: path -> blob id.
    private func loadIndex(in root: URL) -> [String: String] {
        let file = root.appendingPathComponent(".git/index.json")
        guard let data = try? Data(contentsOf: file),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        if index.values.allSatisfy(Self.isBlobSHA) { return index }

        // Older builds stored String.hashValue, which Swift seeds differently on every launch, so
        // every file looked changed after a relaunch. Their snapshots can't be trusted (clones also
        // indexed the wrong folder), so start again from the files as they are now.
        let tree = workingTree(in: root)
        for (path, sha) in tree {
            try? storeObject(copying: root.appendingPathComponent(path), sha: sha, in: root)
        }
        try? saveIndex(tree, in: root)
        return tree
    }

    private func diff(from old: [String: String], to new: [String: String]) -> [GitChangedFile] {
        var changed: [GitChangedFile] = []
        for (path, sha) in new {
            if let previous = old[path] {
                if previous != sha { changed.append(GitChangedFile(path: path, status: .modified)) }
            } else {
                changed.append(GitChangedFile(path: path, status: .untracked))
            }
        }
        for path in old.keys where new[path] == nil {
            changed.append(GitChangedFile(path: path, status: .deleted))
        }
        return changed.sorted { $0.path < $1.path }
    }

    /// Writes one file from the object store (or deletes it when `sha` is nil).
    private func writeFile(_ path: String, sha: String?, in root: URL) throws {
        let target = root.appendingPathComponent(path)
        let fm = FileManager.default
        if let sha {
            let object = objectURL(sha, in: root)
            guard fm.fileExists(atPath: object.path) else {
                throw gitError("The saved copy of \(path) is missing, so it can't be restored.")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: object, to: target)
        } else {
            try? fm.removeItem(at: target)
            // Remove folders the delete left empty, as git does.
            var folder = target.deletingLastPathComponent().standardizedFileURL
            let rootPath = root.standardizedFileURL.path
            while folder.path.count > rootPath.count, folder.path.hasPrefix(rootPath),
                  let items = try? fm.contentsOfDirectory(atPath: folder.path), items.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: folder)
                folder = folder.deletingLastPathComponent()
            }
        }
        forgetHash(target)
    }

    /// Makes the working files match `to` wherever `from` and `to` differ. Checks every object
    /// first, so a missing one changes nothing.
    private func applyTree(from: [String: String], to: [String: String], in root: URL) throws {
        let paths = Set(from.keys).union(to.keys).filter { from[$0] != to[$0] }
        for path in paths {
            if let sha = to[path], !hasObject(sha, in: root) {
                throw gitError("The saved copy of \(path) is missing, so the files can't be switched.")
            }
        }
        for path in paths.sorted() { try writeFile(path, sha: to[path], in: root) }
    }

    // MARK: - Commit log

    private func readLog(_ root: URL) -> [Record] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".git/commits.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Record] else { return [] }
        return list
    }

    /// Every commit record, newest first.
    private func commitLog(in url: URL) -> [Record] {
        migrateIfNeeded(url)
        return readLog(url)
    }

    private func writeCommitLog(_ commits: [Record], in url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: commits, options: .prettyPrinted)
        try data.write(to: url.appendingPathComponent(".git/commits.json"))
    }

    private func byHash(_ log: [Record]) -> [String: Record] {
        var map: [String: Record] = [:]
        for record in log {
            if let hash = record["hash"] as? String { map[hash] = record }
        }
        return map
    }

    private func snapshot(of id: String, in url: URL) -> [String: String]? {
        commitLog(in: url).first { $0["hash"] as? String == id }?["tree"] as? [String: String]
    }

    /// The snapshot before commit `id`: empty for a first commit, nil if its parent predates snapshots.
    private func parentSnapshot(of id: String, in url: URL) -> [String: String]? {
        let records = byHash(commitLog(in: url))
        guard let record = records[id] else { return nil }
        guard let parent = record["parent"] as? String else { return [:] }
        return records[parent]?["tree"] as? [String: String]
    }

    /// Every commit reachable from `hash` through all parents.
    private func ancestors(of hash: String?, in records: [String: Record]) -> Set<String> {
        var seen = Set<String>()
        var queue = hash.map { [$0] } ?? []
        while let next = queue.popLast() {
            guard !seen.contains(next), let record = records[next] else { continue }
            seen.insert(next)
            if let p = record["parent"] as? String { queue.append(p) }
            if let p = record["parent2"] as? String { queue.append(p) }
        }
        return seen
    }

    /// Commits made on this branch since it was last on GitHub, newest first. The walk stops at
    /// the branch's sync point, at any commit GitHub already has, and at commits without a snapshot.
    private func unpushedCommits(in url: URL) -> [Record] {
        let records = byHash(commitLog(in: url))
        let synced = pushedCommit(in: url)
        var out: [Record] = []
        var seen = Set<String>()
        var next = headTip(in: url)
        while let hash = next, let record = records[hash], !seen.contains(hash) {
            if hash == synced || record["github"] != nil || !(record["tree"] is [String: String]) { break }
            out.append(record)
            seen.insert(hash)
            next = record["parent"] as? String
        }
        return out
    }

    // MARK: - Migration

    private static let format = "2"
    private let migrationLock = NSLock()

    /// Brings a repository from before branches were real up to date: links each commit to the
    /// one before it, points every branch at the newest commit (they all shared one history) and
    /// turns the single sync marker into one per branch.
    private func migrateIfNeeded(_ root: URL) {
        let formatFile = root.appendingPathComponent(".git/format")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path), !fm.fileExists(atPath: formatFile.path) else { return }
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !fm.fileExists(atPath: formatFile.path) else { return }

        var log = readLog(root)
        if !log.contains(where: { $0["parent"] != nil }) {
            for i in log.indices where i + 1 < log.count {
                log[i]["parent"] = log[i + 1]["hash"]
            }
        }
        let known = Set(log.compactMap { $0["hash"] as? String })
        let oldTop = log.first?["hash"] as? String
        var top = oldTop

        // A pull in older builds could change the snapshot without a commit; record it as one, so
        // switching branches and back doesn't bring the old files back.
        let indexFile = root.appendingPathComponent(".git/index.json")
        if let data = try? Data(contentsOf: indexFile),
           let index = try? JSONDecoder().decode([String: String].self, from: data),
           index.values.allSatisfy(Self.isBlobSHA),
           let oldTop, let tree = log.first?["tree"] as? [String: String], tree != index {
            let hash = String(UUID().uuidString.prefix(8).lowercased())
            log.insert([
                "hash": hash, "author": "GitHub", "timestamp": Date().timeIntervalSince1970,
                "message": "Pulled from GitHub", "tree": index, "parent": oldTop, "pulled": true,
            ], at: 0)
            top = hash
        }
        try? writeCommitLog(log, in: root)

        let headsDir = root.appendingPathComponent(".git/refs/heads")
        var names = Set(branchNames(in: headsDir))
        names.insert(currentBranch(in: root))
        var synced: String?
        if let data = try? Data(contentsOf: root.appendingPathComponent(".git/pushed.json")),
           let dict = try? JSONDecoder().decode([String: String].self, from: data), let commit = dict["commit"], known.contains(commit) {
            synced = commit
        }
        for name in names {
            // Older builds wrote the branch's own name into its ref file.
            let ref = readRef(refURL(name, in: root))
            if ref == nil || !known.contains(ref!) || ref == oldTop {
                try? writeRef(top, to: refURL(name, in: root))
            }
            if let synced { try? writeRef(synced, to: upstreamURL(name, in: root)) }
        }
        try? fm.removeItem(at: root.appendingPathComponent(".git/pushed.json"))
        try? Self.format.write(to: formatFile, atomically: true, encoding: .utf8)
    }

    private func branchNames(in headsDir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: headsDir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = headsDir.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base) { out.append(String(path.dropFirst(base.count))) }
        }
        return out
    }

    // MARK: - Branches

    func branches(in url: URL) -> [String] {
        guard isGitRepo(at: url) else { return ["main"] }
        migrateIfNeeded(url)
        var names = Set(branchNames(in: url.appendingPathComponent(".git/refs/heads")))
        names.insert(currentBranch(in: url))
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Git's branch name rules, with spaces turned into dashes as VS Code does.
    func validBranchName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        let forbidden = Set("~^:?*[\\")
        let invalid = name.isEmpty || name == "@" || name.hasPrefix("-") || name.hasPrefix("/") || name.hasSuffix("/")
            || name.hasSuffix(".") || name.hasSuffix(".lock") || name.contains("..") || name.contains("//") || name.contains("@{")
            || name.contains { forbidden.contains($0) || $0.isWhitespace || ($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
            || name.split(separator: "/").contains { $0.hasPrefix(".") }
        if invalid { throw gitError("'\(name)' isn't a valid branch name.") }
        return name
    }

    private func branchExists(_ name: String, in url: URL) -> Bool {
        FileManager.default.fileExists(atPath: refURL(name, in: url).path) || name == currentBranch(in: url)
    }

    /// Creates a branch at `from` (a commit; HEAD when nil) and, if asked, switches to it.
    func createBranch(_ rawName: String, from: String? = nil, checkout: Bool = true, in url: URL) throws {
        if !isGitRepo(at: url) { try initRepo(at: url) }
        let name = try validBranchName(rawName)
        guard !branchExists(name, in: url) else { throw gitError("A branch named '\(name)' already exists.") }
        let start = from ?? headTip(in: url)
        if !checkout {
            try setTip(start, of: name, in: url)
        } else if start == headTip(in: url) {
            // Same commit: only HEAD moves, and every change comes along.
            try setTip(start, of: name, in: url)
            try setHead(name, in: url)
        } else {
            try setTip(start, of: name, in: url)
            do {
                try self.checkout(name, in: url)
            } catch {
                try? FileManager.default.removeItem(at: refURL(name, in: url))
                throw error
            }
        }
    }

    /// Error code for checkouts that would overwrite local changes; `userInfo["paths"]` lists them.
    static let checkoutConflictCode = 1001

    /// Switches to `branch`, rewriting only the files that differ between the two branches.
    /// Changes to other files come along. If a changed file would be overwritten, nothing happens
    /// and the error lists them, unless `force` throws those changes away.
    func checkout(_ branch: String, force: Bool = false, in url: URL) throws {
        guard isGitRepo(at: url) else { return }
        let current = currentBranch(in: url)
        guard branch != current else { return }
        guard branchExists(branch, in: url) else { throw gitError("There's no branch named '\(branch)'.") }
        guard mergeHead(in: url) == nil else { throw gitError("Finish or abort the merge before switching branches.") }

        let records = byHash(commitLog(in: url))
        let head = loadIndex(in: url)
        let target: [String: String]
        if let tipHash = tip(of: branch, in: url) {
            guard let tree = records[tipHash]?["tree"] as? [String: String] else {
                throw gitError("'\(branch)' was made by an older version of Mobile Studio and has no file snapshot to switch to.")
            }
            target = tree
        } else {
            target = head   // a branch with no commits yet starts from the current files
        }

        let status = self.status(in: url)
        let dirty = Set(status.changedFiles.map(\.path) + status.stagedFiles.map(\.path))
        let differing = Set(head.keys).union(target.keys).filter { head[$0] != target[$0] }
        let conflicts = dirty.intersection(differing).sorted()
        if !conflicts.isEmpty && !force {
            throw NSError(domain: "GitManager", code: Self.checkoutConflictCode, userInfo: [
                NSLocalizedDescriptionKey: "Your local changes to these files would be overwritten by checkout: \(conflicts.joined(separator: ", ")). Commit or stash them first.",
                "paths": conflicts,
            ])
        }

        // Every path that differs is rewritten. Unchanged ones match HEAD already; changed ones in
        // the way only get here when forced, and their staged copies go too.
        var staged = loadStaged(in: url)
        for path in conflicts { staged[path] = nil }
        try applyTree(from: head, to: target, in: url)
        try saveIndex(target, in: url)
        try saveStaged(staged, in: url)
        try setHead(branch, in: url)
    }

    func deleteBranch(_ name: String, force: Bool = false, in url: URL) throws {
        guard name != currentBranch(in: url) else { throw gitError("You can't delete the branch you're on. Switch to another branch first.") }
        guard branchExists(name, in: url) else { return }
        if !force {
            let records = byHash(commitLog(in: url))
            var elsewhere = Set<String>()
            for other in branches(in: url) where other != name {
                elsewhere.formUnion(ancestors(of: tip(of: other, in: url), in: records))
            }
            let unmerged = ancestors(of: tip(of: name, in: url), in: records).subtracting(elsewhere)
                .filter { records[$0]?["github"] == nil && $0 != upstream(of: name, in: url) }
            if !unmerged.isEmpty {
                throw gitError("The branch '\(name)' isn't fully merged and its commits aren't on GitHub.", code: 409)
            }
        }
        try? FileManager.default.removeItem(at: refURL(name, in: url))
        try? FileManager.default.removeItem(at: upstreamURL(name, in: url))
    }

    func renameBranch(_ old: String, to rawName: String, in url: URL) throws {
        let name = try validBranchName(rawName)
        guard name != old else { return }
        guard !branchExists(name, in: url) else { throw gitError("A branch named '\(name)' already exists.") }
        try setTip(tip(of: old, in: url), of: name, in: url)
        try? FileManager.default.removeItem(at: refURL(old, in: url))
        // The GitHub branch keeps its old name, so the new name starts unpublished.
        try? FileManager.default.removeItem(at: upstreamURL(old, in: url))
        if currentBranch(in: url) == old { try setHead(name, in: url) }
    }

    // MARK: - Staging
    //
    // .git/staged.json maps path -> blob id of the staged copy ("" stages a deletion). The staged
    // copy is stored in objects when it's staged, so later edits to the file don't change it.

    private func loadStaged(in root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".git/staged.json")),
              let staged = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return staged
    }

    private func saveStaged(_ staged: [String: String], in root: URL) throws {
        let file = root.appendingPathComponent(".git/staged.json")
        if staged.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try JSONEncoder().encode(staged).write(to: file)
        }
        indexChanged()
    }

    /// The snapshot the next commit would record: the last commit with staged changes on top.
    private func indexTree(in root: URL) -> [String: String] {
        var tree = loadIndex(in: root)
        for (path, sha) in loadStaged(in: root) {
            tree[path] = sha.isEmpty ? nil : sha
        }
        return tree
    }

    func stage(_ paths: [String], in url: URL) throws {
        if !isGitRepo(at: url) { try initRepo(at: url) }
        let head = loadIndex(in: url)
        let working = workingTree(in: url)
        let conflicts = Set(mergeConflictPaths(in: url))
        var staged = loadStaged(in: url)
        for path in paths {
            if let sha = working[path] {
                try storeObject(copying: url.appendingPathComponent(path), sha: sha, in: url)
                // A resolved conflict stays staged even if it ends up matching HEAD.
                staged[path] = head[path] == sha && !conflicts.contains(path) ? nil : sha
            } else {
                staged[path] = head[path] == nil && !conflicts.contains(path) ? nil : ""
            }
        }
        try saveStaged(staged, in: url)
    }

    func unstage(_ paths: [String], in url: URL) throws {
        var staged = loadStaged(in: url)
        for path in paths { staged[path] = nil }
        try saveStaged(staged, in: url)
    }

    func stageAll(in url: URL) throws {
        let status = self.status(in: url)
        try stage(status.changedFiles.map(\.path) + status.mergeConflicts.map(\.path), in: url)
    }

    func unstageAll(in url: URL) throws {
        try saveStaged([:], in: url)
    }

    // MARK: - Status & Inspection

    func status(in url: URL) -> GitStatus {
        guard isGitRepo(at: url) else { return GitStatus() }
        migrateIfNeeded(url)
        let head = loadIndex(in: url)
        let index = indexTree(in: url)
        let staged = diff(from: head, to: index).map {
            GitChangedFile(path: $0.path, status: $0.status == .untracked ? .added : $0.status)
        }
        let conflicts = Set(mergeConflictPaths(in: url)).subtracting(loadStaged(in: url).keys)
        let branch = currentBranch(in: url)
        return GitStatus(
            stagedFiles: staged,
            changedFiles: diff(from: index, to: workingTree(in: url)).filter { !conflicts.contains($0.path) },
            mergeConflicts: conflicts.sorted().map { GitChangedFile(path: $0, status: .conflicted) },
            currentBranch: branch,
            aheadCount: unpushedCommits(in: url).filter { $0["pulled"] as? Bool != true }.count,
            remoteURL: getRemoteURL(in: url),
            hasUpstream: upstream(of: branch, in: url) != nil,
            mergingBranch: mergeHead(in: url) == nil ? nil : (readRef(url.appendingPathComponent(".git/MERGE_BRANCH")) ?? "branch"),
            stashCount: loadStashes(in: url).count
        )
    }

    /// The text of a file as of `version`, or nil when it didn't exist then or isn't text.
    func text(of path: String, at version: GitFileVersion, in url: URL) -> String? {
        let tree: [String: String]?
        switch version {
        case .head: tree = loadIndex(in: url)
        case .index: tree = indexTree(in: url)
        case .commit(let id): tree = snapshot(of: id, in: url)
        case .parent(let id): tree = parentSnapshot(of: id, in: url)
        }
        return objectText(tree?[path], in: url)
    }

    /// Files a commit changed, against the commit before it. Empty for commits without a snapshot.
    func changes(inCommit id: String, in url: URL) -> [GitChangedFile] {
        guard let tree = snapshot(of: id, in: url) else { return [] }
        return diff(from: parentSnapshot(of: id, in: url) ?? [:], to: tree).map {
            GitChangedFile(path: $0.path, status: $0.status == .untracked ? .added : $0.status)
        }
    }

    /// The current branch's history, newest first (following first parents, as VS Code's graph does).
    func history(in url: URL, limit: Int = 500) -> [GitCommit] {
        guard isGitRepo(at: url) else { return [] }
        let records = byHash(commitLog(in: url))
        let branch = currentBranch(in: url)
        let outgoing = Set(unpushedCommits(in: url).compactMap { $0["hash"] as? String })
        let synced = pushedCommit(in: url)
        var labels: [String: [String]] = [:]
        for other in branches(in: url) where other != branch {
            if let tipHash = tip(of: other, in: url) { labels[tipHash, default: []].append(other) }
        }
        var out: [GitCommit] = []
        var seen = Set<String>()
        var next = tip(of: branch, in: url)
        while let hash = next, let record = records[hash], !seen.contains(hash), out.count < limit {
            seen.insert(hash)
            if let author = record["author"] as? String, let ts = record["timestamp"] as? TimeInterval,
               let message = record["message"] as? String {
                out.append(GitCommit(id: hash, author: author, date: Date(timeIntervalSince1970: ts), message: message,
                                     isOutgoing: outgoing.contains(hash), isSynced: hash == synced,
                                     hasSnapshot: record["tree"] is [String: String], isMerge: record["parent2"] != nil,
                                     branches: labels[hash] ?? []))
            }
            next = record["parent"] as? String
        }
        return out
    }

    // MARK: - Discard Changes

    /// Puts a file back the way it's staged (or committed, if not staged). Untracked files are deleted.
    func discardChanges(for path: String, in url: URL) throws {
        try writeFile(path, sha: indexTree(in: url)[path], in: url)
    }

    func discardAll(in url: URL) throws {
        for item in status(in: url).changedFiles {
            try discardChanges(for: item.path, in: url)
        }
    }

    // MARK: - Commit

    /// Commits the staged changes, or every change when `all` is set.
    /// `amend` replaces the last commit instead (only before it's pushed); an empty message keeps its message.
    @discardableResult
    func commit(message: String, all: Bool = false, amend: Bool = false, author: String? = nil, in url: URL) throws -> GitCommit {
        var message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isGitRepo(at: url) {
            try initRepo(at: url)
        }
        var commits = commitLog(in: url)
        let records = byHash(commits)
        let branch = currentBranch(in: url)
        let tipHash = tip(of: branch, in: url)
        let merging = mergeHead(in: url)
        var parent = tipHash
        if amend {
            guard let tipHash, let last = records[tipHash], unpushedCommits(in: url).first?["hash"] as? String == tipHash else {
                throw gitError("Only a commit that hasn't been pushed can be amended.")
            }
            guard merging == nil else { throw gitError("Finish the merge before amending.") }
            if message.isEmpty { message = last["message"] as? String ?? "" }
            parent = last["parent"] as? String
        }
        if message.isEmpty, merging != nil { message = readRef(url.appendingPathComponent(".git/MERGE_MSG")) ?? "" }
        guard !message.isEmpty else { throw gitError("Enter a commit message first.") }

        if all {
            try stage(status(in: url).changedFiles.map(\.path) + mergeConflictPaths(in: url), in: url)
        }
        if merging != nil {
            let unresolved = Set(mergeConflictPaths(in: url)).subtracting(loadStaged(in: url).keys)
            guard unresolved.isEmpty else {
                throw gitError("Resolve the conflicts in \(unresolved.sorted().joined(separator: ", ")) and stage them before committing the merge.")
            }
            let index = indexTree(in: url)
            let marked = mergeConflictPaths(in: url).filter { objectText(index[$0], in: url)?.contains("<<<<<<<") == true }
            guard marked.isEmpty else {
                throw gitError("\(marked.joined(separator: ", ")) still \(marked.count == 1 ? "has" : "have") conflict markers (<<<<<<<). Edit them, then stage again.")
            }
        }
        let tree = indexTree(in: url)
        if !amend && merging == nil && tree == loadIndex(in: url) {
            throw gitError(all ? "Nothing to commit. No files have changed since the last commit."
                               : "There are no staged changes to commit.")
        }

        let finalAuthor = author ?? GitAccountManager.shared.currentUser?.name ?? GitAccountManager.shared.currentUser?.login ?? "Mobile Studio Developer"
        let hash = UUID().uuidString.prefix(8).lowercased()
        let commit = GitCommit(id: String(hash), author: finalAuthor, date: Date(), message: message,
                               isOutgoing: true, hasSnapshot: true, isMerge: merging != nil)
        var record: Record = [
            "hash": commit.id,
            "author": commit.author,
            "timestamp": commit.date.timeIntervalSince1970,
            "message": commit.message,
            "tree": tree,
        ]
        if let parent { record["parent"] = parent }
        if let merging { record["parent2"] = merging }
        if amend, let tipHash, !isReferenced(tipHash, except: branch, in: url) {
            commits.removeAll { $0["hash"] as? String == tipHash }
        }
        commits.insert(record, at: 0)
        try writeCommitLog(commits, in: url)
        try saveIndex(tree, in: url)
        try saveStaged([:], in: url)
        try setTip(commit.id, of: branch, in: url)
        if merging != nil { clearMergeState(in: url) }
        return commit
    }

    /// Another branch, or a stash, still points at this commit.
    private func isReferenced(_ hash: String, except branch: String, in url: URL) -> Bool {
        branches(in: url).contains { $0 != branch && tip(of: $0, in: url) == hash }
    }

    /// Takes back the last commit (only before it's pushed). Its changes go back to being staged,
    /// as `git reset --soft HEAD~` does. Returns its message so it can be edited and committed again.
    func undoLastCommit(in url: URL) throws -> String {
        var commits = commitLog(in: url)
        let records = byHash(commits)
        let branch = currentBranch(in: url)
        guard let hash = tip(of: branch, in: url), let last = records[hash],
              unpushedCommits(in: url).first?["hash"] as? String == hash,
              let tree = last["tree"] as? [String: String] else {
            throw gitError("Only a commit that hasn't been pushed can be undone.")
        }
        let parentHash = last["parent"] as? String
        let parent: [String: String]? = parentHash.map { records[$0]?["tree"] as? [String: String] } ?? [:]
        guard let parent else { throw gitError("The commit before this one is from an older version of Mobile Studio, so this one can't be undone.") }

        var staged = loadStaged(in: url)
        for path in Set(tree.keys).union(parent.keys) where tree[path] != parent[path] && staged[path] == nil {
            staged[path] = tree[path] ?? ""
        }
        try saveIndex(parent, in: url)
        try saveStaged(staged, in: url)
        try setTip(parentHash, of: branch, in: url)
        if !isReferenced(hash, except: branch, in: url) {
            commits.removeAll { $0["hash"] as? String == hash }
            try writeCommitLog(commits, in: url)
        }
        return last["message"] as? String ?? ""
    }

    // MARK: - Stash
    //
    // stash.json, newest first: each entry keeps HEAD's snapshot at the time, the staged map and
    // the working copy of every changed path ("" = deleted), with contents in objects.

    private func loadStashes(in url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(".git/stash.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Record] else { return [] }
        return list
    }

    private func saveStashes(_ list: [Record], in url: URL) throws {
        let file = url.appendingPathComponent(".git/stash.json")
        if list.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try JSONSerialization.data(withJSONObject: list, options: .prettyPrinted).write(to: file)
        }
    }

    func stashes(in url: URL) -> [GitStash] {
        loadStashes(in: url).enumerated().map { i, entry in
            GitStash(index: i, message: entry["message"] as? String ?? "WIP", branch: entry["branch"] as? String ?? "",
                     date: Date(timeIntervalSince1970: entry["timestamp"] as? TimeInterval ?? 0))
        }
    }

    /// Saves every staged and unstaged change (untracked files too) and puts the files back to HEAD.
    func stash(message: String = "", in url: URL) throws {
        guard mergeHead(in: url) == nil else { throw gitError("Finish or abort the merge before stashing.") }
        let status = self.status(in: url)
        guard !status.isClean else { throw gitError("There are no local changes to stash.") }
        let head = loadIndex(in: url)
        let working = workingTree(in: url)
        let staged = loadStaged(in: url)
        var saved: [String: String] = [:]
        for path in Set(status.changedFiles.map(\.path)).union(staged.keys) {
            if let sha = working[path] {
                try storeObject(copying: url.appendingPathComponent(path), sha: sha, in: url)
                saved[path] = sha
            } else {
                saved[path] = ""
            }
        }
        let branch = currentBranch(in: url)
        let tipMessage = headTip(in: url).flatMap { byHash(commitLog(in: url))[$0]?["message"] as? String } ?? ""
        let title = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = loadStashes(in: url)
        list.insert([
            "message": title.isEmpty ? "WIP on \(branch): \(tipMessage.components(separatedBy: .newlines).first ?? "")" : "On \(branch): \(title)",
            "branch": branch,
            "timestamp": Date().timeIntervalSince1970,
            "head": head,
            "staged": staged,
            "working": saved,
        ], at: 0)
        try saveStashes(list, in: url)
        for path in saved.keys { try writeFile(path, sha: head[path], in: url) }
        try saveStaged([:], in: url)
    }

    /// Puts a stash's changes back. Stops before changing anything if a file it touches has
    /// changed here, or differs on this branch from where the stash was made. `drop` is pop.
    func applyStash(_ index: Int = 0, drop: Bool, in url: URL) throws {
        var list = loadStashes(in: url)
        guard list.indices.contains(index) else { throw gitError("There's no stash to apply.") }
        let entry = list[index]
        let saved = entry["working"] as? [String: String] ?? [:]
        let stashHead = entry["head"] as? [String: String] ?? [:]
        let stashStaged = entry["staged"] as? [String: String] ?? [:]
        let head = loadIndex(in: url)
        let staging = indexTree(in: url)
        let working = workingTree(in: url)
        var conflicts: [String] = []
        for (path, sha) in saved {
            let target = sha.isEmpty ? nil : sha
            if working[path] == target { continue }
            if working[path] != staging[path] || head[path] != stashHead[path] { conflicts.append(path) }
        }
        guard conflicts.isEmpty else {
            throw gitError("The stash changes \(conflicts.sorted().joined(separator: ", ")), which \(conflicts.count == 1 ? "has" : "have") also changed here. Commit or discard those changes first.")
        }
        for (path, sha) in saved { try writeFile(path, sha: sha.isEmpty ? nil : sha, in: url) }
        var staged = loadStaged(in: url)
        for (path, sha) in stashStaged where head[path] == stashHead[path] { staged[path] = sha }
        try saveStaged(staged, in: url)
        if drop {
            list.remove(at: index)
            try saveStashes(list, in: url)
        }
    }

    func dropStash(_ index: Int, in url: URL) throws {
        var list = loadStashes(in: url)
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        try saveStashes(list, in: url)
    }

    func dropAllStashes(in url: URL) throws {
        try saveStashes([], in: url)
    }

    // MARK: - Merge

    private func mergeHead(in url: URL) -> String? {
        guard let ref = readRef(url.appendingPathComponent(".git/MERGE_HEAD")), !ref.isEmpty else { return nil }
        return ref
    }

    private func mergeConflictPaths(in url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(".git/MERGE_CONFLICTS")),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// Conflicted files that haven't been staged (marked resolved) yet.
    func unresolvedConflicts(in url: URL) -> [String] {
        Set(mergeConflictPaths(in: url)).subtracting(loadStaged(in: url).keys).sorted()
    }

    /// The message the merge commit will get.
    func mergeMessage(in url: URL) -> String? {
        mergeHead(in: url) == nil ? nil : readRef(url.appendingPathComponent(".git/MERGE_MSG"))
    }

    private func clearMergeState(in url: URL) {
        for name in ["MERGE_HEAD", "MERGE_MSG", "MERGE_BRANCH", "MERGE_CONFLICTS"] {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(".git/\(name)"))
        }
    }

    /// Merges `branch` into the current branch. Needs a clean working tree. Fast-forwards when it
    /// can; otherwise combines the files line by line and commits, or leaves conflict markers in
    /// the files that clash (stage them once resolved, then commit, or abort).
    func merge(_ branch: String, in url: URL) throws -> GitMergeResult {
        guard mergeHead(in: url) == nil else { throw gitError("A merge is already in progress. Commit or abort it first.") }
        let current = currentBranch(in: url)
        guard branch != current else { return .upToDate }
        guard status(in: url).isClean else { throw gitError("Commit or stash your changes before merging.") }
        let records = byHash(commitLog(in: url))
        guard let theirs = tip(of: branch, in: url) else { return .upToDate }
        let ours = tip(of: current, in: url)
        let ourAncestors = ancestors(of: ours, in: records)
        if ourAncestors.contains(theirs) { return .upToDate }
        guard let theirTree = records[theirs]?["tree"] as? [String: String] else {
            throw gitError("'\(branch)' was made by an older version of Mobile Studio and can't be merged.")
        }
        let head = loadIndex(in: url)

        if ours == nil || ancestors(of: theirs, in: records).contains(ours!) {
            try applyTree(from: head, to: theirTree, in: url)
            try saveIndex(theirTree, in: url)
            try setTip(theirs, of: current, in: url)
            return .fastForward
        }

        // The nearest commit both branches share.
        var base: String?
        var queue = [theirs]
        var seen = Set<String>()
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !seen.contains(next) else { continue }
            seen.insert(next)
            if ourAncestors.contains(next) { base = next; break }
            if let p = records[next]?["parent"] as? String { queue.append(p) }
            if let p = records[next]?["parent2"] as? String { queue.append(p) }
        }
        let baseTree = base.flatMap { records[$0]?["tree"] as? [String: String] } ?? [:]

        var result = head
        var conflicts: [String] = []
        var conflictText: [String: String] = [:]
        for path in Set(baseTree.keys).union(head.keys).union(theirTree.keys) {
            let b = baseTree[path], o = head[path], t = theirTree[path]
            if o == t || t == b { continue }
            if o == b { result[path] = t; continue }
            // Both sides changed this file.
            if let o, let t, let ourText = objectText(o, in: url), let theirText = objectText(t, in: url),
               let baseText = b == nil ? "" : objectText(b, in: url),
               let merged = LineMerge.merge(base: baseText, ours: ourText, theirs: theirText, theirLabel: branch) {
                if merged.conflicts == 0 {
                    result[path] = try storeObject(Data(merged.text.utf8), in: url)
                } else {
                    conflicts.append(path)
                    conflictText[path] = merged.text
                }
            } else {
                // Deleted on one side and changed on the other, or not text: keep ours for the user to decide.
                conflicts.append(path)
            }
        }

        try applyTree(from: head, to: result, in: url)
        for (path, text) in conflictText {
            let file = url.appendingPathComponent(path)
            try Data(text.utf8).write(to: file)
            forgetHash(file)
        }
        let message = "Merge branch '\(branch)' into \(current)"
        if conflicts.isEmpty {
            var log = commitLog(in: url)
            let hash = String(UUID().uuidString.prefix(8).lowercased())
            var record: Record = [
                "hash": hash,
                "author": GitAccountManager.shared.currentUser?.name ?? GitAccountManager.shared.currentUser?.login ?? "Mobile Studio Developer",
                "timestamp": Date().timeIntervalSince1970, "message": message, "tree": result, "parent2": theirs,
            ]
            if let ours { record["parent"] = ours }
            log.insert(record, at: 0)
            try writeCommitLog(log, in: url)
            try saveIndex(result, in: url)
            try setTip(hash, of: current, in: url)
            return .merged
        }

        // Stage what merged cleanly, as git does; the conflicts wait for the user.
        var staged: [String: String] = [:]
        for path in Set(head.keys).union(result.keys) where head[path] != result[path] && !conflicts.contains(path) {
            staged[path] = result[path] ?? ""
        }
        try saveStaged(staged, in: url)
        try writeRef(theirs, to: url.appendingPathComponent(".git/MERGE_HEAD"))
        try writeRef(message, to: url.appendingPathComponent(".git/MERGE_MSG"))
        try writeRef(branch, to: url.appendingPathComponent(".git/MERGE_BRANCH"))
        try JSONEncoder().encode(conflicts.sorted()).write(to: url.appendingPathComponent(".git/MERGE_CONFLICTS"))
        return .conflicts(conflicts.sorted())
    }

    /// Puts every file back the way it was before the merge.
    func abortMerge(in url: URL) throws {
        guard mergeHead(in: url) != nil else { return }
        let head = loadIndex(in: url)
        let working = workingTree(in: url)
        for path in Set(head.keys).union(working.keys) where head[path] != working[path] {
            try writeFile(path, sha: head[path], in: url)
        }
        try saveStaged([:], in: url)
        clearMergeState(in: url)
    }

    // MARK: - Remote Clone

    func clone(from urlString: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            completion(.failure(NSError(domain: "GitManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Git URL"])))
            return
        }

        var repoName = url.deletingPathExtension().lastPathComponent
        if repoName.isEmpty { repoName = "cloned-project" }

        var request = URLRequest(url: url)
        if url.host == "github.com" {
            let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if pathComponents.count >= 2 {
                let owner = pathComponents[0]
                let repo = pathComponents[1].replacingOccurrences(of: ".git", with: "")
                repoName = repo
                // The zipball endpoint serves the default branch (main or master) and private repos with a token.
                request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/zipball")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                if let token = GitAccountManager.shared.token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            }
        }

        // Never overwrite an existing project with the same name.
        let targetDir = ProjectStore.shared.uniqueProjectURL(named: repoName)

        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let message = http.statusCode == 404
                    ? "Repository not found. Check the URL, or sign in to GitHub for private repositories."
                    : "Download failed (HTTP \(http.statusCode))."
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "GitManager", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])))
                }
                return
            }

            guard let tempURL else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "GitManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed"])))
                }
                return
            }

            do {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

                // Unpack archive
                var extractError: NSError?
                let ok = dc_extract_love_archive(tempURL.path, targetDir.path, &extractError)
                if !ok {
                    throw extractError ?? NSError(domain: "GitManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Archive extraction failed"])
                }

                // If contents are nested in a single folder (e.g. repo-main/), flatten them
                let contents = try FileManager.default.contentsOfDirectory(atPath: targetDir.path)
                if contents.count == 1, let sub = contents.first {
                    let subURL = targetDir.appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: subURL.path, isDirectory: &isDir) && isDir.boolValue {
                        let subItems = try FileManager.default.contentsOfDirectory(atPath: subURL.path)
                        for item in subItems {
                            let src = subURL.appendingPathComponent(item)
                            let dst = targetDir.appendingPathComponent(item)
                            try? FileManager.default.moveItem(at: src, to: dst)
                        }
                        try? FileManager.default.removeItem(at: subURL)
                    }
                }

                // Initialize local tracking & record remote origin
                try? self?.initRepo(at: targetDir)
                self?.setRemoteURL(urlString, in: targetDir)
                if let commit = try? self?.commit(message: "Initial commit from clone (\(urlString))", all: true, in: targetDir) {
                    // This snapshot is what GitHub has, so it never needs pushing.
                    self?.markPushed(commit.id, in: targetDir)
                }

                // The caller opens the project on the main thread.
                DispatchQueue.main.async {
                    completion(.success(targetDir))
                }
            } catch {
                try? FileManager.default.removeItem(at: targetDir)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
    }

    // MARK: - Remote Push & Pull via GitHub API

    private func githubAPI(for url: URL) throws -> GitHubAPI {
        guard let token = GitAccountManager.shared.token, !token.isEmpty else {
            throw gitError("Please sign in to GitHub first to sync changes.", code: 401)
        }
        guard let remote = getRemoteURL(in: url),
              let remoteURL = URL(string: remote),
              let host = remoteURL.host, host.contains("github.com") else {
            throw gitError("No valid GitHub remote configured for this project.")
        }
        let components = remoteURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2 else {
            throw gitError("Invalid GitHub repository URL path.")
        }
        return GitHubAPI(owner: components[0],
                         repo: components[1].replacingOccurrences(of: ".git", with: ""),
                         token: token)
    }

    /// Hidden files (.gitignore, .github/...) aren't shown or tracked locally, so syncing leaves them alone.
    private static func visible(_ files: [String: String]) -> [String: String] {
        files.filter { !$0.key.split(separator: "/").contains { $0.hasPrefix(".") } }
    }

    /// A GitHub tree's files and modes.
    private struct RemoteTree {
        let sha: String
        let files: [String: String]
        let modes: [String: String]
        var visibleFiles: [String: String] { GitManager.visible(files) }
    }

    private func fetchTree(ofCommit commitSHA: String, api: GitHubAPI) async throws -> RemoteTree {
        let commit = try await api.call("git/commits/\(commitSHA)")
        guard let treeSHA = (commit["tree"] as? [String: Any])?["sha"] as? String else {
            throw gitError("GitHub returned an unexpected commit.")
        }
        let tree = try await api.call("git/trees/\(treeSHA)?recursive=1")
        if tree["truncated"] as? Bool == true {
            throw gitError("This repository is too large to sync from Mobile Studio.")
        }
        var files: [String: String] = [:]
        var modes: [String: String] = [:]
        for entry in tree["tree"] as? [[String: Any]] ?? [] {
            guard entry["type"] as? String == "blob",
                  let path = entry["path"] as? String, let sha = entry["sha"] as? String else { continue }
            files[path] = sha
            modes[path] = entry["mode"] as? String
        }
        return RemoteTree(sha: treeSHA, files: files, modes: modes)
    }

    /// The branch on GitHub that this project syncs with, and the files at its head.
    private struct RemoteHead {
        let branch: String
        let exists: Bool        // false: the local branch isn't on GitHub yet; head is the default branch
        let head: String
        let tree: RemoteTree
    }

    private func fetchRemote(in root: URL, api: GitHubAPI) async throws -> RemoteHead {
        var branch = currentBranch(in: root)
        var exists = true
        let head: String
        do {
            head = try await api.refSHA(branch)
        } catch let error as NSError where error.code == 404 {
            let info = try await api.call("")
            let defaultBranch = info["default_branch"] as? String ?? "main"
            if branch == "main" && defaultBranch != "main" && upstream(of: "main", in: root) != nil
                && !branchExists(defaultBranch, in: root) {
                // Clones start on "main"; the repository's default branch is what was cloned.
                let synced = upstream(of: "main", in: root)
                try renameBranch("main", to: defaultBranch, in: root)
                try writeRef(synced, to: upstreamURL(defaultBranch, in: root))
                branch = defaultBranch
            } else {
                exists = false
            }
            head = try await api.refSHA(defaultBranch)
        }
        return RemoteHead(branch: branch, exists: exists, head: head, tree: try await fetchTree(ofCommit: head, api: api))
    }

    /// The snapshot GitHub had at the branch's last push or pull, if this project has one.
    private func syncedTree(in url: URL) -> [String: String]? {
        guard let pushed = pushedCommit(in: url) else { return nil }
        return snapshot(of: pushed, in: url)
    }

    /// Pushes each unpushed local commit to GitHub as one commit with the user's own message.
    /// Only files that changed are uploaded. Succeeds with the number of commits pushed (0 = up to date).
    func push(in url: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        let api: GitHubAPI
        do { api = try githubAPI(for: url) } catch {
            completion(.failure(error))
            return
        }
        guard mergeHead(in: url) == nil else {
            completion(.failure(gitError("Finish the merge before pushing.")))
            return
        }
        guard status(in: url).isClean else {
            completion(.failure(gitError("You have uncommitted changes. Enter a commit message and commit them before syncing.")))
            return
        }

        let unpushed = unpushedCommits(in: url)
        let pending = Array(unpushed.reversed())
        let records = byHash(commitLog(in: url))
        // Where the walk stopped: the commit the pending ones build on.
        let stop = (unpushed.last?["parent"] as? String).flatMap { records[$0] }
            ?? (unpushed.isEmpty ? headTip(in: url).flatMap { records[$0] } : nil)
        let synced = pushedCommit(in: url)
        // Up to date when nothing is new and the branch sits where GitHub had it. A fast-forward to
        // a commit GitHub already has (from another branch) still needs GitHub's branch moved.
        guard !pending.isEmpty || synced == nil || headTip(in: url) != synced else {
            completion(.success(0))
            return
        }
        let base = syncedTree(in: url)

        Task {
            do {
                let count = try await self.pushCommits(pending, stop: stop, base: base, in: url, api: api)
                await MainActor.run { completion(.success(count)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private func pushCommits(_ commits: [Record], stop: Record?, base: [String: String]?, in root: URL, api: GitHubAPI) async throws -> Int {
        let remote = try await fetchRemote(in: root, api: api)

        // What GitHub's branch will be built on, and the local snapshot that matches it.
        var parent: String
        var current: RemoteTree
        var previous: [String: String]
        if let stop, let github = stop["github"] as? String, let stopTree = stop["tree"] as? [String: String],
           !remote.exists || github == remote.head || commits.isEmpty {
            // This branch continues from a commit GitHub already has.
            parent = github
            current = github == remote.head ? remote.tree : try await fetchTree(ofCommit: github, api: api)
            previous = stopTree
        } else {
            parent = remote.head
            current = remote.tree
            previous = base ?? remote.tree.visibleFiles
            if let base, let first = commits.first?["tree"] as? [String: String] {
                // Diff against what we last synced, so files changed only on GitHub aren't reverted.
                let visibleRemote = remote.tree.visibleFiles
                let conflicts = Set(first.keys).union(base.keys).filter { path in
                    first[path] != base[path] && visibleRemote[path] != base[path] && visibleRemote[path] != first[path]
                }
                if !conflicts.isEmpty {
                    throw gitError("These files were also changed on GitHub: \(conflicts.sorted().joined(separator: ", ")). Pull first, or push stops so nothing gets overwritten.", code: 409)
                }
            } else if base == nil && remote.exists && stop?["github"] != nil {
                throw gitError("GitHub has newer commits on \(remote.branch). Pull them before pushing.", code: 409)
            }
        }

        var files = current.files
        var uploaded = Set(files.values)
        var baseTree = current.sha
        var pushedSHAs: [String: String] = [:]
        var pushed = 0
        for commit in commits {
            guard let tree = commit["tree"] as? [String: String], let hash = commit["hash"] as? String,
                  let message = commit["message"] as? String else { continue }
            // Only paths this commit changed, and only where GitHub's copy differs.
            var entries: [[String: Any]] = []
            for (path, sha) in tree where previous[path] != sha && files[path] != sha {
                if !uploaded.contains(sha) {
                    let data = try Data(contentsOf: objectURL(sha, in: root))
                    let blob = try await api.call("git/blobs", method: "POST",
                                                  body: ["content": data.base64EncodedString(), "encoding": "base64"])
                    guard blob["sha"] as? String == sha else { throw gitError("GitHub stored \(path) differently than expected.") }
                    uploaded.insert(sha)
                }
                entries.append(["path": path, "mode": current.modes[path] ?? "100644", "type": "blob", "sha": sha])
            }
            for path in previous.keys where tree[path] == nil && files[path] != nil {
                entries.append(["path": path, "mode": current.modes[path] ?? "100644", "type": "blob", "sha": NSNull()])
            }
            previous = tree
            guard !entries.isEmpty else { continue }

            let newTree = try await api.call("git/trees", method: "POST", body: ["base_tree": baseTree, "tree": entries])
            guard let treeSHA = newTree["sha"] as? String else { throw gitError("GitHub didn't accept the file tree.") }
            let newCommit = try await api.call("git/commits", method: "POST",
                                               body: ["message": message, "tree": treeSHA, "parents": [parent]])
            guard let commitSHA = newCommit["sha"] as? String else { throw gitError("GitHub didn't accept the commit.") }
            for entry in entries {
                guard let path = entry["path"] as? String else { continue }
                files[path] = entry["sha"] as? String
            }
            baseTree = treeSHA
            parent = commitSHA
            pushedSHAs[hash] = commitSHA
            pushed += 1
        }

        if parent != remote.head || !remote.exists {
            if remote.exists {
                _ = try await api.call("git/refs/heads/\(remote.branch)", method: "PATCH", body: ["sha": parent, "force": false])
            } else {
                _ = try await api.call("git/refs", method: "POST", body: ["ref": "refs/heads/\(remote.branch)", "sha": parent])
            }
        }
        let last = commits.last?["hash"] as? String
        let marker = last ?? (stop?["hash"] as? String)
        let finalParent = parent
        let githubSHAs = pushedSHAs
        await MainActor.run {
            // Remember which GitHub commit each local one became, so other branches can build on them.
            var log = self.commitLog(in: root)
            for i in log.indices {
                guard let hash = log[i]["hash"] as? String else { continue }
                if let sha = githubSHAs[hash] { log[i]["github"] = sha }
                if hash == last, log[i]["github"] == nil { log[i]["github"] = finalParent }
            }
            try? self.writeCommitLog(log, in: root)
            if let marker { self.markPushed(marker, in: root) }
        }
        return pushed
    }

    /// Brings files changed on GitHub into the project. Files you've also changed locally stop the
    /// pull before anything is written. Succeeds with the number of files updated (0 = up to date).
    func pull(in url: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        let api: GitHubAPI
        do { api = try githubAPI(for: url) } catch {
            completion(.failure(error))
            return
        }
        guard mergeHead(in: url) == nil else {
            completion(.failure(gitError("Finish the merge before pulling.")))
            return
        }
        Task {
            do {
                let count = try await self.pullChanges(in: url, api: api)
                await MainActor.run { completion(.success(count)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Downloads blobs that aren't in the object store yet, checking each against its id.
    private func download(_ shas: [String: String], in root: URL, api: GitHubAPI) async throws {
        for (path, sha) in shas where !hasObject(sha, in: root) {
            let blob = try await api.call("git/blobs/\(sha)")
            guard let content = blob["content"] as? String,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
                  Self.blobSHA(data) == sha else {
                throw gitError("Couldn't download \(path) from GitHub.")
            }
            try storeObject(data, in: root)
        }
    }

    private func pullChanges(in root: URL, api: GitHubAPI) async throws -> Int {
        let remote = try await fetchRemote(in: root, api: api)
        guard remote.exists else {
            throw gitError("The branch \(remote.branch) isn't on GitHub yet. Publish it first.")
        }
        let theirs = remote.tree.visibleFiles
        let originalIndex = loadIndex(in: root)
        var index = originalIndex
        let base = syncedTree(in: root) ?? index
        let local = workingTree(in: root)

        var updates: [String] = []
        var conflicts: [String] = []
        for path in Set(base.keys).union(theirs.keys) where base[path] != theirs[path] {
            if local[path] == theirs[path] {
                index[path] = theirs[path]          // already the same here
            } else if local[path] == base[path] && index[path] == base[path] {
                updates.append(path)
            } else {
                conflicts.append(path)
            }
        }
        guard conflicts.isEmpty else {
            throw gitError("These files changed both here and on GitHub: \(conflicts.sorted().joined(separator: ", ")). Pull stopped so your work isn't overwritten.", code: 409)
        }

        // Download everything first, so a failed download leaves the project untouched.
        try await download(Dictionary(uniqueKeysWithValues: updates.compactMap { p in theirs[p].map { (p, $0) } }), in: root, api: api)

        for path in updates {
            try writeFile(path, sha: theirs[path], in: root)
            index[path] = theirs[path]
        }
        let staged = loadStaged(in: root)
        try saveIndex(index, in: root)
        // A staged change that now matches the pulled file is no longer a change.
        try saveStaged(staged.filter { index[$0.key] != ($0.value.isEmpty ? nil : $0.value) }, in: root)

        // Keep HEAD's commit in step with the snapshot. With nothing waiting to be pushed, the
        // pulled snapshot is the new sync point.
        let synced = unpushedCommits(in: root).isEmpty
        if index != originalIndex {
            var commits = commitLog(in: root)
            let hash = String(UUID().uuidString.prefix(8).lowercased())
            var record: Record = [
                "hash": hash,
                "author": "GitHub",
                "timestamp": Date().timeIntervalSince1970,
                "message": "Pulled \(remote.branch) from GitHub (\(remote.head.prefix(7)))",
                "tree": index,
            ]
            if let parent = headTip(in: root) { record["parent"] = parent }
            if synced { record["github"] = remote.head } else { record["pulled"] = true }
            commits.insert(record, at: 0)
            try writeCommitLog(commits, in: root)
            try setTip(hash, of: currentBranch(in: root), in: root)
            if synced { markPushed(hash, in: root) }
        }
        return updates.count
    }

    /// Branch names on GitHub.
    func remoteBranches(in url: URL, completion: @escaping (Result<[String], Error>) -> Void) {
        let api: GitHubAPI
        do { api = try githubAPI(for: url) } catch {
            completion(.failure(error))
            return
        }
        Task {
            do {
                let list = try await api.list("branches?per_page=100")
                let names = list.compactMap { $0["name"] as? String }
                await MainActor.run { completion(.success(names)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Creates a local branch from a GitHub branch and switches to it, like checking out origin/<name>.
    func checkoutRemoteBranch(_ name: String, in url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let api: GitHubAPI
        do { api = try githubAPI(for: url) } catch {
            completion(.failure(error))
            return
        }
        guard !branchExists(name, in: url) else {
            completion(Result { try self.checkout(name, in: url) })
            return
        }
        Task {
            do {
                let head = try await api.refSHA(name)
                let info = try await api.call("git/commits/\(head)")
                let tree = try await self.fetchTree(ofCommit: head, api: api)
                let files = tree.visibleFiles
                try await self.download(files, in: url, api: api)
                let message = (info["message"] as? String)?.components(separatedBy: .newlines).first ?? "origin/\(name)"
                let author = (info["author"] as? [String: Any])?["name"] as? String ?? "GitHub"
                await MainActor.run {
                    completion(Result {
                        var log = self.commitLog(in: url)
                        let hash = String(UUID().uuidString.prefix(8).lowercased())
                        log.insert([
                            "hash": hash, "author": author, "timestamp": Date().timeIntervalSince1970,
                            "message": message, "tree": files, "github": head,
                        ], at: 0)
                        try self.writeCommitLog(log, in: url)
                        try self.setTip(hash, of: name, in: url)
                        try self.writeRef(hash, to: self.upstreamURL(name, in: url))
                        try self.checkout(name, in: url)
                    })
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}

/// Three-way line merge (Myers diff + the merge3 algorithm), for merging branches.
enum LineMerge {
    /// Matching runs (aStart, bStart, length) between two line lists, or nil past `maxEdits`.
    static func matchingBlocks(_ a: [Int], _ b: [Int], maxEdits: Int = 2000) -> [(Int, Int, Int)]? {
        let n = a.count, m = b.count
        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = false
        var d = 0
        while d <= limit {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            var k = -d
            while k <= d {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    found = true
                    break
                }
                k += 2
            }
            if found { break }
            d += 1
        }
        guard found else { return nil }

        var pairs: [(Int, Int)] = []
        var x = n, y = m
        var step = trace.count - 1
        while step >= 0 {
            let row = trace[step]
            let k = x - y
            var prevX = 0, prevY = 0
            if step > 0 {
                let prevK = (k == -step || (k != step && row[k - 1 + step] < row[k + 1 + step])) ? k + 1 : k - 1
                prevX = row[prevK + step]
                prevY = prevX - prevK
            }
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                pairs.append((x, y))
            }
            if step > 0 {
                x = prevX
                y = prevY
            }
            step -= 1
        }
        var blocks: [(Int, Int, Int)] = []
        for (i, j) in pairs.reversed() {
            if let last = blocks.last, last.0 + last.2 == i, last.1 + last.2 == j {
                blocks[blocks.count - 1].2 += 1
            } else {
                blocks.append((i, j, 1))
            }
        }
        return blocks
    }

    /// Lines with their "\n" kept, so joining them gives the text back exactly.
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "\n" {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Merges two edits of `base`. Clashing edits are written between git's conflict markers.
    /// Nil when the files are too different to compare.
    static func merge(base: String, ours: String, theirs: String, ourLabel: String = "HEAD", theirLabel: String) -> (text: String, conflicts: Int)? {
        let baseLines = lines(base), ourLines = lines(ours), theirLines = lines(theirs)
        var ids: [String: Int] = [:]
        let id = { (line: String) -> Int in
            if let existing = ids[line] { return existing }
            ids[line] = ids.count
            return ids.count - 1
        }
        let z = baseLines.map(id), a = ourLines.map(id), b = theirLines.map(id)
        guard let am = matchingBlocks(z, a), let bm = matchingBlocks(z, b) else { return nil }

        var sync: [(Int, Int, Int, Int, Int, Int)] = []
        var ia = 0, ib = 0
        while ia < am.count && ib < bm.count {
            let (abase, amatch, alen) = am[ia]
            let (bbase, bmatch, blen) = bm[ib]
            let lo = max(abase, bbase), hi = min(abase + alen, bbase + blen)
            if lo < hi {
                let asub = amatch + (lo - abase), bsub = bmatch + (lo - bbase)
                sync.append((lo, hi, asub, asub + (hi - lo), bsub, bsub + (hi - lo)))
            }
            if abase + alen < bbase + blen { ia += 1 } else { ib += 1 }
        }
        sync.append((z.count, z.count, a.count, a.count, b.count, b.count))

        var out = ""
        var conflicts = 0
        var iz = 0, ja = 0, jb = 0
        let withNewline = { (chunk: ArraySlice<String>) -> String in
            let text = chunk.joined()
            return text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        }
        for (zs, ze, as_, ae, bs, be) in sync {
            if as_ > ja || bs > jb {
                let oursChunk = a[ja..<as_], theirsChunk = b[jb..<bs], baseChunk = z[iz..<zs]
                if Array(oursChunk) == Array(theirsChunk) {
                    out += ourLines[ja..<as_].joined()
                } else {
                    let oursSame = Array(oursChunk) == Array(baseChunk)
                    let theirsSame = Array(theirsChunk) == Array(baseChunk)
                    if oursSame && !theirsSame {
                        out += theirLines[jb..<bs].joined()
                    } else if theirsSame && !oursSame {
                        out += ourLines[ja..<as_].joined()
                    } else {
                        conflicts += 1
                        out += "<<<<<<< \(ourLabel)\n" + withNewline(ourLines[ja..<as_]) + "=======\n"
                            + withNewline(theirLines[jb..<bs]) + ">>>>>>> \(theirLabel)\n"
                    }
                }
            }
            out += baseLines[zs..<ze].joined()
            iz = ze
            ja = ae
            jb = be
        }
        return (out, conflicts)
    }
}

/// Minimal client for the GitHub REST endpoints that push and pull use.
private struct GitHubAPI {
    let owner: String
    let repo: String
    let token: String

    /// Calls repos/{owner}/{repo}/{path}. HTTP errors throw an NSError whose code is the status.
    func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        try await send(path, method: method, body: body) as? [String: Any] ?? [:]
    }

    /// A GET whose response is a JSON array.
    func list(_ path: String) async throws -> [[String: Any]] {
        try await send(path, method: "GET", body: nil) as? [[String: Any]] ?? []
    }

    private func send(_ path: String, method: String, body: [String: Any]?) async throws -> Any? {
        let suffix = path.isEmpty ? "" : "/\(path)"
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)\(suffix)") else {
            throw NSError(domain: "GitHub", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid GitHub path \(path)"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MobileStudio-iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (json as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            let message: String
            switch status {
            case 401: message = "GitHub rejected the sign-in. Sign in again."
            case 403 where method != "GET", 404 where method != "GET": message = "GitHub refused the push (\(detail)). Check you have write access to \(owner)/\(repo)."
            case 409: message = "The GitHub repository is empty or busy (\(detail))."
            case 422 where path.hasPrefix("git/refs"): message = "GitHub has newer commits on this branch. Pull them before pushing."
            default: message = "GitHub error: \(detail)"
            }
            throw NSError(domain: "GitHub", code: status, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return json
    }

    func refSHA(_ branch: String) async throws -> String {
        let ref = try await call("git/ref/heads/\(branch)")
        guard let sha = (ref["object"] as? [String: Any])?["sha"] as? String else {
            throw NSError(domain: "GitHub", code: -1, userInfo: [NSLocalizedDescriptionKey: "GitHub returned an unexpected branch reference."])
        }
        return sha
    }
}
