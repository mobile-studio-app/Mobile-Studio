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
    /// Sliding-window attention (Gemma 3): most layers only keep the last `slidingWindow` tokens,
    /// and `fullAttentionShare` of them the whole context.
    var slidingWindow = 0
    var fullAttentionShare = 1.0
    /// Good enough to be the Chat agent (tools, editing, running): small models loop or call
    /// tools wrongly, so they only answer questions.
    var agent = false
    var reasoning: Reasoning = .none

    enum Reasoning: String {
        /// No thinking: it answers straight away.
        case none
        /// Reasons first when Think is on (Qwen3).
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
        let gigabytes = minimumMemory > 6_000_000_000 ? 8 : minimumMemory > 4_000_000_000 ? 6 : 4
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
        LocalModel(id: "qwen2.5-coder-1.5b-instruct", name: "Qwen2.5-Coder 1.5B Instruct", detail: "Small coding assistant",
                   fileName: "Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf",
                   url: hf("bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf"),
                   sha256: "f530705d447660a4336c329981af164b471b60b974b1d808d57e8ec9fe23b239",
                   bytes: 986_048_800, minimumMemory: 3_500_000_000, chats: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 28672),
        LocalModel(id: "qwen2.5-coder-3b-instruct", name: "Qwen2.5-Coder 3B Instruct", detail: "Coding assistant",
                   fileName: "Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf",
                   url: hf("bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf"),
                   sha256: "3da3afe6cf5c674ac195803ea0dd6fee7e1c228c2105c1ce8c66890d1d4ab460",
                   bytes: 1_929_903_360, minimumMemory: 5_000_000_000, chats: true, license: "Qwen Research License", trainedContext: 32768, kvBytesPerToken: 36864, agent: true),
        LocalModel(id: "qwen2.5-coder-7b-instruct", name: "Qwen2.5-Coder 7B Instruct", detail: "Best coding assistant here",
                   fileName: "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
                   url: hf("bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"),
                   sha256: "1664fccab734674a50763490a8c6931b70e3f2f8ec10031b54806d30e5f956b6",
                   bytes: 4_683_074_336, minimumMemory: 7_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 57344, yarnContext: 131072, agent: true),
        LocalModel(id: "qwen3-1.7b", name: "Qwen3 1.7B", detail: "General assistant that reasons first",
                   fileName: "Qwen3-1.7B-Q8_0.gguf",
                   url: hf("Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf"),
                   sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
                   bytes: 1_834_426_016, minimumMemory: 4_500_000_000, chats: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 114688, reasoning: .optional),
        LocalModel(id: "qwen3-4b", name: "Qwen3 4B", detail: "General assistant that reasons first",
                   fileName: "Qwen3-4B-Q4_K_M.gguf",
                   url: hf("Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"),
                   sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
                   bytes: 2_497_280_256, minimumMemory: 6_000_000_000, chats: true, license: "Apache 2.0", trainedContext: 32768, kvBytesPerToken: 147456, yarnContext: 131072, agent: true, reasoning: .optional),
        LocalModel(id: "llama3.2-1b", name: "Llama 3.2 1B", detail: "Meta's small assistant",
                   fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
                   url: hf("bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
                   sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
                   bytes: 807_694_464, minimumMemory: 3_000_000_000, chats: true, license: "Llama 3.2 Community License", trainedContext: 131072, kvBytesPerToken: 32768),
        LocalModel(id: "llama3.2-3b", name: "Llama 3.2 3B", detail: "Meta's assistant",
                   fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                   url: hf("bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
                   sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
                   bytes: 2_019_377_696, minimumMemory: 5_000_000_000, chats: true, license: "Llama 3.2 Community License", trainedContext: 131072, kvBytesPerToken: 114688),
        LocalModel(id: "gemma3-1b", name: "Gemma 3 1B", detail: "Google's small assistant",
                   fileName: "google_gemma-3-1b-it-Q4_K_M.gguf",
                   url: hf("bartowski/google_gemma-3-1b-it-GGUF/resolve/main/google_gemma-3-1b-it-Q4_K_M.gguf"),
                   sha256: "12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d",
                   bytes: 806_058_496, minimumMemory: 3_000_000_000, chats: true, license: "Gemma Terms of Use", trainedContext: 32768, kvBytesPerToken: 26624, slidingWindow: 512, fullAttentionShare: 1.0 / 6),
        LocalModel(id: "gemma3-4b", name: "Gemma 3 4B", detail: "Google's assistant",
                   fileName: "google_gemma-3-4b-it-Q4_K_M.gguf",
                   url: hf("bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf"),
                   sha256: "4996030242583a40aa151ff93f49ed787ac8c25e4120c3ae4588b2e2a7d1ae94",
                   bytes: 2_489_758_112, minimumMemory: 6_000_000_000, chats: true, license: "Gemma Terms of Use", trainedContext: 131072, kvBytesPerToken: 139264, slidingWindow: 1024, fullAttentionShare: 1.0 / 6),
        LocalModel(id: "phi4-mini", name: "Phi-4 mini", detail: "Microsoft's assistant, good at reasoning",
                   fileName: "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf",
                   url: hf("bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"),
                   sha256: "01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2",
                   bytes: 2_491_874_688, minimumMemory: 6_000_000_000, chats: true, license: "MIT", trainedContext: 131072, kvBytesPerToken: 131072, agent: true),
        LocalModel(id: "deepseek-r1-1.5b", name: "DeepSeek-R1 Distill 1.5B", detail: "Reasons step by step",
                   fileName: "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf",
                   url: hf("bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"),
                   sha256: "1741e5b2d062b07acf048bf0d2c514dadf2a48f94e2b4aa0cfe069af3838ee2f",
                   bytes: 1_117_320_800, minimumMemory: 3_500_000_000, chats: true, license: "MIT", trainedContext: 131072, kvBytesPerToken: 28672, reasoning: .always),
        LocalModel(id: "smollm2-1.7b", name: "SmolLM2 1.7B", detail: "Hugging Face's small assistant",
                   fileName: "SmolLM2-1.7B-Instruct-Q4_K_M.gguf",
                   url: hf("bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Q4_K_M.gguf"),
                   sha256: "77665ea4815999596525c636fbeb56ba8b080b46ae85efef4f0d986a139834d7",
                   bytes: 1_055_609_824, minimumMemory: 3_500_000_000, chats: true, license: "Apache 2.0", trainedContext: 8192, kvBytesPerToken: 196608),
    ]

    static let all = [fast, regular] + extras

    static func model(for choice: AIModelChoice) -> LocalModel? {
        all.first { $0.choice == choice }
    }

    /// Models for AI Suggestions and merge conflicts: Fast and Regular AI, and code models downloaded from Advanced.
    static var completionModels: [LocalModel] { all.filter { $0.completes && ($0.isBuiltIn || $0.isDownloaded) } }

    /// Chat models suggested before any are downloaded, best first, with why.
    static let suggestedChat: [(id: String, why: String)] = [
        ("qwen2.5-coder-3b-instruct", "A quick coding agent for most devices"),
        ("qwen3-4b", "Thinks before it answers; up to 128K context"),
        ("qwen2.5-coder-7b-instruct", "The best coding agent here; up to 128K context"),
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
