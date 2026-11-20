import Foundation

/// The Chat panel's saved chats, per project, so a chat can be reopened after the app closes or a
/// new one starts. Separate from the context cache: chats don't count against its limit, and
/// clearing it keeps them. Each chat is one JSON file (chat.js decides what's in it); a project
/// keeps its latest 200.
final class ChatHistory {
    static let shared = ChatHistory()
    static let keptPerProject = 200

    private let directory: URL
    private let queue = DispatchQueue(label: "app.mobilestudio.chathistory", qos: .utility)
    private let fm = FileManager.default

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A project's folder, by its folder's name (which survives reinstalling the app).
    private func folder(_ project: URL) -> URL {
        let name = project.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(name.isEmpty ? "_" : name, isDirectory: true)
    }

    /// A chat's file; ids are letters and digits, so one can't name a file elsewhere.
    private func file(_ id: String, _ project: URL) throws -> URL {
        guard !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw NSError(domain: "MobileStudioChats", code: -1, userInfo: [NSLocalizedDescriptionKey: "There's no chat \(id)."])
        }
        return folder(project).appendingPathComponent(id + ".json")
    }

    /// For the page: list, load, save and delete; replies on the main queue.
    func handle(_ op: String, _ body: [String: Any], project: URL, reply: @escaping (Any?, String?) -> Void) {
        queue.async {
            let result: Result<Any, Error> = Result {
                switch op {
                case "list":
                    // Newest first: id, title, when it changed and how many messages, without the rest.
                    let files = (try? self.fm.contentsOfDirectory(at: self.folder(project), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    let chats = files.filter { $0.pathExtension == "json" }.compactMap { url -> [String: Any]? in
                        guard let data = try? Data(contentsOf: url),
                              let chat = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return ["id": url.deletingPathExtension().lastPathComponent, "title": chat["title"] as? String ?? "Chat",
                                "updated": date.timeIntervalSince1970 * 1000, "count": (chat["messages"] as? [Any])?.count ?? 0]
                    }
                    return chats.sorted { ($0["updated"] as? Double ?? 0) > ($1["updated"] as? Double ?? 0) }
                case "load":
                    let data = try Data(contentsOf: try self.file(body["id"] as? String ?? "", project))
                    return try JSONSerialization.jsonObject(with: data)
                case "save":
                    let url = try self.file(body["id"] as? String ?? "", project)
                    guard let chat = body["chat"] else { throw NSError(domain: "MobileStudioChats", code: -1) }
                    try self.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONSerialization.data(withJSONObject: chat).write(to: url, options: .atomic)
                    self.trim(project)
                    return true
                case "delete":
                    try? self.fm.removeItem(at: try self.file(body["id"] as? String ?? "", project))
                    return true
                default:
                    throw NSError(domain: "MobileStudioChats", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown operation \(op)."])
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let value): reply(value, nil)
                case .failure(let error): reply(nil, error.localizedDescription)
                }
            }
        }
    }

    /// Keeps a project's newest chats.
    private func trim(_ project: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = ((try? fm.contentsOfDirectory(at: folder(project), includingPropertiesForKeys: keys)) ?? []).filter { $0.pathExtension == "json" }
        guard files.count > Self.keptPerProject else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.keptPerProject) { try? fm.removeItem(at: url) }
    }
}
