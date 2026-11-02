import UIKit
import UniformTypeIdentifiers

/// One page of Settings (SettingsRootViewController lists them): its sections of rows.
final class SettingsViewController: UITableViewController {
    enum Page: CaseIterable {
        case general, ai, running, sourceControl, advanced, about

        var title: String {
            switch self {
            case .general: return "General"
            case .ai: return "AI"
            case .running: return "Running"
            case .sourceControl: return "Source Control"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }

        /// An SF Symbol for the list of pages.
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "sparkles"
            case .running: return "play.circle"
            case .sourceControl: return "arrow.triangle.branch"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }

        fileprivate var sections: [Section] {
            switch self {
            case .general: return [.editor, .suggestions]
            case .ai: return [.ai, .aiMerge, .chat, .cloud]
            case .running: return [.run, .programs]
            case .sourceControl: return [.account]
            case .advanced: return [.models, .files, .developer]
            case .about: return [.about]
            }
        }

        /// The settings on this page, for Settings' search.
        var searchTerms: [String] {
            switch self {
            case .general: return ["Color Theme", "File Icon Theme", "Icons", "Font Size", "Indent Width", "Tab Size", "Word Wrap", "Auto Save", "Format on Save", "Code Suggestions", "Completion"]
            case .ai: return ["AI Suggestions", "Apple Intelligence", "Fast AI", "Regular AI", "Download over Mobile Data", "AI Merge Conflicts", "Chat", "Models", "Cloud Models", "API Key", "Anthropic", "Claude", "OpenAI", "OpenRouter", "Ollama", "LM Studio"]
            case .running: return ["LuaJIT JIT Compiler", "Running Games", "Programs from Extensions", "Signing Certificate"]
            case .sourceControl: return ["GitHub", "Sign in", "Smart Commit"]
            case .advanced: return ["AI Models", "Download Models", "Ollama", "Llama", "Gemma", "Qwen", "Phi", "DeepSeek", "settings.json", "keybindings.json", "Keyboard Shortcuts", "Test Automation", "Pairing Code", "Developer"]
            case .about: return ["Version", "Runtimes", "Device Memory", "Licences"]
            }
        }
    }

    fileprivate enum Section: Int, CaseIterable {
        case editor, suggestions, ai, aiMerge, chat, cloud, run, programs, account, models, files, developer, about
    }

    /// Posted to open a settings file (userInfo "path") in the editor.
    static let openFileRequest = Notification.Name("DuoCodeOpenSettingsFile")

    private enum EditorRow: Int, CaseIterable {
        case theme, iconTheme, fontSize, tabSize, wordWrap, autoSave, formatOnSave
    }

    /// Off, Apple Intelligence, Fast and Regular AI, and code models downloaded in Advanced → AI Models.
    private var aiChoices: [AIModelChoice] { [.off, .appleIntelligence] + AIModelCatalog.completionModels.map(\.choice) }
    /// The merge conflict model's rows; nil is "Same as AI Suggestions".
    private var mergeChoices: [AIModelChoice?] { [nil] + aiChoices.map { Optional($0) } }
    /// Apple Intelligence, the suggested chat models and the other downloaded ones.
    private var chatChoices: [AIModelChoice] { [.appleIntelligence] + AIModelCatalog.chatModels.map(\.choice) }
    private let settings = AppSettings.shared
    private let page: Page
    private let sections: [Section]

    init(page: Page) {
        self.page = page
        sections = page.sections
        super.init(style: .insetGrouped)
    }

