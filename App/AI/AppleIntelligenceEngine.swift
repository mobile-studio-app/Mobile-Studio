import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Code completion with the on-device Apple Intelligence model (iOS 26+, supported iPhones only).
/// It's a general chat model with no fill-in-the-middle mode, so it gets the code with a cursor
/// marker and instructions to answer with only the text to insert.
enum AppleIntelligenceEngine {
    /// nil when Apple Intelligence can be used; otherwise why not, for Settings to show.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This iPhone doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in the Settings app."
                case .modelNotReady: return "Apple Intelligence is still getting ready. Try again later."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            }
        }
        return "Needs iOS 26 or later."
        #else
        return "This build of Mobile Studio doesn't include Apple Intelligence."
        #endif
    }

    private static let instructions = """
        You are the code completion engine of a code editor. You get a file with the marker <CURSOR> \
        where the user's cursor is. Reply with only the code to insert at <CURSOR>: no explanations, \
        no Markdown, no code fences. Never repeat code that is already before or after the cursor. \
        Keep it short: finish the current line, or write at most a few lines.
        """

    /// Merged code for one conflict (see ConflictResolver).
    static func resolve(_ request: ConflictRequest, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: ConflictResolver.instructions)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            return try await session.respond(to: ConflictResolver.chatPrompt(request), options: options).content
        }
        #endif
        throw NSError(domain: "DuoCodeAI", code: -1, userInfo: [NSLocalizedDescriptionKey: unavailableReason ?? "Unavailable"])
    }

    /// The Chat panel's answer to a conversation (AIChatService). Its context is small, so only the
    /// latest part of a long conversation goes in.
    static func chat(_ messages: [ChatMessage]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let instructions = messages.first { $0.role == "system" }?.content ?? ""
            let turns = messages.filter { $0.role != "system" }
            let session = LanguageModelSession(instructions: instructions)
            // The first turn (the question, or a subagent's task) always stays; of the rest, the newest
            // that fit in about 6,000 characters.
            let earlier = turns.dropLast().map { "\($0.role == "user" ? "User" : "Assistant"): \($0.content)" }
            var history = ""
            if let first = earlier.first {
                var rest = earlier.dropFirst().joined(separator: "\n\n")
                let room = max(0, 6000 - first.count)
                if rest.count > room { rest = room > 0 ? "…\n" + String(rest.suffix(room)) : "" }
                history = rest.isEmpty ? first : first + "\n\n" + rest
            }
            let question = turns.last?.content ?? ""
            let prompt = history.isEmpty ? question : "The conversation so far:\n\n\(history)\n\nUser: \(question)"
            return try await session.respond(to: prompt).content
        }
        #endif
        throw NSError(domain: "DuoCodeAI", code: -1, userInfo: [NSLocalizedDescriptionKey: unavailableReason ?? "Unavailable"])
    }

    static func complete(prefix: String, suffix: String, path: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let language = path.hasSuffix(".lua") ? "Lua for the LÖVE game framework" : "the language of \(path)"
            let prompt = "File \(path) (\(language)):\n\(prefix)<CURSOR>\(suffix)"
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            return try await session.respond(to: prompt, options: options).content
        }
        #endif
        throw NSError(domain: "DuoCodeAI", code: -1, userInfo: [NSLocalizedDescriptionKey: unavailableReason ?? "Unavailable"])
    }
}
