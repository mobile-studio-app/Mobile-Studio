import UIKit

/// An extension's page, as VS Code shows it: icon, name, publisher, install or manage, whether
/// it can work in DuoCode (and what won't), and its README.
final class ExtensionDetailViewController: UIViewController {
    var onInstall: (() -> Void)?

    private let namespace: String
    private let name: String
    private var id: String { "\(namespace).\(name)".lowercased() }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let publisherLabel = UILabel()
    private let summaryLabel = UILabel()
    private let actionButton = VSButton(split: false)
    private let compatibilityLabel = PaddedLabel()
    private let readme = UITextView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var details: ExtensionManager.Details?

    init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = VS.editorBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        iconView.contentMode = .scaleAspectFit
        iconView.image = Codicon.extensions.image(48)
        iconView.tintColor = VS.icon
        titleLabel.font = VS.font(22, .semibold)
        titleLabel.textColor = VS.foreground
        titleLabel.numberOfLines = 0
        publisherLabel.font = VS.font(13)
        publisherLabel.textColor = VS.link
        summaryLabel.font = VS.font(13)
        summaryLabel.textColor = VS.foreground
        summaryLabel.numberOfLines = 0
        compatibilityLabel.font = VS.font(12)
        compatibilityLabel.textColor = VS.foreground
        compatibilityLabel.numberOfLines = 0
        compatibilityLabel.layer.borderWidth = 1
        compatibilityLabel.isHidden = true
        compatibilityLabel.isUserInteractionEnabled = true
        compatibilityLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showCompatibilityNotes)))
        actionButton.isHidden = true
        actionButton.mainButton.addAction(UIAction { [weak self] _ in self?.primaryAction() }, for: .touchUpInside)
        readme.isEditable = false
        readme.isScrollEnabled = false
        readme.backgroundColor = .clear
        readme.textColor = VS.foreground
        readme.font = VS.font(14)
        readme.dataDetectorTypes = [.link]
        spinner.color = VS.icon
        spinner.startAnimating()

        let header = UIStackView(arrangedSubviews: [iconView, UIStackView(arrangedSubviews: [titleLabel, publisherLabel])])
        (header.arrangedSubviews[1] as? UIStackView)?.axis = .vertical
        (header.arrangedSubviews[1] as? UIStackView)?.spacing = 2
        header.spacing = 14
        header.alignment = .center
        let divider = UIView()
        divider.backgroundColor = VS.sectionBorder
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        [header, summaryLabel, actionButton, compatibilityLabel, spinner, divider, readme].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.setCustomSpacing(18, after: compatibilityLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            actionButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        titleLabel.text = name
        publisherLabel.text = namespace
        NotificationCenter.default.addObserver(self, selector: #selector(updateAction), name: ExtensionManager.didChange, object: nil)
        load()
    }

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let details = try await ExtensionManager.shared.details(namespace: self.namespace, name: self.name)
                var readmeText: String?
                if let url = details.readme, let response = try? await URLSession.shared.data(from: url) {
                    readmeText = String(data: response.0, encoding: .utf8)
                }
                var icon: UIImage?
                if let iconURL = ((details.info["files"] as? [String: Any])?["icon"] as? String).flatMap(URL.init(string:)),
                   let response = try? await URLSession.shared.data(from: iconURL) {
                    icon = UIImage(data: response.0)
                }
                await MainActor.run { self.show(details, readme: readmeText, icon: icon) }
            } catch {
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.summaryLabel.text = "Couldn't load this extension: \(error.localizedDescription)"
                }
            }
        }
    }

    private func show(_ details: ExtensionManager.Details, readme text: String?, icon: UIImage?) {
        self.details = details
        spinner.stopAnimating()
        spinner.isHidden = true
        titleLabel.text = details.info["displayName"] as? String ?? name
        let downloads = details.info["downloadCount"] as? Int ?? 0
        let version = details.info["version"] as? String ?? ""
        let verified = details.info["verified"] as? Bool == true ? "  ✓ verified" : ""
        publisherLabel.text = "\(details.info["namespaceDisplayName"] as? String ?? namespace)\(verified)  ·  v\(version)  ·  \(downloads) installs"
        summaryLabel.text = details.info["description"] as? String
        if let icon { iconView.image = icon }

        let compatibility = details.compatibility
        let (title, color): (String, UIColor) = {
            switch compatibility.level {
            case .full: return ("This extension works in Mobile Studio", VS.gitUntracked)
            case .partial: return ("This extension partly works in Mobile Studio", VS.gitModified)
            case .unsupported: return ("This extension does not work in Mobile Studio", VS.gitDeleted)
            }
        }()
        // One line; the reasons are behind the (i).
        let box = NSMutableAttributedString(string: title, attributes: [.font: VS.font(12), .foregroundColor: VS.foreground])
        if !compatibility.notes.isEmpty {
            let info = UIImage(systemName: "info.circle")!.withTintColor(color, renderingMode: .alwaysOriginal)
            box.append(NSAttributedString(string: " "))
            box.append(NSAttributedString(attachment: NSTextAttachment(image: info)))
        }
        compatibilityLabel.attributedText = box
        compatibilityNotes = compatibility.notes
        compatibilityLabel.layer.borderColor = color.cgColor
        compatibilityLabel.backgroundColor = color.withAlphaComponent(0.12)
        compatibilityLabel.isHidden = false
        readme.attributedText = Self.render(markdown: text ?? "No README.")
        updateAction()
    }

    private var compatibilityNotes: [String] = []

    @objc private func showCompatibilityNotes() {
        guard !compatibilityNotes.isEmpty else { return }
        let alert = UIAlertController(title: nil, message: compatibilityNotes.joined(separator: "\n\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func updateAction() {
        guard let details else { return }
        actionButton.isHidden = false
        if let record = ExtensionManager.shared.installed.first(where: { $0.id == id }) {
            actionButton.setTitle(record.enabled ? "Disable" : "Enable", icon: nil)
            actionButton.isEnabled = true
            let uninstall = UIBarButtonItem(title: "Uninstall", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                ExtensionManager.shared.uninstall(self.id)
            })
            uninstall.tintColor = .systemRed
            navigationItem.leftBarButtonItem = uninstall
        } else {
            navigationItem.leftBarButtonItem = nil
            actionButton.isWarning = details.compatibility.level == .partial
            actionButton.setTitle(details.compatibility.canInstall ? "Install" : "Not Supported", icon: details.compatibility.canInstall ? .cloudDownload : nil)
            actionButton.isEnabled = details.compatibility.canInstall
        }
    }

    private func primaryAction() {
        if let record = ExtensionManager.shared.installed.first(where: { $0.id == id }) {
            ExtensionManager.shared.setEnabled(id, !record.enabled)
        } else {
            actionButton.setTitle("Installing…", icon: nil)
            actionButton.isEnabled = false
            onInstall?()
        }
    }

    /// README markdown as styled text: headings, code blocks, lists and inline styles.
    static func render(markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: VS.font(14), .foregroundColor: VS.foreground]
        var inCode = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: VS.foreground,
                    .backgroundColor: UIColor(white: 1, alpha: 0.06),
                ]))
                continue
            }
            // Images and HTML don't render here; skip lines that are only that.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<") || (trimmed.hasPrefix("![") && trimmed.hasSuffix(")")) || trimmed.hasPrefix("[![") { continue }
            var level = 0
            while level < trimmed.count && trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == "#" { level += 1 }
            if level > 0 && level <= 6 {
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: VS.font(level == 1 ? 20 : level == 2 ? 17 : 15, .semibold), .foregroundColor: VS.foreground,
                ]))
                continue
            }
            var text = line
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { text = "• " + trimmed.dropFirst(2) }
            if let inline = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                let styled = NSMutableAttributedString(attributedString: NSAttributedString(inline))
                styled.addAttributes(body, range: NSRange(location: 0, length: styled.length))
                styled.enumerateAttribute(.link, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
                    if value != nil { styled.addAttribute(.foregroundColor, value: VS.link, range: range) }
                }
                out.append(styled)
                out.append(NSAttributedString(string: "\n", attributes: body))
            } else {
                out.append(NSAttributedString(string: text + "\n", attributes: body))
            }
        }
        return out
    }
}
