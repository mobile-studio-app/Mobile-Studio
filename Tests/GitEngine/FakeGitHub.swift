import Foundation

/// An in-memory GitHub for the REST endpoints GitManager calls. It records every blob upload
/// and every path sent in a tree, so tests can prove pushes only send what changed.
final class FakeGitHub: URLProtocol {
    static var blobs: [String: Data] = [:]
    static var trees: [String: [String: String]] = [:]
    static var commits: [String: (tree: String, parents: [String], message: String)] = [:]
    static var refs: [String: String] = [:]
    static var defaultBranch = "main"
    static var blobUploads = 0
    static var treePaths: [String] = []
    private static var counter = 0

    static func reset() {
        blobs = [:]; trees = [:]; commits = [:]; refs = [:]
        defaultBranch = "main"; blobUploads = 0; treePaths = []
    }

    /// Adds a commit with exactly these files on top of `branch` (creating it if needed).
    @discardableResult
    static func seed(_ branch: String, files: [String: String], message: String = "seed") -> String {
        var tree: [String: String] = [:]
        for (path, text) in files {
            let data = Data(text.utf8)
            let sha = GitManager.blobSHA(data)
            blobs[sha] = data
            tree[path] = sha
        }
        let treeSHA = storeTree(tree)
        let sha = newSHA("commit")
        commits[sha] = (treeSHA, refs[branch].map { [$0] } ?? [], message)
        refs[branch] = sha
        return sha
    }

    /// The files at a branch's head, as text.
    static func files(_ branch: String) -> [String: String] {
        guard let head = refs[branch], let commit = commits[head], let tree = trees[commit.tree] else { return [:] }
        return tree.mapValues { String(decoding: blobs[$0] ?? Data(), as: UTF8.self) }
    }

    static func parents(_ commit: String) -> [String] { commits[commit]?.parents ?? [] }

    private static func storeTree(_ tree: [String: String]) -> String {
        let key = tree.keys.sorted().map { "\($0)=\(tree[$0]!)" }.joined(separator: ";")
        let sha = GitManager.blobSHA(Data(("tree:" + key).utf8))
        trees[sha] = tree
        return sha
    }

    private static func newSHA(_ kind: String) -> String {
        counter += 1
        return GitManager.blobSHA(Data("\(kind)-\(counter)-\(UUID().uuidString)".utf8))
    }

    private static func isAncestor(_ ancestor: String, of commit: String) -> Bool {
        var queue = [commit]
        var seen = Set<String>()
        while let next = queue.popLast() {
            if next == ancestor { return true }
            guard seen.insert(next).inserted else { continue }
            queue.append(contentsOf: parents(next))
        }
        return false
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, json) = Self.handle(request, body: Self.body(of: request))
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func handle(_ request: URLRequest, body: [String: Any]) -> (Int, Any) {
        let notFound: (Int, Any) = (404, ["message": "Not Found"])
        let invalid: (Int, Any) = (422, ["message": "Unprocessable"])
        guard let url = request.url else { return notFound }
        let parts = url.path.split(separator: "/").map(String.init)   // repos, owner, repo, ...
        guard parts.count >= 3, parts[0] == "repos" else { return notFound }
        let rest = Array(parts.dropFirst(3))
        let method = request.httpMethod ?? "GET"

        switch (method, rest.first, rest.dropFirst().first) {
        case ("GET", nil, _):
            return (200, ["default_branch": defaultBranch])
        case ("GET", "branches"?, _):
            return (200, refs.keys.sorted().map { ["name": $0] })
        case ("GET", "git"?, "ref"?):
            let branch = rest.dropFirst(3).joined(separator: "/")
            guard let sha = refs[branch] else { return notFound }
            return (200, ["object": ["sha": sha]])
        case ("GET", "git"?, "commits"?):
            guard let sha = rest.last, let commit = commits[sha] else { return notFound }
            return (200, ["sha": sha, "tree": ["sha": commit.tree], "message": commit.message, "author": ["name": "Fake"]])
        case ("GET", "git"?, "trees"?):
            guard let sha = rest.last, let tree = trees[sha] else { return notFound }
            return (200, ["sha": sha, "truncated": false,
                          "tree": tree.map { ["path": $0.key, "mode": "100644", "type": "blob", "sha": $0.value] }])
        case ("GET", "git"?, "blobs"?):
            guard let sha = rest.last, let data = blobs[sha] else { return notFound }
            return (200, ["sha": sha, "content": data.base64EncodedString(), "encoding": "base64"])
        case ("POST", "git"?, "blobs"?):
            guard let content = body["content"] as? String, let data = Data(base64Encoded: content) else { return invalid }
            let sha = GitManager.blobSHA(data)
            blobs[sha] = data
            blobUploads += 1
            return (201, ["sha": sha])
        case ("POST", "git"?, "trees"?):
            guard let base = body["base_tree"] as? String, var tree = trees[base],
                  let entries = body["tree"] as? [[String: Any]] else { return invalid }
            for entry in entries {
                guard let path = entry["path"] as? String else { return invalid }
                if let sha = entry["sha"] as? String {
                    guard blobs[sha] != nil else { return invalid }
                    tree[path] = sha
                } else {
                    guard tree[path] != nil else { return invalid }   // GitHub refuses to delete a missing path
                    tree[path] = nil
                }
                treePaths.append(path)
            }
            return (201, ["sha": storeTree(tree)])
        case ("POST", "git"?, "commits"?):
            guard let tree = body["tree"] as? String, trees[tree] != nil,
                  let parents = body["parents"] as? [String], parents.allSatisfy({ commits[$0] != nil }) else { return invalid }
            let sha = newSHA("commit")
            commits[sha] = (tree, parents, body["message"] as? String ?? "")
            return (201, ["sha": sha])
        case ("PATCH", "git"?, "refs"?):
            let branch = rest.dropFirst(3).joined(separator: "/")
            guard let old = refs[branch], let sha = body["sha"] as? String, commits[sha] != nil else { return invalid }
            if body["force"] as? Bool != true && !isAncestor(old, of: sha) { return invalid }
            refs[branch] = sha
            return (200, ["object": ["sha": sha]])
        case ("POST", "git"?, "refs"?):
            guard let ref = body["ref"] as? String, ref.hasPrefix("refs/heads/"), let sha = body["sha"] as? String,
                  commits[sha] != nil else { return invalid }
            let branch = String(ref.dropFirst("refs/heads/".count))
            guard refs[branch] == nil else { return invalid }
            refs[branch] = sha
            return (201, ["object": ["sha": sha]])
        default:
            return notFound
        }
    }
}
