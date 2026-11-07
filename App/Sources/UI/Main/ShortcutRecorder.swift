import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Which global action a recorder edits.
enum ShortcutKind: CaseIterable {
    case hold, lock, pasteLast

    var name: String {
        switch self {
        case .hold: "hold to dictate"
        case .lock: "hands-free mode"
        case .pasteLast: "paste last transcription"
        }
    }

    @MainActor
    var shortcuts: [Shortcut] {
        get {
            let settings = AppSettings.shared
            switch self {
            case .hold: return settings.holdShortcuts
            case .lock: return settings.lockShortcuts
            case .pasteLast: return settings.pasteLastShortcuts
            }
        }
        nonmutating set {
            let settings = AppSettings.shared
            switch self {
            case .hold: settings.holdShortcuts = newValue
            case .lock: settings.lockShortcuts = newValue
            case .pasteLast: settings.pasteLastShortcuts = newValue
            }
        }
    }

    /// Dictation always needs a way to start; the paste shortcut can be turned off.
    var minimumCount: Int { self == .pasteLast ? 0 : 1 }
    static let maximumCount = 5
}

/// All the shortcuts of one action, each removable, plus an "Add" button
/// that records another one (a key combo, a modifier or a mouse button).
struct ShortcutList: View {
    let kind: ShortcutKind
    @Bindable private var settings = AppSettings.shared

    init(_ kind: ShortcutKind) { self.kind = kind }

    var body: some View {
        _ = settings.holdShortcuts; _ = settings.lockShortcuts; _ = settings.pasteLastShortcuts
        let list = kind.shortcuts
        return VStack(alignment: .trailing, spacing: 6) {
            // Identified by value (a list never holds the same shortcut twice),
            // so a row being recorded keeps its state when another is removed.
            ForEach(Array(list.enumerated()), id: \.element) { index, _ in
                ShortcutRecorder(kind, slot: .existing(index))
            }
            if list.count < ShortcutKind.maximumCount {
                ShortcutRecorder(kind, slot: .new)
            }
        }
        .animation(.snappy, value: list)
    }
}

/// Key-cap style control that records a global shortcut.
///
/// Click → "Press Shortcut…": a key combo (e.g. ⌥ + Space) is taken on key
/// down; pressing and releasing modifiers alone (e.g. fn, right ⌥) records a
/// modifier-only shortcut; an extra mouse button (middle, back, forward),
/// optionally with modifiers, records a mouse shortcut. Esc cancels.
struct ShortcutRecorder: View {
    enum Slot: Equatable {
        case existing(Int)
        /// Records a shortcut to append to the list.
        case new
    }

    let kind: ShortcutKind
    let slot: Slot
    @Bindable private var settings = AppSettings.shared
    @State private var capture = ShortcutCapture()
    /// The whole combination is physically held right now.
    @State private var fullyPressed = false

    init(_ kind: ShortcutKind, slot: Slot) {
        self.kind = kind
        self.slot = slot
    }

    private var shortcut: Shortcut {
        _ = settings.holdShortcuts; _ = settings.lockShortcuts; _ = settings.pasteLastShortcuts
        guard case .existing(let index) = slot, kind.shortcuts.indices.contains(index) else { return .none }
        return kind.shortcuts[index]
    }

