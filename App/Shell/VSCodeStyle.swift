import CoreText
import UIKit

/// VS Code's workbench colours and metrics, shared by the activity bar and side bar. The main ones
/// follow the editor's colour theme (ThemeColors); the defaults are Dark+'s.
enum VS {
    static func hex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    static var editorBackground: UIColor { ThemeColors.color("editorBackground", hex(0x1E1E1E)) }
    static var sideBar: UIColor { ThemeColors.color("sideBar", hex(0x252526)) }
    static var activityBar: UIColor { ThemeColors.color("activityBar", hex(0x333333)) }
    static var activityBarInactive: UIColor { ThemeColors.color("activityBarInactive", hex(0xFFFFFF, 0.4)) }
    static var activityBarBadge: UIColor { ThemeColors.color("activityBarBadge", hex(0x007ACC)) }
    static var foreground: UIColor { ThemeColors.color("foreground", hex(0xCCCCCC)) }
    static var titleForeground: UIColor { ThemeColors.color("titleForeground", hex(0xBBBBBB)) }
    static var description: UIColor { ThemeColors.color("description", hex(0xCCCCCC, 0.7)) }
    static var icon: UIColor { ThemeColors.color("icon", hex(0xC5C5C5)) }
    static var sectionBorder: UIColor { ThemeColors.color("sectionBorder", hex(0xCCCCCC, 0.2)) }
    static var border: UIColor { ThemeColors.color("border", hex(0x454545)) }

    static var inputBackground: UIColor { ThemeColors.color("inputBackground", hex(0x3C3C3C)) }
    static var placeholder: UIColor { ThemeColors.color("placeholder", hex(0xA6A6A6)) }
    static var focusBorder: UIColor { ThemeColors.color("focusBorder", hex(0x007FD4)) }
    static let optionActiveBackground = hex(0x2489DB, 0.51)
    static let optionActiveBorder = hex(0x007ACC)
    static let toolbarHover = hex(0x5A5D5E, 0.5)

    static var buttonBackground: UIColor { ThemeColors.color("buttonBackground", hex(0x0E639C)) }
    /// A button for something that only partly works (VS Code's warning yellow).
    static let warningButtonBackground = hex(0xCCA700)
    static let warningButtonHover = hex(0xDDB811)
    static let warningButtonForeground = hex(0x1E1E1E)
    static var buttonHover: UIColor { ThemeColors.color("buttonHover", hex(0x1177BB)) }
    static let buttonSeparator = hex(0xFFFFFF, 0.4)
    static var badgeBackground: UIColor { ThemeColors.color("badgeBackground", hex(0x4D4D4D)) }

    static var listHover: UIColor { ThemeColors.color("listHover", hex(0x2A2D2E)) }
    static var listSelection: UIColor { ThemeColors.color("listSelection", hex(0x37373D)) }
    static var listActiveSelection: UIColor { ThemeColors.color("listActiveSelection", hex(0x04395E)) }

    static let errorForeground = hex(0xF48771)
    static let errorBackground = hex(0x5A1D1D)
    static let errorBorder = hex(0xBE1100)
    static var link: UIColor { ThemeColors.color("link", hex(0x3794FF)) }

    static let findMatch = hex(0xEA5C00, 0.33)
    static let removedText = hex(0xFF0000, 0.3)
    static let insertedText = hex(0x9CCC2C, 0.3)

    static let gitModified = hex(0xE2C08D)
    static let gitUntracked = hex(0x73C991)
    static let gitAdded = hex(0x81B88B)
    static let gitDeleted = hex(0xC74E39)
    static let gitConflict = hex(0xE4676B)
    static let graphLane = hex(0x59A4F9)
    static let graphRemote = hex(0xB180D7)
    static let graphOther = hex(0xFFB000)

    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 35
    static let paneHeaderHeight: CGFloat = 24
    static let indent: CGFloat = 8

