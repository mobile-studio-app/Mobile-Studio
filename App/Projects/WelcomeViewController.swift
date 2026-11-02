import UIKit
import UniformTypeIdentifiers

/// VS Code-style Welcome page: start a new project, clone one from GitHub, import a .love file,
/// or reopen a recent project. Shown at launch and from the Home button in the activity bar.
final class WelcomeViewController: UIViewController, UIDocumentPickerDelegate {
    /// Called with the project to open; the presenter opens it and dismisses this screen.
    var onOpenProject: ((URL) -> Void)?
    /// The open project was deleted; the presenter loads the new current one behind this screen.
    var onCurrentProjectDeleted: (() -> Void)?

    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let columns = UIStackView()
    private let startColumn = UIStackView()
    private let recentColumn = UIStackView()
    private let recentList = UIStackView()
    private var accountButton = UIButton()
    private let busyOverlay = UIView()
    private let busyLabel = UILabel()

    private static let linkColor = UIColor(red: 0.22, green: 0.58, blue: 1.0, alpha: 1)
    private static let secondaryText = UIColor(white: 0.6, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        closeButton.tintColor = UIColor(white: 0.7, alpha: 1)
        closeButton.accessibilityLabel = "Close Welcome"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        view.addSubview(closeButton)

        content.axis = .vertical
        content.spacing = 32
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)

        let title = UILabel()
        title.text = "Mobile Studio"
        title.font = .systemFont(ofSize: 34, weight: .light)
        title.textColor = UIColor(white: 0.92, alpha: 1)
        let subtitle = UILabel()
        subtitle.text = "Write, run and debug code on your phone"
        subtitle.font = .systemFont(ofSize: 17, weight: .regular)
        subtitle.textColor = Self.secondaryText
        let header = UIStackView(arrangedSubviews: [title, subtitle])
        header.axis = .vertical
        header.spacing = 4
        content.addArrangedSubview(header)

