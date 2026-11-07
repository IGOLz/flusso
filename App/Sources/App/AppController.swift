import AppKit
import Observation
import os

nonisolated enum RecordingMode: Equatable, Sendable {
    /// Push-to-talk: recording while the hold shortcut is pressed.
    case hold
    /// Hands-free: locked on until the lock shortcut (or ✓) is pressed again.
    case locked
}

enum DictationPhase: Equatable {
    case idle
    case recording(RecordingMode)
    case transcribing
}

enum EngineStatus: Equatable {
    case noModel
    case loading
    case ready
    case failed(String)
}

/// Thread-safe flag read by the event-tap thread before starting a capture.
nonisolated private final class DictationGate: Sendable {
    let canStart = AtomicFlag()
    /// The shortcuts page is open: shortcuts light up there but don't dictate.
    let previewing = AtomicFlag()
    let preRoll = AtomicFlag()
}

/// Orchestrates shortcut → recording → transcription → paste.
@Observable
final class AppController {
    static let shared = AppController()

    private(set) var phase: DictationPhase = .idle
    private(set) var engineStatus: EngineStatus = .noModel {
        didSet {
            let usable = engineStatus == .ready || engineStatus == .loading
            gate.canStart.set(usable)
        }
    }

    /// Set while the user is recording a new shortcut in Settings, so the
    /// global shortcuts don't fire.
    var hotkeysSuspended = false {
        didSet {
            // A recording can't be finished while shortcuts are paused.
            if hotkeysSuspended { cancelRecording() }
            hotkeys.setSuspended(hotkeysSuspended)
        }
    }

    /// While true, shortcuts are still detected (and their keys swallowed)
    /// but don't start a dictation: used by the onboarding shortcuts page.
    /// Only effective while Flusso is the active app, so switching to
    /// another app to dictate always works.
    var shortcutPreview = false {
        didSet { updatePreviewGate() }
    }

    private func updatePreviewGate() {
        let effective = shortcutPreview && NSApp.isActive
        gate.previewing.set(effective)
        if effective { cancelRecording() }
    }

    /// Physical keyboard state seen by the global shortcut monitor.
    var keyboardSnapshot: KeyboardSnapshot { hotkeys.keyboardSnapshot }

    /// Live microphone levels for the waveform.
    @ObservationIgnored let levels: AudioLevelMeter

    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let engine = TranscriptionEngine()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let sounds = Sounds()
    @ObservationIgnored private let gate = DictationGate()
    @ObservationIgnored private var hotkeys: HotkeyMonitor!

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private let permissions = Permissions.shared
    @ObservationIgnored private let models = ModelManager.shared

    /// Monotonic time (event-tap clock) at which the current recording started.
    @ObservationIgnored private var recordingStartedAt: TimeInterval = 0
    @ObservationIgnored private var recordingCounter = 0
    @ObservationIgnored private var captureCounter = 0
    @ObservationIgnored private var loadToken = 0
    /// Hands-free mode: a quick tap of the hold key stops the recording.
    @ObservationIgnored private var lockedHoldDownAt: TimeInterval?
    @ObservationIgnored private var lockToggledSinceHoldDown = false
    @ObservationIgnored private var started = false

    private init() {
        let levels = AudioLevelMeter()
        let recorder = AudioRecorder(levels: levels)
        let gate = self.gate
        self.levels = levels
        self.recorder = recorder

        // Runs on the event-tap thread: start capturing *before* hopping to
        // the main thread so a busy UI can never delay the recording.
        hotkeys = HotkeyMonitor { event, time in
            if gate.previewing.value { return }
            switch event {
            case .holdDown:
                let didStart = gate.canStart.value
                    && recorder.beginCapture(preRoll: gate.preRoll.value ? 0.3 : 0)
                DispatchQueue.main.async { AppController.shared.handleHoldDown(didStart: didStart, at: time) }
            case .lockToggle:
                let didStart = gate.canStart.value && !recorder.isCapturing
                    && recorder.beginCapture(preRoll: gate.preRoll.value ? 0.3 : 0)
                DispatchQueue.main.async { AppController.shared.handleLockToggle(didStart: didStart, at: time) }
            case .holdUp:
                DispatchQueue.main.async { AppController.shared.handleHoldUp(at: time) }
            case .cancel:
                DispatchQueue.main.async { AppController.shared.cancelRecording() }
            case .holdInterrupted:
                DispatchQueue.main.async { AppController.shared.handleHoldInterrupted(at: time) }
            case .pasteLast:
                DispatchQueue.main.async { AppController.shared.pasteLastTranscription(waitForModifiers: true) }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        hotkeys.update(hold: settings.holdShortcut, lock: settings.lockShortcut, pasteLast: settings.pasteLastShortcut)
        startHotkeysIfPossible()
        configureRecorder()
        loadSelectedModel()

        models.onModelInstalled = { [weak self] model in
            guard let self else { return }
            if model.id == self.settings.selectedModelID || self.engineStatus == .noModel {
                self.selectModel(model)
            }
        }

        observeSettings()
        observePermissions()

        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppController.shared.updatePreviewGate() }
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [recorder] _ in
            recorder.setSuspended(true)
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [recorder] _ in
            recorder.setSuspended(false)
        }
    }