    static func font(_ size: CGFloat = 13, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func color(for status: GitFileStatus) -> UIColor {
        switch status {
        case .modified: return gitModified
        case .untracked: return gitUntracked
        case .added: return gitAdded
        case .deleted: return gitDeleted
        case .conflicted: return gitConflict
        }
    }

    /// Seti-style file icon and colour (VS Code's default icon theme draws no folder icons).
    static func fileIcon(_ name: String) -> (Codicon, UIColor) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "lua": return (.fileCode, hex(0x519ABA))
        case "json": return (.json, hex(0xCBCB41))
        case "md": return (.markdown, hex(0x519ABA))
        case "glsl", "frag", "vert", "shader": return (.symbolColor, hex(0xA074C4))
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "tga", "dds", "ktx", "exr", "hdr": return (.fileMedia, hex(0xA074C4))
        case "wav", "ogg", "oga", "mp3", "flac", "m4a", "aac", "it", "xm", "mod", "s3m": return (.unmute, hex(0xE37933))
        case "ttf", "otf", "fnt": return (.textSize, hex(0xE37933))
        case "zip", "love": return (.fileZip, hex(0x8DC149))
        case "txt", "": return (.file, foreground)
        default: return (.file, foreground)
        }
    }
}

// MARK: - Codicons

/// VS Code's icon font (github.com/microsoft/vscode-codicons, CC BY 4.0), bundled as codicon.ttf.
enum Codicon: UInt32 {
    case account = 0xEB99, add = 0xEA60, arrowDown = 0xEA9A, arrowUp = 0xEAA1
    case caseSensitive = 0xEAB1, check = 0xEAB2, chevronDown = 0xEAB4, chevronRight = 0xEAB6
    case circleFilled = 0xEA71, clearAll = 0xEABF, close = 0xEA76, cloudUpload = 0xEAC3
    case collapseAll = 0xEAC5, copy = 0xEBCC, debugStop = 0xEAD7, diff = 0xEAE1, discard = 0xEAE2
    case edit = 0xEA73, ellipsis = 0xEA7C, expandAll = 0xEB95, file = 0xEA7B, fileBinary = 0xEAE8
    case fileCode = 0xEAE9, fileMedia = 0xEAEA, fileZip = 0xEAEF, files = 0xEAF0, gitCommit = 0xEAFC
    case goToFile = 0xEA94, history = 0xEA82, home = 0xEB06, json = 0xEB0F, linkExternal = 0xEB14
    case listFlat = 0xEB84, listTree = 0xEB86, markdown = 0xEB1D, newFile = 0xEA7F, play = 0xEB2C
    case preserveCase = 0xEB2E, refresh = 0xEB37, regex = 0xEB38, remove = 0xEB3B, replace = 0xEB3D
    case replaceAll = 0xEB3C, repoPull = 0xEB40, repoPush = 0xEB41, search = 0xEA6D, settingsGear = 0xEB51
    case signIn = 0xEA6F, signOut = 0xEA6E, sourceControl = 0xEA68, symbolColor = 0xEB5C, sync = 0xEA77
    case textSize = 0xEB69, trash = 0xEA81, unmute = 0xEB75, wholeWord = 0xEB7E
    case extensions = 0xEAE6, cloudDownload = 0xEAC2, verified = 0xEB77, warning = 0xEA6C, info = 0xEA74
    case gear = 0xEAF8, starFull = 0xEB59, packageIcon = 0xEB29, error = 0xEA87
    case debugAlt = 0xEB91, debugContinue = 0xEACF, debugPause = 0xEAD1, debugStepOver = 0xEAD6
    case debugStepInto = 0xEAD4, debugStepOut = 0xEAD5, debugRestart = 0xEAD2, debugStackframe = 0xEB8B
    case debugBreakpointConditional = 0xEAA7, debugBreakpointLog = 0xEAAB, circleOutline = 0xEABC, closeAll = 0xEAC1
    case eye = 0xEA70, newFolder = 0xEA80, filter = 0xEAF1, gitPullRequest = 0xEA64

    /// The branch glyph; VS Code draws branches with the source control icon.
    static let gitBranch = Codicon.sourceControl

    var glyph: String { String(Character(Unicode.Scalar(rawValue)!)) }

    private static let fontName: String? = {
        guard let url = Bundle.main.url(forResource: "codicon", withExtension: "ttf")
                ?? Bundle.main.url(forResource: "codicon", withExtension: "ttf", subdirectory: "Fonts") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }()

