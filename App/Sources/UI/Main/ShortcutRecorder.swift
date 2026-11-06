import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Which of the two global shortcuts a recorder edits.
enum ShortcutKind {
    case hold, lock

    var name: String {
        switch self {
        case .hold: "dettare tenendo premuto"
        case .lock: "la modalità mani libere"
        }
    }
}

/// Key-cap style control that records a new global shortcut.
///
/// Click → "Premi i tasti…": a key combo (e.g. ⌥ + Spazio) is taken on key
/// down; pressing and releasing modifiers alone (e.g. fn, ⌥ destro) records a
/// modifier-only shortcut. Esc cancels.
struct ShortcutRecorder: View {
    let kind: ShortcutKind
    @Bindable private var settings = AppSettings.shared
    @State private var capture = ShortcutCapture()

    init(_ kind: ShortcutKind) { self.kind = kind }

    private var shortcut: Shortcut {
        kind == .hold ? settings.holdShortcut : settings.lockShortcut
    }

    private var otherShortcut: Shortcut {
        kind == .hold ? settings.lockShortcut : settings.holdShortcut
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                if capture.isCapturing { capture.cancel() } else { start() }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(capture.isCapturing ? "Premi la nuova combinazione, Esc per annullare" : "Fai clic per cambiare la scorciatoia")

            if let message = capture.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(capture.messageIsError ? .red : .secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: capture.isCapturing)
        .animation(.snappy, value: capture.message)
        .onDisappear { capture.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            capture.cancel()
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if capture.isCapturing {
                Image(systemName: "record.circle")
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Premi i tasti…")
                    .foregroundStyle(.tint)
                    .font(.callout.weight(.medium))
            } else {
                KeyCaps(shortcut)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 140, minHeight: 34)
        .background(capture.isCapturing ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.quaternary),
                    in: .rect(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(capture.isCapturing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), lineWidth: 1.5)
        }
        .contentShape(.rect)
    }

    private func start() {
        capture.start { candidate in
            if let error = validate(candidate) { return error }
            switch kind {
            case .hold: settings.holdShortcut = candidate
            case .lock: settings.lockShortcut = candidate
            }
            return nil
        }
    }

    /// Returns an error message, or nil if the shortcut is acceptable.
    private func validate(_ candidate: Shortcut) -> String? {
        if let keyCode = candidate.keyCode {
            let meaningful = candidate.modifiers.subtracting([.leftShift, .rightShift])
            if meaningful.isEmpty && !ShortcutCapture.isFunctionKey(keyCode) {
                return "Aggiungi un modificatore (fn, ⌃, ⌥ o ⌘): un tasto da solo bloccherebbe la scrittura."
            }
        }
        if ShortcutCapture.conflicts(candidate, otherShortcut) {
            let other = kind == .hold ? ShortcutKind.lock : .hold
            return "Questa scorciatoia è già usata per \(other.name)."
        }
        return nil
    }
}

/// Event-capturing state machine behind `ShortcutRecorder`.
@Observable
final class ShortcutCapture {
    private(set) var isCapturing = false
    private(set) var message: String?
    private(set) var messageIsError = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var peak: ModifierKeys = []
    /// A regular key was pressed during the current chord: releasing the
    /// modifiers afterwards must not produce a modifier-only shortcut.
    @ObservationIgnored private var keyPressedInChord = false
    /// The shortcut has been recorded but modifiers are still physically held:
    /// keep global hotkeys suspended until they're released.
    @ObservationIgnored private var awaitingRelease = false
    @ObservationIgnored private var onCapture: ((Shortcut) -> String?)?
    @ObservationIgnored private var releaseTimeout: Task<Void, Never>?

    /// Only one recorder captures at a time.
    @ObservationIgnored private static weak var active: ShortcutCapture?

    /// `onCapture` applies the shortcut and returns nil, or returns an error
    /// message to keep capturing.
    func start(onCapture: @escaping (Shortcut) -> String?) {
        if let other = Self.active, other !== self { other.cancel() }
        teardown()
        Self.active = self
        self.onCapture = onCapture
        peak = []
        keyPressedInChord = false
        message = "Esc per annullare"
        messageIsError = false
        isCapturing = true
        AppController.shared.hotkeysSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let swallow = MainActor.assumeIsolated { self.handle(event) }
            return swallow ? nil : event
        }
    }

    func cancel() {
        guard isCapturing || awaitingRelease || monitor != nil else { return }
        message = nil
        teardown()
    }

    /// Returns true when the event must be swallowed.
    private func handle(_ event: NSEvent) -> Bool {
        let held = ModifierKeys(eventFlags: UInt64(event.modifierFlags.rawValue))

        if awaitingRelease {
            if event.type == .flagsChanged && held.isEmpty { teardown() }
            return false
        }
        guard isCapturing else { return false }

        switch event.type {
        case .keyDown:
            if Int(event.keyCode) == kVK_Escape && held.isEmpty {
                cancel()
                return true
            }
            keyPressedInChord = true
            finish(with: Shortcut.fromKeyDown(event))
            return true

        case .flagsChanged:
            if held.isEmpty {
                let candidate = peak
                let hadKey = keyPressedInChord
                peak = []
                keyPressedInChord = false
                if !candidate.isEmpty && !hadKey {
                    finish(with: Shortcut(keyCode: nil, modifiers: candidate))
                }
            } else {
                peak.formUnion(held)
            }
            return true

        default:
            return false
        }
    }

    private func finish(with candidate: Shortcut) {
        if let error = onCapture?(candidate) {
            message = error
            messageIsError = true
            return
        }
        isCapturing = false
        message = nil
        if Self.currentlyHeldModifiers.isEmpty {
            teardown()
        } else {
            // Wait for the physical release before re-enabling global hotkeys,
            // otherwise the just-recorded combo could trigger dictation.
            awaitingRelease = true
            releaseTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.teardown()
            }
        }
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        releaseTimeout?.cancel()
        releaseTimeout = nil
        let wasActive = isCapturing || awaitingRelease || Self.active === self
        isCapturing = false
        awaitingRelease = false
        peak = []
        keyPressedInChord = false
        onCapture = nil
        if Self.active === self { Self.active = nil }
        if wasActive { AppController.shared.hotkeysSuspended = false }
    }

    private static var currentlyHeldModifiers: ModifierKeys {
        ModifierKeys(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return fKeys.contains(Int(keyCode))
    }

    /// Whether two shortcuts would trigger on the same input.
    static func conflicts(_ a: Shortcut, _ b: Shortcut) -> Bool {
        guard a.keyCode == b.keyCode else { return false }
        if a.keyCode == nil { return a.modifiers == b.modifiers }
        return a.modifiers.sideAgnostic == b.modifiers.sideAgnostic
    }
}
