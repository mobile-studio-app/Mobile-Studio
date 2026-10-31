import UIKit

protocol RuntimeHostDelegate: AnyObject {
    func runtimeHost(_ host: RuntimeHost, log message: String, level: dc_log_level)
    func runtimeHost(_ host: RuntimeHost, stateChanged state: dc_runtime_state)
    func runtimeHost(_ host: RuntimeHost, error message: String, file: String?, line: Int)
    /// The runtime's `run` returned; `code` is its exit code (0 = clean).
    func runtimeHost(_ host: RuntimeHost, didExitWithCode code: Int32)
}

/// Owns the C `dc_host_api` handed to runtimes and drives a single game run.
///
/// IMPORTANT run-loop note: `dc_runtime.run` blocks the main thread and pumps
/// the CFRunLoop itself. We must NOT call it from inside a GCD main-queue block
/// (the main queue is serial, so nested GCD work — which WebKit and UIKit rely
/// on — would stall until the game exits). Instead we start it from a run-loop
/// perform (`perform(_:with:afterDelay:)`), which is exactly how SDL launches
/// SDL_main on iOS.
final class RuntimeHost: NSObject {
    weak var delegate: RuntimeHostDelegate?
    let containerView: UIView
    private(set) var isRunning = false
    private(set) var active: RuntimeDescriptor?
    private var initialised = Set<String>()
    private let api: UnsafeMutablePointer<dc_host_api>
    var inputFocused = false {
        didSet { active?.vtable?.pointee.set_input_focus?(inputFocused ? 1 : 0) }
    }
    /// The running program's debugger events and replies (JSON), when the run is debugged.
    var onDebugEvent: ((String) -> Void)?
    /// The current run is being debugged.
    private(set) var isDebugging = false

    /// Settings → Run → LuaJIT JIT; actual JIT use also requires the process to be debugged.
    var jitEnabledByUser: Bool { AppSettings.shared.useJIT }

    /// A debugger is attached and LuaJIT can safely compile. On iOS 26 and later (TXM), a debugger
    /// alone isn't enough: pages only become executable through a debugger handshake LuaJIT doesn't
    /// do yet, and its first compiled trace would crash. Games use the interpreter there for now.
    static var jitAvailable: Bool {
        if #available(iOS 26.0, *) { return false }
        return dc_process_is_debugged() != 0
    }

    init(containerView: UIView) {
        self.containerView = containerView
        api = .allocate(capacity: 1)
        super.init()
        api.initialize(to: dc_host_api(
            abi_version: UInt32(DC_RUNTIME_ABI_VERSION),
            ctx: Unmanaged.passUnretained(self).toOpaque(),
            log: { ctx, level, msg in
                guard let ctx, let msg else { return }
                let host = Unmanaged<RuntimeHost>.fromOpaque(ctx).takeUnretainedValue()
                host.delegate?.runtimeHost(host, log: String(cString: msg), level: level)
            },
            on_state: { ctx, state in
                guard let ctx else { return }
                let host = Unmanaged<RuntimeHost>.fromOpaque(ctx).takeUnretainedValue()
                if state == DC_STATE_STOPPED || state == DC_STATE_IDLE {
                    host.isRunning = false
                    host.active = nil
                }
                host.delegate?.runtimeHost(host, stateChanged: state)
            },
            on_error: { ctx, msg, file, line in
                guard let ctx else { return }
                let host = Unmanaged<RuntimeHost>.fromOpaque(ctx).takeUnretainedValue()
                host.delegate?.runtimeHost(host,
                                           error: msg.map { String(cString: $0) } ?? "unknown error",
                                           file: file.map { String(cString: $0) },
                                           line: Int(line))
            },
            container_view: { ctx in
                guard let ctx else { return nil }
                let host = Unmanaged<RuntimeHost>.fromOpaque(ctx).takeUnretainedValue()
                return Unmanaged.passUnretained(host.containerView).toOpaque()
            },
            jit_available: { _ in RuntimeHost.jitAvailable ? 1 : 0 },
            has_input_focus: { ctx in
                guard let ctx else { return 0 }
                return Unmanaged<RuntimeHost>.fromOpaque(ctx).takeUnretainedValue().inputFocused ? 1 : 0
            },
            debug_event: { ctx, json in
                guard let ctx, let json else { return }
                let host = Unmanaged<RuntimeHost>.fromOpaque(ctx).takeUnretainedValue()
                host.onDebugEvent?(String(cString: json))
            }
        ))
    }

