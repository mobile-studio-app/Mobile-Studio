import Foundation

/// `git` in the Terminal: the usual commands on libgit2 (GitRepository), answered as git would,
/// with git's colours. Paths are relative to the folder the command runs in.
enum GitCommandLine {
    struct Output {
        var text = ""
        var code: Int32 = 0
    }

    private static let red = "\u{1B}[31m", green = "\u{1B}[32m", yellow = "\u{1B}[33m", cyan = "\u{1B}[36m",
                        bold = "\u{1B}[1m", off = "\u{1B}[0m"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(_ args: [String], root: URL, cwd: URL) async -> Output {
        guard let command = args.first else { return Output(text: usage) }
        let rest = Array(args.dropFirst())
        if command == "help" || command == "--help" || command == "-h" || command == "--version" {
            return Output(text: command == "--version" ? "git version 2 (libgit2)\n" : usage)
        }
        if command == "clone" { return await clone(rest, cwd: cwd) }
        if command == "init" {
            if GitRepository.isRepository(root) { return Output(text: "Reinitialized existing Git repository in \(root.path)/.git/\n") }
            do {
                try GitRepository.create(at: root, branch: value(after: ["-b", "--initial-branch"], in: rest) ?? "main")
                return Output(text: "Initialized empty Git repository in \(root.path)/.git/\n")
            } catch {
                return Output(text: "fatal: \(error.localizedDescription)\n", code: 128)
            }
        }
        guard let git = try? GitRepository.open(root) else {
            return Output(text: "fatal: not a git repository (run git init)\n", code: 128)
        }
        do {
            switch command {
            case "status": return Output(text: status(git.status(), short: rest.contains("-s") || rest.contains("--short")))
            case "add": try add(rest, git: git, cwd: cwd)
            case "rm": try remove(rest, git: git, cwd: cwd)
            case "reset": return Output(text: try reset(rest, git: git, cwd: cwd))
            case "restore": try restore(rest, git: git, cwd: cwd)
            case "commit": return Output(text: try commit(rest, git: git))
            case "log": return Output(text: log(rest, git: git))
            case "show": return Output(text: try show(rest, git: git))
            case "diff": return Output(text: try diff(rest, git: git, cwd: cwd))
            case "branch": return Output(text: try branch(rest, git: git))
            case "checkout", "switch": return Output(text: try checkout(command, rest, git: git, cwd: cwd))
            case "merge":
                if rest.contains("--abort") { try git.abortMerge(); return Output() }
                guard let name = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git merge <branch>\n", code: 1) }
                return merged(try git.merge(name))
            case "revert":
                if rest.contains("--abort") { try git.abortMerge(); return Output() }
                guard let id = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git revert <commit>\n", code: 1) }
                return merged(try git.revert(id))
            case "cherry-pick":
                if rest.contains("--abort") { try git.abortMerge(); return Output() }
                guard let id = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git cherry-pick <commit>\n", code: 1) }
                return merged(try git.cherryPick(id))
            case "stash": return Output(text: try stash(rest, git: git))
            case "tag": return Output(text: try tag(rest, git: git))
            case "remote": return Output(text: try remote(rest, git: git))
            case "fetch", "pull", "push": return await network(command, rest, root: root)
            case "rev-parse":
                if rest.contains("--abbrev-ref") { return Output(text: git.status().currentBranch + "\n") }
                if rest.contains("--show-toplevel") { return Output(text: root.path + "\n") }
                let spec = rest.first { !$0.hasPrefix("-") } ?? "HEAD"
                guard let commit = git.commit(spec) else { return Output(text: "fatal: ambiguous argument '\(spec)'\n", code: 128) }
                return Output(text: (rest.contains("--short") ? commit.shortId : commit.id) + "\n")
            case "config": return Output(text: try config(rest, git: git))
            default:
                return Output(text: "git: '\(command)' isn't available here. See 'git help'.\n", code: 1)
            }
        } catch {
            return Output(text: "fatal: \(error.localizedDescription)\n", code: 128)
        }
        return Output()
    }

