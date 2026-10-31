import UIKit

/// The side bar views extensions contribute ("views" in package.json): each is a collapsible
/// section, as in VS Code's view containers. Tree views show the extension's TreeDataProvider
/// items; webview views open in an editor tab. The items come from the extension host through
/// the editor page (window.duocode.viewChildren and friends).
///
/// An extension's own view containers ("viewsContainers": activity bar and secondary side bar)
/// each get an activity bar button with the extension's icon (`containers`); the panel then
/// shows that container's views. Views in VS Code's built-in containers (Explorer, Source
/// Control...) show under the Extension Views button (`container` nil). Views whose `when`
/// clause is false are hidden, as in VS Code.
final class ExtensionViewsPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    /// Calls an async function on the editor page: (JavaScript body, arguments, result).
    var callEditor: ((String, [String: Any], @escaping (Any?) -> Void) -> Void)?
    var onHeaderActionsChanged: (() -> Void)?

    /// Posted by the editor bridge when a tree's items changed (userInfo "viewId").
    static let viewChanged = Notification.Name("DuoCodeExtensionViewChanged")
    /// Context keys extensions set with the setContext command, for `when` clauses.
    static var contextKeys: [String: Any] = [:] {
        didSet { NotificationCenter.default.post(name: contextChanged, object: nil) }
    }
    /// Posted when a context key changes: which views (and containers) show may change.
    static let contextChanged = Notification.Name("DuoCodeExtensionContextChanged")

    struct View {
        let id: String
        let name: String
        let extensionName: String
        let isWebview: Bool
        let when: String?
        /// The view container it's in: an extension's own, or a built-in one ("explorer").
        let container: String
    }

    /// An extension's own view container: an activity bar button.
    struct Container {
        let id: String
        let title: String
        /// "$(codicon)", or a file in the extension (SVG or PNG).
        let icon: String?
        let extensionPath: String
        let when: String?
    }

    struct Item {
        let handle: String
        let label: String
        let description: String
        let tooltip: String
        let codicon: String?
        let collapsible: Int
        let contextValue: String
        let hasCommand: Bool
        let checked: Bool?

        init(_ json: [String: Any]) {
            handle = json["handle"] as? String ?? ""
            label = json["label"] as? String ?? ""
            description = json["description"] as? String ?? ""
            tooltip = json["tooltip"] as? String ?? ""
            codicon = json["codicon"] as? String
            collapsible = json["collapsible"] as? Int ?? 0
            contextValue = json["contextValue"] as? String ?? ""
            hasCommand = json["hasCommand"] as? Bool ?? false
            checked = json["checked"] as? Bool
        }
    }

    private enum Row {
        case item(Item, depth: Int)
        case message(String)
        case openWebview
    }

    private struct MenuEntry {
        let command: String
        let title: String
        let icon: String?
        let when: String?
        let group: String
    }

    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    /// Every contributed view, and the ones showing (in `container`, with a true `when`).
    private var allViews: [View] = []
    private(set) var views: [View] = []
    private(set) var containers: [Container] = []
    /// The extension container shown, or nil for views in built-in containers.
    var container: String? {
        didSet { if container != oldValue { updateShownViews(); if !isHidden { reloadAll() } } }
    }
    private var rows: [[Row]] = []
    /// Items under a parent: "viewId\u{0}handle" ("" for the top level).
    private var children: [String: [Item]] = [:]
    private var messages: [String: String] = [:]
    private var expanded: Set<String> = []
    private var collapsedViews: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "extensionViews.collapsed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "extensionViews.collapsed") }
    }
    private var commandInfo: [String: (title: String, icon: String?)] = [:]
    private var titleMenus: [MenuEntry] = []
    private var itemMenus: [MenuEntry] = []
    private var refreshing: Set<String> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = VS.sideBar
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.sectionHeaderTopPadding = 0
        table.register(ItemCell.self, forCellReuseIdentifier: "item")
        table.translatesAutoresizingMaskIntoConstraints = false
        addSubview(table)

        emptyLabel.text = "No installed extension adds views to the side bar."
        emptyLabel.font = VS.font(13)
        emptyLabel.textColor = VS.description
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: topAnchor),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(extensionsChanged), name: ExtensionManager.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(viewDidChange(_:)), name: Self.viewChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextDidChange), name: Self.contextChanged, object: nil)
        loadContributions()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whether views in built-in containers show (the Extension Views button).
    var hasViews: Bool { allViews.contains { !isOwnContainer($0.container) && evaluate($0.when, view: $0.id) } }

    /// The extension containers with a view showing, for the activity bar.
    var shownContainers: [Container] {
        containers.filter { c in evaluate(c.when, view: "") && allViews.contains { $0.container == c.id && evaluate($0.when, view: $0.id) } }
    }

    /// The title for the side bar: the container's, or EXTENSION VIEWS.
    var title: String { containers.first { $0.id == container }?.title ?? "Extension Views" }

    private func isOwnContainer(_ id: String) -> Bool { containers.contains { $0.id == id } }

    private func updateShownViews() {
        views = allViews.filter { view in
            (container.map { view.container == $0 } ?? !isOwnContainer(view.container)) && evaluate(view.when, view: view.id)
        }
        emptyLabel.isHidden = !views.isEmpty
    }

    @objc private func contextDidChange() {
        let before = views.map(\.id)
        updateShownViews()
        if views.map(\.id) != before && !isHidden { reloadAll() }
    }

    /// A container's only view when it's a webview: it opens straight away, without the side bar.
    func soleWebview(in containerId: String) -> View? {
        let shown = allViews.filter { $0.container == containerId && evaluate($0.when, view: $0.id) }
        return shown.count == 1 && shown[0].isWebview ? shown[0] : nil
    }

    func openWebview(_ view: View) {
        callEditor?("return await window.duocode.openWebviewView(viewId, title)", ["viewId": view.id, "title": view.name]) { _ in }
    }

    /// A container's icon for the activity bar (a template image), from its codicon or file.
    /// SVG files are drawn by the editor page, since UIKit can't read SVG.
    func icon(for container: Container, completion: @escaping (UIImage?) -> Void) {
        guard let icon = container.icon else { return completion(nil) }
        if icon.hasPrefix("$(") { return completion(Codicon.image(named: icon)) }
        let path = (container.extensionPath as NSString).appendingPathComponent(icon)
        if let cached = Self.iconCache[path] { return completion(cached) }
        if !icon.lowercased().hasSuffix(".svg") {
            let image = UIImage(contentsOfFile: path).map { Self.fit($0) }
            Self.iconCache[path] = image
            return completion(image)
        }
        guard let svg = try? String(contentsOfFile: path, encoding: .utf8), let callEditor else { return completion(nil) }
        let draw = """
            const image = new Image();
            image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = size;
            canvas.getContext('2d').drawImage(image, 0, 0, size, size);
            return canvas.toDataURL('image/png');
            """
        callEditor(draw, ["svg": svg, "size": 72]) { result in
            let image = (result as? String).flatMap { $0.components(separatedBy: ",").last }
                .flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0, scale: 3) }
                .map { Self.fit($0) }
            Self.iconCache[path] = image
            completion(image)
        }
    }

    private static var iconCache: [String: UIImage] = [:]

    /// 24 points, drawn as a mask in the activity bar's colours like VS Code's icons.
    private static func fit(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .withRenderingMode(.alwaysTemplate)
    }

    // MARK: - Contributions

    @objc private func extensionsChanged() {
        loadContributions()
        children.removeAll()
        messages.removeAll()
        if !isHidden { reloadAll() }
    }

    /// The views, commands and menus of the enabled extensions.
    private func loadContributions() {
        var found: [View] = []
        var ownContainers: [Container] = []
        commandInfo = [:]
        titleMenus = []
        itemMenus = []
        for payload in ExtensionManager.shared.editorPayload() {
            guard let manifest = payload["manifest"] as? [String: Any] else { continue }
            let name = manifest["displayName"] as? String ?? manifest["name"] as? String ?? ""
            let contributes = manifest["contributes"] as? [String: Any] ?? [:]
            let extensionPath = payload["path"] as? String ?? ""
            for (_, list) in contributes["viewsContainers"] as? [String: Any] ?? [:] {
                for entry in list as? [[String: Any]] ?? [] {
                    guard let id = entry["id"] as? String else { continue }
                    let icon = entry["icon"] as? String ?? ((entry["icon"] as? [String: Any])?["dark"] as? String)
                    ownContainers.append(Container(id: id, title: Self.text(entry["title"]) ?? name, icon: icon,
                                                   extensionPath: extensionPath, when: entry["when"] as? String))
                }
            }
            for (containerId, list) in contributes["views"] as? [String: Any] ?? [:] {
                for view in list as? [[String: Any]] ?? [] {
                    guard let id = view["id"] as? String else { continue }
                    let title = Self.text(view["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? name
                    found.append(View(id: id, name: title, extensionName: name, isWebview: view["type"] as? String == "webview",
                                      when: view["when"] as? String, container: containerId))
                }
            }
            for command in contributes["commands"] as? [[String: Any]] ?? [] {
                guard let id = command["command"] as? String else { continue }
                let icon = (command["icon"] as? String).flatMap { $0.hasPrefix("$(") ? $0 : nil }
                commandInfo[id] = (Self.text(command["title"]) ?? id, icon)
            }
            let menus = contributes["menus"] as? [String: Any] ?? [:]
            let entries = { (key: String) -> [MenuEntry] in
                (menus[key] as? [[String: Any]] ?? []).compactMap { entry in
                    guard let command = entry["command"] as? String else { return nil }
                    return MenuEntry(command: command, title: "", icon: nil, when: entry["when"] as? String, group: entry["group"] as? String ?? "")
                }
            }
            titleMenus += entries("view/title")
            itemMenus += entries("view/item/context")
        }
        allViews = found
        containers = ownContainers
        updateShownViews()
    }

    private static func text(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        return (value as? [String: Any])?["value"] as? String
    }

    // MARK: - When clauses

    /// Evaluates a `when` clause for a view (and an item): ==, !=, =~, !, &&, || over view,
    /// viewItem and the context keys extensions set. Unknown keys are false.
    private func evaluate(_ when: String?, view: String, item: String? = nil) -> Bool {
        guard let when, !when.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let value = { (key: String) -> Any? in
            switch key {
            case "view": return view
            case "viewItem": return item
            case "true": return true
            case "false": return false
            default: return Self.contextKeys[key]
            }
        }
        let truthy = { (v: Any?) -> Bool in
            if let b = v as? Bool { return b }
            if let s = v as? String { return !s.isEmpty }
            if let n = v as? NSNumber { return n.boolValue }
            return v != nil && !(v is NSNull)
        }
        let unquote = { (s: String) -> String in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.count >= 2 && (t.hasPrefix("'") && t.hasSuffix("'") || t.hasPrefix("\"") && t.hasSuffix("\"")) ? String(t.dropFirst().dropLast()) : t
        }
        let term = { (raw: String) -> Bool in
            var t = raw.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("(") && t.hasSuffix(")") { t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
            if let r = t.range(of: "=~") {
                let key = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var pattern = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                var options: NSRegularExpression.Options = []
                if pattern.hasPrefix("/"), let end = pattern.lastIndex(of: "/"), end != pattern.startIndex {
                    if pattern[pattern.index(after: end)...].contains("i") { options.insert(.caseInsensitive) }
                    pattern = String(pattern[pattern.index(after: pattern.startIndex)..<end])
                }
                guard let s = value(key) as? String, let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
                return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
            for op in ["!=", "=="] {
                if let r = t.range(of: op) {
                    let key = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let expected = unquote(String(t[r.upperBound...]))
                    let actual = value(key).map { "\($0)" }
                    let equal = actual == expected || (expected == "true" && truthy(value(key))) || (expected == "false" && !truthy(value(key)))
                    return op == "==" ? equal : !equal
                }
            }
            if t.hasPrefix("!") { return !truthy(value(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))) }
            return truthy(value(t))
        }
        return when.components(separatedBy: "||").contains { clause in
            clause.components(separatedBy: "&&").allSatisfy(term)
        }
    }

    // MARK: - Loading

    func didBecomeVisible() {
        loadContributions()
        reloadAll()
    }

    private func key(_ viewId: String, _ handle: String?) -> String { viewId + "\u{0}" + (handle ?? "") }

    private func reloadAll() {
        rebuildRows()
        for view in views where !view.isWebview && !collapsedViews.contains(view.id) { refresh(view.id) }
        onHeaderActionsChanged?()
    }

    @objc private func viewDidChange(_ note: Notification) {
        guard let viewId = note.userInfo?["viewId"] as? String, !isHidden, views.contains(where: { $0.id == viewId }) else { return }
        refresh(viewId)
    }

    /// Fetches a view's top level and every expanded item under it again.
    private func refresh(_ viewId: String) {
        guard !refreshing.contains(viewId) else { return }
        refreshing.insert(viewId)
        fetch(viewId, nil) { [weak self] in
            guard let self else { return }
            let open = self.expanded.filter { $0.hasPrefix(viewId + "\u{0}") }.map { String($0.dropFirst(viewId.count + 1)) }
            var remaining = open.count
            let finish = { self.refreshing.remove(viewId); self.rebuildRows() }
            if remaining == 0 { finish(); return }
            for handle in open {
                self.fetch(viewId, handle) {
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
        }
    }

    private func fetch(_ viewId: String, _ handle: String?, done: @escaping () -> Void) {
        let args: [String: Any] = ["viewId": viewId, "handle": (handle as Any?) ?? NSNull()]
        guard let callEditor else { done(); return }
        callEditor("return await window.duocode.viewChildren(viewId, handle)", args) { [weak self] result in
            guard let self else { return }
            if let json = result as? [String: Any] {
                self.children[self.key(viewId, handle)] = (json["items"] as? [[String: Any]] ?? []).map(Item.init)
                if handle == nil { self.messages[viewId] = json["message"] as? String }
            } else if handle == nil {
                self.children[self.key(viewId, nil)] = []
                self.messages[viewId] = "Its extension isn't running."
            }
            done()
        }
    }

    private func rebuildRows() {
        rows = views.map { view in
            guard !collapsedViews.contains(view.id) else { return [] }
            if view.isWebview { return [.openWebview] }
            var out: [Row] = []
            if let message = messages[view.id], !message.isEmpty { out.append(.message(message)) }
            func walk(_ handle: String?, depth: Int) {
                for item in children[key(view.id, handle)] ?? [] {
                    out.append(.item(item, depth: depth))
                    if item.collapsible != 0 && isExpanded(view.id, item) { walk(item.handle, depth: depth + 1) }
                }
            }
            walk(nil, depth: 0)
            if out.isEmpty && children[key(view.id, nil)] == nil { out.append(.message("Loading…")) }
            return out
        }
        table.reloadData()
    }

    /// Expanded: opened by the user, or the extension made it start expanded.
    private func isExpanded(_ viewId: String, _ item: Item) -> Bool {
        let k = key(viewId, item.handle)
        if expanded.contains(k) { return true }
        if item.collapsible == 2 && !collapsedItems.contains(k) {
            expanded.insert(k)
            if children[k] == nil { fetch(viewId, item.handle) { [weak self] in self?.rebuildRows() } }
            return true
        }
        return false
    }
    private var collapsedItems: Set<String> = []

    // MARK: - Header actions (view/title menus)

    /// The title bar's actions: each visible tree view's navigation commands, then a menu with the rest.
    func headerActions() -> [UIView] {
        let more = VSIconButton(.ellipsis, label: "More Actions")
        more.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            guard let self else { return done([]) }
            var sections: [UIMenuElement] = []
            for view in self.views {
                let actions = self.titleMenus.filter { self.evaluate($0.when, view: view.id) }.map { entry -> UIAction in
                    let info = self.commandInfo[entry.command]
                    return UIAction(title: info?.title ?? entry.command, image: info?.icon.flatMap { Codicon.image(named: $0) }) { _ in
                        self.run(viewId: view.id, handle: nil, command: entry.command)
                    }
                }
                let refresh = UIAction(title: "Refresh", image: Codicon.refresh.image()) { _ in self.refresh(view.id) }
                sections.append(UIMenu(title: view.name, options: .displayInline, children: actions + (view.isWebview ? [] : [refresh])))
            }
            done(sections)
        }])
        more.showsMenuAsPrimaryAction = true
        return [more]
    }

    private func run(viewId: String, handle: String?, command: String) {
        let args: [String: Any] = ["viewId": viewId, "handle": (handle as Any?) ?? NSNull(), "command": command]
        callEditor?("return await window.duocode.viewMenu(viewId, handle, command)", args) { _ in }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { views.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section < rows.count ? rows[section].count : 0
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 26 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 26 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let view = views[section]
        let header = UIView()
        header.backgroundColor = VS.sideBar
        let collapsed = collapsedViews.contains(view.id)
        let chevron = UIImageView(image: (collapsed ? Codicon.chevronRight : .chevronDown).image(16))
        chevron.tintColor = VS.foreground
        let title = UILabel()
        title.text = view.name.uppercased()
        title.font = VS.font(11, .bold)
        title.textColor = VS.foreground
        title.lineBreakMode = .byTruncatingTail
        let actions = UIStackView()
        actions.axis = .horizontal
        // Navigation actions show as buttons, as in VS Code's view title bar.
        if !collapsed {
            for entry in titleMenus where entry.group.hasPrefix("navigation") && evaluate(entry.when, view: view.id) {
                guard let icon = commandInfo[entry.command]?.icon, let image = Codicon.image(named: icon) else { continue }
                let button = VSIconButton(.ellipsis, label: commandInfo[entry.command]?.title ?? entry.command) { [weak self] in
                    self?.run(viewId: view.id, handle: nil, command: entry.command)
                }
                button.setImage(image, for: .normal)
                actions.addArrangedSubview(button)
            }
        }
        for v in [chevron, title, actions] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -4),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        header.accessibilityLabel = view.name
        header.accessibilityTraits = .button
        header.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(headerTapped(_:))))
        header.tag = section
        return header
    }

    @objc private func headerTapped(_ gesture: UITapGestureRecognizer) {
        guard let section = gesture.view?.tag, section < views.count else { return }
        let view = views[section]
        var collapsed = collapsedViews
        if collapsed.contains(view.id) {
            collapsed.remove(view.id)
            collapsedViews = collapsed
            if !view.isWebview && children[key(view.id, nil)] == nil { refresh(view.id) }
        } else {
            collapsed.insert(view.id)
            collapsedViews = collapsed
        }
        rebuildRows()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath) as! ItemCell
        switch rows[indexPath.section][indexPath.row] {
        case let .item(item, depth):
            let open = item.collapsible != 0 && expanded.contains(key(views[indexPath.section].id, item.handle))
            cell.configure(label: item.label, description: item.description, depth: depth,
                           chevron: item.collapsible == 0 ? nil : (open ? .chevronDown : .chevronRight),
                           icon: item.checked.map { $0 ? Codicon.check.image(16) : Codicon.circleOutline.image(16) }
                                ?? item.codicon.flatMap { Codicon.image(named: $0) })
            cell.accessibilityHint = item.tooltip.isEmpty ? nil : item.tooltip
        case let .message(text):
            cell.configure(label: text, description: "", depth: 0, chevron: nil, icon: nil, muted: true)
        case .openWebview:
            cell.configure(label: "Open \(views[indexPath.section].name)", description: "", depth: 0, chevron: nil,
                           icon: Codicon.linkExternal.image(16))
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let view = views[indexPath.section]
        switch rows[indexPath.section][indexPath.row] {
        case let .item(item, _):
            let args: [String: Any] = ["viewId": view.id, "handle": item.handle]
            if let checked = item.checked {
                callEditor?("return await window.duocode.viewCheck(viewId, handle, checked)", args.merging(["checked": !checked]) { a, _ in a }) { [weak self] _ in
                    self?.refresh(view.id)
                }
                return
            }
            if item.collapsible != 0 {
                let k = key(view.id, item.handle)
                let opening = !expanded.contains(k)
                if opening {
                    expanded.insert(k)
                    collapsedItems.remove(k)
                    if children[k] == nil { fetch(view.id, item.handle) { [weak self] in self?.rebuildRows() } }
                } else {
                    expanded.remove(k)
                    collapsedItems.insert(k)
                }
                rebuildRows()
                callEditor?("return await window.duocode.viewExpand(viewId, handle, expanded)", args.merging(["expanded": opening]) { a, _ in a }) { _ in }
            }
            if item.hasCommand || item.collapsible == 0 {
                callEditor?("return await window.duocode.viewInvoke(viewId, handle)", args) { _ in }
            }
        case .openWebview:
            openWebview(view)
        case .message:
            break
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case let .item(item, _) = rows[indexPath.section][indexPath.row] else { return nil }
        let view = views[indexPath.section]
        let entries = itemMenus.filter { evaluate($0.when, view: view.id, item: item.contextValue) }
        guard !entries.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            // Grouped as VS Code groups them ("inline" first, then "1_modification", …).
            let groups = Dictionary(grouping: entries) { $0.group.components(separatedBy: "@").first ?? "" }
            let menus = groups.keys.sorted().map { group in
                UIMenu(options: .displayInline, children: groups[group]!.map { entry in
                    let info = self.commandInfo[entry.command]
                    return UIAction(title: info?.title ?? entry.command, image: info?.icon.flatMap { Codicon.image(named: $0) }) { _ in
                        self.run(viewId: view.id, handle: item.handle, command: entry.command)
                    }
                })
            }
            return UIMenu(children: menus)
        }
    }
}

/// A tree row: indent, chevron, icon, label and a muted description.
private final class ItemCell: UITableViewCell {
    private let chevron = UIImageView()
    private let icon = UIImageView()
    private let label = UILabel()
    private var leading: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = VS.listActiveSelection
        selectedBackgroundView = selected
        chevron.tintColor = VS.foreground
        icon.tintColor = VS.icon
        icon.contentMode = .center
        label.lineBreakMode = .byTruncatingTail
        for v in [chevron, icon, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        leading = chevron.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            leading,
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(label text: String, description: String, depth: Int, chevron arrow: Codicon?, icon image: UIImage?, muted: Bool = false) {
        leading.constant = 8 + CGFloat(depth) * 12
        chevron.image = arrow?.image(16)
        icon.image = image
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: VS.font(13), .foregroundColor: muted ? VS.description : VS.foreground])
        if !description.isEmpty {
            attributed.append(NSAttributedString(string: "  " + description, attributes: [.font: VS.font(12), .foregroundColor: VS.description]))
        }
        label.attributedText = attributed
        accessibilityLabel = description.isEmpty ? text : "\(text), \(description)"
    }
}
