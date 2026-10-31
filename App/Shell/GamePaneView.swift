import UIKit

struct LoveWindowConfig {
    var width: CGFloat = 800
    var height: CGFloat = 600
    var resizable: Bool = false
}

/// Container the runtime renders into. Tapping it gives the game input focus.
/// Supports non-resizable games by scaling the window, preserving aspect ratio,
/// while keeping the game's internal resolution (and coordinate space) exact.
final class GamePaneView: UIView {
    var onTap: (() -> Void)?
    var onLayout: (() -> Void)?

    var windowConfig = LoveWindowConfig() {
        didSet { setNeedsLayout() }
    }

    /// User override: force aspect fit letterboxing regardless of resizable flag
    var maintainAspectRatio = true {
        didSet { setNeedsLayout() }
    }

    private let placeholder = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1.0, alpha: 0.1).cgColor

        placeholder.text = "Game pane — press Run ▶"
        placeholder.textColor = .secondaryLabel
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 0
        placeholder.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(placeholder)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    override var canBecomeFirstResponder: Bool { true }

    func setFocused(_ focused: Bool) {
        layer.borderColor = (focused ? UIColor.systemBlue : UIColor(white: 1.0, alpha: 0.1)).cgColor
    }

    func setPlaceholderVisible(_ visible: Bool, text: String = "Game pane — press Run ▶") {
        placeholder.text = text
        placeholder.isHidden = !visible
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = bounds

        // Find the attached runtime view
        let gameViews = subviews.filter { $0 !== placeholder }
        guard let gameView = gameViews.first, bounds.width > 0, bounds.height > 0 else {
            onLayout?()
            return
        }

        let isFixed = !windowConfig.resizable || maintainAspectRatio

        if isFixed {
            let intW = windowConfig.width > 0 ? windowConfig.width : 800
            let intH = windowConfig.height > 0 ? windowConfig.height : 600

            let scale = min(bounds.width / intW, bounds.height / intH)
            gameView.bounds = CGRect(x: 0, y: 0, width: intW, height: intH)
            gameView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            gameView.transform = CGAffineTransform(scaleX: scale, y: scale)
        } else {
            gameView.transform = .identity
            gameView.frame = bounds
        }

        onLayout?()
    }
}
