import Foundation

// Tests for GitManager, run on CI before the app builds:
//   swiftc -swift-version 5 App/Git/GitManager.swift Tests/GitEngine/*.swift -o git-tests && ./git-tests
// The recurring check is that the status is clean whenever nothing was edited, and that pushes
// only send files that changed: the "every file changed" bug from an earlier build.

URLProtocol.registerClass(FakeGitHub.self)
let git = GitManager.shared
var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("  FAIL (line \(line)): \(what())")
    }
}

func section(_ name: String) { print("• \(name)") }

func newRepo(remote: Bool = true) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("git-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try! git.initRepo(at: url)
    if remote { git.setRemoteURL("https://github.com/owner/repo", in: url) }
    return url
}

func write(_ root: URL, _ path: String, _ text: String) {
    let file = root.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: file)
}

func read(_ root: URL, _ path: String) -> String? {
    (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
}

func remove(_ root: URL, _ path: String) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
}

/// The project's visible files as text.
func files(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    let base = root.standardizedFileURL.path + "/"
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
    for case let url as URL in e where !url.hasDirectoryPath {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(base) { out[String(path.dropFirst(base.count))] = read(root, String(path.dropFirst(base.count))) }
    }
    return out
}

func describe(_ status: GitStatus) -> String {
    "staged \(status.stagedFiles.map { "\($0.status.rawValue) \($0.path)" }), "
        + "changes \(status.changedFiles.map { "\($0.status.rawValue) \($0.path)" }), conflicts \(status.mergeConflicts.map(\.path))"
}

func checkClean(_ root: URL, _ what: String, line: UInt = #line) {
    let status = git.status(in: root)
    check(status.isClean, "\(what): expected no changes, got \(describe(status))", line: line)
}

func wait<T>(_ start: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    start { result = $0 }
    let deadline = Date().addingTimeInterval(30)
    while result == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    guard let result else { fatalError("timed out") }
    return result
}

@discardableResult
func push(_ root: URL, line: UInt = #line) -> Int {
    switch wait({ git.push(in: root, completion: $0) }) {
    case .success(let count): return count
    case .failure(let error):
        check(false, "push failed: \(error.localizedDescription)", line: line)
        return -1
    }
}

@discardableResult
func pull(_ root: URL, line: UInt = #line) -> Int {
    switch wait({ git.pull(in: root, completion: $0) }) {
    case .success(let count): return count
    case .failure(let error):
        check(false, "pull failed: \(error.localizedDescription)", line: line)
        return -1
    }
}

func expectError(_ what: String, code: Int? = nil, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "\(what): expected an error", line: line)
    } catch {
        if let code { check((error as NSError).code == code, "\(what): expected code \(code), got \((error as NSError).code)", line: line) }
    }
}

// MARK: - Local

section("commit and status")
do {
    let repo = newRepo(remote: false)
    write(repo, "main.lua", "print('a')\n")
    write(repo, "lib/util.lua", "return {}\n")
    check(git.status(in: repo).changedFiles.count == 2, "two new files")
    try git.commit(message: "first", all: true, in: repo)
    checkClean(repo, "after commit")
    checkClean(repo, "status again")
    write(repo, "main.lua", "print('changed')\n")
    let status = git.status(in: repo)
    check(status.changedFiles.map(\.path) == ["main.lua"] && status.changedFiles.first?.status == .modified, "one modified file: \(describe(status))")
    expectError("commit with nothing staged") { try git.commit(message: "x", in: repo) }
    try git.stage(["main.lua"], in: repo)
    check(git.status(in: repo).stagedFiles.map(\.path) == ["main.lua"], "staged")
    try git.commit(message: "second", in: repo)
    checkClean(repo, "after staged commit")
    check(git.history(in: repo).count == 2, "two commits")
}