    deinit {
        api.deinitialize(count: 1)
        api.deallocate()
    }

    private struct PendingRun { let runtime: RuntimeDescriptor; let project: URL; let debugConfig: String?; let arguments: [String] }
    private var pending: PendingRun?

    /// Schedules a run on the next run-loop turn (see class comment). With `debugConfig` (JSON:
    /// breakpoints, stopOnErrors) the run is debugged.
    func start(runtime: RuntimeDescriptor, project: URL, debugConfig: String? = nil, arguments: [String] = []) throws {
        guard !isRunning, pending == nil else { throw RuntimeError.busy }
        let vt = try runtime.load()
        if !initialised.contains(runtime.manifest.id) {
            let rc = vt.pointee.initialize?(api) ?? -1
            guard rc == 0 else { throw RuntimeError.initFailed(rc) }
            initialised.insert(runtime.manifest.id)
        }
        if debugConfig != nil && vt.pointee.debug_command == nil { throw RuntimeError.cannotDebug }
        pending = PendingRun(runtime: runtime, project: project, debugConfig: debugConfig, arguments: arguments)
        perform(#selector(runPending), with: nil, afterDelay: 0)
    }

    @objc private func runPending() {
        guard let p = pending, let vt = p.runtime.vtable else { return }
        pending = nil
        active = p.runtime
        isRunning = true
        isDebugging = p.debugConfig != nil
        vt.pointee.set_input_focus?(inputFocused ? 1 : 0)
        let b = containerView.bounds
        vt.pointee.container_resized?(Double(b.width), Double(b.height), Double(containerView.contentScaleFactor))

        let enableJIT: Int32 = (jitEnabledByUser && RuntimeHost.jitAvailable) ? 1 : 0
        // C strings for argv, alive for the whole (blocking) run.
        let argv = p.arguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        let rc: Int32 = p.project.path.withCString { dir in
            withOptionalCString(p.debugConfig) { debugConfig in
                argv.map { UnsafePointer<CChar>($0) }.withUnsafeBufferPointer { args in
                    var opts = dc_run_options(project_dir: dir, argv: args.isEmpty ? nil : args.baseAddress, argc: Int32(args.count),
                                              enable_jit: enableJIT, debug_config: debugConfig)
                    return vt.pointee.run?(&opts) ?? -1   // BLOCKS until the game exits
                }
            }
        }

        isRunning = false
        isDebugging = false
        active = nil
        delegate?.runtimeHost(self, log: p.runtime.isConsole ? "Exited with code \(rc)" : "Game exited with code \(rc)", level: DC_LOG_INFO)
        delegate?.runtimeHost(self, didExitWithCode: rc)
    }

    func stop() {
        if pending != nil {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runPending), object: nil)
            pending = nil
        }
        active?.vtable?.pointee.request_stop?()
    }

    /// A line typed into the console, for a console program's input.
    func sendInput(_ line: String) {
        line.withCString { active?.vtable?.pointee.send_input?($0) }
    }

    var acceptsInput: Bool { active?.vtable?.pointee.send_input != nil }

    /// A debugger command (JSON) for the running program.
    func sendDebugCommand(_ json: String) {
        json.withCString { active?.vtable?.pointee.debug_command?($0) }
    }

    func containerResized() {
        let b = containerView.bounds
        active?.vtable?.pointee.container_resized?(Double(b.width), Double(b.height), Double(containerView.contentScaleFactor))
    }
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
