import UIKit
import MetricKit
import os

/// Settings → Advanced → Export Diagnostics: one text file to attach to a bug report, with the
/// app and device, a few settings, the installed extensions, the latest crash reports, the
/// program console and the Node.js extension host's log. No keys, tokens or project files.
/// Crash diagnostics iOS delivers (MetricKit, the launch after a crash) are kept for it too.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    /// Application Support/Diagnostics: MetricKit's reports, newest kept.
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for (i, payload) in payloads.enumerated() {
            try? payload.jsonRepresentation().write(to: Self.folder.appendingPathComponent("diagnostic-\(stamp)-\(i).json"))
        }
        // The ten newest.
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(10) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Writes the report to a temporary file for the share sheet.
    func report() -> URL {
        var out = "Mobile Studio diagnostics\n"
        func section(_ title: String, _ body: String) { out += "\n== \(title) ==\n\(body.isEmpty ? "(none)" : body)\n" }

        let info = Bundle.main.infoDictionary
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let s = AppSettings.shared
        section("App and device", """
            Version: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))
            Device: \(model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
            Memory: \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)), \
            \(ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory)) available now
            Date: \(ISO8601DateFormatter().string(from: Date()))
            """)
        let cloud = CloudProvider.allCases.filter(\.isConfigured).map(\.name).joined(separator: ", ")
        section("Settings", """
            AI Suggestions: \(s.aiModel.rawValue); Chat: \(s.chatModel.rawValue), context \(s.chatContextSize), mode \(s.chatMode), thinking \(s.chatThinking)
            Subagents: \(s.subagentModel?.rawValue ?? "same as Chat"), \(s.subagentParallel) at once
            Cloud models set up: \(cloud.isEmpty ? "none" : cloud)
            Theme: \(s.editorTheme); icons: \(s.fileIconTheme); LuaJIT JIT: \(s.useJIT)
            """)
        section("Extensions", ExtensionManager.shared.installed.map { "\($0.id)\($0.enabled ? "" : " (disabled)")" }.joined(separator: "\n"))

        var crashes = ""
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let log = try? String(contentsOf: documents.appendingPathComponent("crash.log"), encoding: .utf8) { crashes += Self.tail(log, 20_000) }
        let reports = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(3)
        for url in reports {
            if let text = try? String(contentsOf: url, encoding: .utf8) { crashes += "\n-- \(url.lastPathComponent)\n" + Self.tail(text, 30_000) }
        }
        section("Crash reports", crashes)
        section("Program console (latest)", ProgramRunCapture.shared.recent.suffix(300).joined(separator: "\n"))
        let nodeLog = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-studio-node-host.log")
        section("Node.js extension host log", Self.tail((try? String(contentsOf: nodeLog, encoding: .utf8)) ?? "", 120_000))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mobile Studio Diagnostics.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func tail(_ text: String, _ count: Int) -> String {
        text.count > count ? "(earlier part left out)\n" + text.suffix(count) : text
    }
}