section("checkout switches files and leaves nothing changed")
do {
    let repo = newRepo(remote: false)
    write(repo, "a.lua", "a = 1\n")
    write(repo, "b.lua", "b = 1\n")
    try git.commit(message: "base", all: true, in: repo)
    try git.createBranch("feature", in: repo)
    check(git.currentBranch(in: repo) == "feature", "on feature")
    checkClean(repo, "after creating a branch")
    write(repo, "a.lua", "a = 2 -- feature\n")
    write(repo, "src/new.lua", "new = true\n")
    remove(repo, "b.lua")
    try git.commit(message: "feature work", all: true, in: repo)
    checkClean(repo, "after feature commit")

    try git.checkout("main", in: repo)
    check(git.currentBranch(in: repo) == "main", "on main")
    check(files(repo) == ["a.lua": "a = 1\n", "b.lua": "b = 1\n"], "main's files: \(files(repo))")
    check(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("src").path), "empty folder removed")
    checkClean(repo, "after checkout main")
    check(git.history(in: repo).count == 1, "main has one commit")

    try git.checkout("feature", in: repo)
    check(files(repo) == ["a.lua": "a = 2 -- feature\n", "src/new.lua": "new = true\n"], "feature's files: \(files(repo))")
    checkClean(repo, "after checkout feature")
    check(git.history(in: repo).count == 2, "feature has two commits")
    for _ in 0..<3 {
        try git.checkout("main", in: repo)
        try git.checkout("feature", in: repo)
    }
    checkClean(repo, "after switching back and forth")

    // Edits to files that are the same on both branches come along.
    try git.checkout("main", in: repo)
    write(repo, "b.lua", "b = 99 -- local edit\n")
    expectError("checkout over a local change", code: GitManager.checkoutConflictCode) { try git.checkout("feature", in: repo) }
    check(git.currentBranch(in: repo) == "main" && read(repo, "b.lua") == "b = 99 -- local edit\n", "failed checkout changed nothing")
    try git.discardChanges(for: "b.lua", in: repo)
    write(repo, "notes.txt", "todo\n")
    try git.checkout("feature", in: repo)
    check(read(repo, "notes.txt") == "todo\n", "untracked file came along")
    let carried = git.status(in: repo)
    check(carried.changedFiles.map(\.path) == ["notes.txt"], "only the carried file is changed: \(describe(carried))")
    remove(repo, "notes.txt")

    // Forced checkout throws the local change away.
    write(repo, "a.lua", "a = 3 -- unsaved\n")
    try git.checkout("main", force: true, in: repo)
    check(read(repo, "a.lua") == "a = 1\n", "forced checkout wrote main's a.lua")
    checkClean(repo, "after forced checkout")

    expectError("bad branch name") { try git.createBranch("bad..name", in: repo) }
    expectError("duplicate branch") { try git.createBranch("feature", in: repo) }
    try git.createBranch("my feature", checkout: false, in: repo)
    check(git.branches(in: repo).contains("my-feature"), "spaces become dashes")
    try git.createBranch("topic/nested", in: repo)
    check(git.branches(in: repo).contains("topic/nested"), "nested branch listed")
    try git.checkout("main", in: repo)
    try git.renameBranch("topic/nested", to: "topic-renamed", in: repo)
    check(git.branches(in: repo).contains("topic-renamed") && !git.branches(in: repo).contains("topic/nested"), "renamed")
    expectError("delete current branch") { try git.deleteBranch("main", in: repo) }
    try git.deleteBranch("topic-renamed", in: repo)
    expectError("delete unmerged branch", code: 409) { try git.deleteBranch("feature", in: repo) }
    check(git.branches(in: repo).contains("feature"), "unmerged branch kept")
}

section("stash")
do {
    let repo = newRepo(remote: false)
    write(repo, "a.lua", "one\n")
    try git.commit(message: "base", all: true, in: repo)
    write(repo, "a.lua", "two\n")
    write(repo, "b.lua", "new file\n")
    try git.stage(["b.lua"], in: repo)
    try git.stash(in: repo)
    check(files(repo) == ["a.lua": "one\n"], "stash put files back: \(files(repo))")
    checkClean(repo, "after stash")
    check(git.stashes(in: repo).count == 1, "one stash")
    try git.applyStash(drop: true, in: repo)
    check(files(repo) == ["a.lua": "two\n", "b.lua": "new file\n"], "pop restored files")
    let status = git.status(in: repo)
    check(status.stagedFiles.map(\.path) == ["b.lua"] && status.changedFiles.map(\.path) == ["a.lua"], "pop restored staging: \(describe(status))")
    check(git.stashes(in: repo).isEmpty, "pop dropped the stash")

    // Stash, switch branch, pop there.
    try git.stash(message: "move me", in: repo)
    try git.createBranch("other", in: repo)
    try git.applyStash(drop: true, in: repo)
    check(read(repo, "a.lua") == "two\n", "stash applied on another branch")
}

