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
    var reasoning: Reasoning = .none
    /// How its prompts are written.
    var format: PromptFormat = .template

    enum PromptFormat {
        /// The model's own chat template (llama.cpp's built-in version of it).
        case template
        /// The template, with the start of the answer written for it: "<think>\n" to reason, or an
        /// empty thought to answer straight away, as Qwen3.5's and SmolLM3's templates do.
        case thinkPrefill
        /// Gemma 4's turns (<|turn>user … <turn|>), which llama.cpp's templates don't know.
        case gemma4
    }

    enum Reasoning: String {
        /// No thinking: it answers straight away.
        case none
        /// Reasons first when Think is on (Qwen3.5, Gemma 4, SmolLM3).
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
    /// Fast AI and Regular AI, which Settings → AI always lists; the rest are listed once downloaded.
    var isBuiltIn: Bool { id == "fast" || id == "regular" }

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

enum AIModelCatalog {
    private static func hf(_ path: String) -> URL { URL(string: "https://huggingface.co/\(path)")! }

    // Qwen2.5-Coder base models: trained for fill-in-the-middle, which is what inline completion is.
    static let fast = LocalModel(
        id: "fast",
        name: "Fast AI",
        detail: "Qwen2.5-Coder 3B",
        fileName: "Qwen2.5-Coder-3B-Q4_K_M.gguf",
        url: hf("bartowski/Qwen2.5-Coder-3B-GGUF/resolve/main/Qwen2.5-Coder-3B-Q4_K_M.gguf"),
        sha256: "bf2cee2051affae926e9a9ef4a62ebd197aec86639b075634faf973fcfd8a10c",
        bytes: 1_929_903_200,
        minimumMemory: 5_000_000_000,
        completes: true,
        license: "Qwen Research License", trainedContext: 32768, kvBytesPerToken: 36864
    )

    static let regular = LocalModel(
        id: "regular",
        name: "Regular AI",
        detail: "Qwen2.5-Coder 7B",
        fileName: "Qwen2.5-Coder-7B.Q4_K_M.gguf",
        url: hf("mradermacher/Qwen2.5-Coder-7B-GGUF/resolve/main/Qwen2.5-Coder-7B.Q4_K_M.gguf"),
        sha256: "92b96b6bfe55432605dee9c4757ed52ac9ca0a2a365eeaf782ce4c572bbfac39",
        bytes: 4_683_074_400,
        minimumMemory: 7_000_000_000,
        completes: true,
        license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 57344
    )

    /// More models for Settings → Advanced → AI Models. Each one downloaded joins the lists it fits:
    /// code models AI Suggestions and merge conflicts, chat models the Chat panel.
    static let extras: [LocalModel] = [
        LocalModel(id: "qwen2.5-coder-0.5b", name: "Qwen2.5-Coder 0.5B", detail: "Tiny code model for older devices",
                   fileName: "Qwen2.5-Coder-0.5B.Q8_0.gguf",
                   url: hf("mradermacher/Qwen2.5-Coder-0.5B-GGUF/resolve/main/Qwen2.5-Coder-0.5B.Q8_0.gguf"),
                   sha256: "88a4073ab5430eb1010c757737eda04ed0557456aa70dc672ea307e09966c141",
                   bytes: 531_068_576, minimumMemory: 2_500_000_000, completes: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 12288),
        LocalModel(id: "qwen2.5-coder-1.5b", name: "Qwen2.5-Coder 1.5B", detail: "Small code model",
                   fileName: "Qwen2.5-Coder-1.5B.Q4_K_M.gguf",
                   url: hf("mradermacher/Qwen2.5-Coder-1.5B-GGUF/resolve/main/Qwen2.5-Coder-1.5B.Q4_K_M.gguf"),
                   sha256: "b5fa4d99dd9aa4d5c36f2bd9c60eb189d10809d547a336e6cba8a4f45d178dc8",
                   bytes: 986_048_960, minimumMemory: 3_500_000_000, completes: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 28672),
        // Qwen3.5: three of every four layers keep a fixed-size state instead of a cache, so the cache
        // per token is a quarter of a plain model's (kvBytesPerToken counts the other layers).
        LocalModel(id: "qwen3.5-0.8b", name: "Qwen3.5 0.8B", detail: "Tiny assistant for older devices",
                   fileName: "Qwen3.5-0.8B-Q8_0.gguf",
                   url: hf("unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q8_0.gguf"),
                   sha256: "0ad885ffd4bb022fc4f0d33a3308fa108ef8613159d3b3a67e23abca056b7a6c",
                   bytes: 811_843_840, minimumMemory: 3_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 262144, kvBytesPerToken: 12288,
                   reasoning: .optional, format: .thinkPrefill),
        LocalModel(id: "qwen3.5-2b", name: "Qwen3.5 2B", detail: "Small assistant",
                   fileName: "Qwen3.5-2B-Q4_K_M.gguf",
                   url: hf("unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf"),
                   sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
                   bytes: 1_280_835_840, minimumMemory: 4_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 262144, kvBytesPerToken: 12288,
                   reasoning: .optional, format: .thinkPrefill),
        LocalModel(id: "qwen3.5-4b", name: "Qwen3.5 4B", detail: "Coding agent that can think first",
                   fileName: "Qwen3.5-4B-Q4_K_M.gguf",
                   url: hf("unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"),
                   sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                   bytes: 2_740_937_888, minimumMemory: 6_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 262144, kvBytesPerToken: 32768,
                   agent: true, reasoning: .optional, format: .thinkPrefill),
        LocalModel(id: "qwen3.5-9b", name: "Qwen3.5 9B", detail: "Best coding agent here",
                   fileName: "Qwen3.5-9B-Q4_K_M.gguf",
                   url: hf("unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"),
                   sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
                   bytes: 5_680_522_464, minimumMemory: 10_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 262144, kvBytesPerToken: 32768,
                   agent: true, reasoning: .optional, format: .thinkPrefill),
        // Gemma 4: most layers attend over the last 512 tokens, and later layers share earlier ones' cache.
        LocalModel(id: "gemma4-e2b", name: "Gemma 4 E2B", detail: "Google's small assistant",
                   fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
                   url: hf("unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf"),
                   sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8",
                   bytes: 3_106_738_272, minimumMemory: 6_000_000_000, chats: true, license: "Gemma Terms of Use", trainedContext: 131072, kvBytesPerToken: 15360,
                   slidingWindow: 512, fullAttentionShare: 0.4, reasoning: .optional, format: .gemma4),
        LocalModel(id: "gemma4-e4b", name: "Gemma 4 E4B", detail: "Google's assistant",
                   fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
                   url: hf("unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf"),
                   sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
                   bytes: 4_977_171_584, minimumMemory: 10_000_000_000, chats: true, license: "Gemma Terms of Use", trainedContext: 131072, kvBytesPerToken: 49152,
                   slidingWindow: 512, fullAttentionShare: 0.42, agent: true, reasoning: .optional, format: .gemma4),
        LocalModel(id: "phi4-mini", name: "Phi-4 mini", detail: "Microsoft's assistant, good at reasoning",
                   fileName: "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf",
                   url: hf("bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"),
                   sha256: "01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2",
                   bytes: 2_491_874_688, minimumMemory: 6_000_000_000, chats: true, license: "MIT", trainedContext: 131072, kvBytesPerToken: 131072, agent: true),
        LocalModel(id: "smollm3-3b", name: "SmolLM3 3B", detail: "Hugging Face's assistant that can think first",
                   fileName: "SmolLM3-3B-Q4_K_M.gguf",
                   url: hf("unsloth/SmolLM3-3B-GGUF/resolve/main/SmolLM3-3B-Q4_K_M.gguf"),
                   sha256: "4de907d2d388a5508fb7cb443a06effe14cce3518b0a78d3bdd9e74d9edce989",
                   bytes: 1_915_306_528, minimumMemory: 5_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 65536, kvBytesPerToken: 73728,
                   reasoning: .optional, format: .thinkPrefill),
    ]

    static let all = [fast, regular] + extras

    /// Models the catalog used to have, replaced by newer ones (Qwen3.5 for Qwen3 and Qwen2.5-Coder
    /// Instruct, Gemma 4 for Gemma 3, SmolLM3 for SmolLM2; Qwen3.5 reasons as DeepSeek-R1 Distill
    /// did, and outdoes Llama 3.2): their files, deleted at launch.
    private static let retired: [(id: String, fileName: String)] = [
        ("qwen2.5-coder-1.5b-instruct", "Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf"),
        ("qwen2.5-coder-3b-instruct", "Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf"),
        ("qwen2.5-coder-7b-instruct", "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"),
        ("qwen3-1.7b", "Qwen3-1.7B-Q8_0.gguf"),
        ("qwen3-4b", "Qwen3-4B-Q4_K_M.gguf"),
        ("llama3.2-1b", "Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
        ("llama3.2-3b", "Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
        ("gemma3-1b", "google_gemma-3-1b-it-Q4_K_M.gguf"),
        ("gemma3-4b", "google_gemma-3-4b-it-Q4_K_M.gguf"),
        ("deepseek-r1-1.5b", "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"),
        ("smollm2-1.7b", "SmolLM2-1.7B-Instruct-Q4_K_M.gguf"),
    ]

    /// Deletes retired models' files and moves settings that named one to a model still here.
    static func removeRetired() {
        for model in retired {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.fileName))
        }
        let ids = Set(retired.map(\.id))
        let settings = AppSettings.shared
        if ids.contains(settings.chatModel.rawValue) { settings.chatModel = .appleIntelligence }
        if let sub = settings.subagentModel, ids.contains(sub.rawValue) { settings.subagentModel = nil }
    }

    static func model(for choice: AIModelChoice) -> LocalModel? {
        all.first { $0.choice == choice }
    }

    /// Models for AI Suggestions and merge conflicts: Fast and Regular AI, and code models downloaded from Advanced.
    static var completionModels: [LocalModel] { all.filter { $0.completes && ($0.isBuiltIn || $0.isDownloaded) } }

    /// Chat models suggested before any are downloaded, best first, with why.
    static let suggestedChat: [(id: String, why: String)] = [
        ("qwen3.5-4b", "A quick coding agent for most devices; can think first"),
        ("qwen3.5-9b", "The best coding agent here, for devices with 12 GB"),
        ("gemma4-e4b", "Google's agent, for devices with 12 GB"),
    ]

    /// Why a model is suggested for Chat, if it is.
    static func suggestion(for model: LocalModel) -> String? {
        suggestedChat.first { $0.id == model.id }?.why
    }

    /// Chat's models: the suggested ones this device can run (downloaded or not), then other downloaded ones.
    static var chatModels: [LocalModel] {
        let suggested = suggestedChat.compactMap { s in all.first { $0.id == s.id } }.filter { $0.isSupported || $0.isDownloaded }
        return suggested + all.filter { $0.chats && $0.isDownloaded && suggestion(for: $0) == nil }
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
