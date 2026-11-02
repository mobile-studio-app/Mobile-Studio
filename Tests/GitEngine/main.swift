import Foundation
import Clibgit2

// Tests for the app's git (GitRepository on libgit2), run on CI before the app builds:
//   swiftc ... App/Git/*.swift Tests/GitEngine/*.swift (see .github/workflows/build-ipa.yml)
// Repositories are real ones in a temporary folder; a bare repository stands in for GitHub, so
// push, clone, fetch and pull run without a network.

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

func temporary(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("git-test-\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func newRepo() -> GitRepository { try! GitRepository.create(at: temporary("repo")) }

/// A bare repository, as a server has, whose HEAD is main (as GitHub's is).
func newRemote() -> URL {
    _ = Git.ready
    let url = temporary("remote")
    var options = git_repository_init_options()
    git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
    options.flags = GIT_REPOSITORY_INIT_BARE.rawValue | GIT_REPOSITORY_INIT_MKPATH.rawValue
    var repo: OpaquePointer?
    "main".withCString { name in
        options.initial_head = name
        precondition(git_repository_init_ext(&repo, url.path, &options) == 0)
    }
    git_repository_free(repo)
    return url
}

func write(_ repo: GitRepository, _ path: String, _ text: String) {
    let file = repo.root.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: file)
}

func read(_ repo: GitRepository, _ path: String) -> String? {
    (try? Data(contentsOf: repo.root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
}

func describe(_ status: GitStatus) -> String {
    "staged \(status.stagedFiles.map { "\($0.status.rawValue) \($0.path)" }), "
        + "changes \(status.changedFiles.map { "\($0.status.rawValue) \($0.path)" }), conflicts \(status.mergeConflicts.map(\.path))"
}

func checkClean(_ repo: GitRepository, _ what: String, line: UInt = #line) {
    let status = repo.status()
    check(status.isClean, "\(what): expected no changes, got \(describe(status))", line: line)
}

func expectError(_ what: String, line: UInt = #line, _ body: () throws -> Void) -> GitError? {
    do {
        try body()
        check(false, "\(what): expected an error", line: line)
        return nil
    } catch let error as GitError {
        return error
    } catch {
        check(false, "\(what): expected a GitError, got \(error)", line: line)
        return nil
    }
}

func attempt(_ what: String, line: UInt = #line, _ body: () throws -> Void) {
    do { try body() } catch { check(false, "\(what): \(error.localizedDescription)", line: line) }
}

// MARK: - Local

section("commit and status")
do {
    let repo = newRepo()
    check(GitRepository.isRepository(repo.root), "a new repository is one")
    check(repo.status().branch == "main" && repo.status().head == nil, "starts on main with no commits: \(String(describing: repo.status().branch))")
    write(repo, "main.lua", "print('hi')\n")
    write(repo, "lib/util.lua", "return {}\n")
    check(repo.status().changedFiles.map(\.status) == [.untracked, .untracked], "new files are untracked: \(describe(repo.status()))")
    attempt("stage all") { try repo.stageAll() }
    check(repo.status().stagedFiles.count == 2 && repo.status().stagedFiles.allSatisfy { $0.status == .added }, "staged as added: \(describe(repo.status()))")
    var first: GitCommit?
    attempt("commit") { first = try repo.commit(message: "First") }
    check(first?.id.count == 40 && first?.parents.isEmpty == true, "a real commit, the first")
    checkClean(repo, "after committing")
    check(repo.log().count == 1 && repo.log().first?.summary == "First", "history has it")
    check(repo.status().head == first?.id, "HEAD is the commit")

    write(repo, "main.lua", "print('hello')\n")
    check(repo.status().changedFiles.map(\.status) == [.modified], "an edit is a change")
    attempt("stage") { try repo.stage(["main.lua"]) }
    check(repo.status().stagedFiles.map(\.path) == ["main.lua"] && repo.status().changedFiles.isEmpty, "staged")
    attempt("unstage") { try repo.unstage(["main.lua"]) }
    check(repo.status().stagedFiles.isEmpty && repo.status().changedFiles.count == 1, "unstaged")
    check(repo.text(of: "main.lua", at: .index) == "print('hi')\n" && repo.text(of: "main.lua", at: .head) == "print('hi')\n", "the index and HEAD have the old text")
    attempt("discard") { try repo.discard(repo.status().changedFiles) }
    check(read(repo, "main.lua") == "print('hi')\n", "discarding restores the file")
    write(repo, "scratch.txt", "x")
    attempt("discard untracked") { try repo.discard(repo.status().changedFiles) }
    check(read(repo, "scratch.txt") == nil, "discarding an untracked file deletes it")
    checkClean(repo, "after discarding")

    let nothing = expectError("committing nothing") { try repo.commit(message: "Empty") }
    check(nothing?.code == GitError.nothingToCommit, "nothing to commit is said so")

    try? FileManager.default.removeItem(at: repo.root.appendingPathComponent("lib/util.lua"))
    attempt("commit -a with a deletion") { try repo.commit(message: "Remove util", stageAll: true) }
    check(repo.changes(inCommit: repo.status().head!).map { "\($0.status.rawValue) \($0.path)" } == ["D lib/util.lua"], "the commit's changes")
    check(repo.log().count == 2 && repo.log().last?.summary == "First", "newest first")
}

section("undo and amend")
do {
    let repo = newRepo()
    write(repo, "a.txt", "1\n")
    attempt("first") { try repo.commit(message: "One", stageAll: true) }
    write(repo, "a.txt", "2\n")
    attempt("second") { try repo.commit(message: "Two", stageAll: true) }
    var message = ""
    attempt("undo") { message = try repo.undoLastCommit() }
    check(message == "Two" && repo.log().count == 1, "the last commit is undone: \(message)")
    check(repo.status().stagedFiles.map(\.path) == ["a.txt"], "its changes stay staged")
    attempt("amend") { try repo.commit(message: "One and two", amend: true) }
    check(repo.log().count == 1 && repo.log().first?.summary == "One and two", "amending replaces the commit")
    checkClean(repo, "after amending")
    attempt("undo the first") { _ = try repo.undoLastCommit() }
    check(repo.log().isEmpty && repo.status().stagedFiles.count == 1, "undoing the first commit leaves none, its files staged")
}

section("branches and checkout")
do {
    let repo = newRepo()
    write(repo, "main.lua", "-- main\n")
    attempt("commit") { try repo.commit(message: "Base", stageAll: true) }
    attempt("create feature") { try repo.createBranch("feature") }
    check(repo.status().branch == "feature", "on the new branch")
    write(repo, "main.lua", "-- feature\n")
    write(repo, "new.lua", "-- new\n")
    attempt("commit on feature") { try repo.commit(message: "Feature work", stageAll: true) }
    attempt("back to main") { try repo.checkout("main") }
    check(read(repo, "main.lua") == "-- main\n" && read(repo, "new.lua") == nil, "main's files are back")
    checkClean(repo, "after switching")
    attempt("feature again") { try repo.checkout("feature") }
    check(read(repo, "new.lua") == "-- new\n", "feature's files are back")
    check(Set(repo.branches().map(\.name)) == ["main", "feature"] && repo.branches().first?.isHead == true, "branches: \(repo.branches().map(\.name))")

    attempt("main") { try repo.checkout("main") }
    write(repo, "main.lua", "-- local edit\n")
    let blocked = expectError("checkout over local changes") { try repo.checkout("feature") }
    check(blocked?.isConflict == true && blocked?.paths == ["main.lua"], "the change in the way is named: \(String(describing: blocked?.paths))")
    check(read(repo, "main.lua") == "-- local edit\n", "and kept")
    attempt("force") { try repo.checkout("feature", force: true) }
    check(read(repo, "main.lua") == "-- feature\n" && repo.status().branch == "feature", "force overwrites it")

    attempt("rename") { try repo.renameBranch("feature", to: "topic") }
    check(repo.status().branch == "topic", "renamed the checked-out branch")
    let notMerged = expectError("deleting the checked-out branch") { try repo.deleteBranch("topic") }
    check(notMerged != nil, "can't delete the checked-out branch")
    attempt("main") { try repo.checkout("main") }
    let unmerged = expectError("deleting an unmerged branch") { try repo.deleteBranch("topic") }
    check(unmerged?.code == GitError.notMerged, "an unmerged branch needs force")
    attempt("force delete") { try repo.deleteBranch("topic", force: true) }
    check(repo.branches().map(\.name) == ["main"], "deleted")

    let base = repo.status().head!
    attempt("detach") { try repo.checkout(commit: base) }
    check(repo.status().branch == nil && repo.status().head == base, "a detached HEAD")
    check(expectError("bad name") { try repo.createBranch("bad..name") } != nil, "invalid names are refused")
}

section("merge")
do {
    let repo = newRepo()
    write(repo, "a.txt", "one\ntwo\nthree\n")
    attempt("base") { try repo.commit(message: "Base", stageAll: true) }
    attempt("branch") { try repo.createBranch("feature") }
    write(repo, "b.txt", "feature\n")
    attempt("feature") { try repo.commit(message: "Add b", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    var result: GitMergeResult?
    attempt("fast-forward") { result = try repo.merge("feature") }
    if case .fastForward = result {} else { check(false, "expected a fast-forward, got \(String(describing: result))") }
    check(read(repo, "b.txt") == "feature\n" && repo.status().head == repo.branches().first { $0.name == "feature" }?.tip, "main moved to feature")
    attempt("again") { result = try repo.merge("feature") }
    if case .upToDate = result {} else { check(false, "expected up to date") }

    // Both change the same line: a conflict.
    attempt("branch 2") { try repo.createBranch("other") }
    write(repo, "a.txt", "one\nTWO (other)\nthree\n")
    attempt("other") { try repo.commit(message: "Other's two", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    write(repo, "a.txt", "one\nTWO (main)\nthree\n")
    attempt("main's") { try repo.commit(message: "Main's two", stageAll: true) }
    attempt("conflicting merge") { result = try repo.merge("other") }
    guard case .conflicts(let paths) = result else { check(false, "expected conflicts, got \(String(describing: result))"); exit(1) }
    check(paths == ["a.txt"] && repo.status().state == .merging && repo.status().mergingBranch == "other", "a conflict in a.txt, merging other")
    let text = read(repo, "a.txt") ?? ""
    check(text.contains("<<<<<<<") && text.contains("TWO (main)") && text.contains("TWO (other)") && text.contains(">>>>>>>"), "conflict markers: \(text)")
    check(expectError("committing with conflicts") { try repo.commit(message: "x") } != nil, "can't commit unresolved conflicts")
    write(repo, "a.txt", "one\nTWO (both)\nthree\n")
    attempt("resolve") { try repo.stage(["a.txt"]) }
    check(repo.status().mergeConflicts.isEmpty, "staging resolves it")
    attempt("merge commit") { try repo.commit(message: repo.mergeMessage ?? "Merge") }
    check(repo.log().first?.parents.count == 2 && repo.status().state == .none, "a merge commit, and the merge is over")
    checkClean(repo, "after the merge")

    // Abort.
    attempt("branch 3") { try repo.createBranch("third") }
    write(repo, "a.txt", "one\nthird\nthree\n")
    attempt("third") { try repo.commit(message: "Third", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    write(repo, "a.txt", "one\nmain again\nthree\n")
    attempt("main again") { try repo.commit(message: "Main again", stageAll: true) }
    attempt("merge third") { result = try repo.merge("third") }
    attempt("abort") { try repo.abortMerge() }
    check(read(repo, "a.txt") == "one\nmain again\nthree\n" && repo.status().state == .none, "aborting goes back")
    checkClean(repo, "after aborting")
}

section("revert, cherry-pick, reset")
do {
    let repo = newRepo()
    write(repo, "a.txt", "1\n")
    attempt("one") { try repo.commit(message: "One", stageAll: true) }
    write(repo, "a.txt", "2\n")
    var two: GitCommit?
    attempt("two") { two = try repo.commit(message: "Two", stageAll: true) }
    var result: GitMergeResult?
    attempt("revert") { result = try repo.revert(two!.id) }
    if case .merged = result {} else { check(false, "revert: \(String(describing: result))") }
    check(read(repo, "a.txt") == "1\n" && repo.log().first?.summary == "Revert \"Two\"", "reverted: \(String(describing: repo.log().first?.summary))")

    attempt("branch") { try repo.createBranch("pick", at: repo.log().last!.id) }
    write(repo, "b.txt", "b\n")
    var b: GitCommit?
    attempt("b") { b = try repo.commit(message: "Add b", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    attempt("cherry-pick") { result = try repo.cherryPick(b!.id) }
    check(read(repo, "b.txt") == "b\n" && repo.log().first?.summary == "Add b" && repo.log().first?.id != b?.id, "picked as a new commit")

    let count = repo.log().count
    attempt("reset hard") { try repo.reset(to: two!.id, mode: .hard) }
    check(repo.log().count == 2 && read(repo, "a.txt") == "2\n" && read(repo, "b.txt") == nil, "reset --hard")
    attempt("reset soft") { try repo.reset(to: repo.log().last!.id, mode: .soft) }
    check(repo.log().count == 1 && repo.status().stagedFiles.map(\.path) == ["a.txt"], "reset --soft keeps the changes staged (from \(count))")
}

section("stash")
do {
    let repo = newRepo()
    write(repo, "a.txt", "base\n")
    attempt("base") { try repo.commit(message: "Base", stageAll: true) }
    write(repo, "a.txt", "edited\n")
    write(repo, "new.txt", "new\n")
    attempt("stash") { try repo.stash(message: "work") }
    checkClean(repo, "after stashing")
    check(read(repo, "new.txt") == nil && repo.stashes().count == 1 && repo.stashes()[0].message.contains("work"), "stashed with untracked files")
    attempt("pop") { try repo.applyStash(0, drop: true) }
    check(read(repo, "a.txt") == "edited\n" && read(repo, "new.txt") == "new\n" && repo.stashes().isEmpty, "popped")
    attempt("stash again") { try repo.stash() }
    attempt("apply") { try repo.applyStash(0, drop: false) }
    check(repo.stashes().count == 1, "apply keeps it")
    attempt("drop all") { try repo.dropAllStashes() }
    check(repo.stashes().isEmpty, "dropped")
    attempt("clean up") { try repo.discard(repo.status().changedFiles) }
    check(expectError("stashing nothing") { try repo.stash() } != nil, "nothing to stash")
}

section("tags, config, blame, file history, patches")
do {
    let repo = newRepo()
    write(repo, "a.txt", "one\ntwo\n")
    attempt("one") { try repo.commit(message: "One", stageAll: true) }
    attempt("tag") { try repo.createTag("v1.0", message: "Release") }
    write(repo, "a.txt", "one\nTWO\nthree\n")
    write(repo, "b.txt", "b\n")
    attempt("two") { try repo.commit(message: "Two", stageAll: true) }
    attempt("light tag") { try repo.createTag("latest") }
    check(Set(repo.tags().map(\.name)) == ["v1.0", "latest"], "tags: \(repo.tags().map(\.name))")
    check(repo.tags().first { $0.name == "v1.0" }?.target == repo.log().last?.id, "an annotated tag points at its commit")
    check(repo.log().first?.refs.contains(GitRefLabel(name: "latest", kind: .tag)) == true && repo.log().first?.refs.first?.kind == .head, "the Graph's labels")
    attempt("delete tag") { try repo.deleteTag("latest") }
    check(repo.tags().map(\.name) == ["v1.0"], "deleted")

    attempt("config") { try repo.setConfig("user.name", "Someone") }
    attempt("email") { try repo.setConfig("user.email", "someone@example.com") }
    check(repo.config("user.name") == "Someone", "config set")
    write(repo, "a.txt", "one\nTWO\nthree\nfour\n")
    var three: GitCommit?
    attempt("three") { three = try repo.commit(message: "Three", stageAll: true) }
    check(three?.author == "Someone" && three?.email == "someone@example.com", "commits use user.name and user.email")

    let blame = repo.blame("a.txt", contents: "one\nTWO\nthree\nfour\nfive (not committed)\n")
    check(blame.count == 6, "a line each (and the last, empty one): \(blame.count)")
    check(blame[0]?.summary == "One" && blame[1]?.summary == "Two" && blame[3]?.summary == "Three" && blame[4] == nil, "blame: \(blame.map { $0?.summary ?? "-" })")
    check(repo.log(path: "a.txt").map(\.summary) == ["Three", "Two", "One"] && repo.log(path: "b.txt").map(\.summary) == ["Two"], "file history")

    let patch = repo.patch(.commit(three!.id))
    check(patch.contains("diff --git a/a.txt b/a.txt") && patch.contains("+four"), "a commit's patch: \(patch)")
    write(repo, "a.txt", "changed\n")
    check(repo.patch(.workingTree).contains("-one") && repo.patch(.workingTree).contains("+changed"), "the working tree's patch")
    check(repo.patch(.staged).isEmpty, "nothing staged")
}

section("remotes: push, clone, fetch, pull")
do {
    let server = newRemote()
    let mine = newRepo()
    write(mine, "main.lua", "-- v1\n")
    attempt("first") { try mine.commit(message: "First", stageAll: true) }
    attempt("remote") { try mine.setRemote(url: server.path) }
    check(mine.remotes() == [GitRemote(name: "origin", url: server.path)], "origin added")
    attempt("push") { try mine.push() }
    check(mine.status().upstream == "origin/main" && mine.status().aheadCount == 0, "pushed, with an upstream: \(String(describing: mine.status().upstream))")
    write(mine, "main.lua", "-- v2\n")
    attempt("second") { try mine.commit(message: "Second", stageAll: true) }
    check(mine.status().aheadCount == 1, "one to push")
    attempt("push again") { try mine.push() }
    check(mine.status().aheadCount == 0, "pushed")

    // Someone else clones it: the whole history comes along.
    var theirs: GitRepository?
    attempt("clone") { theirs = try GitRepository.clone(server.path, to: temporary("clone").appendingPathComponent("project")) }
    guard let theirs else { exit(1) }
    check(theirs.log().map(\.summary) == ["Second", "First"] && read(theirs, "main.lua") == "-- v2\n", "a clone has every commit")
    check(theirs.status().upstream == "origin/main", "and follows origin")
    write(theirs, "theirs.lua", "-- theirs\n")
    attempt("their commit") { try theirs.commit(message: "Theirs", stageAll: true) }
    attempt("their push") { try theirs.push() }

    attempt("fetch") { try mine.fetch() }
    check(mine.status().behindCount == 1 && read(mine, "theirs.lua") == nil, "fetching finds the new commit without merging it")
    var result: GitMergeResult?
    attempt("pull") { result = try mine.pull() }
    if case .fastForward = result {} else { check(false, "pull: \(String(describing: result))") }
    check(read(mine, "theirs.lua") == "-- theirs\n" && mine.status().behindCount == 0, "pulled")

    // Both commit: pushing is refused until pulling merges.
    write(mine, "mine.lua", "-- mine\n")
    attempt("mine") { try mine.commit(message: "Mine", stageAll: true) }
    write(theirs, "more.lua", "-- more\n")
    attempt("more") { try theirs.commit(message: "More", stageAll: true) }
    attempt("their push 2") { try theirs.push() }
    check(expectError("pushing behind") { try mine.push() } != nil, "a push that would lose their commit is refused")
    attempt("pull merges") { result = try mine.pull() }
    if case .merged = result {} else { check(false, "pull merge: \(String(describing: result))") }
    attempt("push after pull") { try mine.push() }
    check(mine.status().aheadCount == 0 && mine.status().behindCount == 0 && read(mine, "more.lua") == "-- more\n", "in sync")

    // A branch published, then checked out from the remote elsewhere.
    attempt("branch") { try mine.createBranch("feature") }
    write(mine, "f.lua", "-- f\n")
    attempt("f") { try mine.commit(message: "F", stageAll: true) }
    attempt("publish") { try mine.push() }
    attempt("their fetch") { try theirs.fetch() }
    check(theirs.branches(remote: true).map(\.name).contains("origin/feature"), "the branch shows as a remote one")
    attempt("checkout remote") { try theirs.checkoutRemote("origin/feature") }
    check(theirs.status().branch == "feature" && theirs.status().upstream == "origin/feature" && read(theirs, "f.lua") == "-- f\n", "a local branch following it")
    attempt("push tags") { try mine.createTag("v2"); try mine.pushTags() }
    attempt("fetch tags") { try theirs.fetch() }
    check(theirs.tags().map(\.name).contains("v2"), "tags come with a fetch")

    check(GitRepository.gitHubOwnerAndRepo("https://github.com/owner/repo.git")! == ("owner", "repo")
        && GitRepository.gitHubOwnerAndRepo("git@github.com:owner/repo.git")! == ("owner", "repo")
        && GitRepository.gitHubOwnerAndRepo("https://gitlab.com/owner/repo") == nil, "GitHub remotes are recognised")
}

section("the Graph's lanes")
do {
    func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, summary: id, message: id, author: "", email: "", date: Date(), parents: parents)
    }
    // m merges f into c; f and c both come from b.
    let rows = GitGraph.layout([commit("m", ["c", "f"]), commit("f", ["b"]), commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
    check(rows.map(\.node) == [0, 1, 0, 0, 0], "lanes: \(rows.map(\.node))")
    check(rows[0].outgoing == [0, 1], "the merge has two lines down")
    check(rows[2].passThrough == [1] && rows[3].incoming.sorted() == [0, 1], "the branch runs beside and joins at b: \(rows[2]) \(rows[3])")
    check(rows[4].outgoing.isEmpty && rows[4].below.isEmpty, "the first commit ends the lane")
}

section("git in the Terminal (GitCommandLine)")
do {
    let repo = newRepo()
    write(repo, "a.txt", "one\n")
    var out = await GitCommandLine.run(["status"], root: repo.root, cwd: repo.root)
    check(out.text.contains("No commits yet") && out.text.contains("a.txt"), "status: \(out.text)")
    _ = await GitCommandLine.run(["add", "."], root: repo.root, cwd: repo.root)
    out = await GitCommandLine.run(["commit", "-m", "Add a"], root: repo.root, cwd: repo.root)
    check(out.code == 0 && out.text.contains("Add a"), "commit: \(out.text)")
    write(repo, "a.txt", "one\ntwo\n")
    out = await GitCommandLine.run(["diff"], root: repo.root, cwd: repo.root)
    check(out.text.contains("+two"), "diff: \(out.text)")
    out = await GitCommandLine.run(["commit", "-am", "Two"], root: repo.root, cwd: repo.root)
    out = await GitCommandLine.run(["log", "--oneline"], root: repo.root, cwd: repo.root)
    check(out.text.contains("Two") && out.text.contains("Add a") && out.text.contains("HEAD -> "), "log: \(out.text)")
    out = await GitCommandLine.run(["checkout", "-b", "topic"], root: repo.root, cwd: repo.root)
    check(out.text.contains("Switched to a new branch 'topic'"), "checkout -b: \(out.text)")
    out = await GitCommandLine.run(["branch"], root: repo.root, cwd: repo.root)
    check(out.text.contains("topic") && out.text.contains("main"), "branch: \(out.text)")
    out = await GitCommandLine.run(["tag", "v1"], root: repo.root, cwd: repo.root)
    out = await GitCommandLine.run(["tag"], root: repo.root, cwd: repo.root)
    check(out.text == "v1\n", "tag: \(out.text)")
    out = await GitCommandLine.run(["show", "HEAD"], root: repo.root, cwd: repo.root)
    check(out.text.contains("+two") && out.text.contains("Author:"), "show: \(out.text)")
    out = await GitCommandLine.run(["frobnicate"], root: repo.root, cwd: repo.root)
    check(out.code != 0, "unknown commands fail")
}

section("rebase")
do {
    let repo = newRepo()
    write(repo, "a.txt", "one\ntwo\nthree\n")
    attempt("base") { try repo.commit(message: "Base", stageAll: true) }
    attempt("feature") { try repo.createBranch("feature") }
    write(repo, "f1.txt", "f1\n")
    attempt("f1") { try repo.commit(message: "F1", stageAll: true) }
    write(repo, "f2.txt", "f2\n")
    attempt("f2") { try repo.commit(message: "F2", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    write(repo, "m.txt", "m\n")
    attempt("m") { try repo.commit(message: "M", stageAll: true) }
    attempt("feature again") { try repo.checkout("feature") }
    var result: GitRebaseResult?
    attempt("rebase") { result = try repo.rebase(onto: "main") }
    if case .done(let count) = result { check(count == 2, "two commits replayed: \(count)") } else { check(false, "rebase: \(String(describing: result))") }
    check(repo.log().map(\.summary) == ["F2", "F1", "M", "Base"], "linear history on top of main: \(repo.log().map(\.summary))")
    check(repo.status().branch == "feature" && repo.status().state == .none && read(repo, "m.txt") == "m\n", "still on feature, done")
    checkClean(repo, "after the rebase")
    attempt("again") { result = try repo.rebase(onto: "main") }
    if case .upToDate = result {} else { check(false, "a second rebase has nothing to do") }

    // A conflict: fix, stage, continue.
    attempt("main 2") { try repo.checkout("main") }
    write(repo, "a.txt", "one\nTWO (main)\nthree\n")
    attempt("main's") { try repo.commit(message: "Main's two", stageAll: true) }
    attempt("feature 2") { try repo.checkout("feature") }
    write(repo, "a.txt", "one\nTWO (feature)\nthree\n")
    attempt("feature's") { try repo.commit(message: "Feature's two", stageAll: true) }
    attempt("conflicting rebase") { result = try repo.rebase(onto: "main") }
    guard case .conflicts(let paths) = result else { check(false, "expected conflicts: \(String(describing: result))"); exit(1) }
    check(paths == ["a.txt"] && repo.status().state == .rebasing, "stopped at the conflict, rebasing")
    check(expectError("continuing unresolved") { _ = try repo.continueRebase() } != nil, "can't continue with conflicts")
    write(repo, "a.txt", "one\nTWO (both)\nthree\n")
    attempt("resolve") { try repo.stage(["a.txt"]) }
    attempt("continue") { result = try repo.continueRebase() }
    if case .done = result {} else { check(false, "continue: \(String(describing: result))") }
    check(repo.log().map(\.summary) == ["Feature's two", "F2", "F1", "Main's two", "M", "Base"] && repo.status().state == .none,
          "continued and finished: \(repo.log().map(\.summary))")
    check(read(repo, "a.txt") == "one\nTWO (both)\nthree\n", "the fixed text is kept")

    // Abort.
    attempt("main 3") { try repo.checkout("main") }
    write(repo, "a.txt", "main 3\n")
    attempt("m3") { try repo.commit(message: "M3", stageAll: true) }
    attempt("feature 3") { try repo.checkout("feature") }
    let before = repo.status().head
    write(repo, "a.txt", "feature 3\n")
    attempt("f3") { try repo.commit(message: "F3", stageAll: true) }
    let tip = repo.status().head
    attempt("rebase 3") { result = try repo.rebase(onto: "main") }
    attempt("abort") { try repo.abortRebase() }
    check(repo.status().head == tip && repo.status().branch == "feature" && repo.status().state == .none && before != tip, "aborting goes back to the branch as it was")
    checkClean(repo, "after aborting")
}

section("merge options")
do {
    let repo = newRepo()
    write(repo, "a.txt", "a\n")
    attempt("base") { try repo.commit(message: "Base", stageAll: true) }
    attempt("feature") { try repo.createBranch("feature") }
    write(repo, "b.txt", "b\n")
    attempt("b") { try repo.commit(message: "B", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    var result: GitMergeResult?
    attempt("no-ff") { result = try repo.merge("feature", mode: .noFastForward) }
    check(repo.log().first?.parents.count == 2, "--no-ff makes a merge commit: \(String(describing: result))")
    attempt("other") { try repo.createBranch("other", at: repo.log().last!.id, checkout: true) }
    write(repo, "c.txt", "c\n")
    attempt("c") { try repo.commit(message: "C", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    check(expectError("ff-only on diverged") { _ = try repo.merge("other", mode: .fastForwardOnly) } != nil, "--ff-only refuses a real merge")
    attempt("squash") { result = try repo.merge("other", mode: .squash) }
    check(repo.status().stagedFiles.map(\.path) == ["c.txt"] && repo.status().state == .none, "--squash stages the changes, no merge in progress")
    attempt("commit the squash") { try repo.commit(message: "Squashed C") }
    check(repo.log().first?.parents.count == 1, "an ordinary commit")
    check(Set(repo.branches(merged: true).map(\.name)) == ["main", "feature"] && repo.branches(merged: false).map(\.name) == ["other"], "--merged and --no-merged")
}

section("submodules")
do {
    // A library repository, published to its own server.
    let libraryServer = newRemote()
    let library = newRepo()
    write(library, "lib.lua", "return 'lib'\n")
    attempt("library") { try library.commit(message: "Library", stageAll: true) }
    attempt("library remote") { try library.setRemote(url: libraryServer.path) }
    attempt("library push") { try library.push() }

    let appServer = newRemote()
    let app = newRepo()
    write(app, "main.lua", "require('lib')\n")
    attempt("app") { try app.commit(message: "App", stageAll: true) }
    attempt("add submodule") { try app.addSubmodule(libraryServer.path, at: "vendor/lib") }
    check(read(app, "vendor/lib/lib.lua") == "return 'lib'\n" && read(app, ".gitmodules")?.contains("vendor/lib") == true, "added and cloned")
    check(app.submodules().map(\.path) == ["vendor/lib"] && app.isSubmodule("vendor/lib"), "listed")
    attempt("commit it") { try app.commit(message: "Add lib", stageAll: true) }
    attempt("app remote") { try app.setRemote(url: appServer.path) }
    attempt("app push") { try app.push() }

    // Someone clones the app: the submodule comes too.
    var clone: GitRepository?
    attempt("clone") { clone = try GitRepository.clone(appServer.path, to: temporary("subclone").appendingPathComponent("app")) }
    check(clone.flatMap { read($0, "vendor/lib/lib.lua") } == "return 'lib'\n", "a clone checks the submodule out")
    check(clone?.submodules().first?.isCloned == true && clone?.submodules().first?.checkedOut == clone?.submodules().first?.recorded, "at the recorded commit")

    var shallow: GitRepository?
    attempt("clone without") { shallow = try GitRepository.clone(appServer.path, to: temporary("subclone2").appendingPathComponent("app"), submodules: false) }
    check(shallow?.submodules().first?.isCloned == false, "--no-recurse-submodules leaves it")
    var count = 0
    attempt("update") { count = try shallow?.updateSubmodules() ?? 0 }
    check(count == 1 && shallow.flatMap { read($0, "vendor/lib/lib.lua") } == "return 'lib'\n", "update --init clones it")
}

section("more of git in the Terminal")
do {
    let repo = newRepo()
    write(repo, "a.txt", "alpha\nbeta\n")
    _ = await GitCommandLine.run(["add", "."], root: repo.root, cwd: repo.root)
    _ = await GitCommandLine.run(["commit", "-m", "First"], root: repo.root, cwd: repo.root)
    _ = await GitCommandLine.run(["tag", "v1"], root: repo.root, cwd: repo.root)
    write(repo, "a.txt", "alpha\nbeta\ngamma\n")
    _ = await GitCommandLine.run(["commit", "-am", "Second"], root: repo.root, cwd: repo.root)
    let run = { (args: [String]) async -> GitCommandLine.Output in await GitCommandLine.run(args, root: repo.root, cwd: repo.root) }
    var out = await run(["log", "--format=%h %s"])
    check(out.text.split(separator: "\n").count == 2 && out.text.contains(" Second"), "log --format: \(out.text)")
    out = await run(["diff", "--stat", "HEAD~1"])
    check(out.text.contains("a.txt") && out.text.contains("1 insertion"), "diff --stat: \(out.text)")
    out = await run(["blame", "a.txt"])
    check(out.text.contains("gamma") && out.text.split(separator: "\n").count == 3, "blame: \(out.text)")
    out = await run(["describe"])
    check(out.text.hasPrefix("v1-1-g"), "describe: \(out.text)")
    out = await run(["ls-files"])
    check(out.text == "a.txt\n", "ls-files: \(out.text)")
    out = await run(["grep", "-n", "bet"])
    check(out.text.contains("a.txt") && out.text.contains("beta"), "grep: \(out.text)")
    out = await run(["shortlog", "-s"])
    check(out.text.contains("2\t"), "shortlog -s: \(out.text)")
    out = await run(["cat-file", "-t", "HEAD"])
    check(out.text == "commit\n", "cat-file -t: \(out.text)")
    out = await run(["rev-list", "--count", "HEAD"])
    check(out.text == "2\n", "rev-list --count: \(out.text)")
    write(repo, "junk.tmp", "x")
    out = await run(["clean", "-n"])
    check(out.text.contains("Would remove junk.tmp") && read(repo, "junk.tmp") != nil, "clean -n: \(out.text)")
    out = await run(["clean", "-f"])
    check(read(repo, "junk.tmp") == nil, "clean -f deletes it")
    _ = await run(["checkout", "-b", "topic"])
    out = await run(["checkout", "-"])
    check(out.text.contains("main") && repo.status().branch == "main", "checkout -: \(out.text)")
    out = await run(["reflog"])
    check(out.text.contains("HEAD@{0}"), "reflog: \(out.text)")
    _ = await run(["mv", "a.txt", "b.txt"])
    check(read(repo, "b.txt") != nil && repo.status().stagedFiles.contains { $0.path == "b.txt" }, "mv stages the move: \(describe(repo.status()))")
    out = await run(["status", "-sb"])
    check(out.text.hasPrefix("## main"), "status -sb: \(out.text)")
}

section("conflicts for the merge editor")
do {
    let repo = newRepo()
    write(repo, "a.txt", "one\ntwo\nthree\n")
    attempt("base") { try repo.commit(message: "Base", stageAll: true) }
    attempt("branch") { try repo.createBranch("feature") }
    write(repo, "a.txt", "one\nTWO (feature)\nthree\n")
    attempt("feature") { try repo.commit(message: "Feature", stageAll: true) }
    attempt("main") { try repo.checkout("main") }
    write(repo, "a.txt", "one\nTWO (main)\nthree\n")
    attempt("main's") { try repo.commit(message: "Main", stageAll: true) }
    _ = try? repo.merge("feature")
    let text = read(repo, "a.txt") ?? ""
    check(text.contains("|||||||") && text.contains("\ntwo\n"), "the markers include the common ancestor (diff3): \(text)")
    let conflict = repo.conflict("a.txt")
    check(conflict?.base == "one\ntwo\nthree\n" && conflict?.ours == "one\nTWO (main)\nthree\n" && conflict?.theirs == "one\nTWO (feature)\nthree\n",
          "the index's three versions: \(String(describing: conflict))")
    check(conflict?.operation == "merge" && conflict?.oursLabel == "main" && conflict?.theirsLabel == "feature",
          "named: \(String(describing: conflict?.oursLabel)) / \(String(describing: conflict?.theirsLabel))")
    attempt("abort") { try repo.abortMerge() }
}

section("interactive rebase")
do {
    let repo = newRepo()
    write(repo, "a.txt", "base\n")
    attempt("base") { try repo.commit(message: "Base", stageAll: true) }
    let base = repo.status().head!
    for (file, message) in [("one.txt", "One"), ("two.txt", "Two"), ("three.txt", "Three"), ("four.txt", "Four")] {
        write(repo, file, message + "\n")
        attempt(message) { try repo.commit(message: message, stageAll: true) }
    }
    var steps: [GitRebaseStep] = []
    attempt("plan") { steps = try repo.rebasePlan(onto: base) }
    check(steps.map(\.summary) == ["One", "Two", "Three", "Four"] && steps.allSatisfy { $0.action == .pick }, "the plan, oldest first: \(steps.map(\.summary))")
    // Reword One, fold Two into it, drop Three, and move Four first.
    steps[0].action = .reword
    steps[0].message = "One (reworded)\n"
    steps[1].action = .fixup
    steps[2].action = .drop
    let four = steps.removeLast()
    steps.insert(four, at: 0)
    var result: GitInteractiveResult?
    attempt("rebase") { result = try repo.interactiveRebase(steps, onto: base) }
    if case .done = result {} else { check(false, "interactive rebase: \(String(describing: result))") }
    check(repo.log().map(\.summary) == ["One (reworded)", "Four", "Base"], "the new history: \(repo.log().map(\.summary))")
    check(read(repo, "two.txt") == "Two\n" && read(repo, "three.txt") == nil, "fixup kept Two's change; Three was dropped")
    check(repo.status().branch == "main" && repo.status().state == .none && repo.interactiveRebase == nil, "back on main, finished")
    checkClean(repo, "after the interactive rebase")

    // Edit: stop, amend, continue.
    attempt("plan 2") { steps = try repo.rebasePlan(onto: base) }
    steps[0].action = .edit
    attempt("edit") { result = try repo.interactiveRebase(steps, onto: base) }
    if case .stoppedToEdit(let step) = result { check(step.summary == "Four", "stopped after Four") } else { check(false, "edit: \(String(describing: result))") }
    check(repo.status().state == .rebasing, "rebasing while stopped")
    write(repo, "four.txt", "Four, amended\n")
    attempt("amend") { try repo.commit(message: "Four (amended)", stageAll: true, amend: true) }
    attempt("continue") { result = try repo.continueInteractiveRebase() }
    check(repo.log().map(\.summary) == ["One (reworded)", "Four (amended)", "Base"] && read(repo, "four.txt") == "Four, amended\n", "amended in place: \(repo.log().map(\.summary))")

    // A conflict from reordering: fix, stage, continue.
    write(repo, "a.txt", "base\nfirst\n")
    attempt("first") { try repo.commit(message: "First edit", stageAll: true) }
    write(repo, "a.txt", "base\nfirst\nsecond\n")
    attempt("second") { try repo.commit(message: "Second edit", stageAll: true) }
    attempt("plan 3") { steps = try repo.rebasePlan(onto: base) }
    steps.swapAt(steps.count - 1, steps.count - 2)
    attempt("conflicting") { result = try repo.interactiveRebase(steps, onto: base) }
    guard case .conflicts(let paths) = result else { check(false, "expected conflicts: \(String(describing: result))"); exit(1) }
    check(paths == ["a.txt"] && repo.status().state == .rebasing && repo.conflict("a.txt")?.operation == "rebase", "stopped at the conflict")
    write(repo, "a.txt", "base\nfirst\nsecond\n")
    attempt("resolve") { try repo.stage(["a.txt"]) }
    attempt("continue 2") { result = try repo.continueInteractiveRebase() }
    if case .conflicts = result { write(repo, "a.txt", "base\nfirst\nsecond\n"); attempt("resolve 2") { try repo.stage(["a.txt"]) }; attempt("continue 3") { result = try repo.continueInteractiveRebase() } }
    if case .done = result {} else { check(false, "finished: \(String(describing: result))") }
    check(repo.log().first.map { ["First edit", "Second edit"].contains($0.summary) } == true && repo.status().state == .none, "reordered: \(repo.log().map(\.summary))")

    // Abort goes back.
    let tip = repo.status().head
    attempt("plan 4") { steps = try repo.rebasePlan(onto: base) }
    steps[0].action = .edit
    attempt("start") { result = try repo.interactiveRebase(steps, onto: base) }
    attempt("abort") { try repo.abortInteractiveRebase() }
    check(repo.status().head == tip && repo.status().branch == "main" && repo.interactiveRebase == nil, "aborting restores the branch")
    checkClean(repo, "after aborting")
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
