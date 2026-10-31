import UIKit

/// VS Code's Extensions view: search Open VSX, install, and manage installed extensions.
/// Installing checks the extension first and refuses ones that can't work on iOS.
final class ExtensionsPanelView: UIView, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    var onHeaderActionsChanged: (() -> Void)?

    private enum Section { case installed, popular, results }

    private let searchField = VSTextField(placeholder: "Search Extensions in Open VSX")
    private let messageLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let progress = VSProgressBar()

    private var query = ""
    private var results: [MarketplaceExtension] = []
    private var popular: [MarketplaceExtension] = []
    private var sections: [Section] = []
    private var installing: Set<String> = []
    /// Extensions that can't work in DuoCode are left out of the lists unless this is on.
    private var showUnsupported = UserDefaults.standard.bool(forKey: "extensions.showUnsupported") {
        didSet { UserDefaults.standard.set(showUnsupported, forKey: "extensions.showUnsupported") }
    }
    private var checkTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var debounce: DispatchWorkItem?
    private static let iconCache = NSCache<NSURL, UIImage>()

    private var manager: ExtensionManager { .shared }

    override init(frame: CGRect) {
        super.init(frame: frame)
        searchField.delegate = self
        searchField.returnKeyType = .search
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        messageLabel.font = VS.font(12)
        messageLabel.textColor = VS.description
        messageLabel.numberOfLines = 0

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 62
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ExtensionCell.self, forCellReuseIdentifier: ExtensionCell.reuseID)
        tableView.register(VSPaneHeader.self, forHeaderFooterViewReuseIdentifier: VSPaneHeader.reuseID)

        let top = UIStackView(arrangedSubviews: [searchField, messageLabel])
        top.axis = .vertical
        top.spacing = 6
        top.isLayoutMarginsRelativeArrangement = true
        top.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        let column = UIStackView(arrangedSubviews: [progress, top, tableView])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsChanged), name: ExtensionManager.didChange, object: nil)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func headerActions() -> [UIView] {
        let refresh = VSIconButton(.refresh, label: "Refresh") { [weak self] in self?.runSearch() }
        let filter = VSIconButton(showUnsupported ? .eye : .filter, label: showUnsupported ? "Hide Unsupported Extensions" : "Show Unsupported Extensions") { [weak self] in
            guard let self else { return }
            self.showUnsupported.toggle()
            self.onHeaderActionsChanged?()
            self.rebuild()
        }
        let clear = VSIconButton(.clearAll, label: "Clear Search") { [weak self] in
            self?.searchField.text = ""
            self?.queryChanged()
        }
        return [filter, refresh, clear]
    }

    /// Called when the view opens: loads the popular list the first time.
    func didBecomeVisible() {
        if popular.isEmpty && query.isEmpty { runSearch() }
    }

    @objc private func extensionsChanged() {
        rebuild()
    }

    @objc private func queryChanged() {
        query = searchField.text ?? ""
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        runSearch()
        textField.resignFirstResponder()
        return true
    }

    private func runSearch() {
        searchTask?.cancel()
        let text = query
        progress.isAnimating = true
        searchTask = Task { [weak self] in
            do {
                let found = try await ExtensionManager.shared.search(text)
                await MainActor.run {
                    guard let self, text == self.query else { return }
                    if text.isEmpty { self.popular = found } else { self.results = found }
                    self.messageLabel.text = !text.isEmpty && found.isEmpty ? "No extensions found." : nil
                    self.progress.isAnimating = false
                    self.rebuild()
                    self.checkCompatibility(of: found)
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.progress.isAnimating = false
                    self.messageLabel.text = "Couldn't reach Open VSX: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Checks listed extensions a few at a time, so unsupported ones can be left out and partly
    /// supported ones marked. Answers are remembered, so this is quick after the first time.
    private func checkCompatibility(of list: [MarketplaceExtension]) {
        checkTask?.cancel()
        let pending = list.filter { manager.knownLevel(of: $0) == nil && !manager.isInstalled($0.id) }
        guard !pending.isEmpty else { return }
        progress.isAnimating = true
        checkTask = Task { @MainActor [weak self] in
            var index = 0
            while index < pending.count, !Task.isCancelled {
                let batch = pending[index..<min(index + 6, pending.count)]
                index += batch.count
                await withTaskGroup(of: Void.self) { group in
                    for ext in batch { group.addTask { _ = await ExtensionManager.shared.checkLevel(of: ext) } }
                }
                self?.rebuild()
            }
            if !Task.isCancelled { self?.progress.isAnimating = false }
        }
    }

    /// Whether a listed extension shows: installed, or checked and usable (or everything, when
    /// unsupported ones are shown). Unchecked ones wait for their check.
    private func isListed(_ ext: MarketplaceExtension) -> Bool {
        if showUnsupported || manager.isInstalled(ext.id) { return true }
        guard let level = manager.knownLevel(of: ext) else { return false }
        return level != .unsupported
    }

    private func rebuild() {
        sections = query.isEmpty ? [.installed, .popular] : [.results]
        messageLabel.isHidden = messageLabel.text == nil
        tableView.reloadData()
    }

    private func items(_ section: Section) -> [Any] {
        switch section {
        case .installed: return manager.installed.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .popular: return popular.filter(isListed)
        case .results: return results.filter(isListed)
        }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items(sections[section]).count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { VS.paneHeaderHeight }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: VSPaneHeader.reuseID) as? VSPaneHeader else { return nil }
        let title: String
        switch sections[section] {
        case .installed: title = "Installed (\(manager.installed.count))"
        case .popular: title = "Popular"
        case .results: title = "Open VSX"
        }
        header.configure(title: title, expanded: true, actions: [])
        header.onToggle = nil
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ExtensionCell.reuseID, for: indexPath) as! ExtensionCell
        let item = items(sections[indexPath.section])[indexPath.row]
        if let record = item as? InstalledExtension {
            cell.configure(title: record.displayName, publisher: record.publisher, summary: record.summary,
                           detail: record.enabled ? nil : "Disabled", warning: record.level == .partial)
            cell.iconView.image = manager.iconImage(of: record) ?? Codicon.extensions.image(28)
            cell.setAction(menu: manageMenu(record))
        } else if let ext = item as? MarketplaceExtension {
            let downloads = ext.downloadCount >= 1000 ? "\(ext.downloadCount / 1000)K" : "\(ext.downloadCount)"
            cell.configure(title: ext.displayName, publisher: ext.namespace + (ext.verified ? " ✓" : ""), summary: ext.summary,
                           detail: "\(downloads) installs", warning: false)
            loadIcon(ext.iconURL, into: cell)
            if manager.isInstalled(ext.id) {
                cell.setAction(menu: manager.installed.first { $0.id == ext.id }.map(manageMenu))
            } else if manager.knownLevel(of: ext) == .unsupported || manager.cachedCompatibility(ext.id)?.canInstall == false {
                cell.setUnsupported()
            } else {
                // Yellow: it installs, but not everything in it works here.
                let partial = manager.knownLevel(of: ext) == .partial || manager.cachedCompatibility(ext.id)?.level == .partial
                cell.setInstall(busy: installing.contains(ext.id), partial: partial) { [weak self] in self?.install(ext) }
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items(sections[indexPath.section])[indexPath.row]
        let namespace: String, name: String
        if let record = item as? InstalledExtension {
            let parts = record.id.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            namespace = parts[0]; name = parts[1]
        } else if let ext = item as? MarketplaceExtension {
            namespace = ext.namespace; name = ext.name
        } else { return }
        let detail = ExtensionDetailViewController(namespace: namespace, name: name)
        detail.onInstall = { [weak self] in self?.install(namespace: namespace, name: name, id: "\(namespace).\(name)".lowercased()) }
        presenter?.present(UINavigationController(rootViewController: detail), animated: true)
    }

    private func loadIcon(_ url: URL?, into cell: ExtensionCell) {
        cell.iconView.image = Codicon.extensions.image(28)
        guard let url else { return }
        if let cached = Self.iconCache.object(forKey: url as NSURL) {
            cell.iconView.image = cached
            return
        }
        cell.iconURL = url
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.iconCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async { if cell.iconURL == url { cell.iconView.image = image } }
        }.resume()
    }

    // MARK: - Actions

    private func manageMenu(_ record: InstalledExtension) -> UIMenu {
        var settingsItems: [UIMenuElement] = []
        let themes = EditorThemeCatalog.themes(of: record.id)
        if record.enabled && !themes.isEmpty {
            let current = AppSettings.shared.editorTheme
            settingsItems.append(UIMenu(title: "Set Color Theme", image: Codicon.symbolColor.image(), children: themes.map { theme in
                UIAction(title: theme.name, state: theme.id == current ? .on : .off) { _ in AppSettings.shared.editorTheme = theme.id }
            }))
        }
        if let manifest = ExtensionManager.shared.manifest(of: record.id),
           !ExtensionSettingsViewController.settings(in: manifest).isEmpty {
            settingsItems.append(UIAction(title: "Extension Settings", image: Codicon.gear.image()) { [weak self] _ in
                let controller = ExtensionSettingsViewController(extensionName: record.displayName, manifest: manifest)
                self?.presenter?.present(UINavigationController(rootViewController: controller), animated: true)
            })
        }
        return UIMenu(children: settingsItems + [
            UIAction(title: record.enabled ? "Disable" : "Enable", image: Codicon.extensions.image()) { _ in
                ExtensionManager.shared.setEnabled(record.id, !record.enabled)
            },
            UIAction(title: "Uninstall", image: Codicon.trash.image(), attributes: .destructive) { _ in
                ExtensionManager.shared.uninstall(record.id)
            },
        ])
    }

    private func install(_ ext: MarketplaceExtension) {
        install(namespace: ext.namespace, name: ext.name, id: ext.id)
    }

    private func install(namespace: String, name: String, id: String) {
        guard !installing.contains(id) else { return }
        installing.insert(id)
        progress.isAnimating = true
        tableView.reloadData()
        Task { [weak self] in
            var message: String?
            var skipped: [String] = []
            do {
                skipped = try await ExtensionManager.shared.install(namespace: namespace, name: name)
            } catch {
                message = error.localizedDescription
            }
            await MainActor.run {
                guard let self else { return }
                self.installing.remove(id)
                self.progress.isAnimating = !self.installing.isEmpty
                self.rebuild()
                if let message {
                    self.alert("Can't Install", message)
                } else if !skipped.isEmpty {
                    self.alert("Installed, with exceptions", "Some of the extensions it needs couldn't be installed:\n" + skipped.joined(separator: "\n"))
                } else {
                    self.offerTheme(after: id)
                }
            }
        }
    }

    /// Like VS Code, offer to switch to a colour theme an extension just added.
    private func offerTheme(after id: String) {
        let themes = EditorThemeCatalog.themes(of: id)
        guard let first = themes.first else { return }
        let alert = UIAlertController(title: "Set Color Theme?", message: "This extension adds \(themes.map(\.name).joined(separator: ", ")).", preferredStyle: .alert)
        for theme in themes.prefix(4) {
            alert.addAction(UIAlertAction(title: theme.name, style: .default) { _ in AppSettings.shared.editorTheme = theme.id })
        }
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        _ = first
        presenter?.present(alert, animated: true)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }
}

/// One extension in the list: icon, name, publisher, description and an action.
final class ExtensionCell: UITableViewCell {
    static let reuseID = "ExtensionCell"
    let iconView = UIImageView()
    var iconURL: URL?
    private let title = UILabel()
    private let publisher = UILabel()
    private let summary = UILabel()
    private let actionButton = UIButton(type: .custom)
    private var onAction: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = VS.listSelection
        selectedBackgroundView = selected

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = VS.icon
        iconView.layer.cornerRadius = 4
        iconView.clipsToBounds = true
        title.font = VS.font(13, .semibold)
        title.textColor = VS.foreground
        publisher.font = VS.font(12)
        publisher.textColor = VS.description
        summary.font = VS.font(12)
        summary.textColor = VS.description
        summary.lineBreakMode = .byTruncatingTail
        actionButton.titleLabel?.font = VS.font(12)
        actionButton.layer.cornerRadius = 2
        actionButton.contentEdgeInsets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [title, UIView(), actionButton])
        titleRow.spacing = 6
        titleRow.alignment = .center
        let text = UIStackView(arrangedSubviews: [titleRow, summary, publisher])
        text.axis = .vertical
        text.spacing = 1
        let row = UIStackView(arrangedSubviews: [iconView, text])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, publisher: String, summary: String, detail: String?, warning: Bool) {
        self.title.text = title
        self.publisher.text = [publisher, detail].compactMap { $0 }.joined(separator: "  ·  ")
        self.summary.text = (warning ? "⚠︎ " : "") + summary
        accessibilityLabel = title
    }

    func setInstall(busy: Bool, partial: Bool = false, action: @escaping () -> Void) {
        actionButton.menu = nil
        actionButton.showsMenuAsPrimaryAction = false
        actionButton.isEnabled = !busy
        actionButton.setTitle(busy ? "Installing…" : "Install", for: .normal)
        actionButton.setImage(nil, for: .normal)
        actionButton.setTitleColor(partial ? VS.warningButtonForeground : .white, for: .normal)
        actionButton.backgroundColor = partial ? VS.warningButtonBackground : VS.buttonBackground
        actionButton.accessibilityLabel = "Install \(title.text ?? "")" + (partial ? " (partly supported)" : "")
        onAction = action
    }

    func setAction(menu: UIMenu?) {
        onAction = nil
        actionButton.isEnabled = true
        actionButton.setTitle(nil, for: .normal)
        actionButton.setImage(Codicon.gear.image(16), for: .normal)
        actionButton.tintColor = VS.icon
        actionButton.backgroundColor = .clear
        actionButton.menu = menu
        actionButton.showsMenuAsPrimaryAction = true
        actionButton.accessibilityLabel = "Manage \(title.text ?? "")"
    }

    func setUnsupported() {
        onAction = nil
        actionButton.menu = nil
        actionButton.isEnabled = false
        actionButton.setImage(nil, for: .normal)
        actionButton.setTitle("Not supported", for: .normal)
        actionButton.setTitleColor(VS.description, for: .normal)
        actionButton.backgroundColor = .clear
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconURL = nil
        onAction = nil
    }
}
