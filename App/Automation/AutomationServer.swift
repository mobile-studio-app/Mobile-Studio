import Foundation
import Network
import UIKit

/// Test automation over Wi-Fi (Settings → Developer). A small HTTP server that lets a computer
/// on the same network take screenshots, tap, type and read state, so DuoCode can be tested on
/// a real phone from scripts (tools/duo.py). Off by default; every request needs the pairing code
/// shown in Settings. See AutomationDriver for what each endpoint does.
final class AutomationServer {
    static let shared = AutomationServer()
    static let port: UInt16 = 8765
    static let didChange = Notification.Name("DuoCodeAutomationDidChange")
    /// Automation changed files behind the editor's back (git setup); the editor re-reads the open file.
    static let filesChangedOnDisk = Notification.Name("DuoCodeAutomationFilesChangedOnDisk")

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.duocode.automation")
    private(set) var isRunning = false

    private init() {
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySetting()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // iOS can drop the listener while the app is suspended (the phone locked); start a
            // new one if it's gone. A listener that still works is left alone.
            guard let self, AppSettings.shared.testAutomation, !self.isRunning else { return }
            self.stop()
            self.start()
        }
    }

    /// Six digits, kept between launches so scripts keep working.
    var token: String {
        if let saved = UserDefaults.standard.string(forKey: "duocode.automation.token") { return saved }
        return resetToken()
    }

    @discardableResult
    func resetToken() -> String {
        let token = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(token, forKey: "duocode.automation.token")
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return token
    }

    /// "http://192.168.1.20:8765", or nil when there's no Wi-Fi address.
    var address: String? {
        Self.wifiAddress().map { "http://\($0):\(Self.port)" }
    }

    func applySetting() {
        AppSettings.shared.testAutomation ? start() : stop()
        // A locked phone suspends the app and drops the connection, so it stays awake while on.
        UIApplication.shared.isIdleTimerDisabled = AppSettings.shared.testAutomation
    }

    private func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed:
                    // Usually the port isn't free yet after a suspend; try again shortly.
                    self?.isRunning = false
                    self?.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.applySetting() }
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                self.respond(to: request) { response in
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if done || error != nil || buffer.count > 64 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, send: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            guard request.headers["x-duo-token"] == self.token || request.query["token"] == self.token else {
                return send(HTTPResponse.json(["error": "Wrong or missing pairing code (X-Duo-Token)."], status: 401))
            }
            AutomationDriver.handle(request) { send($0) }
        }
    }

    /// The phone's IPv4 address on Wi-Fi (en0).
    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Parses a complete request, or returns nil if more bytes are needed.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let components = URLComponents(string: parts[1])
        method = parts[0].uppercased()
        path = components?.path ?? parts[1]
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        self.query = query
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

enum HTTPResponse {
    static func make(_ body: Data, type: String, status: Int = 200) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func json(_ object: Any, status: Int = 200) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return make(body, type: "application/json", status: status)
    }

    static func error(_ message: String, status: Int = 400) -> Data {
        json(["error": message], status: status)
    }
}
