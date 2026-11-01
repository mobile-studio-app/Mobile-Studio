import UIKit
import UniformTypeIdentifiers
import WebKit

/// Serves extensions' files to their webviews as duocode-res://file/<path>, the URLs
/// webview.asWebviewUri gives (Editor/src/ext/worker.js). Real URLs, so a webview's scripts can
/// import their other files by relative paths, as big apps (Codex's 22,000 files) do. Webviews are
/// sandboxed frames with no origin, so each response allows any origin (CORS), which module
/// scripts need. Only files inside installed extensions are served.
final class ExtensionResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "duocode-res"
    /// Tasks WebKit stopped (the frame went away): answering one raises an exception.
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url) else {
            return respond(task, status: 404, type: "text/plain", data: Data("Not found".utf8))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async {
                guard let data else { return self.respond(task, status: 404, type: "text/plain", data: Data("Not found".utf8)) }
                self.respond(task, status: 200, type: Self.mimeType(for: file), data: data)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, type: String, data: Data) {
        let headers = [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        // The frame may have closed while the file was read.
        guard stopped.remove(ObjectIdentifier(task)) == nil else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// The file a URL names: duocode-res://file/<absolute path>, or the older form with the whole
    /// path percent-encoded as the host. A web extension's files have the virtual path
    /// /.duocode/extensions/<id>/<file>.
    static func file(for url: URL) -> URL? {
        var path: String
        if url.host == "file" {
            path = url.path
        } else {
            let raw = url.absoluteString.dropFirst("\(scheme)://".count)
            path = String(raw).removingPercentEncoding ?? String(raw)
            while path.hasSuffix("/") { path.removeLast() }
        }
        if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
        let extensions = ExtensionManager.shared.root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate: URL
        if path.hasPrefix("/.duocode/extensions/") {
            let parts = path.dropFirst("/.duocode/extensions/".count).split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let folder = ExtensionManager.shared.folder(of: parts[0]) else { return nil }
            candidate = folder.appendingPathComponent(parts[1])
        } else {
            candidate = URL(fileURLWithPath: path)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        // /var and /private/var are the same folder on iOS.
        let normalize = { (p: String) in p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
        guard normalize(resolved.path).hasPrefix(normalize(extensions) + "/") else { return nil }
        return resolved
    }

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js", "mjs", "cjs": return "text/javascript"
        case "css": return "text/css"
        case "html", "htm": return "text/html"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
