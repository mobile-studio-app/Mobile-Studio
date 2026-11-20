import Foundation

/// The context cache: storage the Chat agent uses as slow context, under one limit the user sets
/// (Settings → AI → Context Cache: 2 GB unless changed, up to 10 GB). Two things live in it:
///
/// - **Memory**, per project: text the agent saved as notes (`remember`), and text set aside when it
///   left the context (a conversation compacted to a summary, a long tool result cut short). The
///   agent's tools search it and load parts back into the context (chat.js), so nothing the agent
///   read is lost for good, and notes carry over from one chat to the next.
/// - **Model states**: what a local model has read for a conversation (its KV cache and recurrent
///   state, llama.cpp's sequence state). Going back to that conversation (after a subagent used the
///   model, another chat, or iOS closing the app) loads it from storage, which takes a moment, instead
///   of reading the whole conversation again, which can take a minute on a phone. A state only works
///   whole and from the start of its conversation, so it saves time; memory is what extends the context.
///
/// Over the limit, the least recently used model states go first, then set-aside text, then notes.
final class ContextCache {
    static let shared = ContextCache()

    /// The limits Settings offers.
    static let limits: [Int64] = [512, 1024, 2048, 4096, 6144, 8192, 10240].map { Int64($0) * 1_048_576 }
    static let defaultLimit: Int64 = 2048 * 1_048_576
    static let maximumLimit: Int64 = 10240 * 1_048_576
    /// A state shorter than this is quicker to read again than to save.
    static let minimumStateTokens = 3072

    /// Application Support/ContextCache, excluded from iCloud backup.
    let directory: URL
    private var memoryDirectory: URL { directory.appendingPathComponent("Memory", isDirectory: true) }
    private var statesDirectory: URL { directory.appendingPathComponent("States", isDirectory: true) }
    private let queue = DispatchQueue(label: "app.mobilestudio.contextcache", qos: .utility)
    private let fm = FileManager.default

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("ContextCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir
    }

    // MARK: - Memory

    /// A piece of memory: a note the agent saved, or text set aside from the context.
    struct Entry: Codable {
        let id: String
        /// "note" or "archive" (set aside).
        let kind: String
        let title: String
        let text: String
        let created: Date
        var used: Date
    }

    /// A project's memory folder: by its folder's name, which stays the same when the app is reinstalled.
    private func folder(_ project: URL) -> URL {
        let name = project.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        return memoryDirectory.appendingPathComponent(name.isEmpty ? "_" : name, isDirectory: true)
    }

