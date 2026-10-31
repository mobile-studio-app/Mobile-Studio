import Foundation

/// Node.js (nodejs-mobile, without JIT on iOS) running the extension host for extensions whose
/// code needs Node. It runs Editor/src/ext/node-host.js, which serves the same protocol as the
/// web extension host over a local HTTP port that only this device can reach (the editor
/// page connects to it). Node can start only once per launch, so it then runs for the rest of
/// the app's life; the editor resets it when extensions change.
final class NodeExtensionHost {
    static let shared = NodeExtensionHost()

    private(set) var port: Int?
    /// Where JavaScript programs (the Node.js runtime) are started: the next port.
    var programPort: Int? { port.map { $0 + 1 } }

    private typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

    /// node_start from NodeMobile.framework, opened on first use (the app doesn't link it, so a
    /// framework that won't load can't stop the app starting).
    private static let nodeStart: NodeStart? = {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("NodeMobile.framework/NodeMobile"),
              let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            NSLog("DuoCode: Node.js didn't load: %@", dlerror().map { String(cString: $0) } ?? "missing")
            return nil
        }
        guard let symbol = dlsym(handle, "node_start") else { return nil }
        return unsafeBitCast(symbol, to: NodeStart.self)
    }()

    /// Starts Node if it isn't running and returns its port (nil if Node.js can't load).
    func start() -> Int? {
        if let port { return port }
        guard let nodeStart = Self.nodeStart else { return nil }
        guard let script = Bundle.main.url(forResource: "node-host", withExtension: "js", subdirectory: "Editor")
                ?? Bundle.main.url(forResource: "node-host", withExtension: "js") else { return nil }
        // Two ports: extensions on this one, programs on the next. The third is where extensions'
        // macOS programs are started (NativeTools.mm); it's taken first, so the pair avoids it.
        let nativePort = Int(dc_native_tools_start())
        var port = 47_831
        for _ in 0..<20 {
            guard let candidate = Self.freePort(), candidate < 65_535 else { continue }
            if candidate != nativePort && candidate + 1 != nativePort && Self.isFree(candidate + 1) {
                port = candidate
                break
            }
        }
        self.port = port
        let arguments = ["node", script.path, String(port), String(port + 1), String(nativePort)]
        let thread = Thread {
            // Node wants argv in one block of memory (libuv rewrites it in place). It's never freed:
            // node_start returns only when Node exits, which it shouldn't.
            let size = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
            let block = UnsafeMutablePointer<CChar>.allocate(capacity: size)
            var argv: [UnsafeMutablePointer<CChar>?] = []
            var offset = 0
            for argument in arguments {
                argument.withCString { strcpy(block + offset, $0) }
                argv.append(block + offset)
                offset += argument.utf8.count + 1
            }
            argv.append(nil)
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argv.count)
            pointers.initialize(from: argv, count: argv.count)
            let code = nodeStart(Int32(arguments.count), pointers)
            NSLog("DuoCode: Node.js exited with code %d", code)
        }
        thread.name = "Node.js extension host"
        thread.stackSize = 16 << 20   // V8 without JIT recurses deeply
        thread.qualityOfService = .userInitiated
        thread.start()
        return port
    }

    /// Whether `port` on the loopback interface can be listened on.
    private static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    /// A free TCP port on the loopback interface.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
