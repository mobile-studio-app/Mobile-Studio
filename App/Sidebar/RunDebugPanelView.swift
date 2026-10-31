import UIKit

/// VS Code's Run and Debug view: Variables, Watch, Call Stack and Breakpoints, plus the
/// "Run and Debug" button when nothing is being debugged.
final class RunDebugPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onHeaderActionsChanged: (() -> Void)?
    /// Start a debugging session.
    var onStart: (() -> Void)?
    /// Show a place in the code (a frame or a breakpoint).
    var onReveal: ((String, Int) -> Void)?

    private enum Section: Int, CaseIterable { case variables, watch, callStack, breakpoints }

    /// A row in the Variables or Watch tree.
    private final class Node {
        let name: String
        var value: String
        var type: String
        var ref: Int?
        var isError = false
        var expanded = false
        var children: [Node]?
        init(name: String, value: String, type: String, ref: Int?) {
            self.name = name; self.value = value; self.type = type; self.ref = ref
        }
        convenience init(_ v: DebugSession.Variable) { self.init(name: v.name, value: v.value, type: v.type, ref: v.ref) }
    }

    private let startButton = VSButton(split: false)
    private let hintLabel = UILabel()
    private let startArea = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var collapsed: Set<Section> = []

    private var scopes: [Node] = []
    private var watches: [Node] = []
    private var session: DebugSession { .shared }
    private var store: BreakpointStore { .shared }

    override init(frame: CGRect) {
        super.init(frame: frame)
        startButton.setTitle("Run and Debug", icon: nil)
        startButton.mainButton.addAction(UIAction { [weak self] _ in self?.onStart?() }, for: .touchUpInside)
        hintLabel.text = "Tap left of a line number to add a breakpoint. The program pauses there, and you can step through it and see its variables."
        hintLabel.font = VS.font(12)
        hintLabel.textColor = VS.description
        hintLabel.numberOfLines = 0
        startArea.axis = .vertical
        startArea.spacing = 10
        startArea.isLayoutMarginsRelativeArrangement = true
        startArea.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        startArea.addArrangedSubview(startButton)
        startButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = VS.rowHeight
        tableView.sectionHeaderTopPadding = 0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(VSListCell.self, forCellReuseIdentifier: VSListCell.reuseID)
        tableView.register(VSPaneHeader.self, forHeaderFooterViewReuseIdentifier: VSPaneHeader.reuseID)

        let column = UIStackView(arrangedSubviews: [startArea, tableView])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(sessionChanged), name: DebugSession.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(breakpointsChanged), name: BreakpointStore.didChange, object: nil)
        sessionChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func headerActions() -> [UIView] {
        guard session.isActive else { return [] }
        return [VSIconButton(.debugRestart, label: "Restart") { [weak self] in self?.onStart?() }]
    }

    func didBecomeVisible() {
        tableView.reloadData()
    }

    // MARK: - Data

    private var lastState: DebugSession.State = .inactive
    private var lastFrame = 0

    @objc private func sessionChanged() {
        startArea.isHidden = session.isActive
        if session.state != lastState { onHeaderActionsChanged?() }
        let reload = session.state != lastState || session.selectedFrame != lastFrame
        lastState = session.state
        lastFrame = session.selectedFrame
        if session.state == .paused {
            if reload { loadScopes(); evaluateWatches() }
        } else {
            scopes = []
            watches = session.watches.map { Node(name: $0, value: "", type: "", ref: nil) }
        }
        tableView.reloadData()
    }

    @objc private func breakpointsChanged() {
        tableView.reloadSections([Section.breakpoints.rawValue], with: .none)
    }

    private func loadScopes() {
        session.scopes { [weak self] list in
            guard let self else { return }
            self.scopes = list.map(Node.init)
            // Locals open, the others closed, as in VS Code.
            if let locals = self.scopes.first { self.expand(locals) }
            self.tableView.reloadSections([Section.variables.rawValue], with: .none)
        }
    }

    private func evaluateWatches() {
        watches = session.watches.map { Node(name: $0, value: "", type: "", ref: nil) }
        for node in watches {
            session.evaluate(node.name, context: "watch") { [weak self] value, error in
                node.value = value?.value ?? error ?? "not available"
                node.type = value?.type ?? ""
                node.ref = value?.ref
                node.isError = value == nil
                self?.tableView.reloadSections([Section.watch.rawValue], with: .none)
            }
        }
    }

    private func expand(_ node: Node) {
        node.expanded = true
        guard node.children == nil, let ref = node.ref else { return }
        session.variables(ref) { [weak self] list in
            node.children = list.map(Node.init)
            self?.tableView.reloadData()
        }
    }

    /// Visible rows of a tree: (node, depth).
    private func flatten(_ nodes: [Node], depth: Int = 0) -> [(Node, Int)] {
        nodes.flatMap { node -> [(Node, Int)] in
            [(node, depth)] + (node.expanded ? flatten(node.children ?? [], depth: depth + 1) : [])
        }
    }

    private var variableRows: [(Node, Int)] { flatten(scopes) }
    private var watchRows: [(Node, Int)] { flatten(watches) }

    private var breakpointRows: [(file: String, breakpoint: Breakpoint)?] {
        [nil] + store.all.map { Optional($0) }   // nil: "Uncaught Errors"
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let kind = Section(rawValue: section)!
        if collapsed.contains(kind) { return 0 }
        switch kind {
        case .variables: return session.state == .paused ? variableRows.count : 0
        case .watch: return watchRows.count
        case .callStack: return session.state == .inactive ? 0 : max(session.frames.count, 1)
        case .breakpoints: return breakpointRows.count
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { VS.paneHeaderHeight }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: VSPaneHeader.reuseID) as! VSPaneHeader
        let kind = Section(rawValue: section)!
        let titles: [Section: String] = [.variables: "Variables", .watch: "Watch", .callStack: "Call Stack", .breakpoints: "Breakpoints"]
        var actions: [UIView] = []
        switch kind {
        case .watch:
            actions = [VSIconButton(.add, label: "Add Expression") { [weak self] in self?.addWatch() },
                       VSIconButton(.closeAll, label: "Remove All Expressions") { [weak self] in
                           self?.session.watches = []
                           self?.sessionChanged()
                       }]
        case .breakpoints:
            let allOn = store.all.allSatisfy { $0.breakpoint.enabled }
            actions = [VSIconButton(allOn ? .circleOutline : .circleFilled, label: allOn ? "Deactivate Breakpoints" : "Activate Breakpoints") { [weak self] in
                           self?.store.setAllEnabled(!allOn)
                       },
                       VSIconButton(.closeAll, label: "Remove All Breakpoints") { [weak self] in self?.store.removeAll() }]
        case .variables:
            actions = [VSIconButton(.collapseAll, label: "Collapse All") { [weak self] in
                self?.scopes.forEach { $0.expanded = false }
                self?.tableView.reloadData()
            }]
        case .callStack:
            break
        }
        var title = titles[kind]!
        if kind == .callStack, session.state == .paused { title += "  ·  Paused on \(pausedReason)" }
        header.configure(title: title, expanded: !collapsed.contains(kind), actions: actions)
        header.onToggle = { [weak self] in
            guard let self else { return }
            if self.collapsed.contains(kind) { self.collapsed.remove(kind) } else { self.collapsed.insert(kind) }
            self.tableView.reloadSections([section], with: .automatic)
        }
        return header
    }

    private var pausedReason: String {
        switch session.stopReason {
        case "breakpoint": return "breakpoint"
        case "exception": return "exception"
        case "step": return "step"
        default: return "pause"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VSListCell.reuseID, for: indexPath) as! VSListCell
        cell.isMarked = false
        cell.setTrailing([])
        switch Section(rawValue: indexPath.section)! {
        case .variables:
            let (node, depth) = variableRows[indexPath.row]
            configure(cell, node: node, depth: depth, isScope: depth == 0)
        case .watch:
            let (node, depth) = watchRows[indexPath.row]
            configure(cell, node: node, depth: depth, isScope: false)
        case .callStack:
            guard indexPath.row < session.frames.count else {
                cell.configure(depth: 0, twistie: nil, icon: nil, title: "Running", titleColor: VS.description)
                return cell
            }
            let frame = session.frames[indexPath.row]
            let selected = frame.id == session.selectedFrame
            cell.configure(depth: 0, twistie: nil, icon: indexPath.row == 0 ? .debugStackframe : nil, iconColor: VS.hex(0xFFCC00),
                           title: frame.name, description: "\(frame.file):\(frame.line)", bold: selected)
            cell.isMarked = selected
        case .breakpoints:
            guard let entry = breakpointRows[indexPath.row] else {
                cell.configure(depth: 0, twistie: nil, icon: store.stopOnErrors ? .check : .circleOutline,
                               iconColor: store.stopOnErrors ? VS.foreground : VS.description,
                               title: "Uncaught Errors", description: "pause when the program fails")
                return cell
            }
            let bp = entry.breakpoint
            let icon: Codicon = bp.logMessage?.isEmpty == false ? .debugBreakpointLog
                : (bp.condition?.isEmpty == false ? .debugBreakpointConditional : .circleFilled)
            var detail = "\(entry.file):\(bp.line)"
            if let condition = bp.condition, !condition.isEmpty { detail += "  when \(condition)" }
            if let log = bp.logMessage, !log.isEmpty { detail += "  log \(log)" }
            cell.configure(depth: 0, twistie: nil, icon: icon, iconColor: bp.enabled ? VS.hex(0xE51400) : VS.description,
                           title: (entry.file as NSString).lastPathComponent, titleColor: bp.enabled ? VS.foreground : VS.description,
                           description: detail)
        }
        return cell
    }

    private func configure(_ cell: VSListCell, node: Node, depth: Int, isScope: Bool) {
        let expandable = node.ref != nil
        let title = NSMutableAttributedString(string: node.name, attributes: [
            .font: VS.font(13, isScope ? .semibold : .regular),
            .foregroundColor: isScope ? VS.foreground : VS.hex(0xC586C0),
        ])
        if !isScope && !node.value.isEmpty {
            title.append(NSAttributedString(string: ": ", attributes: [.font: VS.font(13), .foregroundColor: VS.foreground]))
            title.append(NSAttributedString(string: node.value, attributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                                            .foregroundColor: valueColor(node)]))
        }
        cell.configure(depth: depth, twistie: expandable ? node.expanded : nil, icon: nil, attributedTitle: title)
    }

    /// VS Code's debug token colours.
    private func valueColor(_ node: Node) -> UIColor {
        if node.isError { return VS.errorForeground }
        switch node.type {
        case "string", "str": return VS.hex(0xCE9178)
        case "number", "int", "float": return VS.hex(0xB5CEA8)
        case "boolean", "bool", "nil", "NoneType": return VS.hex(0x569CD6)
        default: return VS.foreground
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        switch Section(rawValue: indexPath.section)! {
        case .variables, .watch:
            let rows = indexPath.section == Section.variables.rawValue ? variableRows : watchRows
            let node = rows[indexPath.row].0
            guard node.ref != nil else { return }
            if node.expanded { node.expanded = false; tableView.reloadData() } else { expand(node); tableView.reloadData() }
        case .callStack:
            guard indexPath.row < session.frames.count else { return }
            let frame = session.frames[indexPath.row]
            session.selectedFrame = frame.id
            onReveal?(frame.file, frame.line)
        case .breakpoints:
            guard let entry = breakpointRows[indexPath.row] else {
                store.stopOnErrors.toggle()
                return
            }
            onReveal?(entry.file, entry.breakpoint.line)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        switch Section(rawValue: indexPath.section)! {
        case .watch:
            let row = watchRows[indexPath.row]
            guard row.1 == 0, let index = watches.firstIndex(where: { $0 === row.0 }) else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Edit Expression", image: Codicon.edit.image()) { _ in self?.addWatch(editing: index) },
                    UIAction(title: "Remove Expression", image: Codicon.close.image(), attributes: .destructive) { _ in
                        guard let self else { return }
                        var list = self.session.watches
                        if index < list.count { list.remove(at: index) }
                        self.session.watches = list
                        self.sessionChanged()
                    },
                ])
            })
        case .variables:
            let node = variableRows[indexPath.row].0
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Copy Value", image: Codicon.copy.image()) { _ in UIPasteboard.general.string = node.value },
                    UIAction(title: "Add to Watch", image: Codicon.eye.image()) { _ in
                        guard let self else { return }
                        self.session.watches = self.session.watches + [node.name]
                        self.evaluateWatches()
                    },
                ])
            })
        case .breakpoints:
            guard let entry = breakpointRows[indexPath.row] else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Edit Condition…", image: Codicon.debugBreakpointConditional.image()) { _ in
                        self?.editBreakpoint(entry.file, entry.breakpoint, log: false)
                    },
                    UIAction(title: "Edit Log Message…", image: Codicon.debugBreakpointLog.image()) { _ in
                        self?.editBreakpoint(entry.file, entry.breakpoint, log: true)
                    },
                    UIAction(title: entry.breakpoint.enabled ? "Disable Breakpoint" : "Enable Breakpoint", image: Codicon.circleOutline.image()) { _ in
                        var bp = entry.breakpoint
                        bp.enabled.toggle()
                        self?.store.update(bp, in: entry.file)
                    },
                    UIAction(title: "Remove Breakpoint", image: Codicon.close.image(), attributes: .destructive) { _ in
                        self?.store.remove(line: entry.breakpoint.line, in: entry.file)
                    },
                ])
            })
        case .callStack:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == Section.breakpoints.rawValue, let entry = breakpointRows[indexPath.row] else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            self?.store.remove(line: entry.breakpoint.line, in: entry.file)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    // MARK: - Editing

    private func addWatch(editing index: Int? = nil) {
        let alert = UIAlertController(title: index == nil ? "Add Watch Expression" : "Edit Watch Expression", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Expression to watch"
            field.text = index.flatMap { self.session.watches.indices.contains($0) ? self.session.watches[$0] : nil }
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: index == nil ? "Add" : "Save", style: .default) { [weak self] _ in
            guard let self, let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
            var list = self.session.watches
            if let index, index < list.count { list[index] = text } else { list.append(text) }
            self.session.watches = list
            if self.session.state == .paused { self.evaluateWatches() } else { self.sessionChanged() }
        })
        presenter?.present(alert, animated: true)
    }

    private func editBreakpoint(_ file: String, _ breakpoint: Breakpoint, log: Bool) {
        let alert = UIAlertController(title: log ? "Log Message" : "Condition",
                                      message: log ? "Printed when the line runs, without stopping. {expression} shows a value."
                                                   : "Stop only when this expression is true.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = log ? breakpoint.logMessage : breakpoint.condition
            field.placeholder = log ? "x is {x}" : "x > 10"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            var bp = breakpoint
            let text = alert.textFields?.first?.text ?? ""
            if log { bp.logMessage = text.isEmpty ? nil : text } else { bp.condition = text.isEmpty ? nil : text }
            self?.store.update(bp, in: file)
        })
        presenter?.present(alert, animated: true)
    }
}

