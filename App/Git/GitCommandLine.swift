import Foundation

/// `git` in the Terminal: the usual commands, run by GitManager and answered as git would
/// (with git's colours). Paths are relative to the folder the command runs in.
enum GitCommandLine {
    struct Output {
        var text = ""
        var code: Int32 = 0
    }

    private static let red = "\u{1B}[31m", green = "\u{1B}[32m", yellow = "\u{1B}[33m", cyan = "\u{1B}[36m",
                        bold = "\u{1B}[1m", off = "\u{1B}[0m"

    @MainActor
    static func run(_ args: [String], root: URL, cwd: URL) async -> Output {
        var out = Output()
        let git = GitManager.shared
        guard let command = args.first else {
            out.text = usage
            return out
        }
        let rest = Array(args.dropFirst())
        if command != "init" && command != "clone" && command != "help" && !git.isGitRepo(at: root) {
            return Output(text: "fatal: not a git repository (run git init)\n", code: 128)
        }
        do {
            switch command {
            case "help", "--help", "-h":
                out.text = usage
            case "init":
                if git.isGitRepo(at: root) { out.text = "Reinitialized existing Git repository in \(root.path)/.git/\n" } else {
                    try git.initRepo(at: root)
                    out.text = "Initialized empty Git repository in \(root.path)/.git/\n"
                }
            case "status":
                out.text = status(git.status(in: root), short: rest.contains("-s") || rest.contains("--short"))
            case "add":
                let status = git.status(in: root)
                if rest.contains(".") || rest.contains("-A") || rest.contains("--all") || rest.contains("*") {
                    try git.stageAll(in: root)
                } else {
                    let candidates = (status.changedFiles + status.mergeConflicts).map(\.path)
                    let paths = try matching(rest, candidates: candidates, root: root, cwd: cwd)
                    try git.stage(paths, in: root)
                }
            case "reset":
                let paths = rest.filter { !$0.hasPrefix("-") && $0 != "HEAD" }
                if paths.isEmpty { try git.unstageAll(in: root) } else {
                    try git.unstage(try matching(paths, candidates: git.status(in: root).stagedFiles.map(\.path), root: root, cwd: cwd), in: root)
                }
            case "restore":
                let paths = rest.filter { !$0.hasPrefix("-") }
                if rest.contains("--staged") {
                    try git.unstage(try matching(paths, candidates: git.status(in: root).stagedFiles.map(\.path), root: root, cwd: cwd), in: root)
                } else {
                    for path in try matching(paths, candidates: git.status(in: root).changedFiles.map(\.path), root: root, cwd: cwd) {
                        try git.discardChanges(for: path, in: root)
                    }
                }
            case "commit":
                out.text = try commit(rest, root: root)
            case "log":
                out.text = log(rest, root: root)
            case "show":
                guard let id = rest.first(where: { !$0.hasPrefix("-") }) ?? git.history(in: root, limit: 1).first?.id else { break }
                let commit = git.history(in: root).first { $0.id.hasPrefix(id) || id.hasPrefix($0.id) }
                if let commit { out.text = describe(commit) + "\n" }
                out.text += git.changes(inCommit: commit?.id ?? id, in: root).map { "\($0.status.rawValue)\t\($0.path)" }.joined(separator: "\n") + "\n"
            case "diff":
                out.text = try diff(rest, root: root, cwd: cwd)
            case "branch":
                out.text = try await branch(rest, root: root)
            case "checkout", "switch":
                out.text = try await checkout(command, rest, root: root, cwd: cwd)
            case "merge":
                if rest.contains("--abort") { try git.abortMerge(in: root); break }
                guard let name = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git merge <branch>\n", code: 1) }
                switch try git.merge(name, in: root) {
                case .upToDate: out.text = "Already up to date.\n"
                case .fastForward: out.text = "Fast-forward\n"
                case .merged: out.text = "Merge made by Mobile Studio.\n"
                case .conflicts(let paths):
                    out.text = paths.map { "CONFLICT (content): Merge conflict in \($0)\n" }.joined()
                        + "Automatic merge failed; fix conflicts and then commit the result.\n"
                    out.code = 1
                }
            case "stash":
                out.text = try stash(rest, root: root)
            case "push":
                let count = try await callback { git.push(in: root, completion: $0) }
                out.text = count == 0 ? "Everything up-to-date\n" : "Pushed \(count) commit\(count == 1 ? "" : "s") to \(git.getRemoteURL(in: root) ?? "origin").\n"
            case "pull":
                let count = try await callback { git.pull(in: root, completion: $0) }
                out.text = count == 0 ? "Already up to date.\n" : "Pulled \(count) commit\(count == 1 ? "" : "s").\n"
            case "fetch":
                let names = try await callback { git.remoteBranches(in: root, completion: $0) }
                out.text = "From \(git.getRemoteURL(in: root) ?? "origin")\n" + names.map { " * [branch]  \($0) -> origin/\($0)\n" }.joined()
            case "clone":
                guard let url = rest.first(where: { !$0.hasPrefix("-") }) else { return Output(text: "usage: git clone <url>\n", code: 1) }
                let folder = try await callback { git.clone(from: url, completion: $0) }
                out.text = "Cloned into '\(folder.lastPathComponent)'. Open it from the Welcome page.\n"
            case "remote":
                out.text = remote(rest, root: root)
            case "rev-parse":
                if rest.contains("--abbrev-ref") { out.text = git.currentBranch(in: root) + "\n" } else {
                    out.text = (git.tip(of: git.currentBranch(in: root), in: root) ?? "") + "\n"
                }
            case "config":
                out.text = "Mobile Studio's git uses your GitHub account (Settings > Source Control) for author details.\n"
            default:
                return Output(text: "git: '\(command)' isn't available in Mobile Studio's git. See 'git help'.\n", code: 1)
            }
        } catch {
            return Output(text: "fatal: \(error.localizedDescription)\n", code: 128)
        }
        return out
    }