        startColumn.axis = .vertical
        startColumn.spacing = 6
        startColumn.alignment = .leading
        startColumn.addArrangedSubview(sectionTitle("Start"))
        startColumn.addArrangedSubview(linkRow(symbol: "doc.badge.plus", title: "New Project…", action: #selector(newProjectTapped)))
        startColumn.addArrangedSubview(linkRow(symbol: "folder", title: "Open Folder from Files…", action: #selector(openFolderTapped)))
        startColumn.addArrangedSubview(linkRow(symbol: "arrow.down.circle", title: "Clone Git Repository…", action: #selector(cloneTapped)))
        startColumn.addArrangedSubview(linkRow(symbol: "tray.and.arrow.down", title: "Import .love File…", action: #selector(importTapped)))
        accountButton = linkRow(symbol: "person.crop.circle", title: "Sign in to GitHub…", action: #selector(accountTapped))
        startColumn.setCustomSpacing(16, after: startColumn.arrangedSubviews.last!)
        startColumn.addArrangedSubview(accountButton)
        reloadAccount()

        recentList.axis = .vertical
        recentList.spacing = 2
        recentList.alignment = .fill
        recentColumn.axis = .vertical
        recentColumn.spacing = 6
        recentColumn.addArrangedSubview(sectionTitle("Recent"))
        recentColumn.addArrangedSubview(recentList)

        columns.addArrangedSubview(startColumn)
        columns.addArrangedSubview(recentColumn)
        columns.spacing = 32
        columns.alignment = .top
        content.addArrangedSubview(columns)

        // For a first look: a game to play with, and the AI agent.
        let started = UIStackView(arrangedSubviews: [
            sectionTitle("Get Started"),
            linkRow(symbol: "gamecontroller", title: "Open Sample Game", action: #selector(sampleTapped)),
            linkRow(symbol: "sparkles", title: "Set Up AI Chat…", action: #selector(aiTapped)),
        ])
        let tip = UILabel()
        tip.text = "In the editor, the chat button at the top right (or ⌃⌘I) opens the AI agent: it reads and edits your project, runs it and fixes what it finds. It runs on this device with Apple Intelligence or a model you download."
        tip.font = .preferredFont(forTextStyle: .footnote)
        tip.adjustsFontForContentSizeCategory = true
        tip.textColor = Self.secondaryText
        tip.numberOfLines = 0
        started.addArrangedSubview(tip)
        started.axis = .vertical
        started.spacing = 6
        started.alignment = .leading
        content.addArrangedSubview(started)

        setupBusyOverlay()

        let readable = content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48)
        readable.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 56),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            content.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            readable,

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        reloadRecent()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Two columns when there's room, stacked on phones.
        let wide = view.bounds.width >= 600
        columns.axis = wide ? .horizontal : .vertical
        columns.distribution = wide ? .fillEqually : .fill
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Building blocks

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 19, weight: .regular)
        label.textColor = UIColor(white: 0.85, alpha: 1)
        return label
    }

    private func linkRow(symbol: String, title: String, action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        cfg.imagePadding = 10
        cfg.title = title
        cfg.baseForegroundColor = Self.linkColor
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 12)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = .systemFont(ofSize: 15)
            return a
        }
        let button = UIButton(configuration: cfg)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func reloadRecent() {
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let projects = ProjectStore.shared.listProjects()
        let current = ProjectStore.shared.currentProject.standardizedFileURL
        if projects.isEmpty {
            let empty = UILabel()
            empty.text = "No projects yet."
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = Self.secondaryText
            recentList.addArrangedSubview(empty)
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for project in projects {
            var cfg = UIButton.Configuration.plain()
            cfg.title = project.name
            let isCurrent = project.url.standardizedFileURL == current
            let place = project.isExternal ? "Files: \(project.url.deletingLastPathComponent().lastPathComponent)/\(project.name)" : "Projects/\(project.name)"
            cfg.subtitle = "\(place)  ·  \(isCurrent ? "open now" : formatter.localizedString(for: project.lastUsed, relativeTo: Date()))"
            cfg.titleAlignment = .leading
            cfg.baseForegroundColor = Self.linkColor
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = .systemFont(ofSize: 15)
                return a
            }
            cfg.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = .systemFont(ofSize: 12)
                a.foregroundColor = Self.secondaryText
                return a
            }
            let row = UIButton(configuration: cfg)
            row.contentHorizontalAlignment = .leading
            let url = project.url
            row.addAction(UIAction { [weak self] _ in self?.open(url) }, for: .touchUpInside)
            // Long-press the row, or tap its ⋯ button, for the project's actions.
            let menu = projectMenu(project)
            row.menu = menu
            row.showsMenuAsPrimaryAction = false

            var moreConfig = UIButton.Configuration.plain()
            moreConfig.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            moreConfig.baseForegroundColor = Self.secondaryText
            moreConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            let more = UIButton(configuration: moreConfig)
            more.menu = menu
            more.showsMenuAsPrimaryAction = true
            more.accessibilityLabel = "Actions for \(project.name)"
            more.setContentHuggingPriority(.required, for: .horizontal)

            let line = UIStackView(arrangedSubviews: [row, more])
            line.axis = .horizontal
            line.alignment = .center
            recentList.addArrangedSubview(line)
        }
    }

    private func projectMenu(_ project: ProjectInfo) -> UIMenu {
        let url = project.url
        let open = UIAction(title: "Open", image: UIImage(systemName: "folder")) { [weak self] _ in self?.open(url) }
        // A folder from Files is only taken off the list; its files stay where they are.
        if project.isExternal {
            return UIMenu(title: project.name, children: [
                open,
                UIAction(title: "Remove from Recent", image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                    if ProjectStore.shared.forgetExternalFolder(url) { self?.onCurrentProjectDeleted?() }
                    self?.reloadRecent()
                },
            ])
        }
        return UIMenu(title: project.name, children: [
            open,
            UIAction(title: "Delete Project…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDelete(project)
            },
        ])
    }

    private func confirmDelete(_ project: ProjectInfo) {
        var message = "This deletes the project folder and everything in it, including its Git history. This can't be undone."
        let git = GitManager.shared
        if git.isGitRepo(at: project.url) {
            let status = git.status(in: project.url)
            var unsaved: [String] = []
            if status.aheadCount > 0 { unsaved.append("\(status.aheadCount) commit\(status.aheadCount == 1 ? "" : "s") that aren't on GitHub") }
            let changes = status.stagedFiles.count + status.changedFiles.count
            if changes > 0 { unsaved.append("\(changes) uncommitted change\(changes == 1 ? "" : "s")") }
            if !unsaved.isEmpty {
                message += "\n\nIt has \(unsaved.joined(separator: " and ")), which will be lost."
            } else if status.remoteURL != nil {
                message += "\n\nEverything is on GitHub, so you can clone it again later."
            }
        }
        if project.url.standardizedFileURL == ProjectStore.shared.currentProject.standardizedFileURL {
            message += "\n\nIt's the project that's open now; Mobile Studio will switch to another one."
        }
        let alert = UIAlertController(title: "Delete “\(project.name)”?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                if try ProjectStore.shared.deleteProject(project.url) { self.onCurrentProjectDeleted?() }
                self.reloadRecent()
            } catch {
                self.showError(title: "Couldn't Delete Project", error)
            }
        })
        present(alert, animated: true)
    }

    private func setupBusyOverlay() {
        busyOverlay.backgroundColor = UIColor(white: 0, alpha: 0.55)
        busyOverlay.isHidden = true
        busyOverlay.translatesAutoresizingMaskIntoConstraints = false
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        busyLabel.textColor = .white
        busyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        let stack = UIStackView(arrangedSubviews: [spinner, busyLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        busyOverlay.addSubview(stack)
        view.addSubview(busyOverlay)
        NSLayoutConstraint.activate([
            busyOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            busyOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            busyOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            busyOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: busyOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: busyOverlay.centerYAnchor),
        ])
    }

    private func setBusy(_ message: String?) {
        busyLabel.text = message
        busyOverlay.isHidden = message == nil
    }

    // MARK: - Actions

    private func open(_ url: URL) {
        onOpenProject?(url)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func sampleTapped() {
        do {
            open(try ProjectStore.shared.createSampleGame())
        } catch {
            showError(title: "Couldn’t Create the Sample Game", error)
        }
    }

    /// Settings → AI, over the Welcome screen: Apple Intelligence, a model to download, or a cloud model.
    @objc private func aiTapped() {
        let nav = UINavigationController(rootViewController: SettingsViewController(page: .ai))
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func newProjectTapped() {
        let alert = UIAlertController(title: "New Project", message: "Name it, then pick its interpreter. You can change the interpreter later from the status bar.", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "my-game"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        for runtime in RuntimeManager.shared.selectableRuntimes {
            let kind = runtime.isConsole ? "Program" : "Game"
            let title = runtime.isAvailable ? "\(runtime.manifest.displayName) \(kind)" : "\(runtime.manifest.displayName) (coming soon)"
            let action = UIAlertAction(title: title, style: .default) { [weak self, weak alert] _ in
                let name = alert?.textFields?.first?.text ?? ""
                do {
                    self?.open(try ProjectStore.shared.createProject(named: name, runtime: runtime.manifest.id))
                } catch {
                    self?.showError(title: "Couldn’t Create Project", error)
                }
            }
            action.isEnabled = runtime.isAvailable
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func cloneTapped() {
        let signedIn = GitAccountManager.shared.isSignedIn
        let alert = UIAlertController(
            title: "Clone Git Repository",
            message: signedIn
                ? "Paste a GitHub repository URL."
                : "Paste a GitHub repository URL. Sign in under Source Control to clone private repositories.",
            preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "https://github.com/owner/repo"
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clone", style: .default) { [weak self, weak alert] _ in
            let urlString = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !urlString.isEmpty else { return }
            self?.clone(urlString)
        })
        present(alert, animated: true)
    }

    private func clone(_ urlString: String) {
        setBusy("Cloning…")
        GitManager.shared.clone(from: urlString) { [weak self] result in
            self?.setBusy(nil)
            switch result {
            case .success(let url):
                self?.open(url)
            case .failure(let error as NSError) where error.domain == "GitManager" && [401, 403, 404].contains(error.code):
                // GitHub answers 404 for private repos it won't show you, so offer to sign in and retry.
                self?.offerSignIn(thenClone: urlString, error: error)
            case .failure(let error):
                self?.showError(title: "Clone Failed", error)
            }
        }
    }

    private func offerSignIn(thenClone urlString: String, error: NSError) {
        let signedIn = GitAccountManager.shared.isSignedIn
        let login = GitAccountManager.shared.currentUser?.login ?? "your account"
        let alert = UIAlertController(
            title: "Can’t Access Repository",
            message: signedIn
                ? "GitHub didn’t give @\(login) access to this repository. Check the URL, or sign in with an account that can see it."
                : "The repository doesn’t exist or is private. Sign in to GitHub to clone private repositories.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: signedIn ? "Switch Account" : "Sign In", style: .default) { [weak self] _ in
            guard let self else { return }
            GitHubSignInViewController.present(from: self) { [weak self] ok in
                self?.reloadAccount()
                if ok { self?.clone(urlString) }
            }
        })
        present(alert, animated: true)
    }

    @objc private func accountTapped() {
        if GitAccountManager.shared.isSignedIn {
            let login = GitAccountManager.shared.currentUser?.login ?? "GitHub"
            let sheet = UIAlertController(title: "Signed in as @\(login)", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
                GitAccountManager.shared.signOut()
                self?.reloadAccount()
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = accountButton
            sheet.popoverPresentationController?.sourceRect = accountButton.bounds
            present(sheet, animated: true)
        } else {
            GitHubSignInViewController.present(from: self) { [weak self] _ in self?.reloadAccount() }
        }
    }

    private func reloadAccount() {
        let manager = GitAccountManager.shared
        accountButton.configuration?.title = manager.isSignedIn
            ? "GitHub: @\(manager.currentUser?.login ?? "signed in")"
            : "Sign in to GitHub…"
        accountButton.configuration?.image = UIImage(systemName: manager.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    }

    /// Which picker is showing: a folder to open in place, or a .love file to import.
    private var pickingFolder = false

    @objc private func openFolderTapped() {
        pickingFolder = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func importTapped() {
        pickingFolder = false
        var types: [UTType] = [.archive]
        if let loveType = UTType(filenameExtension: "love") {
            types.append(loveType)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if pickingFolder {
            do {
                open(try ProjectStore.shared.addExternalFolder(url))
            } catch {
                showError(title: "Couldn't Open Folder", error)
            }
            return
        }
        do {
            open(try ProjectStore.shared.importLoveArchive(from: url))
        } catch {
            showError(title: "Import Failed", error)
        }
    }

    private func showError(title: String, _ error: Error) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