section("merge")
do {
    let repo = newRepo(remote: false)
    write(repo, "game.lua", "line1\nline2\nline3\nline4\nline5\n")
    write(repo, "other.lua", "x\n")
    try git.commit(message: "base", all: true, in: repo)

    // Fast-forward.
    try git.createBranch("ff", in: repo)
    write(repo, "other.lua", "x2\n")
    try git.commit(message: "ff change", all: true, in: repo)
    try git.checkout("main", in: repo)
    guard case .fastForward = try git.merge("ff", in: repo) else { fatalError("expected fast-forward") }
    check(read(repo, "other.lua") == "x2\n", "fast-forward moved files")
    check(git.tip(of: "main", in: repo) == git.tip(of: "ff", in: repo), "fast-forward moved the branch")
    checkClean(repo, "after fast-forward")
    guard case .upToDate = try git.merge("ff", in: repo) else { fatalError("expected up to date") }

    // Clean three-way merge of different lines in one file.
    try git.createBranch("left", in: repo)
    write(repo, "game.lua", "LINE1\nline2\nline3\nline4\nline5\n")
    try git.commit(message: "left", all: true, in: repo)
    try git.checkout("main", in: repo)
    write(repo, "game.lua", "line1\nline2\nline3\nline4\nLINE5\n")
    write(repo, "added.lua", "added on main\n")
    try git.commit(message: "main side", all: true, in: repo)
    guard case .merged = try git.merge("left", in: repo) else { fatalError("expected merged") }
    check(read(repo, "game.lua") == "LINE1\nline2\nline3\nline4\nLINE5\n", "both edits kept: \(read(repo, "game.lua") ?? "")")
    checkClean(repo, "after merge commit")
    check(git.history(in: repo).first?.isMerge == true, "merge commit recorded")

    // Conflict.
    try git.createBranch("clash", in: repo)
    write(repo, "game.lua", "LINE1\nfrom clash\nline3\nline4\nLINE5\n")
    try git.commit(message: "clash", all: true, in: repo)
    try git.checkout("main", in: repo)
    write(repo, "game.lua", "LINE1\nfrom main\nline3\nline4\nLINE5\n")
    try git.commit(message: "main clash", all: true, in: repo)
    guard case .conflicts(let paths) = try git.merge("clash", in: repo) else { fatalError("expected conflicts") }
    check(paths == ["game.lua"], "conflict in game.lua")
    check(read(repo, "game.lua")?.contains("<<<<<<< HEAD\nfrom main\n=======\nfrom clash\n>>>>>>> clash\n") == true, "conflict markers written")
    let merging = git.status(in: repo)
    check(merging.mergeConflicts.map(\.path) == ["game.lua"] && merging.mergingBranch == "clash", "status shows the conflict")
    expectError("commit with an unresolved conflict") { try git.commit(message: "", in: repo) }
    expectError("checkout during a merge") { try git.checkout("clash", in: repo) }
    try git.stage(["game.lua"], in: repo)
    expectError("commit with markers left in") { try git.commit(message: "", in: repo) }
    write(repo, "game.lua", "LINE1\nfrom both\nline3\nline4\nLINE5\n")
    try git.stage(["game.lua"], in: repo)
    try git.commit(message: "", in: repo)
    check(git.history(in: repo).first?.message == "Merge branch 'clash' into main", "merge message used")
    checkClean(repo, "after resolving")

    // Abort.
    try git.checkout("clash", in: repo)
    write(repo, "game.lua", "again from clash\n")
    try git.commit(message: "clash 2", all: true, in: repo)
    try git.checkout("main", in: repo)
    write(repo, "game.lua", "again from main\n")
    try git.commit(message: "main 2", all: true, in: repo)
    _ = try git.merge("clash", in: repo)
    try git.abortMerge(in: repo)
    check(read(repo, "game.lua") == "again from main\n", "abort restored the file")
    checkClean(repo, "after abort")
}

