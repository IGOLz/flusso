@preconcurrency import AppKit
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import Synchronization

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
        var hold: Shortcut = .holdDefault
        var lock: Shortcut = .lockDefault
        var suspended = false
        var dictating = false
    }

    private let config = Mutex(Config())
    /// Live keyboard state for the UI (shortcut key caps light up).
    private let keyboard = Mutex(KeyboardSnapshot())
    /// Called on the event-tap thread. Keep it fast.
    private let handler: @Sendable (HotkeyEvent, TimeInterval) -> Void

    // Main actor only.
    private var tap: CFMachPort?

    // Event-tap thread state.
    private var tapForThread: CFMachPort?
    private var held: ModifierKeys = []
    private var holdActive = false
    private var lockModifierActive = false
    private var swallowedKeyUps = Set<UInt16>()
    private var wasSuspended = false

    init(handler: @escaping @Sendable (HotkeyEvent, TimeInterval) -> Void) {
        self.handler = handler
    }

    func update(hold: Shortcut, lock: Shortcut) {
        config.withLock { $0.hold = hold; $0.lock = lock }
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

    /// Starts the event tap thread. Returns false if the tap could not be
    /// created (Accessibility not granted yet).
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
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
            keyboard.withLock { $0.keysDown = $0.keysDown.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) } }
            return pass
        }

        let cfg = config.withLock { $0 }

        // Leaving suspension (shortcut recorder closed): resync with the keyboard.
        if wasSuspended != cfg.suspended {
            wasSuspended = cfg.suspended
            holdActive = false
            lockModifierActive = false
            swallowedKeyUps.removeAll()
            held = ModifierKeys(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
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
                if let holdKey = cfg.hold.keyCode, holdKey == keyCode, holdActive {
                    holdActive = false
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
           mods.sideAgnostic.subtracting(cfg.hold.modifiers.sideAgnostic.union(cfg.lock.modifiers.sideAgnostic)).isEmpty {
            if !isRepeat { emit(.cancel) }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if cfg.lock.matchesKeyDown(keyCode: keyCode, held: mods) {
            if !isRepeat { emit(.lockToggle) }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if cfg.hold.matchesKeyDown(keyCode: keyCode, held: mods) {
            if !isRepeat, !holdActive {
                holdActive = true
                emit(.holdDown)
            }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        // Any other key while a modifier-only hold shortcut is down.
        if holdActive, cfg.hold.isModifierOnly, !isRepeat {
            emit(.holdInterrupted)
        }
        return pass
    }

    private func handleModifiers(_ cfg: Config) {
        let hold = cfg.hold
        if hold.isModifierOnly, !hold.modifiers.isEmpty {
            if !holdActive, hold.matchesModifiers(held) {
                holdActive = true
                emit(.holdDown)
            } else if holdActive, !held.isSuperset(of: hold.modifiers) {
                holdActive = false
                emit(.holdUp)
            }
        }

        let lock = cfg.lock
        if lock.isModifierOnly, !lock.modifiers.isEmpty {
            if !lockModifierActive, lock.matchesModifiers(held) {
                lockModifierActive = true
                emit(.lockToggle)
            } else if lockModifierActive, !held.isSuperset(of: lock.modifiers) {
                lockModifierActive = false
            }
        }
    }

    /// After the tap was disabled we may have missed key releases: compare
    /// our state with the physical keyboard and emit what was missed.
    private func reconcileWithPhysicalState(_ cfg: Config) {
        held = ModifierKeys(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        swallowedKeyUps = swallowedKeyUps.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
        if lockModifierActive, !held.isSuperset(of: cfg.lock.modifiers) { lockModifierActive = false }
        guard holdActive else { return }
        let stillHeld: Bool
        if let key = cfg.hold.keyCode {
            stillHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
        } else {
            stillHeld = held.isSuperset(of: cfg.hold.modifiers)
        }
        if !stillHeld {
            holdActive = false
            emit(.holdUp)
        }
    }
}
