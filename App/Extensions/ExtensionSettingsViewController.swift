import UIKit

/// An extension's settings ("contributes.configuration"), as VS Code's Settings editor shows
/// them: switches for booleans, menus for enums, fields for numbers and strings, and JSON for
/// anything else. Values are stored by ExtensionHostBridge and reach running extensions at once.
final class ExtensionSettingsViewController: UITableViewController {
    struct Setting {
        let key: String
        let title: String
        let category: String
        let description: String
        let type: String
        let defaultValue: Any?
        let options: [String]
        let optionDescriptions: [String]
        let order: Int
    }

    private let extensionName: String
    private let settings: [Setting]

    /// Settings an extension contributes, in its order.
    static func settings(in manifest: [String: Any]) -> [Setting] {
        let contributes = manifest["contributes"] as? [String: Any] ?? [:]
        let sections: [[String: Any]]
        if let list = contributes["configuration"] as? [[String: Any]] { sections = list }
        else if let one = contributes["configuration"] as? [String: Any] { sections = [one] }
        else { sections = [] }
        var out: [Setting] = []
        for section in sections {
            let category = section["title"] as? String ?? ""
            for (key, value) in section["properties"] as? [String: Any] ?? [:] {
                guard let prop = value as? [String: Any] else { continue }
                if prop["deprecationMessage"] != nil || prop["markdownDeprecationMessage"] != nil { continue }
                let types = (prop["type"] as? [String]) ?? [(prop["type"] as? String) ?? "string"]
                let type = types.first { $0 != "null" } ?? "string"
                let options = (prop["enum"] as? [Any])?.map { "\($0)" } ?? []
                out.append(Setting(
                    key: key,
                    title: title(for: key),
                    category: category,
                    description: plain(prop["markdownDescription"] as? String ?? prop["description"] as? String ?? ""),
                    type: options.isEmpty ? type : "enum",
                    defaultValue: prop["default"],
                    options: options,
                    optionDescriptions: (prop["enumDescriptions"] as? [String] ?? prop["markdownEnumDescriptions"] as? [String] ?? []).map(plain),
                    order: prop["order"] as? Int ?? Int.max))
            }
        }
        return out.sorted { ($0.order, $0.key) < ($1.order, $1.key) }
    }

    /// "prettier.printWidth" -> "Print Width", as VS Code titles settings.
    private static func title(for key: String) -> String {
        let last = key.split(separator: ".").last.map(String.init) ?? key
        var words = ""
        for (i, c) in last.enumerated() {
            if i > 0, c.isUppercase { words.append(" ") }
            words.append(i == 0 ? Character(c.uppercased()) : c)
        }
        return words
    }

    private static func plain(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"#([\w.]+)#"#, with: "$1", options: .regularExpression)
    }

    init(extensionName: String, manifest: [String: Any]) {
        self.extensionName = extensionName
        settings = Self.settings(in: manifest)
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(extensionName) Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "setting")
        tableView.keyboardDismissMode = .interactive
    }

    private func value(of setting: Setting) -> Any? {
        ExtensionHostBridge.configuration[setting.key] ?? setting.defaultValue
    }

    private func set(_ setting: Setting, _ value: Any?) {
        var all = ExtensionHostBridge.configuration
        all[setting.key] = value
        ExtensionHostBridge.configuration = all
    }

    private func isModified(_ setting: Setting) -> Bool {
        ExtensionHostBridge.configuration[setting.key] != nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int { max(settings.count, 1) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { settings.isEmpty ? 0 : 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !settings.isEmpty else { return nil }
        let s = settings[section]
        let modified = isModified(s) ? " • Modified" : ""
        return (s.category.isEmpty ? s.title : "\(s.category): \(s.title)") + modified
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if settings.isEmpty { return "This extension has no settings." }
        let s = settings[section]
        return s.description.isEmpty ? s.key : "\(s.description)\n\(s.key)"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting", for: indexPath)
        let setting = settings[indexPath.section]
        let current = value(of: setting)
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        switch setting.type {
        case "boolean":
            content.text = setting.title
            let toggle = UISwitch()
            toggle.isOn = current as? Bool ?? false
            toggle.addAction(UIAction { [weak self] _ in
                self?.set(setting, toggle.isOn)
                self?.refreshHeader(indexPath.section)
            }, for: .valueChanged)
            cell.accessoryView = toggle
        case "enum":
            content.text = setting.title
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = current.map { "\($0)" } ?? "—"
            config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
            config.imagePlacement = .trailing
            config.imagePadding = 4
            button.configuration = config
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: setting.options.enumerated().map { i, option in
                UIAction(title: option, subtitle: i < setting.optionDescriptions.count ? setting.optionDescriptions[i] : nil,
                         state: "\(current ?? "")" == option ? .on : .off) { [weak self] _ in
                    let raw: Any = (setting.defaultValue is Int || setting.defaultValue is Double) ? (Double(option).map { $0 as Any } ?? option) : option
                    self?.set(setting, raw)
                    self?.tableView.reloadSections([indexPath.section], with: .none)
                }
            })
            button.sizeToFit()
            cell.accessoryView = button
        case "number", "integer", "string":
            content.text = nil
            let field = UITextField()
            field.text = current.map { "\($0)" } ?? ""
            field.placeholder = setting.defaultValue.map { "\($0)" } ?? setting.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = setting.type == "string" ? .default : .numbersAndPunctuation
            field.returnKeyType = .done
            field.frame = CGRect(x: 0, y: 0, width: max(tableView.bounds.width - 60, 120), height: 36)
            field.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let text = field.text ?? ""
                if setting.type == "string" { self.set(setting, text) }
                else if let number = Double(text) { self.set(setting, setting.type == "integer" ? Int(number) as Any : number) }
                else if text.isEmpty { self.set(setting, nil) }
                self.refreshHeader(indexPath.section)
            }, for: .editingDidEnd)
            field.addAction(UIAction { _ in field.resignFirstResponder() }, for: .editingDidEndOnExit)
            cell.accessoryView = field
        default:
            content.text = "Edit in JSON"
            content.secondaryText = json(current)
            content.secondaryTextProperties.numberOfLines = 2
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        return cell
    }

    private func refreshHeader(_ section: Int) {
        UIView.performWithoutAnimation { tableView.reloadSections([section], with: .none) }
    }

    private func json(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let setting = settings[indexPath.section]
        guard !["boolean", "enum", "number", "integer", "string"].contains(setting.type) else { return }
        let alert = UIAlertController(title: setting.title, message: setting.key, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.json(self.value(of: setting))
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let text = alert.textFields?.first?.text ?? ""
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
                let error = UIAlertController(title: "That isn't valid JSON", message: nil, preferredStyle: .alert)
                error.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(error, animated: true)
                return
            }
            self?.set(setting, value)
            self?.tableView.reloadSections([indexPath.section], with: .none)
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let setting = settings[indexPath.section]
        guard isModified(setting) else { return nil }
        let reset = UIContextualAction(style: .normal, title: "Reset") { [weak self] _, _, done in
            self?.set(setting, nil)
            self?.tableView.reloadSections([indexPath.section], with: .automatic)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [reset])
    }
}
