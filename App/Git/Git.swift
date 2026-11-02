import Foundation
import Clibgit2

/// The Swift side of libgit2 (scripts/build-libgit2.sh): starting it, its errors, object IDs,
/// string arrays, and the callbacks network operations use for sign-in and progress.
/// GitRepository builds on these.
enum Git {
    /// libgit2 starts once. Global settings (`git config --global`) live in Application
    /// Support/git/.gitconfig; repositories in folders from the Files app can belong to another
    /// user ID than the app, which is fine here, so ownership isn't checked.
    static let ready: Void = {
        git_libgit2_init()
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("git", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = ms_git_set_global_config_path(home.path)
        _ = ms_git_set_owner_validation(0)
    }()

    /// Throws libgit2's error when `code` is negative.
    @discardableResult
    static func check(_ code: Int32, _ what: @autoclosure () -> String = "") throws -> Int32 {
        guard code < 0 else { return code }
        throw GitError(code: code, context: what())
    }

    static func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }

    static func hex(_ oid: UnsafePointer<git_oid>?) -> String {
        guard let oid, let text = git_oid_tostr_s(oid) else { return "" }
        return String(cString: text)
    }

    static func hex(_ oid: git_oid) -> String {
        var copy = oid
        return hex(&copy)
    }

    static func isZero(_ oid: git_oid) -> Bool {
        var copy = oid
        return git_oid_is_zero(&copy) == 1
    }

    /// A git_strarray for the duration of `body`.
    static func withStrings<T>(_ strings: [String], _ body: (UnsafeMutablePointer<git_strarray>) throws -> T) rethrows -> T {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var array = pointers
        return try array.withUnsafeMutableBufferPointer { buffer in
            var strarray = git_strarray(strings: buffer.baseAddress, count: buffer.count)
            return try body(&strarray)
        }
    }

    /// A git_strarray from libgit2, as Swift strings (it's freed).
    static func strings(_ array: inout git_strarray) -> [String] {
        defer { git_strarray_dispose(&array) }
        guard let strings = array.strings else { return [] }
        return (0..<array.count).map { string(strings[$0]) }
    }

    static func buffer(_ fill: (UnsafeMutablePointer<git_buf>) -> Int32) -> String? {
        var buf = git_buf()
        defer { git_buf_dispose(&buf) }
        guard fill(&buf) == 0, let ptr = buf.ptr else { return nil }
        return String(cString: ptr)
    }
}

/// A libgit2 error, with what was being done.
struct GitError: LocalizedError {
    let code: Int32
    let message: String
    /// For a checkout that local changes are in the way of: those files.
    var paths: [String] = []

    init(code: Int32, context: String = "") {
        self.code = code
        let last = git_error_last()
        let detail = last.flatMap { $0.pointee.message.map { String(cString: $0) } } ?? ""
        let text = detail.isEmpty ? "Git failed (\(code))." : detail.prefix(1).uppercased() + detail.dropFirst()
        message = context.isEmpty ? text : "\(context): \(text)"
    }

    init(_ message: String, code: Int32 = -1, paths: [String] = []) {
        self.code = code
        self.message = message
        self.paths = paths
    }

    var errorDescription: String? { message }

    var isConflict: Bool { code == GIT_ECONFLICT.rawValue || code == GIT_EMERGECONFLICT.rawValue }
    var isAuthentication: Bool { code == GIT_EAUTH.rawValue || code == Self.signInNeeded }
    var isNotFound: Bool { code == GIT_ENOTFOUND.rawValue }

    /// Codes of the app's own: a sign-in is needed (no credentials for the host), and a branch
    /// that isn't merged anywhere (deleting it would lose commits).
    static let signInNeeded: Int32 = -1001
    static let notMerged: Int32 = -1002
    static let nothingToCommit: Int32 = -1003
}

/// What a fetch, push or clone has done so far.
struct GitProgress {
    var phase: String
    var done: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

// MARK: - Credentials

/// Sign-in for HTTPS remotes: GitHub's from the signed-in account; other hosts' saved in the
/// Keychain (asked for when a remote says it needs them).
enum GitCredentials {
    struct Login {
        let user: String
        let password: String
    }