    static let usage = """
        usage: git <command> [<args>]

        Mobile Studio's git (libgit2; works with GitHub and any HTTPS Git server):
           init [-b branch], clone <url> [folder]
           status [-s], add <paths>|., rm [--cached] <paths>, restore [--staged] <paths>
           reset [<paths>] | [--soft|--mixed|--hard] <commit>
           commit -m <message> [-a] [--amend], log [--oneline] [--graph] [--all] [-n N] [path]
           show [commit], diff [--staged] [commit [commit]] [paths]
           branch [-a|-r] [-d|-D|-m] [name] [start], checkout|switch [-b|-c] <branch>|<commit>
           merge|revert|cherry-pick <branch or commit> [--abort]
           stash [push [-m msg]|list|pop|apply|drop|clear], tag [-a name -m msg] [-d name]
           fetch [remote] [--prune], pull, push [-u] [-f] [--tags] [remote] [branch]
           remote [-v] | add|set-url|remove|rename ..., config [--global] key [value], rev-parse

        """

    // MARK: - Commands

    private static func value(after flags: [String], in args: [String]) -> String? {
        for (i, arg) in args.enumerated() {
            if flags.contains(arg), i + 1 < args.count { return args[i + 1] }
            for flag in flags where flag.hasPrefix("--") && arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    private static func status(_ status: GitStatus, short: Bool) -> String {
        if short {
            var lines: [String] = []
            for file in status.mergeConflicts { lines.append("\(red)UU\(off) \(file.path)") }
            for file in status.stagedFiles { lines.append("\(green)\(file.status.rawValue)\(off)  \(file.oldPath.map { "\($0) -> " } ?? "")\(file.path)") }
            for file in status.changedFiles {
                lines.append(file.status == .untracked ? "\(red)??\(off) \(file.path)" : " \(red)\(file.status.rawValue)\(off) \(file.path)")
            }
            return lines.map { $0 + "\n" }.joined()
        }
        var text = status.branch.map { "On branch \($0)\n" } ?? "\(red)HEAD detached at \(status.currentBranch)\(off)\n"
        if let merging = status.mergingBranch { text += "You have unmerged paths (merging \(merging)).\n" }
        if status.state == .reverting { text += "You are currently reverting a commit.\n" }
        if status.state == .cherryPicking { text += "You are currently cherry-picking a commit.\n" }
        if let upstream = status.upstream {
            if status.aheadCount > 0 && status.behindCount > 0 {
                text += "Your branch and '\(upstream)' have diverged,\nand have \(status.aheadCount) and \(status.behindCount) different commits each, respectively.\n"
            } else if status.aheadCount > 0 {
                text += "Your branch is ahead of '\(upstream)' by \(status.aheadCount) commit\(status.aheadCount == 1 ? "" : "s").\n"
            } else if status.behindCount > 0 {
                text += "Your branch is behind '\(upstream)' by \(status.behindCount) commit\(status.behindCount == 1 ? "" : "s"), and can be fast-forwarded.\n"
            } else {
                text += "Your branch is up to date with '\(upstream)'.\n"
            }
        }
        if status.head == nil { text += "\nNo commits yet\n" }
        let label: (GitChangedFile) -> String = {
            switch $0.status {
            case .added: return "new file:   \($0.path)"
            case .deleted: return "deleted:    \($0.path)"
            case .renamed: return "renamed:    \($0.oldPath ?? "") -> \($0.path)"
            case .typeChanged: return "typechange: \($0.path)"
            case .conflicted: return "both modified:   \($0.path)"
            default: return "modified:   \($0.path)"
            }
        }
        if !status.mergeConflicts.isEmpty {
            text += "\nUnmerged paths:\n" + status.mergeConflicts.map { "\t\(red)\(label($0))\(off)\n" }.joined()
        }
        if !status.stagedFiles.isEmpty {
            text += "\nChanges to be committed:\n" + status.stagedFiles.map { "\t\(green)\(label($0))\(off)\n" }.joined()
        }
        let tracked = status.changedFiles.filter { $0.status != .untracked }
        let untracked = status.changedFiles.filter { $0.status == .untracked }
        if !tracked.isEmpty {
            text += "\nChanges not staged for commit:\n" + tracked.map { "\t\(red)\(label($0))\(off)\n" }.joined()
        }
        if !untracked.isEmpty {
            text += "\nUntracked files:\n" + untracked.map { "\t\(red)\($0.path)\(off)\n" }.joined()
        }
        if status.isClean { text += "\nnothing to commit, working tree clean\n" }
        return text
    }

    private static func add(_ args: [String], git: GitRepository, cwd: URL) throws {
        let paths = args.filter { !$0.hasPrefix("-") }
        if args.contains("-A") || args.contains("--all") || (paths == ["."] && cwd.standardizedFileURL == git.root.standardizedFileURL) {
            try git.stageAll()
            return
        }
        let status = git.status()
        let candidates = (status.changedFiles + status.mergeConflicts).map(\.path)
        try git.stage(try matching(paths, candidates: candidates, root: git.root, cwd: cwd))
    }

    private static func remove(_ args: [String], git: GitRepository, cwd: URL) throws {
        let paths = try matching(args, candidates: allFiles(git), root: git.root, cwd: cwd)
        if args.contains("--cached") {
            // Out of the index (untracked), kept on disk.
            try git.removeFromIndex(paths)
        } else {
            for path in paths { try? FileManager.default.removeItem(at: git.root.appendingPathComponent(path)) }
            try git.stage(paths)
        }
    }

    private static func allFiles(_ git: GitRepository) -> [String] {
        let status = git.status()
        var files = Set(status.changedFiles.map(\.path) + status.stagedFiles.map(\.path))
        let base = git.root.standardizedFileURL.path
        if let walker = FileManager.default.enumerator(atPath: base) {
            for case let path as String in walker where !path.hasPrefix(".git") { files.insert(path) }
        }
        return Array(files)
    }

    private static func reset(_ args: [String], git: GitRepository, cwd: URL) throws -> String {
        let mode: GitResetMode? = args.contains("--hard") ? .hard : args.contains("--soft") ? .soft : args.contains("--mixed") ? .mixed : nil
        let rest = args.filter { !$0.hasPrefix("-") }
        if let target = rest.first, git.commit(target) != nil, mode != nil || rest.count == 1 && !FileManager.default.fileExists(atPath: cwd.appendingPathComponent(target).path) {
            try git.reset(to: target, mode: mode ?? .mixed)
            if mode == .hard, let commit = git.commit("HEAD") { return "HEAD is now at \(commit.shortId) \(commit.summary)\n" }
            return ""
        }
        if mode == .hard {
            try git.reset(to: "HEAD", mode: .hard)
            return git.commit("HEAD").map { "HEAD is now at \($0.shortId) \($0.summary)\n" } ?? ""
        }
        let paths = rest.filter { $0 != "HEAD" }
        if paths.isEmpty { try git.unstageAll() } else {
            try git.unstage(try matching(paths, candidates: git.status().stagedFiles.map(\.path), root: git.root, cwd: cwd))
        }
        return ""
    }

    private static func restore(_ args: [String], git: GitRepository, cwd: URL) throws {
        let paths = args.filter { !$0.hasPrefix("-") }
        let status = git.status()
        if args.contains("--staged") || args.contains("-S") {
            try git.unstage(try matching(paths, candidates: status.stagedFiles.map(\.path), root: git.root, cwd: cwd))
        } else {
            let chosen = Set(try matching(paths, candidates: status.changedFiles.filter { $0.status != .untracked }.map(\.path), root: git.root, cwd: cwd))
            try git.discard(status.changedFiles.filter { chosen.contains($0.path) })
        }
    }

    private static func commit(_ args: [String], git: GitRepository) throws -> String {
        var message: String?
        var all = false
        var amend = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--amend" { amend = true } else if a == "-a" || a == "--all" { all = true } else if a == "-m" || a == "--message" {
                i += 1
                if i < args.count { message = (message.map { $0 + "\n\n" } ?? "") + args[i] }
            } else if a.hasPrefix("-") && a.contains("m") && !a.hasPrefix("--") {
                // Combined short flags: -am "message".
                if a.contains("a") { all = true }
                i += 1
                if i < args.count { message = (message.map { $0 + "\n\n" } ?? "") + args[i] }
            } else if a.hasPrefix("--message=") {
                message = String(a.dropFirst("--message=".count))
            }
            i += 1
        }
        if !amend && (message ?? "").isEmpty && git.state == .merging { message = git.mergeMessage }
        guard amend || !(message ?? "").isEmpty else { throw Failure(message: "a commit message is needed: git commit -m \"message\"") }
        let commit = try git.commit(message: message ?? "", stageAll: all, amend: amend)
        let files = git.changes(inCommit: commit.id).count
        return "[\(git.status().currentBranch) \(commit.shortId)] \(commit.summary)\n \(files) file\(files == 1 ? "" : "s") changed\n"
    }

