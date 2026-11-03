import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        dc_install_crash_handlers()
        Diagnostics.shared.start()
        ProjectStore.shared.bootstrap()
        RuntimeManager.shared.discover()
        AIModelCatalog.removeRetired()
        ModelDownloadManager.shared.reconnect()
        AICompletionService.shared.start()
        AutomationServer.shared.applySetting()
        SigningCertificate.load()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelDownloadManager.shared.handleBackgroundEvents(for: identifier, completionHandler: completionHandler)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // A local model is the biggest thing we can give back; it reloads on the next suggestion.
        AICompletionService.shared.unload()
        AIChatService.shared.unload()
    }

    // MARK: - Menu bar

    /// The menu bar (iPadOS 26) and the shortcuts shown while ⌘ is held: VS Code's Go, Run and
    /// Terminal menus and more of its View menu. Each runs a Command Palette command (or the app's
    /// own: run, debug, stop) through IDEViewController.performMenuCommand. Shortcuts are only given
    /// to commands that aren't text editing, which the editor and text fields handle themselves.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let action = #selector(IDEViewController.performMenuCommand(_:))
        func item(_ title: String, _ command: String, _ input: String? = nil, _ modifiers: UIKeyModifierFlags = .command) -> UIMenuElement {
            guard let input else { return UICommand(title: title, action: action, propertyList: command) }
            return UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers, propertyList: command)
        }
        func group(_ children: [UIMenuElement]) -> UIMenu { UIMenu(options: .displayInline, children: children) }

        builder.insertChild(group([
            item("Command Palette…", "workbench.action.showCommands", "p", [.command, .shift]),
        ]), atStartOfMenu: .view)
        builder.insertChild(group([
            item("Explorer", "workbench.view.explorer", "e", [.command, .shift]),
            item("Search", "workbench.view.search", "f", [.command, .shift]),
            // ⌃⇧G is Toggle Game Focus (IDEViewController.keyCommands).
            item("Source Control", "workbench.view.scm"),
            item("Run and Debug", "workbench.view.debug"),
            item("Extensions", "workbench.view.extensions", "x", [.command, .shift]),
        ]), atEndOfMenu: .view)
        builder.insertChild(group([
            item("Problems", "workbench.actions.view.problems", "m", [.command, .shift]),
            item("Output", "workbench.action.output.toggleOutput", "u", [.command, .shift]),
            item("Debug Console", "workbench.debug.action.toggleRepl", "y", [.command, .shift]),
            item("Terminal", "workbench.action.terminal.toggleTerminal", "`", .control),
            item("Toggle Panel", "workbench.action.togglePanel", "j"),
            item("Chat", "workbench.action.chat.open", "i", [.control, .command]),
        ]), atEndOfMenu: .view)
        builder.insertChild(group([
            item("Split Editor", "workbench.action.splitEditor", "\\"),
            item("Markdown Preview", "markdown.showPreviewToSide"),
            item("Live Preview", "livePreview.start.preview.atFile"),
        ]), atEndOfMenu: .view)

        let go = UIMenu(title: "Go", identifier: UIMenu.Identifier("app.mobilestudio.go"), children: [
            group([
                item("Go to File…", "workbench.action.quickOpen", "p"),
                item("Go to Symbol in Editor…", "workbench.action.gotoSymbol", "o", [.command, .shift]),
                item("Go to Line/Column…", "workbench.action.gotoLine", "g", .control),
            ]),
            group([
                item("Go to Definition", "editor.action.revealDefinition"),
                item("Peek Definition", "editor.action.peekDefinition"),
                item("Go to References", "editor.action.referenceSearch.trigger"),
                item("Rename Symbol", "editor.action.rename"),
                item("Quick Fix…", "editor.action.quickFix"),
            ]),
        ])
        let run = UIMenu(title: "Run", identifier: UIMenu.Identifier("app.mobilestudio.run"), children: [
            group([
                item("Run", "app.run", "r"),
                item("Start Debugging", "app.debug", "d", [.command, .shift]),
                item("Stop", "app.stop"),
            ]),
            group([
                item("Toggle Breakpoint", "editor.debug.action.toggleBreakpoint"),
                item("Start REPL", "mobilestudio.startRepl"),
            ]),
            group([
                item("Run Task…", "workbench.action.tasks.runTask"),
                item("Run Build Task", "workbench.action.tasks.build", "b", [.command, .shift]),
            ]),
        ])
        let terminal = UIMenu(title: "Terminal", identifier: UIMenu.Identifier("app.mobilestudio.terminal"), children: [
            item("New Terminal", "workbench.action.terminal.new", "`", [.control, .shift]),
            item("Run Test Task", "workbench.action.tasks.test"),
        ])
        builder.insertSibling(go, afterMenu: .view)
        builder.insertSibling(run, afterMenu: go.identifier)
        builder.insertSibling(terminal, afterMenu: run.identifier)
        builder.insertChild(group([
            item("Settings…", "workbench.action.openSettings", ","),
            item("Open User Settings (JSON)", "workbench.action.openSettingsJson"),
            item("Open Keyboard Shortcuts (JSON)", "workbench.action.openGlobalKeybindingsFile"),
            item("Color Theme…", "workbench.action.selectTheme"),
        ]), atEndOfMenu: .file)
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = HostWindow(windowScene: windowScene)
        // The IDE chrome is dark-only; keep system UI (alerts, pickers, tables) matching it.
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = IDEViewController()
        window.makeKeyAndVisible()
        self.window = window

        if let url = connectionOptions.urlContexts.first?.url {
            handleIncomingURL(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "love" || ext == "zip" {
            (window?.rootViewController as? IDEViewController)?.importIncomingLoveArchive(url)
        }
    }
}

/// The app's window. While a game runs, its window sits just below this one and the game pane
/// here is transparent; touches on the pane go through to the game unless `passesThrough` says no.
final class HostWindow: UIWindow {
    var passesThrough: ((UIView?) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let passesThrough, passesThrough(hit) { return nil }
        return hit
    }
}
