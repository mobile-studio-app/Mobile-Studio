import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        dc_install_crash_handlers()
        ProjectStore.shared.bootstrap()
        RuntimeManager.shared.discover()
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