    static func font(_ size: CGFloat) -> UIFont {
        fontName.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    private static var cache: [String: UIImage] = [:]

    /// A template image of the glyph, `size` points square, for buttons, list rows and menus.
    func image(_ size: CGFloat = 16) -> UIImage { Self.render(rawValue, size) }

    /// Codicon names ("refresh", "go-to-file") to code points, for the icons extensions name
    /// (Editor/codicon-names.json, from the codicons package's mapping).
    private static let codes: [String: UInt32] = {
        guard let url = Bundle.main.url(forResource: "codicon-names", withExtension: "json", subdirectory: "Editor")
                ?? Bundle.main.url(forResource: "codicon-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return [:] }
        return names.mapValues { UInt32($0) }
    }()

    /// The icon an extension names ("$(refresh)" or "refresh"), or nil if there's no such codicon.
    static func image(named name: String, size: CGFloat = 16) -> UIImage? {
        let bare = name.replacingOccurrences(of: "$(", with: "").replacingOccurrences(of: ")", with: "")
            .components(separatedBy: "~").first ?? name
        guard let code = codes[bare] else { return nil }
        return render(code, size)
    }

    private static func render(_ code: UInt32, _ size: CGFloat) -> UIImage {
        let key = "\(code)-\(size)"
        if let cached = cache[key] { return cached }
        let glyph = String(Character(Unicode.Scalar(code) ?? " "))
        let text = NSAttributedString(string: glyph, attributes: [.font: font(size), .foregroundColor: UIColor.black])
        let bounds = text.boundingRect(with: CGSize(width: 1000, height: 1000), options: .usesLineFragmentOrigin, context: nil)
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }

    /// The glyph as text, to sit inline in a label.
    func attributed(_ size: CGFloat = 14, color: UIColor? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: Self.font(size), .baselineOffset: -2]
        if let color { attributes[.foregroundColor] = color }
        return NSAttributedString(string: glyph, attributes: attributes)
    }
}

// MARK: - Controls

/// An action bar icon: a Codicon with VS Code's rounded press highlight. `.option` is the
/// inline toggle style used inside inputs (Match Case and friends).
final class VSIconButton: UIButton {
    enum Style { case toolbar, option }

    private let style: Style
    var isChecked = false { didSet { updateLook() } }

    init(_ icon: Codicon, label: String, style: Style = .toolbar, action: (() -> Void)? = nil) {
        self.style = style
        super.init(frame: .zero)
        setIcon(icon)
        accessibilityLabel = label
        tintColor = VS.icon
        layer.cornerRadius = style == .toolbar ? 5 : 3
        layer.borderWidth = style == .option ? 1 : 0
        isPointerInteractionEnabled = true
        translatesAutoresizingMaskIntoConstraints = false
        let side: CGFloat = style == .toolbar ? 26 : 22
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
        if let action { addAction(UIAction { _ in action() }, for: .touchUpInside) }
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIcon(_ icon: Codicon) {
        setImage(icon.image(16), for: .normal)
    }

    override var isHighlighted: Bool { didSet { updateLook() } }
    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.4 } }

    private func updateLook() {
        // VoiceOver says whether an option (Match Case and the like) is on.
        if style == .option { accessibilityTraits = isChecked ? [.button, .selected] : .button }
        if style == .option && isChecked {
            backgroundColor = VS.optionActiveBackground
            layer.borderColor = VS.optionActiveBorder.cgColor
            tintColor = .white
        } else {
            backgroundColor = isHighlighted ? VS.toolbarHover : .clear
            layer.borderColor = UIColor.clear.cgColor
            tintColor = VS.icon
        }
        accessibilityTraits = isChecked ? [.button, .selected] : .button
    }
}

/// VS Code's input box: flat #3C3C3C, a 1px focus border and optional inline toggles on the right.
final class VSTextField: UITextField {
    private let options = UIStackView()