/// VS Code's floating debug toolbar: Continue/Pause, Step Over, Step Into, Step Out, Restart, Stop.
final class DebugToolbar: UIView {
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?

    private let continueButton = VSIconButton(.debugContinue, label: "Continue")
    private let stepOverButton = VSIconButton(.debugStepOver, label: "Step Over")
    private let stepIntoButton = VSIconButton(.debugStepInto, label: "Step Into")
    private let stepOutButton = VSIconButton(.debugStepOut, label: "Step Out")
    private let restartButton = VSIconButton(.debugRestart, label: "Restart")
    private let stopButton = VSIconButton(.debugStop, label: "Stop")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = VS.hex(0x333333)
        layer.cornerRadius = 4
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        let grip = UIImageView(image: UIImage(systemName: "circle.grid.2x1.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 7)))
        grip.tintColor = VS.description
        grip.contentMode = .center
        let stack = UIStackView(arrangedSubviews: [grip, continueButton, stepOverButton, stepIntoButton, stepOutButton, restartButton, stopButton])
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            grip.widthAnchor.constraint(equalToConstant: 10),
        ])
        for button in [continueButton, stepOverButton, stepIntoButton, stepOutButton, restartButton, stopButton] {
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        continueButton.addAction(UIAction { _ in
            let session = DebugSession.shared
            if session.state == .paused { session.resume() } else { session.pause() }
        }, for: .touchUpInside)
        stepOverButton.addAction(UIAction { _ in DebugSession.shared.stepOver() }, for: .touchUpInside)
        stepIntoButton.addAction(UIAction { _ in DebugSession.shared.stepInto() }, for: .touchUpInside)
        stepOutButton.addAction(UIAction { _ in DebugSession.shared.stepOut() }, for: .touchUpInside)
        restartButton.addAction(UIAction { [weak self] _ in self?.onRestart?() }, for: .touchUpInside)
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        restartButton.tintColor = VS.hex(0x89D185)
        stopButton.tintColor = VS.hex(0xF48771)
        continueButton.tintColor = VS.hex(0x75BEFF)
        for b in [stepOverButton, stepIntoButton, stepOutButton] { b.tintColor = VS.hex(0x75BEFF) }

        // Drag it out of the way, as in VS Code.
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: DebugSession.didChange, object: nil)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func update() {
        let paused = DebugSession.shared.state == .paused
        continueButton.setIcon(paused ? .debugContinue : .debugPause)
        continueButton.accessibilityLabel = paused ? "Continue" : "Pause"
        for b in [stepOverButton, stepIntoButton, stepOutButton] {
            b.isEnabled = paused
            b.alpha = paused ? 1 : 0.4
        }
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: superview)
        transform = transform.translatedBy(x: t.x, y: t.y)
        gesture.setTranslation(.zero, in: superview)
    }
}