    static let usage = """
        usage: git <command> [<args>]

        Mobile Studio's git (the app's own git engine, synced with GitHub):
           init, clone <url>
           status [-s], add <paths>|., reset|restore [--staged] <paths>, diff [--staged] [paths]
           commit -m <message> [-a] [--amend], log [--oneline] [-n N], show [commit]
           branch [-a] [-d|-D|-m] [name], checkout|switch [-b|-c] <branch>, merge <branch>|--abort
           stash [push|list|pop|apply|drop|clear], push, pull, fetch, remote [-v]

        """

    // MARK: - Commands

    private static func status(_ status: GitStatus, short: Bool) -> String {
        if short {
            var lines: [String] = []
            for file in status.mergeConflicts { lines.append("\(red)UU\(off) \(file.path)") }
            for file in status.stagedFiles { lines.append("\(green)\(file.status.rawValue)\(off)  \(file.path)") }
            for file in status.changedFiles {
                lines.append(file.status == .untracked ? "\(red)??\(off) \(file.path)" : " \(red)\(file.status.rawValue)\(off) \(file.path)")
            }
            return lines.map { $0 + "\n" }.joined()
        }
        var text = "On branch \(status.currentBranch)\n"
        if let merging = status.mergingBranch { text += "You are merging \(merging).\n" }
        if status.hasUpstream {
            if status.aheadCount > 0 && status.behindCount > 0 {
                text += "Your branch and 'origin/\(status.currentBranch)' have diverged (\(status.aheadCount) and \(status.behindCount) different commits).\n"
            } else if status.aheadCount > 0 {
                text += "Your branch is ahead of 'origin/\(status.currentBranch)' by \(status.aheadCount) commit\(status.aheadCount == 1 ? "" : "s").\n"
            } else if status.behindCount > 0 {
                text += "Your branch is behind 'origin/\(status.currentBranch)' by \(status.behindCount) commit\(status.behindCount == 1 ? "" : "s").\n"
            } else {
                text += "Your branch is up to date with 'origin/\(status.currentBranch)'.\n"
            }
        }
        let label: (GitFileStatus) -> String = {
            switch $0 {
            case .added: return "new file:   "
            case .deleted: return "deleted:    "
            case .conflicted: return "both modified:   "
            default: return "modified:   "
            }
        }
        if !status.mergeConflicts.isEmpty {
            text += "\nUnmerged paths:\n" + status.mergeConflicts.map { "\t\(red)both modified:   \($0.path)\(off)\n" }.joined()
        }
        if !status.stagedFiles.isEmpty {
            text += "\nChanges to be committed:\n" + status.stagedFiles.map { "\t\(green)\(label($0.status))\($0.path)\(off)\n" }.joined()
        }
        let tracked = status.changedFiles.filter { $0.status != .untracked }
        let untracked = status.changedFiles.filter { $0.status == .untracked }
        if !tracked.isEmpty {
            text += "\nChanges not staged for commit:\n" + tracked.map { "\t\(red)\(label($0.status))\($0.path)\(off)\n" }.joined()
        }
        if !untracked.isEmpty {
            text += "\nUntracked files:\n" + untracked.map { "\t\(red)\($0.path)\(off)\n" }.joined()
        }
        if status.isClean { text += "\nnothing to commit, working tree clean\n" }
        return text
    }

