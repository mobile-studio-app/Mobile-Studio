import Foundation

/// A code model that runs on the phone with llama.cpp. Downloaded on demand from Hugging Face.
struct LocalModel {
    let choice: AIModelChoice
    let name: String
    let detail: String
    let fileName: String
    let url: URL
    let sha256: String
    let bytes: Int64
    /// Physical RAM the phone needs. 6 GB phones report about 5.7 GB, 8 GB phones about 7.5 GB.
    let minimumMemory: UInt64

    var localURL: URL { AIModelCatalog.directory.appendingPathComponent(fileName) }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }
    var isSupported: Bool { ProcessInfo.processInfo.physicalMemory >= minimumMemory }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var requirementText: String {
        "Needs a phone with \(minimumMemory > 6_000_000_000 ? 8 : 6) GB of memory."
    }
}

enum AIModelCatalog {
    // Qwen2.5-Coder base models: trained for fill-in-the-middle, which is what inline completion is.
    static let fast = LocalModel(
        choice: .fast,
        name: "Fast AI",
        detail: "Qwen2.5-Coder 3B",
        fileName: "Qwen2.5-Coder-3B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-3B-GGUF/resolve/main/Qwen2.5-Coder-3B-Q4_K_M.gguf")!,
        sha256: "bf2cee2051affae926e9a9ef4a62ebd197aec86639b075634faf973fcfd8a10c",
        bytes: 1_929_903_200,
        minimumMemory: 5_000_000_000
    )

    static let regular = LocalModel(
        choice: .regular,
        name: "Regular AI",
        detail: "Qwen2.5-Coder 7B",
        fileName: "Qwen2.5-Coder-7B.Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/mradermacher/Qwen2.5-Coder-7B-GGUF/resolve/main/Qwen2.5-Coder-7B.Q4_K_M.gguf")!,
        sha256: "92b96b6bfe55432605dee9c4757ed52ac9ca0a2a365eeaf782ce4c572bbfac39",
        bytes: 4_683_074_400,
        minimumMemory: 7_000_000_000
    )

    static let all = [fast, regular]

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