section("undo and amend")
do {
    let repo = newRepo(remote: false)
    write(repo, "a.lua", "1\n")
    try git.commit(message: "one", all: true, in: repo)
    write(repo, "a.lua", "22\n")
    try git.commit(message: "two", all: true, in: repo)
    let message = try git.undoLastCommit(in: repo)
    check(message == "two", "undo returns the message")
    check(git.status(in: repo).stagedFiles.map(\.path) == ["a.lua"], "undone change is staged")
    try git.commit(message: "two again", in: repo)
    try git.commit(message: "two, amended", amend: true, in: repo)
    check(git.history(in: repo).map(\.message) == ["two, amended", "one"], "amend replaced the commit")
    checkClean(repo, "after amend")
}

section("migrating a repository from an older build")
do {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-legacy-\(UUID().uuidString)")
    let gitDir = repo.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
    var tree1: [String: String] = [:], tree2: [String: String] = [:]
    for (path, text, tree) in [("a.lua", "old\n", 1), ("a.lua", "new\n", 2), ("b.lua", "same\n", 0)] {
        let data = Data(text.utf8)
        let sha = GitManager.blobSHA(data)
        try data.write(to: gitDir.appendingPathComponent("objects/\(sha)"))
        if tree != 2 { tree1[path] = sha }
        if tree != 1 { tree2[path] = sha }
    }
    let log: [[String: Any]] = [
        ["hash": "c2c2c2c2", "author": "me", "timestamp": 2.0, "message": "second", "tree": tree2],
        ["hash": "c1c1c1c1", "author": "me", "timestamp": 1.0, "message": "first", "tree": tree1],
    ]
    try JSONSerialization.data(withJSONObject: log).write(to: gitDir.appendingPathComponent("commits.json"))
    try JSONEncoder().encode(tree2).write(to: gitDir.appendingPathComponent("index.json"))
    try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    try "dev".write(to: gitDir.appendingPathComponent("refs/heads/dev"), atomically: true, encoding: .utf8)   // old builds wrote the name
    try JSONEncoder().encode(["commit": "c1c1c1c1"]).write(to: gitDir.appendingPathComponent("pushed.json"))
    write(repo, "a.lua", "new\n")
    write(repo, "b.lua", "same\n")

    checkClean(repo, "legacy repo after migration")
    check(git.tip(of: "main", in: repo) == "c2c2c2c2" && git.tip(of: "dev", in: repo) == "c2c2c2c2", "branches point at the newest commit")
    check(git.upstream(of: "main", in: repo) == "c1c1c1c1", "sync point kept")
    check(git.status(in: repo).aheadCount == 1, "one commit to push")
    check(git.history(in: repo).map(\.id) == ["c2c2c2c2", "c1c1c1c1"], "history linked")
    try git.checkout("dev", in: repo)
    checkClean(repo, "legacy repo after checkout")
}

// MARK: - GitHub