    private func entries(_ project: URL) -> [Entry] {
        let dir = folder(project)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }.compactMap { try? decoder.decode(Entry.self, from: Data(contentsOf: $0)) }
    }

    private func write(_ entry: Entry, _ project: URL) throws {
        let dir = folder(project)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent(entry.id + ".json"), options: .atomic)
    }

    /// For the page: what each call answers, on the main queue.
    func memory(_ op: String, _ body: [String: Any], project: URL, reply: @escaping (Any?, String?) -> Void) {
        queue.async {
            let result: Result<Any, Error> = Result {
                switch op {
                case "save":
                    let kind = body["kind"] as? String == "archive" ? "archive" : "note"
                    let text = body["text"] as? String ?? ""
                    guard !text.isEmpty else { throw Self.error("There's nothing to save.") }
                    var title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.isEmpty { title = String(text.prefix(60)) }
                    // A note with a title already used replaces that one, so notes can be updated.
                    let old: Entry? = kind == "note"
                        ? self.entries(project).first(where: { $0.kind == "note" && $0.title.lowercased() == title.lowercased() }) : nil
                    let id = old?.id ?? "m" + String(UInt64.random(in: 0..<2_176_782_336), radix: 36)
                    let entry = Entry(id: id, kind: kind, title: title, text: text, created: old?.created ?? Date(), used: Date())
                    try self.write(entry, project)
                    self.trim()
                    return ["id": id, "replaced": old != nil] as [String: Any]
                case "read":
                    let id = body["id"] as? String ?? ""
                    guard var entry = self.entries(project).first(where: { $0.id == id }) else { throw Self.error("There's no memory \(id).") }
                    entry.used = Date()
                    try? self.write(entry, project)
                    return Self.json(entry, text: true)
                case "search":
                    let limit = body["limit"] as? Int ?? 8
                    return self.search(String(body["query"] as? String ?? ""), in: self.entries(project), limit: limit)
                case "list":
                    let all = self.entries(project).sorted { $0.used > $1.used }
                    return Array(all.prefix(body["limit"] as? Int ?? 200)).map { Self.json($0, text: false) }
                case "delete":
                    let id = body["id"] as? String ?? ""
                    // Ids are letters and digits: one from the model can't name a file elsewhere.
                    let url = self.folder(project).appendingPathComponent(id + ".json")
                    guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), self.fm.fileExists(atPath: url.path) else {
                        throw Self.error("There's no memory \(id).")
                    }
                    try self.fm.removeItem(at: url)
                    return true
                default:
                    throw Self.error("Unknown memory operation \(op).")
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

    private static func json(_ e: Entry, text: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": e.id, "kind": e.kind, "title": e.title, "length": e.text.count,
                                  "created": e.created.timeIntervalSince1970 * 1000, "used": e.used.timeIntervalSince1970 * 1000]
        if text { out["text"] = e.text }
        return out
    }

    /// Entries that have the query's words, best first (each word counts for less the more entries
    /// have it; in the title, for more), with the passage that has the most of them.
    private func search(_ query: String, in entries: [Entry], limit: Int) -> [[String: Any]] {
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init).filter { $0.count > 1 })
        guard !words.isEmpty else { return Array(entries.sorted { $0.used > $1.used }.prefix(limit)).map { Self.json($0, text: false) } }
        let lowered = entries.map { ($0, $0.title.lowercased(), $0.text.lowercased()) }
        var idf: [String: Double] = [:]
        for w in words {
            let having = lowered.filter { $0.1.contains(w) || $0.2.contains(w) }.count
            idf[w] = log(1 + Double(lowered.count + 1) / Double(having + 1))
        }
        var scored: [(Entry, Double, String)] = []
        for (entry, title, text) in lowered {
            var score = 0.0
            for w in words {
                let count = text.components(separatedBy: w).count - 1
                if count > 0 { score += idf[w]! * (1 + log(Double(count))) }
                if title.contains(w) { score += idf[w]! * 2 }
            }
            if score > 0 { scored.append((entry, score, Self.passage(entry.text, words: words))) }
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit)).map { item -> [String: Any] in
            var out = Self.json(item.0, text: false)
            out["score"] = (item.1 * 100).rounded() / 100
            out["passage"] = item.2
            return out
        }
    }

    /// About 300 characters around where the most query words are.
    private static func passage(_ text: String, words: Set<String>) -> String {
        let chars = Array(text)
        guard chars.count > 300 else { return text }
        let lower = Array(text.lowercased())
        var best = 0
        var bestCount = -1
        var start = 0
        while start < chars.count {
            let window = String(lower[start..<min(lower.count, start + 300)])
            let count = words.reduce(0) { $0 + (window.contains($1) ? 1 : 0) }
            if count > bestCount { bestCount = count; best = start }
            start += 150
        }
        return (best > 0 ? "…" : "") + String(chars[best..<min(chars.count, best + 300)]) + (best + 300 < chars.count ? "…" : "")
    }

    // MARK: - Model states

    /// The folder of one model's states at one context size and cache precision (a state only loads
    /// into the same).
    private func statesFolder(_ key: String) -> URL { statesDirectory.appendingPathComponent(key, isDirectory: true) }

    /// Saves what a model has read for `tokens` (its sequence state), replacing any saved state its
    /// conversation had before (one that starts the same and is shorter). Runs in the background;
    /// `data` stays alive until it's written.
    func saveState(_ key: String, tokens: [Int32], data: [UInt8]) {
        guard tokens.count >= Self.minimumStateTokens, !data.isEmpty, Int64(data.count) < limit / 2 else { return }
        queue.async {
            // Room on the device: the cache never takes the last of it.
            if let free = try? self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < Int64(data.count) * 2 + 1_000_000_000 { return }
            let dir = self.statesFolder(key)
            try? self.fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (url, saved) in self.savedTokens(dir) where saved.count <= tokens.count && tokens.starts(with: saved) {
                if saved.count == tokens.count {
                    // The same: just used again.
                    try? self.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                    return
                }
                self.removeState(url)
            }
            let base = dir.appendingPathComponent(UUID().uuidString)
            do {
                try Data(data).write(to: base.appendingPathExtension("state"))
                try tokens.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: base.appendingPathExtension("tokens"))
            } catch {
                self.removeState(base.appendingPathExtension("tokens"))
                return
            }
            self.trim()
        }
    }

    /// The longest saved state `prompt` starts with (shorter than it, so there's something to read),
    /// as its tokens and data. Runs on the caller's queue (a model's, which waits for it anyway).
    func loadState(_ key: String, prompt: [Int32]) -> (tokens: [Int32], data: [UInt8])? {
        queue.sync { () -> (tokens: [Int32], data: [UInt8])? in
            let dir = statesFolder(key)
            guard let best = savedTokens(dir).filter({ $0.1.count < prompt.count && prompt.starts(with: $0.1) })
                .max(by: { $0.1.count < $1.1.count }),
                let data = try? Data(contentsOf: best.0.deletingPathExtension().appendingPathExtension("state"), options: .mappedIfSafe)
            else { return nil }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: best.0.path)
            return (best.1, [UInt8](data))
        }
    }

    /// Each saved state's tokens file and tokens.
    private func savedTokens(_ dir: URL) -> [(URL, [Int32])] {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "tokens" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count % 4 == 0 else { return nil }
            return (url, data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) })
        }
    }

    private func removeState(_ tokensURL: URL) {
        try? fm.removeItem(at: tokensURL)
        try? fm.removeItem(at: tokensURL.deletingPathExtension().appendingPathExtension("state"))
    }

    // MARK: - Size

    var limit: Int64 { AppSettings.shared.contextCacheLimit }

    /// Bytes in use: memory and states.
    func usage(_ completion: @escaping (Int64) -> Void) {
        queue.async {
            let bytes = self.files().reduce(Int64(0)) { $0 + $1.size }
            DispatchQueue.main.async { completion(bytes) }
        }
    }

    /// Deletes everything: memory and model states.
    func clear(_ completion: @escaping () -> Void) {
        queue.async {
            try? self.fm.removeItem(at: self.memoryDirectory)
            try? self.fm.removeItem(at: self.statesDirectory)
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Runs `completion` on the main queue once the writes asked for so far are done.
    func afterWrites(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    /// The limit changed: back under it.
    func limitChanged() { queue.async { self.trim() } }

    private struct File {
        let url: URL
        let size: Int64
        let used: Date
        /// 0: a model state, 1: set-aside text, 2: a note.
        let rank: Int
    }

    private func files() -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walk = fm.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var out: [File] = []
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let rank = url.pathExtension == "state" || url.pathExtension == "tokens" ? 0
                : (try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: url)))?.kind == "note" ? 2 : 1
            out.append(File(url: url, size: Int64(values.fileSize ?? 0), used: values.contentModificationDate ?? .distantPast, rank: rank))
        }
        return out
    }

    /// Deletes the least recently used model states, then set-aside text, then notes, until the cache
    /// is under its limit. On `queue`.
    private func trim() {
        let all = files()
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        // A state's .state and .tokens go together.
        for file in all.filter({ $0.url.pathExtension != "tokens" }).sorted(by: { ($0.rank, $0.used) < ($1.rank, $1.used) }) {
            guard total > limit else { break }
            if file.url.pathExtension == "state" {
                let tokens = file.url.deletingPathExtension().appendingPathExtension("tokens")
                total -= file.size + (all.first { $0.url == tokens }?.size ?? 0)
                removeState(tokens)
            } else {
                total -= file.size
                try? fm.removeItem(at: file.url)
            }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MobileStudioContextCache", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
