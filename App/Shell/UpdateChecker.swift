import UIKit

/// Sideloaded copies don't update themselves, so the app looks for a newer release on GitHub at
/// launch (at most once a day) and offers it; after an update it shows what's new, from the
/// release's notes (CHANGELOG.md's section for that version).
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let repository = "mobile-studio-app/Mobile-Studio"
    private let defaults = UserDefaults.standard
    private enum Key {
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
        static let lastRunVersion = "updates.lastRunVersion"
    }

    struct Release {
        let version: String
        let notes: String
        let page: URL
        /// The .ipa's download, when the release has one.
        let download: URL?
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "0.10.0" > "0.9.1": numbers compared part by part.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// At launch: What's New after an update, else (once a day) a newer release.
    func launched(presentingFrom presenter: UIViewController) {
        let current = Self.currentVersion
        let lastRun = defaults.string(forKey: Key.lastRunVersion)
        defaults.set(current, forKey: Key.lastRunVersion)
        if let lastRun, Self.isNewer(current, than: lastRun) {
            fetch(tag: "v" + current) { release in
                guard let release else { return }
                Self.present(WhatsNewViewController(release: release, isUpdate: true), from: presenter)
            }
            return
        }
        let last = defaults.double(forKey: Key.lastCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check { [weak self] release in
            guard let self, let release, release.version != self.defaults.string(forKey: Key.skipped) else { return }
            self.offer(release, from: presenter)
        }
    }

    /// Looks for a release newer than this one (nil when there's none, or it can't tell).
    func check(_ completion: @escaping (Release?) -> Void) {
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
        fetch(tag: nil) { release in
            completion(release.flatMap { Self.isNewer($0.version, than: Self.currentVersion) ? $0 : nil })
        }
    }

    /// The latest release, or the one tagged `tag`. Completes on the main queue.
    func fetch(tag: String?, completion: @escaping (Release?) -> Void) {
        let path = tag.map { "releases/tags/\($0)" } ?? "releases/latest"
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)") else { return completion(nil) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var release: Release?
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String,
               let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                let assets = json["assets"] as? [[String: Any]] ?? []
                let ipa = assets.first { ($0["name"] as? String)?.hasSuffix(".ipa") == true }
                release = Release(version: tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName,
                                  notes: json["body"] as? String ?? "", page: page,
                                  download: (ipa?["browser_download_url"] as? String).flatMap(URL.init(string:)))
            }
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    /// "Version x is available": What's New, Download, Later or Skip This Version.
    func offer(_ release: Release, from presenter: UIViewController) {
        let alert = UIAlertController(title: "Mobile Studio \(release.version) Is Available",
                                      message: "You have \(Self.currentVersion). Download the new .ipa and install it with your sideloading tool, as before; your projects stay.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "What's New", style: .default) { _ in
            Self.present(WhatsNewViewController(release: release, isUpdate: false), from: presenter)
        })
        alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in
            UIApplication.shared.open(release.download ?? release.page)
        })
        alert.addAction(UIAlertAction(title: "Skip This Version", style: .default) { [weak self] _ in
            self?.defaults.set(release.version, forKey: Key.skipped)
        })
        alert.addAction(UIAlertAction(title: "Later", style: .cancel))
        Self.present(alert, from: presenter)
    }

    /// Over whatever is showing (the Welcome screen, say).
    static func present(_ controller: UIViewController, from presenter: UIViewController) {
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(controller, animated: true)
    }
}

/// A release's notes: the version's changes, from CHANGELOG.md.
final class WhatsNewViewController: UIViewController {
    private let release: UpdateChecker.Release
    private let isUpdate: Bool

    init(release: UpdateChecker.Release, isUpdate: Bool) {
        self.release = release
        self.isUpdate = isUpdate
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = isUpdate ? "What's New in \(release.version)" : "Mobile Studio \(release.version)"
        title.font = UIFont.preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header

        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = .clear
        text.attributedText = Self.render(release.notes)
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = .zero

        let done = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = isUpdate ? "Continue" : "Close"
        done.configuration = config
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [title, text, done])
        if UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion) {
            let download = UIButton(type: .system)
            var c = UIButton.Configuration.tinted()
            c.title = "Download \(release.version)"
            download.configuration = c
            let url = release.download ?? release.page
            download.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .primaryActionTriggered)
            stack.insertArrangedSubview(download, at: 2)
        }
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    /// The notes' Markdown, simply: headings, bullets, and bold, italics, code and links in lines.
    /// The install line every release starts with is left out.
    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .body)
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Download `MobileStudio.ipa`") { continue }
            var font = body
            var prefix = ""
            if line.hasPrefix("### ") { font = UIFont.preferredFont(forTextStyle: .headline); line.removeFirst(4) }
            else if line.hasPrefix("## ") { font = UIFont.preferredFont(forTextStyle: .title3).withTraits(.traitBold); line.removeFirst(3) }
            else if line.hasPrefix("- ") { prefix = "•  "; line.removeFirst(2) }
            if line.isEmpty && (out.length == 0 || out.string.hasSuffix("\n\n")) { continue }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let inline = (try? NSMutableAttributedString(AttributedString(markdown: line, options: options))) ?? NSMutableAttributedString(string: line)
            let piece = NSMutableAttributedString(string: prefix)
            piece.append(inline)
            // Keep **bold** and *italics* from the Markdown, at this line's size.
            piece.addAttribute(.font, value: font, range: NSRange(location: 0, length: piece.length))
            piece.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: piece.length)) { value, range, _ in
                guard let raw = (value as? NSNumber)?.uintValue else { return }
                let presentation = InlinePresentationIntent(rawValue: raw)
                var traits: UIFontDescriptor.SymbolicTraits = []
                if presentation.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if presentation.contains(.emphasized) { traits.insert(.traitItalic) }
                if presentation.contains(.code) { traits.insert(.traitMonoSpace) }
                piece.addAttribute(.font, value: font.withTraits(traits), range: range)
            }
            let paragraph = NSMutableParagraphStyle()
            if !prefix.isEmpty { paragraph.headIndent = 18 }
            paragraph.paragraphSpacing = 4
            piece.addAttributes([.paragraphStyle: paragraph, .foregroundColor: UIColor.label], range: NSRange(location: 0, length: piece.length))
            piece.append(NSAttributedString(string: "\n"))
            out.append(piece)
        }
        return out
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
