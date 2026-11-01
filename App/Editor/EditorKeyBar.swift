import UIKit
import WebKit

/// The bar above the keyboard while editing code, in place of WebKit's form bar (‹ › Done):
/// Tab and Shift-Tab, arrow keys, undo/redo, the symbols code needs most, and hide keyboard.
final class EditorKeyBar: UIInputView {
    /// Called with a key name ("Tab", "ArrowLeft", "undo", "dismiss", ...) or "insert:<text>".
    var onKey: ((String) -> Void)?

    private static let symbols = ["(", ")", "{", "}", "[", "]", "\"", "'", "=", ".", ",", ":", ";", "+", "-", "*", "/", "<", ">", "#", "_", "~", "%", "&", "|", "!", "?"]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]

        let leading = UIStackView(arrangedSubviews: [
            key("⇥", name: "Tab", label: "Tab"),
            key("⇤", name: "Shift-Tab", label: "Outdent"),
            separator(),
        ])
        let symbolStack = UIStackView(arrangedSubviews: Self.symbols.map { key($0, name: "insert:\($0)", label: $0) })
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        symbolStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(symbolStack)
        let trailing = UIStackView(arrangedSubviews: [
            separator(),
            key("←", name: "ArrowLeft", label: "Left"),
            key("↑", name: "ArrowUp", label: "Up"),
            key("↓", name: "ArrowDown", label: "Down"),
            key("→", name: "ArrowRight", label: "Right"),
            separator(),
            icon("plus.rectangle.on.rectangle", name: "addNext", label: "Add Next Occurrence"),
            icon("text.line.last.and.arrowtriangle.forward", name: "cursorBelow", label: "Add Cursor Below"),
            separator(),
            icon("command", name: "palette", label: "Command Palette"),
            icon("arrow.uturn.backward", name: "undo", label: "Undo"),
            icon("arrow.uturn.forward", name: "redo", label: "Redo"),
            icon("keyboard.chevron.compact.down", name: "dismiss", label: "Hide Keyboard"),
        ])
        for stack in [leading, symbolStack, trailing] {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 2
        }
        let row = UIStackView(arrangedSubviews: [leading, scroll, trailing])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 44),
            symbolStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            symbolStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            symbolStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            symbolStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            symbolStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func key(_ title: String, name: String, label: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor(white: 1, alpha: 0.14)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var out = attributes
            out.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
            return out
        }
        return button(config, name: name, label: label)
    }

    private func icon(_ symbol: String, name: String, label: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        return button(config, name: name, label: label)
    }

    private func button(_ config: UIButton.Configuration, name: String, label: String) -> UIButton {
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.onKey?(name)
        }, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.2)
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return line
    }
}

extension EditorKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

extension WKWebView {
    /// Gives the web view's text input `bar` as its keyboard accessory. WebKit's content view
    /// supplies its own form bar and offers no setting, so this swaps in a subclass that returns `bar`.
    func useKeyboardAccessory(_ bar: UIView) {
        guard let content = scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }) else { return }
        EditorKeyBarHolder.bar = bar
        let baseClass: AnyClass = type(of: content)
        let name = "\(NSStringFromClass(baseClass))_DuoCodeKeyBar"
        if NSStringFromClass(baseClass) == name { return }
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let created = objc_allocateClassPair(baseClass, name, 0) {
            let getter: @convention(block) (AnyObject) -> UIView? = { _ in EditorKeyBarHolder.bar }
            let selector = #selector(getter: UIResponder.inputAccessoryView)
            if let method = class_getInstanceMethod(UIResponder.self, selector) {
                class_addMethod(created, selector, imp_implementationWithBlock(getter), method_getTypeEncoding(method))
            }
            objc_registerClassPair(created)
            subclass = created
        }
        if let subclass { object_setClass(content, subclass) }
    }
}

private enum EditorKeyBarHolder {
    static var bar: UIView?
}
