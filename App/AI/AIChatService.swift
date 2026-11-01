import Foundation
import llama

/// One turn of a chat: "system", "user" or "assistant".
struct ChatMessage {
    let role: String
    let content: String
}

/// The Chat panel's conversations, with the model picked for Chat: Apple Intelligence or a chat
/// model downloaded in Settings → Advanced. Everything runs on the device; nothing is sent anywhere.
final class AIChatService {
    static let shared = AIChatService()

    private var engine: LlamaChatEngine?
    private var cancelToken: CompletionCancel?
    private var appleTask: Task<Void, Never>?
    /// A reply is being written.
    private(set) var isBusy = false
    /// A local chat model is loaded (or about to be).
    var hasEngine: Bool { engine != nil }

    struct Option {
        let choice: AIModelChoice
        let name: String
        let detail: String
        let ready: Bool
    }

    /// The models the Chat panel's menu offers: Apple Intelligence and the downloaded chat models.
    var options: [Option] {
        let reason = AppleIntelligenceEngine.unavailableReason
        var list = [Option(choice: .appleIntelligence, name: "Apple Intelligence", detail: reason ?? "Built into iOS", ready: reason == nil)]
        for model in AIModelCatalog.chatModels {
            list.append(Option(choice: model.choice, name: model.name,
                               detail: model.isSupported ? model.detail : model.requirementText, ready: model.isSupported))
        }
        return list
    }

    func cancel() {
        cancelToken?.cancel()
        cancelToken = nil
        appleTask?.cancel()
        appleTask = nil
    }

    /// Frees the chat model (memory warning, a game, or code suggestions needing the memory).
    func unload() {
        cancel()
        engine = nil
    }

    /// Frees the chat model unless it's answering: AI Suggestions are about to load theirs.
    func releaseIdleEngine() {
        if !isBusy { engine = nil }
    }

    /// Answers the conversation, whose last message is the user's. `onText` gets the answer so far as
    /// it's written; both callbacks run on the main queue. Stopping keeps what was written.
    func respond(_ messages: [ChatMessage], onText: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let choice = AppSettings.shared.chatModel
        if choice == .appleIntelligence {
            if let reason = AppleIntelligenceEngine.unavailableReason { return completion(.failure(Self.error(reason))) }
            isBusy = true
            appleTask = Task { @MainActor [weak self] in
                do {
                    let text = try await AppleIntelligenceEngine.chat(messages)
                    self?.isBusy = false
                    completion(.success(text))
                } catch {
                    self?.isBusy = false
                    completion(Task.isCancelled ? .success("") : .failure(error))
                }
            }
            return
        }
        guard let model = AIModelCatalog.model(for: choice), model.chats, model.isDownloaded else {
            return completion(.failure(Self.error("Pick a chat model in the menu above. Download one in Settings → Advanced → AI Models.")))
        }
        guard model.isSupported else { return completion(.failure(Self.error("\(model.name): \(model.requirementText)"))) }
        // One local model in memory at a time: the suggestions model is unloaded while chatting.
        AICompletionService.shared.unload()
        if engine?.model.id != model.id { engine = LlamaChatEngine(model: model) }
        guard let engine else { return }
        let cancel = CompletionCancel()
        cancelToken = cancel
        isBusy = true
        engine.respond(messages, maxTokens: 1536, cancel: cancel, onText: { text in
            DispatchQueue.main.async { if !cancel.isCancelled { onText(text) } }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion(result)
            }
        })
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "MobileStudioChat", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Chat with a local instruction model: the conversation is put in the model's own chat format
/// (its GGUF chat template) and the answer streams back token by token. All work happens on `queue`.
/// Each turn starts with the previous one's tokens, so the KV cache keeps them and only the new
/// turn is evaluated.
final class LlamaChatEngine {
    let model: LocalModel

    private let queue = DispatchQueue(label: "app.mobilestudio.ai.chat", qos: .userInitiated)
    private var llamaModel: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var template: String?
    private var cached: [llama_token] = []

    init(model: LocalModel) {
        self.model = model
    }

    deinit {
        if let context { llama_free(context) }
        if let llamaModel { llama_model_free(llamaModel) }
    }

    func respond(_ messages: [ChatMessage], maxTokens: Int, cancel: CompletionCancel,
                 onText: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            completion(Result { try self.generate(messages, maxTokens: maxTokens, cancel: cancel, onText: onText) })
        }
    }

    // MARK: - Loading