section("push sends only changed files")
do {
    FakeGitHub.reset()
    let head = FakeGitHub.seed("main", files: ["main.lua": "print(1)\n", "conf.lua": "-- conf\n", "assets/readme.txt": "hi\n", ".gitignore": "*.tmp\n"])
    let repo = newRepo()
    check(pull(repo) == 3, "first pull brings the three visible files")
    check(files(repo) == ["main.lua": "print(1)\n", "conf.lua": "-- conf\n", "assets/readme.txt": "hi\n"], "pulled files")
    checkClean(repo, "after first pull")
    check(git.status(in: repo).hasUpstream, "pull set the sync point")
    check(push(repo) == 0 && FakeGitHub.blobUploads == 0 && FakeGitHub.treePaths.isEmpty, "nothing to push after pull")

    write(repo, "main.lua", "print(2)\n")
    try git.commit(message: "edit main", all: true, in: repo)
    check(git.status(in: repo).aheadCount == 1, "one commit ahead")
    check(push(repo) == 1, "one commit pushed")
    check(FakeGitHub.blobUploads == 1 && FakeGitHub.treePaths == ["main.lua"], "only main.lua sent: \(FakeGitHub.treePaths)")
    check(FakeGitHub.parents(FakeGitHub.refs["main"]!) == [head], "pushed on top of GitHub's head")
    check(FakeGitHub.files("main")[".gitignore"] == "*.tmp\n", "hidden files on GitHub left alone")
    check(git.status(in: repo).aheadCount == 0, "nothing ahead after push")
    FakeGitHub.treePaths = []
    check(push(repo) == 0 && FakeGitHub.treePaths.isEmpty, "second push sends nothing")
    checkClean(repo, "after push")

    // A change made on GitHub comes down; nothing goes back up.
    FakeGitHub.seed("main", files: ["main.lua": "print(2)\n", "conf.lua": "-- conf v2\n", "assets/readme.txt": "hi\n", ".gitignore": "*.tmp\n"])
    check(pull(repo) == 1, "pull brought conf.lua")
    check(read(repo, "conf.lua") == "-- conf v2\n", "conf.lua updated")
    checkClean(repo, "after second pull")
    FakeGitHub.treePaths = []
    check(push(repo) == 0 && FakeGitHub.treePaths.isEmpty, "push after pull sends nothing")

    // A new branch is published on top of the commit it started from.
    try git.createBranch("feature", in: repo)
    check(!git.status(in: repo).hasUpstream, "new branch has no upstream")
    write(repo, "assets/readme.txt", "hello\n")
    try git.commit(message: "readme", all: true, in: repo)
    let mainHead = FakeGitHub.refs["main"]!
    FakeGitHub.treePaths = []
    check(push(repo) == 1, "feature published")
    check(FakeGitHub.refs["feature"] != nil, "branch created on GitHub")
    check(FakeGitHub.parents(FakeGitHub.refs["feature"]!) == [mainHead], "feature builds on main's head")
    check(FakeGitHub.treePaths == ["assets/readme.txt"], "only the readme sent: \(FakeGitHub.treePaths)")
    check(git.status(in: repo).hasUpstream, "feature now has an upstream")
    check(FakeGitHub.refs["main"] == mainHead, "main untouched")

    // Back on main, the branch's files are gone and nothing looks changed.
    try git.checkout("main", in: repo)
    check(read(repo, "assets/readme.txt") == "hi\n", "main's readme")
    checkClean(repo, "main after publishing feature")
    FakeGitHub.treePaths = []
    check(push(repo) == 0 && FakeGitHub.treePaths.isEmpty, "main has nothing to push")

    // Merge the branch and push the merge.
    guard case .fastForward = try git.merge("feature", in: repo) else { fatalError("expected fast-forward") }
    FakeGitHub.treePaths = []
    push(repo)
    check(FakeGitHub.files("main") == FakeGitHub.files("feature"), "main matches feature on GitHub")
    check(FakeGitHub.treePaths.isEmpty, "fast-forward push sent no files: \(FakeGitHub.treePaths)")
    checkClean(repo, "after merge push")

    // A branch that only exists on GitHub.
    FakeGitHub.seed("art", files: ["main.lua": "print(2)\n", "conf.lua": "-- conf v2\n", "assets/readme.txt": "hello\n", "art/logo.txt": "logo\n"])
    let remoteNames = wait { git.remoteBranches(in: repo, completion: $0) }
    check((try? remoteNames.get())?.contains("art") == true, "remote branches listed")
    let checkout = wait { git.checkoutRemoteBranch("art", in: repo, completion: $0) }
    if case .failure(let error) = checkout { check(false, "checkout origin/art failed: \(error.localizedDescription)") }
    check(git.currentBranch(in: repo) == "art" && read(repo, "art/logo.txt") == "logo\n", "on art with its files")
    checkClean(repo, "after checking out a GitHub branch")
    FakeGitHub.treePaths = []
    check(push(repo) == 0 && FakeGitHub.treePaths.isEmpty, "a fresh GitHub branch has nothing to push")

    // Conflicting edits on both sides stop the pull before anything is written.
    try git.checkout("main", in: repo)
    write(repo, "conf.lua", "-- local\n")
    try git.commit(message: "local conf", all: true, in: repo)
    FakeGitHub.seed("main", files: FakeGitHub.files("main").merging(["conf.lua": "-- remote\n"]) { $1 })
    switch wait({ git.pull(in: repo, completion: $0) }) {
    case .success: check(false, "pull should stop on a conflict")
    case .failure(let error): check((error as NSError).code == 409, "pull conflict code")
    }
    check(read(repo, "conf.lua") == "-- local\n", "local file untouched")
}

// MARK: - AI merge answers

