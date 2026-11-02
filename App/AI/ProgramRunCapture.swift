import Foundation

/// The Chat agent's run_program and read_console: runs the project as the Run button does and
/// collects what it prints to the console, until it ends or a time limit passes (games keep
/// running). IDEViewController feeds it the console's lines and the program's exit.
final class ProgramRunCapture {
    static let shared = ProgramRunCapture()

    /// Set by IDEViewController.
    var startRun: (() -> Void)?
    var stopRun: (() -> Void)?
    var isRunning: (() -> Bool)?

    /// The console's last lines, from any run.
    private(set) var recent: [String] = []
    private var lines: [String] = []
    private var completion: (([String: Any]) -> Void)?
    private var timeout: DispatchWorkItem?

    /// A console line (IDEViewController.appendLog).
    func log(_ line: String) {
        recent.append(line)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        if completion != nil { lines.append(line) }
    }

    /// The program ended.
    func exited(code: Int32) {
        finish(code: Int(code), running: false)
    }

    /// Runs the project (restarting it if it's running) and reports its output after it ends, or
    /// after `seconds`; then it's stopped unless `keepRunning`.
    func run(seconds: Double, keepRunning: Bool, completion: @escaping ([String: Any]) -> Void) {
        finish(code: nil, running: false)
        lines = []
        self.completion = completion
        startRun?()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let running = self.isRunning?() ?? false
            if running && !keepRunning { self.stopRun?() }
            self.finish(code: nil, running: running)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Collects the console of a run someone else starts (pip), until it ends.
    func capture(_ completion: @escaping (String, Int32) -> Void) {
        finish(code: nil, running: false)
        lines = []
        self.completion = { result in
            completion(result["output"] as? String ?? "", Int32(result["exitCode"] as? Int ?? 1))
        }
    }

    func cancelCapture() {
        completion = nil
        lines = []
    }

    private func finish(code: Int?, running: Bool) {
        timeout?.cancel()
        timeout = nil
        guard let completion else { return }
        self.completion = nil
        var output = lines.joined(separator: "\n")
        if output.count > 8000 { output = "…\n" + output.suffix(8000) }
        completion(["output": output, "exitCode": code.map { $0 as Any } ?? NSNull(), "stillRunning": running])
    }
}
