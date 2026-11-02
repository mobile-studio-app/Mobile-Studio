import Foundation

/// A Chat model on a server, with the user's own API key: off until the user sets one up in
/// Settings → AI → Cloud Models. Unlike everything else in Mobile Studio's AI, the conversation,
/// including the code the agent reads, is sent to the provider.
enum CloudProvider: String, CaseIterable {
    case anthropic, openai, openrouter, custom

    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom Server"
        }
    }

    /// What Settings shows under the name.
    var detail: String {
        switch self {
        case .anthropic: return "Claude models, with an Anthropic API key"
        case .openai: return "GPT models, with an OpenAI API key"
        case .openrouter: return "Models from many providers, with an OpenRouter key"
        case .custom: return "Ollama, LM Studio or another OpenAI-compatible server"
        }
    }

    var choice: AIModelChoice { AIModelChoice(rawValue: "cloud:" + rawValue)! }

    static func from(_ choice: AIModelChoice) -> CloudProvider? {
        guard choice.rawValue.hasPrefix("cloud:") else { return nil }
        return CloudProvider(rawValue: String(choice.rawValue.dropFirst(6)))
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai, .openrouter, .custom: return ""
        }
    }

    var modelPlaceholder: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "Model, like gpt-5"
        case .openrouter: return "Model, like anthropic/claude-sonnet-5-5"
        case .custom: return "Model, like qwen3:8b"
        }
    }

    /// A server on your own network needs no key.
    var needsKey: Bool { self != .custom }

    private var keyAccount: String { "cloud-ai-key." + rawValue }
    private var defaultsKey: String { "settings.ai.cloud." + rawValue }

    var apiKey: String {
        get { KeychainStore.string(for: keyAccount) ?? "" }
        nonmutating set { if newValue.isEmpty { KeychainStore.remove(keyAccount) } else { KeychainStore.set(newValue, for: keyAccount) } }
    }

    var model: String {
        get { UserDefaults.standard.string(forKey: defaultsKey + ".model") ?? defaultModel }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey + ".model") }
    }

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: defaultsKey + ".url") ?? defaultBaseURL }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey + ".url") }
    }

    /// Set up: a model, and a key (or, for a custom server, its address).
    var isConfigured: Bool {
        !model.isEmpty && (needsKey ? !apiKey.isEmpty : !baseURL.isEmpty)
    }

    func forget() {
        apiKey = ""
        UserDefaults.standard.removeObject(forKey: defaultsKey + ".model")
        UserDefaults.standard.removeObject(forKey: defaultsKey + ".url")
    }

    /// The model's context window, as far as it's known from its name; a custom server's model is
    /// assumed to be modest (Ollama's default is smaller still, but most models take this much).
    var contextSize: Int {
        let m = model.lowercased()
        switch self {
        case .anthropic: return 200_000
        case .openai, .openrouter:
            if m.contains("claude") { return 200_000 }
            if m.contains("gemini") { return 1_000_000 }
            if m.contains("gpt-4.1") || m.contains("gpt-5") { return 400_000 }
            return 128_000
        case .custom: return 32_768
        }
    }

    /// The Chat panel's name for it.
    var displayName: String { "\(model) (\(name))" }
}

enum CloudChat {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Streams `provider`'s answer; `onText` gets the answer so far. Cancelling the task stops it.
    static func respond(_ provider: CloudProvider, messages: [ChatMessage], maxTokens: Int,
                        onText: @escaping (String) -> Void) async throws -> String {
        let request = try makeRequest(provider, messages: messages, maxTokens: maxTokens)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 4000 { break } }
            throw Failure(message: "\(provider.name): \(errorMessage(body) ?? "the server answered \(status)")")
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { continue }
            if let error = json["error"] { throw Failure(message: "\(provider.name): \(errorMessage(error) ?? "error")") }
            if let piece = delta(provider, json), !piece.isEmpty {
                text += piece
                onText(text)
            }
        }
        return text
    }

    private static func makeRequest(_ provider: CloudProvider, messages: [ChatMessage], maxTokens: Int) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard provider.isConfigured else {
            throw Failure(message: "\(provider.name) isn't set up: add a key and model in Settings → AI → Cloud Models.")
        }
        let path = provider == .anthropic ? "/v1/messages" : "/chat/completions"
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http" else {
            throw Failure(message: "\(provider.name): \(base) isn't a web address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": provider.model, "stream": true]
        switch provider {
        case .anthropic:
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = maxTokens
            let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            body["messages"] = alternating(messages.filter { $0.role != "system" })
        case .openai, .openrouter, .custom:
            if !provider.apiKey.isEmpty { request.setValue("Bearer " + provider.apiKey, forHTTPHeaderField: "Authorization") }
            if provider == .openrouter { request.setValue("Mobile Studio", forHTTPHeaderField: "X-Title") }
            // OpenAI's newer models take max_completion_tokens; other servers know max_tokens.
            body[provider == .openai ? "max_completion_tokens" : "max_tokens"] = maxTokens
            body["messages"] = messages.map { ["role": $0.role, "content": $0.content] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Anthropic's messages alternate, starting with the user's: neighbours with the same role join.
    private static func alternating(_ messages: [ChatMessage]) -> [[String: String]] {
        var out: [[String: String]] = []
        for m in messages {
            let role = m.role == "assistant" ? "assistant" : "user"
            if out.isEmpty && role == "assistant" { out.append(["role": "user", "content": "(The conversation so far.)"]) }
            if let last = out.last, last["role"] == role {
                out[out.count - 1]["content"] = (last["content"] ?? "") + "\n\n" + m.content
            } else {
                out.append(["role": role, "content": m.content])
            }
        }
        return out
    }

    private static func delta(_ provider: CloudProvider, _ json: [String: Any]) -> String? {
        if provider == .anthropic {
            guard json["type"] as? String == "content_block_delta", let delta = json["delta"] as? [String: Any] else { return nil }
            return delta["text"] as? String
        }
        guard let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    /// The message in an error answer (a JSON body, or an error object).
    private static func errorMessage(_ value: Any) -> String? {
        var object = value
        if let text = value as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return text.isEmpty ? nil : String(text.prefix(300)) }
            object = parsed
        }
        if let dict = object as? [String: Any] {
            if let error = dict["error"] { return errorMessage(error) }
            if let message = dict["message"] as? String { return message }
        }
        return nil
    }
}
