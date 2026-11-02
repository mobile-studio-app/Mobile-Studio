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

    /// git rebase -i: opens the steps sheet in Source Control (InteractiveRebaseViewController); userInfo "base".
    static let interactiveRebaseRequest = Notification.Name("MobileStudioInteractiveRebaseRequest")

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
            case "status":
                let short = rest.contains("-s") || rest.contains("--short") || rest.contains("-sb") || rest.contains("--porcelain")
                return Output(text: status(git.status(), short: short, branch: rest.contains("-b") || rest.contains("-sb") || rest.contains("--branch"),
                                           submodules: git.submodules()))
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
                if rest.contains("--continue") { return Output(text: try commit([], git: git)) }
                guard let name = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git merge <branch>\n", code: 1) }
                let mode: GitMergeMode = rest.contains("--squash") ? .squash : rest.contains("--ff-only") ? .fastForwardOnly
                    : rest.contains("--no-ff") ? .noFastForward : .normal
                let result = try git.merge(name, mode: mode)
                if mode == .squash, case .merged = result { return Output(text: "Squash commit -- not updating HEAD\nCommit the staged changes to finish.\n") }
                return merged(result)
            case "rebase": return rebased(rest, git: git)
            case "submodule": return await submodule(rest, root: root)
            case "mv":
                let paths = rest.filter { !$0.hasPrefix("-") }
                guard paths.count == 2 else { return Output(text: "usage: git mv <source> <destination>\n", code: 1) }
                try git.move(relative(paths[0], git: git, cwd: cwd), to: relative(paths[1], git: git, cwd: cwd))
            case "blame": return Output(text: try blame(rest, git: git, cwd: cwd))
            case "shortlog":
                var counts: [String: [String]] = [:]
                for commit in git.log(all: rest.contains("--all"), limit: 5000) { counts[commit.author, default: []].append(commit.summary) }
                let summary = rest.contains("-s") || rest.contains("-sn") || rest.contains("-ns")
                return Output(text: counts.sorted { $0.value.count > $1.value.count }.map { author, subjects in
                    summary ? String(format: "%6d\t%@\n", subjects.count, author)
                        : "\(author) (\(subjects.count)):\n" + subjects.map { "      \($0)\n" }.joined() + "\n"
                }.joined())
            case "describe":
                guard let text = git.describe() else { return Output(text: "fatal: No names found, cannot describe anything.\n", code: 128) }
                return Output(text: text + "\n")
            case "reflog":
                return Output(text: git.reflog().enumerated().map { "\(yellow)\($1.id.prefix(7))\(off) HEAD@{\($0)}: \($1.message)\n" }.joined())
            case "ls-files": return Output(text: git.trackedFiles().map { $0 + "\n" }.joined())
            case "grep":
                guard let pattern = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git grep <pattern>\n", code: 1) }
                let hits = git.grep(pattern, ignoreCase: rest.contains("-i"))
                if hits.isEmpty { return Output(code: 1) }
                return Output(text: hits.map { "\(cyan)\($0.path)\(off)\(rest.contains("-n") ? ":\(green)\($0.line)\(off)" : ""):\($0.text)\n" }.joined())
            case "clean":
                let dryRun = rest.contains("-n") || rest.contains("--dry-run")
                guard dryRun || rest.contains(where: { $0.hasPrefix("-") && $0.contains("f") }) else {
                    return Output(text: "fatal: clean refuses to delete files without -f (or -n to see what it would delete)\n", code: 128)
                }
                let paths = git.clean(ignored: rest.contains("-x"), dryRun: dryRun)
                return Output(text: paths.map { "\(dryRun ? "Would remove" : "Removing") \($0)\n" }.joined())
            case "cat-file":
                guard let spec = rest.first(where: { !$0.hasPrefix("-") }), let object = git.object(spec) else {
                    return Output(text: "fatal: Not a valid object name\n", code: 128)
                }
                return Output(text: rest.contains("-t") ? object.type + "\n" : object.text)
            case "rev-list":
                let commits = git.log(from: rest.first { !$0.hasPrefix("-") }, all: rest.contains("--all"), limit: 100_000)
                return Output(text: rest.contains("--count") ? "\(commits.count)\n" : commits.map { $0.id + "\n" }.joined())
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
            case "ls-remote":
                return Output(text: git.branches(remote: true).map { "\($0.tip)\trefs/remotes/\($0.name)\n" }.joined()
                    + git.tags().map { "\($0.target)\trefs/tags/\($0.name)\n" }.joined())
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
           init [-b branch], clone [--no-recurse-submodules] <url> [folder]
           status [-s] [-b], add <paths>|., rm [--cached] <paths>, mv <from> <to>
           restore [--staged] [--source <commit>] <paths>, reset [<paths>] | [--soft|--mixed|--hard] <commit>
           commit -m <message> [-a] [--amend], clean -n|-f [-x]
           log [--oneline] [--graph] [--all] [-n N] [-p] [--stat] [--author a] [--grep t] [--format f] [path]
           show [commit] [--stat], diff [--staged] [--stat|--name-only] [commit [commit]] [paths]
           blame <file>, shortlog [-s], describe, reflog, grep [-i] [-n] <pattern>, ls-files
           branch [-a|-r|-v] [--merged|--no-merged] [-d|-D|-m] [-u upstream] [name] [start]
           checkout|switch [-b|-c] <branch>|<commit>|-, merge [--no-ff|--ff-only|--squash] <branch> [--abort]
           rebase [--onto base] <upstream> | --continue | --skip | --abort
           revert|cherry-pick <commit> [--abort], stash [push [-m msg]|list|show|pop|apply|drop|clear]
           tag [-a name -m msg] [-d name], fetch [remote] [--all] [--prune]
           pull [--rebase|--ff-only], push [-u] [-f] [--tags] [--delete branch] [remote] [branch]
           submodule [status | init | update [--init] [--recursive] | add <url> [path] | sync]
           remote [-v] | add|set-url|remove|rename ..., ls-remote, config [--global] key [value]
           rev-parse [--short] [--abbrev-ref] [rev], rev-list [--count] [rev], cat-file -t|-p <object>

        """

    // MARK: - Commands

    private static func value(after flags: [String], in args: [String]) -> String? {
        for (i, arg) in args.enumerated() {
            if flags.contains(arg), i + 1 < args.count { return args[i + 1] }
            for flag in flags where flag.hasPrefix("--") && arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    private static func status(_ status: GitStatus, short: Bool, branch: Bool = false, submodules: [GitSubmodule] = []) -> String {
        if short {
            var lines: [String] = []
            if branch {
                var line = "## \(status.branch ?? "HEAD (no branch)")"
                if let upstream = status.upstream { line += "...\(upstream)" }
                let counts = [status.aheadCount > 0 ? "ahead \(status.aheadCount)" : nil, status.behindCount > 0 ? "behind \(status.behindCount)" : nil].compactMap { $0 }
                if !counts.isEmpty { line += " [\(counts.joined(separator: ", "))]" }
                lines.append(line)
            }
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
        if status.state == .rebasing { text += "You are currently rebasing (fix conflicts, then git rebase --continue, or --skip, or --abort).\n" }
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
        let uncloned = submodules.filter { !$0.isCloned }
        if !uncloned.isEmpty { text += "\nSubmodules not cloned yet (git submodule update --init):\n" + uncloned.map { "\t\($0.path)\n" }.joined() }
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
        let source = value(after: ["--source", "-s"], in: args)
        let paths = args.filter { !$0.hasPrefix("-") && $0 != source }
        let status = git.status()
        if let source {
            // The files as they were in that commit.
            for arg in paths {
                let path = relative(arg, git: git, cwd: cwd)
                guard let data = git.data(of: path, at: .commit(source)) else { throw Failure(message: "'\(path)' isn't in \(source)") }
                try data.write(to: git.root.appendingPathComponent(path))
            }
            return
        }
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
        var history = git.log(from: start, all: all, path: path, limit: limit)
        if history.isEmpty { return "fatal: your current branch '\(git.status().currentBranch)' does not have any commits yet\n" }
        if let author = value(after: ["--author"], in: args)?.lowercased() {
            history = history.filter { $0.author.lowercased().contains(author) || $0.email.lowercased().contains(author) }
        }
        if let grep = value(after: ["--grep"], in: args)?.lowercased() { history = history.filter { $0.message.lowercased().contains(grep) } }
        // --format / --pretty: oneline, short, or placeholders (%H %h %s %b %an %ae %ad %ar %d %n).
        if let format = value(after: ["--format", "--pretty"], in: args) {
            if format == "oneline" { return history.map { "\(yellow)\($0.id)\(off) \($0.summary)\n" }.joined() }
            if format == "short" { return history.map { "\(yellow)commit \($0.id)\(off)\nAuthor: \($0.author) <\($0.email)>\n\n    \($0.summary)\n" }.joined(separator: "\n") }
            let template = format.hasPrefix("format:") ? String(format.dropFirst(7)) : format.hasPrefix("tformat:") ? String(format.dropFirst(8)) : format
            return history.map { formatted($0, template) + "\n" }.joined()
        }
        let detail = { (commit: GitCommit) -> String in
            if args.contains("-p") || args.contains("--patch") { return "\n" + git.patch(.commit(commit.id), color: true) }
            if args.contains("--stat") { return "\n" + stat(git.patch(.commit(commit.id))) }
            if args.contains("--name-only") { return "\n" + git.changes(inCommit: commit.id).map { "\($0.path)\n" }.joined() }
            if args.contains("--name-status") { return "\n" + git.changes(inCommit: commit.id).map { "\($0.status.rawValue)\t\($0.path)\n" }.joined() }
            return ""
        }
        if args.contains("-p") || args.contains("--patch") || args.contains("--stat") || args.contains("--name-only") || args.contains("--name-status"),
           !args.contains("--oneline"), !args.contains("--graph") {
            return history.map { describe($0) + detail($0) }.joined(separator: "\n")
        }
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
        if args.contains("--stat") { return stat(git.patch(target, paths: paths)) }
        if args.contains("--name-only") || args.contains("--name-status") {
            let names = files(in: git.patch(target, paths: paths))
            return names.map { args.contains("--name-status") ? "\($0.status)\t\($0.path)\n" : "\($0.path)\n" }.joined()
        }
        if args.contains("--shortstat") { return stat(git.patch(target, paths: paths)).components(separatedBy: "\n").filter { !$0.isEmpty }.last.map { $0 + "\n" } ?? "" }
        return git.patch(target, paths: paths, color: true)
    }

    /// The files in a patch, with M/A/D.
    private static func files(in patch: String) -> [(path: String, status: String)] {
        var out: [(String, String)] = []
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git a/"), let b = line.range(of: " b/") {
                out.append((String(line[b.upperBound...]), "M"))
            } else if line.hasPrefix("new file mode"), !out.isEmpty {
                out[out.count - 1].1 = "A"
            } else if line.hasPrefix("deleted file mode"), !out.isEmpty {
                out[out.count - 1].1 = "D"
            } else if line.hasPrefix("rename from"), !out.isEmpty {
                out[out.count - 1].1 = "R"
            }
        }
        return out
    }

    /// git's --stat: lines added and removed per file, from a patch.
    private static func stat(_ patch: String) -> String {
        var rows: [(path: String, added: Int, removed: Int)] = []
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git a/"), let b = line.range(of: " b/") {
                rows.append((String(line[b.upperBound...]), 0, 0))
            } else if !rows.isEmpty, line.hasPrefix("+"), !line.hasPrefix("+++") {
                rows[rows.count - 1].added += 1
            } else if !rows.isEmpty, line.hasPrefix("-"), !line.hasPrefix("---") {
                rows[rows.count - 1].removed += 1
            }
        }
        guard !rows.isEmpty else { return "" }
        let width = rows.map(\.path.count).max() ?? 0
        let most = max(1, rows.map { $0.added + $0.removed }.max() ?? 1)
        var text = rows.map { row -> String in
            let total = row.added + row.removed
            let scale = most > 40 ? 40.0 / Double(most) : 1
            let plus = Int((Double(row.added) * scale).rounded(.up)), minus = Int((Double(row.removed) * scale).rounded(.up))
            return " \(row.path.padding(toLength: width, withPad: " ", startingAt: 0)) | \(String(format: "%3d", total)) "
                + "\(green)\(String(repeating: "+", count: plus))\(off)\(red)\(String(repeating: "-", count: minus))\(off)\n"
        }.joined()
        let added = rows.map(\.added).reduce(0, +), removed = rows.map(\.removed).reduce(0, +)
        text += " \(rows.count) file\(rows.count == 1 ? "" : "s") changed, \(added) insertion\(added == 1 ? "" : "s")(+), \(removed) deletion\(removed == 1 ? "" : "s")(-)\n"
        return text
    }

    /// git log --format's placeholders.
    private static func formatted(_ commit: GitCommit, _ template: String) -> String {
        let iso = ISO8601DateFormatter()
        let relative = RelativeDateTimeFormatter()
        let body = commit.message.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let names = commit.refs.map { $0.kind == .head ? "HEAD -> \($0.name)" : $0.kind == .tag ? "tag: \($0.name)" : $0.name }
        let values: [(String, String)] = [
            ("%H", commit.id), ("%h", commit.shortId), ("%s", commit.summary), ("%b", body), ("%an", commit.author), ("%ae", commit.email),
            ("%ad", iso.string(from: commit.date)), ("%ar", relative.localizedString(for: commit.date, relativeTo: Date())),
            ("%P", commit.parents.joined(separator: " ")), ("%p", commit.parents.map { String($0.prefix(7)) }.joined(separator: " ")),
            ("%d", names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"), ("%n", "\n"), ("%%", "%"),
        ]
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: key, with: value) }
        return out
    }

    private static func branch(_ args: [String], git: GitRepository) throws -> String {
        let names = args.filter { !$0.hasPrefix("-") }
        if args.contains("--merged") || args.contains("--no-merged") {
            return git.branches(merged: args.contains("--merged")).map { ($0.isHead ? "* \(green)" : "  ") + $0.name + ($0.isHead ? off : "") + "\n" }.joined()
        }
        if args.contains("--show-current") { return (git.currentBranchName ?? "") + "\n" }
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
        var names = args.filter { !$0.hasPrefix("-") }
        // git checkout -: the branch before this one.
        if args.contains("-") {
            guard let previous = previousBranch(git) else { throw Failure(message: "there's no previous branch") }
            names.insert(previous, at: 0)
        }
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

    private static func rebased(_ args: [String], git: GitRepository) -> Output {
        do {
            let result: GitRebaseResult
            // The interactive rebase's own sequencer.
            if git.interactiveRebase != nil {
                if args.contains("--abort") { try git.abortInteractiveRebase(); return Output() }
                let step: GitInteractiveResult
                if args.contains("--continue") { step = try git.continueInteractiveRebase() }
                else if args.contains("--skip") { step = try git.skipInteractiveStep() }
                else { return Output(text: "An interactive rebase is in progress: git rebase --continue, --skip or --abort.\n", code: 1) }
                switch step {
                case .done(let count): return Output(text: "Successfully rebased and updated refs/heads/\(git.currentBranchName ?? "HEAD") (\(count) commits).\n")
                case .stoppedToEdit(let s): return Output(text: "Stopped at \(s.shortId)... \(s.summary)\nYou can amend the commit now (git commit --amend), then git rebase --continue.\n")
                case .conflicts(let paths):
                    return Output(text: paths.map { "CONFLICT (content): Merge conflict in \($0)\n" }.joined() + "Resolve them, git add them, then git rebase --continue.\n", code: 1)
                }
            }
            if args.contains("--abort") { try git.abortRebase(); return Output() }
            if args.contains("--continue") { result = try git.continueRebase() }
            else if args.contains("--skip") { result = try git.skipRebaseStep() }
            else {
                let words = args.filter { !$0.hasPrefix("-") }
                let onto = value(after: ["--onto"], in: args)
                let upstream = words.first { $0 != onto } ?? git.status().upstream
                guard let upstream else { return Output(text: "There is no tracking information for the current branch: git rebase <branch>\n", code: 1) }
                if args.contains("-i") || args.contains("--interactive") {
                    // The todo list is a sheet in Source Control.
                    _ = try git.rebasePlan(onto: upstream)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: GitCommandLine.interactiveRebaseRequest, object: nil, userInfo: ["base": upstream])
                    }
                    return Output(text: "Opened the rebase steps in Source Control: choose what to do with each commit, then tap Rebase.\n")
                }
                result = try git.rebase(onto: upstream, newBase: onto)
            }
            switch result {
            case .upToDate: return Output(text: "Current branch \(git.status().currentBranch) is up to date.\n")
            case .done(let count):
                return Output(text: "Successfully rebased and updated refs/heads/\(git.currentBranchName ?? "HEAD") (\(count) commit\(count == 1 ? "" : "s")).\n")
            case .conflicts(let paths):
                return Output(text: paths.map { "CONFLICT (content): Merge conflict in \($0)\n" }.joined()
                    + "error: could not apply the commit. Resolve all conflicts, stage them with \"git add\",\n"
                    + "then run \"git rebase --continue\" (or \"git rebase --skip\" to drop it, \"git rebase --abort\" to stop).\n", code: 1)
            }
        } catch {
            return Output(text: "fatal: \(error.localizedDescription)\n", code: 128)
        }
    }

    @MainActor
    private static func submodule(_ args: [String], root: URL) async -> Output {
        let sub = args.first ?? "status"
        let words = args.dropFirst().filter { !$0.hasPrefix("-") }
        if sub == "status" || sub == "summary" || (args.first?.hasPrefix("-") ?? false) {
            guard let git = try? GitRepository.open(root) else { return Output(code: 128) }
            return Output(text: git.submodules().map { sm in
                let marker = !sm.isCloned ? "-" : sm.isModified || sm.checkedOut != sm.recorded ? "+" : " "
                return "\(marker)\(sm.checkedOut ?? sm.recorded ?? "") \(sm.path)\n"
            }.joined())
        }
        if sub == "sync" || sub == "init" {
            do {
                let git = try GitRepository.open(root)
                if sub == "sync" { try git.syncSubmodules() }
                return Output(text: git.submodules().map { "Submodule '\($0.name)' (\($0.url)) registered for path '\($0.path)'\n" }.joined())
            } catch { return Output(text: "fatal: \(error.localizedDescription)\n", code: 128) }
        }
        guard sub == "update" || sub == "add" else {
            return Output(text: "usage: git submodule [status | init | update [--init] [--recursive] [paths] | add <url> [path] | sync]\n", code: 1)
        }
        let recursive = args.contains("--recursive") || sub == "add"
        return await Task.detached(priority: .userInitiated) { () -> Output in
            do {
                let git = try GitRepository.open(root)
                if sub == "add" {
                    guard let url = words.first else { return Output(text: "usage: git submodule add <url> [path]\n", code: 1) }
                    try git.addSubmodule(url, at: words.dropFirst().first)
                    return Output(text: "Cloning into '\(words.dropFirst().first ?? url)'...\n")
                }
                let count = try git.updateSubmodules(Array(words), recursive: recursive)
                return Output(text: count == 0 ? "" : "Updated \(count) submodule\(count == 1 ? "" : "s").\n")
            } catch {
                return Output(text: "fatal: \(error.localizedDescription)\n", code: 128)
            }
        }.value
    }

    private static func blame(_ args: [String], git: GitRepository, cwd: URL) throws -> String {
        guard let arg = args.last(where: { !$0.hasPrefix("-") }) else { throw Failure(message: "usage: git blame <file>") }
        let path = relative(arg, git: git, cwd: cwd)
        guard let text = try? String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8) else {
            throw Failure(message: "no such path '\(path)'")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = text.components(separatedBy: "\n")
        let owners = git.blame(path, contents: text)
        let width = owners.compactMap { $0?.author.count }.max() ?? 10
        return zip(owners, lines).enumerated().compactMap { i, pair -> String? in
            let (owner, line) = pair
            if i == lines.count - 1 && line.isEmpty { return nil }
            let who = (owner?.author ?? "Not Committed Yet").padding(toLength: width, withPad: " ", startingAt: 0)
            let id = owner?.shortId ?? "0000000"
            let date = owner.map { formatter.string(from: $0.date) } ?? "          "
            return "\(yellow)\(id)\(off) (\(who) \(date) \(String(format: "%4d", i + 1))) \(line)\n"
        }.joined()
    }

    /// A path relative to the repository, from one relative to `cwd`.
    private static func relative(_ arg: String, git: GitRepository, cwd: URL) -> String {
        let rootPath = git.root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = (arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : cwd.appendingPathComponent(arg)).standardizedFileURL.resolvingSymlinksInPath().path
        return full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : arg
    }

    /// The branch checked out before this one (git checkout -), from the reflog.
    private static func previousBranch(_ git: GitRepository) -> String? {
        for entry in git.reflog(limit: 200) where entry.message.hasPrefix("checkout: moving from ") {
            let rest = entry.message.dropFirst("checkout: moving from ".count)
            if let range = rest.range(of: " to ") { return String(rest[..<range.lowerBound]) }
        }
        return nil
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
                case "pull" where args.contains("--rebase") || args.contains("-r") || git.config("pull.rebase") == "true":
                    switch try git.pullRebase(transfer: transfer) {
                    case .upToDate: text += "Current branch is up to date.\n"
                    case .done(let count): text += "Successfully rebased (\(count) commit\(count == 1 ? "" : "s")).\n"
                    case .conflicts(let paths):
                        return Output(text: text + paths.map { "CONFLICT (content): Merge conflict in \($0)\n" }.joined()
                            + "Resolve the conflicts, stage them, then git rebase --continue.\n", code: 1)
                    }
                case "pull" where args.contains("--ff-only"):
                    let upstream = git.status().upstream ?? "origin/\(git.status().currentBranch)"
                    try git.fetch(String(upstream.split(separator: "/").first ?? "origin"), transfer: transfer)
                    if case .upToDate = try git.merge(upstream, mode: .fastForwardOnly) { text += "Already up to date.\n" } else { text += "Fast-forward\n" }
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
                    if args.contains("--delete") || args.contains("-d") {
                        guard let branch else { return Output(text: "usage: git push [remote] --delete <branch>\n", code: 1) }
                        try git.deleteRemoteBranch(branch, remote: remote ?? "origin", transfer: transfer)
                        return Output(text: "To \(git.remoteURL(remote ?? "origin") ?? "origin")\n - [deleted]         \(branch)\n")
                    }
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
                try GitRepository.clone(url, to: target, submodules: !args.contains("--no-recurse-submodules"), transfer: transfer)
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