section("cleaning AI conflict resolutions")
do {
    let request = ConflictRequest(path: "main.lua", ours: "    speed = 200\n", theirs: "    speed = 120\n    jump = 400\n", base: nil,
                                  before: "function love.load()\n", after: "end\n\nfunction love.draw()\n    x = 1\n",
                                  oursLabel: "HEAD", theirsLabel: "feature")
    let prompt = ConflictResolver.fillInPrompt(request)
    check(prompt.prefix.hasPrefix("function love.load()\n") && prompt.prefix.hasSuffix("-- Merged version:\n"), "prompt ends where the merge goes")
    check(prompt.prefix.contains("--     jump = 400") && prompt.suffix == request.after, "prompt shows both versions")

    let clean = { (raw: String) in ConflictResolver.clean(raw, for: request) }
    check(clean("```lua\n-- Merged version:\n    speed = 200\n    jump = 400\n```") == "    speed = 200\n    jump = 400\n", "fences and echoes removed")
    check(clean("    speed = 200\n    jump = 400\nend\n\nfunction love.draw()\n") == "    speed = 200\n    jump = 400\n",
          "run-on into the following code trimmed: \(String(describing: clean("    speed = 200\n    jump = 400\nend\n\nfunction love.draw()\n")))")
    check(clean("<<<<<<< HEAD\n    speed = 200\n=======\n") == nil, "conflict markers rejected")
    check(clean("-- speed = 200\n-- speed = 120\n") == nil, "commented-out copy rejected")
    check(clean("\n\n") == nil, "empty answer rejected")

    let block = ConflictRequest(path: "main.lua", ours: "    if a then\n    end\n", theirs: "    if b then\n    end\n", base: nil,
                                before: "", after: "end\n", oursLabel: "HEAD", theirsLabel: "feature")
    check(ConflictResolver.clean("    if a or b then\n    end\n", for: block) == "    if a or b then\n    end\n", "a legitimate closing line is kept")
    check(ConflictResolver.comment(for: "fx.glsl") == "//" && ConflictResolver.comment(for: "tool.py") == "#", "comment syntax by language")
}

// MARK: - Extension compatibility

