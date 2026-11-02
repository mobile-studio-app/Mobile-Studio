import Foundation
import os
import llama

/// One turn of a chat: "system", "user" or "assistant".
struct ChatMessage {
    let role: String
    let content: String
}

/// The Chat panel's conversations and its agent's subagents, with Apple Intelligence or a model
/// downloaded in Settings → Advanced. Everything runs on the device; nothing is sent anywhere.
/// Requests have ids, so several can run at once (subagents): Apple Intelligence sessions run side
/// by side, and each local model is loaded once with its requests taking turns.
final class AIChatService {
    static let shared = AIChatService()

    /// Loaded local models, by catalog id.
    private var engines: [String: LlamaChatEngine] = [:]
    private var cancels: [String: CompletionCancel] = [:]
    private var appleTasks: [String: Task<Void, Never>] = [:]
    /// A reply is being written.
    var isBusy: Bool { !cancels.isEmpty || !appleTasks.isEmpty }
    /// A local chat model is loaded (or about to be).
    var hasEngine: Bool { !engines.isEmpty }

    struct Option {
        let choice: AIModelChoice
        let name: String
        let detail: String
        let ready: Bool
        /// The context sizes it can have, each with its estimated memory and whether that fits.
        let contexts: [ContextSize]
        /// A suggested model that isn't downloaded yet: picking it opens Settings → AI to get it.
        var suggested = false
    }

    struct ContextSize {
        let tokens: Int
        let bytes: Int64
        let fits: Bool
    }

    /// Apple Intelligence's context window.
    static let appleContextSize = 4096
    static let contextSizes = [2048, 4096, 8192, 16384, 32768, 65536, 131072]

    /// A context's memory: the model, its KV cache at 8 bits (about 53% of the 16-bit size, with
    /// the scales) and room for the computation.
    static func memory(of model: LocalModel, context: Int) -> Int64 {
        model.bytes + Int64(Double(model.kvBytesPerToken) * Double(context) * 0.53) + 300_000_000
    }

    /// Memory the app can still use, plus what loaded chat models already take (they'd be replaced).
    private var memoryForChat: Int64 {
        let free = Int64(os_proc_available_memory())
        let loaded = engines.values.reduce(Int64(0)) { $0 + Self.memory(of: $1.model, context: $1.contextSize) }
        return free + loaded
    }

    /// The sizes a model offers: up to its trained length, each marked whether it fits now.
    func contexts(for model: LocalModel) -> [ContextSize] {
        let budget = memoryForChat
        return Self.contextSizes.filter { $0 <= model.trainedContext }.map { size in
            let bytes = Self.memory(of: model, context: size)
            return ContextSize(tokens: size, bytes: bytes, fits: Double(bytes) < Double(budget) * 0.9)
        }
    }

    /// The context a request gets: the setting, but no more than the model was trained for or
    /// than fits in memory (at least 2K).
    func effectiveContext(for model: LocalModel, wanted: Int) -> Int {
        let usable = contexts(for: model).filter { $0.fits }.map(\.tokens)
        return min(wanted, usable.max() ?? 2048, model.trainedContext)
    }

    /// The models the Chat panel offers: Apple Intelligence, the downloaded chat models, and the
    /// downloaded code models (which answer less well, but can).
    var options: [Option] {
        let reason = AppleIntelligenceEngine.unavailableReason
        var list = [Option(choice: .appleIntelligence, name: "Apple Intelligence", detail: reason ?? "Built into iOS",
                           ready: reason == nil, contexts: [ContextSize(tokens: Self.appleContextSize, bytes: 0, fits: true)])]
        for model in AIModelCatalog.all where model.isDownloaded && (model.chats || model.completes) {
            let detail = model.isSupported ? (model.chats ? model.detail : "\(model.detail) · a code model, chats less well") : model.requirementText
            list.append(Option(choice: model.choice, name: model.chats ? model.name : "\(model.name) (\(model.detail))", detail: detail,
                               ready: model.isSupported, contexts: contexts(for: model)))
        }
        for model in AIModelCatalog.chatModels where !model.isDownloaded && model.isSupported {
            list.append(Option(choice: model.choice, name: model.name,
                               detail: "\(AIModelCatalog.suggestion(for: model) ?? model.detail) · \(model.sizeText)",
                               ready: false, contexts: [], suggested: true))
        }
        return list
    }

