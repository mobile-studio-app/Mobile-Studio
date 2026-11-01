import UIKit

/// GitHub pull requests for the open project, like VS Code's GitHub Pull Requests view: the open
/// and closed ones, each with its description, changed files (opened as diffs in the editor), the
/// conversation, checkout and merge; and a form to create one from the current branch.
final class PullRequestsViewController: UITableViewController {
    /// Posted to show the pull requests (userInfo "create": true opens the form for a new one).
    static let showRequest = Notification.Name("MobileStudioShowPullRequests")
    /// Posted with userInfo "branch" for Source Control to check that GitHub branch out.
    static let checkoutRequest = Notification.Name("MobileStudioCheckoutPullRequest")

    var onOpenDiff: ((DiffRequest) -> Void)?
    private let project: URL
    private let startWithCreate: Bool
    private var state = "open"
    private var pulls: [PullRequest] = []
    private var message: String? = "Loading…"
    private var loadTask: Task<Void, Never>?

    init(project: URL, create: Bool = false) {
        self.project = project
        self.startWithCreate = create
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pull Requests"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(createTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Create Pull Request"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        let segments = UISegmentedControl(items: ["Open", "Closed"])
        segments.selectedSegmentIndex = 0
        segments.addAction(UIAction { [weak self, weak segments] _ in
            self?.state = segments?.selectedSegmentIndex == 1 ? "closed" : "open"
            self?.load()
        }, for: .valueChanged)
        navigationItem.titleView = segments
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        load()
        if startWithCreate { createTapped() }
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    @objc private func createTapped() {
        let form = CreatePullRequestViewController(project: project)
        form.onCreated = { [weak self] pull in
            guard let self else { return }
            self.load()
            self.navigationController?.popToRootViewController(animated: false)
            self.show(pull)
        }
        navigationController?.pushViewController(form, animated: true)
    }

    private func load() {
        loadTask?.cancel()
        if pulls.isEmpty { message = "Loading…"; tableView.reloadData() }
        let state = state
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await PullRequests.list(state: state, in: self.project)
                guard !Task.isCancelled else { return }
                self.pulls = list
                self.message = list.isEmpty ? "No \(state) pull requests." : nil
            } catch {
                guard !Task.isCancelled else { return }
                self.pulls = []
                self.message = error.localizedDescription
            }
            self.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }
    }

    private func show(_ pull: PullRequest) {
        let detail = PullRequestDetailViewController(pull: pull, project: project)
        detail.onOpenDiff = { [weak self] request in
            self?.dismiss(animated: true) { self?.onOpenDiff?(request) }
        }
        detail.onChanged = { [weak self] in self?.load() }
        navigationController?.pushViewController(detail, animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { pulls.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { message }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let pull = pulls[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = pull.title
        content.textProperties.numberOfLines = 2
        let when = RelativeDateTimeFormatter().localizedString(for: pull.created, relativeTo: Date())
        content.secondaryText = "#\(pull.number) by \(pull.author) · \(pull.headRef) → \(pull.baseRef) · \(when)" + (pull.isDraft ? " · Draft" : "")
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = PullRequestDetailViewController.icon(for: pull)
        content.imageProperties.tintColor = PullRequestDetailViewController.color(for: pull)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        show(pulls[indexPath.row])
    }
}

/// One pull request: what it is, its actions, its changed files and its conversation.
final class PullRequestDetailViewController: UITableViewController {
    var onOpenDiff: ((DiffRequest) -> Void)?
    /// Merged, closed or commented on: the list reloads.
    var onChanged: (() -> Void)?
    private var pull: PullRequest
    private let project: URL
    private var files: [PullRequestFile] = []
    private var comments: [PullRequestComment] = []
    private var filesMessage: String? = "Loading…"

    private enum Section: Int, CaseIterable { case header, description, actions, files, conversation }
    private enum Action { case checkout, openOnGitHub, merge, close }

    static func icon(for pull: PullRequest) -> UIImage? {
        UIImage(systemName: pull.isMerged ? "arrow.triangle.merge" : "arrow.triangle.pull")
    }

    static func color(for pull: PullRequest) -> UIColor {
        if pull.isMerged { return .systemPurple }
        if pull.state == "closed" { return .systemRed }
        return pull.isDraft ? .systemGray : .systemGreen
    }

    init(pull: PullRequest, project: URL) {
        self.pull = pull
        self.project = project
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isFromFork: Bool {
        guard let repo = try? GitManager.shared.gitHubRepository(in: project) else { return false }
        return !pull.headRepo.isEmpty && pull.headRepo.lowercased() != "\(repo.owner)/\(repo.repo)".lowercased()
    }

    private var actions: [Action] {
        var list: [Action] = []
        if pull.state == "open" { list.append(.checkout) }
        list.append(.openOnGitHub)
        if pull.state == "open" { list += [.merge, .close] }
        return list
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "#\(pull.number)"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        load()
    }

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            do {
                async let fresh = PullRequests.get(self.pull.number, in: self.project)
                async let files = PullRequests.files(self.pull.number, in: self.project)
                async let comments = PullRequests.comments(self.pull.number, in: self.project)
                self.pull = try await fresh
                self.files = try await files
                self.comments = try await comments
                self.filesMessage = self.files.isEmpty ? "No files changed." : nil
            } catch {
                self.filesMessage = error.localizedDescription
            }
            self.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .header, .description: return 1
        case .actions: return actions.count
        case .files: return files.count
        case .conversation: return comments.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .description: return "Description"
        case .files: return files.isEmpty ? "Files Changed" : "Files Changed (\(files.count))"
        case .conversation: return "Conversation"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .actions where isFromFork && pull.state == "open":
            return "This pull request is from \(pull.headRepo), a fork, so its branch can't be checked out here. Its changes can still be read below."
        case .files: return filesMessage
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        switch Section(rawValue: indexPath.section)! {
        case .header:
            content.text = pull.title
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.textProperties.numberOfLines = 0
            let state = pull.isMerged ? "Merged" : pull.state == "closed" ? "Closed" : pull.isDraft ? "Draft" : "Open"
            content.secondaryText = "\(state) · \(pull.author) wants to merge \(pull.headRef) into \(pull.baseRef)"
            content.secondaryTextProperties.numberOfLines = 0
            content.image = Self.icon(for: pull)
            content.imageProperties.tintColor = Self.color(for: pull)
            cell.selectionStyle = .none
        case .description:
            content = UIListContentConfiguration.cell()
            let body = pull.body.trimmingCharacters(in: .whitespacesAndNewlines)
            content.text = body.isEmpty ? "No description provided." : body
            content.textProperties.numberOfLines = 0
            content.textProperties.color = body.isEmpty ? .secondaryLabel : .label
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            cell.selectionStyle = .none
        case .actions:
            content = UIListContentConfiguration.cell()
            content.textProperties.color = .tintColor
            switch actions[indexPath.row] {
            case .checkout:
                content.text = "Check Out \(pull.headRef)"
                content.image = UIImage(systemName: "arrow.triangle.branch")
                if isFromFork { content.textProperties.color = .tertiaryLabel; cell.selectionStyle = .none }
            case .openOnGitHub:
                content.text = "Open on GitHub"
                content.image = UIImage(systemName: "safari")
            case .merge:
                content.text = "Merge Pull Request…"
                content.image = UIImage(systemName: "arrow.triangle.merge")
            case .close:
                content.text = "Close Pull Request"
                content.image = UIImage(systemName: "xmark.circle")
                content.textProperties.color = .systemRed
            }
        case .files:
            let file = files[indexPath.row]
            content.text = (file.path as NSString).lastPathComponent
            let folder = (file.path as NSString).deletingLastPathComponent
            content.secondaryText = "+\(file.additions) −\(file.deletions) · \(file.status)" + (folder.isEmpty ? "" : " · \(folder)")
            content.image = UIImage(systemName: file.status == "added" ? "plus.square" : file.status == "removed" ? "minus.square" : "doc.text")
            cell.accessoryType = .disclosureIndicator
        case .conversation:
            if indexPath.row < comments.count {
                let comment = comments[indexPath.row]
                content.text = "\(comment.author) · \(RelativeDateTimeFormatter().localizedString(for: comment.date, relativeTo: Date()))"
                content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
                content.textProperties.color = .secondaryLabel
                content.secondaryText = comment.body
                content.secondaryTextProperties.numberOfLines = 0
                content.secondaryTextProperties.color = .label
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
                cell.selectionStyle = .none
            } else {
                content = UIListContentConfiguration.cell()
                content.text = "Add a Comment…"
                content.textProperties.color = .tintColor
                content.image = UIImage(systemName: "text.bubble")
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .actions:
            switch actions[indexPath.row] {
            case .checkout:
                guard !isFromFork else { return }
                NotificationCenter.default.post(name: PullRequestsViewController.checkoutRequest, object: nil, userInfo: ["branch": pull.headRef])
                dismiss(animated: true)
            case .openOnGitHub:
                if let url = pull.url { UIApplication.shared.open(url) }
            case .merge: confirmMerge(from: tableView.cellForRow(at: indexPath))
            case .close: confirmClose()
            }
        case .files: openDiff(files[indexPath.row])
        case .conversation where indexPath.row == comments.count: promptComment()
        default: break
        }
    }

    // MARK: - Actions

    private func openDiff(_ file: PullRequestFile) {
        let pull = pull
        Task { [weak self] in
            guard let self else { return }
            do {
                var original: String?
                var modified: String?
                if file.status != "added" {
                    original = try await PullRequests.fileText(file.previousPath ?? file.path, at: pull.baseSHA, in: self.project)
                }
                if file.status != "removed" {
                    modified = try await PullRequests.fileText(file.path, at: pull.headSHA, in: self.project)
                }
                let name = (file.path as NSString).lastPathComponent
                self.onOpenDiff?(DiffRequest(path: file.path, original: original ?? "", modified: modified ?? "",
                                             title: "\(name) (#\(pull.number))"))
            } catch {
                self.showError(error)
            }
        }
    }

    private func confirmMerge(from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: "Merge #\(pull.number)?", message: "Into \(pull.baseRef) on GitHub.", preferredStyle: .actionSheet)
        for (title, method) in [("Create a Merge Commit", "merge"), ("Squash and Merge", "squash"), ("Rebase and Merge", "rebase")] {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.merge(method) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        sheet.popoverPresentationController?.sourceRect = cell?.bounds ?? view.bounds
        present(sheet, animated: true)
    }

    private func merge(_ method: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await PullRequests.merge(self.pull.number, method: method, in: self.project)
                self.onChanged?()
                self.load()
            } catch {
                self.showError(error)
            }
        }
    }

    private func confirmClose() {
        let alert = UIAlertController(title: "Close #\(pull.number)?", message: "It can be reopened on GitHub.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Close Pull Request", style: .destructive) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await PullRequests.close(self.pull.number, in: self.project)
                    self.onChanged?()
                    self.load()
                } catch {
                    self.showError(error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func promptComment() {
        let editor = CommentEditorViewController(title: "Comment on #\(pull.number)") { [weak self] text in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await PullRequests.addComment(self.pull.number, body: text, in: self.project)
                    self.load()
                } catch {
                    self.showError(error)
                }
            }
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "GitHub", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// A text box for a comment or a pull request's description, with Send.
final class CommentEditorViewController: UIViewController {
    private let textView = UITextView()
    private let onSend: (String) -> Void

    init(title: String, onSend: @escaping (String) -> Void) {
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Send", style: .done, target: self, action: #selector(sendTapped))
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 10
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
        textView.becomeFirstResponder()
    }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        navigationController?.popViewController(animated: true)
    }
}

/// Create Pull Request: from the current branch (pushed first if GitHub doesn't have it yet) into
/// the branch picked, with a title, description and draft switch.
final class CreatePullRequestViewController: UITableViewController, UITextFieldDelegate {
    var onCreated: ((PullRequest) -> Void)?
    private let project: URL
    private let branch: String
    private var base = ""
    private var bases: [String] = []
    private var isDraft = false
    private let titleField = UITextField()
    private let bodyView = UITextView()
    private var isBusy = false

    init(project: URL) {
        self.project = project
        branch = GitManager.shared.currentBranch(in: project)
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Create Pull Request"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", style: .done, target: self, action: #selector(createTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        titleField.placeholder = "Title"
        titleField.clearButtonMode = .whileEditing
        titleField.delegate = self
        // The last commit's summary, as GitHub suggests.
        titleField.text = GitManager.shared.history(in: project, limit: 1).first?.message.components(separatedBy: .newlines).first
        bodyView.font = .preferredFont(forTextStyle: .body)
        bodyView.backgroundColor = .clear
        Task { [weak self] in
            guard let self else { return }
            let main = (try? await PullRequests.defaultBranch(in: self.project)) ?? "main"
            if self.base.isEmpty { self.base = main == self.branch ? "" : main }
            GitManager.shared.remoteBranches(in: self.project) { result in
                self.bases = ((try? result.get()) ?? [main]).filter { $0 != self.branch }
                if self.base.isEmpty { self.base = self.bases.first ?? main }
                self.tableView.reloadData()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [nil, "Title", "Description"][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Changes on \(branch) that GitHub doesn't have yet are pushed first." : nil
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 2 ? 180 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            var content = UIListContentConfiguration.valueCell()
            content.text = "Merge into"
            content.secondaryText = base.isEmpty ? "…" : base
            cell.contentConfiguration = content
            // A menu of GitHub's branches.
            let button = UIButton(type: .system)
            button.setTitle("Change", for: .normal)
            button.menu = UIMenu(children: bases.map { name in
                UIAction(title: name, state: name == base ? .on : .off) { [weak self] _ in
                    self?.base = name
                    self?.tableView.reloadRows(at: [indexPath], with: .none)
                }
            })
            button.showsMenuAsPrimaryAction = true
            button.sizeToFit()
            cell.accessoryView = bases.isEmpty ? nil : button
        case (0, _):
            var content = UIListContentConfiguration.valueCell()
            content.text = "Draft"
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = isDraft
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.isDraft = toggle?.isOn ?? false }, for: .valueChanged)
            cell.accessoryView = toggle
        case (1, _):
            embed(titleField, in: cell, inset: 12)
        default:
            embed(bodyView, in: cell, inset: 6)
        }
        return cell
    }

    private func embed(_ field: UIView, in cell: UITableViewCell, inset: CGFloat) {
        field.removeFromSuperview()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: inset),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -inset),
        ])
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        bodyView.becomeFirstResponder()
        return false
    }

    @objc private func createTapped() {
        let title = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !title.isEmpty, !base.isEmpty else {
            if title.isEmpty { titleField.becomeFirstResponder() }
            return
        }
        isBusy = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let git = GitManager.shared
        let status = git.status(in: project)
        let needsPush = git.upstream(of: branch, in: project) == nil || status.aheadCount > 0
        let create = { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let pull = try await PullRequests.create(title: title, body: self.bodyView.text, head: self.branch, base: self.base,
                                                             draft: self.isDraft, in: self.project)
                    self.onCreated?(pull)
                } catch {
                    self.failed(error)
                }
            }
        }
        guard needsPush else { create(); return }
        git.push(in: project) { [weak self] result in
            switch result {
            case .success: create()
            case .failure(let error): self?.failed(error)
            }
        }
    }

    private func failed(_ error: Error) {
        isBusy = false
        navigationItem.rightBarButtonItem?.isEnabled = true
        let alert = UIAlertController(title: "Couldn't Create Pull Request", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
