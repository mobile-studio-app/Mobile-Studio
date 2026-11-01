import Foundation
import llama

/// Set from any thread to stop a running completion; llama.cpp polls it between compute steps.
final class CompletionCancel {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Fill-in-the-middle completion with a local GGUF model. All work happens on `queue`.
///
/// The prompt is <fim_prefix>code before<fim_suffix>code after<fim_middle>. Requests made while
/// typing share most of their prompt with the previous one, so the KV cache keeps the shared
/// tokens and only the changed tail is evaluated again.
final class LlamaCompletionEngine {
    let model: LocalModel

    private let queue = DispatchQueue(label: "com.duocode.ai.llama", qos: .userInitiated)
    private var llamaModel: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var fim: (pre: llama_token, suf: llama_token, mid: llama_token) = (-1, -1, -1)
    private var stopTokens = Set<llama_token>()
    private var cached: [llama_token] = []   // tokens currently in the KV cache, in order

    static let backendReady: Void = {
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp is chatty; keep the console for the game
        llama_backend_init()
    }()

    init(model: LocalModel) {
        self.model = model
    }

    deinit {
        if let context { llama_free(context) }
        if let llamaModel { llama_model_free(llamaModel) }
    }

    /// Loads the model ahead of the first request so it doesn't pay the load time.
    func preload() {
        queue.async { try? self.loadIfNeeded() }
    }

    func complete(prefix: String, suffix: String, maxTokens: Int, maxLines: Int, cancel: CompletionCancel,
                  completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result = Result { try self.generate(prefix: prefix, suffix: suffix, maxTokens: maxTokens, maxLines: maxLines, cancel: cancel) }
            completion(result)
        }
    }

    // MARK: - Loading

    private func loadIfNeeded() throws {
        if context != nil { return }
        _ = Self.backendReady

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        var loaded = llama_model_load_from_file(model.localURL.path, modelParams)
        if loaded == nil {
            // Not enough GPU memory for every layer: fall back to the CPU.
            modelParams.n_gpu_layers = 0
            loaded = llama_model_load_from_file(model.localURL.path, modelParams)
        }
        guard let loaded else { throw Self.error("Couldn't load \(model.name). Try deleting and downloading it again.") }

        let threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw Self.error("Not enough memory to run \(model.name).")
        }

        let vocab = llama_model_get_vocab(loaded)
        fim = (llama_vocab_fim_pre(vocab), llama_vocab_fim_suf(vocab), llama_vocab_fim_mid(vocab))
        guard fim.pre >= 0, fim.suf >= 0, fim.mid >= 0 else {   // LLAMA_TOKEN_NULL is -1
            llama_free(ctx)
            llama_model_free(loaded)
            throw Self.error("\(model.name) doesn't support code completion.")
        }
        stopTokens = Set([llama_vocab_fim_pre(vocab), llama_vocab_fim_suf(vocab), llama_vocab_fim_mid(vocab),
                          llama_vocab_fim_pad(vocab), llama_vocab_fim_rep(vocab), llama_vocab_fim_sep(vocab)].filter { $0 >= 0 })

        llamaModel = loaded
        context = ctx
        self.vocab = vocab
        cached = []
    }

    // MARK: - Generation

    private func generate(prefix: String, suffix: String, maxTokens: Int, maxLines: Int, cancel: CompletionCancel) throws -> String {
        try loadIfNeeded()
        guard let ctx = context, let vocab else { throw Self.error("\(model.name) isn't loaded.") }
        if cancel.isCancelled { throw CancellationError() }

        // Fit the prompt in the context: keep the start of the code after the cursor and as much
        // of the code before it as fits, dropping the oldest lines first.
        let budget = Int(llama_n_ctx(ctx)) - maxTokens - 8
        let suffixTokens = Array(tokenize(suffix).prefix(256))
        var prefixTokens = tokenize(prefix)
        let room = budget - suffixTokens.count - 3
        if prefixTokens.count > room { prefixTokens = Array(prefixTokens.suffix(room)) }
        let prompt = [fim.pre] + prefixTokens + [fim.suf] + suffixTokens + [fim.mid]

        let box = Unmanaged.passRetained(cancel)
        defer { box.release() }
        llama_set_abort_callback(ctx, { data in
            guard let data else { return false }
            return Unmanaged<CompletionCancel>.fromOpaque(data).takeUnretainedValue().isCancelled
        }, box.toOpaque())

        // Reuse the cached tokens this prompt starts with. At least one token must be decoded to get logits.
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
            guard rc == 0 else { return try fail(rc, cancel: cancel) }
            cached += chunk
            index += count
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        var output: [UInt8] = []
        var lines = 0
        for _ in 0..<maxTokens {
            if cancel.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) || stopTokens.contains(token) { break }
            let bytes = piece(token)
            output += bytes
            lines += bytes.filter { $0 == 10 }.count
            if lines >= maxLines { break }
            guard llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0 else { break }
            cached.append(token)
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// A failed or aborted decode leaves the KV cache partly written, so start over next time.
    private func fail(_ rc: Int32, cancel: CompletionCancel) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        cached = []
        if cancel.isCancelled { throw CancellationError() }
        throw Self.error("\(model.name) failed (\(rc)).")
    }

    private func tokenize(_ text: String) -> [llama_token] {
        guard !text.isEmpty else { return [] }
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, false)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, false)
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
        NSError(domain: "DuoCodeAI", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
