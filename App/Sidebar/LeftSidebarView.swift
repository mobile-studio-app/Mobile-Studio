import UIKit

enum SidebarTab {
    case files
    case search
    case git
    case extensions
    case debug
    /// Views that extensions add (ExtensionViewsPanelView).
    case views
}

/// VS Code's side bar: a view title ("EXPLORER", "SEARCH", "SOURCE CONTROL") with its actions,
/// over the Explorer tree, the Search view or the Source Control view.
final class LeftSidebarView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onOpenFile: ((String) -> Void)?
    /// Open a file in the split editor beside the main one.
    var onOpenToSide: ((String) -> Void)?
    /// Open a file with a range selected: path, 1-based line, UTF-16 column and length.
    var onOpenMatch: ((String, Int, Int, Int) -> Void)?
    var onOpenDiff: ((DiffRequest) -> Void)?
    var onProjectChanged: (() -> Void)?
    /// Writes the editor's unsaved edits to disk, then calls back. Git and Search read files from disk.
    var onSaveEdits: ((@escaping () -> Void) -> Void)? {
        didSet {
            searchPanel.onSaveEdits = onSaveEdits
            scmPanel.onSaveEdits = onSaveEdits
        }
    }
    /// Files changed on disk (pull, discard, replace); the editor should re-read the open file.
    var onFilesChangedOnDisk: (() -> Void)?
    /// Pending Source Control changes, for the activity bar badge.
    var onChangeCountChanged: ((Int) -> Void)?
    /// The Explorer's ⋯ menu: back to the Welcome page, or straight to another project.
    var onShowWelcome: (() -> Void)?
    var onSwitchProject: ((URL) -> Void)?
    /// A file or folder was renamed (old path, new path) or deleted (new path nil), so open tabs follow.
    var onPathMoved: ((String, String?) -> Void)?

    private(set) var currentTab: SidebarTab = .files

    private let titleLabel = UILabel()
    private let headerActions = UIStackView()

    // Explorer
    private let explorerView = UIView()
    private let filesTableView = UITableView(frame: .zero, style: .plain)
    private var explorerRows: [ExplorerRow] = []
    /// Relative paths of expanded folders; saved per project.
    private var expandedFolders: Set<String> = []
    private var activeFile: String? = "main.lua"
    private var projectExpanded = true
    /// Git status letters for the Explorer, as VS Code decorates changed files.
    private var decorations: [String: GitFileStatus] = [:]

    private let searchPanel = SearchPanelView()
    private let scmPanel = SourceControlPanelView()
    private let extensionsPanel = ExtensionsPanelView()
    let debugPanel = RunDebugPanelView()
    let viewsPanel = ExtensionViewsPanelView()
    private var gitRefreshPending: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        loadExpandedFolders()
        setupView()
        refreshAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        backgroundColor = VS.sideBar

        let header = UIView()
        titleLabel.font = VS.font(11)
        titleLabel.textColor = VS.titleForeground
        headerActions.axis = .horizontal
        headerActions.spacing = 0
        headerActions.alignment = .center
        for view in [titleLabel, headerActions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }

        setupExplorer()
        wirePanels()

        let content = UIView()
        for panel in [explorerView, searchPanel, scmPanel, extensionsPanel, debugPanel, viewsPanel] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: content.topAnchor),
                panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        for view in [header, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: VS.headerHeight),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerActions.leadingAnchor, constant: -4),
            headerActions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            headerActions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setTab(.files)

        GitAccountManager.shared.onAuthStateChanged = { [weak self] in
            DispatchQueue.main.async { self?.scmPanel.refresh() }
        }
        // Saving in the editor updates Source Control, as it does in VS Code.
        NotificationCenter.default.addObserver(self, selector: #selector(projectFilesChanged),
                                               name: ProjectStore.filesDidChange, object: nil)
    }

    private func wirePanels() {
        debugPanel.onHeaderActionsChanged = { [weak self] in self?.refreshHeaderActions(for: .debug) }
        viewsPanel.onHeaderActionsChanged = { [weak self] in self?.refreshHeaderActions(for: .views) }
        searchPanel.onOpenMatch = { [weak self] path, line, column, length in
            self?.markActive(path)
            self?.onOpenMatch?(path, line, column, length)
        }
        searchPanel.onFilesChangedOnDisk = { [weak self] in self?.filesChangedOnDisk() }
        searchPanel.onHeaderActionsChanged = { [weak self] in self?.refreshHeaderActions(for: .search) }

        scmPanel.onOpenFile = { [weak self] path in
            self?.markActive(path)
            self?.onOpenFile?(path)
        }
        scmPanel.onOpenDiff = { [weak self] request in
            self?.markActive(request.path)
            self?.onOpenDiff?(request)
        }
        scmPanel.onRevealInExplorer = { [weak self] path in
            guard let self else { return }
            self.reveal(path)
            self.markActive(path)
            self.setTab(.files)
            self.onTabChangeRequest?(.files)
        }
        scmPanel.onFilesChangedOnDisk = { [weak self] in self?.filesChangedOnDisk() }
        scmPanel.onHeaderActionsChanged = { [weak self] in self?.refreshHeaderActions(for: .git) }
        scmPanel.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.onChangeCountChanged?(status.stagedFiles.count + status.changedFiles.count)
            self.updateDecorations(status)
        }
    }

    /// Asks the host to show a tab (so the activity bar follows), e.g. Reveal in Explorer View.
    var onTabChangeRequest: ((SidebarTab) -> Void)?

    private func filesChangedOnDisk() {
        onFilesChangedOnDisk?()
        refreshFiles()
        scmPanel.refresh()
    }

    @objc private func projectFilesChanged() {
        // Saves come quickly while typing with auto save on; refresh once things settle.
        gitRefreshPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scmPanel.refresh()
            self?.refreshFiles()
        }
        gitRefreshPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Title bar

    func setTab(_ tab: SidebarTab) {
        let changed = tab != currentTab
        currentTab = tab
        explorerView.isHidden = tab != .files
        searchPanel.isHidden = tab != .search
        scmPanel.isHidden = tab != .git
        extensionsPanel.isHidden = tab != .extensions
        debugPanel.isHidden = tab != .debug
        viewsPanel.isHidden = tab != .views
        switch tab {
        case .files:
            titleLabel.text = "EXPLORER"
            refreshFiles()
        case .search:
            titleLabel.text = "SEARCH"
            if changed { searchPanel.didBecomeVisible() }
        case .git:
            titleLabel.text = "SOURCE CONTROL"
            scmPanel.refresh()
        case .extensions:
            titleLabel.text = "EXTENSIONS"
            if changed { extensionsPanel.didBecomeVisible() }
        case .debug:
            titleLabel.text = "RUN AND DEBUG"
            if changed { debugPanel.didBecomeVisible() }
        case .views:
            titleLabel.text = viewsPanel.title.uppercased()
            if changed { viewsPanel.didBecomeVisible() }
        }
        refreshHeaderActions(for: tab)
    }

    private func refreshHeaderActions(for tab: SidebarTab) {
        guard tab == currentTab else { return }
        headerActions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let actions: [UIView]
        switch tab {
        case .files: actions = [explorerMoreButton()]
        case .search: actions = searchPanel.headerActions()
        case .git: actions = scmPanel.headerActions()
        case .extensions: actions = extensionsPanel.headerActions()
        case .debug: actions = debugPanel.headerActions()
        case .views: actions = viewsPanel.headerActions()
        }
        actions.forEach(headerActions.addArrangedSubview)
    }

    // MARK: - Explorer

    /// VS Code's File menu essentials: the Welcome page, recent projects and a new file.
    private func explorerMoreButton() -> UIView {
        let more = VSIconButton(.ellipsis, label: "More Actions")
        more.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            guard let self else { return done([]) }
            let current = ProjectStore.shared.currentProject.standardizedFileURL
            let recent = ProjectStore.shared.listProjects().filter { $0.url.standardizedFileURL != current }.prefix(10)
            var items: [UIMenuElement] = [
                UIAction(title: "Welcome Page", image: Codicon.home.image()) { [weak self] _ in self?.onShowWelcome?() },
            ]
            if !recent.isEmpty {
                items.append(UIMenu(title: "Open Recent", image: Codicon.history.image(), children: recent.map { project in
                    UIAction(title: project.name) { [weak self] _ in self?.onSwitchProject?(project.url) }
                }))
            }
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "New File...", image: Codicon.newFile.image()) { [weak self] _ in self?.promptNewFile() },
            ]))
            done(items)
        }])
        more.showsMenuAsPrimaryAction = true
        return more
    }

    private func setupExplorer() {
        filesTableView.backgroundColor = .clear
        filesTableView.separatorStyle = .none
        filesTableView.rowHeight = VS.rowHeight
        filesTableView.sectionHeaderTopPadding = 0
        filesTableView.dataSource = self
        filesTableView.delegate = self
        filesTableView.register(VSListCell.self, forCellReuseIdentifier: VSListCell.reuseID)
        filesTableView.register(VSPaneHeader.self, forHeaderFooterViewReuseIdentifier: VSPaneHeader.reuseID)
        filesTableView.translatesAutoresizingMaskIntoConstraints = false
        explorerView.addSubview(filesTableView)
        NSLayoutConstraint.activate([
            filesTableView.topAnchor.constraint(equalTo: explorerView.topAnchor),
            filesTableView.leadingAnchor.constraint(equalTo: explorerView.leadingAnchor),
            filesTableView.trailingAnchor.constraint(equalTo: explorerView.trailingAnchor),
            filesTableView.bottomAnchor.constraint(equalTo: explorerView.bottomAnchor),
        ])
    }

    @objc func refreshFiles() {
        let root = ExplorerNode()
        for folder in ProjectStore.shared.listFolders() {
            var node = root
            for part in folder.split(separator: "/").map(String.init) { node = node.child(part) }
        }
        for path in ProjectStore.shared.list() {
            let parts = path.split(separator: "/").map(String.init)
            guard let fileName = parts.last else { continue }
            var node = root
            for folder in parts.dropLast() {
                node = node.child(folder)
            }
            node.files.append(fileName)
        }
        explorerRows = []
        if projectExpanded { appendRows(of: root, prefix: "", depth: 0) }
        filesTableView.reloadData()
    }

    /// Folders first, then files, each sorted the way VS Code does; expanded folders recurse.
    private func appendRows(of node: ExplorerNode, prefix: String, depth: Int) {
        for name in node.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let path = prefix + name
            explorerRows.append(ExplorerRow(path: path, name: name, depth: depth, isFolder: true))
            if expandedFolders.contains(path), let child = node.folders[name] {
                appendRows(of: child, prefix: path + "/", depth: depth + 1)
            }
        }
        for name in node.files.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            explorerRows.append(ExplorerRow(path: prefix + name, name: name, depth: depth, isFolder: false))
        }
    }

    private func updateDecorations(_ status: GitStatus) {
        var map: [String: GitFileStatus] = [:]
        for file in status.stagedFiles { map[file.path] = file.status }
        for file in status.changedFiles { map[file.path] = file.status }
        guard map.count != decorations.count || map.contains(where: { decorations[$0.key] != $0.value }) else { return }
        decorations = map
        filesTableView.reloadData()
    }

    /// The colour of a folder holding changed files, as VS Code tints it.
    private func folderDecoration(_ path: String) -> GitFileStatus? {
        let prefix = path + "/"
        let statuses = decorations.filter { $0.key.hasPrefix(prefix) && $0.value != .deleted }.map(\.value)
        if statuses.contains(.modified) { return .modified }
        return statuses.first
    }

    private var expandedFoldersKey: String {
        "duocode.explorer.expanded." + ProjectStore.shared.currentProject.lastPathComponent
    }

    private func loadExpandedFolders() {
        expandedFolders = Set(UserDefaults.standard.stringArray(forKey: expandedFoldersKey) ?? [])
    }

    private func saveExpandedFolders() {
        UserDefaults.standard.set(Array(expandedFolders), forKey: expandedFoldersKey)
    }

    private func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
        }
        saveExpandedFolders()
        refreshFiles()
    }

    /// Expands every folder above `path` so its row is visible.
    private func reveal(_ path: String) {
        var folder = ""
        for part in path.split(separator: "/").dropLast().map(String.init) {
            folder = folder.isEmpty ? part : folder + "/" + part
            expandedFolders.insert(folder)
        }
        saveExpandedFolders()
    }

    private func markActive(_ path: String) {
        activeFile = path
        reveal(path)
        refreshFiles()
    }

    private func collapseAllFolders() {
        expandedFolders.removeAll()
        saveExpandedFolders()
        refreshFiles()
    }

    /// New File, in `folder` when it's given (the folder that was long-pressed).
    private func promptNewFile(in folder: String = "") {
        let alert = UIAlertController(title: "New File", message: "Enter a file name, such as player.lua or states/menu.lua.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "script.lua"
            field.text = folder.isEmpty ? nil : folder + "/"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.hasSuffix("/") else { return }
            if (try? ProjectStore.shared.resolve(name)).map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                // A comment in the file's own language, or nothing for languages without one.
                let comment: [String: String] = ["lua": "-- ", "py": "# ", "js": "// ", "glsl": "// ", "c": "// ", "cpp": "// ", "h": "// "]
                let ext = (name as NSString).pathExtension.lowercased()
                try? ProjectStore.shared.write(name, contents: comment[ext].map { $0 + (name as NSString).lastPathComponent + "\n" } ?? "")
            }
            self?.markActive(name)
            self?.onOpenFile?(name)
        })
        presenter?.present(alert, animated: true)
    }

    private func promptNewFolder(in folder: String = "") {
        let alert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "assets"
            field.text = folder.isEmpty ? nil : folder + "/"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: CharacterSet(charactersIn: " /\n")), !name.isEmpty else { return }
            do {
                try ProjectStore.shared.createFolder(name)
                self.expandedFolders.insert(name)
                var parent = (name as NSString).deletingLastPathComponent
                while !parent.isEmpty { self.expandedFolders.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
                self.saveExpandedFolders()
                self.refreshFiles()
            } catch {
                self.showError(error)
            }
        })
        presenter?.present(alert, animated: true)
    }

    private func promptRename(_ path: String, isFolder: Bool) {
        let name = (path as NSString).lastPathComponent
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            // Select the name without its extension, as VS Code does.
            DispatchQueue.main.async {
                let stem = isFolder ? name : (name as NSString).deletingPathExtension
                if let start = field.position(from: field.beginningOfDocument, offset: 0),
                   let end = field.position(from: start, offset: (stem.isEmpty ? name : stem).utf16.count) {
                    field.selectedTextRange = field.textRange(from: start, to: end)
                }
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let newName = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newName.isEmpty, newName != name else { return }
            let folder = (path as NSString).deletingLastPathComponent
            let target = folder.isEmpty ? newName : folder + "/" + newName
            // Unsaved edits go to the old path first, so they move with the file.
            let saveEdits = self.onSaveEdits ?? { $0() }
            saveEdits {
                do {
                    try ProjectStore.shared.move(path, to: target)
                    if isFolder, self.expandedFolders.remove(path) != nil { self.expandedFolders.insert(target) }
                    BreakpointStore.shared.move(path, to: target)
                    self.onPathMoved?(path, target)
                    if self.activeFile == path { self.activeFile = target }
                    self.refreshFiles()
                    self.scmPanel.refresh()
                } catch {
                    self.showError(error)
                }
            }
        })
        presenter?.present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: error.localizedDescription, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }

    private func confirmDelete(_ path: String) {
        let name = (path as NSString).lastPathComponent
        let alert = UIAlertController(title: "Are you sure you want to delete '\(name)'?",
                                      message: "You can restore it from Source Control if it was committed.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            try? ProjectStore.shared.delete(path)
            BreakpointStore.shared.move(path, to: nil)
            self?.onPathMoved?(path, nil)
            self?.refreshFiles()
            self?.scmPanel.refresh()
        })
        presenter?.present(alert, animated: true)
    }

    // MARK: - Project

    /// The current project changed: reset per-project state and reload every view.
    func projectDidChange() {
        activeFile = ProjectStore.shared.entryFile(in: ProjectStore.shared.currentProject)
        loadExpandedFolders()
        decorations = [:]
        searchPanel.reset()
        scmPanel.projectDidChange()
        refreshFiles()
    }

    func refreshAll() {
        refreshFiles()
        scmPanel.refresh()
    }

    // MARK: - Explorer table

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        explorerRows.count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        VS.paneHeaderHeight
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: VSPaneHeader.reuseID) as? VSPaneHeader else { return nil }
        header.configure(title: ProjectStore.shared.currentProject.lastPathComponent, expanded: projectExpanded, actions: [
            VSIconButton(.newFile, label: "New File...") { [weak self] in self?.promptNewFile() },
            VSIconButton(.newFolder, label: "New Folder...") { [weak self] in self?.promptNewFolder() },
            VSIconButton(.refresh, label: "Refresh Explorer") { [weak self] in self?.refreshFiles() },
            VSIconButton(.collapseAll, label: "Collapse Folders in Explorer") { [weak self] in self?.collapseAllFolders() },
        ])
        header.onToggle = { [weak self] in
            guard let self else { return }
            self.projectExpanded.toggle()
            self.refreshFiles()
        }
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VSListCell.reuseID, for: indexPath) as! VSListCell
        let row = explorerRows[indexPath.row]
        if row.isFolder {
            let status = folderDecoration(row.path)
            cell.configure(depth: row.depth, twistie: expandedFolders.contains(row.path), icon: nil,
                           title: row.name, titleColor: status.map(VS.color(for:)) ?? VS.foreground)
            if let status {
                let dot = UILabel()
                dot.text = "•"
                dot.font = VS.font(14, .bold)
                dot.textColor = VS.color(for: status)
                cell.setTrailing([dot])
            }
        } else {
            let (icon, color) = VS.fileIcon(row.name)
            let status = decorations[row.path]
            // A leaf keeps the twistie's space, so file icons line up under their folder's name.
            cell.configure(depth: row.depth, twistie: nil, icon: icon, iconColor: color, title: row.name,
                           titleColor: status.map(VS.color(for:)) ?? VS.foreground)
            if let status { cell.setTrailing([VSListCell.statusLetter(status)]) }
            cell.isMarked = row.path == activeFile
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = explorerRows[indexPath.row]
        if row.isFolder {
            toggleFolder(row.path)
        } else {
            activeFile = row.path
            tableView.reloadData()
            onOpenFile?(row.path)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let row = explorerRows[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(row.path)
            done(false)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let row = explorerRows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let folder = row.isFolder ? row.path : (row.path as NSString).deletingLastPathComponent
            var edit: [UIMenuElement] = [
                UIAction(title: "Rename...", image: Codicon.edit.image()) { _ in self?.promptRename(row.path, isFolder: row.isFolder) },
            ]
            if !row.isFolder {
                edit.append(UIAction(title: "Duplicate", image: Codicon.copy.image()) { _ in
                    guard let self, let copy = try? ProjectStore.shared.duplicate(row.path) else { return }
                    self.refreshFiles()
                    self.markActive(copy)
                    self.onOpenFile?(copy)
                })
            }
            let open: [UIMenuElement] = row.isFolder ? [] : [
                UIAction(title: "Open to the Side", image: Codicon.image(named: "split-horizontal")) { _ in self?.onOpenToSide?(row.path) },
            ]
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: open),
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "New File...", image: Codicon.newFile.image()) { _ in self?.promptNewFile(in: folder) },
                    UIAction(title: "New Folder...", image: Codicon.newFolder.image()) { _ in self?.promptNewFolder(in: folder) },
                ]),
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "Copy Path", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = row.path },
                ]),
                UIMenu(options: .displayInline, children: edit + [
                    UIAction(title: "Delete", image: Codicon.trash.image(), attributes: .destructive) { _ in self?.confirmDelete(row.path) },
                ]),
            ])
        }
    }
}

/// A visible row of the Explorer tree.
private struct ExplorerRow {
    /// Path relative to the project root (no trailing slash for folders).
    let path: String
    let name: String
    let depth: Int
    let isFolder: Bool
}

/// Folder node used while building the Explorer tree from flat file paths.
private final class ExplorerNode {
    var folders: [String: ExplorerNode] = [:]
    var files: [String] = []

    func child(_ name: String) -> ExplorerNode {
        if let existing = folders[name] { return existing }
        let node = ExplorerNode()
        folders[name] = node
        return node
    }
}
