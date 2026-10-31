import UIKit
import SafariServices

/// "Sign in with GitHub" sheet using the OAuth device flow, with a personal access token as a fallback.
/// Use `GitHubSignInViewController.present(from:completion:)`.
final class GitHubSignInViewController: UIViewController {
    private var completion: ((Bool) -> Void)?
    private let flow = GitHubDeviceFlow()
    private var code: GitHubDeviceFlow.Code?
    private weak var browser: SFSafariViewController?
    private var finished = false

    private let messageLabel = UILabel()
    private let codeLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    /// Presents the sign-in sheet. `completion(true)` once signed in, `false` if cancelled.
    static func present(from presenter: UIViewController, completion: @escaping (Bool) -> Void) {
        let vc = GitHubSignInViewController()
        vc.completion = completion
        let nav = UINavigationController(rootViewController: vc)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in to GitHub"
        view.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = UIColor(white: 0.8, alpha: 1)

        codeLabel.font = .monospacedSystemFont(ofSize: 34, weight: .semibold)
        codeLabel.textColor = .white
        codeLabel.textAlignment = .center

        var openCfg = UIButton.Configuration.filled()
        openCfg.title = "Copy Code & Open GitHub"
        openCfg.image = UIImage(systemName: "safari")
        openCfg.imagePadding = 8
        openCfg.cornerStyle = .large
        openCfg.baseBackgroundColor = UIColor(red: 0.14, green: 0.53, blue: 0.24, alpha: 1)
        openButton.configuration = openCfg
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = UIColor(white: 0.6, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        var tokenCfg = UIButton.Configuration.plain()
        tokenCfg.title = "Use a personal access token instead"
        tokenCfg.baseForegroundColor = UIColor(red: 0.22, green: 0.58, blue: 1.0, alpha: 1)
        let tokenButton = UIButton(configuration: tokenCfg)
        tokenButton.addTarget(self, action: #selector(tokenTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [messageLabel, codeLabel, openButton, spinner, statusLabel, tokenButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: openButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            openButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        guard GitHubOAuthConfig.isConfigured else {
            messageLabel.text = "Browser sign-in isn't set up in this build (no GitHub OAuth client ID). You can still sign in with a personal access token."
            codeLabel.isHidden = true
            openButton.isHidden = true
            return
        }
        requestCode()
    }

    private func requestCode() {
        messageLabel.text = "Getting a sign-in code from GitHub…"
        codeLabel.text = "––––-––––"
        codeLabel.isHidden = false
        openButton.isEnabled = false
        spinner.startAnimating()
        statusLabel.text = nil
        Task { @MainActor in
            do {
                let code = try await flow.requestCode()
                self.code = code
                messageLabel.text = "Enter this code on GitHub to let Mobile Studio access your repositories, including private ones."
                codeLabel.text = code.userCode
                openButton.isEnabled = true
                statusLabel.text = "Waiting for you to approve on GitHub…"
                flow.waitForToken(code) { [weak self] result in self?.received(result) }
            } catch {
                spinner.stopAnimating()
                messageLabel.text = error.localizedDescription
                codeLabel.isHidden = true
            }
        }
    }

    private func received(_ result: Result<String, Error>) {
        switch result {
        case .success(let token):
            statusLabel.text = "Approved. Finishing sign-in…"
            GitAccountManager.shared.signIn(token: token) { [weak self] result in
                switch result {
                case .success: self?.finish(true)
                case .failure(let error): self?.showFailure(error)
                }
            }
        case .failure(let error):
            showFailure(error)
        }
    }

    private func showFailure(_ error: Error) {
        spinner.stopAnimating()
        statusLabel.text = error.localizedDescription
        let retry = UIAlertController(title: "Sign-in Failed", message: error.localizedDescription, preferredStyle: .alert)
        retry.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(false) })
        retry.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in self?.requestCode() })
        if let browser {
            browser.dismiss(animated: true) { [weak self] in self?.present(retry, animated: true) }
        } else {
            present(retry, animated: true)
        }
    }

    private func finish(_ signedIn: Bool) {
        guard !finished else { return }
        finished = true
        flow.cancel()
        let completion = self.completion
        // Close the browser (if open) and this sheet.
        navigationController?.presentingViewController?.dismiss(animated: true) {
            completion?(signedIn)
        }
    }

    @objc private func openTapped() {
        guard let code else { return }
        UIPasteboard.general.string = code.userCode
        statusLabel.text = "Code copied. Paste it on GitHub, then approve. This page closes by itself."
        let safari = SFSafariViewController(url: code.verificationURL)
        safari.preferredControlTintColor = .white
        safari.preferredBarTintColor = UIColor(white: 0.1, alpha: 1)
        browser = safari
        present(safari, animated: true)
    }

    @objc private func cancelTapped() {
        finish(false)
    }

    @objc private func tokenTapped() {
        let alert = UIAlertController(
            title: "Personal Access Token",
            message: "Create one on GitHub (classic with the “repo” scope, or fine-grained with Contents read/write) and paste it here.",
            preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "ghp_… or github_pat_…"
            tf.isSecureTextEntry = true
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self, weak alert] _ in
            let token = alert?.textFields?.first?.text ?? ""
            GitAccountManager.shared.signIn(token: token) { result in
                switch result {
                case .success: self?.finish(true)
                case .failure(let error): self?.showFailure(error)
                }
            }
        })
        present(alert, animated: true)
    }
}
