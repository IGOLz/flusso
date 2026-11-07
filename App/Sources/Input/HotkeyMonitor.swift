@preconcurrency import AppKit
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import os

nonisolated enum HotkeyEvent: Sendable {
    /// The hold (push-to-talk) shortcut went down.
    case holdDown
    /// The hold shortcut was released.
    case holdUp
    /// The lock (hands-free) shortcut was pressed.
    case lockToggle
    /// Escape while dictating.
    case cancel
    /// Another key was pressed while the hold shortcut was down: the user is
    /// probably using it as a modifier (e.g. fn + ←).
    case holdInterrupted
    /// The "paste last transcription" shortcut was pressed.
    case pasteLast
}

/// Global shortcut detection via a `CGEventTap` running on its own thread,
/// so a busy main thread can never delay the start of a recording.
/// Requires the Accessibility permission.
///
/// The handler receives each event with the monotonic time (seconds, same
/// clock as `ProcessInfo.systemUptime`) at which the tap saw it, so timing
/// decisions don't depend on when the main thread gets to run.
nonisolated final class HotkeyMonitor: @unchecked Sendable {
    private struct Config {
        var hold: [Shortcut] = [.holdDefault]
        var lock: [Shortcut] = [.lockDefault]
        var pasteLast: [Shortcut] = [.pasteLastDefault]
        var suspended = false
        var dictating = false

        /// Modifiers that belong to a dictation shortcut (Escape still cancels while they're held).
        var dictationModifiers: ModifierKeys {
            (hold + lock).reduce(into: ModifierKeys()) { $0.formUnion($1.modifiers.sideAgnostic) }
        }
    }

    private let config = OSAllocatedUnfairLock(initialState: Config())
    /// Live keyboard state for the UI (shortcut key caps light up).
    private let keyboard = OSAllocatedUnfairLock(initialState: KeyboardSnapshot())
    /// Called on the event-tap thread. Keep it fast.
    private let handler: @Sendable (HotkeyEvent, TimeInterval) -> Void

    // Main actor only.
    private var tap: CFMachPort?

    // Event-tap thread state.
    private var tapForThread: CFMachPort?
    private var held: ModifierKeys = []
    /// The hold shortcut currently down, if any.
    private var activeHold: Shortcut?
    /// The modifier-only lock shortcut currently down, if any.
    private var activeLockModifiers: Shortcut?
    private var swallowedKeyUps = Set<UInt16>()
    private var swallowedButtonUps = Set<UInt8>()
    private var wasSuspended = false

    init(handler: @escaping @Sendable (HotkeyEvent, TimeInterval) -> Void) {
        self.handler = handler
    }

    func update(hold: [Shortcut], lock: [Shortcut], pasteLast: [Shortcut]) {
        config.withLock { $0.hold = hold; $0.lock = lock; $0.pasteLast = pasteLast }
    }

    func setSuspended(_ value: Bool) {
        config.withLock { $0.suspended = value }
    }

    /// Lets the monitor know whether a dictation is in progress (Escape is
    /// only intercepted then).
    func setDictating(_ value: Bool) {
        config.withLock { $0.dictating = value }
    }

    /// Only read/written on the main actor (start is called from there).
    var isRunning: Bool { tap != nil }

    /// What is physically held right now (as seen by the tap).
    var keyboardSnapshot: KeyboardSnapshot { keyboard.withLock { $0 } }

    private func publishKeyboard() {
        let held = self.held
        keyboard.withLock { $0.held = held }
    }

    private func setKey(_ keyCode: UInt16, down: Bool) {
        keyboard.withLock { s in
            if down { s.keysDown.insert(keyCode) } else { s.keysDown.remove(keyCode) }
        }
    }

    private func setButton(_ button: UInt8, down: Bool) {
        keyboard.withLock { s in
            if down { s.buttonsDown.insert(button) } else { s.buttonsDown.remove(button) }
        }
    }

    private static func isButtonDown(_ button: UInt8) -> Bool {
        guard let b = CGMouseButton(rawValue: UInt32(button)) else { return false }
        return CGEventSource.buttonState(.combinedSessionState, button: b)
    }

    /// Starts the event tap thread. Returns false if the tap could not be
    /// created (Accessibility not granted yet).
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.hotkey.error("Event tap creation failed (Accessibility not granted?)")
            return false
        }
        self.tap = tap
        self.tapForThread = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "dev.igol.flusso.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        Log.hotkey.info("Event tap started")
        return true
    }

    // MARK: - Event tap thread

    private func emit(_ event: HotkeyEvent) {
        handler(event, ProcessInfo.processInfo.systemUptime)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapForThread { CGEvent.tapEnable(tap: tapForThread, enable: true) }
            Log.hotkey.info("Event tap re-enabled")
            reconcileWithPhysicalState(config.withLock { $0 })
            publishKeyboard()
            keyboard.withLock {
                $0.keysDown = $0.keysDown.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
                $0.buttonsDown = $0.buttonsDown.filter(Self.isButtonDown)
            }
            return pass
        }

        // Text Flusso itself is typing or pasting: not the user's keyboard.
        if (type == .keyDown || type == .keyUp),
           event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventMarker {
            return pass
        }

        let cfg = config.withLock { $0 }

        // Leaving suspension (shortcut recorder closed): resync with the keyboard.
        if wasSuspended != cfg.suspended {
            wasSuspended = cfg.suspended
            activeHold = nil
            activeLockModifiers = nil
            swallowedKeyUps.removeAll()
            swallowedButtonUps.removeAll()
            held = ModifierKeys(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        }

        if type == .otherMouseDown || type == .otherMouseUp {
            return handleMouse(down: type == .otherMouseDown, event: event, cfg)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown { setKey(keyCode, down: true) }
        if type == .keyUp { setKey(keyCode, down: false) }

        if type == .flagsChanged {
            held = ModifierKeys(eventFlags: event.flags.rawValue)
            publishKeyboard()
            guard !cfg.suspended else { return pass }
            handleModifiers(cfg)
            return pass
        }

        guard !cfg.suspended else { return pass }

        if type == .keyUp {
            if swallowedKeyUps.remove(keyCode) != nil {
                if let holdKey = activeHold?.keyCode, holdKey == keyCode {
                    activeHold = nil
                    emit(.holdUp)
                }
                return nil
            }
            return pass
        }

        guard type == .keyDown else { return pass }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Arrow/function keys carry the fn flag implicitly; use our tracked state.
        let mods = held

        // Escape cancels an ongoing dictation, even while the shortcut's own
        // modifiers (e.g. fn) are still held.
        if cfg.dictating, keyCode == UInt16(kVK_Escape),
           mods.sideAgnostic.subtracting(cfg.dictationModifiers).isEmpty {
            if !isRepeat { emit(.cancel) }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if cfg.lock.contains(where: { $0.matchesKeyDown(keyCode: keyCode, held: mods) }) {
            if !isRepeat { emit(.lockToggle) }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if let hold = cfg.hold.first(where: { $0.matchesKeyDown(keyCode: keyCode, held: mods) }) {
            if !isRepeat { beginHold(hold) }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if cfg.pasteLast.contains(where: { $0.matchesKeyDown(keyCode: keyCode, held: mods) }) {
            if !isRepeat {
                // e.g. fn + V while fn alone is the hold shortcut: the press of
                // fn started a dictation that must be dropped first.
                if activeHold?.isModifierOnly == true { emit(.holdInterrupted) }
                emit(.pasteLast)
            }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        // Any other key while a modifier-only hold shortcut is down.
        if activeHold?.isModifierOnly == true, !isRepeat {
            emit(.holdInterrupted)
        }
        return pass
    }

    /// Extra mouse buttons (middle, back, forward…). Matching presses and
    /// their releases are swallowed so the app under the pointer doesn't
    /// also act on them.
    private func handleMouse(down: Bool, event: CGEvent, _ cfg: Config) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let raw = event.getIntegerValueField(.mouseEventButtonNumber)
        guard (2...31).contains(raw) else { return pass }
        let button = UInt8(raw)
        setButton(button, down: down)
        guard !cfg.suspended else { return pass }

        guard down else {
            guard swallowedButtonUps.remove(button) != nil else { return pass }
            if activeHold?.mouseButton == button {
                activeHold = nil
                emit(.holdUp)
            }
            return nil
        }

        let mods = held
        if cfg.lock.contains(where: { $0.matchesMouseDown(button: button, held: mods) }) {
            emit(.lockToggle)
        } else if let hold = cfg.hold.first(where: { $0.matchesMouseDown(button: button, held: mods) }) {
            beginHold(hold)
        } else if cfg.pasteLast.contains(where: { $0.matchesMouseDown(button: button, held: mods) }) {
            if activeHold?.isModifierOnly == true { emit(.holdInterrupted) }
            emit(.pasteLast)
        } else {
            return pass
        }
        swallowedButtonUps.insert(button)
        return nil
    }

    /// A key or mouse hold shortcut went down. If a modifier-only hold is
    /// already recording (e.g. fn, then fn + Middle Click), the more specific
    /// one takes over: its release ends the dictation.
    private func beginHold(_ hold: Shortcut) {
        if activeHold == nil {
            activeHold = hold
            emit(.holdDown)
        } else if activeHold?.isModifierOnly == true {
            activeHold = hold
        }
    }

    private func handleModifiers(_ cfg: Config) {
        if let hold = activeHold {
            if hold.isModifierOnly, !held.isSuperset(of: hold.modifiers) {
                activeHold = nil
                emit(.holdUp)
            }
        } else if let hold = cfg.hold.first(where: { $0.matchesModifiers(held) }) {
            activeHold = hold
            emit(.holdDown)
        }

        if let lock = activeLockModifiers {
            if !held.isSuperset(of: lock.modifiers) { activeLockModifiers = nil }
        } else if let lock = cfg.lock.first(where: { $0.matchesModifiers(held) }) {
            activeLockModifiers = lock
            emit(.lockToggle)
        }
    }

    /// After the tap was disabled we may have missed key releases: compare
    /// our state with the physical keyboard and emit what was missed.
    private func reconcileWithPhysicalState(_ cfg: Config) {
        held = ModifierKeys(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        swallowedKeyUps = swallowedKeyUps.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
        swallowedButtonUps = swallowedButtonUps.filter(Self.isButtonDown)
        if let lock = activeLockModifiers, !held.isSuperset(of: lock.modifiers) { activeLockModifiers = nil }
        guard let hold = activeHold else { return }
        let stillHeld: Bool
        if let button = hold.mouseButton {
            stillHeld = Self.isButtonDown(button)
        } else if let key = hold.keyCode {
            stillHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
        } else {
            stillHeld = held.isSuperset(of: hold.modifiers)
        }
        if !stillHeld {
            activeHold = nil
            emit(.holdUp)
        }
    }
}