    private var canRemove: Bool {
        if case .existing = slot { return kind.shortcuts.count > kind.minimumCount }
        return false
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if slot == .new && !capture.isCapturing {
                    addButton
                } else {
                    Button {
                        if capture.isCapturing { capture.cancel() } else { start() }
                    } label: {
                        label
                    }
                    .buttonStyle(.plain)
                    .help(capture.isCapturing ? "Press the new shortcut, or Esc to cancel" : "Click to change this shortcut")
                }

                if canRemove, !capture.isCapturing {
                    Button {
                        guard case .existing(let index) = slot else { return }
                        withAnimation(.snappy) { _ = kind.shortcuts.remove(at: index) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this shortcut")
                    .accessibilityLabel("Remove \(shortcut.displayString)")
                } else {
                    // Keeps every row of the list lined up.
                    Color.clear.frame(width: 16, height: 1)
                }
            }

            if let message = capture.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(capture.messageIsError ? .red : .secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .padding(.trailing, 22)
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

    private var addButton: some View {
        Button(action: start) {
            Label(kind.shortcuts.isEmpty ? "Add Shortcut" : "Add Another", systemImage: "plus")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .help("Add another shortcut for \(kind.name): keys or an extra mouse button")
    }

    private var label: some View {
        HStack(spacing: 6) {
            if capture.isCapturing {
                Image(systemName: "record.circle")
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Press Shortcut…")
                    .foregroundStyle(.tint)
                    .font(.callout.weight(.medium))
            } else if shortcut.isEmpty {
                Text("Off")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                LiveShortcutCaps(shortcut: shortcut) { fullyPressed = $0 }
                // Space is always reserved so the layout doesn't shift.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .opacity(fullyPressed ? 1 : 0)
                    .scaleEffect(fullyPressed ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 140, minHeight: 34)
        .background(recorderFill, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(recorderStroke, lineWidth: 1.5)
        }
        .animation(.snappy(duration: 0.15), value: fullyPressed)
        .contentShape(.rect)
    }

    private var recorderFill: AnyShapeStyle {
        if capture.isCapturing { return AnyShapeStyle(Color.accentColor.opacity(0.12)) }
        if fullyPressed { return AnyShapeStyle(Color.green.opacity(0.15)) }
        return AnyShapeStyle(.fill.quaternary)
    }

    private var recorderStroke: AnyShapeStyle {
        if capture.isCapturing { return AnyShapeStyle(Color.accentColor) }
        if fullyPressed { return AnyShapeStyle(Color.green) }
        return AnyShapeStyle(.clear)
    }

    private func start() {
        fullyPressed = false
        // The shortcut being replaced, found again by value when the capture
        // ends (rows above it may have been removed meanwhile).
        let original: Shortcut? = slot == .new ? nil : shortcut
        let kind = self.kind
        capture.start { candidate in
            if let error = Self.validate(candidate, kind: kind, replacing: original) { return error }
            if let original {
                guard let index = kind.shortcuts.firstIndex(of: original) else { return nil }
                kind.shortcuts[index] = candidate
            } else {
                kind.shortcuts.append(candidate)
            }
            return nil
        }
    }

    /// Returns an error message, or nil if the shortcut is acceptable.
    private static func validate(_ candidate: Shortcut, kind: ShortcutKind, replacing original: Shortcut?) -> String? {
        if kind == .pasteLast, candidate.isModifierOnly {
            return "Use a key with modifiers, like ⌃ ⌘ V, or a mouse button."
        }
        if let keyCode = candidate.keyCode {
            let meaningful = candidate.modifiers.subtracting([.leftShift, .rightShift])
            if meaningful.isEmpty && !ShortcutCapture.isFunctionKey(keyCode) {
                return "Add a modifier (fn, ⌃, ⌥, or ⌘) — a key on its own would get in the way of typing."
            }
        }
        for other in ShortcutKind.allCases {
            for existing in other.shortcuts {
                if other == kind, existing == original { continue }
                if candidate.conflicts(with: existing) {
                    return other == kind
                        ? "This shortcut is already in the list."
                        : "This shortcut is already used for \(other.name)."
                }
                // Hands-free toggles on every match: a modifier alone plus a
                // combo using it would switch it on and straight off again.
                if kind == .lock, other == .lock, existing != original,
                   candidate.overlapsAsToggle(with: existing) {
                    return "This overlaps with \(existing.displayString): pressing one would trigger both."
                }
            }
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
    /// Mouse buttons pressed while the pointer is over another app.
    @ObservationIgnored private var globalMouseMonitor: Any?
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
        message = "Press keys or an extra mouse button. Esc cancels."
        messageIsError = false
        isCapturing = true
        AppController.shared.hotkeysSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            let swallow = MainActor.assumeIsolated { self.handle(event) }
            return swallow ? nil : event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated { _ = self.handle(event) }
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

        case .otherMouseDown:
            // Left and right clicks never reach here; 2+ are middle, back, forward…
            guard event.buttonNumber >= 2, event.buttonNumber <= 31 else { return false }
            keyPressedInChord = true
            finish(with: Shortcut(keyCode: nil, modifiers: held, mouseButton: UInt8(event.buttonNumber)))
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
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
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
}
