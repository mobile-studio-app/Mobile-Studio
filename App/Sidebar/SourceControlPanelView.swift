import UIKit

/// What the editor needs to show a diff. `modified == nil` means the working file itself,
/// which stays editable as it does in VS Code's working tree diff.
struct DiffRequest {
    let path: String
    let original: String
    let modified: String?
    let title: String
}

/// The Source Control view, laid out like VS Code's: message box, Commit / Sync button,
/// Staged Changes and Changes (list or tree), and the Graph.
final class SourceControlPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onOpenFile: ((String) -> Void)?
    var onOpenDiff: ((DiffRequest) -> Void)?
    var onRevealInExplorer: ((String) -> Void)?
    var onSaveEdits: ((@escaping () -> Void) -> Void)?
    var onFilesChangedOnDisk: (() -> Void)?
    var onHeaderActionsChanged: (() -> Void)?
    /// Fresh status after every refresh, for the activity bar badge and Explorer colours.
    var onStatusChanged: ((GitStatus) -> Void)?

    private enum Group: String {
        case merge, staged, changes
        var title: String {
            switch self {
            case .merge: return "Merge Changes"
            case .staged: return "Staged Changes"
            case .changes: return "Changes"
            }
        }
    }

    private enum Row {
        case group(Group, count: Int)
        case folder(Group, path: String, name: String, depth: Int)
        case file(Group, GitChangedFile, depth: Int)
        case commit(GitCommit, index: Int)
        case commitFile(GitCommit, GitChangedFile)
        case graphMessage(String)
    }

    private var project: URL { ProjectStore.shared.currentProject }
    private var isRepo = false
    private var status = GitStatus()
    private var commits: [GitCommit] = []
    private var changeRows: [Row] = []
    private var graphRows: [Row] = []
    private var collapsed: Set<String> = []
    private var expandedCommits: Set<String> = []
    private var commitFiles: [String: [GitChangedFile]] = [:]
    private var graphExpanded = true
    /// The row whose inline actions are showing (VS Code shows them on the hovered or focused row).
    private var focusedKey: String?
    private var refreshGeneration = 0
    private var isBusy = false { didSet { progress.isAnimating = isBusy; updateActionButton() } }
    private var viewAsTree = UserDefaults.standard.bool(forKey: "duocode.scm.tree") {
        didSet { UserDefaults.standard.set(viewAsTree, forKey: "duocode.scm.tree") }
    }

    private let progress = VSProgressBar()
    private let messageView = VSTextView()
    private let validationLabel = PaddedLabel()
    private let branchButton = UIButton(type: .custom)
    private let commitButton = VSButton(split: true)
    private let syncButton = VSButton(split: false)
    private let inputStack = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let welcome = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        messageView.onSubmit = { [weak self] in self?.commit() }
        messageView.onChange = { [weak self] in self?.setValidation(nil) }
        messageView.autocapitalizationType = .sentences

        validationLabel.font = VS.font(12)
        validationLabel.textColor = VS.foreground
        validationLabel.backgroundColor = VS.errorBackground
        validationLabel.layer.borderColor = VS.errorBorder.cgColor
        validationLabel.layer.borderWidth = 1
        validationLabel.numberOfLines = 0
        validationLabel.isHidden = true

        commitButton.mainButton.addAction(UIAction { [weak self] _ in self?.commit() }, for: .touchUpInside)
        commitButton.dropdownButton.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            done(self?.commitMenuItems() ?? [])
        }])
        commitButton.setTitle("Commit", icon: .check)
        syncButton.mainButton.addAction(UIAction { [weak self] _ in self?.primarySyncAction() }, for: .touchUpInside)
        syncButton.isHidden = true

        // The branch, as VS Code's status bar shows it; tapping it is "Checkout to...".
        branchButton.contentHorizontalAlignment = .leading
        branchButton.showsMenuAsPrimaryAction = true
        branchButton.isPointerInteractionEnabled = true
        branchButton.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            guard let self else { return done([]) }
            self.checkoutItems(done)
        }])
        branchButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        inputStack.axis = .vertical
        inputStack.spacing = 6
        inputStack.isLayoutMarginsRelativeArrangement = true
        inputStack.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        [branchButton, messageView, validationLabel, commitButton, syncButton].forEach(inputStack.addArrangedSubview)
        inputStack.setCustomSpacing(4, after: branchButton)
        inputStack.setCustomSpacing(0, after: messageView)
        inputStack.setCustomSpacing(6, after: validationLabel)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = VS.rowHeight
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(VSListCell.self, forCellReuseIdentifier: VSListCell.reuseID)
        tableView.register(VSPaneHeader.self, forHeaderFooterViewReuseIdentifier: VSPaneHeader.reuseID)

        // Shown when the project isn't a repository yet, like VS Code's Source Control welcome view.
        let welcomeText = UILabel()
        welcomeText.text = "This project doesn't have a Git repository yet. Initialize one to track changes, commit them and sync with GitHub."
        welcomeText.font = VS.font(13)
        welcomeText.textColor = VS.foreground
        welcomeText.numberOfLines = 0
        let initButton = VSButton(split: false)
        initButton.setTitle("Initialize Repository", icon: nil)
        initButton.mainButton.addAction(UIAction { [weak self] _ in self?.initializeRepository() }, for: .touchUpInside)
        welcome.axis = .vertical
        welcome.spacing = 12
        welcome.isLayoutMarginsRelativeArrangement = true
        welcome.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        welcome.addArrangedSubview(welcomeText)
        welcome.addArrangedSubview(initButton)
        welcome.isHidden = true

        let column = UIStackView(arrangedSubviews: [progress, inputStack, welcome, tableView])
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
    }

    // MARK: - Header

    func headerActions() -> [UIView] {
        guard isRepo else { return [] }
        let commit = VSIconButton(.check, label: "Commit") { [weak self] in self?.commit() }
        let refresh = VSIconButton(.refresh, label: "Refresh") { [weak self] in self?.refresh() }
        let more = VSIconButton(.ellipsis, label: "More Actions")
        more.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            done(self?.moreMenuItems() ?? [])
        }])
        more.showsMenuAsPrimaryAction = true
        return [commit, refresh, more]
    }

    private func moreMenuItems() -> [UIMenuElement] {
        let checkout = UIMenu(title: "Checkout to...", image: Codicon.gitBranch.image(), children: [
            AutomationMenus.deferred { [weak self] done in
                guard let self else { return done([]) }
                self.checkoutItems(done)
            },
        ])

        let noChanges = status.changedFiles.isEmpty
        let noStaged = status.stagedFiles.isEmpty
        var commitItems = commitMenuItems()
        commitItems.append(UIAction(title: "Commit Staged") { [weak self] _ in self?.commit(all: false) })
        commitItems.append(UIAction(title: "Commit All") { [weak self] _ in self?.commit(all: true) })
        commitItems.append(UIAction(title: "Undo Last Commit", attributes: canUndoLastCommit ? [] : [.disabled]) { [weak self] _ in
            self?.undoLastCommit()
        })
        let commitMenu = UIMenu(title: "Commit", children: commitItems)
        let discardAttributes: UIMenuElement.Attributes = noChanges ? [.disabled, .destructive] : [.destructive]
        let changesMenu = UIMenu(title: "Changes", children: [
            UIAction(title: "Stage All Changes", attributes: noChanges ? [.disabled] : []) { [weak self] _ in self?.stageAll() },
            UIAction(title: "Unstage All Changes", attributes: noStaged ? [.disabled] : []) { [weak self] _ in self?.unstageAll() },
            UIAction(title: "Discard All Changes", attributes: discardAttributes) { [weak self] _ in
                self?.confirmDiscard(self?.status.changedFiles ?? [])
            },
        ])
        let syncMenu = UIMenu(title: "Pull, Push", children: [
            UIAction(title: "Sync", image: Codicon.sync.image()) { [weak self] _ in self?.sync() },
            UIAction(title: "Pull", image: Codicon.repoPull.image()) { [weak self] _ in self?.pull() },
            UIAction(title: "Push", image: Codicon.repoPush.image()) { [weak self] _ in self?.push() },
        ])
        let branchMenu = UIMenu(title: "Branch", children: branchMenuItems())
        let stashMenu = UIMenu(title: "Stash", children: stashMenuItems())
        var mergeItems: [UIMenuElement] = []
        if status.mergingBranch != nil {
            mergeItems.append(UIAction(title: "Abort Merge", image: Codicon.discard.image(), attributes: .destructive) { [weak self] _ in
                self?.abortMerge()
            })
        }
        let remoteMenu = UIMenu(title: "Remote", children: [
            UIAction(title: status.remoteURL == nil ? "Add Remote..." : "Change Remote URL...") { [weak self] _ in self?.promptRemote(then: nil) },
        ])
        let viewMenu = UIMenu(title: "View & Sort", children: [
            UIAction(title: "View as List", state: viewAsTree ? .off : .on) { [weak self] _ in self?.setTreeView(false) },
            UIAction(title: "View as Tree", state: viewAsTree ? .on : .off) { [weak self] _ in self?.setTreeView(true) },
        ])
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Pull", image: Codicon.repoPull.image()) { [weak self] _ in self?.pull() },
                UIAction(title: "Push", image: Codicon.repoPush.image()) { [weak self] _ in self?.push() },
                checkout,
            ]),
            UIMenu(options: .displayInline, children: mergeItems + [commitMenu, changesMenu, syncMenu, branchMenu, remoteMenu, stashMenu]),
            UIMenu(options: .displayInline, children: [viewMenu]),
        ]
    }

    /// The Commit button's dropdown.
    private func commitMenuItems() -> [UIMenuElement] {
        [
            UIAction(title: "Commit", image: Codicon.check.image()) { [weak self] _ in self?.commit() },
            UIAction(title: "Commit (Amend)", attributes: canUndoLastCommit ? [] : [.disabled]) { [weak self] _ in self?.commit(amend: true) },
            UIAction(title: "Commit & Push", image: Codicon.repoPush.image()) { [weak self] _ in self?.commit(then: .push) },
            UIAction(title: "Commit & Sync", image: Codicon.sync.image()) { [weak self] _ in self?.commit(then: .sync) },
        ]
    }

    private var canUndoLastCommit: Bool { commits.first?.isOutgoing == true && commits.first?.hasSnapshot == true }

    private func setTreeView(_ tree: Bool) {
        viewAsTree = tree
        rebuildRows()
    }

    // MARK: - Refresh

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let root = project
        // Hashing can take a moment in big projects, so it happens off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let repo = GitManager.shared.isGitRepo(at: root)
            let status = GitManager.shared.status(in: root)
            let commits = GitManager.shared.history(in: root)
            DispatchQueue.main.async {
                guard generation == self.refreshGeneration else { return }
                let wasRepo = self.isRepo
                self.isRepo = repo
                self.status = status
                self.commits = commits
                self.commitFiles.removeAll()
                self.rebuildRows()
                self.onStatusChanged?(status)
                if wasRepo != repo { self.onHeaderActionsChanged?() }
            }
        }
    }

    func projectDidChange() {
        messageView.text = ""
        collapsed.removeAll()
        expandedCommits.removeAll()
        focusedKey = nil
        refresh()
    }

    private func rebuildRows() {
        inputStack.isHidden = !isRepo
        welcome.isHidden = isRepo
        tableView.isHidden = !isRepo
        messageView.placeholder = "Message (⌘↩ to commit on '\(status.currentBranch)')"
        updateBranchButton()
        updateActionButton()

        changeRows = []
        if !status.mergeConflicts.isEmpty { appendGroup(.merge, files: status.mergeConflicts) }
        if !status.stagedFiles.isEmpty { appendGroup(.staged, files: status.stagedFiles) }
        if !status.changedFiles.isEmpty { appendGroup(.changes, files: status.changedFiles) }

        graphRows = []
        if graphExpanded {
            if commits.isEmpty {
                graphRows.append(.graphMessage("No commits yet."))
            }
            for (index, commit) in commits.enumerated() {
                graphRows.append(.commit(commit, index: index))
                guard expandedCommits.contains(commit.id) else { continue }
                let files = commitFiles[commit.id] ?? GitManager.shared.changes(inCommit: commit.id, in: project)
                commitFiles[commit.id] = files
                files.forEach { graphRows.append(.commitFile(commit, $0)) }
            }
        }
        tableView.reloadData()
    }

    private func groupKey(_ group: Group) -> String { "g:" + group.rawValue }
    private func folderKey(_ group: Group, _ path: String) -> String { "d:\(group.rawValue):\(path)" }
    private func fileKey(_ group: Group, _ path: String) -> String { "f:\(group.rawValue):\(path)" }

    private func appendGroup(_ group: Group, files: [GitChangedFile]) {
        changeRows.append(.group(group, count: files.count))
        guard !collapsed.contains(groupKey(group)) else { return }
        if viewAsTree {
            let root = FolderNode(name: "", path: "")
            for (index, file) in files.enumerated() {
                var node = root
                for part in file.path.split(separator: "/").dropLast().map(String.init) { node = node.child(part) }
                node.files.append(index)
            }
            root.compact()
            appendTree(root, group: group, files: files, depth: 1)
        } else {
            files.forEach { changeRows.append(.file(group, $0, depth: 1)) }
        }
    }

    private func appendTree(_ node: FolderNode, group: Group, files: [GitChangedFile], depth: Int) {
        for child in node.sortedChildren {
            changeRows.append(.folder(group, path: child.path, name: child.name, depth: depth))
            if !collapsed.contains(folderKey(group, child.path)) { appendTree(child, group: group, files: files, depth: depth + 1) }
        }
        for index in node.files.sorted(by: { files[$0].path.localizedStandardCompare(files[$1].path) == .orderedAscending }) {
            changeRows.append(.file(group, files[index], depth: depth))
        }
    }

    // MARK: - Primary button

    private enum After { case none, push, sync }

    private func updateActionButton() {
        let ahead = status.aheadCount
        if isRepo && status.isClean && !commits.isEmpty && (status.remoteURL == nil || !status.hasUpstream) {
            syncButton.setTitle("Publish Branch", icon: .cloudUpload)
            showSync(true)
        } else if isRepo && status.isClean && ahead > 0 {
            syncButton.setTitle("Sync Changes \(ahead)↑", icon: .sync)
            showSync(true)
        } else {
            showSync(false)
            commitButton.isEnabled = !status.isClean && !isBusy
        }
        syncButton.isEnabled = !isBusy
    }

    private func showSync(_ sync: Bool) {
        syncButton.isHidden = !sync
        commitButton.isHidden = sync
    }

    private func primarySyncAction() {
        if status.remoteURL == nil {
            promptRemote { [weak self] in self?.push() }
        } else if !status.hasUpstream {
            push()   // publish the branch
        } else {
            sync()
        }
    }

    // MARK: - Commit

    private func setValidation(_ message: String?) {
        guard validationLabel.text != message else { return }
        validationLabel.text = message
        validationLabel.isHidden = message == nil
    }

    /// `all: nil` commits what's staged, or asks to stage everything when nothing is (VS Code's smart commit).
    private func commit(all: Bool? = nil, amend: Bool = false, then after: After = .none) {
        saveEdits { [weak self] in
            guard let self else { return }
            let message = self.messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = GitManager.shared.status(in: self.project)
            self.status = status
            if message.isEmpty && !amend {
                self.setValidation("Enter a commit message to commit.")
                _ = self.messageView.becomeFirstResponder()
                return
            }
            if status.isClean && !amend {
                self.showAlert("There are no changes to commit.")
                return
            }
            if all == nil && status.stagedFiles.isEmpty && !status.changedFiles.isEmpty && !amend {
                if AppSettings.shared.smartCommit {
                    self.performCommit(message: message, all: true, amend: amend, then: after)
                    return
                }
                let alert = UIAlertController(
                    title: "There are no staged changes to commit.",
                    message: "Would you like to stage all your changes and commit them directly?",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Yes", style: .default) { _ in
                    self.performCommit(message: message, all: true, amend: amend, then: after)
                })
                alert.addAction(UIAlertAction(title: "Always", style: .default) { _ in
                    AppSettings.shared.smartCommit = true
                    self.performCommit(message: message, all: true, amend: amend, then: after)
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                self.presenter?.present(alert, animated: true)
                return
            }
            self.performCommit(message: message, all: all ?? false, amend: amend, then: after)
        }
    }

    private func performCommit(message: String, all: Bool, amend: Bool, then after: After) {
        do {
            try GitManager.shared.commit(message: message, all: all, amend: amend, in: project)
            messageView.text = ""
            messageView.resignFirstResponder()
            setValidation(nil)
            refresh()
            switch after {
            case .none: break
            case .push: push()
            case .sync: sync()
            }
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func undoLastCommit() {
        do {
            let message = try GitManager.shared.undoLastCommit(in: project)
            if messageView.text.isEmpty { messageView.text = message }
            refresh()
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    // MARK: - Staging and discarding

    private func stage(_ paths: [String]) {
        saveEdits { [weak self] in
            guard let self else { return }
            self.perform { try GitManager.shared.stage(paths, in: self.project) }
        }
    }

    private func unstage(_ paths: [String]) {
        perform { try GitManager.shared.unstage(paths, in: project) }
    }

    private func stageAll() {
        saveEdits { [weak self] in
            guard let self else { return }
            self.perform { try GitManager.shared.stageAll(in: self.project) }
        }
    }

    private func unstageAll() {
        perform { try GitManager.shared.unstageAll(in: project) }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { showAlert(error.localizedDescription) }
        refresh()
    }

    /// VS Code's discard confirmations, which warn louder about deleting untracked files.
    private func confirmDiscard(_ files: [GitChangedFile]) {
        guard !files.isEmpty else { return }
        let untracked = files.filter { $0.status == .untracked }
        let title: String
        let button: String
        if files.count == 1, let file = files.first {
            let name = (file.path as NSString).lastPathComponent
            if file.status == .untracked {
                title = "Are you sure you want to DELETE '\(name)'?"
                button = "Delete File"
            } else {
                title = "Are you sure you want to discard changes in '\(name)'?"
                button = "Discard File"
            }
        } else {
            title = "Are you sure you want to discard ALL changes in \(files.count) files?"
            button = "Discard All \(files.count) Files"
        }
        let message = untracked.isEmpty
            ? "This is IRREVERSIBLE! Your current working set will be FOREVER LOST if you proceed."
            : "This is IRREVERSIBLE! \(untracked.count == 1 ? "This file" : "\(untracked.count) untracked files") will be FOREVER LOST if you proceed."
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: button, style: .destructive) { [weak self] _ in
            guard let self else { return }
            // Write the editor's edits first, so a discarded file isn't saved again afterwards.
            self.saveEdits {
                self.perform {
                    for file in files { try GitManager.shared.discardChanges(for: file.path, in: self.project) }
                }
                self.onFilesChangedOnDisk?()
            }
        })
        presenter?.present(alert, animated: true)
    }

    // MARK: - Branches and remote

    // MARK: Checkout

    /// "Checkout to...": new branch, local branches, then GitHub's branches (fetched when the menu opens).
    private func checkoutItems(_ done: @escaping ([UIMenuElement]) -> Void) {
        let local = GitManager.shared.branches(in: project)
        let current = status.currentBranch
        var items: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Create New Branch...", image: Codicon.add.image()) { [weak self] _ in self?.promptNewBranch(from: nil) },
                UIMenu(title: "Create New Branch From...", children: local.map { name in
                    UIAction(title: name) { [weak self] _ in self?.promptNewBranch(from: name) }
                }),
            ]),
            UIMenu(title: "Branches", options: .displayInline, children: local.map { name in
                UIAction(title: name, image: Codicon.gitBranch.image(), state: name == current ? .on : .off) { [weak self] _ in
                    self?.checkout(name)
                }
            }),
        ]
        guard status.remoteURL != nil, GitAccountManager.shared.isSignedIn else { return done(items) }
        GitManager.shared.remoteBranches(in: project) { [weak self] result in
            let remote = ((try? result.get()) ?? []).filter { !local.contains($0) }
            if !remote.isEmpty {
                items.append(UIMenu(title: "Remote Branches", options: .displayInline, children: remote.map { name in
                    UIAction(title: "origin/\(name)", image: Codicon.cloudUpload.image()) { [weak self] _ in self?.checkoutRemote(name) }
                }))
            }
            _ = self
            done(items)
        }
    }

    private func checkout(_ branch: String, force: Bool = false) {
        saveEdits { [weak self] in
            guard let self else { return }
            do {
                try GitManager.shared.checkout(branch, force: force, in: self.project)
                self.didSwitchBranch()
            } catch let error as NSError where error.code == GitManager.checkoutConflictCode {
                self.confirmCheckoutConflict(branch, error: error)
            } catch {
                self.showAlert(error.localizedDescription)
            }
        }
    }

    /// VS Code's choices when local changes are in the way of a checkout.
    private func confirmCheckoutConflict(_ branch: String, error: NSError) {
        let paths = error.userInfo["paths"] as? [String] ?? []
        let alert = UIAlertController(title: "Your local changes would be overwritten by checkout.",
                                      message: paths.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Stash & Checkout", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try GitManager.shared.stash(in: self.project)
                try GitManager.shared.checkout(branch, in: self.project)
                self.didSwitchBranch()
            } catch {
                self.showAlert(error.localizedDescription)
                self.didSwitchBranch()
            }
        })
        alert.addAction(UIAlertAction(title: "Force Checkout", style: .destructive) { [weak self] _ in self?.checkout(branch, force: true) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter?.present(alert, animated: true)
    }

    private func checkoutRemote(_ name: String) {
        guard !isBusy else { return }
        saveEdits { [weak self] in
            guard let self else { return }
            self.isBusy = true
            GitManager.shared.checkoutRemoteBranch(name, in: self.project) { result in
                self.isBusy = false
                switch result {
                case .success:
                    self.didSwitchBranch()
                case .failure(let error as NSError) where error.code == GitManager.checkoutConflictCode:
                    self.refresh()
                    self.confirmCheckoutConflict(name, error: error)
                case .failure(let error):
                    self.refresh()
                    self.showGitError(error)
                }
            }
        }
    }

    /// Files changed on disk: the editor re-reads the open file and every view refreshes.
    private func didSwitchBranch() {
        onFilesChangedOnDisk?()
        refresh()
    }

    private func updateBranchButton() {
        var title = status.currentBranch
        if !status.isClean { title += "*" }
        if let merging = status.mergingBranch { title += "  (merging \(merging))" }
        let text = NSMutableAttributedString(attributedString: Codicon.gitBranch.attributed(14, color: VS.description))
        text.append(NSAttributedString(string: " " + title, attributes: [.font: VS.font(12), .foregroundColor: VS.description]))
        if status.aheadCount > 0 {
            text.append(NSAttributedString(string: "  \(status.aheadCount)", attributes: [.font: VS.font(12), .foregroundColor: VS.description]))
            text.append(Codicon.arrowUp.attributed(13, color: VS.description))
        }
        if status.stashCount > 0 {
            text.append(NSAttributedString(string: "   \(status.stashCount) stashed", attributes: [.font: VS.font(12), .foregroundColor: VS.description]))
        }
        branchButton.setAttributedTitle(text, for: .normal)
        branchButton.accessibilityLabel = "Branch \(status.currentBranch). Checkout to another branch"
    }

    // MARK: Branch

    private func branchMenuItems() -> [UIMenuElement] {
        let current = status.currentBranch
        let others = GitManager.shared.branches(in: project).filter { $0 != current }
        var items: [UIMenuElement] = [
            UIMenu(title: "Merge Branch...", image: Codicon.gitBranch.image(), children: others.map { name in
                UIAction(title: name) { [weak self] _ in self?.merge(name) }
            }),
            UIAction(title: "Create Branch...", image: Codicon.add.image()) { [weak self] _ in self?.promptNewBranch(from: nil) },
            UIMenu(title: "Create Branch From...", children: GitManager.shared.branches(in: project).map { name in
                UIAction(title: name) { [weak self] _ in self?.promptNewBranch(from: name) }
            }),
            UIAction(title: "Rename Branch...", image: Codicon.edit.image()) { [weak self] _ in self?.promptRenameBranch() },
            UIMenu(title: "Delete Branch...", image: Codicon.trash.image(), children: others.map { name in
                UIAction(title: name, attributes: .destructive) { [weak self] _ in self?.confirmDeleteBranch(name) }
            }),
        ]
        if status.remoteURL != nil && !status.hasUpstream {
            items.append(UIAction(title: "Publish Branch", image: Codicon.cloudUpload.image()) { [weak self] _ in self?.push() })
        }
        return items
    }

    private func promptNewBranch(from source: String?) {
        let alert = UIAlertController(title: source.map { "Create Branch From '\($0)'" } ?? "Create Branch",
                                      message: "Please provide a new branch name.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Branch name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self.saveEdits {
                do {
                    let start = source.flatMap { GitManager.shared.tip(of: $0, in: self.project) }
                    try GitManager.shared.createBranch(name, from: start, in: self.project)
                    self.didSwitchBranch()
                } catch {
                    self.showAlert(error.localizedDescription)
                }
            }
        })
        presenter?.present(alert, animated: true)
    }

    private func promptRenameBranch() {
        let current = status.currentBranch
        let alert = UIAlertController(title: "Rename Branch", message: "Please provide a new name for '\(current)'.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            self.perform { try GitManager.shared.renameBranch(current, to: name, in: self.project) }
        })
        presenter?.present(alert, animated: true)
    }

    private func confirmDeleteBranch(_ name: String) {
        do {
            try GitManager.shared.deleteBranch(name, in: project)
            refresh()
        } catch let error as NSError where error.code == 409 {
            let alert = UIAlertController(title: "The branch '\(name)' is not fully merged. Delete anyway?",
                                          message: "Its commits aren't on another branch or on GitHub, so they'll be lost.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete Branch", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.perform { try GitManager.shared.deleteBranch(name, force: true, in: self.project) }
            })
            presenter?.present(alert, animated: true)
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    // MARK: Merge

    private func merge(_ branch: String) {
        saveEdits { [weak self] in
            guard let self else { return }
            do {
                switch try GitManager.shared.merge(branch, in: self.project) {
                case .upToDate:
                    self.toast("Already up to date.")
                case .fastForward, .merged:
                    self.didSwitchBranch()
                case .conflicts(let paths):
                    self.didSwitchBranch()
                    self.messageView.text = GitManager.shared.mergeMessage(in: self.project) ?? ""
                    self.showAlert("Merging '\(branch)' left conflicts in \(paths.joined(separator: ", ")). Edit each file to keep what you want (remove the <<<<<<<, ======= and >>>>>>> lines), stage it, then commit.")
                }
            } catch {
                self.showAlert(error.localizedDescription)
            }
        }
    }

    private func abortMerge() {
        perform { try GitManager.shared.abortMerge(in: project) }
        messageView.text = ""
        onFilesChangedOnDisk?()
    }

    // MARK: Stash

    private func stashMenuItems() -> [UIMenuElement] {
        let stashes = GitManager.shared.stashes(in: project)
        let none: UIMenuElement.Attributes = stashes.isEmpty ? [.disabled] : []
        let list = { (title: String, action: @escaping (Int) -> Void) -> UIMenu in
            UIMenu(title: title, children: stashes.map { stash in
                UIAction(title: "stash@{\(stash.index)}: \(stash.message)") { _ in action(stash.index) }
            })
        }
        return [
            UIAction(title: "Stash", attributes: status.isClean ? [.disabled] : []) { [weak self] _ in self?.promptStash() },
            UIAction(title: "Pop Latest Stash", attributes: none) { [weak self] _ in self?.applyStash(0, drop: true) },
            UIAction(title: "Apply Latest Stash", attributes: none) { [weak self] _ in self?.applyStash(0, drop: false) },
            list("Pop Stash...") { [weak self] index in self?.applyStash(index, drop: true) },
            list("Apply Stash...") { [weak self] index in self?.applyStash(index, drop: false) },
            list("Drop Stash...") { [weak self] index in
                guard let self else { return }
                self.perform { try GitManager.shared.dropStash(index, in: self.project) }
            },
            UIAction(title: "Drop All Stashes...", attributes: stashes.isEmpty ? [.disabled, .destructive] : [.destructive]) { [weak self] _ in
                self?.confirmDropAllStashes()
            },
        ]
    }

    private func promptStash() {
        let alert = UIAlertController(title: "Stash", message: "Message (optional)", preferredStyle: .alert)
        alert.addTextField { field in field.placeholder = "Stash message" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Stash", style: .default) { [weak self] _ in
            guard let self else { return }
            let message = alert.textFields?.first?.text ?? ""
            self.saveEdits {
                self.perform { try GitManager.shared.stash(message: message, in: self.project) }
                self.onFilesChangedOnDisk?()
            }
        })
        presenter?.present(alert, animated: true)
    }

    private func applyStash(_ index: Int, drop: Bool) {
        saveEdits { [weak self] in
            guard let self else { return }
            self.perform { try GitManager.shared.applyStash(index, drop: drop, in: self.project) }
            self.onFilesChangedOnDisk?()
        }
    }

    private func confirmDropAllStashes() {
        let count = GitManager.shared.stashes(in: project).count
        let alert = UIAlertController(title: "Are you sure you want to drop ALL stashes?",
                                      message: "There \(count == 1 ? "is 1 stash" : "are \(count) stashes") that will be dropped. This can't be undone.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Drop All Stashes", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.perform { try GitManager.shared.dropAllStashes(in: self.project) }
        })
        presenter?.present(alert, animated: true)
    }

    private func promptRemote(then: (() -> Void)?) {
        let alert = UIAlertController(title: status.remoteURL == nil ? "Add Remote" : "Change Remote",
                                      message: "The GitHub repository to push to and pull from.", preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.status.remoteURL
            field.placeholder = "https://github.com/owner/repo"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self, let url = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
            GitManager.shared.setRemoteURL(url, in: self.project)
            self.refresh()
            then?()
        })
        presenter?.present(alert, animated: true)
    }

    private func initializeRepository() {
        do {
            try GitManager.shared.initRepo(at: project)
        } catch {
            showAlert(error.localizedDescription)
        }
        refresh()
        onHeaderActionsChanged?()
    }

    // MARK: - Pull, push, sync

    private func pull(then next: (() -> Void)? = nil) {
        guard !isBusy else { return }
        saveEdits { [weak self] in
            guard let self else { return }
            self.isBusy = true
            GitManager.shared.pull(in: self.project) { result in
                self.isBusy = false
                switch result {
                case .success(let count):
                    if count > 0 { self.onFilesChangedOnDisk?() }
                    self.refresh()
                    if let next { next() } else if count == 0 { self.toast("Already up to date.") }
                case .failure(let error):
                    self.refresh()
                    self.showGitError(error)
                }
            }
        }
    }

    private func push() {
        guard !isBusy else { return }
        guard status.remoteURL != nil else {
            promptRemote { [weak self] in self?.push() }
            return
        }
        saveEdits { [weak self] in
            guard let self else { return }
            self.isBusy = true
            GitManager.shared.push(in: self.project) { result in
                self.isBusy = false
                self.refresh()
                switch result {
                case .success(let count):
                    if count == 0 { self.toast("Everything is already on GitHub.") }
                case .failure(let error):
                    self.showGitError(error)
                }
            }
        }
    }

    /// Pull, then push, as VS Code's Sync does.
    private func sync() {
        pull { [weak self] in self?.push() }
    }

    private func showGitError(_ error: Error) {
        let alert = UIAlertController(title: "Git", message: error.localizedDescription, preferredStyle: .alert)
        if (error as NSError).code == 401 {
            alert.addAction(UIAlertAction(title: "Sign in to GitHub", style: .default) { [weak self] _ in
                guard let self, let presenter = self.presenter else { return }
                GitHubSignInViewController.present(from: presenter) { _ in self.refresh() }
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter?.present(alert, animated: true)
    }

    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }

    /// A brief note in the message area, for results that need no decision.
    private func toast(_ message: String) {
        setValidation(nil)
        let label = PaddedLabel()
        label.text = message
        label.font = VS.font(12)
        label.textColor = VS.foreground
        label.backgroundColor = VS.hex(0x063B49)
        label.layer.borderColor = VS.focusBorder.cgColor
        label.layer.borderWidth = 1
        label.numberOfLines = 0
        inputStack.addArrangedSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.2, animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
        }
    }

    private func saveEdits(_ then: @escaping () -> Void) {
        if let onSaveEdits { onSaveEdits(then) } else { then() }
    }

    // MARK: - Diffs

    private func openDiff(_ file: GitChangedFile, group: Group) {
        let git = GitManager.shared
        let name = (file.path as NSString).lastPathComponent
        switch group {
        case .merge:
            onOpenFile?(file.path)
        case .changes:
            if file.status == .deleted {
                let original = git.text(of: file.path, at: .index, in: project) ?? ""
                onOpenDiff?(DiffRequest(path: file.path, original: original, modified: "", title: "\(name) (Deleted)"))
            } else if isTextFile(file.path) {
                let original = git.text(of: file.path, at: .index, in: project) ?? ""
                onOpenDiff?(DiffRequest(path: file.path, original: original, modified: nil, title: "\(name) (Working Tree)"))
            } else {
                onOpenFile?(file.path)
            }
        case .staged:
            let original = git.text(of: file.path, at: .head, in: project) ?? ""
            guard let staged = git.text(of: file.path, at: .index, in: project) ?? (file.status == .deleted ? "" : nil) else {
                onOpenFile?(file.path)
                return
            }
            onOpenDiff?(DiffRequest(path: file.path, original: original, modified: staged, title: "\(name) (Index)"))
        }
    }

    private func openDiff(_ file: GitChangedFile, commit: GitCommit) {
        let git = GitManager.shared
        let name = (file.path as NSString).lastPathComponent
        let original = git.text(of: file.path, at: .parent(of: commit.id), in: project) ?? ""
        guard let modified = git.text(of: file.path, at: .commit(commit.id), in: project) ?? (file.status == .deleted ? "" : nil) else {
            onOpenFile?(file.path)
            return
        }
        let short = String(commit.id.prefix(7))
        onOpenDiff?(DiffRequest(path: file.path, original: original, modified: modified, title: "\(name) (\(short)^ ↔ \(short))"))
    }

    private func isTextFile(_ path: String) -> Bool {
        guard let url = try? ProjectStore.shared.resolve(path), let data = try? Data(contentsOf: url) else { return false }
        return !data.prefix(8000).contains(0) && String(data: data, encoding: .utf8) != nil
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? changeRows.count : graphRows.count
    }

    private func row(at indexPath: IndexPath) -> Row {
        indexPath.section == 0 ? changeRows[indexPath.row] : graphRows[indexPath.row]
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 1 && isRepo ? VS.paneHeaderHeight : 0
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section == 1, isRepo,
              let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: VSPaneHeader.reuseID) as? VSPaneHeader else { return nil }
        header.configure(title: "Graph", expanded: graphExpanded, actions: [
            VSIconButton(.repoPull, label: "Pull") { [weak self] in self?.pull() },
            VSIconButton(.repoPush, label: "Push") { [weak self] in self?.push() },
            VSIconButton(.refresh, label: "Refresh") { [weak self] in self?.refresh() },
        ])
        header.onToggle = { [weak self] in
            guard let self else { return }
            self.graphExpanded.toggle()
            self.rebuildRows()
        }
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VSListCell.reuseID, for: indexPath) as! VSListCell
        switch row(at: indexPath) {
        case let .group(group, count):
            cell.configure(depth: 0, twistie: !collapsed.contains(groupKey(group)), icon: nil, title: group.title, bold: true)
            cell.setTrailing(groupActions(group) + [badge(count)])
        case let .folder(group, path, name, depth):
            cell.configure(depth: depth, twistie: !collapsed.contains(folderKey(group, path)), icon: nil, title: name)
        case let .file(group, file, depth):
            let name = (file.path as NSString).lastPathComponent
            let (icon, color) = VS.fileIcon(name)
            cell.configure(depth: depth, twistie: nil, icon: icon, iconColor: color, title: name,
                           titleColor: VS.color(for: file.status), strikethrough: file.status == .deleted,
                           description: viewAsTree ? nil : (file.path as NSString).deletingLastPathComponent)
            let focused = focusedKey == fileKey(group, file.path)
            cell.setTrailing((focused ? fileActions(file, group: group) : []) + [VSListCell.statusLetter(file.status)])
            cell.isMarked = focused
        case let .commit(commit, index):
            let expanded = commit.hasSnapshot ? expandedCommits.contains(commit.id) : nil
            cell.configure(depth: 0, twistie: expanded, icon: nil, title: commit.message.components(separatedBy: .newlines).first ?? "",
                           description: commit.author)
            let lane = GraphLaneView()
            lane.isFirst = index == 0
            lane.isLast = index == commits.count - 1 && !(expandedCommits.contains(commit.id))
            lane.isHead = index == 0
            cell.setLeadingView(lane, width: 16)
            cell.setTrailing(refLabels(for: commit, index: index))
        case let .commitFile(commit, file):
            let name = (file.path as NSString).lastPathComponent
            let (icon, color) = VS.fileIcon(name)
            cell.configure(depth: 3, twistie: nil, icon: icon, iconColor: color, title: name,
                           titleColor: VS.color(for: file.status), strikethrough: file.status == .deleted,
                           description: (file.path as NSString).deletingLastPathComponent)
            cell.setTrailing([VSListCell.statusLetter(file.status)])
            // Carry the lane down past the commit's files, unless it's the oldest commit.
            if commits.last?.id != commit.id {
                let lane = GraphLaneView()
                lane.isPassThrough = true
                cell.setOverlay(lane, x: 4 + 16, width: 16)
            }
        case let .graphMessage(text):
            cell.configure(depth: 1, twistie: nil, icon: nil, title: text, titleColor: VS.description)
        }
        return cell
    }

    private func badge(_ count: Int) -> VSBadge {
        let badge = VSBadge()
        badge.text = "\(count)"
        return badge
    }

    private func groupActions(_ group: Group) -> [UIView] {
        switch group {
        case .merge:
            return [VSIconButton(.add, label: "Stage All Merge Changes") { [weak self] in
                self?.stage(self?.status.mergeConflicts.map(\.path) ?? [])
            }]
        case .staged:
            return [VSIconButton(.remove, label: "Unstage All Changes") { [weak self] in self?.unstageAll() }]
        case .changes:
            return [
                VSIconButton(.discard, label: "Discard All Changes") { [weak self] in self?.confirmDiscard(self?.status.changedFiles ?? []) },
                VSIconButton(.add, label: "Stage All Changes") { [weak self] in self?.stageAll() },
            ]
        }
    }

    private func fileActions(_ file: GitChangedFile, group: Group) -> [UIView] {
        var actions: [UIView] = []
        if file.status != .deleted {
            actions.append(VSIconButton(.goToFile, label: "Open File") { [weak self] in self?.onOpenFile?(file.path) })
        }
        switch group {
        case .merge:
            actions.append(VSIconButton(.add, label: "Stage Changes (Mark Resolved)") { [weak self] in self?.stage([file.path]) })
        case .staged:
            actions.append(VSIconButton(.remove, label: "Unstage Changes") { [weak self] in self?.unstage([file.path]) })
        case .changes:
            actions.append(VSIconButton(.discard, label: "Discard Changes") { [weak self] in self?.confirmDiscard([file]) })
            actions.append(VSIconButton(.add, label: "Stage Changes") { [weak self] in self?.stage([file.path]) })
        }
        return actions
    }

    /// The branch badge on the newest commit and the GitHub badge where the last sync was.
    private func refLabels(for commit: GitCommit, index: Int) -> [UIView] {
        var labels: [UIView] = []
        if index == 0 { labels.append(RefLabel(icon: .gitBranch, text: status.currentBranch, color: VS.graphLane)) }
        for name in commit.branches.prefix(2) { labels.append(RefLabel(icon: .gitBranch, text: name, color: VS.graphOther)) }
        if commit.isSynced, status.remoteURL != nil {
            labels.append(RefLabel(icon: .cloudUpload, text: "origin", color: VS.graphRemote))
        }
        return labels
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        messageView.resignFirstResponder()
        switch row(at: indexPath) {
        case let .group(group, _):
            toggle(groupKey(group))
        case let .folder(group, path, _, _):
            toggle(folderKey(group, path))
        case let .file(group, file, _):
            focusedKey = fileKey(group, file.path)
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
            openDiff(file, group: group)
        case let .commit(commit, _):
            guard commit.hasSnapshot else { return }
            if expandedCommits.contains(commit.id) { expandedCommits.remove(commit.id) } else { expandedCommits.insert(commit.id) }
            rebuildRows()
        case let .commitFile(commit, file):
            openDiff(file, commit: commit)
        case .graphMessage:
            break
        }
    }

    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        rebuildRows()
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case let .file(group, file, _) = row(at: indexPath) else { return nil }
        var actions: [UIContextualAction] = []
        switch group {
        case .merge:
            let resolve = UIContextualAction(style: .normal, title: "Resolved") { [weak self] _, _, done in
                self?.stage([file.path])
                done(true)
            }
            resolve.backgroundColor = VS.buttonBackground
            actions.append(resolve)
        case .staged:
            let unstage = UIContextualAction(style: .normal, title: "Unstage") { [weak self] _, _, done in
                self?.unstage([file.path])
                done(true)
            }
            unstage.backgroundColor = VS.buttonBackground
            actions.append(unstage)
        case .changes:
            let stage = UIContextualAction(style: .normal, title: "Stage") { [weak self] _, _, done in
                self?.stage([file.path])
                done(true)
            }
            stage.backgroundColor = VS.buttonBackground
            let discard = UIContextualAction(style: .destructive, title: "Discard") { [weak self] _, _, done in
                self?.confirmDiscard([file])
                done(false)
            }
            actions.append(stage)
            actions.append(discard)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let item = row(at: indexPath)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            switch item {
            case let .file(group, file, _):
                var items: [UIMenuElement] = [
                    UIAction(title: "Open Changes", image: Codicon.diff.image()) { _ in self.openDiff(file, group: group) },
                ]
                if file.status != .deleted {
                    items.append(UIAction(title: "Open File", image: Codicon.goToFile.image()) { _ in self.onOpenFile?(file.path) })
                }
                switch group {
                case .merge:
                    items.append(UIAction(title: "Stage Changes (Mark Resolved)", image: Codicon.add.image()) { _ in self.stage([file.path]) })
                case .staged:
                    items.append(UIAction(title: "Unstage Changes", image: Codicon.remove.image()) { _ in self.unstage([file.path]) })
                case .changes:
                    items.append(UIAction(title: "Stage Changes", image: Codicon.add.image()) { _ in self.stage([file.path]) })
                    items.append(UIAction(title: "Discard Changes", image: Codicon.discard.image(), attributes: .destructive) { _ in
                        self.confirmDiscard([file])
                    })
                }
                items.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: "Copy Path", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = file.path },
                    UIAction(title: "Reveal in Explorer View", image: Codicon.files.image()) { _ in self.onRevealInExplorer?(file.path) },
                ]))
                return UIMenu(children: items)
            case let .group(group, _):
                switch group {
                case .merge:
                    return UIMenu(children: [
                        UIAction(title: "Stage All Merge Changes", image: Codicon.add.image()) { _ in self.stage(self.status.mergeConflicts.map(\.path)) },
                        UIAction(title: "Abort Merge", image: Codicon.discard.image(), attributes: .destructive) { _ in self.abortMerge() },
                    ])
                case .staged:
                    return UIMenu(children: [UIAction(title: "Unstage All Changes", image: Codicon.remove.image()) { _ in self.unstageAll() }])
                case .changes:
                    return UIMenu(children: [
                        UIAction(title: "Stage All Changes", image: Codicon.add.image()) { _ in self.stageAll() },
                        UIAction(title: "Discard All Changes", image: Codicon.discard.image(), attributes: .destructive) { _ in
                            self.confirmDiscard(self.status.changedFiles)
                        },
                    ])
                }
            case let .commit(commit, index):
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy Commit ID", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = commit.id },
                    UIAction(title: "Copy Commit Message", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = commit.message },
                ]
                if index == 0 && self.canUndoLastCommit {
                    items.append(UIAction(title: "Undo Last Commit", image: Codicon.discard.image()) { _ in self.undoLastCommit() })
                }
                return UIMenu(children: items)
            case let .commitFile(commit, file):
                return UIMenu(children: [
                    UIAction(title: "Open Changes", image: Codicon.diff.image()) { _ in self.openDiff(file, commit: commit) },
                    UIAction(title: "Copy Path", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = file.path },
                ])
            case .folder, .graphMessage:
                return nil
            }
        }
    }
}

