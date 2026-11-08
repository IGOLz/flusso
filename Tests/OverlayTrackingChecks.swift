// Run with:
// xcrun swiftc -default-isolation MainActor App/Sources/UI/Overlay/OverlayModel.swift \
//   App/Sources/UI/Overlay/OverlayController.swift Tests/OverlayTrackingChecks.swift \
//   -o build/overlay-tracking-checks && build/overlay-tracking-checks
import AppKit
import SwiftUI

// Stand-ins for unrelated app services; the controller and state model are real.
enum RecordingMode: Equatable { case hold, locked }
struct LearnedWord: Equatable { let term: String; let spokenAs: String? }
final class AppController {
    static let shared = AppController()
    func resolveLearnedWord(_ word: LearnedWord, add: Bool) {}
}
enum OverlayDemo { static func start() {} }
struct OverlayRootView: View {
    let model: OverlayModel
    var body: some View { Color.clear }
}

@main
struct OverlayTrackingChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let overlay = OverlayController.shared
        overlay.showRecording(mode: .hold)
        let panel = app.windows.compactMap { $0 as? OverlayPanel }.first!
        func expectedOrigin() -> NSPoint {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens.first!
            return NSPoint(
                x: (screen.visibleFrame.midX - OverlayLayout.panelSize.width / 2).rounded(),
                y: (screen.visibleFrame.minY + OverlayLayout.screenBottomMargin - OverlayLayout.shapeBottomInset).rounded()
            )
        }
        let expected = expectedOrigin()
        assert(panel.frame.origin == expected)

        // Force the panel away: each pill state must restore it on the next tick,
        // even without interactive controls or a hide/show between states.
        for state in [OverlayState.recording(.hold), .recording(.locked), .transcribing] {
            switch state {
            case .recording(let mode): overlay.showRecording(mode: mode)
            default: overlay.showTranscribing()
            }
            panel.setFrameOrigin(NSPoint(x: expected.x + 80, y: expected.y + 80))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            assert(panel.frame.origin == expectedOrigin(), "Pill did not track the mouse screen: \(state)")
            assert(!panel.isKeyWindow && !panel.canBecomeKey && !panel.canBecomeMain)
        }

        overlay.showNotPasted(text: "Keep the Copy button still")
        let toastOrigin = NSPoint(x: expected.x + 80, y: expected.y + 80)
        panel.setFrameOrigin(toastOrigin)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        assert(panel.frame.origin == toastOrigin, "Interactive toast should stay in place")

        overlay.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        assert(!panel.isVisible)
        assert(Mirror(reflecting: overlay).children.first { $0.label == "tickTimer" }
            .map { Mirror(reflecting: $0.value).children.isEmpty } == true, "Hidden overlay kept its timer")
        print("Overlay tracking checks passed: hold, locked, transcribing, toast, hide, focus")
    }
}