    /// Where a section is on this page (nil: it's on another page).
    private func index(_ section: Section) -> Int? { sections.firstIndex(of: section) }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = page.title
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        NotificationCenter.default.addObserver(self, selector: #selector(modelsChanged),
                                               name: ModelDownloadManager.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(automationChanged),
                                               name: AutomationServer.didChange, object: nil)
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    /// Progress updates name their model, so only its rows are redrawn. A finished download can add
    /// rows (the model joins the lists it fits), and then the lists are rebuilt.
    @objc private func modelsChanged(_ note: Notification) {
        guard let model = note.userInfo?["model"] as? AIModelChoice, aiRowCountsMatch() else { return reloadAIRows() }
        var rows: [IndexPath] = []
        for (section, choices) in aiLists() {
            if let row = choices.firstIndex(of: model) { rows.append(IndexPath(row: row, section: section)) }
        }
        tableView.reconfigureRows(at: rows)
    }

    /// The model lists on this page: each one's section and its choices, by row.
    private func aiLists() -> [(Int, [AIModelChoice?])] {
        var lists: [(Int, [AIModelChoice?])] = []
        if let section = index(.ai) { lists.append((section, aiChoices.map { Optional($0) })) }
        if let section = index(.aiMerge) { lists.append((section, mergeChoices)) }
        if let section = index(.chat) { lists.append((section, chatChoices.map { Optional($0) })) }
        if let section = index(.cloud) { lists.append((section, CloudProvider.allCases.map { Optional($0.choice) })) }
        if let section = index(.models) { lists.append((section, AIModelCatalog.extras.map { Optional($0.choice) })) }
        return lists
    }

    private func aiRowCountsMatch() -> Bool {
        aiLists().allSatisfy { section, choices in
            tableView.numberOfRows(inSection: section) == choices.count + (sections[section] == .ai ? 1 : 0)
        }
    }

    @objc private func automationChanged() {
        if let section = index(.developer) { tableView.reloadSections(IndexSet(integer: section), with: .none) }
    }

    /// The model lists, whose checkmarks, download states and rows depend on each other.
    private func reloadAIRows() {
        let lists = IndexSet(aiLists().map { $0.0 })
        if !lists.isEmpty { tableView.reloadSections(lists, with: .none) }
    }

