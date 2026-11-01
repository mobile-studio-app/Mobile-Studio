import UIKit

/// The Search view, laid out like VS Code's: a replace toggle beside the search and replace
/// inputs (with inline Match Case / Whole Word / Regex / Preserve Case toggles), "files to
/// include/exclude" behind the ellipsis, then results as a list or a folder tree.
final class SearchPanelView: UIView, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    /// Open a file with a match selected: path, 1-based line, UTF-16 column and length.
    var onOpenMatch: ((String, Int, Int, Int) -> Void)?
    var onSaveEdits: ((@escaping () -> Void) -> Void)?
    var onFilesChangedOnDisk: (() -> Void)?
    /// The header buttons changed (Collapse All / Expand All, Tree / List).
    var onHeaderActionsChanged: (() -> Void)?

    private var query = SearchQuery()
    private var preserveCase = false
    private var showReplace = false { didSet { updateReplaceVisibility() } }
    private var showDetails = false { didSet { detailsStack.isHidden = !showDetails; detailsButton.isChecked = showDetails } }
    private var viewAsTree = UserDefaults.standard.bool(forKey: "duocode.search.tree") {
        didSet { UserDefaults.standard.set(viewAsTree, forKey: "duocode.search.tree") }
    }

    private var outcome = SearchOutcome()
    private var regex: NSRegularExpression?
    private var collapsed: Set<String> = []
    private var rows: [Row] = []
    private var cancellation: SearchCancellation?
    private var debounce: DispatchWorkItem?
    private var searchGeneration = 0

    private enum Row {
        case folder(path: String, name: String, depth: Int, count: Int)
        case file(Int, depth: Int)
        case match(file: Int, match: Int, depth: Int)
    }

    // Inputs
    private let replaceToggle = UIButton(type: .custom)
    private let searchField = VSTextField(placeholder: "Search")
    private let replaceField = VSTextField(placeholder: "Replace")
    private let replaceRow = UIStackView()
    private let validationLabel = PaddedLabel()
    private lazy var caseButton = VSIconButton(.caseSensitive, label: "Match Case", style: .option) { [weak self] in self?.toggle(\.matchCase) }
    private lazy var wordButton = VSIconButton(.wholeWord, label: "Match Whole Word", style: .option) { [weak self] in self?.toggle(\.wholeWord) }
    private lazy var regexButton = VSIconButton(.regex, label: "Use Regular Expression", style: .option) { [weak self] in self?.toggle(\.isRegex) }
    private lazy var preserveCaseButton = VSIconButton(.preserveCase, label: "Preserve Case", style: .option) { [weak self] in
        self?.togglePreserveCase()
    }
    private lazy var replaceAllButton = VSIconButton(.replaceAll, label: "Replace All") { [weak self] in self?.confirmReplaceAll() }
    private lazy var detailsButton = VSIconButton(.ellipsis, label: "Toggle Search Details", style: .option) { [weak self] in
        self?.showDetails.toggle()
    }
    private let detailsStack = UIStackView()
    private let includeField = VSTextField(placeholder: "e.g. *.lua, src/**/include")
    private let excludeField = VSTextField(placeholder: "e.g. *.json, libs")
    private let messageLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupInputs()
        setupTable()
        updateReplaceVisibility()
        NotificationCenter.default.addObserver(forName: FileIconTheme.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupInputs() {
        replaceToggle.setImage(Codicon.chevronRight.image(16), for: .normal)
        replaceToggle.tintColor = VS.icon
        replaceToggle.accessibilityLabel = "Toggle Replace"
        replaceToggle.layer.cornerRadius = 3
        replaceToggle.addAction(UIAction { [weak self] _ in self?.showReplace.toggle() }, for: .touchUpInside)
        replaceToggle.translatesAutoresizingMaskIntoConstraints = false
        replaceToggle.widthAnchor.constraint(equalToConstant: 18).isActive = true

        for field in [searchField, replaceField, includeField, excludeField] {
            field.delegate = self
            field.addTarget(self, action: #selector(inputChanged(_:)), for: .editingChanged)
        }
        searchField.setOptions([caseButton, wordButton, regexButton])
        replaceField.setOptions([preserveCaseButton])
        replaceField.returnKeyType = .done

        validationLabel.font = VS.font(12)
        validationLabel.textColor = VS.foreground
        validationLabel.backgroundColor = VS.errorBackground
        validationLabel.layer.borderColor = VS.errorBorder.cgColor
        validationLabel.layer.borderWidth = 1
        validationLabel.numberOfLines = 0
        validationLabel.isHidden = true

        replaceRow.axis = .horizontal
        replaceRow.spacing = 2
        replaceRow.alignment = .center
        replaceRow.addArrangedSubview(replaceField)
        replaceRow.addArrangedSubview(replaceAllButton)

        let inputs = UIStackView(arrangedSubviews: [searchField, validationLabel, replaceRow])
        inputs.axis = .vertical
        inputs.spacing = 4

        let top = UIStackView(arrangedSubviews: [replaceToggle, inputs])
        top.axis = .horizontal
        top.spacing = 2
        top.alignment = .fill

        let detailsRow = UIStackView(arrangedSubviews: [UIView(), detailsButton])
        detailsRow.axis = .horizontal

        detailsStack.axis = .vertical
        detailsStack.spacing = 2
        detailsStack.isHidden = true
        for (title, field) in [("files to include", includeField), ("files to exclude", excludeField)] {
            let label = UILabel()
            label.text = title
            label.font = VS.font(11)
            label.textColor = VS.foreground
            detailsStack.addArrangedSubview(label)
            detailsStack.addArrangedSubview(field)
            detailsStack.setCustomSpacing(6, after: field)
        }

        messageLabel.font = VS.font(12)
        messageLabel.textColor = VS.description
        messageLabel.numberOfLines = 0

        let column = UIStackView(arrangedSubviews: [top, detailsRow, detailsStack, messageLabel])
        column.axis = .vertical
        column.spacing = 2
        column.setCustomSpacing(4, after: detailsStack)
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(top: 0, left: 2, bottom: 6, right: 10)
        // The details stack sits under the inputs, not under the toggle.
        detailsStack.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        detailsStack.isLayoutMarginsRelativeArrangement = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: column.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            replaceAllButton.widthAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func setupTable() {
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = VS.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(VSListCell.self, forCellReuseIdentifier: VSListCell.reuseID)
        tableView.sectionHeaderTopPadding = 0
    }

    private func updateReplaceVisibility() {
        replaceRow.isHidden = !showReplace
        replaceToggle.setImage((showReplace ? Codicon.chevronDown : .chevronRight).image(16), for: .normal)
        replaceToggle.accessibilityValue = showReplace ? "expanded" : "collapsed"
        updateReplaceAllEnabled()
        tableView.reloadData()
    }

    private func updateReplaceAllEnabled() {
        replaceAllButton.isEnabled = !outcome.files.isEmpty
    }

    // MARK: - Header

    /// The view title's actions: Refresh, Clear, Tree/List and Collapse/Expand All.
    func headerActions() -> [UIView] {
        let refresh = VSIconButton(.refresh, label: "Refresh") { [weak self] in self?.runSearch() }
        refresh.isEnabled = !query.text.isEmpty
        let clear = VSIconButton(.clearAll, label: "Clear Search Results") { [weak self] in self?.clear() }
        clear.isEnabled = !query.text.isEmpty || !outcome.files.isEmpty
        let viewMode = VSIconButton(viewAsTree ? .listFlat : .listTree, label: viewAsTree ? "View as List" : "View as Tree") { [weak self] in
            guard let self else { return }
            self.viewAsTree.toggle()
            self.rebuildRows()
            self.onHeaderActionsChanged?()
        }
        let allCollapsed = !outcome.files.isEmpty && outcome.files.allSatisfy { collapsed.contains(fileKey($0.path)) }
        let collapse = VSIconButton(allCollapsed ? .expandAll : .collapseAll, label: allCollapsed ? "Expand All" : "Collapse All") { [weak self] in
            guard let self else { return }
            if allCollapsed { self.collapsed.removeAll() } else { self.collapseAll() }
            self.rebuildRows()
            self.onHeaderActionsChanged?()
        }
        collapse.isEnabled = !outcome.files.isEmpty
        return [refresh, clear, viewMode, collapse]
    }

    /// Called when the Search view opens: put the cursor in the box if it's empty, as VS Code does.
    func didBecomeVisible() {
        if query.text.isEmpty { _ = searchField.becomeFirstResponder() }
    }

    func reset() {
        cancellation?.cancel()
        searchField.text = ""
        replaceField.text = ""
        query.text = ""
        outcome = SearchOutcome()
        collapsed.removeAll()
        setValidation(nil)
        rebuildRows()
        onHeaderActionsChanged?()
    }

    private func clear() {
        reset()
        _ = searchField.becomeFirstResponder()
    }

    private func collapseAll() {
        for file in outcome.files { collapsed.insert(fileKey(file.path)) }
    }

    // MARK: - Input

    private func toggle(_ option: WritableKeyPath<SearchQuery, Bool>) {
        query[keyPath: option].toggle()
        caseButton.isChecked = query.matchCase
        wordButton.isChecked = query.wholeWord
        regexButton.isChecked = query.isRegex
        runSearch()
    }

    private func togglePreserveCase() {
        preserveCase.toggle()
        preserveCaseButton.isChecked = preserveCase
        tableView.reloadData()
    }

    @objc private func inputChanged(_ field: UITextField) {
        if field === replaceField {
            tableView.reloadData()   // the preview shows the replacement
            return
        }
        query.text = searchField.text ?? ""
        query.include = includeField.text ?? ""
        query.exclude = excludeField.text ?? ""
        // Search as you type, after a pause (VS Code's search.searchOnTypeDebouncePeriod).
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === replaceField {
            textField.resignFirstResponder()
        } else {
            runSearch()
        }
        return true
    }

    private var replaceText: String { replaceField.text ?? "" }

    // MARK: - Searching

    func runSearch() {
        debounce?.cancel()
        cancellation?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        guard !query.text.isEmpty else {
            outcome = SearchOutcome()
            setValidation(nil)
            rebuildRows()
            onHeaderActionsChanged?()
            return
        }
        do {
            regex = try query.regex()
            setValidation(nil)
        } catch {
            regex = nil
            outcome = SearchOutcome()
            setValidation(error.localizedDescription)
            rebuildRows()
            return
        }
        let token = SearchCancellation()
        cancellation = token
        let q = query
        // Search what's on disk, so write the open file first.
        saveEdits { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            let root = ProjectStore.shared.currentProject
            let paths = ProjectStore.shared.list()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = (try? ProjectSearch.run(q, root: root, paths: paths, cancellation: token)) ?? SearchOutcome()
                DispatchQueue.main.async {
                    guard generation == self.searchGeneration else { return }
                    self.outcome = result
                    self.rebuildRows()
                    self.onHeaderActionsChanged?()
                }
            }
        }
    }

    private func saveEdits(_ then: @escaping () -> Void) {
        if let onSaveEdits { onSaveEdits(then) } else { then() }
    }

    private func setValidation(_ message: String?) {
        validationLabel.text = message
        validationLabel.isHidden = message == nil
        searchField.layer.borderColor = message == nil
            ? (searchField.isFirstResponder ? VS.focusBorder : UIColor.clear).cgColor
            : VS.errorBorder.cgColor
    }

    private func updateMessage() {
        let files = outcome.files.count
        let count = outcome.matchCount
        if query.text.isEmpty || regex == nil {
            messageLabel.text = nil
        } else if count == 0 {
            messageLabel.text = query.include.isEmpty && query.exclude.isEmpty
                ? "No results found."
                : "No results found. Review your include and exclude patterns."
        } else {
            var text = "\(count) result\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
            if outcome.limitHit { text += " (the first \(ProjectSearch.maxResults) results; narrow your search to see the rest)" }
            messageLabel.text = text
        }
        messageLabel.isHidden = messageLabel.text == nil
    }

    // MARK: - Rows

    private func fileKey(_ path: String) -> String { "f:" + path }
    private func folderKey(_ path: String) -> String { "d:" + path }

    private func rebuildRows() {
        rows = []
        if viewAsTree {
            let root = FolderNode(name: "", path: "")
            for (index, file) in outcome.files.enumerated() {
                var node = root
                for part in file.path.split(separator: "/").dropLast().map(String.init) {
                    node = node.child(part)
                }
                node.files.append(index)
            }
            root.compact()
            appendRows(root, depth: 0)
        } else {
            for (index, file) in outcome.files.enumerated() {
                appendFile(index, file: file, depth: 0)
            }
        }
        updateMessage()
        updateReplaceAllEnabled()
        tableView.reloadData()
    }

    private func appendRows(_ node: FolderNode, depth: Int) {
        for child in node.sortedChildren {
            let count = child.allFiles.reduce(0) { $0 + outcome.files[$1].matches.count }
            rows.append(.folder(path: child.path, name: child.name, depth: depth, count: count))
            if !collapsed.contains(folderKey(child.path)) { appendRows(child, depth: depth + 1) }
        }
        for index in node.files.sorted(by: { outcome.files[$0].path.localizedStandardCompare(outcome.files[$1].path) == .orderedAscending }) {
            appendFile(index, file: outcome.files[index], depth: depth)
        }
    }

    private func appendFile(_ index: Int, file: SearchFileResult, depth: Int) {
        rows.append(.file(index, depth: depth))
        guard !collapsed.contains(fileKey(file.path)) else { return }
        for m in file.matches.indices {
            rows.append(.match(file: index, match: m, depth: depth + 1))
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VSListCell.reuseID, for: indexPath) as! VSListCell
        switch rows[indexPath.row] {
        case let .folder(path, name, depth, count):
            cell.configure(depth: depth, twistie: !collapsed.contains(folderKey(path)), icon: nil, title: name)
            cell.setTrailing([badge(count)])
        case let .file(index, depth):
            let file = outcome.files[index]
            let name = (file.path as NSString).lastPathComponent
            let folder = (file.path as NSString).deletingLastPathComponent
            let (icon, color) = VS.fileIcon(name)
            cell.configure(depth: depth, twistie: !collapsed.contains(fileKey(file.path)), icon: icon, iconColor: color,
                           title: name, description: viewAsTree ? nil : folder)
            cell.useThemeIcon(file: name)
            cell.setTrailing([badge(file.matches.count)])
        case let .match(fileIndex, matchIndex, depth):
            let match = outcome.files[fileIndex].matches[matchIndex]
            cell.configure(depth: depth, twistie: nil, icon: nil, attributedTitle: preview(match))
            cell.accessibilityLabel = "Line \(match.line): \(match.lineText.trimmingCharacters(in: .whitespaces))"
        }
        return cell
    }

    private func badge(_ count: Int) -> VSBadge {
        let badge = VSBadge()
        badge.text = "\(count)"
        return badge
    }

    /// The line around the match with the match highlighted, or struck through beside its
    /// replacement while Replace is open.
    private func preview(_ match: SearchMatch) -> NSAttributedString {
        let line = match.lineText as NSString
        let column = min(match.column, line.length)
        let length = min(match.matchedText.utf16.count, line.length - column)
        let contextStart = max(0, column - 26)
        var before = line.substring(with: NSRange(location: contextStart, length: column - contextStart))
        before = contextStart == 0 ? String(before.drop { $0 == " " || $0 == "\t" }) : "…" + before
        let afterLength = min(line.length - column - length, 160)
        let after = line.substring(with: NSRange(location: column + length, length: max(0, afterLength)))
        let matched = line.substring(with: NSRange(location: column, length: length))

        let base: [NSAttributedString.Key: Any] = [.font: VS.font(13), .foregroundColor: VS.foreground]
        let text = NSMutableAttributedString(string: before, attributes: base)
        if showReplace, let regex {
            var removed = base
            removed[.backgroundColor] = VS.removedText
            removed[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            text.append(NSAttributedString(string: matched, attributes: removed))
            let replacement = ProjectSearch.previewReplacement(for: match, regex: regex, query: query,
                                                               replaceText: replaceText, preserveCase: preserveCase)
            var inserted = base
            inserted[.backgroundColor] = VS.insertedText
            text.append(NSAttributedString(string: replacement, attributes: inserted))
        } else {
            var highlighted = base
            highlighted[.backgroundColor] = VS.findMatch
            text.append(NSAttributedString(string: matched, attributes: highlighted))
        }
        text.append(NSAttributedString(string: after, attributes: base))
        return text
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case let .folder(path, _, _, _):
            toggleCollapsed(folderKey(path))
        case let .file(index, _):
            toggleCollapsed(fileKey(outcome.files[index].path))
        case let .match(fileIndex, matchIndex, _):
            let file = outcome.files[fileIndex]
            let match = file.matches[matchIndex]
            endEditing(true)
            onOpenMatch?(file.path, match.line, match.column, match.matchedText.utf16.count)
        }
    }

    private func toggleCollapsed(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        rebuildRows()
        onHeaderActionsChanged?()
    }

    // MARK: - Row actions (VS Code shows these on hover; here they're swipe actions and the long-press menu)

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        var actions: [UIContextualAction] = []
        let dismiss = UIContextualAction(style: .normal, title: "Dismiss") { [weak self] _, _, done in
            self?.dismiss(indexPath.row)
            done(true)
        }
        dismiss.image = Codicon.close.image(16)
        dismiss.backgroundColor = VS.badgeBackground
        actions.append(dismiss)
        if showReplace, rowCanReplace(indexPath.row) {
            let replace = UIContextualAction(style: .normal, title: "Replace") { [weak self] _, _, done in
                self?.replace(row: indexPath.row)
                done(true)
            }
            replace.image = Codicon.replace.image(16)
            replace.backgroundColor = VS.buttonBackground
            actions.append(replace)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    private func rowCanReplace(_ row: Int) -> Bool {
        if case .folder = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let row = indexPath.row
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var items: [UIMenuElement] = []
            switch self.rows[row] {
            case let .match(fileIndex, matchIndex, _):
                let file = self.outcome.files[fileIndex]
                let match = file.matches[matchIndex]
                if self.showReplace {
                    items.append(UIAction(title: "Replace", image: Codicon.replace.image()) { _ in self.replace(row: row) })
                }
                items.append(UIAction(title: "Copy", image: Codicon.copy.image()) { _ in
                    UIPasteboard.general.string = "  \(match.line),\(match.column + 1): \(match.lineText.trimmingCharacters(in: .whitespaces))"
                })
                items.append(UIAction(title: "Copy Path", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = file.path })
            case let .file(fileIndex, _):
                let file = self.outcome.files[fileIndex]
                if self.showReplace {
                    items.append(UIAction(title: "Replace All", image: Codicon.replaceAll.image()) { _ in self.replace(row: row) })
                }
                items.append(UIAction(title: "Copy Path", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = file.path })
                items.append(UIAction(title: "Copy All", image: Codicon.copy.image()) { _ in
                    UIPasteboard.general.string = self.copyText(for: [file])
                })
            case let .folder(path, _, _, _):
                items.append(UIAction(title: "Copy Path", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = path })
            }
            items.append(UIAction(title: "Dismiss", image: Codicon.close.image()) { _ in self.dismiss(row) })
            return UIMenu(children: items)
        }
    }

    private func copyText(for files: [SearchFileResult]) -> String {
        files.map { file in
            ([file.path] + file.matches.map { "  \($0.line),\($0.column + 1): \($0.lineText.trimmingCharacters(in: .whitespaces))" })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The results a row covers: a match, a file's matches, or every file under a folder.
    private func targets(of row: Int) -> [(file: Int, matches: [Int])] {
        switch rows[row] {
        case let .match(file, match, _):
            return [(file, [match])]
        case let .file(file, _):
            return [(file, Array(outcome.files[file].matches.indices))]
        case let .folder(path, _, _, _):
            return outcome.files.indices.filter { outcome.files[$0].path.hasPrefix(path + "/") }
                .map { ($0, Array(outcome.files[$0].matches.indices)) }
        }
    }

    /// Removes results from the list without changing any files.
    private func dismiss(_ row: Int) {
        guard row < rows.count else { return }
        var files = outcome.files
        for (file, matches) in targets(of: row) {
            let drop = Set(matches)
            files[file].matches = files[file].matches.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        outcome.files = files.filter { !$0.matches.isEmpty }
        rebuildRows()
        onHeaderActionsChanged?()
    }

    // MARK: - Replace

    private func replace(row: Int) {
        guard row < rows.count else { return }
        replace(targets(of: row))
    }

    private func confirmReplaceAll() {
        let count = outcome.matchCount
        let files = outcome.files.count
        guard count > 0 else { return }
        let with = replaceText.isEmpty ? "" : " with '\(replaceText)'"
        let alert = UIAlertController(
            title: "Replace All",
            message: "Replace \(count) occurrence\(count == 1 ? "" : "s") across \(files) file\(files == 1 ? "" : "s")\(with)?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Replace", style: .default) { [weak self] _ in
            guard let self else { return }
            self.replace(self.outcome.files.indices.map { ($0, Array(self.outcome.files[$0].matches.indices)) })
        })
        presenter?.present(alert, animated: true)
    }

    private func replace(_ targets: [(file: Int, matches: [Int])]) {
        let jobs: [(path: String, matches: [SearchMatch])] = targets.map { target in
            let file = outcome.files[target.file]
            return (file.path, target.matches.map { file.matches[$0] })
        }
        let q = query
        let text = replaceText
        let keepCase = preserveCase
        saveEdits { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for job in jobs {
                do {
                    let url = try ProjectStore.shared.resolve(job.path)
                    _ = try ProjectSearch.replace(job.matches, in: url, query: q, replaceText: text, preserveCase: keepCase)
                } catch {
                    failures.append(job.path)
                }
            }
            self.onFilesChangedOnDisk?()
            self.runSearch()
            if !failures.isEmpty {
                let alert = UIAlertController(title: "Replace Failed",
                                              message: "Couldn't write \(failures.joined(separator: ", ")).", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.presenter?.present(alert, animated: true)
            }
        }
    }
}

/// Folder grouping for tree views. Chains of single folders are joined ("src/game"), as VS Code's compact folders do.
final class FolderNode {
    var name: String
    var path: String
    var children: [String: FolderNode] = [:]
    var files: [Int] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    func child(_ part: String) -> FolderNode {
        if let existing = children[part] { return existing }
        let node = FolderNode(name: part, path: path.isEmpty ? part : path + "/" + part)
        children[part] = node
        return node
    }

    var sortedChildren: [FolderNode] {
        children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var allFiles: [Int] {
        files + children.values.flatMap(\.allFiles)
    }

    func compact() {
        for (key, child) in children {
            var node = child
            while node.files.isEmpty, node.children.count == 1, let only = node.children.values.first {
                only.name = node.name + "/" + only.name
                node = only
            }
            children[key] = node
            node.compact()
        }
    }
}

/// A label with VS Code's input validation padding.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}