section("VS Code extension compatibility")
do {
    func analyze(_ manifest: [String: Any], _ platforms: [String], _ code: String? = nil) -> ExtensionCompatibility {
        ExtensionCompatibility.analyze(manifest: manifest, platforms: platforms, nodeCode: code)
    }
    let native = analyze(["main": "./client/out/extension", "contributes": ["configuration": [:]]], ["darwin-arm64", "linux-x64", "win32-x64"])
    check(native.level == .unsupported, "platform-specific (native) extension blocked")
    check(native.notes.first?.contains("macOS programs") == true, "a macOS build says its programs can't run yet: \(native.notes)")
    let mac = ExtensionCompatibility.analyze(manifest: ["main": "./client/out/extension", "contributes": ["configuration": [:]]],
                                             platforms: ["darwin-arm64", "linux-x64"], nodeCode: "module.exports = {}", macPrograms: true)
    check(mac.level == .unsupported && !mac.canInstall, "a macOS build is blocked even with a certificate, for now: \(mac.notes)")
    let linuxOnly = ExtensionCompatibility.analyze(manifest: ["main": "./x"], platforms: ["linux-x64", "win32-x64"], macPrograms: true)
    check(linuxOnly.level == .unsupported, "no macOS build is still blocked")

    let theme = analyze(["contributes": ["themes": [["label": "Dracula", "path": "./theme.json"]]]], ["universal"])
    check(theme.level == .full && theme.canInstall, "theme extension works: \(theme.notes)")

    let web = analyze(["browser": "./dist/web/extension.js", "contributes": ["commands": [["command": "x.y"]]]], ["universal"])
    check(web.level == .full, "web extension works")

    let nodeWithGrammar = analyze(["main": "./out/extension.js", "contributes": ["grammars": [[:]], "languages": [[:]]]], ["universal"])
    check(nodeWithGrammar.level == .partial && nodeWithGrammar.canInstall, "Node extension with a grammar installs partly")

    let nodeOnly = analyze(["main": "./out/extension.js", "contributes": ["commands": [["command": "a"]]]], ["universal"])
    check(nodeOnly.level == .partial && nodeOnly.canInstall, "Node-only extension, code unknown: partly")

    let nodeClean = analyze(["main": "./out/extension.js", "contributes": ["commands": [["command": "a"]]]], ["universal"],
                            "const cp = require('child_process'); cp.fork(serverPath, ['--node-ipc']); vscode.commands.registerCommand('a.b', f)")
    check(nodeClean.level == .full, "Node extension that only forks Node.js scripts works: \(nodeClean.notes)")

    let nodeGit = analyze(["main": "./out/extension.js"], ["universal"], "cp.spawn('git', ['status']); execFile(\"/usr/bin/python3\", args)")
    check(nodeGit.level == .partial && nodeGit.notes.joined().contains("git") && nodeGit.notes.joined().contains("python3"),
          "Node extension that starts programs is partly supported: \(nodeGit.notes)")

    let nodeNative = analyze(["main": "./out/extension.js", "dependencies": ["keytar": "^7"]], ["universal"], "module.exports = {}")
    check(nodeNative.level == .partial, "Node extension with native dependencies is partly supported")

    let nodeAddon = analyze(["main": "./out/extension.js"], ["universal"], "require('./build/Release/addon.node')")
    check(nodeAddon.level == .partial, "Node extension loading a .node addon is partly supported")

    let nativeShipped = ExtensionCompatibility.analyze(manifest: ["main": "./out/extension.js", "dependencies": ["fancy-db": "^1"]],
                                                       platforms: ["universal"], nodeCode: "require('fancy-db')", nativePackages: ["fancy-db"])
    check(nativeShipped.level == .partial && nativeShipped.notes.joined().contains("fancy-db"),
          "Node extension shipping a package that builds native code is partly supported: \(nativeShipped.notes)")
    check(ExtensionCompatibility.buildsNativeCode(["gypfile": true]) && ExtensionCompatibility.buildsNativeCode(["scripts": ["install": "node-gyp rebuild"]])
          && !ExtensionCompatibility.buildsNativeCode(["scripts": ["test": "mocha"]]), "packages that build native code are recognised")

    let treeView = analyze(["main": "./out/extension.js", "contributes": ["views": ["explorer": [["id": "todo", "name": "Todo"]]],
                                                                          "viewsContainers": ["activitybar": [[:]]], "customEditors": [[:]],
                                                                          "taskDefinitions": [[:]]]], ["universal"], "vscode.window.createTreeView('todo', {})")
    check(treeView.level == .full, "views, custom editors and tasks are supported: \(treeView.notes)")

    let languagePack = analyze(["categories": ["Language Packs"], "contributes": ["localizations": [[:]]]], ["universal"])
    check(languagePack.level == .unsupported, "language pack blocked")

    let pack = analyze(["extensionPack": ["a.b", "c.d"]], ["universal"])
    check(pack.canInstall, "extension pack installs (members checked separately)")

    let debugger = analyze(["browser": "./web.js", "contributes": ["debuggers": [[:]], "snippets": [[:]]]], ["web"])
    check(debugger.level == .partial, "desktop-only contributions make it partial: \(debugger.notes)")
}

