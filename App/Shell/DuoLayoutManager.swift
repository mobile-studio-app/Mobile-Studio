import UIKit

/// The kind of display the IDE is currently drawn on.
enum DisplayKind {
    /// A regular iPhone, or the iPhone Duo's cover display when folded.
    case phone
    /// The iPhone Duo's unfolded inner display. The split is aligned to the physical hinge.
    case duoInner
}

/// Resolved layout for the current bounds and hinge state.
struct DuoLayout: Equatable {
    var display: DisplayKind
    /// `true`: game above the IDE (portrait). `false`: IDE and game side by side (landscape).
    var isVertical: Bool
}

protocol DuoLayoutManagerDelegate: AnyObject {
    func duoLayoutManagerHingeDidChange(_ manager: DuoLayoutManager)
}

/// Tracks the iPhone Duo hinge and decides how the IDE should be split.
final class DuoLayoutManager {
    static let shared = DuoLayoutManager()
    weak var delegate: DuoLayoutManagerDelegate?

    /// Mirrors UIHingeInteraction's status values.
    enum HingeStatus: Int {
        case closed = 0, fullyOpen = 1, partiallyOpen = 2, unknown = 3
    }

    private(set) var hingeStatus: HingeStatus = .unknown
    /// Width of the reserved crease region on the inner display.
    static let creaseThickness: CGFloat = 24

    func attach(to view: UIView) {
        _ = DuoHingeBridge.attach(to: view) { [weak self] _, status in
            guard let self else { return }
            let newStatus = HingeStatus(rawValue: status) ?? .unknown
            guard newStatus != self.hingeStatus else { return }
            self.hingeStatus = newStatus
            self.delegate?.duoLayoutManagerHingeDidChange(self)
        }
    }

    func layout(for bounds: CGRect, screenSize: CGSize) -> DuoLayout {
        let display: DisplayKind
        switch hingeStatus {
        case .closed:
            display = .phone
        case .fullyOpen, .partiallyOpen:
            display = .duoInner
        case .unknown:
            // No hinge reports yet: the inner display is far wider than any candybar iPhone.
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            display = isPhone && min(screenSize.width, screenSize.height) >= 600 ? .duoInner : .phone
        }
        return DuoLayout(display: display, isVertical: bounds.height >= bounds.width)
    }
}
