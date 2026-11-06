import AppKit
import Observation

/// What the on-screen widget currently shows.
enum OverlayState: Equatable {
    case hidden
    case recording(RecordingMode)
    case transcribing
    case notPasted(String)

    var isPill: Bool {
        switch self {
        case .recording, .transcribing: true
        default: false
        }
    }

    var isToast: Bool {
        if case .notPasted = self { return true }
        return false
    }

    /// States where the widget has clickable controls.
    var isInteractive: Bool {
        switch self {
        case .recording(.locked), .notPasted: true
        default: false
        }
    }
}

/// Shared, observable state between `OverlayController` and the SwiftUI views.
@Observable
final class OverlayModel {
    var state: OverlayState = .hidden
    var reduceMotion = false

    // Toast
    var toastID = 0
    /// Countdown progress, 1 → 0.
    var toastProgress: Double = 1
    var toastCopied = false
    var toastHovered = false

    /// Frames of the visible shapes in hosting-view coordinates (top-left origin),
    /// used to decide when the panel should accept mouse events.
    @ObservationIgnored var pillFrame: CGRect = .zero
    @ObservationIgnored var toastFrame: CGRect = .zero
}

/// Layout constants, tuned against Wispr Flow's widget.
enum OverlayLayout {
    static let panelSize = CGSize(width: 380, height: 150)
    /// Distance between the panel's bottom and the visible shape's bottom
    /// (room for the soft shadow).
    static let shapeBottomInset: CGFloat = 16
    /// Distance between the shape's bottom and `screen.visibleFrame.minY`.
    static let screenBottomMargin: CGFloat = 20

    static let pillHeight: CGFloat = 32
    static let buttonDiameter: CGFloat = 21
    static let buttonInset: CGFloat = 5.5
    static let buttonGap: CGFloat = 7
    static let holdHorizontalPadding: CGFloat = 13

    static let barCount = 11
    static let barWidth: CGFloat = 2.4
    static let barSpacing: CGFloat = 2.4
    static let barMinHeight: CGFloat = 2.4
    static let barMaxHeight: CGFloat = 18
    static var waveformWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    static let toastWidth: CGFloat = 330
    static let toastCornerRadius: CGFloat = 14
    static let toastDuration: TimeInterval = 5
}