section("git in the Terminal (GitCommandLine) and line diffs")
do {
    /// Runs a git command line as the Terminal does, waiting for it.
    func runGit(_ args: [String], _ root: URL, cwd: URL? = nil) -> GitCommandLine.Output {
        var result: GitCommandLine.Output?
        Task { @MainActor in result = await GitCommandLine.run(args, root: root, cwd: cwd ?? root) }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        return result!
    }
    func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }

    let edits = LineDiff.diff(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"])
    check(edits == [.same("a"), .removed("b"), .added("x"), .same("c"), .same("d"), .added("e")], "line diff: \(edits)")
    let ten = (1...10).map(String.init).joined(separator: "\n") + "\n"
    let hunk = LineDiff.unified(old: ten, new: ten.replacingOccurrences(of: "\n5\n", with: "\nfive\n"), path: "f.txt")
    check(hunk.contains("@@ -2,7 +2,7 @@") && hunk.contains("-5\n+five\n"), "unified hunk with 3 lines of context: \(hunk)")
    check(LineDiff.unified(old: "same\n", new: "same\n", path: "f") == "", "no diff for the same text")
    let created = LineDiff.unified(old: "", new: "a\nb\n", path: "n", isNew: true)
    check(created.contains("--- /dev/null") && created.contains("@@ -0,0 +1,2 @@"), "new file diff: \(created)")

    let repo = newRepo(remote: false)
    write(repo, "src/app.js", "one\ntwo\n")
    var out = plain(runGit(["status"], repo).text)
    check(out.contains("Untracked files") && out.contains("src/app.js"), "status lists untracked files: \(out)")
    let added = runGit(["add", "app.js"], repo, cwd: repo.appendingPathComponent("src"))
    check(added.code == 0, "add from a subfolder: \(added.text)")
    out = plain(runGit(["status", "-s"], repo).text)
    check(out.contains("src/app.js") && !out.hasPrefix(" ") && !out.hasPrefix("??"), "the file is staged: \(out)")
    let commit = runGit(["commit", "-m", "First"], repo)
    check(commit.code == 0 && plain(commit.text).contains("First"), "commit -m: \(commit.text)")
    out = plain(runGit(["log", "--oneline"], repo).text)
    check(out.contains("First"), "log --oneline: \(out)")
    check(runGit(["checkout", "-b", "feature"], repo).code == 0 && git.currentBranch(in: repo) == "feature", "checkout -b")
    out = plain(runGit(["branch"], repo).text)
    check(out.contains("* feature") && out.contains("  main"), "branch lists both, current starred: \(out)")
    write(repo, "src/app.js", "one\nTWO\n")
    out = plain(runGit(["diff"], repo).text)
    check(out.contains("-two") && out.contains("+TWO") && out.contains("a/src/app.js"), "diff shows the change: \(out)")
    check(runGit(["stash"], repo).code == 0 && read(repo, "src/app.js") == "one\ntwo\n", "stash puts the change away")
    check(runGit(["stash", "pop"], repo).code == 0 && read(repo, "src/app.js") == "one\nTWO\n", "stash pop brings it back")
    check(runGit(["frobnicate"], repo).code == 1, "an unknown command fails")
    check(runGit(["add", "missing.txt"], repo).code == 128, "adding a path with no changes fails")
}

section("git blame")
do {
    // Newest first: c3 changed line 2 and added "d"; c2 added "c"; c1 made the file.
    let v1 = "a\nb\n"
    let v2 = "a\nb\nc\n"
    let v3 = "a\nB\nc\nd\n"
    let current = "a\nB\nc\nd\nnew\n"
    let owners = LineDiff.blame(current: current, versions: [v3, v2, v1])
    check(owners == [2, 0, 1, 0, nil], "each line's commit, and uncommitted lines: \(owners)")
    check(LineDiff.blame(current: "x\n", versions: []) == [nil], "no history: nothing committed")
    check(LineDiff.blame(current: "a\n", versions: ["a\n", nil]) == [0], "the commit that created the file")
    check(LineDiff.blame(current: "a\nb\n", versions: ["a\nb\n", "a\nb\n", "a\n"]) == [2, 1], "commits that didn't touch the file are skipped")
    check(LineDiff.mapping(from: ["a", "x", "c"], to: ["a", "b", "c"]) == [0, nil, 2], "line mapping")
}

section("settings.json: JSON with comments")
do {
    let text = """
        // User settings
        {
            /* the editor */
            "editor.fontSize": 14,   // points
            "files.exclude": { "**/.git": true, },
            "url": "https://example.com/a//b",
            "note": "not /* a comment */ here",
            "list": [1, 2, 3,],
        }
        """
    let value = JSONC.object(text)
    check(value != nil, "parses with comments and trailing commas: \(JSONC.strip(text))")
    check((value?["editor.fontSize"] as? NSNumber)?.intValue == 14, "number value")
    check(value?["url"] as? String == "https://example.com/a//b", "// inside a string isn't a comment")
    check(value?["note"] as? String == "not /* a comment */ here", "/* */ inside a string isn't a comment")
    check((value?["list"] as? [Any])?.count == 3, "trailing comma in a list")
    check(((value?["files.exclude"] as? [String: Any])?["**/.git"] as? NSNumber)?.boolValue == true, "nested object with a trailing comma")
    check(JSONC.object("") != nil && JSONC.object("  // only a comment\n") != nil, "an empty file is an empty object")
    check(JSONC.object("{ \"a\": }") == nil, "invalid JSON is refused")
    check((try? JSONC.parse("[ { \"key\": \"ctrl+k\", \"command\": \"x\" }, ]")) is [Any], "keybindings.json's list")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