    // MARK: - Models

    func selectModel(_ model: ModelInfo) {
        if settings.selectedModelID != model.id { settings.selectedModelID = model.id }
        loadSelectedModel()
    }

    #if DEBUG
    /// Screenshots (`FLUSSO_DEBUG_SAMPLE=1`): show a ready engine without loading a model.
    func showSampleReadyState() { engineStatus = .ready }
    #endif

    private func loadSelectedModel() {
        let selected = ModelCatalog.model(id: settings.selectedModelID) ?? ModelCatalog.models[0]
        let model: ModelInfo
        if models.isInstalled(selected) {
            model = selected
        } else if let installed = ModelCatalog.models.first(where: { models.isInstalled($0) }) {
            model = installed
            settings.selectedModelID = installed.id
        } else {
            engineStatus = .noModel
            return
        }

        loadToken += 1
        let token = loadToken
        engineStatus = .loading
        let path = models.fileURL(for: model).path
        Task {
            do {
                try await engine.load(path: path)
                if token == loadToken { engineStatus = .ready }
            } catch {
                Log.engine.error("Model load failed: \(error.localizedDescription)")
                if token == loadToken { engineStatus = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Hotkey handling (main thread)

    private func handleHoldDown(didStart: Bool, at time: TimeInterval) {
        if didStart && (hotkeysSuspended || gate.previewing.value) {
            recorder.cancelCapture()
            return
        }
        if didStart {
            beginRecording(.hold, at: time)
            return
        }
        switch phase {
        case .recording(.locked):
            lockedHoldDownAt = time
            lockToggledSinceHoldDown = false
        case .idle where !gate.canStart.value:
            notifyNoModel()
        default:
            break
        }
    }

    private func handleHoldUp(at time: TimeInterval) {
        switch phase {
        case .recording(.hold):
            // A very short press is almost certainly accidental.
            if time - recordingStartedAt < 0.25 {
                cancelRecording()
            } else {
                finishRecording()
            }
        case .recording(.locked):
            if let down = lockedHoldDownAt, !lockToggledSinceHoldDown, time - down < 0.4 {
                finishRecording()
            }
            lockedHoldDownAt = nil
        default:
            break
        }
    }

    private func handleLockToggle(didStart: Bool, at time: TimeInterval) {
        lockToggledSinceHoldDown = true
        if didStart && (hotkeysSuspended || gate.previewing.value) {
            recorder.cancelCapture()
            return
        }
        if didStart {
            beginRecording(.locked, at: time)
            return
        }
        switch phase {
        case .recording(.hold):
            phase = .recording(.locked)
            OverlayController.shared.showRecording(mode: .locked)
        case .recording(.locked):
            finishRecording()
        case .idle where !gate.canStart.value:
            notifyNoModel()
        default:
            break
        }
    }

    private func handleHoldInterrupted(at time: TimeInterval) {
        // fn used as a modifier (fn + ←, fn + ⌫…) right after pressing it.
        if phase == .recording(.hold), time - recordingStartedAt < 1.0 {
            cancelRecording()
        }
    }

    // MARK: - Recording

    private func beginRecording(_ mode: RecordingMode, at time: TimeInterval) {
        recordingStartedAt = time
        lockedHoldDownAt = nil
        recordingCounter += 1
        let recording = recordingCounter
        phase = .recording(mode)
        hotkeys.setDictating(true)
        OverlayController.shared.showRecording(mode: mode)
        if settings.playSounds { sounds.playStart() }

        // Stop automatically at the capture limit instead of silently dropping audio.
        Task {
            try? await Task.sleep(for: .seconds(AudioRecorder.maxCaptureSeconds - 1))
            if recording == recordingCounter, case .recording = phase { finishRecording() }
        }
    }

    func cancelRecording() {
        guard case .recording = phase else { return }
        recorder.cancelCapture()
        hotkeys.setDictating(false)
        phase = .idle
        OverlayController.shared.hide()
    }

    func finishRecording() {
        guard case .recording = phase else { return }
        captureCounter += 1
        let id = captureCounter
        phase = .transcribing
        hotkeys.setDictating(false)
        OverlayController.shared.showTranscribing()

        // Detach the capture now so an immediate re-press starts a new one;
        // keep listening briefly for it (people release the key right as the
        // last syllable ends).
        let ticket = recorder.stopCapture(tail: 0.15)
        Task {
            let samples = await recorder.collect(ticket)
            if settings.playSounds { sounds.playStop() }
            await process(samples, id: id)
        }
    }

    private func process(_ samples: [Float], id: Int) async {
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration >= 0.3 else {
            Log.app.info("Recording too short (\(duration, format: .fixed(precision: 2))s), ignored")
            finishUI(id: id, notPasted: nil)
            return
        }
        do {
            let raw = try await engine.transcribe(samples, language: nil)
            let cleaned = TextCleanup.clean(raw, removeFillers: settings.removeFillerWords)
            let entries = settings.dictionary
            let text = entries.isEmpty ? cleaned : await Task.detached(priority: .userInitiated) {
                CustomDictionary.apply(cleaned, entries: entries)
            }.value
            guard !text.isEmpty else {
                finishUI(id: id, notPasted: nil)
                return
            }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName
            let outcome = await inserter.insert(text, restoreClipboard: settings.restoreClipboard)
            HistoryStore.shared.add(HistoryItem(
                text: text, date: Date(), wasPasted: outcome == .pasted,
                appName: outcome == .pasted ? appName : nil, duration: duration))
            finishUI(id: id, notPasted: outcome == .noFocusedField ? text : nil)
        } catch {
            Log.app.error("Transcription failed: \(error.localizedDescription)")
            finishUI(id: id, notPasted: nil)
        }
    }

    private func finishUI(id: Int, notPasted text: String?) {
        // A newer recording may already be running: leave its UI alone.
        guard id == captureCounter, phase == .transcribing else { return }
        phase = .idle
        if let text {
            OverlayController.shared.showNotPasted(text: text)
        } else {
            OverlayController.shared.hide()
        }
    }

    // MARK: - Paste last

    /// Pastes the most recent transcription again where the user is typing
    /// (e.g. after dictating into the wrong field).
    /// - Parameter waitForModifiers: triggered by a global shortcut whose
    ///   modifiers are still held; wait for their release so the synthetic
    ///   ⌘V isn't combined with them.
    /// - Parameter fromMenu: give the menu bar menu time to close first.
    func pasteLastTranscription(waitForModifiers: Bool = false, fromMenu: Bool = false) {
        guard phase == .idle, !pastingLast else { return }
        guard let text = HistoryStore.shared.items.first?.text, !text.isEmpty else {
            NSSound.beep()
            return
        }
        pastingLast = true
        Task {
            defer { pastingLast = false }
            // Still held: a synthetic ⌘V would combine with them (and could
            // even match the shortcut itself and be swallowed).
            if waitForModifiers, await !Self.waitForModifierRelease() { return }
            if fromMenu { try? await Task.sleep(for: .milliseconds(250)) }
            // A dictation may have started while waiting.
            guard phase == .idle else { return }
            let outcome = await inserter.insert(text, restoreClipboard: settings.restoreClipboard)
            if outcome == .noFocusedField { OverlayController.shared.showNotPasted(text: text) }
        }
    }

    @ObservationIgnored private var pastingLast = false

    /// Waits (up to 5 s) until no modifier key is physically held.
    /// Returns false if they are still held.
    private static func waitForModifierRelease() async -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        for _ in 0..<250 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func notifyNoModel() {
        NSSound.beep()
        MainWindowController.shared.show()
    }

    // MARK: - Configuration

    private func startHotkeysIfPossible() {
        guard !hotkeys.isRunning, permissions.accessibility else { return }
        _ = hotkeys.start()
    }

    private func configureRecorder() {
        let micGranted = permissions.microphone == .granted
        let warm = settings.instantStart && micGranted
        gate.preRoll.set(warm)
        recorder.configure(warm: warm, deviceUID: settings.microphoneUID)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.holdShortcut
            _ = settings.lockShortcut
            _ = settings.pasteLastShortcut
            _ = settings.instantStart
            _ = settings.microphoneUID
        } onChange: {
            Task { @MainActor in
                let c = AppController.shared
                c.hotkeys.update(hold: c.settings.holdShortcut, lock: c.settings.lockShortcut,
                                  pasteLast: c.settings.pasteLastShortcut)
                c.configureRecorder()
                c.observeSettings()
            }
        }
    }

    private func observePermissions() {
        withObservationTracking {
            _ = permissions.microphone
            _ = permissions.accessibility
        } onChange: {
            Task { @MainActor in
                let c = AppController.shared
                c.startHotkeysIfPossible()
                c.configureRecorder()
                c.observePermissions()
            }
        }
    }
}
