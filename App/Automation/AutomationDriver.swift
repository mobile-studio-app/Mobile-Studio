import UIKit
import WebKit

/// Views that react to a tap through a gesture recognizer, which automation can't fire directly.
protocol AutomationTappable: AnyObject {
    func automationTap()
}

/// Lets automation open menus built with UIDeferredMenuElement, whose provider UIKit keeps private.
/// Build deferred menus with `AutomationMenus.deferred` instead of `UIDeferredMenuElement.uncached`.
enum AutomationMenus {
    typealias Provider = (@escaping ([UIMenuElement]) -> Void) -> Void

    private final class Box {
        let provider: Provider
        init(_ provider: @escaping Provider) { self.provider = provider }
    }

    private static let providers = NSMapTable<UIDeferredMenuElement, Box>.weakToStrongObjects()

    static func deferred(_ provider: @escaping Provider) -> UIDeferredMenuElement {
        let element = UIDeferredMenuElement.uncached(provider)
        providers.setObject(Box(provider), forKey: element)
        return element
    }

    static func provider(for element: UIDeferredMenuElement) -> Provider? {
        providers.object(forKey: element)?.provider
    }
}

/// The automation endpoints. Everything runs on the main thread. Elements are found by their
/// label: the accessibility label, a button's title, a label's text, a field's text or placeholder,
/// or a list row's title. Coordinates are points in the window, as in /screenshot and /tree.
enum AutomationDriver {
    typealias Reply = (Data) -> Void