    private static func commit(_ args: [String], root: URL) throws -> String {
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
        guard let message, !message.isEmpty else {
            throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "a commit message is needed: git commit -m \"message\""])
        }
        let commit = try GitManager.shared.commit(message: message, all: all, amend: amend, in: root)
        let branch = GitManager.shared.currentBranch(in: root)
        let files = GitManager.shared.changes(inCommit: commit.id, in: root).count
        return "[\(branch) \(commit.id)] \(message.components(separatedBy: "\n").first ?? message)\n \(files) file\(files == 1 ? "" : "s") changed\n"
    }

    private static func describe(_ commit: GitCommit) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
        return "\(yellow)commit \(commit.id)\(off)\nAuthor: \(commit.author)\nDate:   \(formatter.string(from: commit.date))\n\n"
            + commit.message.components(separatedBy: "\n").map { "    \($0)\n" }.joined()
    }

    private static func log(_ args: [String], root: URL) -> String {
        var limit = 500
        if let n = args.firstIndex(of: "-n"), n + 1 < args.count, let value = Int(args[n + 1]) { limit = value }
        if let flag = args.first(where: { $0.count > 1 && $0.hasPrefix("-") && Int($0.dropFirst()) != nil }), let value = Int(flag.dropFirst()) { limit = value }
        let history = GitManager.shared.history(in: root, limit: limit)
        if history.isEmpty { return "fatal: your current branch '\(GitManager.shared.currentBranch(in: root))' does not have any commits yet\n" }
        if args.contains("--oneline") {
            return history.map { "\(yellow)\($0.id)\(off) \($0.message.components(separatedBy: "\n").first ?? "")\n" }.joined()
        }
        return history.map(describe).joined(separator: "\n")
    }

    private static func diff(_ args: [String], root: URL, cwd: URL) throws -> String {
        let git = GitManager.shared
        let status = git.status(in: root)
        let staged = args.contains("--staged") || args.contains("--cached")
        let paths = args.filter { !$0.hasPrefix("-") }
        var files = staged ? status.stagedFiles : status.changedFiles.filter { $0.status != .untracked }
        if !paths.isEmpty {
            let chosen = Set(try matching(paths, candidates: files.map(\.path), root: root, cwd: cwd))
            files = files.filter { chosen.contains($0.path) }
        }
        var text = ""
        for file in files {
            let old: String
            let new: String
            if staged {
                old = file.status == .added ? "" : git.text(of: file.path, at: .head, in: root) ?? ""
                new = file.status == .deleted ? "" : git.text(of: file.path, at: .index, in: root) ?? ""
            } else {
                old = git.text(of: file.path, at: .index, in: root) ?? ""
                new = file.status == .deleted ? "" : (try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8)) ?? ""
            }
            text += LineDiff.unified(old: old, new: new, path: file.path, isNew: staged && file.status == .added,
                                     isDeleted: file.status == .deleted, color: true)
        }
        return text
    }

    private static func branch(_ args: [String], root: URL) async throws -> String {
        let git = GitManager.shared
        let names = args.filter { !$0.hasPrefix("-") }
        if args.contains("-d") || args.contains("-D") {
            for name in names { try git.deleteBranch(name, force: args.contains("-D"), in: root) }
            return names.map { "Deleted branch \($0).\n" }.joined()
        }
        if args.contains("-m") || args.contains("-M") {
            if names.count == 2 { try git.renameBranch(names[0], to: names[1], in: root) } else if let new = names.first {
                try git.renameBranch(git.currentBranch(in: root), to: new, in: root)
            }
            return ""
        }
        if let name = names.first {
            try git.createBranch(name, checkout: false, in: root)
            return ""
        }
        let current = git.currentBranch(in: root)
        var text = git.branches(in: root).map { $0 == current ? "* \(green)\($0)\(off)\n" : "  \($0)\n" }.joined()
        if args.contains("-a") || args.contains("-r") {
            let remotes = (try? await callback { git.remoteBranches(in: root, completion: $0) }) ?? []
            text += remotes.map { "  \(red)remotes/origin/\($0)\(off)\n" }.joined()
        }
        return text
    }

    private static func checkout(_ command: String, _ args: [String], root: URL, cwd: URL) async throws -> String {
        let git = GitManager.shared
        if let dashes = args.firstIndex(of: "--") {
            let paths = Array(args[(dashes + 1)...])
            for path in try matching(paths, candidates: git.status(in: root).changedFiles.map(\.path), root: root, cwd: cwd) {
                try git.discardChanges(for: path, in: root)
            }
            return ""
        }
        let names = args.filter { !$0.hasPrefix("-") }
        guard let name = names.first else { return "usage: git \(command) <branch>\n" }
        if args.contains("-b") || args.contains("-c") || args.contains("-B") {
            try git.createBranch(name, checkout: true, in: root)
            return "Switched to a new branch '\(name)'\n"
        }
        if git.branches(in: root).contains(name) {
            try git.checkout(name, in: root)
            return "Switched to branch '\(name)'\n"
        }
        let remoteName = name.hasPrefix("origin/") ? String(name.dropFirst("origin/".count)) : name
        try await callback { (done: @escaping (Result<Void, Error>) -> Void) in git.checkoutRemoteBranch(remoteName, in: root, completion: done) }
        return "Switched to a new branch '\(remoteName)' (from origin)\n"
    }

    private static func stash(_ args: [String], root: URL) throws -> String {
        let git = GitManager.shared
        let sub = args.first ?? "push"
        let number = args.dropFirst().compactMap { Int($0.replacingOccurrences(of: "stash@{", with: "").replacingOccurrences(of: "}", with: "")) }.first ?? 0
        switch sub {
        case "push", "save", "-m":
            var message = ""
            if let m = args.firstIndex(of: "-m"), m + 1 < args.count { message = args[m + 1] } else if sub == "save", args.count > 1 { message = args[1] }
            try git.stash(message: message, in: root)
            return "Saved working directory and index state\n"
        case "list":
            return git.stashes(in: root).map { "stash@{\($0.index)}: On \($0.branch): \($0.message)\n" }.joined()
        case "pop":
            try git.applyStash(number, drop: true, in: root)
            return "Dropped stash@{\(number)}\n"
        case "apply":
            try git.applyStash(number, drop: false, in: root)
            return ""
        case "drop":
            try git.dropStash(number, in: root)
            return "Dropped stash@{\(number)}\n"
        case "clear":
            try git.dropAllStashes(in: root)
            return ""
        default:
            return "usage: git stash [push [-m message] | list | pop | apply | drop | clear]\n"
        }
    }

    private static func remote(_ args: [String], root: URL) -> String {
        let git = GitManager.shared
        let url = git.getRemoteURL(in: root)
        switch args.first {
        case "add", "set-url":
            if args.count >= 3 { git.setRemoteURL(args[2], in: root) }
            return ""
        case "get-url":
            return (url ?? "") + "\n"
        default:
            guard let url else { return "" }
            return args.contains("-v") ? "origin\t\(url) (fetch)\norigin\t\(url) (push)\n" : "origin\n"
        }
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
            guard full == rootPath || full.hasPrefix(rootPath + "/") else {
                throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "'\(arg)' is outside the repository"])
            }
            let relative = full == rootPath ? "" : String(full.dropFirst(rootPath.count + 1))
            let found = candidates.filter { relative.isEmpty || $0 == relative || $0.hasPrefix(relative + "/") }
            if found.isEmpty {
                throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "pathspec '\(arg)' did not match any files"])
            }
            out += found
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    private static func callback<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
    }
}