    private func loadIfNeeded() throws {
        if context != nil { return }
        _ = LlamaCompletionEngine.backendReady

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        var loaded = llama_model_load_from_file(model.localURL.path, modelParams)
        if loaded == nil {
            modelParams.n_gpu_layers = 0
            loaded = llama_model_load_from_file(model.localURL.path, modelParams)
        }
        guard let loaded else { throw Self.error("Couldn't load \(model.name). Try deleting and downloading it again.") }

        let threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw Self.error("Not enough memory to run \(model.name).")
        }
        llamaModel = loaded
        context = ctx
        vocab = llama_model_get_vocab(loaded)
        template = llama_model_chat_template(loaded, nil).map { String(cString: $0) }
        cached = []
    }

    // MARK: - Prompt

    /// The conversation in the model's chat format, ending where the assistant's answer starts.
    private func format(_ messages: [ChatMessage]) -> String {
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        var chat = messages.indices.map { llama_chat_message(role: UnsafePointer(roles[$0]), content: UnsafePointer(contents[$0])) }
        var buffer = [CChar](repeating: 0, count: messages.reduce(0) { $0 + $1.content.utf8.count } * 2 + 4096)
        func apply(_ name: String?) -> Int32 {
            // An unrecognised template falls back to ChatML, which most small models understand.
            let run = { (tmpl: UnsafePointer<CChar>?) -> Int32 in
                llama_chat_apply_template(tmpl, &chat, chat.count, true, &buffer, Int32(buffer.count))
            }
            guard let name else { return run(nil) }
            return name.withCString { run($0) }
        }
        var n = apply(template ?? "chatml")
        if n < 0 { n = apply("chatml") }
        if n > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(n) + 1)
            n = apply(template ?? "chatml")
            if n < 0 { n = apply("chatml") }
        }
        guard n > 0 else {
            // Last resort: plain ChatML by hand.
            return messages.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
        }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Generation

    private func generate(_ messages: [ChatMessage], maxTokens: Int, cancel: CompletionCancel, onText: (String) -> Void) throws -> String {
        try loadIfNeeded()
        guard let ctx = context, let vocab else { throw Self.error("\(model.name) isn't loaded.") }
        if cancel.isCancelled { return "" }

        // Fit the conversation: drop the oldest turns (keeping the instructions) until it fits.
        let budget = Int(llama_n_ctx(ctx)) - maxTokens - 8
        var turns = messages
        var prompt = tokenize(format(turns))
        while prompt.count > budget && turns.count > 2 {
            turns.remove(at: turns.first?.role == "system" ? 1 : 0)
            prompt = tokenize(format(turns))
        }
        if prompt.count > budget { prompt = Array(prompt.suffix(budget)) }

        let box = Unmanaged.passRetained(cancel)
        defer { box.release() }
        llama_set_abort_callback(ctx, { data in
            guard let data else { return false }
            return Unmanaged<CompletionCancel>.fromOpaque(data).takeUnretainedValue().isCancelled
        }, box.toOpaque())

        // Reuse the cached tokens this prompt starts with (the conversation so far).
        let memory = llama_get_memory(ctx)
        var common = 0
        while common < cached.count, common < prompt.count, cached[common] == prompt[common] { common += 1 }
        if common == prompt.count { common -= 1 }
        if common < cached.count {
            if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
                llama_memory_clear(memory, true)
                common = 0
            }
            cached.removeSubrange(common...)
        }
        var index = common
        while index < prompt.count {
            let count = min(512, prompt.count - index)
            var chunk = Array(prompt[index..<(index + count)])
            let rc = chunk.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32(count))) }
            guard rc == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                if cancel.isCancelled { return "" }
                throw Self.error("\(model.name) failed (\(rc)).")
            }
            cached += chunk
            index += count
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max - 1)))
        defer { llama_sampler_free(sampler) }

        var output: [UInt8] = []
        for _ in 0..<maxTokens {
            if cancel.isCancelled { break }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token)
            onText(Self.text(output))
            guard llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                break
            }
            cached.append(token)
        }
        return Self.text(output)
    }

    /// The answer so far; a character split across tokens shows once it's complete.
    private static func text(_ bytes: [UInt8]) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        while text.hasSuffix("\u{FFFD}") { text.removeLast() }
        return text
    }

    private func tokenize(_ text: String) -> [llama_token] {
        guard !text.isEmpty else { return [] }
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        // The chat format's markers (<|im_start|> and the like) are special tokens.
        var n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MobileStudioChat", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
