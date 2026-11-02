import Foundation

/// pip in the Terminal: runs pip in the Python runtime (its "--pip=" mode, PythonRuntime.mm),
/// collects what it prints, then signs any compiled modules the install brought (iOS only loads
/// native code signed by the app's team; Settings > Programs from Extensions has the certificate).
/// Packages live in Application Support/python3.14/site-packages, which every Python run imports from.
final class PythonPackages {
    static let shared = PythonPackages()

    static var sitePackages: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("python3.14/site-packages", isDirectory: true)
    }

    /// Starts the Python runtime with these arguments in the console (IDEViewController).
    var startPython: (([String]) throws -> Void)?

    private var busy = false

    /// Runs `pip args`; `completion` gets its output and exit code (on the main queue).
    func pip(_ args: [String], completion: @escaping (String, Int32) -> Void) {
        guard !busy else { return completion("pip is already running.\n", 1) }
        guard let startPython else { return completion("Python isn't available.\n", 1) }
        guard let json = try? JSONSerialization.data(withJSONObject: args), let command = String(data: json, encoding: .utf8) else {
            return completion("pip: bad arguments\n", 1)
        }
        busy = true
        ProgramRunCapture.shared.capture { [weak self] output, code in
            guard let self else { return }
            self.busy = false
            var text = output
            if args.first == "install", code == 0 { text += self.signCompiledModules() }
            completion(text.isEmpty ? "" : text + (text.hasSuffix("\n") ? "" : "\n"), code)
        }
        do {
            try startPython(["--pip=" + command])
        } catch {
            ProgramRunCapture.shared.cancelCapture()
            busy = false
            completion("pip couldn't start: \(error.localizedDescription)\n", 1)
        }
    }

    /// Signs the compiled modules (.so, .dylib) not signed yet; says which couldn't be.
    private func signCompiledModules() -> String {
        let root = Self.sitePackages
        let record = root.appendingPathComponent(".mobile-studio-signed.json")
        var signed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: record))) as? [String: Double] ?? [:]
        var unsigned: [String] = []
        var count = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = files?.nextObject() as? URL {
            guard ["so", "dylib"].contains(url.pathExtension) else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let modified = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970
            if signed[relative] == modified { continue }
            let module = relative.components(separatedBy: ".").first?.replacingOccurrences(of: "/", with: ".") ?? "module"
            var error = [CChar](repeating: 0, count: 512)
            let rc = dc_native_tools_sign_library(url.path, "python.\(module)", &error, error.count)
            if rc == 0 {
                count += 1
                let after = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970
                signed[relative] = after
            } else if rc == 3 {
                unsigned.append(relative)
            } else {
                unsigned.append("\(relative) (\(String(cString: error)))")
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: signed) { try? data.write(to: record) }
        var note = ""
        if count > 0 { note += "Signed \(count) compiled module\(count == 1 ? "" : "s") so iOS will load \(count == 1 ? "it" : "them").\n" }
        if !unsigned.isEmpty {
            note += "These compiled modules can't load until they're signed: import your signing certificate in Settings > Programs from Extensions, then run pip install again.\n"
                + unsigned.prefix(8).map { "  \($0)\n" }.joined()
        }
        return note
    }
}