    init(placeholder: String) {
        super.init(frame: .zero)
        font = VS.font(13)
        textColor = VS.foreground
        tintColor = VS.foreground
        backgroundColor = VS.inputBackground
        layer.cornerRadius = 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.clear.cgColor
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        keyboardAppearance = .dark
        returnKeyType = .search
        setPlaceholder(placeholder)
        options.axis = .horizontal
        options.spacing = 1
        options.alignment = .center
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPlaceholder(_ text: String) {
        attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: VS.placeholder, .font: VS.font(13)])
    }

    func setOptions(_ buttons: [UIView]) {
        options.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach(options.addArrangedSubview)
        options.frame.size = options.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        rightView = buttons.isEmpty ? nil : options
        rightViewMode = .always
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { layer.borderColor = VS.focusBorder.cgColor }
        return ok
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { layer.borderColor = UIColor.clear.cgColor }
        return ok
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { inset(bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { inset(bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { inset(bounds) }

    override func rightViewRect(forBounds bounds: CGRect) -> CGRect {
        let size = options.frame.size
        return CGRect(x: bounds.maxX - size.width - 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func inset(_ bounds: CGRect) -> CGRect {
        let right = rightView == nil ? 6 : options.frame.width + 6
        return bounds.inset(by: UIEdgeInsets(top: 0, left: 6, bottom: 0, right: right))
    }
}

/// The Source Control message box: grows with its text up to a limit; ⌘↩ submits.
final class VSTextView: UITextView {
    var onSubmit: (() -> Void)?
    var onChange: (() -> Void)?
    private let placeholderLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint!
    private let maxHeight: CGFloat = 132

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set { placeholderLabel.text = newValue }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = VS.font(13)
        textColor = VS.foreground
        tintColor = VS.foreground
        backgroundColor = VS.inputBackground
        keyboardAppearance = .dark
        layer.cornerRadius = 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.clear.cgColor
        textContainerInset = UIEdgeInsets(top: 5, left: 2, bottom: 5, right: 2)
        isScrollEnabled = false
        placeholderLabel.font = VS.font(13)
        placeholderLabel.textColor = VS.placeholder
        placeholderLabel.numberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 28)
        NSLayoutConstraint.activate([
            heightConstraint,
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            placeholderLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -14),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: UITextView.textDidChangeNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var text: String! {
        didSet { textChanged() }
    }

    @objc private func textChanged() {
        // UITextView can set its text during init, before the constraint exists.
        guard heightConstraint != nil else { return }
        placeholderLabel.isHidden = !text.isEmpty
        let fitting = sizeThatFits(CGSize(width: bounds.width > 0 ? bounds.width : 200, height: .greatestFiniteMagnitude)).height
        let height = min(max(28, ceil(fitting)), maxHeight)
        if heightConstraint.constant != height { heightConstraint.constant = height }
        isScrollEnabled = fitting > maxHeight
        onChange?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The width is only known after layout; re-measure once it is.
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(max(28, ceil(fitting)), maxHeight)
        if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { layer.borderColor = VS.focusBorder.cgColor }
        return ok
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { layer.borderColor = UIColor.clear.cgColor }
        return ok
    }

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(submitCommand))
        submit.discoverabilityTitle = "Commit"
        return [submit]
    }

    @objc private func submitCommand() { onSubmit?() }
}

/// VS Code's primary button, optionally split with a dropdown (as the Commit button is).
final class VSButton: UIView {
    /// Yellow, for an action that only partly works (installing a partly supported extension).
    var isWarning = false {
        didSet {
            updateHighlight()
            if !titleText.isEmpty { setTitle(titleText, icon: titleIcon) }
        }
    }
    private var titleText = ""
    private var titleIcon: Codicon?
    let mainButton = UIButton(type: .custom)
    let dropdownButton = UIButton(type: .custom)
    private let separator = UIView()

    var isEnabled = true {
        didSet {
            mainButton.isEnabled = isEnabled
            alpha = isEnabled ? 1 : 0.4
        }
    }

    init(split: Bool) {
        super.init(frame: .zero)
        backgroundColor = VS.buttonBackground
        layer.cornerRadius = 2
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        for button in [mainButton, dropdownButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isPointerInteractionEnabled = true
            button.addAction(UIAction { [weak self] _ in self?.updateHighlight() }, for: [.touchDown, .touchDragEnter])
            button.addAction(UIAction { [weak self] _ in self?.updateHighlight() },
                             for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        }
        dropdownButton.setImage(Codicon.chevronDown.image(16), for: .normal)
        dropdownButton.tintColor = .white
        dropdownButton.showsMenuAsPrimaryAction = true
        dropdownButton.accessibilityLabel = "More Actions"
        separator.backgroundColor = VS.buttonSeparator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            mainButton.topAnchor.constraint(equalTo: topAnchor),
            mainButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            mainButton.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        if split {
            addSubview(separator)
            addSubview(dropdownButton)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: mainButton.trailingAnchor),
                separator.widthAnchor.constraint(equalToConstant: 1),
                separator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                dropdownButton.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
                dropdownButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                dropdownButton.topAnchor.constraint(equalTo: topAnchor),
                dropdownButton.bottomAnchor.constraint(equalTo: bottomAnchor),
                dropdownButton.widthAnchor.constraint(equalToConstant: 28),
            ])
        } else {
            mainButton.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String, icon: Codicon?) {
        titleText = title
        titleIcon = icon
        let color = isWarning ? VS.warningButtonForeground : UIColor.white
        let text = NSMutableAttributedString()
        if let icon {
            text.append(icon.attributed(15, color: color))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: title, attributes: [.font: VS.font(13), .foregroundColor: color]))
        mainButton.setAttributedTitle(text, for: .normal)
        mainButton.accessibilityLabel = title
    }

    private func updateHighlight() {
        let pressed = mainButton.isHighlighted || dropdownButton.isHighlighted
        backgroundColor = isWarning ? (pressed ? VS.warningButtonHover : VS.warningButtonBackground) : (pressed ? VS.buttonHover : VS.buttonBackground)
    }
}

/// VS Code's count badge.
final class VSBadge: UILabel {
    init() {
        super.init(frame: .zero)
        font = VS.font(11)
        textColor = .white
        backgroundColor = VS.badgeBackground
        textAlignment = .center
        layer.cornerRadius = 9
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: max(18, size.width + 12), height: 18)
    }
}

// MARK: - List rows

/// One row of a VS Code tree: indent, twistie, icon, label, dimmed description, then trailing
/// decorations (badges, status letters, inline actions).
final class VSListCell: UITableViewCell {
    static let reuseID = "VSListCell"

    private let stack = UIStackView()
    private let indentSpacer = UIView()
    private let twistie = UIImageView()
    private let iconView = UIImageView()
    let titleLabel = UILabel()
    let descriptionLabel = UILabel()
    private let trailing = UIStackView()
    private var indentWidth: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    /// Drawn instead of the icon, e.g. the Graph's lane.
    private var leadingCustomView: UIView?

    /// A background that stays after the touch ends (the open file in the Explorer).
    var isMarked = false { didSet { updateBackground() } }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = VS.listSelection
        selectedBackgroundView = selected

        twistie.tintColor = VS.icon
        twistie.contentMode = .center
        iconView.contentMode = .center
        titleLabel.font = VS.font(13)
        titleLabel.textColor = VS.foreground
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        descriptionLabel.font = VS.font(12)
        descriptionLabel.textColor = VS.description
        descriptionLabel.lineBreakMode = .byTruncatingHead
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descriptionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.axis = .horizontal
        trailing.spacing = 2
        trailing.alignment = .center
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        for view: UIView in [indentSpacer, twistie, iconView, titleLabel, descriptionLabel, trailing] {
            stack.addArrangedSubview(view)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.setCustomSpacing(6, after: iconView)
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(4, after: descriptionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        indentWidth = indentSpacer.widthAnchor.constraint(equalToConstant: 0)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            indentWidth,
            twistie.widthAnchor.constraint(equalToConstant: 16),
            iconWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `twistie`: nil leaves the space empty (a leaf), true/false draws it expanded/collapsed.
    func configure(depth: Int, twistie expanded: Bool?, icon: Codicon?, iconColor: UIColor = VS.icon,
                   title: String, titleColor: UIColor = VS.foreground, strikethrough: Bool = false,
                   description: String? = nil, bold: Bool = false) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: VS.font(13, bold ? .semibold : .regular), .foregroundColor: titleColor,
        ]
        if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        configure(depth: depth, twistie: expanded, icon: icon, iconColor: iconColor,
                  attributedTitle: NSAttributedString(string: title, attributes: attributes), description: description)
    }

    func configure(depth: Int, twistie expanded: Bool?, icon: Codicon?, iconColor: UIColor = VS.icon,
                   attributedTitle: NSAttributedString, description: String? = nil) {
        indentWidth.constant = 4 + CGFloat(depth) * VS.indent
        twistie.image = expanded.map { ($0 ? Codicon.chevronDown : .chevronRight).image(16) }
        iconView.image = icon?.image(16)
        iconView.tintColor = iconColor
        iconView.isHidden = icon == nil
        iconWidth.constant = 16
        titleLabel.attributedText = attributedTitle
        descriptionLabel.text = description
        descriptionLabel.isHidden = (description ?? "").isEmpty
        accessibilityValue = expanded.map { $0 ? "expanded" : "collapsed" }
    }

    /// The file icon theme's icon for a file (FileIconTheme), in place of the built-in one.
    func useThemeIcon(file name: String) {
        if let image = FileIconTheme.shared.image(forFile: name) { showThemeIcon(image) }
    }

    /// The file icon theme's icon for a folder; the built-in look has none.
    func useThemeIcon(folder name: String, expanded: Bool) {
        if let image = FileIconTheme.shared.image(forFolder: name, expanded: expanded) { showThemeIcon(image) }
    }

    private func showThemeIcon(_ image: UIImage) {
        iconView.image = image.withRenderingMode(.alwaysOriginal)
        iconView.isHidden = false
        iconWidth.constant = 16
    }

    /// Replaces the icon with a custom view of the given width (the Graph's commit lane).
    func setLeadingView(_ view: UIView?, width: CGFloat) {
        leadingCustomView?.removeFromSuperview()
        leadingCustomView = view
        guard let view else {
            iconWidth.constant = width
            return
        }
        iconView.isHidden = false
        iconView.image = nil
        iconWidth.constant = width
        view.frame = CGRect(x: 0, y: 0, width: width, height: VS.rowHeight)
        view.autoresizingMask = [.flexibleHeight]
        iconView.addSubview(view)
        iconView.clipsToBounds = false
    }

    func setTrailing(_ views: [UIView]) {
        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(trailing.addArrangedSubview)
    }

    private var overlay: UIView?

    /// A full-height view at a fixed x, behind the row's content (the Graph's lane past a commit's files).
    func setOverlay(_ view: UIView?, x: CGFloat, width: CGFloat) {
        overlay?.removeFromSuperview()
        overlay = view
        guard let view else { return }
        view.frame = CGRect(x: x, y: 0, width: width, height: contentView.bounds.height > 0 ? contentView.bounds.height : VS.rowHeight)
        view.autoresizingMask = [.flexibleHeight]
        contentView.insertSubview(view, at: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setTrailing([])
        setLeadingView(nil, width: 16)
        setOverlay(nil, x: 0, width: 0)
        isMarked = false
    }

    private func updateBackground() {
        backgroundColor = isMarked ? VS.listSelection : .clear
    }

    /// A status letter (M, U, A, D) in the decoration colour.
    static func statusLetter(_ status: GitFileStatus) -> UILabel {
        let label = UILabel()
        label.text = status.rawValue
        label.font = VS.font(12, .semibold)
        label.textColor = VS.color(for: status)
        label.textAlignment = .center
        label.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return label
    }
}

/// A collapsible pane header ("GRAPH", "OPEN EDITORS"): bold uppercase 11pt with a top border.
final class VSPaneHeader: UITableViewHeaderFooterView, AutomationTappable {
    static let reuseID = "VSPaneHeader"
    var onToggle: (() -> Void)?
    private let twistie = UIImageView()
    private let title = UILabel()
    private let actions = UIStackView()
    private let topBorder = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = VS.sideBar
        backgroundConfiguration = background
        twistie.tintColor = VS.icon
        twistie.contentMode = .center
        title.font = VS.font(11, .bold)
        title.textColor = VS.foreground
        actions.axis = .horizontal
        actions.spacing = 0
        topBorder.backgroundColor = VS.sectionBorder
        let row = UIStackView(arrangedSubviews: [twistie, title, UIView(), actions])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        contentView.addSubview(topBorder)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: contentView.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            twistie.widthAnchor.constraint(equalToConstant: 20),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, expanded: Bool, actions buttons: [UIView]) {
        title.text = text.uppercased()
        accessibilityLabel = text.uppercased()
        twistie.image = (expanded ? Codicon.chevronDown : .chevronRight).image(16)
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach(actions.addArrangedSubview)
        actions.isHidden = !expanded
    }

    @objc private func tapped() { onToggle?() }

    func automationTap() { onToggle?() }
}

extension UIView {
    /// The view controller to present alerts and sheets from.
    var presenter: UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
