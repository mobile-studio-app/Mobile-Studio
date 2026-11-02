import Foundation
import Clibgit2

// MARK: - Models

/// The letters VS Code shows beside a changed file.
enum GitFileStatus: String {
    case modified = "M"
    case untracked = "U"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case typeChanged = "T"
    case conflicted = "!"
}

struct GitChangedFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let status: GitFileStatus
    /// Where a renamed file was.
    var oldPath: String? = nil
}

/// A branch, tag or remote branch pointing at a commit, for the Graph.
struct GitRefLabel: Hashable {
    enum Kind { case head, branch, remote, tag }
    let name: String
    let kind: Kind
}

struct GitCommit: Identifiable, Hashable {
    /// The full SHA-1.
    let id: String
    let summary: String
    let message: String
    let author: String
    let email: String
    let date: Date
    let parents: [String]
    var refs: [GitRefLabel] = []

    var shortId: String { String(id.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
}

enum GitRepositoryState {
    case none, merging, reverting, cherryPicking, rebasing, other
}

struct GitStatus {
    /// Staged: the next commit's changes against HEAD.
    var stagedFiles: [GitChangedFile] = []
    /// Not staged: the working files against the index.
    var changedFiles: [GitChangedFile] = []
    var mergeConflicts: [GitChangedFile] = []
    /// The checked-out branch; nil when HEAD is detached.
    var branch: String? = "main"
    /// HEAD's commit (nil before the first one).
    var head: String?
    /// The branch's upstream, like "origin/main".
    var upstream: String?
    var aheadCount = 0
    var behindCount = 0
    var remoteURL: String?
    var state: GitRepositoryState = .none
    /// The branch being merged in, while a merge has conflicts.
    var mergingBranch: String?
    var stashCount = 0

    var isClean: Bool { stagedFiles.isEmpty && changedFiles.isEmpty && mergeConflicts.isEmpty }
    var hasUpstream: Bool { upstream != nil }
    /// The branch, or the short commit HEAD is detached at.
    var currentBranch: String { branch ?? head.map { String($0.prefix(7)) } ?? "HEAD" }
}

struct GitBranch: Hashable {
    /// "main", or "origin/main" for a remote branch.
    let name: String
    let isRemote: Bool
    let isHead: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let tip: String
    let summary: String
    let date: Date
}

struct GitStash {
    let index: Int
    let message: String
}

struct GitTag: Hashable {
    let name: String
    let target: String
}

struct GitRemote: Hashable {
    let name: String
    let url: String
}

enum GitMergeResult {
    case upToDate
    case fastForward
    case merged
    case conflicts([String])
}

/// A version of a file, for diffs.
enum GitRevision {
    case head
    case index
    case commit(String)
    /// The commit's first parent (nothing, for the first commit).
    case parent(of: String)
}

enum GitResetMode {
    case soft, mixed, hard

    var git: git_reset_t {
        switch self {
        case .soft: return GIT_RESET_SOFT
        case .mixed: return GIT_RESET_MIXED
        case .hard: return GIT_RESET_HARD
        }
    }
}

// MARK: - The repository

/// A Git repository through libgit2: real `.git` repositories, so other git tools, GitHub and
/// any HTTPS host work with them. Not thread-safe: open one per thread (opening is cheap).
/// Network calls (fetch, pull, push, clone) block, so they run off the main thread.
final class GitRepository {
    /// Posted (on the main queue) when HEAD or the index changes, so the editor's change markers
    /// compare against the new index.
    static let didChange = Notification.Name("MobileStudioGitDidChange")

    let root: URL
    let pointer: OpaquePointer

    private init(root: URL, pointer: OpaquePointer) {
        self.root = root
        self.pointer = pointer
    }

    deinit { git_repository_free(pointer) }

    /// Whether `url` is a repository's top folder (not a folder inside one).
    static func isRepository(_ url: URL) -> Bool { (try? open(url)) != nil }

    static func open(_ url: URL) throws -> GitRepository {
        _ = Git.ready
        var repo: OpaquePointer?
        try Git.check(git_repository_open_ext(&repo, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil))
        return GitRepository(root: url, pointer: repo!)
    }

    /// `git init`, with `branch` as the first branch.
    @discardableResult
    static func create(at url: URL, branch: String = "main") throws -> GitRepository {
        _ = Git.ready
        var options = git_repository_init_options()
        git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        var repo: OpaquePointer?
        try branch.withCString { name in
            options.initial_head = name
            try Git.check(git_repository_init_ext(&repo, url.path, &options), "Couldn't create the repository")
        }
        notifyChange()
        return GitRepository(root: url, pointer: repo!)
    }

    /// `git clone`: the whole history, and the submodules' (git clone --recursive) unless told
    /// not to. Blocks; `transfer`'s progress is called on this thread.
    @discardableResult
    static func clone(_ remote: String, to url: URL, submodules: Bool = true, transfer: GitTransfer = GitTransfer()) throws -> GitRepository {
        _ = Git.ready
        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        transfer.install(&options.fetch_opts.callbacks)
        var repo: OpaquePointer?
        let rc = git_clone(&repo, remote, url.path, &options)
        guard rc == 0, let repo else { throw transfer.error(rc, "Couldn't clone \(remote)") }
        let cloned = GitRepository(root: url, pointer: repo)
        if submodules { try cloned.updateSubmodules(transfer: transfer) }
        return cloned
    }

    static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    // MARK: Objects

    private func lookupCommit(_ spec: String) throws -> OpaquePointer {
        var object: OpaquePointer?
        try Git.check(git_revparse_single(&object, pointer, spec + "^{commit}"), "There's no commit \(spec)")
        return object!
    }

    private func headCommit() -> OpaquePointer? { try? lookupCommit("HEAD") }

    private func index() throws -> OpaquePointer {
        var index: OpaquePointer?
        try Git.check(git_repository_index(&index, pointer))
        return index!
    }

    private func commitModel(_ commit: OpaquePointer, refs: [String: [GitRefLabel]] = [:]) -> GitCommit {
        let id = Git.hex(git_commit_id(commit))
        let author = git_commit_author(commit)
        let parents = (0..<git_commit_parentcount(commit)).map { Git.hex(git_commit_parent_id(commit, $0)) }
        return GitCommit(id: id, summary: Git.string(git_commit_summary(commit)), message: Git.string(git_commit_message(commit)),
                         author: Git.string(author?.pointee.name), email: Git.string(author?.pointee.email),
                         date: Date(timeIntervalSince1970: TimeInterval(author?.pointee.when.time ?? 0)),
                         parents: parents, refs: refs[id] ?? [])
    }

    /// Who commits: user.name and user.email from the repository's or the global config, else the
    /// GitHub account, else a placeholder.
    func signature() throws -> UnsafeMutablePointer<git_signature> {
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, pointer) == 0, let sig { return sig }
        let user = GitAccountManager.shared.currentUser
        let name = user.map { $0.name ?? $0.login } ?? "Mobile Studio"
        let email = user.map { "\($0.login)@users.noreply.github.com" } ?? "mobile-studio@localhost"
        try Git.check(git_signature_now(&sig, name, email))
        return sig!
    }

    // MARK: Config

    func config(_ key: String) -> String? {
        var config: OpaquePointer?
        guard git_repository_config(&config, pointer) == 0, let config else { return nil }
        defer { git_config_free(config) }
        return Git.buffer { git_config_get_string_buf($0, config, key) }
    }

    /// `git config [--global] key value` (nil removes it).
    func setConfig(_ key: String, _ value: String?, global: Bool = false) throws {
        var config: OpaquePointer?
        try Git.check(git_repository_config(&config, pointer))
        defer { git_config_free(config) }
        var target = config
        var level: OpaquePointer?
        if global {
            try Git.check(git_config_open_level(&level, config, GIT_CONFIG_LEVEL_GLOBAL))
            target = level
        }
        defer { if let level { git_config_free(level) } }
        if let value { try Git.check(git_config_set_string(target, key, value)) } else { _ = git_config_delete_entry(target, key) }
    }

    // MARK: Status

    func status() -> GitStatus {
        var status = GitStatus()
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue | GIT_STATUS_OPT_SORT_CASE_INSENSITIVELY.rawValue
        var list: OpaquePointer?
        if git_status_list_new(&list, pointer, &options) == 0, let list {
            defer { git_status_list_free(list) }
            for i in 0..<git_status_list_entrycount(list) {
                guard let entry = git_status_byindex(list, i)?.pointee else { continue }
                let flags = entry.status.rawValue
                let has = { (flag: git_status_t) in flags & flag.rawValue != 0 }
                let staged = entry.head_to_index?.pointee
                let working = entry.index_to_workdir?.pointee
                let path = Git.string(working?.new_file.path ?? staged?.new_file.path)
                if has(GIT_STATUS_CONFLICTED) {
                    status.mergeConflicts.append(GitChangedFile(path: path, status: .conflicted))
                    continue
                }
                if let staged {
                    let file = Git.string(staged.new_file.path)
                    let old = Git.string(staged.old_file.path)
                    if has(GIT_STATUS_INDEX_NEW) { status.stagedFiles.append(GitChangedFile(path: file, status: .added)) }
                    else if has(GIT_STATUS_INDEX_DELETED) { status.stagedFiles.append(GitChangedFile(path: old, status: .deleted)) }
                    else if has(GIT_STATUS_INDEX_RENAMED) { status.stagedFiles.append(GitChangedFile(path: file, status: .renamed, oldPath: old)) }
                    else if has(GIT_STATUS_INDEX_TYPECHANGE) { status.stagedFiles.append(GitChangedFile(path: file, status: .typeChanged)) }
                    else if has(GIT_STATUS_INDEX_MODIFIED) { status.stagedFiles.append(GitChangedFile(path: file, status: .modified)) }
                }
                if working != nil {
                    if has(GIT_STATUS_WT_NEW) { status.changedFiles.append(GitChangedFile(path: path, status: .untracked)) }
                    else if has(GIT_STATUS_WT_DELETED) { status.changedFiles.append(GitChangedFile(path: path, status: .deleted)) }
                    else if has(GIT_STATUS_WT_TYPECHANGE) { status.changedFiles.append(GitChangedFile(path: path, status: .typeChanged)) }
                    else if has(GIT_STATUS_WT_MODIFIED) || has(GIT_STATUS_WT_RENAMED) { status.changedFiles.append(GitChangedFile(path: path, status: .modified)) }
                }
            }
        }

        // The branch, its upstream and how far apart they are.
        var head: OpaquePointer?
        if git_repository_head(&head, pointer) == 0, let head {
            defer { git_reference_free(head) }
            status.head = Git.hex(git_reference_target(head))
            status.branch = git_repository_head_detached(pointer) == 1 ? nil : Git.string(git_reference_shorthand(head))
            var upstream: OpaquePointer?
            if status.branch != nil, git_branch_upstream(&upstream, head) == 0, let upstream {
                defer { git_reference_free(upstream) }
                status.upstream = Git.string(git_reference_shorthand(upstream))
                var ahead = 0, behind = 0
                if let local = git_reference_target(head), let remote = git_reference_target(upstream),
                   git_graph_ahead_behind(&ahead, &behind, pointer, local, remote) == 0 {
                    status.aheadCount = ahead
                    status.behindCount = behind
                }
            }
        } else {
            // Before the first commit, HEAD names the branch to be.
            var ref: OpaquePointer?
            if git_reference_lookup(&ref, pointer, "HEAD") == 0, let ref {
                defer { git_reference_free(ref) }
                let target = Git.string(git_reference_symbolic_target(ref))
                status.branch = target.hasPrefix("refs/heads/") ? String(target.dropFirst(11)) : target
            }
        }
        status.remoteURL = remoteURL()
        status.state = state
        if status.state == .merging { status.mergingBranch = mergingBranch() }
        status.stashCount = stashes().count
        return status
    }

    var state: GitRepositoryState {
        switch git_repository_state(pointer) {
        case Int32(GIT_REPOSITORY_STATE_NONE.rawValue): return .none
        case Int32(GIT_REPOSITORY_STATE_MERGE.rawValue): return .merging
        case Int32(GIT_REPOSITORY_STATE_REVERT.rawValue), Int32(GIT_REPOSITORY_STATE_REVERT_SEQUENCE.rawValue): return .reverting
        case Int32(GIT_REPOSITORY_STATE_CHERRYPICK.rawValue), Int32(GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE.rawValue): return .cherryPicking
        case Int32(GIT_REPOSITORY_STATE_REBASE.rawValue), Int32(GIT_REPOSITORY_STATE_REBASE_INTERACTIVE.rawValue),
             Int32(GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue): return .rebasing
        default: return .other
        }
    }

    private var gitDir: URL { URL(fileURLWithPath: Git.string(git_repository_path(pointer))) }

    /// MERGE_MSG, which a merge with conflicts leaves for its commit.
    var mergeMessage: String? {
        (try? String(contentsOf: gitDir.appendingPathComponent("MERGE_MSG"), encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergingBranch() -> String? {
        guard let message = mergeMessage, let open = message.firstIndex(of: "'"),
              let close = message[message.index(after: open)...].firstIndex(of: "'") else { return mergeMessage == nil ? nil : "a branch" }
        return String(message[message.index(after: open)..<close])
    }

    func conflicts() -> [String] { status().mergeConflicts.map(\.path) }

    // MARK: Staging

    func stage(_ paths: [String]) throws {
        let index = try index()
        defer { git_index_free(index) }
        for path in paths {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                try Git.check(git_index_add_bypath(index, path), "Couldn't stage \(path)")
            } else {
                try Git.check(git_index_remove_bypath(index, path), "Couldn't stage \(path)")
            }
        }
        try Git.check(git_index_write(index))
        Self.notifyChange()
    }

    func stageAll() throws {
        let index = try index()
        defer { git_index_free(index) }
        try Git.withStrings(["*"]) { spec in
            try Git.check(git_index_add_all(index, spec, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
            try Git.check(git_index_update_all(index, spec, nil, nil))
        }
        try Git.check(git_index_write(index))
        Self.notifyChange()
    }

    func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        if let head = headCommit() {
            defer { git_object_free(head) }
            _ = try Git.withStrings(paths) { try Git.check(git_reset_default(pointer, head, $0)) }
        } else {
            // Before the first commit, unstaging takes files out of the index.
            let index = try index()
            defer { git_index_free(index) }
            for path in paths { _ = git_index_remove_bypath(index, path) }
            try Git.check(git_index_write(index))
        }
        Self.notifyChange()
    }

    /// Stops tracking files, leaving them on disk (git rm --cached).
    func removeFromIndex(_ paths: [String]) throws {
        let index = try index()
        defer { git_index_free(index) }
        for path in paths { try Git.check(git_index_remove_bypath(index, path), "Couldn't remove \(path)") }
        try Git.check(git_index_write(index))
        Self.notifyChange()
    }

    func unstageAll() throws { try unstage(status().stagedFiles.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }) }

    /// Discards working changes: files go back to their staged version; untracked ones are deleted.
    func discard(_ files: [GitChangedFile]) throws {
        let untracked = files.filter { $0.status == .untracked }
        for file in untracked { try? FileManager.default.removeItem(at: root.appendingPathComponent(file.path)) }
        let tracked = files.filter { $0.status != .untracked }.map(\.path)
        guard !tracked.isEmpty else { return }
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
        try Git.withStrings(tracked) { paths in
            options.paths = paths.pointee
            try Git.check(git_checkout_index(pointer, nil, &options), "Couldn't discard the changes")
        }
    }

    // MARK: Commits

    /// Commits what's staged (`stageAll`: everything first). Amending replaces the last commit.
    @discardableResult
    func commit(message: String, stageAll all: Bool = false, amend: Bool = false) throws -> GitCommit {
        if all { try stageAll() }
        let index = try index()
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 {
            throw GitError("Resolve the merge conflicts first: stage each fixed file, then commit.")
        }
        var treeId = git_oid()
        try Git.check(git_index_write_tree(&treeId, index))
        var tree: OpaquePointer?
        try Git.check(git_tree_lookup(&tree, pointer, &treeId))
        defer { git_tree_free(tree) }
        let sig = try signature()
        defer { git_signature_free(sig) }
        let text = message.hasSuffix("\n") ? message : message + "\n"
        let head = headCommit()
        defer { if let head { git_object_free(head) } }
        var id = git_oid()

        if amend {
            guard let head else { throw GitError("There's no commit to amend yet.") }
            try Git.check(git_commit_amend(&id, head, "HEAD", nil, sig, nil, message.isEmpty ? nil : text, tree), "Couldn't amend")
        } else {
            var parents: [OpaquePointer?] = []
            if let head {
                // Nothing staged and not finishing a merge: nothing to commit.
                if state != .merging, let headTree = treeOid(head), git_oid_equal(&treeId, [headTree]) == 1 {
                    throw GitError("There are no changes to commit.", code: GitError.nothingToCommit)
                }
                parents.append(head)
            }
            for other in mergeHeads() { parents.append(try lookupCommit(other)) }
            defer { parents.dropFirst(head == nil ? 0 : 1).forEach { git_object_free($0) } }
            _ = try parents.withUnsafeMutableBufferPointer { buffer in
                try Git.check(git_commit_create(&id, pointer, "HEAD", sig, sig, nil, text, tree, buffer.count, buffer.baseAddress), "Couldn't commit")
            }
            if state != .none { git_repository_state_cleanup(pointer) }
        }
        Self.notifyChange()
        var commit: OpaquePointer?
        try Git.check(git_commit_lookup(&commit, pointer, &id))
        defer { git_commit_free(commit) }
        return commitModel(commit!)
    }

    private func treeOid(_ commit: OpaquePointer) -> git_oid? {
        git_commit_tree_id(commit)?.pointee
    }

    private func mergeHeads() -> [String] {
        guard state == .merging else { return [] }
        final class Box { var ids: [String] = [] }
        let box = Box()
        _ = git_repository_mergehead_foreach(pointer, { oid, payload in
            Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue().ids.append(Git.hex(oid))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.ids
    }

    /// Undoes the last commit, keeping its changes staged (git reset --soft HEAD~). Returns its message.
    func undoLastCommit() throws -> String {
        guard let head = headCommit() else { throw GitError("There's no commit to undo.") }
        defer { git_object_free(head) }
        let message = Git.string(git_commit_message(head))
        if git_commit_parentcount(head) == 0 {
            // The first commit: the branch goes back to having none.
            var ref: OpaquePointer?
            try Git.check(git_repository_head(&ref, pointer))
            defer { git_reference_free(ref) }
            try Git.check(git_reference_delete(ref))
        } else {
            var parent: OpaquePointer?
            try Git.check(git_commit_parent(&parent, head, 0))
            defer { git_commit_free(parent) }
            try Git.check(git_reset(pointer, parent, GIT_RESET_SOFT, nil))
        }
        Self.notifyChange()
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The commits reachable from `from` (HEAD), newest first; `all` adds every branch and tag,
    /// for the Graph. `path` keeps the commits that changed that file.
    func log(from start: String? = nil, all: Bool = false, path: String? = nil, limit: Int = 500) -> [GitCommit] {
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, pointer) == 0, let walk else { return [] }
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        if let start, let commit = try? lookupCommit(start) {
            git_revwalk_push(walk, git_commit_id(commit))
            git_object_free(commit)
        } else if git_revwalk_push_head(walk) != 0 && !all {
            return []
        }
        if all {
            _ = git_revwalk_push_glob(walk, "refs/heads")
            _ = git_revwalk_push_glob(walk, "refs/remotes")
            _ = git_revwalk_push_glob(walk, "refs/tags")
        }
        let refs = refLabels()
        var commits: [GitCommit] = []
        var oid = git_oid()
        while commits.count < limit, git_revwalk_next(&oid, walk) == 0 {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, pointer, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }
            if let path, !changes(path, in: commit) { continue }
            commits.append(commitModel(commit, refs: refs))
        }
        return commits
    }

    func commit(_ id: String) -> GitCommit? {
        guard let commit = try? lookupCommit(id) else { return nil }
        defer { git_object_free(commit) }
        return commitModel(commit, refs: refLabels())
    }

    /// Whether `commit` changed `path` from its first parent.
    private func changes(_ path: String, in commit: OpaquePointer) -> Bool {
        let mine = entryId(path, in: commit)
        guard git_commit_parentcount(commit) > 0 else { return mine != nil }
        var parent: OpaquePointer?
        guard git_commit_parent(&parent, commit, 0) == 0, let parent else { return mine != nil }
        defer { git_commit_free(parent) }
        return mine != entryId(path, in: parent)
    }

    private func entryId(_ path: String, in commit: OpaquePointer) -> String? {
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else { return nil }
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else { return nil }
        defer { git_tree_entry_free(entry) }
        return Git.hex(git_tree_entry_id(entry))
    }

    /// Branches, remote branches, tags and HEAD, by the commit they point at.
    func refLabels() -> [String: [GitRefLabel]] {
        var labels: [String: [GitRefLabel]] = [:]
        var iterator: OpaquePointer?
        guard git_reference_iterator_new(&iterator, pointer) == 0, let iterator else { return [:] }
        defer { git_reference_iterator_free(iterator) }
        var ref: OpaquePointer?
        while git_reference_next(&ref, iterator) == 0, let current = ref {
            defer { git_reference_free(current) }
            let name = Git.string(git_reference_name(current))
            var resolved: OpaquePointer?
            guard git_reference_peel(&resolved, current, GIT_OBJECT_COMMIT) == 0, let resolved else { continue }
            let id = Git.hex(git_object_id(resolved))
            git_object_free(resolved)
            let short = Git.string(git_reference_shorthand(current))
            if name.hasPrefix("refs/heads/") { labels[id, default: []].append(GitRefLabel(name: short, kind: .branch)) }
            else if name.hasPrefix("refs/remotes/"), !name.hasSuffix("/HEAD") { labels[id, default: []].append(GitRefLabel(name: short, kind: .remote)) }
            else if name.hasPrefix("refs/tags/") { labels[id, default: []].append(GitRefLabel(name: short, kind: .tag)) }
        }
        // The checked-out branch first, marked as HEAD.
        let status = (branch: currentBranchName, head: headId)
        if let head = status.head, var list = labels[head] {
            if let branch = status.branch, let i = list.firstIndex(where: { $0.kind == .branch && $0.name == branch }) {
                list.remove(at: i)
                list.insert(GitRefLabel(name: branch, kind: .head), at: 0)
            } else {
                list.insert(GitRefLabel(name: "HEAD", kind: .head), at: 0)
            }
            labels[head] = list
        } else if let head = status.head {
            labels[head] = [GitRefLabel(name: "HEAD", kind: .head)]
        }
        return labels
    }

    var headId: String? {
        var oid = git_oid()
        guard git_reference_name_to_id(&oid, pointer, "HEAD") == 0 else { return nil }
        return Git.hex(oid)
    }

    /// The checked-out branch (nil when detached), even before its first commit.
    var currentBranchName: String? {
        var ref: OpaquePointer?
        guard git_reference_lookup(&ref, pointer, "HEAD") == 0, let ref else { return nil }
        defer { git_reference_free(ref) }
        let target = Git.string(git_reference_symbolic_target(ref))
        return target.hasPrefix("refs/heads/") ? String(target.dropFirst(11)) : nil
    }

    /// The files a commit changed against its first parent.
    func changes(inCommit id: String) -> [GitChangedFile] {
        guard let commit = try? lookupCommit(id) else { return [] }
        defer { git_object_free(commit) }
        var tree: OpaquePointer?
        var parentTree: OpaquePointer?
        git_commit_tree(&tree, commit)
        defer { git_tree_free(tree); if let parentTree { git_tree_free(parentTree) } }
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                git_commit_tree(&parentTree, parent)
                git_commit_free(parent)
            }
        }
        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, pointer, parentTree, tree, nil) == 0, let diff else { return [] }
        defer { git_diff_free(diff) }
        git_diff_find_similar(diff, nil)
        return Self.files(in: diff)
    }

    private static func files(in diff: OpaquePointer) -> [GitChangedFile] {
        (0..<git_diff_num_deltas(diff)).compactMap { i in
            guard let delta = git_diff_get_delta(diff, i)?.pointee else { return nil }
            let path = Git.string(delta.new_file.path)
            switch delta.status {
            case GIT_DELTA_ADDED: return GitChangedFile(path: path, status: .added)
            case GIT_DELTA_DELETED: return GitChangedFile(path: Git.string(delta.old_file.path), status: .deleted)
            case GIT_DELTA_RENAMED: return GitChangedFile(path: path, status: .renamed, oldPath: Git.string(delta.old_file.path))
            case GIT_DELTA_TYPECHANGE: return GitChangedFile(path: path, status: .typeChanged)
            default: return GitChangedFile(path: path, status: .modified)
            }
        }
    }

    /// A file's text at a revision (nil when it isn't there, or isn't text).
    func text(of path: String, at revision: GitRevision) -> String? {
        guard let data = data(of: path, at: revision), !data.prefix(8000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(of path: String, at revision: GitRevision) -> Data? {
        switch revision {
        case .index:
            guard let index = try? index() else { return nil }
            defer { git_index_free(index) }
            guard let entry = git_index_get_bypath(index, path, 0) else { return nil }
            var id = entry.pointee.id
            return blob(&id)
        case .head:
            return data(of: path, inCommit: "HEAD")
        case .commit(let id):
            return data(of: path, inCommit: id)
        case .parent(let id):
            return data(of: path, inCommit: id + "^")
        }
    }

    private func data(of path: String, inCommit spec: String) -> Data? {
        guard let commit = try? lookupCommit(spec) else { return nil }
        defer { git_object_free(commit) }
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else { return nil }
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else { return nil }
        defer { git_tree_entry_free(entry) }
        guard var id = git_tree_entry_id(entry)?.pointee else { return nil }
        return blob(&id)
    }

    private func blob(_ id: inout git_oid) -> Data? {
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, pointer, &id) == 0, let blob else { return nil }
        defer { git_blob_free(blob) }
        guard let raw = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: raw, count: Int(git_blob_rawsize(blob)))
    }

    /// Who last changed each line of `contents` (the editor's text): nil for lines not committed yet.
    func blame(_ path: String, contents: String) -> [GitCommit?] {
        var options = git_blame_options()
        git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION))
        var base: OpaquePointer?
        let lines = contents.components(separatedBy: "\n").count
        guard git_blame_file(&base, pointer, path, &options) == 0, let base else { return Array(repeating: nil, count: lines) }
        defer { git_blame_free(base) }
        var blame: OpaquePointer?
        let bytes = Array(contents.utf8)
        guard bytes.withUnsafeBufferPointer({ buffer in
            buffer.withMemoryRebound(to: CChar.self) { git_blame_buffer(&blame, base, $0.baseAddress, buffer.count) }
        }) == 0, let blame else { return Array(repeating: nil, count: lines) }
        defer { git_blame_free(blame) }
        var owners = [GitCommit?](repeating: nil, count: lines)
        var cache: [String: GitCommit] = [:]
        for i in 0..<git_blame_hunkcount(blame) {
            guard let hunk = git_blame_hunk_byindex(blame, i)?.pointee, !Git.isZero(hunk.final_commit_id) else { continue }
            let id = Git.hex(hunk.final_commit_id)
            if cache[id] == nil, let found = commit(id) { cache[id] = found }
            let start = Int(hunk.final_start_line_number) - 1
            for line in start..<min(lines, start + Int(hunk.lines_in_hunk)) where line >= 0 { owners[line] = cache[id] }
        }
        return owners
    }

    // MARK: Branches

    func branches(remote: Bool = false) -> [GitBranch] {
        var iterator: OpaquePointer?
        guard git_branch_iterator_new(&iterator, pointer, remote ? GIT_BRANCH_REMOTE : GIT_BRANCH_LOCAL) == 0, let iterator else { return [] }
        defer { git_branch_iterator_free(iterator) }
        var list: [GitBranch] = []
        var ref: OpaquePointer?
        var type = GIT_BRANCH_LOCAL
        while git_branch_next(&ref, &type, iterator) == 0, let current = ref {
            defer { git_reference_free(current) }
            var namePointer: UnsafePointer<CChar>?
            git_branch_name(&namePointer, current)
            let name = Git.string(namePointer)
            if remote && name.hasSuffix("/HEAD") { continue }
            var upstreamName: String?
            var ahead = 0, behind = 0
            var upstream: OpaquePointer?
            if !remote, git_branch_upstream(&upstream, current) == 0, let upstream {
                upstreamName = Git.string(git_reference_shorthand(upstream))
                if let a = git_reference_target(current), let b = git_reference_target(upstream) {
                    git_graph_ahead_behind(&ahead, &behind, pointer, a, b)
                }
                git_reference_free(upstream)
            }
            var summary = "", date = Date.distantPast, tip = ""
            var commit: OpaquePointer?
            if git_reference_peel(&commit, current, GIT_OBJECT_COMMIT) == 0, let commit {
                tip = Git.hex(git_object_id(commit))
                summary = Git.string(git_commit_summary(commit))
                date = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
                git_object_free(commit)
            }
            list.append(GitBranch(name: name, isRemote: remote, isHead: git_branch_is_head(current) == 1, upstream: upstreamName,
                                  ahead: ahead, behind: behind, tip: tip, summary: summary, date: date))
        }
        return list.sorted { $0.isHead != $1.isHead ? $0.isHead : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func validBranchName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        var valid: Int32 = 0
        guard !name.isEmpty, git_branch_name_is_valid(&valid, name) == 0, valid == 1 else {
            throw GitError("'\(raw)' isn't a valid branch name.")
        }
        return name
    }

    /// A new branch at `start` (a branch, tag or commit; HEAD when nil), checked out unless told not to.
    func createBranch(_ raw: String, at start: String? = nil, checkout: Bool = true) throws {
        let name = try validBranchName(raw)
        guard let commit = try? lookupCommit(start ?? "HEAD") else {
            // No commits yet: the branch starts with the first one.
            guard start == nil else { throw GitError("There's no commit \(start!).") }
            try Git.check(git_repository_set_head(pointer, "refs/heads/" + name))
            Self.notifyChange()
            return
        }
        defer { git_object_free(commit) }
        var ref: OpaquePointer?
        try Git.check(git_branch_create(&ref, pointer, name, commit, 0), "Couldn't create \(name)")
        git_reference_free(ref)
        if checkout { try self.checkout(name) }
    }

    /// Checks out a local branch. Changes in the way stop it (GitError.isConflict, with the
    /// files) unless `force`, which overwrites them.
    func checkout(_ branch: String, force: Bool = false) throws {
        try checkoutTree("refs/heads/" + branch, force: force)
        try Git.check(git_repository_set_head(pointer, "refs/heads/" + branch))
        Self.notifyChange()
    }

    /// Checks out a commit without a branch (a detached HEAD).
    func checkout(commit id: String, force: Bool = false) throws {
        let commit = try lookupCommit(id)
        defer { git_object_free(commit) }
        try checkoutTree(id, force: force)
        try Git.check(git_repository_set_head_detached(pointer, git_commit_id(commit)))
        Self.notifyChange()
    }

    /// "origin/feature": a local "feature" following it, checked out (or the existing one).
    func checkoutRemote(_ remoteBranch: String, force: Bool = false) throws {
        let local = remoteBranch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? remoteBranch
        if !branches().contains(where: { $0.name == local }) {
            let commit = try lookupCommit("refs/remotes/" + remoteBranch)
            defer { git_object_free(commit) }
            var ref: OpaquePointer?
            try Git.check(git_branch_create(&ref, pointer, local, commit, 0), "Couldn't create \(local)")
            defer { git_reference_free(ref) }
            try Git.check(git_branch_set_upstream(ref, remoteBranch))
        }
        try checkout(local, force: force)
    }

    private func checkoutTree(_ spec: String, force: Bool) throws {
        let commit = try lookupCommit(spec)
        defer { git_object_free(commit) }
        final class Box { var paths: [String] = [] }
        let box = Box()
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = force ? GIT_CHECKOUT_FORCE.rawValue : GIT_CHECKOUT_SAFE.rawValue
        options.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
        options.notify_payload = Unmanaged.passUnretained(box).toOpaque()
        options.notify_cb = { _, path, _, _, _, payload in
            Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue().paths.append(Git.string(path))
            return 0
        }
        let rc = git_checkout_tree(pointer, commit, &options)
        if rc == GIT_ECONFLICT.rawValue || (rc < 0 && !box.paths.isEmpty) {
            throw GitError("Your local changes would be overwritten by checkout.", code: GIT_ECONFLICT.rawValue, paths: box.paths)
        }
        try Git.check(rc, "Couldn't check out \(spec)")
    }

    /// Deletes a branch. One whose commits aren't on another branch or its upstream needs `force`.
    func deleteBranch(_ name: String, force: Bool = false, remote: Bool = false) throws {
        var ref: OpaquePointer?
        try Git.check(git_branch_lookup(&ref, pointer, name, remote ? GIT_BRANCH_REMOTE : GIT_BRANCH_LOCAL), "There's no branch \(name)")
        defer { git_reference_free(ref) }
        if git_branch_is_head(ref) == 1 { throw GitError("'\(name)' is checked out: switch to another branch first.") }
        if !force && !remote, let tip = git_reference_target(ref), !isMergedSomewhere(tip, except: name) {
            throw GitError("The branch '\(name)' is not fully merged.", code: GitError.notMerged)
        }
        try Git.check(git_branch_delete(ref), "Couldn't delete \(name)")
    }

    private func isMergedSomewhere(_ tip: UnsafePointer<git_oid>, except name: String) -> Bool {
        let others = branches().filter { $0.name != name }.map(\.tip) + branches(remote: true).map(\.tip)
        for other in others {
            var oid = git_oid()
            guard git_oid_fromstr(&oid, other) == 0 else { continue }
            if git_oid_equal(&oid, tip) == 1 || git_graph_descendant_of(pointer, &oid, tip) == 1 { return true }
        }
        return false
    }

    func renameBranch(_ old: String, to raw: String) throws {
        let name = try validBranchName(raw)
        var ref: OpaquePointer?
        try Git.check(git_branch_lookup(&ref, pointer, old, GIT_BRANCH_LOCAL), "There's no branch \(old)")
        defer { git_reference_free(ref) }
        var renamed: OpaquePointer?
        try Git.check(git_branch_move(&renamed, ref, name, 0), "Couldn't rename \(old)")
        git_reference_free(renamed)
        Self.notifyChange()
    }

    func setUpstream(_ branch: String, to upstream: String?) throws {
        var ref: OpaquePointer?
        try Git.check(git_branch_lookup(&ref, pointer, branch, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        try Git.check(git_branch_set_upstream(ref, upstream))
    }

    // MARK: Merge, revert, cherry-pick, reset

    /// Merges a branch ("feature" or "origin/main") into the current one.
    func merge(_ branch: String) throws -> GitMergeResult {
        let spec = branchSpec(branch)
        let target = try lookupCommit(spec)
        defer { git_object_free(target) }
        // From the branch's reference when it is one, so the merge message names it.
        var annotated: OpaquePointer?
        var ref: OpaquePointer?
        if spec.hasPrefix("refs/"), git_reference_lookup(&ref, pointer, spec) == 0, let ref {
            defer { git_reference_free(ref) }
            try Git.check(git_annotated_commit_from_ref(&annotated, pointer, ref))
        } else {
            try Git.check(git_annotated_commit_lookup(&annotated, pointer, git_commit_id(target)))
        }
        defer { git_annotated_commit_free(annotated) }
        var analysis = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE
        var heads: [OpaquePointer?] = [annotated]
        try Git.check(heads.withUnsafeMutableBufferPointer { git_merge_analysis(&analysis, &preference, pointer, $0.baseAddress, 1) })
        let has = { (flag: git_merge_analysis_t) in analysis.rawValue & flag.rawValue != 0 }
        if has(GIT_MERGE_ANALYSIS_UP_TO_DATE) { return .upToDate }

        if has(GIT_MERGE_ANALYSIS_UNBORN) || (has(GIT_MERGE_ANALYSIS_FASTFORWARD) && preference.rawValue & GIT_MERGE_PREFERENCE_NO_FASTFORWARD.rawValue == 0) {
            try checkoutTree(Git.hex(git_commit_id(target)), force: false)
            let branchName = currentBranchName ?? "main"
            var ref: OpaquePointer?
            try Git.check(git_reference_create(&ref, pointer, "refs/heads/" + branchName, git_commit_id(target), 1, "merge \(branch): Fast-forward"))
            git_reference_free(ref)
            Self.notifyChange()
            return .fastForward
        }

        var mergeOptions = git_merge_options()
        git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var checkoutOptions = git_checkout_options()
        git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue | GIT_CHECKOUT_CONFLICT_STYLE_MERGE.rawValue
        try Git.check(heads.withUnsafeMutableBufferPointer { git_merge(pointer, $0.baseAddress, 1, &mergeOptions, &checkoutOptions) },
                      "Couldn't merge \(branch)")
        Self.notifyChange()
        let conflicts = self.conflicts()
        if !conflicts.isEmpty { return .conflicts(conflicts) }
        try commit(message: mergeMessage ?? "Merge branch '\(branch)'")
        return .merged
    }

    /// "feature" is refs/heads/feature unless there's only a remote "origin/feature".
    private func branchSpec(_ name: String) -> String {
        var oid = git_oid()
        if git_reference_name_to_id(&oid, pointer, "refs/heads/" + name) == 0 { return "refs/heads/" + name }
        if git_reference_name_to_id(&oid, pointer, "refs/remotes/" + name) == 0 { return "refs/remotes/" + name }
        return name
    }

    /// Abandons a merge, revert or cherry-pick with conflicts: back to HEAD.
    func abortMerge() throws {
        if let head = headCommit() {
            defer { git_object_free(head) }
            try Git.check(git_reset(pointer, head, GIT_RESET_HARD, nil))
        }
        git_repository_state_cleanup(pointer)
        Self.notifyChange()
    }

    /// A new commit undoing `id`'s changes.
    func revert(_ id: String) throws -> GitMergeResult {
        let commit = try lookupCommit(id)
        defer { git_object_free(commit) }
        var options = git_revert_options()
        git_revert_options_init(&options, UInt32(GIT_REVERT_OPTIONS_VERSION))
        if git_commit_parentcount(commit) > 1 { options.mainline = 1 }
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try Git.check(git_revert(pointer, commit, &options), "Couldn't revert")
        Self.notifyChange()
        let conflicts = self.conflicts()
        if !conflicts.isEmpty { return .conflicts(conflicts) }
        try self.commit(message: "Revert \"\(Git.string(git_commit_summary(commit)))\"\n\nThis reverts commit \(Git.hex(git_commit_id(commit))).")
        return .merged
    }

    /// `id`'s changes as a new commit on the current branch.
    func cherryPick(_ id: String) throws -> GitMergeResult {
        let commit = try lookupCommit(id)
        defer { git_object_free(commit) }
        var options = git_cherrypick_options()
        git_cherrypick_options_init(&options, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION))
        if git_commit_parentcount(commit) > 1 { options.mainline = 1 }
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try Git.check(git_cherrypick(pointer, commit, &options), "Couldn't cherry-pick")
        Self.notifyChange()
        let conflicts = self.conflicts()
        if !conflicts.isEmpty { return .conflicts(conflicts) }
        try self.commit(message: Git.string(git_commit_message(commit)))
        return .merged
    }

    /// Moves the current branch to `id` (git reset --soft/--mixed/--hard).
    func reset(to id: String, mode: GitResetMode) throws {
        let commit = try lookupCommit(id)
        defer { git_object_free(commit) }
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try Git.check(git_reset(pointer, commit, mode.git, &options), "Couldn't reset")
        Self.notifyChange()
    }

    // MARK: Stash

    func stashes() -> [GitStash] {
        final class Box { var list: [GitStash] = [] }
        let box = Box()
        _ = git_stash_foreach(pointer, { index, message, _, payload in
            Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue().list.append(GitStash(index: index, message: Git.string(message)))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.list
    }

    func stash(message: String = "", includeUntracked: Bool = true) throws {
        let sig = try signature()
        defer { git_signature_free(sig) }
        var id = git_oid()
        let flags = includeUntracked ? GIT_STASH_INCLUDE_UNTRACKED.rawValue : GIT_STASH_DEFAULT.rawValue
        let rc = git_stash_save(&id, pointer, sig, message.isEmpty ? nil : message, flags)
        if rc == GIT_ENOTFOUND.rawValue { throw GitError("There are no local changes to stash.") }
        try Git.check(rc, "Couldn't stash")
        Self.notifyChange()
    }

    /// Applies a stash (`drop`: and removes it, as pop does).
    func applyStash(_ index: Int = 0, drop: Bool) throws {
        var options = git_stash_apply_options()
        git_stash_apply_options_init(&options, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        options.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        let rc = drop ? git_stash_pop(pointer, index, &options) : git_stash_apply(pointer, index, &options)
        Self.notifyChange()
        if rc == GIT_ECONFLICT.rawValue || rc == GIT_EMERGECONFLICT.rawValue {
            throw GitError("The stash's changes conflict with yours. Commit or stash your changes first.", code: rc)
        }
        try Git.check(rc, "Couldn't apply the stash")
    }

    func dropStash(_ index: Int) throws { try Git.check(git_stash_drop(pointer, index), "Couldn't drop the stash") }

    func dropAllStashes() throws {
        while !stashes().isEmpty { try dropStash(0) }
    }

    // MARK: Tags

    func tags() -> [GitTag] {
        var names = git_strarray()
        guard git_tag_list(&names, pointer) == 0 else { return [] }
        return Git.strings(&names).map { name in
            var target = ""
            if let commit = try? lookupCommit("refs/tags/" + name) {
                target = Git.hex(git_commit_id(commit))
                git_object_free(commit)
            }
            return GitTag(name: name, target: target)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    /// A tag at `target` (HEAD); with a message it's annotated.
    func createTag(_ name: String, at target: String? = nil, message: String? = nil) throws {
        let commit = try lookupCommit(target ?? "HEAD")
        defer { git_object_free(commit) }
        var id = git_oid()
        if let message, !message.isEmpty {
            let sig = try signature()
            defer { git_signature_free(sig) }
            try Git.check(git_tag_create(&id, pointer, name, commit, sig, message, 0), "Couldn't create the tag")
        } else {
            try Git.check(git_tag_create_lightweight(&id, pointer, name, commit, 0), "Couldn't create the tag")
        }
    }

    func deleteTag(_ name: String) throws { try Git.check(git_tag_delete(pointer, name), "Couldn't delete \(name)") }

    // MARK: Remotes

    func remotes() -> [GitRemote] {
        var names = git_strarray()
        guard git_remote_list(&names, pointer) == 0 else { return [] }
        return Git.strings(&names).map { GitRemote(name: $0, url: remoteURL($0) ?? "") }
    }

    func remoteURL(_ name: String = "origin") -> String? {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, pointer, name) == 0, let remote else { return nil }
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
    }

    /// Adds the remote, or changes its address.
    func setRemote(_ name: String = "origin", url: String) throws {
        if remoteURL(name) == nil {
            var remote: OpaquePointer?
            try Git.check(git_remote_create(&remote, pointer, name, url), "Couldn't add \(name)")
            git_remote_free(remote)
        } else {
            try Git.check(git_remote_set_url(pointer, name, url), "Couldn't change \(name)")
        }
    }

    func removeRemote(_ name: String) throws { try Git.check(git_remote_delete(pointer, name), "Couldn't remove \(name)") }

    func renameRemote(_ name: String, to newName: String) throws {
        var problems = git_strarray()
        try Git.check(git_remote_rename(&problems, pointer, name, newName), "Couldn't rename \(name)")
        git_strarray_dispose(&problems)
    }

    // MARK: Network (blocking)

    /// Downloads a remote's new commits, branches and tags (`prune`: removes branches gone from it).
    func fetch(_ remoteName: String = "origin", prune: Bool = false, transfer: GitTransfer = GitTransfer()) throws {
        var remote: OpaquePointer?
        try Git.check(git_remote_lookup(&remote, pointer, remoteName), "There's no remote \(remoteName)")
        defer { git_remote_free(remote) }
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        options.prune = prune ? GIT_FETCH_PRUNE : GIT_FETCH_PRUNE_UNSPECIFIED
        options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_AUTO
        transfer.install(&options.callbacks)
        let rc = git_remote_fetch(remote, nil, &options, nil)
        guard rc == 0 else { throw transfer.error(rc, "Couldn't fetch from \(remoteName)") }
        Self.notifyChange()
    }

    /// Fetches the branch's upstream and merges it in. A branch without one follows its remote
    /// namesake when there is one.
    func pull(transfer: GitTransfer = GitTransfer()) throws -> GitMergeResult {
        guard let branch = currentBranchName else { throw GitError("HEAD is detached: check out a branch to pull.") }
        var upstream = status().upstream
        let remoteName = upstream.flatMap { $0.split(separator: "/").first.map(String.init) } ?? "origin"
        try fetch(remoteName, transfer: transfer)
        if upstream == nil {
            guard branches(remote: true).contains(where: { $0.name == "\(remoteName)/\(branch)" }) else {
                throw GitError("'\(branch)' isn't on \(remoteName) yet: publish it first.")
            }
            if headId != nil { try setUpstream(branch, to: "\(remoteName)/\(branch)") }
            upstream = "\(remoteName)/\(branch)"
        }
        return try merge(upstream!)
    }

    /// Pushes the current branch (or `branch`), setting its upstream when it has none.
    func push(_ branch: String? = nil, remote remoteName: String? = nil, force: Bool = false, tags: Bool = false,
              transfer: GitTransfer = GitTransfer()) throws {
        guard let branch = branch ?? currentBranchName else { throw GitError("HEAD is detached: check out a branch to push.") }
        let upstream = branches().first { $0.name == branch }?.upstream
        let remoteName = remoteName ?? upstream.flatMap { $0.split(separator: "/").first.map(String.init) } ?? "origin"
        var remote: OpaquePointer?
        try Git.check(git_remote_lookup(&remote, pointer, remoteName), "There's no remote \(remoteName)")
        defer { git_remote_free(remote) }
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        transfer.install(&options.callbacks)
        var specs = ["\(force ? "+" : "")refs/heads/\(branch):refs/heads/\(branch)"]
        // Pushes name each ref: libgit2 takes no wildcards here.
        if tags { specs += self.tags().map { "refs/tags/\($0.name):refs/tags/\($0.name)" } }
        let rc = Git.withStrings(specs) { git_remote_push(remote, $0, &options) }
        guard rc == 0 else { throw transfer.error(rc, "Couldn't push to \(remoteName)") }
        if !transfer.rejections.isEmpty {
            throw GitError("\(remoteName) refused the push (\(transfer.rejections.joined(separator: "; "))). Pull first, then push again.")
        }
        if upstream == nil { try? setUpstream(branch, to: "\(remoteName)/\(branch)") }
        Self.notifyChange()
    }

    /// Pushes all tags.
    func pushTags(remote remoteName: String = "origin", transfer: GitTransfer = GitTransfer()) throws {
        var remote: OpaquePointer?
        try Git.check(git_remote_lookup(&remote, pointer, remoteName), "There's no remote \(remoteName)")
        defer { git_remote_free(remote) }
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        transfer.install(&options.callbacks)
        let specs = tags().map { "refs/tags/\($0.name):refs/tags/\($0.name)" }
        guard !specs.isEmpty else { return }
        let rc = Git.withStrings(specs) { git_remote_push(remote, $0, &options) }
        guard rc == 0 else { throw transfer.error(rc, "Couldn't push the tags") }
    }

    // MARK: GitHub

    /// The GitHub repository the "origin" remote points at, for pull requests.
    func gitHubRepository() throws -> (owner: String, repo: String, token: String) {
        guard let url = remoteURL(), let (owner, repo) = Self.gitHubOwnerAndRepo(url) else {
            throw GitError("This project's remote isn't a GitHub repository.")
        }
        guard let token = GitAccountManager.shared.token, !token.isEmpty else {
            throw GitError("Sign in to GitHub first.", code: GitError.signInNeeded)
        }
        return (owner, repo, token)
    }

    /// https://github.com/owner/repo(.git) or git@github.com:owner/repo.git.
    static func gitHubOwnerAndRepo(_ url: String) -> (String, String)? {
        guard GitCredentials.host(of: url) == "github.com" else { return nil }
        let path: Substring
        if let parsed = URL(string: url), parsed.host != nil {
            path = Substring(parsed.path)
        } else if let colon = url.lastIndex(of: ":") {
            path = url[url.index(after: colon)...]
        } else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return (parts[0], repo)
    }
}

// MARK: - Patches

/// What `git diff` compares.
enum GitDiffTarget {
    /// The working files against the index (git diff).
    case workingTree
    /// The index against HEAD (git diff --staged).
    case staged
    /// A commit against its first parent (git show).
    case commit(String)
    /// Two revisions (git diff a b).
    case between(String, String)
}

extension GitRepository {
    /// git's unified diff, coloured as the terminal shows it when `color` is set.
    func patch(_ target: GitDiffTarget, paths: [String] = [], color: Bool = false) -> String {
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        var diff: OpaquePointer?
        func tree(_ spec: String) -> OpaquePointer? {
            var tree: OpaquePointer?
            return git_revparse_single(&tree, pointer, spec + "^{tree}") == 0 ? tree : nil
        }
        Git.withStrings(paths) { spec in
            if !paths.isEmpty { options.pathspec = spec.pointee }
            switch target {
            case .workingTree:
                git_diff_index_to_workdir(&diff, pointer, nil, &options)
            case .staged:
                let head = tree("HEAD")
                defer { if let head { git_object_free(head) } }
                git_diff_tree_to_index(&diff, pointer, head, nil, &options)
            case .commit(let id):
                let new = tree(id), old = tree(id + "^")
                defer { if let new { git_object_free(new) }; if let old { git_object_free(old) } }
                git_diff_tree_to_tree(&diff, pointer, old, new, &options)
            case .between(let a, let b):
                let old = tree(a), new = tree(b)
                defer { if let new { git_object_free(new) }; if let old { git_object_free(old) } }
                git_diff_tree_to_tree(&diff, pointer, old, new, &options)
            }
        }
        guard let diff else { return "" }
        defer { git_diff_free(diff) }
        git_diff_find_similar(diff, nil)
        final class Box {
            var text = ""
            let color: Bool
            init(color: Bool) { self.color = color }
        }
        let box = Box(color: color)
        git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, { _, _, line, payload in
            guard let line = line?.pointee, let payload else { return 0 }
            let box = Unmanaged<Box>.fromOpaque(payload).takeUnretainedValue()
            let content = line.content.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: line.content_len), as: UTF8.self) } ?? ""
            let origin = Character(Unicode.Scalar(UInt8(bitPattern: line.origin)))
            let (on, off) = box.color ? (GitRepository.color(for: origin), "\u{1B}[0m") : ("", "")
            switch origin {
            case "+", "-", " ": box.text += on + String(origin) + content + (on.isEmpty ? "" : off)
            default: box.text += on + content + (on.isEmpty ? "" : off)
            }
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.text
    }

    fileprivate static func color(for origin: Character) -> String {
        switch origin {
        case "+": return "\u{1B}[32m"
        case "-": return "\u{1B}[31m"
        case "F": return "\u{1B}[1m"
        case "H": return "\u{1B}[36m"
        default: return ""
        }
    }
}

// MARK: - Rebase

enum GitRebaseResult {
    case upToDate
    /// Done: how many commits were replayed.
    case done(Int)
    /// Stopped at a commit whose changes conflict: fix, stage, then continue (or skip, or abort).
    case conflicts([String])
}

extension GitRepository {
    private func rebaseOptions() -> git_rebase_options {
        var options = git_rebase_options()
        git_rebase_options_init(&options, UInt32(GIT_REBASE_OPTIONS_VERSION))
        options.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        return options
    }

    private func annotatedCommit(_ spec: String) throws -> OpaquePointer {
        let commit = try lookupCommit(branchSpec(spec))
        defer { git_object_free(commit) }
        var out: OpaquePointer?
        try Git.check(git_annotated_commit_lookup(&out, pointer, git_commit_id(commit)))
        return out!
    }

    /// Replays the current branch's commits on top of `upstream` (a branch, "origin/main", or a
    /// commit), or of `newBase` when given (git rebase --onto newBase upstream).
    func rebase(onto upstream: String, newBase: String? = nil) throws -> GitRebaseResult {
        guard currentBranchName != nil else { throw GitError("HEAD is detached: check out the branch to rebase.") }
        guard state == .none else { throw GitError("Finish or abort the \(state == .rebasing ? "rebase" : "merge") in progress first.") }
        let base = try annotatedCommit(upstream)
        defer { git_annotated_commit_free(base) }
        let onto = try newBase.map { try annotatedCommit($0) }
        defer { if let onto { git_annotated_commit_free(onto) } }

        // Already on top of it: nothing to do.
        if newBase == nil, let head = headCommit() {
            defer { git_object_free(head) }
            var mergeBase = git_oid()
            if git_merge_base(&mergeBase, pointer, git_commit_id(head), git_annotated_commit_id(base)) == 0,
               git_oid_equal(&mergeBase, git_annotated_commit_id(base)) == 1 {
                return .upToDate
            }
        }
        var options = rebaseOptions()
        var rebase: OpaquePointer?
        try Git.check(git_rebase_init(&rebase, pointer, nil, base, onto, &options), "Couldn't start the rebase")
        defer { git_rebase_free(rebase) }
        Self.notifyChange()
        return try replay(rebase!, committedSoFar: 0)
    }

    /// Commits each step, stopping at conflicts; finishes when there are no more.
    private func replay(_ rebase: OpaquePointer, committedSoFar: Int) throws -> GitRebaseResult {
        let sig = try signature()
        defer { git_signature_free(sig) }
        var count = committedSoFar
        var operation: UnsafeMutablePointer<git_rebase_operation>?
        while true {
            let rc = git_rebase_next(&operation, rebase)
            if rc == GIT_ITEROVER.rawValue { break }
            try Git.check(rc, "Couldn't apply the next commit")
            let conflicted = conflicts()
            if !conflicted.isEmpty {
                Self.notifyChange()
                return .conflicts(conflicted)
            }
            var id = git_oid()
            let committed = git_rebase_commit(&id, rebase, nil, sig, nil, nil)
            // GIT_EAPPLIED: the commit's changes are already there, so it's left out.
            if committed != GIT_EAPPLIED.rawValue { try Git.check(committed, "Couldn't commit the rebased change") }
            count += 1
        }
        try Git.check(git_rebase_finish(rebase, sig), "Couldn't finish the rebase")
        Self.notifyChange()
        return .done(count)
    }

    /// git rebase --continue: commits the fixed step (once its conflicts are staged) and goes on.
    func continueRebase() throws -> GitRebaseResult {
        var options = rebaseOptions()
        var rebase: OpaquePointer?
        try Git.check(git_rebase_open(&rebase, pointer, &options), "There's no rebase in progress")
        defer { git_rebase_free(rebase) }
        if !conflicts().isEmpty { throw GitError("Resolve the conflicts and stage the files first.") }
        let sig = try signature()
        defer { git_signature_free(sig) }
        var id = git_oid()
        let rc = git_rebase_commit(&id, rebase, nil, sig, nil, nil)
        if rc != GIT_EAPPLIED.rawValue { try Git.check(rc, "Couldn't commit the rebased change") }
        return try replay(rebase!, committedSoFar: Int(git_rebase_operation_current(rebase)) + 1)
    }

    /// git rebase --skip: drops the step that stopped, and goes on.
    func skipRebaseStep() throws -> GitRebaseResult {
        var options = rebaseOptions()
        var rebase: OpaquePointer?
        try Git.check(git_rebase_open(&rebase, pointer, &options), "There's no rebase in progress")
        defer { git_rebase_free(rebase) }
        if let head = headCommit() {
            defer { git_object_free(head) }
            var checkout = git_checkout_options()
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkout.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
            try Git.check(git_reset(pointer, head, GIT_RESET_HARD, &checkout))
        }
        return try replay(rebase!, committedSoFar: Int(git_rebase_operation_current(rebase)))
    }

    /// git rebase --abort: back to where the branch was.
    func abortRebase() throws {
        var options = rebaseOptions()
        var rebase: OpaquePointer?
        try Git.check(git_rebase_open(&rebase, pointer, &options), "There's no rebase in progress")
        defer { git_rebase_free(rebase) }
        try Git.check(git_rebase_abort(rebase), "Couldn't abort the rebase")
        Self.notifyChange()
    }

    /// Fetches the upstream and rebases onto it (git pull --rebase).
    func pullRebase(transfer: GitTransfer = GitTransfer()) throws -> GitRebaseResult {
        guard let branch = currentBranchName else { throw GitError("HEAD is detached: check out a branch to pull.") }
        let upstream = status().upstream ?? "origin/\(branch)"
        try fetch(String(upstream.split(separator: "/").first ?? "origin"), transfer: transfer)
        guard branches(remote: true).contains(where: { $0.name == upstream }) else { throw GitError("'\(upstream)' doesn't exist.") }
        if status().upstream == nil, headId != nil { try setUpstream(branch, to: upstream) }
        // Nothing of ours yet: just move to it.
        if headId == nil {
            _ = try merge(upstream)
            return .done(0)
        }
        return try rebase(onto: upstream)
    }
}

// MARK: - Merge options

enum GitMergeMode {
    /// A fast-forward when possible, else a merge commit (git merge).
    case normal
    /// Always a merge commit (git merge --no-ff).
    case noFastForward
    /// Only a fast-forward; refuse otherwise (git merge --ff-only).
    case fastForwardOnly
    /// The changes staged, without a merge commit (git merge --squash).
    case squash
}

extension GitRepository {
    func merge(_ branch: String, mode: GitMergeMode) throws -> GitMergeResult {
        guard mode != .normal else { return try merge(branch) }
        let target = try lookupCommit(branchSpec(branch))
        defer { git_object_free(target) }
        let theirs = git_commit_id(target)!
        var ours = git_oid()
        let unborn = git_reference_name_to_id(&ours, pointer, "HEAD") != 0
        if !unborn && (git_oid_equal(&ours, theirs) == 1 || git_graph_descendant_of(pointer, &ours, theirs) == 1) { return .upToDate }
        let canFastForward = unborn || git_graph_descendant_of(pointer, theirs, &ours) == 1
        if mode == .fastForwardOnly {
            guard canFastForward else { throw GitError("Not possible to fast-forward: the branches have diverged.") }
            return try merge(branch)
        }
        var mergeOptions = git_merge_options()
        git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var checkoutOptions = git_checkout_options()
        git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue | GIT_CHECKOUT_CONFLICT_STYLE_MERGE.rawValue
        var annotated: OpaquePointer?
        try Git.check(git_annotated_commit_lookup(&annotated, pointer, theirs))
        defer { git_annotated_commit_free(annotated) }
        var heads: [OpaquePointer?] = [annotated]
        try Git.check(heads.withUnsafeMutableBufferPointer { git_merge(pointer, $0.baseAddress, 1, &mergeOptions, &checkoutOptions) },
                      "Couldn't merge \(branch)")
        Self.notifyChange()
        let conflicted = conflicts()
        if mode == .squash {
            // Staged, with no merge in progress: the next commit is an ordinary one.
            git_repository_state_cleanup(pointer)
            return conflicted.isEmpty ? .merged : .conflicts(conflicted)
        }
        if !conflicted.isEmpty { return .conflicts(conflicted) }
        try commit(message: "Merge branch '\(branch)'")
        return .merged
    }

    /// Branches whose commits are all in HEAD (git branch --merged), or not (--no-merged).
    func branches(merged: Bool) -> [GitBranch] {
        var head = git_oid()
        guard git_reference_name_to_id(&head, pointer, "HEAD") == 0 else { return [] }
        return branches().filter { branch in
            var tip = git_oid()
            guard git_oid_fromstr(&tip, branch.tip) == 0 else { return false }
            let contained = git_oid_equal(&tip, &head) == 1 || git_graph_descendant_of(pointer, &head, &tip) == 1
            return contained == merged
        }
    }

    /// Deletes a branch on a remote (git push origin --delete branch).
    func deleteRemoteBranch(_ branch: String, remote remoteName: String = "origin", transfer: GitTransfer = GitTransfer()) throws {
        var remote: OpaquePointer?
        try Git.check(git_remote_lookup(&remote, pointer, remoteName), "There's no remote \(remoteName)")
        defer { git_remote_free(remote) }
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        transfer.install(&options.callbacks)
        let rc = Git.withStrings([":refs/heads/\(branch)"]) { git_remote_push(remote, $0, &options) }
        guard rc == 0 else { throw transfer.error(rc, "Couldn't delete \(branch) on \(remoteName)") }
        try? deleteBranch("\(remoteName)/\(branch)", force: true, remote: true)
        Self.notifyChange()
    }
}

// MARK: - Submodules

struct GitSubmodule: Hashable {
    let name: String
    let path: String
    let url: String
    /// The commit the parent repository records for it.
    let recorded: String?
    /// The commit checked out in it (nil when it isn't cloned yet).
    let checkedOut: String?
    let isCloned: Bool
    /// Its files have changes, or it's on another commit than the recorded one.
    let isModified: Bool
}

extension GitRepository {
    func submodules() -> [GitSubmodule] {
        final class Box { var names: [String] = [] }
        let box = Box()
        _ = git_submodule_foreach(pointer, { _, name, payload in
            Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue().names.append(Git.string(name))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.names.compactMap { name in
            var sm: OpaquePointer?
            guard git_submodule_lookup(&sm, pointer, name) == 0, let sm else { return nil }
            defer { git_submodule_free(sm) }
            var flags: UInt32 = 0
            git_submodule_status(&flags, pointer, name, GIT_SUBMODULE_IGNORE_UNSPECIFIED)
            let has = { (flag: git_submodule_status_t) in flags & flag.rawValue != 0 }
            let modified = has(GIT_SUBMODULE_STATUS_WD_MODIFIED) || has(GIT_SUBMODULE_STATUS_WD_INDEX_MODIFIED)
                || has(GIT_SUBMODULE_STATUS_WD_WD_MODIFIED) || has(GIT_SUBMODULE_STATUS_INDEX_MODIFIED)
            return GitSubmodule(name: name, path: Git.string(git_submodule_path(sm)), url: Git.string(git_submodule_url(sm)),
                                recorded: git_submodule_head_id(sm).map { Git.hex($0) }, checkedOut: git_submodule_wd_id(sm).map { Git.hex($0) },
                                isCloned: !has(GIT_SUBMODULE_STATUS_WD_UNINITIALIZED), isModified: modified)
        }
    }

    func isSubmodule(_ path: String) -> Bool { submodules().contains { $0.path == path } }

    /// Clones (when needed) and checks out the recorded commit of each submodule (or those in
    /// `paths`); `recursive` does the same inside them (git submodule update --init [--recursive]).
    @discardableResult
    func updateSubmodules(_ paths: [String] = [], recursive: Bool = true, transfer: GitTransfer = GitTransfer()) throws -> Int {
        var count = 0
        for submodule in submodules() where paths.isEmpty || paths.contains(submodule.path) {
            var sm: OpaquePointer?
            try Git.check(git_submodule_lookup(&sm, pointer, submodule.name), "There's no submodule \(submodule.path)")
            defer { git_submodule_free(sm) }
            var options = git_submodule_update_options()
            git_submodule_update_options_init(&options, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION))
            options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            options.allow_fetch = 1
            transfer.attempts = 0
            transfer.install(&options.fetch_opts.callbacks)
            let rc = git_submodule_update(sm, 1, &options)
            guard rc == 0 else { throw transfer.error(rc, "Couldn't update \(submodule.path)") }
            count += 1
            if recursive, let inner = try? GitRepository.open(root.appendingPathComponent(submodule.path)) {
                count += try inner.updateSubmodules(recursive: true, transfer: transfer)
            }
        }
        if count > 0 { Self.notifyChange() }
        return count
    }

    /// git submodule add <url> [path]: clones it into `path` and stages it.
    func addSubmodule(_ url: String, at path: String? = nil, transfer: GitTransfer = GitTransfer()) throws {
        let folder = path ?? (URL(string: url)?.deletingPathExtension().lastPathComponent ?? "submodule")
        var sm: OpaquePointer?
        try Git.check(git_submodule_add_setup(&sm, pointer, url, folder, 1), "Couldn't add \(url)")
        defer { git_submodule_free(sm) }
        var options = git_submodule_update_options()
        git_submodule_update_options_init(&options, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION))
        transfer.install(&options.fetch_opts.callbacks)
        var cloned: OpaquePointer?
        let rc = git_submodule_clone(&cloned, sm, &options)
        guard rc == 0 else { throw transfer.error(rc, "Couldn't clone \(url)") }
        git_repository_free(cloned)
        try Git.check(git_submodule_add_finalize(sm), "Couldn't add \(folder)")
        Self.notifyChange()
    }

    /// Copies each submodule's URL from .gitmodules to the config (git submodule sync).
    func syncSubmodules() throws {
        for submodule in submodules() {
            var sm: OpaquePointer?
            try Git.check(git_submodule_lookup(&sm, pointer, submodule.name))
            defer { git_submodule_free(sm) }
            try Git.check(git_submodule_sync(sm), "Couldn't sync \(submodule.path)")
        }
    }
}

// MARK: - More of git, for the Terminal

extension GitRepository {
    /// git reflog: where HEAD has been, newest first.
    func reflog(limit: Int = 100) -> [(id: String, message: String)] {
        var log: OpaquePointer?
        guard git_reflog_read(&log, pointer, "HEAD") == 0, let log else { return [] }
        defer { git_reflog_free(log) }
        return (0..<min(limit, git_reflog_entrycount(log))).compactMap { i in
            guard let entry = git_reflog_entry_byindex(log, i) else { return nil }
            return (Git.hex(git_reflog_entry_id_new(entry)), Git.string(git_reflog_entry_message(entry)))
        }
    }

    /// git describe --tags: the nearest tag, how far past it, and where.
    func describe() -> String? {
        guard let head = headCommit() else { return nil }
        defer { git_object_free(head) }
        var options = git_describe_options()
        git_describe_options_init(&options, UInt32(GIT_DESCRIBE_OPTIONS_VERSION))
        options.describe_strategy = GIT_DESCRIBE_TAGS.rawValue
        var result: OpaquePointer?
        guard git_describe_commit(&result, head, &options) == 0, let result else { return nil }
        defer { git_describe_result_free(result) }
        var format = git_describe_format_options()
        git_describe_format_options_init(&format, UInt32(GIT_DESCRIBE_FORMAT_OPTIONS_VERSION))
        return Git.buffer { git_describe_format($0, result, &format) }
    }

    /// git ls-files: the files in the index.
    func trackedFiles() -> [String] {
        guard let index = try? index() else { return [] }
        defer { git_index_free(index) }
        return (0..<git_index_entrycount(index)).compactMap { git_index_get_byindex(index, $0).map { Git.string($0.pointee.path) } }
    }

    /// git clean: deletes untracked files (and ignored ones with `ignored`); `dryRun` only lists them.
    func clean(ignored: Bool = false, dryRun: Bool) -> [String] {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_WORKDIR_ONLY
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        if ignored { options.flags |= GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue | GIT_STATUS_OPT_RECURSE_IGNORED_DIRS.rawValue }
        var list: OpaquePointer?
        guard git_status_list_new(&list, pointer, &options) == 0, let list else { return [] }
        defer { git_status_list_free(list) }
        var paths: [String] = []
        for i in 0..<git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, i)?.pointee else { continue }
            let flags = entry.status.rawValue
            guard flags & GIT_STATUS_WT_NEW.rawValue != 0 || (ignored && flags & GIT_STATUS_IGNORED.rawValue != 0) else { continue }
            let path = Git.string(entry.index_to_workdir?.pointee.new_file.path)
            paths.append(path)
            if !dryRun { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
        }
        if !dryRun { Self.notifyChange() }
        return paths
    }

    /// git cat-file -p / -t: an object's type and content.
    func object(_ spec: String) -> (type: String, text: String)? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, pointer, spec) == 0, let object else { return nil }
        defer { git_object_free(object) }
        let type = git_object_type(object)
        let name = Git.string(git_object_type2string(type))
        switch type {
        case GIT_OBJECT_BLOB:
            guard let raw = git_blob_rawcontent(object) else { return (name, "") }
            return (name, String(decoding: Data(bytes: raw, count: Int(git_blob_rawsize(object))), as: UTF8.self))
        case GIT_OBJECT_TREE:
            let lines = (0..<git_tree_entrycount(object)).compactMap { i -> String? in
                guard let entry = git_tree_entry_byindex(object, i) else { return nil }
                let kind = Git.string(git_object_type2string(git_tree_entry_type(entry)))
                return String(format: "%06o", git_tree_entry_filemode(entry).rawValue) + " \(kind) \(Git.hex(git_tree_entry_id(entry)))\t\(Git.string(git_tree_entry_name(entry)))"
            }
            return (name, lines.joined(separator: "\n") + "\n")
        case GIT_OBJECT_COMMIT:
            var text = "tree \(Git.hex(git_commit_tree_id(object)))\n"
            for i in 0..<git_commit_parentcount(object) { text += "parent \(Git.hex(git_commit_parent_id(object, i)))\n" }
            if let author = git_commit_author(object)?.pointee {
                text += "author \(Git.string(author.name)) <\(Git.string(author.email))> \(author.when.time)\n"
            }
            return (name, text + "\n" + Git.string(git_commit_message(object)))
        default:
            return (name, "")
        }
    }

    /// git mv: renames a file and stages both sides.
    func move(_ from: String, to: String) throws {
        let source = root.appendingPathComponent(from), target = root.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        try stage([from, to])
    }

    /// git grep: tracked files' lines matching `pattern` (a regular expression).
    func grep(_ pattern: String, ignoreCase: Bool) -> [(path: String, line: Int, text: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []) else { return [] }
        var hits: [(path: String, line: Int, text: String)] = []
        for path in trackedFiles() {
            guard let text = text(of: path, at: .index) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append((path, i + 1, line))
            }
        }
        return hits
    }
}
