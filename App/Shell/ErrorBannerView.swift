import UIKit

/// VS Code-style error notification shown over the editor when the game reports a Lua error.
/// Tapping it jumps to the failing line; the close button dismisses it.
final class ErrorBannerView: UIView {
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let icon = UIImageView(image: UIImage(systemName: "xmark.octagon.fill"))
    private let messageLabel = UILabel()
    private let locationLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.24, green: 0.11, blue: 0.11, alpha: 0.97)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 0.6).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        icon.tintColor = UIColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = UIColor(white: 0.95, alpha: 1)
        messageLabel.numberOfLines = 3
        messageLabel.lineBreakMode = .byTruncatingTail

        locationLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        locationLabel.textColor = UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1)

        let textStack = UIStackView(arrangedSubviews: [messageLabel, locationLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        closeButton.tintColor = UIColor(white: 0.75, alpha: 1)
        closeButton.accessibilityLabel = "Dismiss error"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        addSubview(icon)
        addSubview(textStack)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            textStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `location` is e.g. "main.lua:12", or nil when the error has no usable source position.
    func configure(message: String, location: String?) {
        messageLabel.text = message
        locationLabel.text = location.map { "Go to \($0)" }
        locationLabel.isHidden = location == nil
    }

    /// Height that fits the current text at `width`.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - 12 - 16 - 10 - 4 - 42)
        let message = messageLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let location = locationLabel.isHidden ? 0 : locationLabel.font.lineHeight + 4
        return max(44, ceil(message + location + 22))
    }

    @objc private func tapped() { onTap?() }
    @objc private func closeTapped() { onDismiss?() }
}