    static func host(of url: String) -> String? {
        if let host = URL(string: url)?.host { return host.lowercased() }
        // user@host:path
        if let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") {
            return String(url[url.index(after: at)..<colon]).lowercased()
        }
        return nil
    }

    static func login(for url: String) -> Login? {
        guard let host = host(of: url) else { return nil }
        if host == "github.com" || host.hasSuffix(".github.com"), let token = GitAccountManager.shared.token, !token.isEmpty {
            return Login(user: "x-access-token", password: token)
        }
        guard let saved = KeychainStore.string(for: "git-credential." + host),
              let split = saved.firstIndex(of: "\n") else { return nil }
        return Login(user: String(saved[..<split]), password: String(saved[saved.index(after: split)...]))
    }

    static func save(_ login: Login, for host: String) {
        KeychainStore.set(login.user + "\n" + login.password, for: "git-credential." + host.lowercased())
    }

    static func forget(host: String) {
        KeychainStore.remove("git-credential." + host.lowercased())
    }
}

/// What libgit2's network callbacks need: the progress handler, sign-in attempts, push
/// rejections, and whether to stop. Passed to C as the callbacks' payload.
final class GitTransfer {
    let progress: (GitProgress) -> Void
    var attempts = 0
    var needsSignIn = false
    var rejections: [String] = []
    var cancelled = false
    private var lastReport = Date.distantPast

    init(progress: @escaping (GitProgress) -> Void = { _ in }) {
        self.progress = progress
    }

    func report(_ progress: GitProgress) {
        // At most every 0.1 s, and always the last.
        let now = Date()
        guard progress.done >= progress.total || now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        self.progress(progress)
    }

    /// Fills libgit2's callbacks with this transfer's.
    func install(_ callbacks: inout git_remote_callbacks) {
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        callbacks.credentials = { out, url, _, allowed, payload in
            guard let payload else { return GIT_PASSTHROUGH.rawValue }
            let transfer = Unmanaged<GitTransfer>.fromOpaque(payload).takeUnretainedValue()
            transfer.attempts += 1
            let address = Git.string(url)
            // libgit2 asks again when a login is refused: once is enough.
            guard transfer.attempts == 1, allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0,
                  let login = GitCredentials.login(for: address) else {
                transfer.needsSignIn = true
                git_error_set_str(Int32(GIT_ERROR_CALLBACK.rawValue), transfer.attempts == 1
                    ? "\(GitCredentials.host(of: address) ?? address) needs you to sign in"
                    : "\(GitCredentials.host(of: address) ?? address) didn't accept the sign-in")
                return GIT_EAUTH.rawValue
            }
            return git_credential_userpass_plaintext_new(out, login.user, login.password)
        }
        callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let transfer = Unmanaged<GitTransfer>.fromOpaque(payload).takeUnretainedValue()
            let s = stats.pointee
            if s.received_objects < s.total_objects {
                transfer.report(GitProgress(phase: "Receiving objects", done: Int(s.received_objects), total: Int(s.total_objects)))
            } else {
                transfer.report(GitProgress(phase: "Resolving deltas", done: Int(s.indexed_deltas), total: Int(s.total_deltas)))
            }
            return transfer.cancelled ? -1 : 0
        }
        callbacks.push_transfer_progress = { current, total, _, payload in
            guard let payload else { return 0 }
            let transfer = Unmanaged<GitTransfer>.fromOpaque(payload).takeUnretainedValue()
            transfer.report(GitProgress(phase: "Writing objects", done: Int(current), total: Int(total)))
            return transfer.cancelled ? -1 : 0
        }
        callbacks.push_update_reference = { refname, status, payload in
            guard let payload, let status else { return 0 }
            let transfer = Unmanaged<GitTransfer>.fromOpaque(payload).takeUnretainedValue()
            transfer.rejections.append("\(Git.string(refname)): \(String(cString: status))")
            return 0
        }
    }

    /// The error for a failed network call: a sign-in one when that was the trouble.
    func error(_ code: Int32, _ what: String) -> GitError {
        var error = GitError(code: code, context: what)
        if needsSignIn { error = GitError(error.message, code: GitError.signInNeeded) }
        return error
    }
}
