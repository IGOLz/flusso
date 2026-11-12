// Run with:
// xcrun swiftc -default-isolation MainActor App/Sources/UI/Overlay/OverlayModel.swift \
//   App/Sources/UI/Overlay/OverlayController.swift App/Sources/UI/Overlay/OverlayViews.swift \
//   Tests/OverlayTrackingChecks.swift \
//   -o build/overlay-tracking-checks && build/overlay-tracking-checks
import AppKit
import SwiftUI

// Stand-ins for unrelated app services; the controller and state model are real.
enum RecordingMode: Equatable { case hold, locked }
struct LearnedWord: Equatable { let term: String; let spokenAs: String? }
final class AppController {
    static let shared = AppController()
    let levels = TestLevels()
    func cancelRecording() {}
    func finishRecording() {}
    func resolveLearnedWord(_ word: LearnedWord, add: Bool) {}
}
struct TestLevels {
    func snapshot(count: Int) -> [Float] { Array(repeating: 0, count: count) }
}
enum OverlayDemo { static func start() {} }

@main
struct OverlayTrackingChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            await runChecks(app: app)
            app.terminate(nil)
        }
        app.run()
    }

    static func runChecks(app: NSApplication) async {
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
            try? await Task.sleep(for: .seconds(0.3))
            assert(panel.frame.origin == expectedOrigin(), "Pill did not track the mouse screen: \(state)")
            assert(!panel.isKeyWindow && !panel.canBecomeKey && !panel.canBecomeMain)
        }

        overlay.showNotPasted(text: "Keep the Copy button still")
        try? await Task.sleep(for: .seconds(0.8))
        let model = Mirror(reflecting: overlay).children.first { $0.label == "model" }!.value as! OverlayModel
        assert(abs(model.toastFrame.width - OverlayLayout.toastWidth) < 1, "Real toast did not lay out")
        assert(model.toastFrame.height > 26, "Real toast text and Copy button must be visible")
        let toastOrigin = NSPoint(x: expected.x + 80, y: expected.y + 80)
        panel.setFrameOrigin(toastOrigin)
        try? await Task.sleep(for: .seconds(0.3))
        assert(panel.frame.origin == toastOrigin, "Interactive toast should stay in place")

        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        OverlayController.pasteboard = clipboard
        overlay.copyToastText()
        assert(clipboard.string(forType: .string) == "Keep the Copy button still")
        overlay.showNotPasted(text: "New transcription")
        try? await Task.sleep(for: .seconds(0.9))
        assert(panel.isVisible, "The previous Copy must not dismiss a new fallback")
        overlay.copyToastText()
        assert(clipboard.string(forType: .string) == "New transcription")
        try? await Task.sleep(for: .seconds(1.3))
        assert(!panel.isVisible, "Copied fallback should dismiss")

        overlay.showNotPasted(text: "Dismiss without copying")
        overlay.dismissToast()
        try? await Task.sleep(for: .seconds(0.5))
        assert(!panel.isVisible)

        overlay.hide()
        try? await Task.sleep(for: .seconds(0.5))
        assert(!panel.isVisible)
        assert(Mirror(reflecting: overlay).children.first { $0.label == "tickTimer" }
            .map { Mirror(reflecting: $0.value).children.isEmpty } == true, "Hidden overlay kept its timer")
        print("Overlay tracking checks passed: hold, locked, transcribing, toast, hide, focus")
    }
}