    static func handle(_ request: HTTPRequest, reply: @escaping Reply) {
        let body = request.json
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            let window = keyWindow
            reply(HTTPResponse.json([
                "app": "DuoCode",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                "width": window?.bounds.width ?? 0, "height": window?.bounds.height ?? 0,
                "scale": window?.screen.scale ?? 1,
            ]))
        case ("GET", "/screenshot"):
            let scale = CGFloat(Double(request.query["scale"] ?? "") ?? 1)
            guard let png = screenshot(scale: scale) else { return reply(HTTPResponse.error("No window to capture.", status: 500)) }
            reply(HTTPResponse.make(png, type: "image/png"))
        case ("GET", "/tree"):
            reply(HTTPResponse.json(["elements": elements().map(\.json), "alert": alertJSON().map { $0 as Any } ?? NSNull()]))
        case ("POST", "/tap"):
            tap(body, reply: reply)
        case ("POST", "/type"):
            type(body, reply: reply)
        case ("GET", "/alert"):
            reply(HTTPResponse.json(alertJSON() ?? ["alert": NSNull()]))
        case ("POST", "/alert"):
            answerAlert(body, reply: reply)
        case ("POST", "/dismiss"):
            // Closes the front sheet (Settings, the Welcome page), as its Done or Close button would.
            var top = keyWindow?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            guard let sheet = top, sheet !== keyWindow?.rootViewController else { return reply(HTTPResponse.error("Nothing is presented.")) }
            sheet.dismiss(animated: true) { reply(HTTPResponse.json(["dismissed": String(describing: Swift.type(of: sheet))])) }
        case ("POST", "/menu"):
            menu(body, reply: reply)
        case ("POST", "/contextmenu"):
            contextMenu(body, reply: reply)
        case ("POST", "/swipe"):
            swipe(body, reply: reply)
        case ("POST", "/js"):
            javaScript(body, reply: reply)
        case ("GET", "/state"):
            reply(HTTPResponse.json(state()))
        case ("POST", "/file"):
            writeFile(body, reply: reply)
        case ("GET", "/file"):
            readFile(request.query["path"] ?? "", reply: reply)
        case ("POST", "/git"):
            git(body, reply: reply)
        default:
            reply(HTTPResponse.error("Unknown endpoint \(request.method) \(request.path).", status: 404))
        }
    }

    // MARK: - Windows and screenshots

    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    private static var keyWindow: UIWindow? {
        windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func screenshot(scale: CGFloat) -> Data? {
        guard let main = keyWindow else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(0.5, min(scale, 3))
        return UIGraphicsImageRenderer(bounds: main.bounds, format: format).pngData { _ in
            for window in windows {
                window.drawHierarchy(in: window.convert(window.bounds, to: main), afterScreenUpdates: true)
            }
        }
    }

    // MARK: - Elements

    struct Element {
        let view: UIView
        let kind: String
        let label: String
        let frame: CGRect

        var json: [String: Any] {
            var out: [String: Any] = [
                "kind": kind, "label": label,
                "x": Int(frame.midX), "y": Int(frame.midY), "w": Int(frame.width), "h": Int(frame.height),
            ]
            if let control = view as? UIControl {
                out["enabled"] = control.isEnabled
                if control.isSelected { out["selected"] = true }
            }
            if let toggle = view as? UISwitch { out["on"] = toggle.isOn }
            if let button = view as? UIButton, button.menu != nil { out["menu"] = true }
            if let cell = view as? UITableViewCell {
                if cell.accessoryType == .checkmark { out["checked"] = true }
                if let value = cell.accessibilityValue { out["value"] = value }
            }
            if view.isFirstResponder { out["focused"] = true }
            return out
        }
    }

    /// Strips Codicon glyphs (private-use characters) so labels read as plain text.
    private static func plain(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = String(text.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func label(of view: UIView) -> String? {
        if let explicit = plain(view.accessibilityLabel), !(view is UITableViewCell) { return explicit }
        switch view {
        case let button as UIButton:
            return plain(button.currentTitle) ?? plain(button.currentAttributedTitle?.string)
                ?? plain(button.configuration?.title) ?? plain(button.configuration?.attributedTitle.map { String($0.characters) })
        case let field as UITextField:
            return plain(field.text) ?? plain(field.placeholder) ?? plain(field.attributedPlaceholder?.string)
        case let textView as VSTextView:
            return plain(textView.text) ?? plain(textView.placeholder)
        case let textView as UITextView:
            return plain(textView.text)
        case let label as UILabel:
            return plain(label.text) ?? plain(label.attributedText?.string)
        case let cell as UITableViewCell:
            if let list = cell as? VSListCell { return plain(list.titleLabel.attributedText?.string) }
            if let content = cell.contentConfiguration as? UIListContentConfiguration {
                return plain(content.text) ?? plain(content.attributedText?.string)
            }
            return plain(cell.textLabel?.text)
        case is UISwitch, is UIStepper, is UISegmentedControl:
            // Controls in a settings row take the row's title.
            var parent = view.superview
            while let current = parent, !(current is UITableViewCell) { parent = current.superview }
            return parent.flatMap { label(of: $0) }
        case is WKWebView:
            return "Editor"
        default:
            return nil
        }
    }

    private static func kind(of view: UIView) -> String? {
        switch view {
        case is UISwitch: return "switch"
        case is UIStepper: return "stepper"
        case is UISegmentedControl: return "segmented"
        case is UITextField, is UITextView: return "text"
        case is UIButton: return "button"
        case is UIControl: return "control"
        case is UITableViewCell: return "row"
        case is UITableViewHeaderFooterView: return "header"
        case is WKWebView: return "web"
        case is UILabel: return "label"
        default: return view is AutomationTappable ? "tappable" : nil
        }
    }

    private static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha < 0.01 { return false }
            current = v.superview
        }
        let frame = view.convert(view.bounds, to: window)
        return frame.width > 0 && frame.height > 0 && frame.intersects(window.bounds)
    }

    /// Every labelled, visible element, front-most window last. Labels inside buttons, rows and
    /// fields are left out, since the control itself is listed.
    static func elements() -> [Element] {
        var out: [Element] = []
        guard let main = keyWindow else { return out }
        for window in windows {
            walk(window) { view, insideControl in
                guard let kind = kind(of: view), !(kind == "label" && insideControl),
                      isVisible(view, in: window), let label = label(of: view) else { return }
                out.append(Element(view: view, kind: kind, label: label, frame: view.convert(view.bounds, to: main)))
            }
        }
        return out
    }

    private static func walk(_ view: UIView, insideControl: Bool = false, _ visit: (UIView, Bool) -> Void) {
        visit(view, insideControl)
        if view is WKWebView { return }
        let inside = insideControl || view is UIControl || view is UITableViewCell || view is UITableViewHeaderFooterView
        for sub in view.subviews { walk(sub, insideControl: inside, visit) }
    }

    /// The `nth` element (from 0) whose label is `text`, preferring exact matches to partial ones.
    private static func find(_ text: String, nth: Int = 0, kinds: Set<String>? = nil) -> Element? {
        let all = elements().filter { kinds?.contains($0.kind) ?? true }
        let wanted = text.lowercased()
        let exact = all.filter { $0.label.lowercased() == wanted }
        let partial = all.filter { $0.label.lowercased().contains(wanted) }
        let matches = exact.isEmpty ? partial : exact
        return matches.indices.contains(nth) ? matches[nth] : nil
    }

    private static func notFound(_ text: String) -> Data {
        let labels = elements().map(\.label).prefix(80).joined(separator: " | ")
        return HTTPResponse.error("No element labelled '\(text)'. Visible: \(labels)", status: 404)
    }

    // MARK: - Tap

    private static func tap(_ body: [String: Any], reply: @escaping Reply) {
        if let text = body["label"] as? String {
            guard let element = find(text, nth: body["nth"] as? Int ?? 0) else { return reply(notFound(text)) }
            reply(perform(on: element.view, at: CGPoint(x: element.frame.midX, y: element.frame.midY)))
        } else if let x = body["x"] as? Double, let y = body["y"] as? Double {
            let point = CGPoint(x: x, y: y)
            guard let main = keyWindow else { return reply(HTTPResponse.error("No window.")) }
            for window in windows.reversed() {
                let local = window.convert(point, from: main)
                if let hit = window.hitTest(local, with: nil) { return reply(perform(on: hit, at: point)) }
            }
            reply(HTTPResponse.error("Nothing at \(Int(x)), \(Int(y))."))
        } else {
            reply(HTTPResponse.error("Send {\"label\": \"...\"} or {\"x\": ..., \"y\": ...}."))
        }
    }

    /// Does what a tap on `view` would: fires its control, selects its row, and so on.
    private static func perform(on view: UIView, at point: CGPoint) -> Data {
        var current: UIView? = view
        while let v = current {
            if let tappable = v as? AutomationTappable {
                tappable.automationTap()
                return HTTPResponse.json(["tapped": "tappable"])
            }
            if let web = v as? WKWebView {
                let local = web.convert(point, from: keyWindow)
                let script = """
                    const el = document.elementFromPoint(\(local.x), \(local.y));
                    if (!el) return null;
                    for (const type of ['mousedown', 'mouseup', 'click']) el.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX: \(local.x), clientY: \(local.y) }));
                    return el.outerHTML.slice(0, 120);
                    """
                web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { _ in }
                return HTTPResponse.json(["tapped": "web"])
            }
            if let toggle = v as? UISwitch {
                toggle.setOn(!toggle.isOn, animated: true)
                toggle.sendActions(for: .valueChanged)
                return HTTPResponse.json(["tapped": "switch", "on": toggle.isOn])
            }
            if let segmented = v as? UISegmentedControl, segmented.numberOfSegments > 0 {
                let local = segmented.convert(point, from: keyWindow)
                let index = min(segmented.numberOfSegments - 1, max(0, Int(local.x / segmented.bounds.width * CGFloat(segmented.numberOfSegments))))
                segmented.selectedSegmentIndex = index
                segmented.sendActions(for: .valueChanged)
                return HTTPResponse.json(["tapped": "segment", "index": index])
            }
            if let stepper = v as? UIStepper {
                let local = stepper.convert(point, from: keyWindow)
                stepper.value += local.x > stepper.bounds.midX ? stepper.stepValue : -stepper.stepValue
                stepper.sendActions(for: .valueChanged)
                return HTTPResponse.json(["tapped": "stepper", "value": stepper.value])
            }
            if let button = v as? UIButton, button.menu != nil, button.showsMenuAsPrimaryAction {
                let titles = button.menu?.children.map(\.title) ?? []
                return HTTPResponse.error("'\(label(of: button) ?? "This button")' opens a menu; use /menu with a path. Top level: \(titles)")
            }
            if let control = v as? UIControl, !(v is UITextField), !(v is UITextView) {
                guard control.isEnabled else { return HTTPResponse.error("'\(label(of: control) ?? "Control")' is disabled.") }
                control.sendActions(for: .touchUpInside)
                return HTTPResponse.json(["tapped": "control"])
            }
            if let field = v as? UITextField {
                _ = field.becomeFirstResponder()
                return HTTPResponse.json(["tapped": "field"])
            }
            if let textView = v as? UITextView {
                _ = textView.becomeFirstResponder()
                return HTTPResponse.json(["tapped": "text"])
            }
            if let cell = v as? UITableViewCell, let table = tableView(of: cell), let indexPath = table.indexPath(for: cell) {
                let target = table.delegate?.tableView?(table, willSelectRowAt: indexPath) ?? indexPath
                table.selectRow(at: target, animated: false, scrollPosition: .none)
                table.delegate?.tableView?(table, didSelectRowAt: target)
                return HTTPResponse.json(["tapped": "row", "section": target.section, "row": target.row])
            }
            if let cell = v as? UICollectionViewCell, let collection = collectionView(of: cell), let indexPath = collection.indexPath(for: cell) {
                collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
                collection.delegate?.collectionView?(collection, didSelectItemAt: indexPath)
                return HTTPResponse.json(["tapped": "item", "section": indexPath.section, "item": indexPath.item])
            }
            current = v.superview
        }
        return HTTPResponse.error("Found '\(label(of: view) ?? String(describing: Swift.type(of: view)))' but nothing there responds to taps.")
    }

    private static func tableView(of cell: UIView) -> UITableView? {
        var parent = cell.superview
        while let v = parent, !(v is UITableView) { parent = v.superview }
        return parent as? UITableView
    }

    private static func collectionView(of cell: UIView) -> UICollectionView? {
        var parent = cell.superview
        while let v = parent, !(v is UICollectionView) { parent = v.superview }
        return parent as? UICollectionView
    }

    // MARK: - Typing

    private static func type(_ body: [String: Any], reply: @escaping Reply) {
        let text = body["text"] as? String ?? ""
        var target: UIView?
        if let name = body["label"] as? String {
            target = find(name, kinds: ["text"])?.view
            if target == nil { return reply(notFound(name)) }
        } else {
            target = elements().first { $0.view.isFirstResponder }?.view
        }
        guard let input = target else { return reply(HTTPResponse.error("No text field is focused; pass a label.")) }
        _ = input.becomeFirstResponder()
        if let field = input as? UITextField {
            if body["replace"] as? Bool == true {
                field.text = ""
                field.sendActions(for: .editingChanged)
            }
            field.insertText(text)
            if body["submit"] as? Bool == true { _ = field.delegate?.textFieldShouldReturn?(field) }
        } else if let textView = input as? UITextView {
            if body["replace"] as? Bool == true { textView.text = "" }
            textView.insertText(text)
            if body["submit"] as? Bool == true, let message = textView as? VSTextView { message.onSubmit?() }
        }
        if body["dismissKeyboard"] as? Bool == true { input.resignFirstResponder() }
        reply(HTTPResponse.json(["typed": text, "into": label(of: input) ?? ""]))
    }

    // MARK: - Alerts

    private static var topAlert: UIAlertController? {
        var controller = keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller as? UIAlertController
    }

    private static func alertJSON() -> [String: Any]? {
        guard let alert = topAlert else { return nil }
        return [
            "title": alert.title ?? "", "message": alert.message ?? "",
            "actions": alert.actions.map { ["title": $0.title ?? "", "enabled": $0.isEnabled] },
            "fields": (alert.textFields ?? []).map { ["text": $0.text ?? "", "placeholder": $0.placeholder ?? ""] },
        ]
    }

    private typealias AlertHandler = @convention(block) (UIAlertAction) -> Void

    private static func answerAlert(_ body: [String: Any], reply: @escaping Reply) {
        guard let alert = topAlert else { return reply(HTTPResponse.error("No alert is showing.")) }
        if let fields = body["fields"] as? [String] {
            for (field, text) in zip(alert.textFields ?? [], fields) { field.text = text }
        }
        let wanted = (body["button"] as? String ?? "").lowercased()
        guard let action = alert.actions.first(where: { ($0.title ?? "").lowercased() == wanted })
                ?? alert.actions.first(where: { ($0.title ?? "").lowercased().contains(wanted) }) else {
            return reply(HTTPResponse.error("No button '\(wanted)'. Buttons: \(alert.actions.compactMap(\.title))"))
        }
        // UIKit keeps the handler private; tests commonly reach it like this.
        let handler = action.value(forKey: "handler").map { unsafeBitCast($0 as AnyObject, to: AlertHandler.self) }
        alert.dismiss(animated: false) {
            handler?(action)
            reply(HTTPResponse.json(["pressed": action.title ?? ""]))
        }
    }

    // MARK: - Menus

    private typealias ActionHandler = @convention(block) (UIAction) -> Void
    private typealias MenuProvider = @convention(block) (NSArray) -> UIMenu?

    /// Opens a button's menu and picks the item at `path` (titles, through submenus).
    private static func menu(_ body: [String: Any], reply: @escaping Reply) {
        let name = body["label"] as? String ?? ""
        guard let element = find(name, nth: body["nth"] as? Int ?? 0) else { return reply(notFound(name)) }
        var view: UIView? = element.view
        while let v = view, !((v as? UIButton)?.menu != nil) { view = v.superview }
        guard let button = view as? UIButton, let menu = button.menu else {
            return reply(HTTPResponse.error("'\(name)' has no menu."))
        }
        choose(in: menu.children, path: body["path"] as? [String] ?? [], reply: reply)
    }

    /// A list row's long-press menu.
    private static func contextMenu(_ body: [String: Any], reply: @escaping Reply) {
        let name = body["label"] as? String ?? ""
        guard let element = find(name, nth: body["nth"] as? Int ?? 0, kinds: ["row"]),
              let cell = element.view as? UITableViewCell, let table = tableView(of: cell),
              let indexPath = table.indexPath(for: cell) else { return reply(notFound(name)) }
        guard let configuration = table.delegate?.tableView?(table, contextMenuConfigurationForRowAt: indexPath, point: .zero),
              let block = configuration.value(forKey: "actionProvider") else {
            return reply(HTTPResponse.error("'\(name)' has no context menu."))
        }
        let provider = unsafeBitCast(block as AnyObject, to: MenuProvider.self)
        guard let menu = provider([] as NSArray) else { return reply(HTTPResponse.error("'\(name)' has an empty context menu.")) }
        choose(in: menu.children, path: body["path"] as? [String] ?? [], reply: reply)
    }

    /// Resolves deferred elements and inline sections, then follows `path`. An empty path lists the items.
    private static func choose(in elements: [UIMenuElement], path: [String], reply: @escaping Reply) {
        flatten(elements) { items in
            guard let first = path.first else {
                return reply(HTTPResponse.json(["items": items.map { describe($0) }]))
            }
            let wanted = first.lowercased()
            guard let item = items.first(where: { $0.title.lowercased() == wanted })
                    ?? items.first(where: { $0.title.lowercased().contains(wanted) }) else {
                return reply(HTTPResponse.error("No menu item '\(first)'. Items: \(items.map(\.title))"))
            }
            if let submenu = item as? UIMenu {
                return choose(in: submenu.children, path: Array(path.dropFirst()), reply: reply)
            }
            guard let action = item as? UIAction else { return reply(HTTPResponse.error("'\(first)' can't be chosen.")) }
            guard !action.attributes.contains(.disabled) else { return reply(HTTPResponse.error("'\(first)' is disabled.")) }
            guard let block = action.value(forKey: "handler") else { return reply(HTTPResponse.error("'\(first)' has no handler.")) }
            unsafeBitCast(block as AnyObject, to: ActionHandler.self)(action)
            reply(HTTPResponse.json(["chose": action.title]))
        }
    }

    private static func describe(_ item: UIMenuElement) -> [String: Any] {
        var out: [String: Any] = ["title": item.title, "submenu": item is UIMenu]
        if let action = item as? UIAction {
            out["disabled"] = action.attributes.contains(.disabled)
            if action.state == .on { out["checked"] = true }
        }
        return out
    }

    private static func flatten(_ elements: [UIMenuElement], completion: @escaping ([UIMenuElement]) -> Void) {
        var result: [UIMenuElement] = []
        func step(_ index: Int) {
            guard index < elements.count else { return completion(result) }
            let element = elements[index]
            if let deferred = element as? UIDeferredMenuElement {
                guard let provider = AutomationMenus.provider(for: deferred) else { return step(index + 1) }
                provider { children in
                    flatten(children) { items in
                        result += items
                        step(index + 1)
                    }
                }
            } else if let menu = element as? UIMenu, menu.options.contains(.displayInline) {
                flatten(menu.children) { items in
                    result += items
                    step(index + 1)
                }
            } else {
                result.append(element)
                step(index + 1)
            }
        }
        step(0)
    }

    // MARK: - Swipe actions

    private static func swipe(_ body: [String: Any], reply: @escaping Reply) {
        let name = body["label"] as? String ?? ""
        guard let element = find(name, nth: body["nth"] as? Int ?? 0, kinds: ["row"]),
              let cell = element.view as? UITableViewCell, let table = tableView(of: cell),
              let indexPath = table.indexPath(for: cell) else { return reply(notFound(name)) }
        let actions = (table.delegate?.tableView?(table, trailingSwipeActionsConfigurationForRowAt: indexPath)?.actions ?? [])
            + (table.delegate?.tableView?(table, leadingSwipeActionsConfigurationForRowAt: indexPath)?.actions ?? [])
        let wanted = (body["action"] as? String ?? "").lowercased()
        guard let action = actions.first(where: { ($0.title ?? "").lowercased() == wanted }) else {
            return reply(HTTPResponse.error("No swipe action '\(wanted)'. Actions: \(actions.compactMap(\.title))"))
        }
        action.handler(action, cell) { _ in }
        reply(HTTPResponse.json(["swiped": action.title ?? ""]))
    }

    // MARK: - Editor, state, files and git

    private static var editorWebView: WKWebView? {
        var found: WKWebView?
        for window in windows {
            walk(window) { view, _ in
                if found == nil, let web = view as? WKWebView { found = web }
            }
        }
        return found
    }

    /// Runs `script` in the editor page as an async function body; `return` sends a value back.
    private static func javaScript(_ body: [String: Any], reply: @escaping Reply) {
        guard let web = editorWebView else { return reply(HTTPResponse.error("The editor isn't showing.")) }
        web.callAsyncJavaScript(body["script"] as? String ?? "", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                let json: Any = JSONSerialization.isValidJSONObject([value]) ? value : "\(value)"
                reply(HTTPResponse.json(["result": json]))
            case .failure(let error):
                reply(HTTPResponse.error("JavaScript failed: \(error.localizedDescription)"))
            }
        }
    }

    private static func state() -> [String: Any] {
        let project = ProjectStore.shared.currentProject
        let git = GitManager.shared
        let status = git.status(in: project)
        let files = { (list: [GitChangedFile]) in list.map { "\($0.status.rawValue) \($0.path)" } }
        return [
            "project": project.lastPathComponent,
            "isRepo": git.isGitRepo(at: project),
            "branch": status.currentBranch,
            "branches": git.branches(in: project),
            "staged": files(status.stagedFiles),
            "changes": files(status.changedFiles),
            "conflicts": files(status.mergeConflicts),
            "merging": status.mergingBranch.map { $0 as Any } ?? NSNull(),
            "ahead": status.aheadCount,
            "hasUpstream": status.hasUpstream,
            "stashes": status.stashCount,
            "history": git.history(in: project, limit: 10).map { "\($0.id) \($0.message)" },
            "aiReady": AICompletionService.shared.isReady,
            "aiMergeReady": AICompletionService.shared.isMergeReady,
            "keyboard": elements().contains { $0.view.isFirstResponder },
        ]
    }

    private static func writeFile(_ body: [String: Any], reply: @escaping Reply) {
        guard let path = body["path"] as? String else { return reply(HTTPResponse.error("Send a path.")) }
        do {
            if body["delete"] as? Bool == true {
                try FileManager.default.removeItem(at: ProjectStore.shared.resolve(path))
                NotificationCenter.default.post(name: ProjectStore.filesDidChange, object: nil)
            } else {
                try ProjectStore.shared.write(path, contents: body["contents"] as? String ?? "")
            }
            NotificationCenter.default.post(name: AutomationServer.filesChangedOnDisk, object: nil)
            reply(HTTPResponse.json(["ok": true]))
        } catch {
            reply(HTTPResponse.error(error.localizedDescription))
        }
    }

    private static func readFile(_ path: String, reply: @escaping Reply) {
        do {
            reply(HTTPResponse.json(["path": path, "contents": try ProjectStore.shared.read(path)]))
        } catch {
            reply(HTTPResponse.error(error.localizedDescription, status: 404))
        }
    }

    /// Scenario setup without tapping through the UI: {"op": "commit", "message": "..."} and so on.
    private static func git(_ body: [String: Any], reply: @escaping Reply) {
        let project = ProjectStore.shared.currentProject
        let git = GitManager.shared
        let name = body["name"] as? String ?? ""
        do {
            var result: Any = true
            switch body["op"] as? String ?? "" {
            case "init": try git.initRepo(at: project)
            case "commit": result = try git.commit(message: body["message"] as? String ?? "Automation", all: true, in: project).id
            case "branch": try git.createBranch(name, checkout: body["checkout"] as? Bool ?? true, in: project)
            case "checkout": try git.checkout(name, force: body["force"] as? Bool ?? false, in: project)
            case "merge":
                switch try git.merge(name, in: project) {
                case .upToDate: result = "upToDate"
                case .fastForward: result = "fastForward"
                case .merged: result = "merged"
                case .conflicts(let paths): result = ["conflicts": paths]
                }
            case "abortMerge": try git.abortMerge(in: project)
            case "deleteBranch": try git.deleteBranch(name, force: body["force"] as? Bool ?? false, in: project)
            default: return reply(HTTPResponse.error("Unknown op. Use init, commit, branch, checkout, merge, abortMerge or deleteBranch."))
            }
            // Views refresh as they do after an edit, and the editor re-reads the open file.
            NotificationCenter.default.post(name: ProjectStore.filesDidChange, object: nil)
            NotificationCenter.default.post(name: AutomationServer.filesChangedOnDisk, object: nil)
            reply(HTTPResponse.json(["result": result, "state": state()]))
        } catch {
            reply(HTTPResponse.error(error.localizedDescription))
        }
    }
}
