import UIKit

/// The game half of the IDE: the runtime's game pane, a liquid glass control bar and the console.
/// The game pane keeps the game's aspect ratio; the console takes whatever height is left.
final class GameStageView: UIView, UITextFieldDelegate {
    let gamePane = GamePaneView()
    let controlBar = GameControlBar()
    let console = UITextView()
    /// Console input for programs that read it (plain Lua, Python).
    let inputField = VSTextField(placeholder: "Input: type a line and press Return")
    var onInput: ((String) -> Void)?

    /// false for console programs, which have nothing to draw: the console fills the stage.
    var showsGamePane = true {
        didSet { setNeedsLayout() }
    }

    /// How much of the stage's bottom the keyboard covers; the console and its input move above it.
    var keyboardInset: CGFloat = 0 {
        didSet { if keyboardInset != oldValue { setNeedsLayout() } }
    }

    var acceptsInput = false {
        didSet {
            inputField.isHidden = !acceptsInput
            if !acceptsInput { inputField.resignFirstResponder() }
            setNeedsLayout()
        }
    }

    var isConsoleVisible = true {
        didSet {
            controlBar.setConsoleVisible(isConsoleVisible)
            setNeedsLayout()
        }
    }

    static let barHeight: CGFloat = 36
    /// Console height a phone reserves below the game when sizing the stage to fit.
    static let phoneConsoleHeight: CGFloat = 96
    /// Smallest console the stage will squeeze to when space is tight.
    static let minConsoleHeight: CGFloat = 64

    /// Height / width of the game's internal resolution.
    var gameAspect: CGFloat {
        let c = gamePane.windowConfig
        return c.width > 0 && c.height > 0 ? c.height / c.width : 0.75
    }

    private var reservedHeight: CGFloat {
        Self.barHeight + (isConsoleVisible ? Self.phoneConsoleHeight : 0)
    }

    /// Height that shows the whole game at full width, plus bar and console.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        width * gameAspect + reservedHeight
    }

    /// Width that shows the whole game at the available height.
    func preferredWidth(forHeight height: CGFloat) -> CGFloat {
        max(0, height - reservedHeight) / gameAspect
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        console.isEditable = false
        console.backgroundColor = UIColor(white: 0.07, alpha: 1)
        console.textColor = UIColor(white: 0.85, alpha: 1)
        console.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        console.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        console.indicatorStyle = .white

        inputField.isHidden = true
        inputField.returnKeyType = .send
        inputField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.backgroundColor = UIColor(white: 0.12, alpha: 1)
        inputField.delegate = self

        addSubview(gamePane)
        addSubview(console)
        addSubview(inputField)
        addSubview(controlBar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        var b = bounds
        b.size.height = max(0, b.height - keyboardInset)
        let available = max(0, b.height - Self.barHeight)
        let gameHeight = !showsGamePane ? 0
            : isConsoleVisible
                ? max(0, min(available - Self.minConsoleHeight, b.width * gameAspect))
                : available
        gamePane.isHidden = !showsGamePane

        gamePane.frame = CGRect(x: 0, y: 0, width: b.width, height: gameHeight)
        controlBar.frame = CGRect(x: 0, y: gameHeight, width: b.width, height: Self.barHeight)
        let consoleTop = gameHeight + Self.barHeight
        let inputHeight: CGFloat = acceptsInput ? 34 : 0
        let consoleHeight = max(0, b.height - consoleTop - inputHeight)
        console.frame = CGRect(x: 0, y: consoleTop, width: b.width, height: consoleHeight)
        console.alpha = (isConsoleVisible || !showsGamePane) ? 1 : 0
        inputField.frame = CGRect(x: 4, y: consoleTop + consoleHeight + 4, width: max(0, b.width - 8), height: 26)
    }

    /// Return sends the line and keeps the keyboard up, like a terminal.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let line = textField.text ?? ""
        textField.text = ""
        onInput?(line)
        return false
    }

    func appendLog(_ line: String) {
        console.text.append(line + "\n")
        console.scrollRangeToVisible(NSRange(location: console.text.utf16.count, length: 0))
    }
}