/// Line diffs (Myers' algorithm, as git uses) and unified diff text.
enum LineDiff {
    enum Line: Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The edit from `a` to `b`, line by line.
    static func diff(_ a: [String], _ b: [String]) -> [Line] {
        var start = 0
        while start < a.count && start < b.count && a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start && endB > start && a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let middle = myers(Array(a[start..<endA]), Array(b[start..<endB]))
        return a[0..<start].map { .same($0) } + middle + a[endA...].map { .same($0) }
    }

    private static func myers(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count, m = b.count
        if n == 0 { return b.map { .added($0) } }
        if m == 0 { return a.map { .removed($0) } }
        let max = n + m
        let offset = max + 1
        var v = [Int](repeating: 0, count: 2 * max + 3)
        var trace: [[Int]] = []
        var found = false
        for d in 0...max {
            // Very different files: report them as replaced rather than spend minutes.
            if d > 4000 { return a.map { .removed($0) } + b.map { .added($0) } }
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break }
            }
            if found { break }
        }
        var x = n, y = m
        var out: [Line] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let previousK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
            let previousX = v[offset + previousK]
            let previousY = previousX - previousK
            while x > previousX && y > previousY { out.append(.same(a[x - 1])); x -= 1; y -= 1 }
            if d > 0 {
                if x == previousX { out.append(.added(b[y - 1])); y -= 1 } else { out.append(.removed(a[x - 1])); x -= 1 }
            }
        }
        return out.reversed()
    }

    /// git's unified diff for one file, with `context` lines around each change.
    static func unified(old: String, new: String, path: String, isNew: Bool = false, isDeleted: Bool = false,
                        context: Int = 3, color: Bool = false) -> String {
        let edits = diff(lines(old), lines(new))
        guard edits.contains(where: { if case .same = $0 { return false }; return true }) else { return "" }
        let (bold, cyan, red, green, off) = color ? ("\u{1B}[1m", "\u{1B}[36m", "\u{1B}[31m", "\u{1B}[32m", "\u{1B}[0m") : ("", "", "", "", "")
        var text = "\(bold)diff --git a/\(path) b/\(path)\n"
        text += isNew ? "--- /dev/null\n" : "--- a/\(path)\n"
        text += (isDeleted ? "+++ /dev/null" : "+++ b/\(path)") + "\(off)\n"
        // Line numbers (1-based) before each edit.
        var oldLine = 1, newLine = 1
        var numbered: [(Line, Int, Int)] = []
        for edit in edits {
            numbered.append((edit, oldLine, newLine))
            switch edit {
            case .same: oldLine += 1; newLine += 1
            case .removed: oldLine += 1
            case .added: newLine += 1
            }
        }
        let changed = numbered.indices.filter { if case .same = numbered[$0].0 { return false }; return true }
        var i = 0
        while i < changed.count {
            let first = changed[i]
            var last = first
            while i + 1 < changed.count && changed[i + 1] - last <= 2 * context { i += 1; last = changed[i] }
            i += 1
            let from = Swift.max(0, first - context), to = Swift.min(numbered.count, last + context + 1)
            let slice = numbered[from..<to]
            let oldCount = slice.filter { if case .added = $0.0 { return false }; return true }.count
            let newCount = slice.filter { if case .removed = $0.0 { return false }; return true }.count
            let oldStart = oldCount == 0 ? slice.first!.1 - 1 : slice.first!.1
            let newStart = newCount == 0 ? slice.first!.2 - 1 : slice.first!.2
            text += "\(cyan)@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(off)\n"
            for (edit, _, _) in slice {
                switch edit {
                case .same(let line): text += " \(line)\n"
                case .removed(let line): text += "\(red)-\(line)\(off)\n"
                case .added(let line): text += "\(green)+\(line)\(off)\n"
                }
            }
        }
        return text
    }
}