    private static func describe(_ commit: GitCommit) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
        var text = "\(yellow)commit \(commit.id)\(off)\(decorations(commit))\n"
        if commit.isMerge { text += "Merge: \(commit.parents.map { String($0.prefix(7)) }.joined(separator: " "))\n" }
        text += "Author: \(commit.author) <\(commit.email)>\nDate:   \(formatter.string(from: commit.date))\n\n"
        return text + commit.message.trimmingCharacters(in: .newlines).components(separatedBy: "\n").map { "    \($0)\n" }.joined()
    }

    private static func decorations(_ commit: GitCommit) -> String {
        guard !commit.refs.isEmpty else { return "" }
        let names = commit.refs.map { ref -> String in
            switch ref.kind {
            case .head: return "\(cyan)\(bold)HEAD -> \(off)\(green)\(bold)\(ref.name)\(off)"
            case .branch: return "\(green)\(bold)\(ref.name)\(off)"
            case .remote: return "\(red)\(bold)\(ref.name)\(off)"
            case .tag: return "\(yellow)\(bold)tag: \(ref.name)\(off)"
            }
        }
        return " \(yellow)(\(off)" + names.joined(separator: "\(yellow), \(off)") + "\(yellow))\(off)"
    }

    private static func log(_ args: [String], git: GitRepository) -> String {
        var limit = 500
        if let n = value(after: ["-n", "--max-count"], in: args), let value = Int(n) { limit = value }
        if let flag = args.first(where: { $0.count > 1 && $0.hasPrefix("-") && Int($0.dropFirst()) != nil }), let value = Int(flag.dropFirst()) { limit = value }
        let all = args.contains("--all")
        let start = args.first { !$0.hasPrefix("-") && git.commit($0) != nil }
        let path = args.last { !$0.hasPrefix("-") && $0 != start && Int($0) == nil }
        let history = git.log(from: start, all: all, path: path, limit: limit)
        if history.isEmpty { return "fatal: your current branch '\(git.status().currentBranch)' does not have any commits yet\n" }
        if args.contains("--graph") {
            let rows = GitGraph.layout(history)
            return zip(history, rows).map { commit, row in
                let lanes = (0..<row.width).map { lane -> String in
                    lane == row.node ? "*" : (row.passThrough.contains(lane) || row.below.contains(lane) || row.incoming.contains(lane)) ? "|" : " "
                }.joined(separator: " ")
                return "\(lanes) \(yellow)\(commit.shortId)\(off)\(decorations(commit)) \(commit.summary)\n"
            }.joined()
        }
        if args.contains("--oneline") {
            return history.map { "\(yellow)\($0.shortId)\(off)\(decorations($0)) \($0.summary)\n" }.joined()
        }
        return history.map(describe).joined(separator: "\n")
    }

    private static func show(_ args: [String], git: GitRepository) throws -> String {
        let spec = args.first { !$0.hasPrefix("-") } ?? "HEAD"
        guard let commit = git.commit(spec) else { throw Failure(message: "bad revision '\(spec)'") }
        let patch = args.contains("--stat") || args.contains("--name-status")
            ? git.changes(inCommit: commit.id).map { "\($0.status.rawValue)\t\($0.path)\n" }.joined()
            : git.patch(.commit(commit.id), color: true)
        return describe(commit) + "\n" + patch
    }

    private static func diff(_ args: [String], git: GitRepository, cwd: URL) throws -> String {
        let staged = args.contains("--staged") || args.contains("--cached")
        let words = args.filter { !$0.hasPrefix("-") }
        let revisions = words.prefix { git.commit($0) != nil && !FileManager.default.fileExists(atPath: cwd.appendingPathComponent($0).path) }
        let pathArgs = Array(words.dropFirst(revisions.count)).filter { $0 != "--" }
        let base = cwd.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = git.root.standardizedFileURL.resolvingSymlinksInPath().path
        let paths = pathArgs.map { arg -> String in
            let full = (arg.hasPrefix("/") ? arg : base + "/" + arg)
            return full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : arg
        }
        let target: GitDiffTarget
        switch revisions.count {
        case 0: target = staged ? .staged : .workingTree
        case 1: target = .between(revisions[revisions.startIndex], "HEAD")
        default: target = .between(revisions[revisions.startIndex], revisions[revisions.startIndex + 1])
        }
        return git.patch(target, paths: paths, color: true)
    }

    private static func branch(_ args: [String], git: GitRepository) throws -> String {
        let names = args.filter { !$0.hasPrefix("-") }
        if args.contains("-d") || args.contains("-D") || args.contains("--delete") {
            let remote = args.contains("-r")
            for name in names { try git.deleteBranch(name, force: args.contains("-D"), remote: remote) }
            return names.map { "Deleted \(remote ? "remote-tracking " : "")branch \($0).\n" }.joined()
        }
        if args.contains("-m") || args.contains("-M") {
            if names.count == 2 { try git.renameBranch(names[0], to: names[1]) } else if let new = names.first, let current = git.status().branch {
                try git.renameBranch(current, to: new)
            }
            return ""
        }
        if let upstream = value(after: ["-u", "--set-upstream-to"], in: args) {
            guard let branch = names.first(where: { $0 != upstream }) ?? git.status().branch else { return "" }
            try git.setUpstream(branch, to: upstream)
            return "branch '\(branch)' set up to track '\(upstream)'.\n"
        }
        if let name = names.first {
            try git.createBranch(name, at: names.count > 1 ? names[1] : nil, checkout: false)
            return ""
        }
        let verbose = args.contains("-v") || args.contains("-vv")
        var text = ""
        if !args.contains("-r") {
            for branch in git.branches() {
                let marker = branch.isHead ? "* \(green)" : "  "
                var line = marker + branch.name + (branch.isHead ? off : "")
                if verbose {
                    line += " \(branch.tip.prefix(7))"
                    if let upstream = branch.upstream {
                        var track = upstream
                        if branch.ahead > 0 { track += ": ahead \(branch.ahead)" }
                        if branch.behind > 0 { track += (branch.ahead > 0 ? ", " : ": ") + "behind \(branch.behind)" }
                        line += " [\(cyan)\(track)\(off)]"
                    }
                    line += " \(branch.summary)"
                }
                text += line + "\n"
            }
            if git.status().branch == nil, git.headId != nil { text = "* \(green)(HEAD detached at \(git.status().currentBranch))\(off)\n" + text }
        }
        if args.contains("-a") || args.contains("-r") {
            text += git.branches(remote: true).map { "  \(red)\(args.contains("-a") ? "remotes/" : "")\($0.name)\(off)\n" }.joined()
        }
        return text
    }

    private static func checkout(_ command: String, _ args: [String], git: GitRepository, cwd: URL) throws -> String {
        if let dashes = args.firstIndex(of: "--") {
            let status = git.status()
            let chosen = Set(try matching(Array(args[(dashes + 1)...]), candidates: status.changedFiles.map(\.path), root: git.root, cwd: cwd))
            try git.discard(status.changedFiles.filter { chosen.contains($0.path) && $0.status != .untracked })
            return ""
        }
        let force = args.contains("-f") || args.contains("--force")
        let names = args.filter { !$0.hasPrefix("-") }
        guard let name = names.first else { return "usage: git \(command) <branch>\n" }
        if args.contains("-b") || args.contains("-c") || args.contains("-B") || args.contains("--create") {
            try git.createBranch(name, at: names.count > 1 ? names[1] : nil)
            return "Switched to a new branch '\(name)'\n"
        }
        do {
            if git.branches().contains(where: { $0.name == name }) {
                try git.checkout(name, force: force)
                return "Switched to branch '\(name)'\n"
            }
            let remote = git.branches(remote: true).first { $0.name == name || $0.name.hasSuffix("/" + name) }
            if let remote, !args.contains("--detach") {
                try git.checkoutRemote(remote.name, force: force)
                let local = remote.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
                return "branch '\(local)' set up to track '\(remote.name)'.\nSwitched to a new branch '\(local)'\n"
            }
            if let commit = git.commit(name) {
                try git.checkout(commit: commit.id, force: force)
                return "HEAD is now at \(commit.shortId) \(commit.summary)\n"
            }
        } catch let error as GitError where error.isConflict {
            throw Failure(message: "Your local changes to the following files would be overwritten by checkout:\n"
                + error.paths.map { "\t\($0)\n" }.joined() + "Please commit your changes or stash them before you switch branches.")
        }
        throw Failure(message: "pathspec '\(name)' did not match any branch or commit (git fetch first for a remote branch)")
    }

    private static func merged(_ result: GitMergeResult) -> Output {
        switch result {
        case .upToDate: return Output(text: "Already up to date.\n")
        case .fastForward: return Output(text: "Fast-forward\n")
        case .merged: return Output(text: "Done.\n")
        case .conflicts(let paths):
            return Output(text: paths.map { "CONFLICT (content): Merge conflict in \($0)\n" }.joined()
                + "Automatic merge failed; fix conflicts and then commit the result.\n", code: 1)
        }
    }

    private static func stash(_ args: [String], git: GitRepository) throws -> String {
        let sub = args.first ?? "push"
        let number = args.dropFirst().compactMap { Int($0.replacingOccurrences(of: "stash@{", with: "").replacingOccurrences(of: "}", with: "")) }.first ?? 0
        switch sub {
        case "push", "save", "-m", "-u":
            var message = value(after: ["-m", "--message"], in: args) ?? ""
            if sub == "save", args.count > 1 { message = args[1] }
            try git.stash(message: message)
            return "Saved working directory and index state \(message.isEmpty ? "WIP on \(git.status().currentBranch)" : "On \(git.status().currentBranch): \(message)")\n"
        case "list":
            return git.stashes().map { "stash@{\($0.index)}: \($0.message)\n" }.joined()
        case "show":
            return git.patch(.commit("stash@{\(number)}"), color: true)
        case "pop":
            try git.applyStash(number, drop: true)
            return "Dropped stash@{\(number)}\n"
        case "apply":
            try git.applyStash(number, drop: false)
            return ""
        case "drop":
            try git.dropStash(number)
            return "Dropped stash@{\(number)}\n"
        case "clear":
            try git.dropAllStashes()
            return ""
        default:
            return "usage: git stash [push [-m message] | list | show | pop | apply | drop | clear]\n"
        }
    }

    private static func tag(_ args: [String], git: GitRepository) throws -> String {
        let names = args.filter { !$0.hasPrefix("-") }
        let message = value(after: ["-m", "--message"], in: args)
        if args.contains("-d") || args.contains("--delete") {
            for name in names { try git.deleteTag(name) }
            return names.map { "Deleted tag '\($0)'\n" }.joined()
        }
        let plain = names.filter { $0 != message }
        if let name = plain.first {
            try git.createTag(name, at: plain.count > 1 ? plain[1] : nil, message: message ?? (args.contains("-a") ? name : nil))
            return ""
        }
        return git.tags().map { "\($0.name)\n" }.joined()
    }

    private static func remote(_ args: [String], git: GitRepository) throws -> String {
        let names = args.dropFirst().filter { !$0.hasPrefix("-") }
        switch args.first {
        case "add", "set-url":
            guard names.count >= 2 else { return "usage: git remote \(args[0]) <name> <url>\n" }
            try git.setRemote(names[0], url: names[1])
            return ""
        case "remove", "rm":
            guard let name = names.first else { return "usage: git remote remove <name>\n" }
            try git.removeRemote(name)
            return ""
        case "rename":
            guard names.count >= 2 else { return "usage: git remote rename <old> <new>\n" }
            try git.renameRemote(names[0], to: names[1])
            return ""
        case "get-url":
            return (git.remoteURL(names.first ?? "origin") ?? "") + "\n"
        default:
            let remotes = git.remotes()
            if args.contains("-v") { return remotes.map { "\($0.name)\t\($0.url) (fetch)\n\($0.name)\t\($0.url) (push)\n" }.joined() }
            return remotes.map { "\($0.name)\n" }.joined()
        }
    }

    private static func config(_ args: [String], git: GitRepository) throws -> String {
        let global = args.contains("--global")
        let words = args.filter { !$0.hasPrefix("--") }
        if args.contains("--unset"), let key = words.first { try git.setConfig(key, nil, global: global); return "" }
        guard let key = words.first else { return "usage: git config [--global] <key> [<value>]\n" }
        if words.count > 1 {
            try git.setConfig(key, words.dropFirst().joined(separator: " "), global: global)
            return ""
        }
        guard let value = git.config(key) else { return "" }
        return value + "\n"
    }

    // MARK: Network

    /// fetch, pull and push, off the main thread, with git's progress lines.
    @MainActor
    private static func network(_ command: String, _ args: [String], root: URL) async -> Output {
        let words = args.filter { !$0.hasPrefix("-") }
        return await Task.detached(priority: .userInitiated) { () -> Output in
            var text = ""
            let transfer = GitTransfer { progress in
                if progress.done == progress.total && progress.total > 0 { text += "\(progress.phase): 100% (\(progress.done)/\(progress.total)), done.\n" }
            }
            do {
                let git = try GitRepository.open(root)
                switch command {
                case "fetch":
                    let remotes = args.contains("--all") ? git.remotes().map(\.name) : [words.first ?? "origin"]
                    for remote in remotes { try git.fetch(remote, prune: args.contains("--prune") || args.contains("-p"), transfer: transfer) }
                    if text.isEmpty { text = "" }
                case "pull":
                    switch try git.pull(transfer: transfer) {
                    case .upToDate: text += "Already up to date.\n"
                    case .fastForward: text += "Fast-forward\n"
                    case .merged: text += "Merge made by the 'ort' strategy.\n"
                    case .conflicts(let paths):
                        return Output(text: text + paths.map { "CONFLICT (content): Merge conflict in \($0)\n" }.joined()
                            + "Automatic merge failed; fix conflicts and then commit the result.\n", code: 1)
                    }
                default:
                    let remote = words.first.flatMap { name in git.remotes().contains { $0.name == name } ? name : nil }
                    let branch = words.dropFirst(remote == nil ? 0 : 1).first
                    if args.contains("--tags") && branch == nil && !args.contains("-u") {
                        try git.pushTags(remote: remote ?? "origin", transfer: transfer)
                    } else {
                        try git.push(branch, remote: remote, force: args.contains("-f") || args.contains("--force"), tags: args.contains("--tags"), transfer: transfer)
                    }
                    text += "To \(git.remoteURL(remote ?? "origin") ?? "origin")\n"
                }
                return Output(text: text)
            } catch let error as GitError where error.isAuthentication {
                return Output(text: text + "fatal: \(error.message). Sign in to GitHub in Settings > Source Control, or push from the Source Control view once to save this server's login.\n", code: 128)
            } catch {
                return Output(text: text + "fatal: \(error.localizedDescription)\n", code: 128)
            }
        }.value
    }

    @MainActor
    private static func clone(_ args: [String], cwd: URL) async -> Output {
        let words = args.filter { !$0.hasPrefix("-") }
        guard let url = words.first else { return Output(text: "usage: git clone <url> [folder]\n", code: 1) }
        let name = words.count > 1 ? words[1] : (URL(string: url)?.deletingPathExtension().lastPathComponent ?? "repository")
        let target = cwd.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            return Output(text: "fatal: destination path '\(name)' already exists and is not an empty directory.\n", code: 128)
        }
        return await Task.detached(priority: .userInitiated) { () -> Output in
            var text = "Cloning into '\(name)'...\n"
            let transfer = GitTransfer { progress in
                if progress.done == progress.total && progress.total > 0 { text += "\(progress.phase): 100% (\(progress.done)/\(progress.total)), done.\n" }
            }
            do {
                try GitRepository.clone(url, to: target, transfer: transfer)
                return Output(text: text)
            } catch {
                try? FileManager.default.removeItem(at: target)
                return Output(text: text + "fatal: \(error.localizedDescription)\n", code: 128)
            }
        }.value
    }

    // MARK: - Helpers

    /// Repository paths for arguments given relative to `cwd`: a file, or a folder for every
    /// changed path under it.
    static func matching(_ args: [String], candidates: [String], root: URL, cwd: URL) throws -> [String] {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [String] = []
        for arg in args where !arg.hasPrefix("-") {
            let full = (arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : cwd.appendingPathComponent(arg))
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard full == rootPath || full.hasPrefix(rootPath + "/") else { throw Failure(message: "'\(arg)' is outside the repository") }
            let relative = full == rootPath ? "" : String(full.dropFirst(rootPath.count + 1))
            let found = candidates.filter { relative.isEmpty || $0 == relative || $0.hasPrefix(relative + "/") }
            if found.isEmpty { throw Failure(message: "pathspec '\(arg)' did not match any files") }
            out += found
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }
}
