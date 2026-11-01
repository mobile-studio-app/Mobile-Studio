import UIKit
import WebKit

/// The editor's web view, with VS Code's editor context menu items added to the menu iOS shows
/// for a long press, a selection, or a right click with a trackpad or mouse.
final class EditorWKWebView: WKWebView {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }
        func action(_ title: String, _ symbol: String, _ command: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.callAsyncJavaScript("return await window.duocode.runCommand(command)", arguments: ["command": command],
                                          in: nil, in: .page) { _ in }
            }
        }
        let code = UIMenu(title: "Code", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), children: [
            UIMenu(options: .displayInline, children: [
                action("Go to Definition", "arrow.right.circle", "editor.action.revealDefinition"),
                action("Peek Definition", "eye", "editor.action.peekDefinition"),
                action("Go to References", "list.bullet.indent", "editor.action.referenceSearch.trigger"),
            ]),
            UIMenu(options: .displayInline, children: [
                action("Rename Symbol", "pencil", "editor.action.rename"),
                action("Quick Fix…", "lightbulb", "editor.action.quickFix"),
                action("Format Document", "text.alignleft", "editor.action.formatDocument"),
            ]),
            UIMenu(options: .displayInline, children: [
                action("Add Next Occurrence", "plus.rectangle.on.rectangle", "editor.action.addSelectionToNextFindMatch"),
                action("Select All Occurrences", "rectangle.stack", "editor.action.selectHighlights"),
                action("Toggle Line Comment", "number", "editor.action.commentLine"),
            ]),
        ])
        builder.insertSibling(code, afterMenu: .standardEdit)
    }
}
