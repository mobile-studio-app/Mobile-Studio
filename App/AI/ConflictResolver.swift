import Foundation

/// One merge conflict for the AI to resolve, with the code around it.
struct ConflictRequest {
    let path: String
    let ours: String
    let theirs: String
    let base: String?
    let before: String
    let after: String
    let oursLabel: String
    let theirsLabel: String
}

/// Prompts and answer checks for "Resolve for me". The local models are code completion models
/// with no chat mode, so they see the two versions as a comment just above the conflict and
/// fill in the merged code there; Apple Intelligence gets plain instructions instead.
enum ConflictResolver {
    /// Line comment syntax for the file's language.
    static func comment(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "lua": return "--"
        case "py", "sh", "rb", "toml", "yml", "yaml", "conf", "cfg": return "#"
        default: return "//"
        }
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Fill-in-the-middle prompt for the local models.
    static func fillInPrompt(_ request: ConflictRequest) -> (prefix: String, suffix: String) {
        let c = comment(for: request.path)
        var note = ["\(c) Merge conflict: write one version of this code that keeps the changes from both versions below."]
        note.append("\(c) Version from \(request.oursLabel) (current):")
        note += lines(request.ours).map { "\(c) \($0)" }
        if let base = request.base {
            note.append("\(c) Original version (before either change):")
            note += lines(base).map { "\(c) \($0)" }
        }
        note.append("\(c) Version from \(request.theirsLabel) (incoming):")
        note += lines(request.theirs).map { "\(c) \($0)" }
        note.append("\(c) Merged version:")
        return (request.before + note.joined(separator: "\n") + "\n", request.after)
    }

    static let instructions = """
        You resolve Git merge conflicts in source code. You get the code around a conflict and the two \
        conflicting versions. Reply with only the code that replaces the conflict: combine both versions \
        so the changes from each are kept, match the surrounding indentation, and don't repeat code from \
        before or after the conflict. No explanations, no Markdown, no code fences, no conflict markers.
        """

    /// Prompt for Apple Intelligence.
    static func chatPrompt(_ request: ConflictRequest) -> String {
        let before = lines(request.before).suffix(30).joined(separator: "\n")
        let after = lines(request.after).prefix(15).joined(separator: "\n")
        var prompt = "File: \(request.path)\n\nCode before the conflict:\n\(before)\n\n"
        prompt += "Version A, from \(request.oursLabel) (current):\n\(request.ours)\n"
        if let base = request.base { prompt += "Original version, before either change:\n\(base)\n" }
        prompt += "Version B, from \(request.theirsLabel) (incoming):\n\(request.theirs)\n"
        prompt += "Code after the conflict:\n\(after)\n\nMerged code:"
        return prompt
    }

    /// Enough room for both versions written out once.
    static func maxTokens(_ request: ConflictRequest) -> Int {
        min(900, max(96, (request.ours.utf8.count + request.theirs.utf8.count) / 2 + 64))
    }

    /// Trims a model's answer to the replacement for the conflict, or nil if it isn't usable.
    static func clean(_ raw: String, for request: ConflictRequest) -> String? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }

        // Stop where a model runs on into the code that follows the conflict.
        if let next = request.after.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
           next.count >= 4,
           let cut = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == next }), cut > 0 {
            lines = Array(lines[..<cut])
        }

        // Drop echoes of the prompt's own comments.
        let echoes = ["Merge conflict:", "Merged version", "Version from", "Original version", "(current):", "(incoming):"]
        lines.removeAll { line in echoes.contains { line.contains($0) } }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }

        // A tail that repeats the start of the code after the conflict (an "end", a closing brace)
        // is the model running on, unless one of the versions ended that way too.
        let following = request.after.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let versionEnds = Set([Self.lines(request.ours), Self.lines(request.theirs)].compactMap { $0.last?.trimmingCharacters(in: .whitespaces) })
        for cut in lines.indices.dropFirst() where !lines[cut].trimmingCharacters(in: .whitespaces).isEmpty {
            let rest = lines[cut...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if rest.count <= following.count, rest == Array(following.prefix(rest.count)), let last = rest.last, !versionEnds.contains(last) {
                lines = Array(lines[..<cut])
                break
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        // Conflict markers mean it didn't merge anything.
        if lines.contains(where: { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") || $0 == "=======" || $0.hasPrefix("|||||||") }) {
            return nil
        }
        // Every line commented out means it copied the versions from the prompt instead of merging them.
        let c = comment(for: request.path)
        let allComments = { (text: [String]) in text.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(c) } }
        if allComments(lines) && !allComments(Self.lines(request.ours) + Self.lines(request.theirs)) { return nil }

        return lines.joined(separator: "\n") + "\n"
    }
}
