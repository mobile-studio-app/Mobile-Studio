import Foundation

/// A model that runs on the phone with llama.cpp. Downloaded on demand from Hugging Face (GGUF
/// files, the format Ollama and LM Studio run).
struct LocalModel {
    /// The setting's value: "fast" and "regular" for the two built in, the catalog id for the rest.
    let id: String
    let name: String
    let detail: String
    let fileName: String
    let url: URL
    let sha256: String
    let bytes: Int64
    /// Physical RAM the phone needs. 6 GB phones report about 5.7 GB, 8 GB phones about 7.5 GB.
    let minimumMemory: UInt64
    /// A base code model, trained for fill-in-the-middle: AI Suggestions and merge conflicts.
    var completes = false
    /// An instruction-tuned model: the Chat panel.
    var chats = false
    var license = ""
    /// The context length the model was trained for, in tokens: the most Chat offers.
    var trainedContext = 32768
    /// Its KV cache per token at 16-bit precision (2 × layers × KV heads × head size × 2 bytes),
    /// for estimating a context's memory. Chat stores the cache at 8 bits, about half this.
    var kvBytesPerToken = 65536
    /// The longest context with YaRN scaling, which the model's makers support past its trained
    /// length (Qwen's 128K); nil when it has none.
    var yarnContext: Int? = nil
    /// Sliding-window attention (Gemma 4): most layers only keep the last `slidingWindow` tokens,
    /// and `fullAttentionShare` of them the whole context.
    var slidingWindow = 0
    var fullAttentionShare = 1.0
    /// Good enough to be the Chat agent (tools, editing, running): small models loop or call
    /// tools wrongly, so they only answer questions.
    var agent = false
    /// Good enough to be a subagent, which only reads and searches (agents are too).
    var subagent = false
    var reasoning: Reasoning = .none
    /// How its prompts are written.
    var format: PromptFormat = .template
    /// How its answers are sampled.
    var sampling: Sampling = .standard

    enum PromptFormat {
        /// The model's own chat template (llama.cpp's built-in version of it).
        case template
        /// The template, with the start of the answer written for it: "<think>\n" to reason, or an
        /// empty thought to answer straight away, as Qwen3.5's and SmolLM3's templates do.
        case thinkPrefill
        /// Gemma 4's turns (<|turn>user … <turn|>), which llama.cpp's templates don't know.
        case gemma4
        /// LFM3's ChatML, which llama.cpp's templates don't know: answers start "<think>" to reason,
        /// or "<think></think>" not to, and earlier answers carry an empty thought.
        case lfm3
    }

    enum Sampling {
        /// By the format: Gemma's, Qwen's for reasoning models, otherwise a general mix.
        case standard
        /// LFM3's for chat, tools and code: temperature 0.1, top-k 50, repetition penalty 1.1.
        case lfm
    }

    enum Reasoning: String {
        /// No thinking: it answers straight away.
        case none
        /// Reasons first when Think is on (Qwen3.5, LFM3).
        case optional
        /// Always reasons (DeepSeek-R1).
        case always
    }

    /// The longest context it can have.
    var maxContext: Int { yarnContext ?? trainedContext }

    /// KV cache memory for `context` tokens at 16 bits: sliding-window layers stop at their window.
    func kvBytes(context: Int) -> Double {
        let tokens = slidingWindow > 0
            ? fullAttentionShare * Double(context) + (1 - fullAttentionShare) * Double(min(context, slidingWindow))
            : Double(context)
        return Double(kvBytesPerToken) * tokens
    }

    var choice: AIModelChoice { AIModelChoice(rawValue: id)! }
    var localURL: URL { AIModelCatalog.directory.appendingPathComponent(fileName) }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }
    var isSupported: Bool { ProcessInfo.processInfo.physicalMemory >= minimumMemory }
    /// The tier it's the model of.
    var tier: AITier? { AITier.of(choice) }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var requirementText: String {
        let gigabytes = minimumMemory > 9_000_000_000 ? 12 : minimumMemory > 6_000_000_000 ? 8 : minimumMemory > 4_000_000_000 ? 6 : 4
        return "Needs a device with \(gigabytes) GB of memory."
    }
    var uses: String {
        switch (completes, chats) {
        case (true, true): return "Suggestions and Chat"
        case (true, false): return "Code suggestions"
        default: return "Chat"
        }
    }
}

/// The four kinds of AI Mobile Studio offers. Each feature (Chat, its subagents, code suggestions,
/// merge conflicts) picks a tier, and each tier names the best model of its size for the job: a chat
/// model that can be the agent, and a code model trained for fill-in-the-middle (which chat models
/// aren't).
enum AITier: String, CaseIterable {
    /// Apple Intelligence: built into iOS, nothing to download. Answers questions; too small for the agent.
    case nano
    /// For every phone: quick, about 2.5 GB in all.
    case light
    /// For phones with 8 GB.
    case standard
    /// For phones with 12 GB.
    case smart

