import CryptoKit
import Foundation
import Network

/// Downloads local models with a background URLSession, so a multi-gigabyte download keeps
/// going when DuoCode is in the background. Each file is checked against its SHA-256 before use.
///
/// There are two sessions because a background session's network rules are fixed when it's made:
/// one only uses unmetered networks, the other also uses mobile data and personal hotspots.
/// Neither uses a network in Low Data Mode. Changing the setting moves running downloads across.
final class ModelDownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloadManager()
    /// `userInfo["model"]` names the model that changed; nil when it could be any of them.
    static let didChange = Notification.Name("DuoCodeModelDownloadDidChange")

    enum State {
        case notDownloaded
        case downloading(Double)
        case verifying
        case downloaded
        case failed(String)
    }

    /// Handed over by the app delegate when iOS wakes us for finished background downloads.
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private var states: [AIModelChoice: State] = [:]
    private var path: NWPath?
    private let pathMonitor = NWPathMonitor()
    private var monitoring = false
    private var allowsCellular = AppSettings.shared.downloadOverCellular

    private static let wifiIdentifier = "com.duocode.ide.models"
    private static let cellularIdentifier = "com.duocode.ide.models.cellular"

    private lazy var wifiSession = makeSession(Self.wifiIdentifier, cellular: false)
    private lazy var cellularSession = makeSession(Self.cellularIdentifier, cellular: true)

    private func makeSession(_ identifier: String, cellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = cellular
        config.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    private var currentSession: URLSession { allowsCellular ? cellularSession : wifiSession }
    private var otherSession: URLSession { allowsCellular ? wifiSession : cellularSession }

    /// Call at launch: reattaches to downloads that were running when the app was last closed.
    func reconnect() {
        startMonitoring()
        for session in [wifiSession, cellularSession] {
            session.getAllTasks { tasks in
                DispatchQueue.main.async {
                    for task in tasks where task.state == .running {
                        guard let choice = Self.choice(of: task) else { continue }
                        let total = task.countOfBytesExpectedToReceive
                        self.states[choice] = .downloading(total > 0 ? Double(task.countOfBytesReceived) / Double(total) : 0)
                    }
                    self.notify()
                }
            }
        }
    }

    func handleBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        backgroundCompletionHandlers[identifier] = completionHandler
        reconnect()
    }

    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.path = path
                self?.notify()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.duocode.ide.models.path"))
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
    }

    func state(for model: LocalModel) -> State {
        if let state = states[model.choice] { return state }
        return model.isDownloaded ? .downloaded : .notDownloaded
    }

    /// Why downloads are stalled on the current network, or nil when they can go ahead.
    var waitingReason: String? {
        guard let path else { return nil }
        if path.isConstrained { return "Paused by Low Data Mode" }
        if path.isExpensive && !allowsCellular { return "Waiting for Wi-Fi" }
        if path.status != .satisfied { return "Waiting for a connection" }
        return nil
    }

    func download(_ model: LocalModel) {
        let task = currentSession.downloadTask(with: model.url)
        task.taskDescription = model.choice.rawValue
        states[model.choice] = .downloading(0)
        task.resume()
        notify(model.choice)
    }

    func cancel(_ model: LocalModel) {
        for session in [wifiSession, cellularSession] {
            session.getAllTasks { tasks in
                tasks.filter { $0.taskDescription == model.choice.rawValue }.forEach { $0.cancel() }
            }
        }
        states[model.choice] = nil
        notify(model.choice)
    }

    func delete(_ model: LocalModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        states[model.choice] = nil
        notify(model.choice)
    }

    /// Moves running downloads to the session that matches the mobile data setting, keeping their progress.
    private func settingsChanged() {
        let cellular = AppSettings.shared.downloadOverCellular
        guard cellular != allowsCellular else { return }
        allowsCellular = cellular
        notify()
        let to = currentSession
        otherSession.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks where task.state == .running {
                guard let choice = Self.choice(of: task), let model = AIModelCatalog.model(for: choice) else { continue }
                task.taskDescription = nil   // so this cancellation isn't reported as the user cancelling
                task.cancel { resumeData in
                    DispatchQueue.main.async {
                        let moved = resumeData.map { to.downloadTask(withResumeData: $0) } ?? to.downloadTask(with: model.url)
                        moved.taskDescription = choice.rawValue
                        moved.resume()
                    }
                }
            }
        }
    }

    private static func choice(of task: URLSessionTask) -> AIModelChoice? {
        task.taskDescription.flatMap(AIModelChoice.init(rawValue:))
    }

    private func notify(_ choice: AIModelChoice? = nil) {
        NotificationCenter.default.post(name: Self.didChange, object: self,
                                        userInfo: choice.map { ["model": $0] })
    }

    // MARK: - URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let choice = Self.choice(of: downloadTask), let model = AIModelCatalog.model(for: choice) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.bytes
        let progress = min(1, Double(totalBytesWritten) / Double(total))
        let previous: Double? = { if case .downloading(let p) = states[choice] { return p }; return nil }()
        states[choice] = .downloading(progress)
        // Only tell observers when the whole percentage changes; this callback fires constantly.
        if previous.map({ Int($0 * 100) }) != Int(progress * 100) { notify(choice) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let choice = Self.choice(of: downloadTask), let model = AIModelCatalog.model(for: choice) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            states[choice] = .failed("Download failed (HTTP \(http.statusCode)).")
            notify(choice)
            return
        }
        // The temporary file is deleted when this method returns, so move it first.
        let partial = model.localURL.appendingPathExtension("part")
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            states[choice] = .failed("Couldn't save the model: \(error.localizedDescription)")
            notify(choice)
            return
        }
        states[choice] = .verifying
        notify(choice)
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.sha256(of: partial) == model.sha256
            if ok {
                try? FileManager.default.removeItem(at: model.localURL)
                try? FileManager.default.moveItem(at: partial, to: model.localURL)
            } else {
                try? FileManager.default.removeItem(at: partial)
            }
            DispatchQueue.main.async {
                self.states[choice] = ok ? nil : .failed("The download was damaged. Try again.")
                self.notify(choice)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let choice = Self.choice(of: task) else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            states[choice] = nil
        } else {
            states[choice] = .failed(error.localizedDescription)
        }
        notify(choice)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        backgroundCompletionHandlers.removeValue(forKey: identifier)?()
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 8 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