/// Liquid glass strip under the game with the in-game controls.
final class GameControlBar: UIView {
    var onRestart: (() -> Void)?
    var onToggleConsole: (() -> Void)?
    var onSwap: (() -> Void)?
    var onToggleMaximize: (() -> Void)?
    var onStop: (() -> Void)?

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let statusDot = UIView()
    private let titleLabel = UILabel()
    private let restartButton = UIButton(type: .system)
    private let consoleButton = UIButton(type: .system)
    private let swapButton = UIButton(type: .system)
    private let maximizeButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.0, alpha: 0.55)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        let topHairline = UIView()
        topHairline.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topHairline)

        statusDot.backgroundColor = UIColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1)
        statusDot.layer.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.9, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        setup(restartButton, systemName: "arrow.counterclockwise", label: "Restart", action: #selector(restartTapped))
        setup(consoleButton, systemName: "terminal.fill", label: "Console", action: #selector(consoleTapped))
        setup(swapButton, systemName: "rectangle.2.swap", label: "Swap panes", action: #selector(swapTapped))
        setup(maximizeButton, systemName: "arrow.up.left.and.arrow.down.right", label: "Maximize game", action: #selector(maximizeTapped))
        setup(stopButton, systemName: "stop.fill", label: "Stop", action: #selector(stopTapped))
        stopButton.configuration?.baseForegroundColor = .white
        stopButton.configuration?.background.backgroundColor = UIColor(red: 0.85, green: 0.22, blue: 0.25, alpha: 0.95)

        let titleStack = UIStackView(arrangedSubviews: [statusDot, titleLabel])
        titleStack.axis = .horizontal
        titleStack.spacing = 7
        titleStack.alignment = .center

        let buttons = UIStackView(arrangedSubviews: [restartButton, consoleButton, swapButton, maximizeButton, stopButton])
        buttons.axis = .horizontal
        buttons.spacing = 6
        buttons.alignment = .center
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [titleStack, buttons])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),

            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: 0.5),

            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            row.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(_ button: UIButton, systemName: String, label: String, action: Selector) {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        cfg.baseForegroundColor = UIColor(white: 0.85, alpha: 1)
        cfg.background.backgroundColor = UIColor(white: 1.0, alpha: 0.1)
        cfg.background.cornerRadius = 14
        cfg.contentInsets = .zero
        button.configuration = cfg
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
    }

    func setConsoleVisible(_ visible: Bool) {
        consoleButton.configuration?.image = UIImage(systemName: visible ? "terminal.fill" : "terminal",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        consoleButton.configuration?.baseForegroundColor = visible ? UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1) : UIColor(white: 0.85, alpha: 1)
    }

    /// After the game exits with an error the stage stays open so its console can be read;
    /// the stop button then closes the stage instead.
    func setStopped(_ stopped: Bool) {
        statusDot.backgroundColor = stopped
            ? UIColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1)
            : UIColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1)
        let symbol = stopped ? "xmark" : "stop.fill"
        stopButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        stopButton.configuration?.background.backgroundColor = stopped
            ? UIColor(white: 1.0, alpha: 0.1)
            : UIColor(red: 0.85, green: 0.22, blue: 0.25, alpha: 0.95)
        stopButton.accessibilityLabel = stopped ? "Close game panel" : "Stop"
        restartButton.isHidden = stopped
        maximizeButton.isHidden = stopped
    }

    func setMaximized(_ maximized: Bool) {
        let name = maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        maximizeButton.configuration?.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        maximizeButton.accessibilityLabel = maximized ? "Restore split" : "Maximize game"
        swapButton.isHidden = maximized
    }

    @objc private func restartTapped() { onRestart?() }
    @objc private func consoleTapped() { onToggleConsole?() }
    @objc private func swapTapped() { onSwap?() }
    @objc private func maximizeTapped() { onToggleMaximize?() }
    @objc private func stopTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onStop?()
    }
}

/// Divider between the game stage and the IDE: the hinge crease on the iPhone Duo,
/// a hairline on regular iPhones.
final class PaneSeparatorView: UIView {
    var isHinge = false {
        didSet { setNeedsLayout() }
    }
    var isVertical = true {
        didSet { setNeedsLayout() }
    }

    private let line = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = isHinge ? UIColor(white: 0.03, alpha: 1) : UIColor(white: 0.2, alpha: 1)
        line.isHidden = !isHinge
        line.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        // A thin highlight running along the crease.
        line.frame = isVertical
            ? CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
            : CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
    }
}
