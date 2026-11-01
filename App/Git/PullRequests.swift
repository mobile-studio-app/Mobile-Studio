import Foundation

/// A GitHub pull request, as the pull requests list and its detail show it.
struct PullRequest {
    let number: Int
    let title: String
    let body: String
    let state: String          // "open" or "closed"
    let isMerged: Bool
    let isDraft: Bool
    let author: String
    let created: Date
    let headRef: String
    let headSHA: String
    /// "owner/repo" of the head branch: another repository for a pull request from a fork.
    let headRepo: String
    let baseRef: String
    let baseSHA: String
    let url: URL?

    init(_ json: [String: Any]) {
        let head = json["head"] as? [String: Any] ?? [:]
        let base = json["base"] as? [String: Any] ?? [:]
        number = json["number"] as? Int ?? 0
        title = json["title"] as? String ?? ""
        body = json["body"] as? String ?? ""
        state = json["state"] as? String ?? "open"
        isMerged = json["merged_at"] is String
        isDraft = json["draft"] as? Bool ?? false
        author = (json["user"] as? [String: Any])?["login"] as? String ?? ""
        created = PullRequests.date(json["created_at"])
        headRef = head["ref"] as? String ?? ""
        headSHA = head["sha"] as? String ?? ""
        headRepo = (head["repo"] as? [String: Any])?["full_name"] as? String ?? ""
        baseRef = base["ref"] as? String ?? ""
        baseSHA = base["sha"] as? String ?? ""
        url = (json["html_url"] as? String).flatMap(URL.init(string:))
    }
}

struct PullRequestFile {
    let path: String
    let status: String         // added, removed, modified, renamed, …
    let additions: Int
    let deletions: Int
    let previousPath: String?
}

struct PullRequestComment {
    let author: String
    let body: String
    let date: Date
}

/// GitHub's pull request API for the open project's repository (its GitHub remote), signed in
/// with the account from Settings → Source Control.
enum PullRequests {
    static func date(_ value: Any?) -> Date {
        guard let text = value as? String else { return .distantPast }
        return ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    /// repos/{owner}/{repo}/{path} on GitHub. HTTP errors throw with GitHub's message.
    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, raw: Bool = false,
                                in project: URL) async throws -> Data {
        let repo = try GitManager.shared.gitHubRepository(in: project)
        let suffix = path.isEmpty ? "" : "/\(path)"
        guard let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)\(suffix)") else {
            throw error("Invalid GitHub path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(repo.token)", forHTTPHeaderField: "Authorization")
        request.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MobileStudio-iOS", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            var detail = json?["message"] as? String ?? "HTTP \(status)"
            // Validation errors say what's wrong in "errors".
            if let errors = json?["errors"] as? [[String: Any]], let first = errors.first?["message"] as? String { detail += ": \(first)" }
            switch status {
            case 401: throw error("GitHub rejected the sign-in. Sign in again in Settings → Source Control.", code: status)
            case 404 where path.hasPrefix("contents/"): throw error("Not found", code: 404)
            default: throw error("GitHub: \(detail)", code: status)
            }
        }
        return data
    }

    private static func json(_ path: String, method: String = "GET", body: [String: Any]? = nil, in project: URL) async throws -> Any {
        let data = try await request(path, method: method, body: body, in: project)
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    static func error(_ message: String, code: Int = -1) -> NSError {
        NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// "open", "closed" or "all", newest first.
    static func list(state: String, in project: URL) async throws -> [PullRequest] {
        let list = try await json("pulls?state=\(state)&per_page=50&sort=updated&direction=desc", in: project) as? [[String: Any]] ?? []
        return list.map(PullRequest.init)
    }

    static func get(_ number: Int, in project: URL) async throws -> PullRequest {
        PullRequest(try await json("pulls/\(number)", in: project) as? [String: Any] ?? [:])
    }

    static func files(_ number: Int, in project: URL) async throws -> [PullRequestFile] {
        let list = try await json("pulls/\(number)/files?per_page=100", in: project) as? [[String: Any]] ?? []
        return list.map {
            PullRequestFile(path: $0["filename"] as? String ?? "", status: $0["status"] as? String ?? "modified",
                            additions: $0["additions"] as? Int ?? 0, deletions: $0["deletions"] as? Int ?? 0,
                            previousPath: $0["previous_filename"] as? String)
        }
    }

    /// The conversation (issue comments), oldest first.
    static func comments(_ number: Int, in project: URL) async throws -> [PullRequestComment] {
        let list = try await json("issues/\(number)/comments?per_page=100", in: project) as? [[String: Any]] ?? []
        return list.map {
            PullRequestComment(author: ($0["user"] as? [String: Any])?["login"] as? String ?? "",
                               body: $0["body"] as? String ?? "", date: date($0["created_at"]))
        }
    }

    static func addComment(_ number: Int, body: String, in project: URL) async throws {
        _ = try await request("issues/\(number)/comments", method: "POST", body: ["body": body], in: project)
    }

    static func create(title: String, body: String, head: String, base: String, draft: Bool, in project: URL) async throws -> PullRequest {
        let json = try await json("pulls", method: "POST",
                                  body: ["title": title, "body": body, "head": head, "base": base, "draft": draft], in: project)
        return PullRequest(json as? [String: Any] ?? [:])
    }

    /// method: "merge", "squash" or "rebase".
    static func merge(_ number: Int, method: String, in project: URL) async throws {
        _ = try await request("pulls/\(number)/merge", method: "PUT", body: ["merge_method": method], in: project)
    }

    static func close(_ number: Int, in project: URL) async throws {
        _ = try await request("pulls/\(number)", method: "PATCH", body: ["state": "closed"], in: project)
    }

    /// A file's text at a commit; nil when it doesn't exist there (or isn't text).
    static func fileText(_ path: String, at ref: String, in project: URL) async throws -> String? {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        do {
            let data = try await request("contents/\(encoded)?ref=\(ref)", raw: true, in: project)
            return String(data: data, encoding: .utf8)
        } catch let error as NSError where error.code == 404 {
            return nil
        }
    }

    static func defaultBranch(in project: URL) async throws -> String {
        (try await json("", in: project) as? [String: Any])?["default_branch"] as? String ?? "main"
    }
}
