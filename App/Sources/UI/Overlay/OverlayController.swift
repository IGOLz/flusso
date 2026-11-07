import AppKit
import SwiftUI

/// The floating recording widget ("pill") and the "not pasted" toast.
///
/// Lives in a borderless, non-activating panel that never becomes key or main,
/// so the frontmost app keeps focus and receives the pasted text.
final class OverlayController {
    static let shared = OverlayController()

    /// Where "Copy" writes. Overridable for tests so they don't clobber the user's clipboard.
    static var pasteboard: NSPasteboard = .general

    private let model = OverlayModel()
    private var panel: OverlayPanel?
    /// Bumped on every state change; delayed work checks it to know it's stale.
    private var generation = 0
    private var tickTimer: Timer?
    private var lastTick: CFTimeInterval = 0

    private init() {
        // Warm up the panel off the critical path, so the first shortcut press is instant
        // when `shared` was touched at launch (e.g. via `runDemoIfRequested()`).
        DispatchQueue.main.async { [self] in _ = ensurePanel() }
        if ProcessInfo.processInfo.arguments.contains("-overlayDemo") {
            DispatchQueue.main.async { OverlayDemo.start() }
        }
    }

    // MARK: Public API

    func showRecording(mode: RecordingMode) {
        setState(.recording(mode))
    }

    func showTranscribing() {
        setState(.transcribing)
    }

    func hide() {
        guard model.state != .hidden else { return }
        setState(.hidden)
    }

    func showNotPasted(text: String) {
        model.toastID += 1
        model.toastProgress = 1
        model.toastCopied = false
        model.toastHovered = false
        setState(.notPasted(text))
    }

    /// Offers a corrected word for the dictionary, unless the widget is busy.
    func showLearnWord(_ word: LearnedWord) {
        guard model.state == .hidden else { return }
        model.toastID += 1
        model.toastProgress = 1
        model.toastCopied = false
        model.toastHovered = false
        setState(.learnWord(word))
    }

    /// Starts the visual demo if the app was launched with `-overlayDemo`.
    static func runDemoIfRequested() {
        _ = shared   // init starts the demo when the flag is present
    }

    // MARK: Toast actions (called by the views)

    func copyToastText() {
        guard case .notPasted(let text) = model.state, !model.toastCopied else { return }
        let pb = Self.pasteboard
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.toastCopied = true }
        let id = model.toastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if model.toastID == id, model.state.isToast { hide() }
        }
    }

    func addLearnedWord() {
        guard case .learnWord(let word) = model.state, !model.toastCopied else { return }
        AppController.shared.resolveLearnedWord(word, add: true)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.toastCopied = true }
        let id = model.toastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if model.toastID == id, model.state.isToast { hide() }
        }
    }

    /// Hides a pending dictionary suggestion without declining it.
    func dismissLearnWord() {
        if case .learnWord = model.state { hide() }
    }

    func dismissToast() {
        // Closing the suggestion means "no": it isn't offered again.
        if case .learnWord(let word) = model.state, !model.toastCopied {
            AppController.shared.resolveLearnedWord(word, add: false)
        }
        if model.state.isToast { hide() }
    }

    // MARK: State machine

    private func setState(_ newState: OverlayState) {
        let panel = ensurePanel()
        generation += 1
        let wasHidden = model.state == .hidden || !panel.isVisible
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if newState == .hidden {
            withAnimation(hideAnimation) { model.state = .hidden }
            panel.ignoresMouseEvents = true
            stopTicking()
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                if gen == generation, model.state == .hidden { panel.orderOut(nil) }
            }
            return
        }

        if wasHidden {
            position(panel)
            panel.orderFrontRegardless()
        }
        withAnimation(showAnimation) { model.state = newState }
        updateMouseHandling()
        if newState.isInteractive { startTicking() } else { stopTicking() }
    }

    private var showAnimation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78)
    }

    private var hideAnimation: Animation {
        model.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.9)
    }

    // MARK: Panel

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(size: OverlayLayout.panelSize)
        let host = OverlayHostingView(rootView: OverlayRootView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: OverlayLayout.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bottom-center of the screen that contains the mouse pointer, just above the Dock.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = OverlayLayout.panelSize
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.minY + OverlayLayout.screenBottomMargin - OverlayLayout.shapeBottomInset).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    // MARK: Mouse pass-through + toast countdown

    /// Screen rect of the visible, clickable shape (or nil if nothing is clickable).
    private func interactiveScreenRect() -> NSRect? {
        guard let panel, model.state.isInteractive else { return nil }
        let local: CGRect
        let slop: CGFloat
        if model.state.isToast { local = model.toastFrame; slop = 10 } else { local = model.pillFrame; slop = 2 }
        guard local.width > 0 else { return nil }
        let h = panel.frame.height
        let rect = NSRect(x: panel.frame.minX + local.minX,
                          y: panel.frame.minY + (h - local.maxY),
                          width: local.width, height: local.height)
        return rect.insetBy(dx: -slop, dy: -slop)
    }

    private func updateMouseHandling() {
        guard let panel else { return }
        let inside = interactiveScreenRect()?.contains(NSEvent.mouseLocation) ?? false
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if model.state.isToast, model.toastHovered != inside { model.toastHovered = inside }
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        updateMouseHandling()

        guard model.state.isToast, !model.toastHovered, !model.toastCopied else { return }
        let duration: TimeInterval
        if case .learnWord = model.state { duration = OverlayLayout.learnToastDuration } else { duration = OverlayLayout.toastDuration }
        model.toastProgress = max(0, model.toastProgress - dt / duration)
        if model.toastProgress <= 0 { hide() }
    }
}

// MARK: - AppKit plumbing

final class OverlayPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostingView: NSHostingView<OverlayRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