    /// Stops one request, or all of them.
    func cancel(_ id: String? = nil) {
        let ids = id.map { [$0] } ?? Array(Set(cancels.keys).union(appleTasks.keys))
        for id in ids {
            cancels.removeValue(forKey: id)?.cancel()
            appleTasks.removeValue(forKey: id)?.cancel()
        }
    }

    /// Frees the chat models (memory warning, a game, or code suggestions needing the memory).
    func unload() {
        cancel()
        engines = [:]
    }

    /// Frees the chat models unless they're answering: AI Suggestions are about to load theirs.
    func releaseIdleEngine() {
        if !isBusy { engines = [:] }
    }

    /// Answers `messages` (the last is the user's) with `choice` (the Chat model when nil). `onText`
    /// gets the answer so far; both callbacks run on the main queue. Stopping keeps what was written.
    /// `contextSize`: the tokens wanted (Chat's or the subagents' setting); the model gets as many as fit.
    func respond(id: String, choice: AIModelChoice? = nil, contextSize: Int? = nil, _ messages: [ChatMessage], maxTokens: Int = 1536,
                 onText: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        cancel(id)
        let choice = choice ?? AppSettings.shared.chatModel
        if choice == .appleIntelligence {
            if let reason = AppleIntelligenceEngine.unavailableReason { return completion(.failure(Self.error(reason))) }
            appleTasks[id] = Task { @MainActor [weak self] in
                do {
                    let text = try await AppleIntelligenceEngine.chat(messages)
                    self?.appleTasks[id] = nil
                    completion(.success(text))
                } catch {
                    self?.appleTasks[id] = nil
                    completion(Task.isCancelled ? .success("") : .failure(error))
                }
            }
            return
        }
        guard let model = AIModelCatalog.model(for: choice), model.chats || model.completes, model.isDownloaded else {
            return completion(.failure(Self.error("Pick a chat model in the menu above. Download one in Settings → Advanced → AI Models.")))
        }
        guard model.isSupported else { return completion(.failure(Self.error("\(model.name): \(model.requirementText)"))) }
        // The suggestions model makes way while chatting.
        AICompletionService.shared.unload()
        // One engine per model: a smaller request uses a bigger loaded context; a bigger one reloads it.
        let size = effectiveContext(for: model, wanted: contextSize ?? AppSettings.shared.chatContextSize)
        if (engines[model.id]?.contextSize ?? 0) < size {
            engines[model.id] = LlamaChatEngine(model: model, contextSize: size)
        }
        guard let engine = engines[model.id] else { return }
        let cancel = CompletionCancel()
        cancels[id] = cancel
        engine.respond(messages, maxTokens: maxTokens, cancel: cancel, onText: { text in
            DispatchQueue.main.async { if !cancel.isCancelled { onText(text) } }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                if self?.cancels[id] === cancel { self?.cancels[id] = nil }
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
    /// Tokens the model reads at once (Chat's context size setting).
    let contextSize: Int

    private let queue = DispatchQueue(label: "app.mobilestudio.ai.chat", qos: .userInitiated)
    private var llamaModel: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var template: String?
    private var cached: [llama_token] = []

    init(model: LocalModel, contextSize: Int) {
        self.model = model
        self.contextSize = contextSize
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
        // No more than the model was trained for. The KV cache is kept at 8 bits, half the memory of
        // 16, which needs flash attention for the V half.
        let trained = Int(llama_model_n_ctx_train(loaded))
        contextParams.n_ctx = UInt32(max(1024, trained > 0 ? min(contextSize, trained) : contextSize))
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        contextParams.type_k = GGML_TYPE_Q8_0
        contextParams.type_v = GGML_TYPE_Q8_0
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
