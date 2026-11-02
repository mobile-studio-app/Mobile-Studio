import UIKit

/// git rebase -i's todo list, as a sheet: the commits since the base, oldest first, each with
/// what to do with it (pick, reword, edit, squash, fixup, drop), in an order you can drag.
final class InteractiveRebaseViewController: UITableViewController {
    /// Posted to open the sheet (the Terminal's git rebase -i); userInfo "base".
    static let request = GitCommandLine.interactiveRebaseRequest

    private let base: String
    private var steps: [GitRebaseStep]
    var onStart: (([GitRebaseStep]) -> Void)?

    init(base: String, steps: [GitRebaseStep]) {
        self.base = base
        self.steps = steps
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Interactive Rebase"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Rebase", style: .done, target: self, action: #selector(startTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Step")
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
        updateStartButton()
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func startTapped() {
        let steps = self.steps
        dismiss(animated: true) { [onStart] in onStart?(steps) }
    }

    private func updateStartButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !steps.isEmpty
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { steps.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Onto \(base), oldest first"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        """
        Drag to reorder. Pick keeps a commit; Reword keeps it with a new message (tap it to write one); \
        Edit stops after it so you can amend it; Squash folds it into the one above, joining the messages; \
        Fixup folds it in, keeping the one above's message; Drop leaves it out.
        """
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Step", for: indexPath)
        let step = steps[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = step.action == .reword || step.action == .squash ? (step.message.components(separatedBy: .newlines).first ?? step.summary) : step.summary
        content.secondaryText = step.shortId + (step.action == .reword ? " · new message" : "")
        content.textProperties.color = step.action == .drop ? .tertiaryLabel : .label
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.contentConfiguration = content
        cell.accessoryView = actionButton(for: indexPath.row)
        cell.editingAccessoryView = cell.accessoryView
        cell.accessibilityLabel = "\(step.action.rawValue), \(step.summary)"
        return cell
    }

    private func actionButton(for row: Int) -> UIButton {
        let step = steps[row]
        var config = UIButton.Configuration.tinted()
        config.title = step.action.rawValue
        config.baseForegroundColor = color(step.action)
        config.baseBackgroundColor = color(step.action)
        config.buttonSize = .small
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Action: \(step.action.rawValue)"
        button.menu = UIMenu(children: GitRebaseStep.Action.allCases.map { action in
            UIAction(title: action.rawValue.capitalized, subtitle: Self.help[action], state: action == step.action ? .on : .off) { [weak self] _ in
                self?.set(action, at: row)
            }
        })
        button.sizeToFit()
        return button
    }

    private static let help: [GitRebaseStep.Action: String] = [
        .pick: "Keep it", .reword: "Keep it, with a new message", .edit: "Stop after it to amend it",
        .squash: "Fold into the one above, joining messages", .fixup: "Fold into the one above", .drop: "Leave it out",
    ]

    private func color(_ action: GitRebaseStep.Action) -> UIColor {
        switch action {
        case .pick: return .systemBlue
        case .reword: return .systemTeal
        case .edit: return .systemOrange
        case .squash, .fixup: return .systemPurple
        case .drop: return .systemRed
        }
    }

    private func set(_ action: GitRebaseStep.Action, at row: Int) {
        if (action == .squash || action == .fixup) && !steps[..<row].contains(where: { $0.action != .drop }) {
            alert("The first commit has nothing above it to fold into.")
            return
        }
        steps[row].action = action
        if action == .squash {
            // The joined message, to edit before starting.
            let above = steps[..<row].last { $0.action != .drop }
            steps[row].message = [above?.message, steps[row].message].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        }
        tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        updateStartButton()
        if action == .reword { editMessage(at: row) }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if steps[indexPath.row].action == .pick { set(.reword, at: indexPath.row) } else if [.reword, .squash].contains(steps[indexPath.row].action) {
            editMessage(at: indexPath.row)
        }
    }

    private func editMessage(at row: Int) {
        let sheet = MessageEditorViewController(message: steps[row].message) { [weak self] message in
            self?.steps[row].message = message
            self?.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        }
        present(UINavigationController(rootViewController: sheet), animated: true)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let step = steps.remove(at: source.row)
        steps.insert(step, at: destination.row)
        // A squash or fixup that's now first has nothing to fold into.
        if let first = steps.firstIndex(where: { $0.action != .drop }), [.squash, .fixup].contains(steps[first].action) { steps[first].action = .pick }
        DispatchQueue.main.async { tableView.reloadData() }
    }

    private func alert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// A commit message to edit, for reword and squash.
final class MessageEditorViewController: UIViewController {
    private let textView = UITextView()
    private let message: String
    private let onSave: (String) -> Void

    init(message: String, onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Commit Message"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        textView.text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .default
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onSave(text + "\n") }
        dismiss(animated: true)
    }
}