    var name: String {
        switch self {
        case .nano: return "Nano"
        case .light: return "Light"
        case .standard: return "Standard"
        case .smart: return "Smart"
        }
    }

    /// What it's for, in Settings.
    var summary: String {
        switch self {
        case .nano: return "Built into iOS, nothing to download"
        case .light: return "Quick, for every phone"
        case .standard: return "For phones with 8 GB"
        case .smart: return "The best answers, for phones with 12 GB"
        }
    }

    /// Chat's model.
    var chatChoice: AIModelChoice {
        switch self {
        case .nano: return .appleIntelligence
        case .light: return AIModelChoice(rawValue: "lfm3-1.7b")!
        case .standard: return AIModelChoice(rawValue: "qwen3.5-4b")!
        case .smart: return AIModelChoice(rawValue: "qwen3.5-9b")!
        }
    }

    /// Code suggestions' and merge conflicts' model.
    var codeChoice: AIModelChoice {
        switch self {
        case .nano: return .appleIntelligence
        case .light: return AIModelChoice(rawValue: "qwen2.5-coder-1.5b")!
        case .standard: return .fast
        case .smart: return .regular
        }
    }

    /// The tier a model belongs to, if any (a cloud model or Off has none).
    static func of(_ choice: AIModelChoice) -> AITier? {
        allCases.first { $0.chatChoice == choice || $0.codeChoice == choice }
    }
}

enum AIModelCatalog {
    private static func hf(_ path: String) -> URL { URL(string: "https://huggingface.co/\(path)")! }

    // Code suggestions and merge conflicts: Qwen2.5-Coder base models, trained for fill-in-the-middle,
    // which is what inline completion is (no newer small model is). Their ids are the settings' old
    // values: "fast" and "regular" were Fast AI and Regular AI.
    static let codeLight = LocalModel(
        id: "qwen2.5-coder-1.5b", name: "Qwen2.5-Coder 1.5B", detail: "Code model",
        fileName: "Qwen2.5-Coder-1.5B.Q4_K_M.gguf",
        url: hf("mradermacher/Qwen2.5-Coder-1.5B-GGUF/resolve/main/Qwen2.5-Coder-1.5B.Q4_K_M.gguf"),
        sha256: "b5fa4d99dd9aa4d5c36f2bd9c60eb189d10809d547a336e6cba8a4f45d178dc8",
        bytes: 986_048_960, minimumMemory: 3_500_000_000, completes: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 28672)

    static let fast = LocalModel(
        id: "fast", name: "Qwen2.5-Coder 3B", detail: "Code model",
        fileName: "Qwen2.5-Coder-3B-Q4_K_M.gguf",
        url: hf("bartowski/Qwen2.5-Coder-3B-GGUF/resolve/main/Qwen2.5-Coder-3B-Q4_K_M.gguf"),
        sha256: "bf2cee2051affae926e9a9ef4a62ebd197aec86639b075634faf973fcfd8a10c",
        bytes: 1_929_903_200, minimumMemory: 5_000_000_000, completes: true,
        license: "Qwen Research License", trainedContext: 32768, kvBytesPerToken: 36864)

    static let regular = LocalModel(
        id: "regular", name: "Qwen2.5-Coder 7B", detail: "Code model",
        fileName: "Qwen2.5-Coder-7B.Q4_K_M.gguf",
        url: hf("mradermacher/Qwen2.5-Coder-7B-GGUF/resolve/main/Qwen2.5-Coder-7B.Q4_K_M.gguf"),
        sha256: "92b96b6bfe55432605dee9c4757ed52ac9ca0a2a365eeaf782ce4c572bbfac39",
        bytes: 4_683_074_400, minimumMemory: 7_000_000_000, completes: true,
        license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 57344)