    private var cellularRow: Int { aiChoices.count }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .editor: return EditorRow.allCases.count
        case .suggestions: return 1
        case .ai: return aiChoices.count + 1
        case .aiMerge: return mergeChoices.count
        case .chat: return chatChoices.count
        case .cloud: return CloudProvider.allCases.count
        case .models: return AIModelCatalog.extras.count
        case .run: return 1
        case .programs: return 1
        case .account: return 2
        case .files: return 3
        case .developer: return settings.testAutomation ? 3 : 1
        case .about: return 3
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .editor: return "Editor"
        case .suggestions: return "Code Completion"
        case .ai: return "AI Suggestions"
        case .aiMerge: return "AI Merge Conflicts"
        case .chat: return "Chat"
        case .cloud: return "Cloud Models"
        case .models: return "AI Models"
        case .run: return "Running Games"
        case .programs: return "Programs from Extensions"
        case .account: return "Source Control"
        case .files: return "Settings Files"
        case .developer: return "Developer"
        case .about: return "About"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .editor:
            return nil
        case .suggestions:
            return "Completions, function signatures and enum values from Mobile Studio's built-in LÖVE and Lua knowledge. Works on every phone, offline."
        case .ai:
            return """
                AI suggestions appear as grey text at the end of a line. Tap them or press Tab to accept, keep typing to ignore. \
                Everything runs on this phone; your code isn't sent anywhere. Models download from Hugging Face, \
                over Wi-Fi only unless Download over Mobile Data is on, and never while Low Data Mode is on. \
                Fast AI is Qwen2.5-Coder 3B (Qwen Research License), Regular AI is Qwen2.5-Coder 7B (Apache 2.0). \
                A local model is unloaded while a game runs and reloads afterwards.
                """
        case .aiMerge:
            return """
                The model "Resolve for me" uses in the merge conflict editor. A bigger model merges better. \
                If it's a different downloaded model from AI Suggestions, the suggestions model is unloaded \
                while it works, so they don't both fill the phone's memory.
                """
        case .chat:
            return """
                The model the Chat panel (⌃⌘I) answers with. Apple Intelligence is built into iOS; the suggested models \
                download when you pick them, and more are in Settings → Advanced → AI Models. Chats stay on this \
                device, unless you pick a cloud model (below).
                """
        case .cloud:
            return """
                Optional, and off until you add a key. A cloud model runs on its provider's servers with your own \
                API key, which is kept in this device's Keychain. Unlike the models above, everything you send in \
                Chat, and every file the agent reads, goes to that provider, under its terms and pricing. \
                A Custom Server can be Ollama or LM Studio on your own network (its address ends in /v1).
                """
        case .models:
            return """
                More models that run on this device, from Hugging Face in GGUF format (the files Ollama and LM Studio run). \
                Each one downloaded joins the lists it fits: code models in AI Suggestions and AI Merge Conflicts, chat \
                models in Chat. Swipe to delete one. Bigger models answer better but need more memory and time.
                """
        case .run:
            if #available(iOS 26.0, *) {
                return "On iOS 26 and later, LuaJIT's compiler needs support Mobile Studio doesn't have yet, so games use LuaJIT's interpreter, even with a JIT enabler."
            }
            return RuntimeHost.jitAvailable
                ? "The JIT compiler is available because Mobile Studio was started with a JIT enabler."
                : "LuaJIT's compiler only works when Mobile Studio is started with a JIT enabler (such as StikDebug). Without one, games use the interpreter."
        case .programs:
            return """
                Some extensions come with macOS programs, such as language servers and linters. Mobile Studio can run them \
                when it signs them with the certificate it was installed with: in Plume Impactor, choose Settings > \
                Export P12, save the file to this iPhone, then import it here. Experimental: a program that crashes \
                closes Mobile Studio.
                """
        case .files:
            return "VS Code's settings files. settings.json has these settings and extensions' under VS Code's names; a project's .vscode/settings.json overrides them for that project."
        case .account:
            return "Smart Commit commits all your changes when nothing is staged, instead of asking first."
        case .developer:
            let state = settings.testAutomation && !AutomationServer.shared.isRunning ? " It's starting, or Wi-Fi is off." : ""
            return """
                Lets a computer on the same Wi-Fi control Mobile Studio for automated testing: screenshots, taps, typing \
                and reading state (see tools/duo.py). Only requests with the pairing code are accepted; tap the code \
                to change it. Turn this off when you're done.\(state)
                """
        case .about:
            return "Icons are VS Code's Codicons by Microsoft, licensed under CC BY 4.0."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        // Kept so a redraw with the same accessory reuses it instead of swapping in a new view.
        let previousAccessory = cell.accessoryView
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.isUserInteractionEnabled = true
        var content = UIListContentConfiguration.valueCell()

        switch sections[indexPath.section] {
        case .editor:
            configureEditorRow(EditorRow(rawValue: indexPath.row)!, cell: cell, content: &content)
        case .suggestions:
            content.text = "Code Suggestions"
            cell.accessoryView = makeSwitch(settings.codeSuggestions) { [weak self] in self?.settings.codeSuggestions = $0 }
            cell.selectionStyle = .none
        case .ai where indexPath.row == cellularRow:
            content.text = "Download over Mobile Data"
            cell.accessoryView = makeSwitch(settings.downloadOverCellular) { [weak self] in self?.settings.downloadOverCellular = $0 }
            cell.selectionStyle = .none
        case .ai:
            content = UIListContentConfiguration.subtitleCell()
            let choice = aiChoices[indexPath.row]
            configureAIRow(choice, selected: settings.aiModel == choice, forMerge: false, cell: cell, content: &content,
                           previousAccessory: previousAccessory)
        case .chat:
            content = UIListContentConfiguration.subtitleCell()
            let choice = chatChoices[indexPath.row]
            configureAIRow(choice, selected: settings.chatModel == choice, forMerge: false, cell: cell, content: &content,
                           previousAccessory: previousAccessory)
            if let model = AIModelCatalog.model(for: choice), let why = AIModelCatalog.suggestion(for: model), !model.isDownloaded,
               model.isSupported, let detail = content.secondaryText {
                content.secondaryText = "Suggested · \(why) · " + detail.replacingOccurrences(of: "\(model.detail) · ", with: "")
            }
        case .cloud:
            content = UIListContentConfiguration.subtitleCell()
            let provider = CloudProvider.allCases[indexPath.row]
            content.text = provider.name
            content.secondaryText = provider.isConfigured ? "\(provider.model) · set up · sends your code to \(provider.name)" : provider.detail
            content.secondaryTextProperties.color = .secondaryLabel
            if settings.chatModel == provider.choice {
                cell.accessoryType = .checkmark
            } else if !provider.isConfigured {
                cell.accessoryView = accessoryLabel("Set Up", color: .tintColor, reusing: previousAccessory)
            }
        case .models:
            content = UIListContentConfiguration.subtitleCell()
            let model = AIModelCatalog.extras[indexPath.row]
            configureAIRow(model.choice, selected: false, forMerge: false, cell: cell, content: &content,
                           previousAccessory: previousAccessory)
            content.text = "\(model.name) · \(model.uses)"
        case .aiMerge:
            content = UIListContentConfiguration.subtitleCell()
            if let choice = mergeChoices[indexPath.row] {
                configureAIRow(choice, selected: settings.aiMergeModel == choice, forMerge: true, cell: cell, content: &content,
                               previousAccessory: previousAccessory)
            } else {
                content.text = "Same as AI Suggestions"
                content.secondaryText = Self.name(of: settings.aiModel)
                content.secondaryTextProperties.color = .secondaryLabel
                cell.accessoryType = settings.aiMergeModel == nil ? .checkmark : .none
            }
        case .run:
            content.text = "LuaJIT JIT Compiler"
            cell.accessoryView = makeSwitch(settings.useJIT) { [weak self] in self?.settings.useJIT = $0 }
            cell.selectionStyle = .none
        case .programs:
            content.text = "Signing Certificate"
            if let team = SigningCertificate.team {
                content.secondaryText = "Team \(team)"
            } else {
                content.secondaryText = "Import…"
                content.secondaryTextProperties.color = .tintColor
            }
        case .files:
            content.text = ["Open User Settings (JSON)", "Open Keyboard Shortcuts (JSON)", "Open Workspace Settings (JSON)"][indexPath.row]
            content.secondaryText = ["settings.json", "keybindings.json", ".vscode/settings.json"][indexPath.row]
            content.textProperties.color = .tintColor
        case .account where indexPath.row == 1:
            content.text = "Smart Commit"
            cell.accessoryView = makeSwitch(settings.smartCommit) { [weak self] in self?.settings.smartCommit = $0 }
            cell.selectionStyle = .none
        case .account:
            if GitAccountManager.shared.isSignedIn, let user = GitAccountManager.shared.currentUser {
                content.text = "@\(user.login)"
                content.secondaryText = "Sign Out"
                content.secondaryTextProperties.color = .systemRed
            } else {
                content.text = "Sign in to GitHub"
                content.textProperties.color = .tintColor
            }
        case .developer:
            cell.selectionStyle = .none
            switch indexPath.row {
            case 0:
                content.text = "Test Automation over Wi-Fi"
                cell.accessoryView = makeSwitch(settings.testAutomation) { [weak self] on in
                    self?.settings.testAutomation = on
                    if let section = self?.index(.developer) { self?.tableView.reloadSections(IndexSet(integer: section), with: .automatic) }
                }
            case 1:
                content.text = "Address"
                content.secondaryText = AutomationServer.shared.address ?? "No Wi-Fi"
            default:
                content.text = "Pairing Code"
                content.secondaryText = AutomationServer.shared.token
                cell.selectionStyle = .default
            }
        case .about:
            cell.selectionStyle = .none
            switch indexPath.row {
            case 0:
                let info = Bundle.main.infoDictionary
                content.text = "Mobile Studio"
                content.secondaryText = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
            case 1:
                content = UIListContentConfiguration.subtitleCell()
                content.secondaryTextProperties.color = .secondaryLabel
                content.text = "Runtimes"
                content.secondaryText = RuntimeManager.shared.selectableRuntimes.filter(\.isAvailable)
                    .map(\.manifest.displayName).joined(separator: ", ")
            default:
                content.text = "Device Memory"
                content.secondaryText = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    private func configureEditorRow(_ row: EditorRow, cell: UITableViewCell, content: inout UIListContentConfiguration) {
        cell.selectionStyle = .none
        switch row {
        case .theme:
            content.text = "Color Theme"
            cell.accessoryView = makeThemeButton()
        case .iconTheme:
            content.text = "File Icon Theme"
            cell.accessoryView = makeIconThemeButton()
        case .fontSize:
            content.text = "Font Size"
            content.secondaryText = "\(settings.fontSize) pt"
            let stepper = UIStepper()
            stepper.minimumValue = 9
            stepper.maximumValue = 24
            stepper.value = Double(settings.fontSize)
            stepper.addAction(UIAction { [weak self] action in
                guard let self, let stepper = action.sender as? UIStepper else { return }
                self.settings.fontSize = Int(stepper.value)
                if let section = self.index(.editor) { self.tableView.reconfigureRows(at: [IndexPath(row: EditorRow.fontSize.rawValue, section: section)]) }
            }, for: .valueChanged)
            cell.accessoryView = stepper
        case .tabSize:
            content.text = "Indent Width"
            let sizes = [2, 4, 8]
            let control = UISegmentedControl(items: sizes.map { "\($0)" })
            control.selectedSegmentIndex = sizes.firstIndex(of: settings.tabSize) ?? 1
            control.addAction(UIAction { [weak self] action in
                guard let control = action.sender as? UISegmentedControl else { return }
                self?.settings.tabSize = sizes[control.selectedSegmentIndex]
            }, for: .valueChanged)
            cell.accessoryView = control
        case .wordWrap:
            content.text = "Word Wrap"
            cell.accessoryView = makeSwitch(settings.wordWrap) { [weak self] in self?.settings.wordWrap = $0 }
        case .autoSave:
            content.text = "Auto Save"
            cell.accessoryView = makeSwitch(settings.autoSave) { [weak self] in self?.settings.autoSave = $0 }
        case .formatOnSave:
            content.text = "Format on Save"
            cell.accessoryView = makeSwitch(settings.formatOnSave) { [weak self] in self?.settings.formatOnSave = $0 }
        }
    }

    private static func name(of choice: AIModelChoice) -> String {
        switch choice {
        case .off: return "Off"
        case .appleIntelligence: return "Apple Intelligence"
        default: return AIModelCatalog.model(for: choice)?.name ?? choice.rawValue
        }
    }

    private func configureAIRow(_ choice: AIModelChoice, selected: Bool, forMerge: Bool, cell: UITableViewCell,
                                content: inout UIListContentConfiguration, previousAccessory: UIView?) {
        cell.accessoryType = selected ? .checkmark : .none
        content.secondaryTextProperties.color = .secondaryLabel
        var enabled = true

        switch choice {
        case .off:
            content.text = "Off"
            content.secondaryText = forMerge ? "Resolve conflicts with the editor's buttons" : "Code Suggestions only"
        case .appleIntelligence:
            content.text = "Apple Intelligence"
            if let reason = AppleIntelligenceEngine.unavailableReason {
                content.secondaryText = reason
                enabled = selected   // still let you switch away from it
            } else {
                content.secondaryText = "Built into iOS · no download"
            }
        default:
            guard let model = AIModelCatalog.model(for: choice) else {
                content.text = choice.rawValue
                content.secondaryText = "No longer available"
                break
            }
            content.text = model.name
            if !model.isSupported {
                content.secondaryText = "\(model.detail) · \(model.requirementText)"
                enabled = selected
            } else {
                switch ModelDownloadManager.shared.state(for: model) {
                case .notDownloaded:
                    content.secondaryText = "\(model.detail) · \(model.sizeText) download"
                    cell.accessoryView = accessoryLabel("Get", color: .tintColor, reusing: previousAccessory)
                case .downloading(let progress):
                    let percent = Int(progress * 100)
                    let status = ModelDownloadManager.shared.waitingReason.map { "\($0) (\(percent)%)" } ?? "Downloading \(percent)%"
                    content.secondaryText = "\(model.detail) · \(status) · tap to cancel"
                    if !selected {
                        let spinner = previousAccessory as? UIActivityIndicatorView ?? UIActivityIndicatorView(style: .medium)
                        spinner.startAnimating()
                        cell.accessoryView = spinner
                    }
                case .verifying:
                    content.secondaryText = "\(model.detail) · Checking download…"
                case .downloaded:
                    content.secondaryText = "\(model.detail) · \(model.sizeText) · swipe to delete"
                case .failed(let message):
                    content.secondaryText = "\(model.detail) · \(message)"
                    content.secondaryTextProperties.color = .systemRed
                    cell.accessoryView = accessoryLabel("Retry", color: .tintColor, reusing: previousAccessory)
                }
            }
        }
        content.textProperties.color = enabled ? .label : .tertiaryLabel
        cell.isUserInteractionEnabled = enabled
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .ai where indexPath.row < aiChoices.count:
            selectAI(aiChoices[indexPath.row]) { [weak self] choice in self?.settings.aiModel = choice }
        case .chat:
            selectAI(chatChoices[indexPath.row]) { [weak self] choice in self?.settings.chatModel = choice }
        case .cloud:
            setUpCloud(CloudProvider.allCases[indexPath.row], at: indexPath)
        case .models:
            selectAI(AIModelCatalog.extras[indexPath.row].choice) { _ in }
        case .aiMerge:
            if let choice = mergeChoices[indexPath.row] {
                selectAI(choice) { [weak self] picked in self?.settings.aiMergeModel = picked }
            } else {
                settings.aiMergeModel = nil
                reloadAIRows()
            }
        case .programs:
            certificateTapped()
        case .files:
            let commands = ["workbench.action.openSettingsJson", "workbench.action.openGlobalKeybindingsFile", "workbench.action.openWorkspaceSettingsFile"]
            NotificationCenter.default.post(name: Self.openFileRequest, object: nil, userInfo: ["command": commands[indexPath.row]])
            dismiss(animated: true)
        case .account where indexPath.row == 0:
            accountTapped()
        case .developer where indexPath.row == 2:
            AutomationServer.shared.resetToken()
        default:
            break
        }
    }

    // MARK: - Signing certificate

    private func certificateTapped() {
        guard let team = SigningCertificate.team else { return pickCertificate() }
        let sheet = UIAlertController(title: "Signing Certificate", message: "Team \(team)", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Import Another…", style: .default) { [weak self] _ in self?.pickCertificate() })
        sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            SigningCertificate.remove()
            self?.reloadCertificateRow()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let section = index(.programs), let cell = tableView.cellForRow(at: IndexPath(row: 0, section: section)) {
            sheet.popoverPresentationController?.sourceView = cell
            sheet.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func pickCertificate() {
        let types = [UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx"), UTType.data].compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// Plume Impactor's exports have no password, so that's tried first.
    fileprivate func importCertificate(_ data: Data, password: String? = nil) {
        do {
            try SigningCertificate.importCertificate(data, password: password ?? "")
            reloadCertificateRow()
        } catch {
            let wrongPassword = error.localizedDescription.contains("password")
            if wrongPassword || password == nil && error.localizedDescription.contains("couldn't be read") {
                let alert = UIAlertController(title: "Certificate Password",
                                              message: password == nil ? "Enter the password the certificate was exported with." : "That password didn't work.",
                                              preferredStyle: .alert)
                alert.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "Password" }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Import", style: .default) { [weak self, weak alert] _ in
                    self?.importCertificate(data, password: alert?.textFields?.first?.text ?? "")
                })
                present(alert, animated: true)
                return
            }
            let alert = UIAlertController(title: "Couldn't Import", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func reloadCertificateRow() {
        if let section = index(.programs) { tableView.reloadSections(IndexSet(integer: section), with: .none) }
    }

    /// Sets up a cloud model: its key, model and (for a custom server) address.
    private func setUpCloud(_ provider: CloudProvider, at indexPath: IndexPath) {
        let alert = UIAlertController(title: provider.name, message: """
            \(provider.detail). Chat sends your messages and the files the agent reads to \(provider.name). \
            The key is kept in this device's Keychain.
            """, preferredStyle: .alert)
        if provider == .custom {
            alert.addTextField { field in
                field.placeholder = "Address, like http://192.168.1.20:11434/v1"
                field.text = provider.baseURL
                field.keyboardType = .URL
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
        }
        alert.addTextField { field in
            field.placeholder = provider.modelPlaceholder
            field.text = provider.model
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = provider.needsKey ? "API key" : "API key (if the server needs one)"
            field.text = provider.apiKey
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        let save = { [weak self, weak alert] (use: Bool) in
            guard let self, let fields = alert?.textFields else { return }
            let values = fields.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if provider == .custom { provider.baseURL = values[0] }
            provider.model = values[values.count - 2]
            provider.apiKey = values[values.count - 1]
            if use && provider.isConfigured { self.settings.chatModel = provider.choice }
            self.reloadAIRows()
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if provider.isConfigured {
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                guard let self else { return }
                if self.settings.chatModel == provider.choice { self.settings.chatModel = .appleIntelligence }
                if self.settings.subagentModel == provider.choice { self.settings.subagentModel = nil }
                provider.forget()
                self.reloadAIRows()
            })
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in save(false) })
        alert.addAction(UIAlertAction(title: "Save and Use for Chat", style: .default) { _ in save(true) })
        present(alert, animated: true)
    }

    /// Picks `choice` with `apply`, downloading it first if needed.
    private func selectAI(_ choice: AIModelChoice, apply: @escaping (AIModelChoice) -> Void) {
        let setAIModel = { [weak self] (choice: AIModelChoice) in
            apply(choice)
            self?.reloadAIRows()
        }
        guard let model = AIModelCatalog.model(for: choice) else {
            if choice == .appleIntelligence, AppleIntelligenceEngine.unavailableReason != nil { return }
            setAIModel(choice)
            return
        }
        guard model.isSupported else { return }
        switch ModelDownloadManager.shared.state(for: model) {
        case .downloaded:
            setAIModel(choice)
        case .downloading:
            let alert = UIAlertController(title: "Cancel Download?", message: "\(model.name) hasn't finished downloading.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep Downloading", style: .cancel))
            alert.addAction(UIAlertAction(title: "Cancel Download", style: .destructive) { _ in
                ModelDownloadManager.shared.cancel(model)
            })
            present(alert, animated: true)
        case .verifying:
            break
        case .notDownloaded, .failed:
            var message = "\(model.detail) is \(model.sizeText) (\(model.license)). It downloads in the background from Hugging Face."
            if let waiting = ModelDownloadManager.shared.waitingReason {
                message += waiting == "Waiting for Wi-Fi"
                    ? "\n\nYou're on mobile data, so it'll start when you join Wi-Fi. To use mobile data, turn on Download over Mobile Data."
                    : "\n\nIt won't start yet: \(waiting.lowercased())."
            }
            let alert = UIAlertController(title: "Download \(model.name)?", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in
                ModelDownloadManager.shared.download(model)
                setAIModel(choice)
            })
            present(alert, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let choice: AIModelChoice?
        switch sections[indexPath.section] {
        case .ai where indexPath.row < aiChoices.count: choice = aiChoices[indexPath.row]
        case .aiMerge: choice = mergeChoices[indexPath.row]
        case .chat: choice = chatChoices[indexPath.row]
        case .models: choice = AIModelCatalog.extras[indexPath.row].choice
        default: choice = nil
        }
        guard let choice, let model = AIModelCatalog.model(for: choice), model.isDownloaded else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            if self.settings.aiModel == model.choice { self.settings.aiModel = .off }
            if self.settings.aiMergeModel == model.choice { self.settings.aiMergeModel = nil }
            if self.settings.chatModel == model.choice { self.settings.chatModel = .appleIntelligence }
            AICompletionService.shared.unload()
            AIChatService.shared.unload()
            ModelDownloadManager.shared.delete(model)
            self.reloadAIRows()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func accountTapped() {
        let accountRow = IndexPath(row: 0, section: index(.account) ?? 0)
        if GitAccountManager.shared.isSignedIn {
            let alert = UIAlertController(title: "Sign Out of GitHub?", message: "You'll need to sign in again to clone private repositories or sync.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
                GitAccountManager.shared.signOut()
                self?.tableView.reconfigureRows(at: [accountRow])
            })
            present(alert, animated: true)
        } else {
            GitHubSignInViewController.present(from: self) { [weak self] _ in
                self?.tableView.reconfigureRows(at: [accountRow])
            }
        }
    }

    // MARK: - Controls

    private func makeSwitch(_ isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { action in
            if let toggle = action.sender as? UISwitch { onChange(toggle.isOn) }
        }, for: .valueChanged)
        return toggle
    }

    private func makeThemeButton() -> UIButton {
        let current = settings.editorTheme
        let button = UIButton(configuration: .plain())
        button.configuration?.title = EditorThemeCatalog.name(of: current)
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
        // Built when opened, so newly installed extensions' themes are there; grouped by extension.
        button.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            guard let self else { return done([]) }
            let current = self.settings.editorTheme
            let action = { (theme: EditorThemeCatalog.Theme) in
                UIAction(title: theme.name, state: theme.id == current ? .on : .off) { [weak self] _ in
                    self?.settings.editorTheme = theme.id
                    if let section = self?.index(.editor) { self?.tableView.reconfigureRows(at: [IndexPath(row: EditorRow.theme.rawValue, section: section)]) }
                }
            }
            var groups: [UIMenuElement] = [UIMenu(title: "Mobile Studio", options: .displayInline, children: EditorThemeCatalog.builtIn.map(action))]
            for ext in ExtensionManager.shared.installed where ext.enabled {
                let themes = EditorThemeCatalog.themes(of: ext.id)
                if !themes.isEmpty { groups.append(UIMenu(title: ext.displayName, options: .displayInline, children: themes.map(action))) }
            }
            done(groups)
        }])
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        return button
    }

    /// None (the built-in icons) and the icon themes installed extensions offer.
    private func makeIconThemeButton() -> UIButton {
        let button = UIButton(configuration: .plain())
        button.configuration?.title = FileIconTheme.shared.label(of: settings.fileIconTheme)
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
        button.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            guard let self else { return done([]) }
            let current = self.settings.fileIconTheme
            let choices = [("", "None")] + FileIconTheme.shared.options.map { ($0.id, $0.label) }
            done(choices.map { id, label in
                UIAction(title: label, state: id == current ? .on : .off) { [weak self] _ in
                    self?.settings.fileIconTheme = id
                    if let section = self?.index(.editor) { self?.tableView.reconfigureRows(at: [IndexPath(row: EditorRow.iconTheme.rawValue, section: section)]) }
                }
            })
        }])
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        return button
    }

    private func accessoryLabel(_ text: String, color: UIColor, reusing previous: UIView? = nil) -> UILabel {
        if let label = previous as? UILabel, label.text == text { return label }
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = color
        label.sizeToFit()
        return label
    }
}

extension SettingsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
        importCertificate(data)
    }
}
