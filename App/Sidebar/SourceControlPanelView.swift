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
        case commit(GitCommit, index: Int, lanes: GitGraphRow)
        case commitFile(GitCommit, GitChangedFile, lanes: [Int])
        case graphMessage(String)
    }

    private var project: URL { ProjectStore.shared.currentProject }
    private var isRepo = false
    private var status = GitStatus()
    private var commits: [GitCommit] = []
    private var lanes: [GitGraphRow] = []
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
        // Check Out on a pull request (PullRequestsViewController).
        NotificationCenter.default.addObserver(forName: FileIconTheme.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.tableView.reloadData()
        }
        NotificationCenter.default.addObserver(forName: PullRequestsViewController.checkoutRequest, object: nil, queue: .main) { [weak self] note in
            guard let branch = note.userInfo?["branch"] as? String else { return }
            self?.checkoutRemote(branch)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The project's repository, opened for this call (nil when it isn't one).
    private var repo: GitRepository? { try? GitRepository.open(project) }

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
            UIAction(title: "Force Push", attributes: .destructive) { [weak self] _ in self?.confirmForcePush() },
            UIAction(title: "Fetch", image: Codicon.refresh.image()) { [weak self] _ in self?.fetch(prune: false) },
            UIAction(title: "Fetch (Prune)") { [weak self] _ in self?.fetch(prune: true) },
            UIAction(title: "Pull (Rebase)", image: Codicon.repoPull.image()) { [weak self] _ in self?.pullRebase() },
        ])
        let tagMenu = UIMenu(title: "Tags", children: tagMenuItems())
        let submoduleMenu = UIMenu(title: "Submodules", children: submoduleMenuItems())
        let branchMenu = UIMenu(title: "Branch", children: branchMenuItems())
        let stashMenu = UIMenu(title: "Stash", children: stashMenuItems())
        var mergeItems: [UIMenuElement] = []
        if status.state == .rebasing {
            mergeItems.append(UIMenu(title: "Rebase in Progress", options: .displayInline, children: [
                UIAction(title: "Continue Rebase", image: Codicon.debugContinue.image()) { [weak self] _ in self?.rebaseStep { try $0.continueRebase() } },
                UIAction(title: "Skip This Commit") { [weak self] _ in self?.rebaseStep { try $0.skipRebaseStep() } },
                UIAction(title: "Abort Rebase", image: Codicon.discard.image(), attributes: .destructive) { [weak self] _ in
                    self?.perform { try $0.abortRebase() }
                    self?.onFilesChangedOnDisk?()
                },
            ]))
        } else if status.state != .none {
            let title = status.state == .reverting ? "Abort Revert" : status.state == .cherryPicking ? "Abort Cherry-Pick" : "Abort Merge"
            mergeItems.append(UIAction(title: title, image: Codicon.discard.image(), attributes: .destructive) { [weak self] _ in
                self?.abortMerge()
            })
        }
        let remoteMenu = UIMenu(title: "Remote", children: remoteMenuItems())
        let showPullRequests = { (create: Bool) in
            NotificationCenter.default.post(name: PullRequestsViewController.showRequest, object: nil, userInfo: ["create": create])
        }
        let pullRequestMenu = UIMenu(options: .displayInline, children: [
            UIAction(title: "Pull Requests…", image: Codicon.gitPullRequest.image(), attributes: status.remoteURL == nil ? [.disabled] : []) { _ in showPullRequests(false) },
            UIAction(title: "Create Pull Request…", attributes: status.remoteURL == nil ? [.disabled] : []) { _ in showPullRequests(true) },
        ])
        let viewMenu = UIMenu(title: "View & Sort", children: [
            UIAction(title: "View as List", state: viewAsTree ? .off : .on) { [weak self] _ in self?.setTreeView(false) },
            UIAction(title: "View as Tree", state: viewAsTree ? .on : .off) { [weak self] _ in self?.setTreeView(true) },
        ])
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Pull", image: Codicon.repoPull.image()) { [weak self] _ in self?.pull() },
                UIAction(title: "Push", image: Codicon.repoPush.image()) { [weak self] _ in self?.push() },
                UIAction(title: "Fetch", image: Codicon.refresh.image()) { [weak self] _ in self?.fetch(prune: false) },
                checkout,
            ]),
            UIMenu(options: .displayInline, children: mergeItems + [commitMenu, changesMenu, syncMenu, branchMenu, remoteMenu, stashMenu, tagMenu, submoduleMenu]),
            pullRequestMenu,
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

    private var canUndoLastCommit: Bool { status.head != nil }

    private func setTreeView(_ tree: Bool) {
        viewAsTree = tree
        rebuildRows()
    }

    // MARK: - Refresh

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let root = project
        // Status and history can take a moment in big repositories, so they're read off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let repository = try? GitRepository.open(root)
            let status = repository?.status() ?? GitStatus()
            // Every branch's history, as the Graph shows it.
            let commits = repository?.log(all: true, limit: 400) ?? []
            let lanes = GitGraph.layout(commits)
            DispatchQueue.main.async {
                guard generation == self.refreshGeneration else { return }
                let wasRepo = self.isRepo
                self.isRepo = repository != nil
                let repo = self.isRepo
                self.status = status
                self.commits = commits
                self.lanes = lanes
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
            let repo = expandedCommits.isEmpty ? nil : self.repo
            for (index, commit) in commits.enumerated() {
                let row = lanes[index]
                graphRows.append(.commit(commit, index: index, lanes: row))
                guard expandedCommits.contains(commit.id) else { continue }
                let files = commitFiles[commit.id] ?? repo?.changes(inCommit: commit.id) ?? []
                commitFiles[commit.id] = files
                files.forEach { graphRows.append(.commitFile(commit, $0, lanes: row.below)) }
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
        let ahead = status.aheadCount, behind = status.behindCount
        if isRepo && status.isClean && status.head != nil && status.branch != nil && (status.remoteURL == nil || !status.hasUpstream) {
            syncButton.setTitle("Publish Branch", icon: .cloudUpload)
            showSync(true)
        } else if isRepo && status.isClean && (ahead > 0 || behind > 0) {
            syncButton.setTitle("Sync Changes " + [behind > 0 ? "\(behind)↓" : nil, ahead > 0 ? "\(ahead)↑" : nil].compactMap { $0 }.joined(separator: " "), icon: .sync)
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
            let status = self.repo?.status() ?? GitStatus()
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
            guard let repo else { return }
            try repo.commit(message: message, stageAll: all, amend: amend)
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
            guard let repo else { return }
            let message = try repo.undoLastCommit()
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
            self.perform { try $0.stage(paths) }
        }
    }

    private func unstage(_ paths: [String]) {
        perform { try $0.unstage(paths) }
    }

    private func stageAll() {
        saveEdits { [weak self] in
            guard let self else { return }
            self.perform { try $0.stageAll() }
        }
    }

    private func unstageAll() {
        perform { try $0.unstageAll() }
    }

    /// Runs `work` on the repository, showing what went wrong, then refreshes.
    private func perform(_ work: (GitRepository) throws -> Void) {
        do {
            guard let repo else { throw GitError("This project isn't a Git repository.") }
            try work(repo)
        } catch {
            showAlert(error.localizedDescription)
        }
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
                self.perform { try $0.discard(files) }
                self.onFilesChangedOnDisk?()
            }
        })
        presenter?.present(alert, animated: true)
    }

    // MARK: - Branches and remote

    // MARK: Checkout

    /// "Checkout to...": new branch, local branches, remote branches (from the last fetch) and tags.
    private func checkoutItems(_ done: @escaping ([UIMenuElement]) -> Void) {
        let repo = self.repo
        let local = repo?.branches() ?? []
        let remote = (repo?.branches(remote: true) ?? []).filter { branch in
            !local.contains { $0.upstream == branch.name || $0.name == branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) }
        }
        let tags = repo?.tags() ?? []
        let current = status.branch
        var items: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Create New Branch...", image: Codicon.add.image()) { [weak self] _ in self?.promptNewBranch(from: nil) },
                UIMenu(title: "Create New Branch From...", children: (local + remote).map { branch in
                    UIAction(title: branch.name) { [weak self] _ in self?.promptNewBranch(from: branch.name) }
                }),
            ]),
            UIMenu(title: "Branches", options: .displayInline, children: local.map { branch in
                UIAction(title: branch.name, subtitle: branch.summary, image: Codicon.gitBranch.image(), state: branch.name == current ? .on : .off) { [weak self] _ in
                    self?.checkout(branch.name)
                }
            }),
        ]
        if !remote.isEmpty {
            items.append(UIMenu(title: "Remote Branches", options: .displayInline, children: remote.map { branch in
                UIAction(title: branch.name, subtitle: branch.summary, image: Codicon.cloudUpload.image()) { [weak self] _ in self?.checkoutRemote(branch.name) }
            }))
        }
        if !tags.isEmpty {
            items.append(UIMenu(title: "Tags", options: .displayInline, children: tags.prefix(30).map { tag in
                UIAction(title: tag.name, image: Codicon.tag.image()) { [weak self] _ in self?.checkout(commit: tag.target, title: tag.name) }
            }))
        }
        done(items)
    }

    private func checkout(_ branch: String, force: Bool = false) {
        saveEdits { [weak self] in
            guard let self else { return }
            do {
                try self.repo?.checkout(branch, force: force)
                self.didSwitchBranch()
            } catch let error as GitError where error.isConflict {
                self.confirmCheckoutConflict(branch, error: error)
            } catch {
                self.showAlert(error.localizedDescription)
            }
        }
    }

    /// A commit (or tag) checked out without a branch: a detached HEAD.
    private func checkout(commit id: String, title: String) {
        saveEdits { [weak self] in
            guard let self else { return }
            do {
                try self.repo?.checkout(commit: id)
                self.didSwitchBranch()
                self.toast("Checked out \(title). You're not on a branch: create one to keep commits you make here.")
            } catch let error as GitError where error.isConflict {
                self.showAlert("Your local changes would be overwritten: commit or stash them first.\n\n" + error.paths.joined(separator: "\n"))
            } catch {
                self.showAlert(error.localizedDescription)
            }
        }
    }

    /// VS Code's choices when local changes are in the way of a checkout.
    private func confirmCheckoutConflict(_ branch: String, error: GitError) {
        let alert = UIAlertController(title: "Your local changes would be overwritten by checkout.",
                                      message: error.paths.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Stash & Checkout", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try self.repo?.stash()
                if branch.contains("/"), !(self.repo?.branches().contains { $0.name == branch } ?? false) {
                    try self.repo?.checkoutRemote(branch)
                } else {
                    try self.repo?.checkout(branch)
                }
                self.didSwitchBranch()
            } catch {
                self.showAlert(error.localizedDescription)
                self.didSwitchBranch()
            }
        })
        alert.addAction(UIAlertAction(title: "Force Checkout", style: .destructive) { [weak self] _ in
            guard let self else { return }
            if branch.contains("/"), !(self.repo?.branches().contains { $0.name == branch } ?? false) {
                self.perform { try $0.checkoutRemote(branch, force: true) }
                self.onFilesChangedOnDisk?()
            } else {
                self.checkout(branch, force: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter?.present(alert, animated: true)
    }

    /// Checks out a remote branch ("origin/feature") as a local one following it. A bare name (a
    /// pull request's branch) is fetched from origin first.
    private func checkoutRemote(_ name: String) {
        guard !isBusy else { return }
        let fetchFirst = !name.contains("/") || !(repo?.branches(remote: true).contains { $0.name == name } ?? false)
        let remoteName = name.contains("/") ? name : "origin/\(name)"
        saveEdits { [weak self] in
            guard let self else { return }
            self.network("Checking out \(remoteName)", { repo, transfer in
                if fetchFirst { try repo.fetch(String(remoteName.split(separator: "/").first ?? "origin"), transfer: transfer) }
                try repo.checkoutRemote(remoteName)
            }, failed: { error in
                if let error = error as? GitError, error.isConflict {
                    self.confirmCheckoutConflict(remoteName, error: error)
                    return true
                }
                return false
            }) {
                self.didSwitchBranch()
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
        if status.branch == nil && status.head != nil { title += " (detached)" }
        if !status.isClean { title += "*" }
        if let merging = status.mergingBranch { title += "  (merging \(merging))" }
        if status.state == .reverting { title += "  (reverting)" }
        if status.state == .cherryPicking { title += "  (cherry-picking)" }
        if status.state == .rebasing { title += "  (rebasing)" }
        let text = NSMutableAttributedString(attributedString: Codicon.gitBranch.attributed(14, color: VS.description))
        text.append(NSAttributedString(string: " " + title, attributes: [.font: VS.font(12), .foregroundColor: VS.description]))
        if status.behindCount > 0 {
            text.append(NSAttributedString(string: "  \(status.behindCount)", attributes: [.font: VS.font(12), .foregroundColor: VS.description]))
            text.append(Codicon.arrowDown.attributed(13, color: VS.description))
        }
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
        let repo = self.repo
        let all = repo?.branches() ?? []
        let others = all.map(\.name).filter { $0 != status.branch }
        let remote = (repo?.branches(remote: true) ?? []).map(\.name)
        var items: [UIMenuElement] = [
            UIMenu(title: "Merge Branch...", image: Codicon.gitBranch.image(), children: (others + remote).map { name in
                UIAction(title: name) { [weak self] _ in self?.merge(name) }
            }),
            UIAction(title: "Create Branch...", image: Codicon.add.image()) { [weak self] _ in self?.promptNewBranch(from: nil) },
            UIMenu(title: "Create Branch From...", children: (all.map(\.name) + remote).map { name in
                UIAction(title: name) { [weak self] _ in self?.promptNewBranch(from: name) }
            }),
            UIMenu(title: "Rebase Branch onto...", image: Codicon.gitCommit.image(), children: (others + remote).map { name in
                UIAction(title: name) { [weak self] _ in self?.rebase(onto: name) }
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
                    try self.repo?.createBranch(name, at: source)
                    self.didSwitchBranch()
                } catch {
                    self.showAlert(error.localizedDescription)
                }
            }
        })
        presenter?.present(alert, animated: true)
    }

    private func promptRenameBranch() {
        guard let current = status.branch else { return showAlert("You're not on a branch.") }
        let alert = UIAlertController(title: "Rename Branch", message: "Please provide a new name for '\(current)'.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            self.perform { try $0.renameBranch(current, to: name) }
        })
        presenter?.present(alert, animated: true)
    }

    private func confirmDeleteBranch(_ name: String) {
        do {
            try repo?.deleteBranch(name)
            refresh()
        } catch let error as GitError where error.code == GitError.notMerged {
            let alert = UIAlertController(title: "The branch '\(name)' is not fully merged. Delete anyway?",
                                          message: "Its commits aren't on another branch or a remote, so they'll be lost.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete Branch", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.perform { try $0.deleteBranch(name, force: true) }
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
                guard let repo = self.repo else { return }
                self.showMergeResult(try repo.merge(branch), what: "Merging '\(branch)'")
            } catch {
                self.showAlert(error.localizedDescription)
            }
        }
    }

    /// After a merge, pull, revert or cherry-pick.
    private func showMergeResult(_ result: GitMergeResult, what: String) {
        switch result {
        case .upToDate:
            toast("Already up to date.")
        case .fastForward, .merged:
            didSwitchBranch()
        case .conflicts(let paths):
            didSwitchBranch()
            messageView.text = repo?.mergeMessage ?? ""
            showAlert("\(what) left conflicts in \(paths.joined(separator: ", ")). Edit each file to keep what you want (or open it to use the merge editor), stage it, then commit.")
        }
    }

    private func abortMerge() {
        perform { try $0.abortMerge() }
        messageView.text = ""
        onFilesChangedOnDisk?()
    }

    // MARK: Stash

    private func stashMenuItems() -> [UIMenuElement] {
        let stashes = repo?.stashes() ?? []
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
                self.perform { try $0.dropStash(index) }
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
                self.perform { try $0.stash(message: message) }
                self.onFilesChangedOnDisk?()
            }
        })
        presenter?.present(alert, animated: true)
    }

    private func applyStash(_ index: Int, drop: Bool) {
        saveEdits { [weak self] in
            guard let self else { return }
            self.perform { try $0.applyStash(index, drop: drop) }
            self.onFilesChangedOnDisk?()
        }
    }

    private func confirmDropAllStashes() {
        let count = repo?.stashes().count ?? 0
        let alert = UIAlertController(title: "Are you sure you want to drop ALL stashes?",
                                      message: "There \(count == 1 ? "is 1 stash" : "are \(count) stashes") that will be dropped. This can't be undone.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Drop All Stashes", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.perform { try $0.dropAllStashes() }
        })
        presenter?.present(alert, animated: true)
    }

    private func remoteMenuItems() -> [UIMenuElement] {
        let remotes = repo?.remotes() ?? []
        var items: [UIMenuElement] = [
            UIAction(title: remotes.isEmpty ? "Add Remote..." : "Change Remote URL...", image: Codicon.edit.image()) { [weak self] _ in
                self?.promptRemote(then: nil)
            },
            UIAction(title: "Add Another Remote...", image: Codicon.add.image()) { [weak self] _ in self?.promptRemote(name: nil, then: nil) },
        ]
        if !remotes.isEmpty {
            items.append(UIMenu(title: "Remove Remote...", image: Codicon.trash.image(), children: remotes.map { remote in
                UIAction(title: remote.name, subtitle: remote.url, attributes: .destructive) { [weak self] _ in
                    self?.perform { try $0.removeRemote(remote.name) }
                }
            }))
        }
        return items
    }

    /// Adds or changes a remote (origin unless named; nil `name` asks for one).
    private func promptRemote(name: String? = "origin", then: (() -> Void)?) {
        let existing = name.flatMap { repo?.remoteURL($0) }
        let alert = UIAlertController(title: existing == nil ? "Add Remote" : "Change Remote",
                                      message: "The repository to push to and pull from: GitHub, GitLab, or any Git server's HTTPS address.", preferredStyle: .alert)
        if name == nil {
            alert.addTextField { field in
                field.placeholder = "Name, like upstream"
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
        }
        alert.addTextField { field in
            field.text = existing
            field.placeholder = "https://github.com/owner/repo"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self, let fields = alert.textFields, let url = fields.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
            let remoteName = name ?? fields.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !remoteName.isEmpty else { return }
            self.perform { try $0.setRemote(remoteName, url: url) }
            then?()
        })
        presenter?.present(alert, animated: true)
    }

    private func initializeRepository() {
        do {
            try GitRepository.create(at: project)
        } catch {
            showAlert(error.localizedDescription)
        }
        refresh()
        onHeaderActionsChanged?()
    }

    // MARK: - Pull, push, sync

    /// Runs network work off the main thread with the progress bar, then `done` on the main one.
    /// A sign-in problem offers GitHub's sign-in or asks for the host's login, then tries again;
    /// `failed` can handle other errors (true when it did).
    private func network(_ what: String, _ work: @escaping (GitRepository, GitTransfer) throws -> Void,
                         failed: ((Error) -> Bool)? = nil, done: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        let root = project
        DispatchQueue.global(qos: .userInitiated).async {
            let transfer = GitTransfer()
            var failure: Error?
            do { try work(try GitRepository.open(root), transfer) } catch { failure = error }
            DispatchQueue.main.async {
                self.isBusy = false
                self.refresh()
                guard let failure else { return done() }
                if failed?(failure) == true { return }
                if let error = failure as? GitError, error.isAuthentication {
                    self.askToSignIn(error) { self.network(what, work, failed: failed, done: done) }
                } else {
                    self.showGitError(failure)
                }
            }
        }
    }

    private func pull(then next: (() -> Void)? = nil) {
        guard status.remoteURL != nil else { return promptRemote { [weak self] in self?.pull(then: next) } }
        saveEdits { [weak self] in
            guard let self else { return }
            var result = GitMergeResult.upToDate
            self.network("Pulling", { repo, transfer in result = try repo.pull(transfer: transfer) }) {
                if case .upToDate = result {
                    if let next { next() } else { self.toast("Already up to date.") }
                    return
                }
                self.showMergeResult(result, what: "Pulling")
                if case .conflicts = result { return }
                next?()
            }
        }
    }

    private func push(force: Bool = false) {
        guard status.remoteURL != nil else { return promptRemote { [weak self] in self?.push(force: force) } }
        guard status.branch != nil else { return showAlert("You're not on a branch: create one to push.") }
        let ahead = status.aheadCount, published = status.hasUpstream
        saveEdits { [weak self] in
            guard let self else { return }
            self.network("Pushing", { repo, transfer in try repo.push(force: force, transfer: transfer) }) {
                if published && ahead == 0 && !force { self.toast("Everything is already pushed.") }
            }
        }
    }

    private func confirmForcePush() {
        let alert = UIAlertController(title: "Force push '\(status.currentBranch)'?",
                                      message: "The remote's branch is replaced with yours: commits only it has are lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Force Push", style: .destructive) { [weak self] _ in self?.push(force: true) })
        presenter?.present(alert, animated: true)
    }

    private func fetch(prune: Bool) {
        guard status.remoteURL != nil else { return promptRemote { [weak self] in self?.fetch(prune: prune) } }
        network("Fetching", { repo, transfer in
            for remote in repo.remotes() { try repo.fetch(remote.name, prune: prune, transfer: transfer) }
        }) { [weak self] in
            guard let self else { return }
            let behind = self.status.behindCount
            self.toast(behind > 0 ? "\(behind) new commit\(behind == 1 ? "" : "s") to pull." : "Fetched: nothing new.")
        }
    }

    /// Pull, then push, as VS Code's Sync does.
    private func sync() {
        pull { [weak self] in self?.push() }
    }

    /// GitHub: its sign-in. Other hosts: their username and password (or token), kept in the Keychain.
    private func askToSignIn(_ error: GitError, then retry: @escaping () -> Void) {
        let url = status.remoteURL ?? ""
        let host = GitCredentials.host(of: url) ?? url
        guard let presenter else { return }
        if host == "github.com" {
            GitHubSignInViewController.present(from: presenter) { _ in retry() }
            return
        }
        let alert = UIAlertController(title: "Sign in to \(host)", message: "\(error.message)\n\nUse your username and a password or access token. They're kept in this device's Keychain.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Username"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Password or token"
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
            guard let fields = alert?.textFields, let user = fields[0].text, !user.isEmpty, let password = fields[1].text else { return }
            GitCredentials.save(GitCredentials.Login(user: user, password: password), for: host)
            retry()
        })
        presenter.present(alert, animated: true)
    }

    private func showGitError(_ error: Error) {
        let alert = UIAlertController(title: "Git", message: error.localizedDescription, preferredStyle: .alert)
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
        guard let git = repo else { return }
        let name = (file.path as NSString).lastPathComponent
        switch group {
        case .merge:
            onOpenFile?(file.path)
        case .changes where git.isSubmodule(file.path):
            showSubmodule(file.path, git: git)
        case .changes:
            if file.status == .deleted {
                let original = git.text(of: file.path, at: .index) ?? ""
                onOpenDiff?(DiffRequest(path: file.path, original: original, modified: "", title: "\(name) (Deleted)"))
            } else if isTextFile(file.path) {
                let original = git.text(of: file.path, at: .index) ?? ""
                onOpenDiff?(DiffRequest(path: file.path, original: original, modified: nil, title: "\(name) (Working Tree)"))
            } else {
                onOpenFile?(file.path)
            }
        case .staged:
            let original = git.text(of: file.oldPath ?? file.path, at: .head) ?? ""
            guard let staged = git.text(of: file.path, at: .index) ?? (file.status == .deleted ? "" : nil) else {
                onOpenFile?(file.path)
                return
            }
            onOpenDiff?(DiffRequest(path: file.path, original: original, modified: staged, title: "\(name) (Index)"))
        }
    }

    private func openDiff(_ file: GitChangedFile, commit: GitCommit) {
        guard let git = repo else { return }
        let name = (file.path as NSString).lastPathComponent
        let original = git.text(of: file.oldPath ?? file.path, at: .parent(of: commit.id)) ?? ""
        guard let modified = git.text(of: file.path, at: .commit(commit.id)) ?? (file.status == .deleted ? "" : nil) else {
            onOpenFile?(file.path)
            return
        }
        let short = commit.shortId
        onOpenDiff?(DiffRequest(path: file.path, original: original, modified: modified, title: "\(name) (\(short)^ ↔ \(short))"))
    }

    private func isTextFile(_ path: String) -> Bool {
        guard let url = try? ProjectStore.shared.resolve(path), let data = try? Data(contentsOf: url) else { return false }
        return !data.prefix(8000).contains(0) && String(data: data, encoding: .utf8) != nil
    }

    // MARK: - Rebase

    private func rebase(onto upstream: String) {
        rebaseStep { try $0.rebase(onto: upstream) }
    }

    /// A rebase, or its next step: done, or stopped at a commit with conflicts.
    private func rebaseStep(_ work: @escaping (GitRepository) throws -> GitRebaseResult) {
        saveEdits { [weak self] in
            guard let self else { return }
            do {
                guard let repo = self.repo else { return }
                self.showRebaseResult(try work(repo))
            } catch {
                self.showAlert(error.localizedDescription)
                self.refresh()
            }
        }
    }

    private func showRebaseResult(_ result: GitRebaseResult) {
        switch result {
        case .upToDate:
            toast("Already up to date.")
        case .done(let count):
            didSwitchBranch()
            toast("Rebased \(count) commit\(count == 1 ? "" : "s").")
        case .conflicts(let paths):
            didSwitchBranch()
            showAlert("The rebase stopped at a commit that conflicts in \(paths.joined(separator: ", ")). Fix each file, stage it, then choose Continue Rebase from the ... menu (or Skip This Commit, or Abort Rebase).")
        }
    }

    private func pullRebase() {
        guard status.remoteURL != nil else { return promptRemote { [weak self] in self?.pullRebase() } }
        saveEdits { [weak self] in
            guard let self else { return }
            var result = GitRebaseResult.upToDate
            self.network("Pulling", { repo, transfer in result = try repo.pullRebase(transfer: transfer) }) {
                self.showRebaseResult(result)
            }
        }
    }

    // MARK: - Submodules

    private func submoduleMenuItems() -> [UIMenuElement] {
        let submodules = repo?.submodules() ?? []
        var items: [UIMenuElement] = [
            UIAction(title: "Update Submodules", image: Codicon.refresh.image(), attributes: submodules.isEmpty ? [.disabled] : []) { [weak self] _ in
                self?.updateSubmodules([])
            },
            UIAction(title: "Add Submodule...", image: Codicon.add.image()) { [weak self] _ in self?.promptAddSubmodule() },
        ]
        if !submodules.isEmpty {
            items.append(UIMenu(title: "Submodules", options: .displayInline, children: submodules.map { sm in
                UIMenu(title: sm.path, subtitle: !sm.isCloned ? "Not cloned yet" : sm.isModified ? "Changed" : sm.checkedOut.map { String($0.prefix(7)) },
                       image: Codicon.packageIcon.image(), children: [
                    UIAction(title: sm.isCloned ? "Update" : "Clone and Check Out") { [weak self] _ in self?.updateSubmodules([sm.path]) },
                    UIAction(title: "Open as Project", attributes: sm.isCloned ? [] : [.disabled]) { [weak self] _ in self?.openSubmodule(sm.path) },
                    UIAction(title: "Copy URL", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = sm.url },
                ])
            }))
        }
        return items
    }

    private func updateSubmodules(_ paths: [String]) {
        var count = 0
        network("Updating submodules", { repo, transfer in count = try repo.updateSubmodules(paths, transfer: transfer) }) { [weak self] in
            self?.onFilesChangedOnDisk?()
            self?.toast("Updated \(count) submodule\(count == 1 ? "" : "s").")
        }
    }

    private func promptAddSubmodule() {
        let alert = UIAlertController(title: "Add Submodule", message: "A repository to include in this one, at a folder of its own.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://github.com/owner/repo"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Folder (optional)"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, let url = fields[0].text?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return }
            let folder = fields[1].text?.trimmingCharacters(in: .whitespaces)
            self.network("Adding \(url)", { repo, transfer in
                try repo.addSubmodule(url, at: folder?.isEmpty == false ? folder : nil, transfer: transfer)
            }) {
                self.onFilesChangedOnDisk?()
                self.toast("Added. Commit .gitmodules and the submodule to record it.")
            }
        })
        presenter?.present(alert, animated: true)
    }

    /// A submodule's change is a different commit, not a text diff.
    private func showSubmodule(_ path: String, git: GitRepository) {
        guard let sm = git.submodules().first(where: { $0.path == path }) else { return }
        let recorded = sm.recorded.map { String($0.prefix(7)) } ?? "none"
        let current = sm.checkedOut.map { String($0.prefix(7)) } ?? "not cloned"
        let alert = UIAlertController(title: "Submodule \(path)", message: "Recorded: \(recorded)\nChecked out: \(current)\(sm.isModified ? "\nIt has changes of its own." : "")",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Update to Recorded", style: .default) { [weak self] _ in self?.updateSubmodules([path]) })
        alert.addAction(UIAlertAction(title: "Open as Project", style: .default) { [weak self] _ in self?.openSubmodule(path) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter?.present(alert, animated: true)
    }

    private func openSubmodule(_ path: String) {
        NotificationCenter.default.post(name: Self.openProjectRequest, object: nil, userInfo: ["url": project.appendingPathComponent(path)])
    }

    /// Opening a submodule as its own project (IDEViewController).
    static let openProjectRequest = Notification.Name("MobileStudioOpenProjectRequest")

    // MARK: - Commits in the Graph

    private func commitActions(_ commit: GitCommit) -> [UIMenuElement] {
        let isHead = commit.id == status.head
        var items: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Checkout (Detached)", image: Codicon.gitBranch.image()) { [weak self] _ in
                    self?.checkout(commit: commit.id, title: commit.shortId)
                },
                UIAction(title: "Create Branch Here...", image: Codicon.add.image()) { [weak self] _ in self?.promptNewBranch(from: commit.id) },
                UIAction(title: "Create Tag Here...", image: Codicon.tag.image()) { [weak self] _ in self?.promptTag(at: commit.id) },
            ]),
        ]
        var change: [UIMenuElement] = []
        if !isHead {
            change.append(UIAction(title: "Cherry-Pick", image: Codicon.gitCommit.image()) { [weak self] _ in
                self?.mergeLike("Cherry-picking \(commit.shortId)") { try $0.cherryPick(commit.id) }
            })
        }
        change.append(UIAction(title: "Revert", image: Codicon.discard.image()) { [weak self] _ in
            self?.mergeLike("Reverting \(commit.shortId)") { try $0.revert(commit.id) }
        })
        if !isHead && status.branch != nil {
            change.append(UIMenu(title: "Reset '\(status.currentBranch)' to Here", image: Codicon.history.image(), children: [
                UIAction(title: "Soft (keep the changes staged)") { [weak self] _ in self?.reset(to: commit, mode: .soft) },
                UIAction(title: "Mixed (keep the changes, unstaged)") { [weak self] _ in self?.reset(to: commit, mode: .mixed) },
                UIAction(title: "Hard (discard the changes)", attributes: .destructive) { [weak self] _ in self?.reset(to: commit, mode: .hard) },
            ]))
        }
        if isHead && canUndoLastCommit {
            change.append(UIAction(title: "Undo Last Commit", image: Codicon.discard.image()) { [weak self] _ in self?.undoLastCommit() })
        }
        items.append(UIMenu(options: .displayInline, children: change))
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Copy Commit ID", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = commit.id },
            UIAction(title: "Copy Commit Message", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = commit.message },
        ]))
        return items
    }

    /// A revert or cherry-pick: it may leave conflicts, like a merge.
    private func mergeLike(_ what: String, _ work: @escaping (GitRepository) throws -> GitMergeResult) {
        saveEdits { [weak self] in
            guard let self else { return }
            do {
                guard let repo = self.repo else { return }
                self.showMergeResult(try work(repo), what: what)
            } catch {
                self.showAlert(error.localizedDescription)
                self.refresh()
            }
        }
    }

    private func reset(to commit: GitCommit, mode: GitResetMode) {
        let apply = { [weak self] in
            guard let self else { return }
            self.saveEdits {
                self.perform { try $0.reset(to: commit.id, mode: mode) }
                self.onFilesChangedOnDisk?()
            }
        }
        guard mode == .hard else { return apply() }
        let alert = UIAlertController(title: "Reset '\(status.currentBranch)' to \(commit.shortId) and discard changes?",
                                      message: "Commits after it leave the branch, and your uncommitted changes are lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in apply() })
        presenter?.present(alert, animated: true)
    }

    // MARK: Tags

    private func tagMenuItems() -> [UIMenuElement] {
        let tags = repo?.tags() ?? []
        return [
            UIAction(title: "Create Tag...", image: Codicon.tag.image(), attributes: status.head == nil ? [.disabled] : []) { [weak self] _ in
                self?.promptTag(at: nil)
            },
            UIMenu(title: "Delete Tag...", image: Codicon.trash.image(), children: tags.map { tag in
                UIAction(title: tag.name, attributes: .destructive) { [weak self] _ in self?.perform { try $0.deleteTag(tag.name) } }
            }),
            UIAction(title: "Push Tags", image: Codicon.repoPush.image(), attributes: tags.isEmpty || status.remoteURL == nil ? [.disabled] : []) { [weak self] _ in
                self?.network("Pushing tags", { repo, transfer in try repo.pushTags(transfer: transfer) }) { self?.toast("Tags pushed.") }
            },
        ]
    }

    private func promptTag(at commit: String?) {
        let alert = UIAlertController(title: "Create Tag", message: "A name, like v1.0, and an optional message (which makes an annotated tag).", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Tag name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in field.placeholder = "Message (optional)" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, let name = fields[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self.perform { try $0.createTag(name, at: commit, message: fields[1].text) }
        })
        presenter?.present(alert, animated: true)
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
            cell.useThemeIcon(file: name)
            let focused = focusedKey == fileKey(group, file.path)
            cell.setTrailing((focused ? fileActions(file, group: group) : []) + [VSListCell.statusLetter(file.status)])
            cell.isMarked = focused
        case let .commit(commit, _, row):
            cell.configure(depth: 0, twistie: expandedCommits.contains(commit.id), icon: nil, title: commit.summary,
                           description: commit.author)
            let lane = GraphLaneView()
            lane.row = row
            lane.isHead = commit.id == status.head
            cell.setLeadingView(lane, width: GraphLaneView.width(for: row.width))
            cell.setTrailing(refLabels(for: commit))
        case let .commitFile(_, file, below):
            let name = (file.path as NSString).lastPathComponent
            let (icon, color) = VS.fileIcon(name)
            cell.configure(depth: 3, twistie: nil, icon: icon, iconColor: color, title: name,
                           titleColor: VS.color(for: file.status), strikethrough: file.status == .deleted,
                           description: (file.path as NSString).deletingLastPathComponent)
            cell.useThemeIcon(file: name)
            cell.setTrailing([VSListCell.statusLetter(file.status)])
            // Carry the lanes down past the commit's files.
            if !below.isEmpty {
                let lane = GraphLaneView()
                lane.row = GitGraphRow(node: -1, passThrough: below, incoming: [], outgoing: [], below: below)
                cell.setOverlay(lane, x: 4 + 16, width: GraphLaneView.width(for: (below.max() ?? 0) + 1))
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

    /// Branch, remote branch and tag badges, the checked-out branch first.
    private func refLabels(for commit: GitCommit) -> [UIView] {
        commit.refs.prefix(3).map { ref in
            switch ref.kind {
            case .head: return RefLabel(icon: .gitBranch, text: ref.name, color: VS.graphLane)
            case .branch: return RefLabel(icon: .gitBranch, text: ref.name, color: VS.graphOther)
            case .remote: return RefLabel(icon: .cloudUpload, text: ref.name, color: VS.graphRemote)
            case .tag: return RefLabel(icon: .tag, text: ref.name, color: VS.graphOther)
            }
        }
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
        case let .commit(commit, _, _):
            if expandedCommits.contains(commit.id) { expandedCommits.remove(commit.id) } else { expandedCommits.insert(commit.id) }
            rebuildRows()
        case let .commitFile(commit, file, _):
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
            case let .commit(commit, _, _):
                return UIMenu(children: self.commitActions(commit))
            case let .commitFile(commit, file, _):
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

/// The Graph's lanes for one row (GitGraph): lines through it, into and out of the commit's dot,
/// each lane its own colour. The checked-out commit's dot is a ring.
final class GraphLaneView: UIView {
    var row = GitGraphRow(node: 0, passThrough: [], incoming: [], outgoing: [], below: [])
    var isHead = false
    static let laneWidth: CGFloat = 11
    static let colors: [UIColor] = [VS.graphLane, VS.graphRemote, VS.graphOther, VS.hex(0xB180D7), VS.hex(0xE5C07B), VS.hex(0x4EC9B0), VS.hex(0xF14C4C)]

    static func width(for lanes: Int) -> CGFloat { CGFloat(max(1, min(lanes, 8))) * laneWidth + 5 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    private func x(_ lane: Int) -> CGFloat { 3 + (CGFloat(min(lane, 7)) + 0.5) * Self.laneWidth }
    private func color(_ lane: Int) -> UIColor { Self.colors[lane % Self.colors.count] }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let mid = bounds.midY
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        let line = { (lane: Int, from: CGPoint, to: CGPoint) in
            self.color(lane).setStroke()
            context.move(to: from)
            if from.x == to.x {
                context.addLine(to: to)
            } else {
                // A curve between lanes.
                context.addCurve(to: to, control1: CGPoint(x: from.x, y: (from.y + to.y) / 2), control2: CGPoint(x: to.x, y: (from.y + to.y) / 2))
            }
            context.strokePath()
        }
        for lane in row.passThrough { line(lane, CGPoint(x: x(lane), y: 0), CGPoint(x: x(lane), y: bounds.maxY)) }
        guard row.node >= 0 else { return }
        let node = CGPoint(x: x(row.node), y: mid)
        for lane in row.incoming { line(lane, CGPoint(x: x(lane), y: 0), node) }
        for lane in row.outgoing { line(lane, node, CGPoint(x: x(lane), y: bounds.maxY)) }
        let dot = CGRect(x: node.x - 4, y: mid - 4, width: 8, height: 8)
        color(row.node).setStroke()
        color(row.node).setFill()
        if isHead {
            VS.sideBar.setFill()
            context.fillEllipse(in: dot)
            context.setLineWidth(2)
            context.strokeEllipse(in: dot.insetBy(dx: 1, dy: 1))
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