    // Chat: the best agents of each size (tool calling and coding benchmarks, November 2026). All three
    // write tool calls in the format Chat's agent uses (<tool_call><function=…>), and can think first.
    static let chatModels: [LocalModel] = [
        // LFM3 1.7B (Liquid AI, October 2026): about as good an agent as Qwen3.5 4B at under half the
        // size (its makers' BFCL v4 71, τ³-bench 68). Convolution layers, and attention layers of which
        // 5 of 11 keep only the last 256 tokens. Free for commercial use under $10M a year in revenue.
        LocalModel(id: "lfm3-1.7b", name: "LFM3 1.7B", detail: "Liquid AI's agent",
                   fileName: "LFM3-1.7B-Q4_K_M.gguf",
                   url: hf("LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q4_K_M.gguf"),
                   sha256: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4",
                   bytes: 1_099_627_808, minimumMemory: 4_000_000_000, chats: true, license: "LFM Open License 1.0", trainedContext: 262144,
                   kvBytesPerToken: 22528, slidingWindow: 256, fullAttentionShare: 6.0 / 11.0, agent: true, subagent: true,
                   reasoning: .optional, format: .lfm3, sampling: .lfm),
        // Qwen3.5: three of every four layers keep a fixed-size state instead of a cache, so the cache
        // per token is a quarter of a plain model's (kvBytesPerToken counts the other layers).
        LocalModel(id: "qwen3.5-4b", name: "Qwen3.5 4B", detail: "Qwen's agent",
                   fileName: "Qwen3.5-4B-Q4_K_M.gguf",
                   url: hf("unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"),
                   sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                   bytes: 2_740_937_888, minimumMemory: 6_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 262144, kvBytesPerToken: 32768,
                   agent: true, subagent: true, reasoning: .optional, format: .thinkPrefill),
        LocalModel(id: "qwen3.5-9b", name: "Qwen3.5 9B", detail: "Qwen's agent",
                   // IQ4_XS: about Q4's quality in half a gigabyte less, which is what fits a 12 GB phone's
                   // share of memory.
                   fileName: "Qwen3.5-9B-IQ4_XS.gguf",
                   url: hf("unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-IQ4_XS.gguf"),
                   sha256: "7e918aeca06c52bcb528ea6b04b4ec957e75ee8c0a73138854c0dfcf371ea429",
                   bytes: 5_168_653_536, minimumMemory: 10_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 262144, kvBytesPerToken: 32768,
                   agent: true, subagent: true, reasoning: .optional, format: .thinkPrefill),
    ]

    static let all = [codeLight, fast, regular] + chatModels

    /// Models the catalog used to have: their files, deleted at launch, and the model that takes
    /// over a setting that named one. Before the tiers, Settings → Advanced offered many models;
    /// each now goes to the tier of its size.
    private static let retired: [(id: String, fileName: String, replacement: String?)] = [
        ("qwen2.5-coder-1.5b-instruct", "Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf", nil),
        ("qwen2.5-coder-3b-instruct", "Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf", nil),
        ("qwen2.5-coder-7b-instruct", "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf", nil),
        ("qwen3-1.7b", "Qwen3-1.7B-Q8_0.gguf", nil),
        ("qwen3-4b", "Qwen3-4B-Q4_K_M.gguf", nil),
        ("llama3.2-1b", "Llama-3.2-1B-Instruct-Q4_K_M.gguf", nil),
        ("llama3.2-3b", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", nil),
        ("gemma3-1b", "google_gemma-3-1b-it-Q4_K_M.gguf", nil),
        ("gemma3-4b", "google_gemma-3-4b-it-Q4_K_M.gguf", nil),
        ("deepseek-r1-1.5b", "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf", nil),
        ("smollm2-1.7b", "SmolLM2-1.7B-Instruct-Q4_K_M.gguf", nil),
        // Replaced by the tiers.
        ("qwen2.5-coder-0.5b", "Qwen2.5-Coder-0.5B.Q8_0.gguf", "qwen2.5-coder-1.5b"),
        ("qwen3.5-0.8b", "Qwen3.5-0.8B-Q8_0.gguf", "lfm3-1.7b"),
        ("qwen3.5-2b", "Qwen3.5-2B-Q4_K_M.gguf", "lfm3-1.7b"),
        ("gemma4-e2b", "gemma-4-E2B-it-Q4_K_M.gguf", "lfm3-1.7b"),
        ("smollm3-3b", "SmolLM3-3B-Q4_K_M.gguf", "lfm3-1.7b"),
        ("gemma4-e4b", "gemma-4-E4B-it-Q4_K_M.gguf", "qwen3.5-4b"),
        ("phi4-mini", "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf", "qwen3.5-4b"),
    ]
    /// Files of models still here that now download another file (Qwen3.5 9B's Q4_K_M, too big to load).
    private static let replacedFiles = ["Qwen3.5-9B-Q4_K_M.gguf"]

    /// Deletes retired models' files and moves settings that named one to the model of its tier.
    static func removeRetired() {
        for name in retired.map(\.fileName) + replacedFiles {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let settings = AppSettings.shared
        func replacement(_ choice: AIModelChoice?, otherwise: AIModelChoice?) -> AIModelChoice?? {
            guard let choice, let old = retired.first(where: { $0.id == choice.rawValue }) else { return .none }
            return .some(old.replacement.flatMap(AIModelChoice.init(rawValue:)) ?? otherwise)
        }
        if case .some(let new) = replacement(settings.chatModel, otherwise: .appleIntelligence) { settings.chatModel = new ?? .appleIntelligence }
        if case .some(let new) = replacement(settings.subagentModel, otherwise: nil) { settings.subagentModel = new }
        if case .some(let new) = replacement(settings.aiModel, otherwise: .off) { settings.aiModel = new ?? .off }
        if case .some(let new) = replacement(settings.aiMergeModel, otherwise: nil) { settings.aiMergeModel = new }
    }

    static func model(for choice: AIModelChoice) -> LocalModel? {
        all.first { $0.choice == choice }
    }

    /// Application Support/Models: hidden from the Files app and excluded from iCloud backup.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()
}