/// The Graph's lane: a line through the commits with a dot for each (a ring for the newest).
final class GraphLaneView: UIView {
    var isFirst = false
    var isLast = false
    var isHead = false
    var isPassThrough = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let x = bounds.midX
        let y = bounds.midY
        VS.graphLane.setStroke()
        VS.graphLane.setFill()
        context.setLineWidth(2)
        if !isFirst || isPassThrough {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: isPassThrough ? bounds.maxY : y))
        }
        if !isLast && !isPassThrough {
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
        }
        context.strokePath()
        guard !isPassThrough else { return }
        let dot = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
        if isHead {
            VS.sideBar.setFill()
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot.insetBy(dx: 0.5, dy: 0.5))
            VS.graphLane.setFill()
            context.fillEllipse(in: dot.insetBy(dx: 2.5, dy: 2.5))
        } else {
            context.fillEllipse(in: dot)
        }
    }
}

/// A branch or remote label in the Graph.
final class RefLabel: UILabel {
    init(icon: Codicon, text: String, color: UIColor) {
        super.init(frame: .zero)
        let content = NSMutableAttributedString(attributedString: icon.attributed(12, color: VS.sideBar))
        content.append(NSAttributedString(string: " " + text, attributes: [.font: VS.font(11, .semibold), .foregroundColor: VS.sideBar]))
        attributedText = content
        backgroundColor = color
        layer.cornerRadius = 8
        clipsToBounds = true
        textAlignment = .center
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: min(110, size.width + 12), height: 16)
    }
}

/// VS Code's thin progress bar under the view title while a pull or push runs.
final class VSProgressBar: UIView {
    private let bar = UIView()

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isAnimating ? start() : stop()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        bar.backgroundColor = VS.focusBorder
        bar.isHidden = true
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func start() {
        bar.isHidden = false
        bar.layer.removeAllAnimations()
        bar.frame = CGRect(x: -bounds.width * 0.3, y: 0, width: max(bounds.width, 200) * 0.3, height: 2)
        UIView.animate(withDuration: 1.2, delay: 0, options: [.repeat, .curveLinear]) {
            self.bar.frame.origin.x = max(self.bounds.width, 200)
        }
    }

    private func stop() {
        bar.layer.removeAllAnimations()
        bar.isHidden = true
    }
}
