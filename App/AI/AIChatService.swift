import Foundation
import os
import llama

/// One turn of a chat: "system", "user" or "assistant". `keep`: never dropped to make room (the
/// question being worked on, a summary of the conversation).
struct ChatMessage {
    let role: String
    let content: String
    var keep = false
}

/// An answer, with how much of the context its prompt took and how many old turns had to be left
/// out to fit (so Chat compacts before more are).
struct ChatReply {
    let text: String
    var promptTokens: Int? = nil
    var dropped = 0
}

/// The Chat panel's conversations and its agent's subagents, with Apple Intelligence or a model
/// of a tier (AITier), which run on the device; or a cloud model the user set up
/// with their own key (CloudChat), the one case where the conversation leaves the device.
/// Requests have ids, so several can run at once (subagents): Apple Intelligence and cloud requests
/// run side by side, and each local model is loaded once with its requests taking turns.
final class AIChatService {
    static let shared = AIChatService()

    /// Loaded local models, by catalog id.
    private var engines: [String: LlamaChatEngine] = [:]
    private var cancels: [String: CompletionCancel] = [:]
    /// Apple Intelligence and cloud requests.
    private var tasks: [String: Task<Void, Never>] = [:]
    /// A reply is being written.
    var isBusy: Bool { !cancels.isEmpty || !tasks.isEmpty }
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
        /// A cloud model: the conversation is sent to its provider.
        var cloud = false
        /// Can be the Chat agent (tools, editing); others only answer questions.
        var agent = false
        /// Can be a subagent, which only reads and searches: agents, and smaller models such as
        /// Apple Intelligence.
        var subagent = false
        var reasoning: LocalModel.Reasoning = .none
        /// Its tier's name ("Smart"); nil for a cloud model.
        var tier: String? = nil
    }

    struct ContextSize {
        let tokens: Int
        let bytes: Int64
        let fits: Bool
    }

    /// Apple Intelligence's context window.
    static let appleContextSize = 4096
    static let contextSizes = [2048, 4096, 8192, 16384, 32768, 65536, 131072]

    /// A context's memory: the model, its KV cache (8 bits: about 53% of the 16-bit size with the
    /// scales; "4 bits": K stays at 8 and V goes to 4, about 40%) and room for the computation.
    static func memory(of model: LocalModel, context: Int, kvBits: Int = AppSettings.shared.chatKVBits) -> Int64 {
        let share = kvBits == 4 ? 0.405 : 0.53
        return model.bytes + Int64(model.kvBytes(context: context) * share) + 300_000_000
    }

    /// What a chat model can use (for the Chat panel's context sizes to say why one won't fit).
    var availableMemory: Int64 { memoryForChat }

    /// Memory the app can still use, plus what loaded chat models already take (they'd be replaced)
    /// and the suggestion models (they're unloaded while a chat answers).
    private var memoryForChat: Int64 {
        let free = Int64(os_proc_available_memory())
        let loaded = engines.values.reduce(Int64(0)) { $0 + Self.memory(of: $1.model, context: $1.contextSize, kvBits: $1.kvBits) }
        return free + loaded + AICompletionService.shared.loadedMemory
    }

    /// The sizes a model offers: up to its longest (with YaRN, past its trained length), each
    /// marked whether it fits now.
    func contexts(for model: LocalModel) -> [ContextSize] {
        let budget = memoryForChat
        return Self.contextSizes.filter { $0 <= model.maxContext }.map { size in
            let bytes = Self.memory(of: model, context: size)
            return ContextSize(tokens: size, bytes: bytes, fits: Double(bytes) < Double(budget) * 0.9)
        }
    }

    /// The context a request gets: the setting, but no more than the model supports or than fits
    /// in memory (at least 2K).
    func effectiveContext(for model: LocalModel, wanted: Int) -> Int {
        let usable = contexts(for: model).filter { $0.fits }.map(\.tokens)
        return min(wanted, usable.max() ?? 2048, model.maxContext)
    }

    /// The models the Chat panel offers: the four tiers (one not downloaded yet is "suggested":
    /// picking it opens Settings → AI to get it; one this device can't run isn't ready), then cloud
    /// models the user set up.
    var options: [Option] {
        var list: [Option] = []
        for tier in AITier.allCases {
            guard let model = AIModelCatalog.model(for: tier.chatChoice) else {
                let reason = AppleIntelligenceEngine.unavailableReason
                list.append(Option(choice: .appleIntelligence, name: tier.name, detail: reason ?? "Apple Intelligence · built into iOS",
                                   ready: reason == nil, contexts: [ContextSize(tokens: Self.appleContextSize, bytes: 0, fits: true)],
                                   subagent: reason == nil, tier: tier.name))
                continue
            }
            let detail = !model.isSupported ? "\(model.name) · \(model.requirementText)"
                : model.isDownloaded ? model.name : "\(model.name) · \(model.sizeText) download"
            list.append(Option(choice: model.choice, name: tier.name, detail: detail, ready: model.isSupported && model.isDownloaded,
                               contexts: model.isDownloaded ? contexts(for: model) : [], suggested: !model.isDownloaded && model.isSupported,
                               agent: model.agent, subagent: model.agent || model.subagent, reasoning: model.reasoning, tier: tier.name))
        }
        for provider in CloudProvider.allCases where provider.isConfigured {
            list.append(Option(choice: provider.choice, name: provider.displayName, detail: "Cloud · sends your code to \(provider.name)",
                               ready: true, contexts: [ContextSize(tokens: provider.contextSize, bytes: 0, fits: true)], cloud: true,
                               agent: true, subagent: true, reasoning: .optional))
        }
        return list
    }

    /// Stops one request, or all of them.
    func cancel(_ id: String? = nil) {
        let ids = id.map { [$0] } ?? Array(Set(cancels.keys).union(tasks.keys))
        for id in ids {
            cancels.removeValue(forKey: id)?.cancel()
            tasks.removeValue(forKey: id)?.cancel()
        }
    }

    /// Frees the chat models (memory warning, a game, or code suggestions needing the memory).
    /// `keepingState`: what each had read goes to the context cache first, so coming back doesn't
    /// mean reading the conversation again (not on a memory warning, when the memory is needed now).
    func unload(keepingState: Bool = false) {
        cancel()
        if keepingState { saveStates() }
        engines = [:]
    }

    /// Frees the chat models unless they're answering: AI Suggestions are about to load theirs.
    func releaseIdleEngine() {
        guard !isBusy else { return }
        saveStates()
        engines = [:]
    }

    /// What each loaded model has read goes to the context cache (the app is going into the
    /// background, where iOS may close it). `done` runs on the main queue once it's written.
    func saveStates(then done: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for engine in engines.values {
            group.enter()
            engine.saveState { group.leave() }
        }
        if let done { group.notify(queue: .main, execute: done) }
    }

    /// Answers `messages` (the last is the user's) with `choice` (the Chat model when nil). `onText`
    /// gets the answer so far; both callbacks run on the main queue. Stopping keeps what was written.
    /// `contextSize`: the tokens wanted (Chat's or the subagents' setting); the model gets as many as fit.
    /// `thinking`: Think is on (a reasoning model samples as its makers suggest for that).
    /// `stop`: the answer ends before any of these (where the agent's model starts writing a tool's
    /// results itself, which come from the app).
    func respond(id: String, choice: AIModelChoice? = nil, contextSize: Int? = nil, _ messages: [ChatMessage], maxTokens: Int = 1536,
                 thinking: Bool = false, stop: [String] = [], onText: @escaping (String) -> Void,
                 completion: @escaping (Result<ChatReply, Error>) -> Void) {
        cancel(id)
        let choice = choice ?? AppSettings.shared.chatModel
        if let provider = CloudProvider.from(choice) {
            tasks[id] = Task { @MainActor [weak self] in
                do {
                    let text = try await CloudChat.respond(provider, messages: messages, maxTokens: maxTokens, stop: stop) { text in
                        DispatchQueue.main.async { if self?.tasks[id] != nil { onText(text) } }
                    }
                    self?.tasks[id] = nil
                    completion(.success(ChatReply(text: text)))
                } catch {
                    self?.tasks[id] = nil
                    completion(Task.isCancelled || error is CancellationError ? .success(ChatReply(text: "")) : .failure(error))
                }
            }
            return
        }
        if choice == .appleIntelligence {
            if let reason = AppleIntelligenceEngine.unavailableReason { return completion(.failure(Self.error(reason))) }
            tasks[id] = Task { @MainActor [weak self] in
                do {
                    let text = try await AppleIntelligenceEngine.chat(messages)
                    self?.tasks[id] = nil
                    completion(.success(ChatReply(text: text)))
                } catch {
                    self?.tasks[id] = nil
                    completion(Task.isCancelled ? .success(ChatReply(text: "")) : .failure(error))
                }
            }
            return
        }
        guard let model = AIModelCatalog.model(for: choice), model.chats || model.completes else {
            return completion(.failure(Self.error("Pick Nano, Light, Standard or Smart in the menu above.")))
        }
        guard model.isDownloaded else {
            let tier = model.tier.map { "\($0.name) (\(model.name))" } ?? model.name
            return completion(.failure(Self.error("\(tier) isn't downloaded yet: get it in Settings → AI, or pick another tier.")))
        }
        guard model.isSupported else { return completion(.failure(Self.error("\(model.name): \(model.requirementText)"))) }
        // Loading a model that doesn't fit gets the app closed by iOS: say so instead.
        let sizes = contexts(for: model)
        guard sizes.contains(where: \.fits) else {
            let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1e9) }
            return completion(.failure(Self.error("\(model.name) needs about \(gb(sizes.first?.bytes ?? model.bytes)), but iOS lets Mobile Studio use "
                + "\(gb(Int64(Double(memoryForChat) * 0.9))) right now. Pick a smaller model, or close other apps and try again.")))
        }
        // The suggestions model makes way while chatting.
        AICompletionService.shared.unload()
        // One engine per model: a smaller request uses a bigger loaded context; a bigger one (or a
        // new cache precision) reloads it.
        let size = effectiveContext(for: model, wanted: contextSize ?? AppSettings.shared.chatContextSize)
        let bits = AppSettings.shared.chatKVBits
        let draft = fasterAnswersDraft(for: model, context: size)
        if (engines[model.id]?.contextSize ?? 0) < size || engines[model.id]?.kvBits != bits || engines[model.id]?.draftModel?.id != draft?.id {
            engines[model.id]?.saveState()
            engines[model.id] = nil
            engines[model.id] = LlamaChatEngine(model: model, contextSize: size, kvBits: bits, draft: draft)
        }
        guard let engine = engines[model.id] else { return }
        let cancel = CompletionCancel()
        cancels[id] = cancel
        engine.respond(messages, maxTokens: maxTokens, thinking: thinking, stop: stop, cancel: cancel, onText: { text in
            DispatchQueue.main.async { if !cancel.isCancelled { onText(text) } }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                if self?.cancels[id] === cancel { self?.cancels[id] = nil }
                completion(result)
            }
        })
    }

    /// Faster answers' draft model for `model`: when the setting is on, the model has one, it's
    /// downloaded, and both fit in memory with room for the recurrent states kept to take back
    /// wrong guesses (about 300 MB, generously).
    func fasterAnswersDraft(for model: LocalModel, context: Int) -> LocalModel? {
        guard AppSettings.shared.chatFasterAnswers, let id = model.draft, let choice = AIModelChoice(rawValue: id),
              let draft = AIModelCatalog.model(for: choice), draft.isDownloaded, draft.isSupported else { return nil }
        let needed = Self.memory(of: model, context: context) + Self.memory(of: draft, context: context) + 300_000_000
        return Double(needed) < Double(memoryForChat) * 0.9 ? draft : nil
    }

    /// Faster answers for the Chat panel: "off", "unavailable" (the model has no draft), "download"
    /// (on, the draft not downloaded yet), "downloading", "wontFit" or "on".
    func fasterAnswersState(for choice: AIModelChoice) -> String {
        guard let model = AIModelCatalog.model(for: choice), let id = model.draft, let draftChoice = AIModelChoice(rawValue: id),
              let draft = AIModelCatalog.model(for: draftChoice) else { return "unavailable" }
        guard AppSettings.shared.chatFasterAnswers else { return "off" }
        switch ModelDownloadManager.shared.state(for: draft) {
        case .downloading, .verifying: return "downloading"
        case .downloaded: break
        default: return "download"
        }
        let context = effectiveContext(for: model, wanted: AppSettings.shared.chatContextSize)
        return fasterAnswersDraft(for: model, context: context) == nil ? "wontFit" : "on"
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
    /// The KV cache's precision: 8 or 4 bits.
    let kvBits: Int

    private let queue = DispatchQueue(label: "app.mobilestudio.ai.chat", qos: .userInitiated)
    private var llamaModel: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var template: String?
    private var cached: [llama_token] = []
    /// Models whose cache can't be cut back to a shorter prompt (Qwen3.5's fixed-size state, Gemma 4's
    /// sliding window): the state after the last prompt is kept, and a prompt that starts with that
    /// one goes on from it instead of being read again from the start.
    private var snapshots = false
    private var snapshot: [UInt8] = []
    private var snapshotTokens: [llama_token] = []
    /// Where this model's states go in the context cache: they only load into the same model,
    /// context size and cache precision.
    private var stateKey: String {
        "\(model.id)-\(context.map { llama_n_ctx($0) } ?? UInt32(contextSize))-\(kvBits)" + (draftModel != nil ? "-rs\(Self.draftLength)" : "")
    }

    /// Faster answers (speculative decoding): a small model with the same vocabulary guesses up to
    /// `draftLength` tokens ahead, and this one reads them all in one pass, keeping its own token at
    /// each place for as long as the guesses agree (so the answer is the one it would have written).
    /// Both caches drop what was guessed wrong; a hybrid model (Qwen3.5) keeps that many recurrent
    /// states to make that possible (n_rs_seq).
    let draftModel: LocalModel?
    static let draftLength = 4
    private var draftLlama: OpaquePointer?
    private var draftContext: OpaquePointer?
    /// What the draft's cache holds.
    private var draftTokens: [llama_token] = []

    init(model: LocalModel, contextSize: Int, kvBits: Int = 8, draft: LocalModel? = nil) {
        self.model = model
        self.contextSize = contextSize
        self.kvBits = kvBits
        self.draftModel = draft
    }

    deinit {
        if let draftContext { llama_free(draftContext) }
        if let draftLlama { llama_model_free(draftLlama) }
        if let context { llama_free(context) }
        if let llamaModel { llama_model_free(llamaModel) }
    }

    /// The last conversation's state goes to the context cache (when it's long enough to be worth
    /// it), after any answer being written. The engine stays alive until it's handed over.
    func saveState(then done: (() -> Void)? = nil) {
        queue.async {
            self.saveSnapshot()
            if let done { ContextCache.shared.afterWrites(done) }
        }
    }

    /// On `queue`.
    private func saveSnapshot() {
        guard snapshots, !snapshot.isEmpty else { return }
        ContextCache.shared.saveState(stateKey, tokens: snapshotTokens, data: snapshot)
    }

    func respond(_ messages: [ChatMessage], maxTokens: Int, thinking: Bool = false, stop: [String] = [], cancel: CompletionCancel,
                 onText: @escaping (String) -> Void, completion: @escaping (Result<ChatReply, Error>) -> Void) {
        queue.async {
            completion(Result { try self.generate(messages, maxTokens: maxTokens, thinking: thinking, stop: stop, cancel: cancel, onText: onText) })
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
        // No more than the model was trained for, or past that with YaRN where its makers support
        // it (YaRN: the RoPE stretched by the ratio, only when it's needed, since it costs a little
        // quality on short texts). The KV cache is kept at 8 bits, half the memory of 16, or V at 4;
        // either needs flash attention for the V half. Sliding-window layers (Gemma 4) keep only
        // their window, not the whole context.
        let trained = Int(llama_model_n_ctx_train(loaded))
        let longest = max(trained, model.yarnContext ?? 0)
        let n = max(1024, longest > 0 ? min(contextSize, longest) : contextSize)
        contextParams.n_ctx = UInt32(n)
        if trained > 0, n > trained, model.yarnContext != nil {
            contextParams.rope_scaling_type = LLAMA_ROPE_SCALING_TYPE_YARN
            contextParams.rope_freq_scale = Float(trained) / Float(n)
            contextParams.yarn_orig_ctx = UInt32(trained)
        }
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        // K stays at 8 bits either way: at 4, models whose keys have large values (Qwen's) lose the
        // thread and write nonsense. V takes 4 bits well.
        contextParams.type_k = GGML_TYPE_Q8_0
        contextParams.type_v = kvBits == 4 ? GGML_TYPE_Q4_0 : GGML_TYPE_Q8_0
        contextParams.swa_full = false
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        // Faster answers: room to take back wrong guesses from a recurrent model's state.
        let recurrent = llama_model_is_recurrent(loaded) || llama_model_is_hybrid(loaded)
        if draftModel != nil && recurrent { contextParams.n_rs_seq = UInt32(Self.draftLength) }
        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw Self.error("Not enough memory to run \(model.name).")
        }
        llamaModel = loaded
        context = ctx
        vocab = llama_model_get_vocab(loaded)
        template = llama_model_chat_template(loaded, nil).map { String(cString: $0) }
        cached = []
        snapshots = recurrent || model.slidingWindow > 0
        snapshot = []
        snapshotTokens = []
        loadDraft(contextParams)
    }

    /// The draft model, with a context like this one's. Without it (it didn't load), answers come
    /// the usual way.
    private func loadDraft(_ params: llama_context_params) {
        guard let draft = draftModel, draft.isDownloaded else { return }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(draft.localURL.path, modelParams) else { return }
        var contextParams = params
        contextParams.n_rs_seq = llama_model_is_recurrent(loaded) || llama_model_is_hybrid(loaded) ? UInt32(Self.draftLength) : 0
        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            return
        }
        draftLlama = loaded
        draftContext = ctx
        draftTokens = []
    }

    /// The draft reads what this model has (`tokens`), going on from what it read before where it
    /// can. False when it couldn't.
    private func syncDraft(_ tokens: [llama_token]) -> Bool {
        guard let dctx = draftContext else { return false }
        let memory = llama_get_memory(dctx)
        var common = 0
        while common < draftTokens.count, common < tokens.count, draftTokens[common] == tokens[common] { common += 1 }
        if common < draftTokens.count {
            if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
                llama_memory_clear(memory, true)
                common = 0
            }
            draftTokens.removeSubrange(common...)
        }
        var index = common
        while index < tokens.count {
            let count = min(512, tokens.count - index)
            var chunk = Array(tokens[index..<(index + count)])
            let rc = chunk.withUnsafeMutableBufferPointer { llama_decode(dctx, llama_batch_get_one($0.baseAddress, Int32(count))) }
            guard rc == 0 else {
                llama_memory_clear(memory, true)
                draftTokens = []
                return false
            }
            draftTokens += chunk
            index += count
        }
        return true
    }

    // MARK: - Prompt

    /// The conversation in the model's chat format, ending where the assistant's answer starts.
    private func format(_ messages: [ChatMessage], thinking: Bool) -> String {
        switch model.format {
        case .gemma4: return Self.gemma4(messages, thinking: thinking)
        case .lfm3: return Self.lfm3(messages, thinking: thinking)
        case .template: return applyTemplate(messages)
        case .thinkPrefill:
            // Earlier answers start as this one does (an empty thought unless they kept theirs), so the
            // prompt goes on from the last one's tokens.
            let turns = messages.map { m in
                m.role == "assistant" && !m.content.hasPrefix("<think>") ? ChatMessage(role: m.role, content: "<think>\n\n</think>\n\n" + m.content, keep: m.keep) : m
            }
            return applyTemplate(turns) + (thinking ? "<think>\n" : "<think>\n\n</think>\n\n")
        }
    }

    /// Gemma 4: <|turn>role … <turn|>, the system turn first (opening with <|think|> to reason), and
    /// earlier thoughts as its thought channel.
    private static func gemma4(_ messages: [ChatMessage], thinking: Bool) -> String {
        var out = ""
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        if thinking || !system.isEmpty { out += "<|turn>system\n" + (thinking ? "<|think|>\n" : "") + system + "<turn|>\n" }
        for m in messages where m.role != "system" {
            var content = m.content
            if m.role == "assistant" {
                content = content.replacingOccurrences(of: "<think>\n", with: "<|channel>thought\n").replacingOccurrences(of: "<think>", with: "<|channel>thought\n")
                    .replacingOccurrences(of: "\n</think>", with: "<channel|>").replacingOccurrences(of: "</think>", with: "<channel|>")
            }
            out += "<|turn>\(m.role == "assistant" ? "model" : m.role)\n\(content)<turn|>\n"
        }
        return out + "<|turn>model\n"
    }

    /// LFM3: ChatML, with earlier answers starting with their thought (an empty one unless they kept
    /// theirs) as its template writes them, and this answer opened to reason or not.
    private static func lfm3(_ messages: [ChatMessage], thinking: Bool) -> String {
        var out = ""
        for m in messages {
            var content = m.content
            if m.role == "assistant" && !content.hasPrefix("<think>") { content = "<think></think>" + content }
            out += "<|im_start|>\(m.role)\n\(content)<|im_end|>\n"
        }
        return out + "<|im_start|>assistant\n" + (thinking ? "<think>" : "<think></think>")
    }

    private func applyTemplate(_ messages: [ChatMessage]) -> String {
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

    private func generate(_ messages: [ChatMessage], maxTokens: Int, thinking: Bool, stop: [String], cancel: CompletionCancel,
                          onText: (String) -> Void) throws -> ChatReply {
        try loadIfNeeded()
        guard let ctx = context, let vocab else { throw Self.error("\(model.name) isn't loaded.") }
        if cancel.isCancelled { return ChatReply(text: "") }

        // Fit the conversation: drop the oldest turns until it fits, but never the instructions or
        // a turn marked keep (the question being worked on), so the model doesn't lose its task.
        let budget = Int(llama_n_ctx(ctx)) - maxTokens - 8
        var turns = messages
        var prompt = tokenize(format(turns, thinking: thinking))
        var dropped = 0
        while prompt.count > budget, let oldest = turns.indices.dropLast().first(where: { turns[$0].role != "system" && !turns[$0].keep }) {
            turns.remove(at: oldest)
            dropped += 1
            prompt = tokenize(format(turns, thinking: thinking))
        }
        if prompt.count > budget { prompt = Array(prompt.suffix(budget)) }
        let promptTokens = prompt.count

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
            if snapshots {
                // The cache can't be cut back: go on from the last prompt's state if this prompt starts
                // with it, otherwise from the start.
                llama_memory_clear(memory, true)
                cached = []
                common = 0
                if !snapshot.isEmpty, snapshotTokens.count < prompt.count, Array(prompt.prefix(snapshotTokens.count)) == snapshotTokens,
                   snapshot.withUnsafeBufferPointer({ llama_state_seq_set_data(ctx, $0.baseAddress, $0.count, 0) }) > 0 {
                    cached = snapshotTokens
                    common = snapshotTokens.count
                } else {
                    llama_memory_clear(memory, true)
                    // Another conversation (a subagent, another chat): the one the model had goes to
                    // the context cache, to go on from when it comes back.
                    saveSnapshot()
                }
            } else {
                if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
                    llama_memory_clear(memory, true)
                    common = 0
                }
                cached.removeSubrange(common...)
            }
        }
        // Nothing to go on from (a model just loaded, or a conversation it doesn't have): what it
        // read for this conversation before, from the context cache, if that's there.
        if snapshots, common == 0, prompt.count > ContextCache.minimumStateTokens,
           let saved = ContextCache.shared.loadState(stateKey, prompt: prompt) {
            if saved.data.withUnsafeBufferPointer({ llama_state_seq_set_data(ctx, $0.baseAddress, $0.count, 0) }) > 0 {
                cached = saved.tokens
                common = saved.tokens.count
            } else {
                llama_memory_clear(memory, true)
                cached = []
            }
        }
        var index = common
        while index < prompt.count {
            let count = min(512, prompt.count - index)
            var chunk = Array(prompt[index..<(index + count)])
            let rc = chunk.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32(count))) }
            guard rc == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                if cancel.isCancelled { return ChatReply(text: "") }
                throw Self.error("\(model.name) failed (\(rc)).")
            }
            cached += chunk
            index += count
        }
        // The state after this prompt, for the next one to go on from (if it isn't too big to keep).
        if snapshots {
            let size = llama_state_seq_get_size(ctx, 0)
            if size > 0, Int64(size) < Int64(os_proc_available_memory()) / 4 {
                var data = [UInt8](repeating: 0, count: size)
                let written = data.withUnsafeMutableBufferPointer { llama_state_seq_get_data(ctx, $0.baseAddress, size, 0) }
                snapshot = written > 0 ? Array(data.prefix(written)) : []
                snapshotTokens = written > 0 ? prompt : []
            } else {
                snapshot = []
                snapshotTokens = []
            }
        }

        // Reasoning models sample as their makers suggest (Qwen3: top-k 20; top-p 0.95 and
        // temperature 0.6 when thinking, 0.8 and 0.7 when not), with a presence penalty against
        // the endless repeats they can fall into; others as before.
        let gemma = model.format == .gemma4
        let reasons = model.reasoning != .none && !gemma
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        if model.sampling == .lfm {
            // LFM3, as its makers suggest for chat, tools and code: temperature 0.1, top-k 50, and a
            // repetition penalty of 1.1 over the last 256 tokens.
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 256, 1.1, 0, 0))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(50))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.1))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max - 1)))
        } else if gemma {
            // Gemma 4: temperature 1, top-k 64, top-p 0.95.
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(64))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(1.0))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max - 1)))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(reasons ? 20 : 40))
            if reasons {
                llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 256, 1.0, 0, 1.0))
            }
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(reasons && !thinking ? 0.8 : 0.95, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(reasons ? 0 : 0.05, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(reasons && thinking ? 0.6 : 0.7))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max - 1)))
        }
        defer { llama_sampler_free(sampler) }

        // Faster answers: the draft model guesses ahead, when it's loaded and has read the prompt.
        if draftContext != nil, syncDraft(prompt) {
            return try speculate(ctx: ctx, vocab: vocab, sampler: sampler, maxTokens: maxTokens, thinking: thinking, stop: stop,
                                 cancel: cancel, onText: onText, promptTokens: promptTokens, dropped: dropped)
        }

        var output: [UInt8] = []
        var stopped: String?
        for _ in 0..<maxTokens {
            if cancel.isCancelled { break }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token)
            let text = shown(output)
            if let end = stopText(text, at: stop, thinking: thinking) {
                stopped = end
                break
            }
            onText(text)
            let rc = llama_decode(ctx, llama_batch_get_one(&token, 1))
            guard rc == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                if output.isEmpty && !cancel.isCancelled { throw Self.error("\(model.name) failed while answering (\(rc)).") }
                break
            }
            cached.append(token)
        }
        return ChatReply(text: stopped ?? shown(output), promptTokens: promptTokens, dropped: dropped)
    }

    /// A stop text: the answer ends before it (the token isn't kept, so the next turn's prompt goes on
    /// from the answer as it's shown). Only the answer can end at one, not the thinking before it
    /// (which may mention them). The answer up to it, or nil.
    private func stopText(_ text: String, at stop: [String], thinking: Bool) -> String? {
        guard !stop.isEmpty else { return nil }
        let opensThinking = (thinking && model.format == .thinkPrefill) || text.contains("<think>")
        let answer: Substring? = text.range(of: "</think>", options: .backwards).map { text[$0.upperBound...] }
            ?? (opensThinking ? nil : text[...])
        guard let answer, let end = stop.first(where: { answer.suffix(96).contains($0) }),
              let at = answer.range(of: end, options: .backwards) else { return nil }
        return String(text[..<at.lowerBound])
    }

    /// The answer with the draft model guessing ahead (see `draftModel`). The prompt is read by both;
    /// `sampler` is this model's, so each token kept is the one it would have written itself.
    private func speculate(ctx: OpaquePointer, vocab: OpaquePointer, sampler: UnsafeMutablePointer<llama_sampler>, maxTokens: Int,
                           thinking: Bool, stop: [String], cancel: CompletionCancel, onText: (String) -> Void,
                           promptTokens: Int, dropped: Int) throws -> ChatReply {
        guard let dctx = draftContext else { throw Self.error("\(model.name)'s draft model isn't loaded.") }
        let memory = llama_get_memory(ctx)
        let draftMemory = llama_get_memory(dctx)
        let greedy = llama_sampler_init_greedy()
        defer { llama_sampler_free(greedy) }
        let k = Self.draftLength
        var batch = llama_batch_init(Int32(k + 1), 0, 1)
        defer { llama_batch_free(batch) }

        var output: [UInt8] = []
        var stoppedAt: String?
        var produced = 0
        var going = true
        // Adds a token to the answer: the answer so far to show, or nil when it ends there.
        let add = { (token: llama_token) -> String? in
            if llama_vocab_is_eog(vocab, token) || produced >= maxTokens { return nil }
            output += self.piece(token)
            produced += 1
            let text = self.shown(output)
            if let end = self.stopText(text, at: stop, thinking: thinking) {
                stoppedAt = end
                return nil
            }
            return text
        }

        // The first token, from the prompt (decoded by neither model yet).
        var last = llama_sampler_sample(sampler, ctx, -1)
        if let text = add(last) { onText(text) } else { going = false }
        while going && !cancel.isCancelled {
            // The draft catches up with what this model has read, then guesses on from `last`.
            if draftTokens.count < cached.count, !syncDraft(cached) { break }
            var guesses: [llama_token] = []
            var next = last
            for _ in 0..<k {
                var token = next
                guard llama_decode(dctx, llama_batch_get_one(&token, 1)) == 0 else { break }
                draftTokens.append(token)
                let guess = llama_sampler_sample(greedy, dctx, -1)
                if llama_vocab_is_eog(vocab, guess) { break }
                guesses.append(guess)
                next = guess
            }

            // This model reads `last` and the guesses in one pass, with logits at each.
            let start = Int32(cached.count)
            let reading = [last] + guesses
            batch.n_tokens = Int32(reading.count)
            for (i, token) in reading.enumerated() {
                batch.token[i] = token
                batch.pos[i] = start + Int32(i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = 1
            }
            let rc = llama_decode(ctx, batch)
            guard rc == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                if output.isEmpty && !cancel.isCancelled { throw Self.error("\(model.name) failed while answering (\(rc)).") }
                break
            }
            cached += reading

            // Its own token at each place, for as long as the guesses agree; then one more.
            var kept: [llama_token] = []
            var agreed = true
            for i in 0..<guesses.count {
                let token = llama_sampler_sample(sampler, ctx, Int32(i))
                kept.append(token)
                if token != guesses[i] || llama_vocab_is_eog(vocab, token) { agreed = false; break }
            }
            if agreed { kept.append(llama_sampler_sample(sampler, ctx, Int32(guesses.count))) }

            // What was guessed wrong goes from both caches (`last` and the agreed guesses stay).
            let end = start + Int32(kept.count)
            if Int(end) < cached.count {
                guard llama_memory_seq_rm(memory, 0, end, -1) else {
                    llama_memory_clear(memory, true)
                    cached = []
                    break
                }
                cached.removeSubrange(Int(end)...)
            }
            if draftTokens.count > Int(end) {
                if llama_memory_seq_rm(draftMemory, 0, end, -1) {
                    draftTokens.removeSubrange(Int(end)...)
                } else {
                    llama_memory_clear(draftMemory, true)
                    draftTokens = []
                }
            }
            for token in kept where going {
                if let text = add(token) { onText(text) } else { going = false }
            }
            last = kept[kept.count - 1]
        }
        return ChatReply(text: stoppedAt ?? shown(output), promptTokens: promptTokens, dropped: dropped)
    }

    /// The answer as Chat shows it: Gemma 4's thought channel as <think> … </think>, without its other markers.
    private func shown(_ bytes: [UInt8]) -> String {
        let text = Self.text(bytes)
        guard model.format == .gemma4 else { return text }
        return text.replacingOccurrences(of: "<|channel>thought\n", with: "<think>\n").replacingOccurrences(of: "<|channel>thought", with: "<think>")
            .replacingOccurrences(of: "<channel|>", with: "\n</think>\n").replacingOccurrences(of: "<turn|>", with: "")
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
        // Gemma 4's thought markers are special tokens: kept, to be shown as <think>.
        let special = model.format == .gemma4
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)
        }
        return buffer.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MobileStudioChat", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
