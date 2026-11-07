import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Hold to record, release to transcribe.
    var holdShortcut: Shortcut { didSet { save(holdShortcut, "holdShortcut") } }
    /// Press once to lock recording on, press again to stop and transcribe.
    var lockShortcut: Shortcut { didSet { save(lockShortcut, "lockShortcut") } }
    /// Pastes the latest transcription again. `.none` = disabled.
    var pasteLastShortcut: Shortcut { didSet { save(pasteLastShortcut, "pasteLastShortcut") } }

    /// Languages the user speaks. Empty = automatic detection.
    /// Parakeet detects the language on its own; this list is a hint and
    /// drives filler-word cleanup.
    var spokenLanguages: [String] { didSet { save(spokenLanguages, "spokenLanguages") } }

    /// Words to always spell as written (see `CustomDictionary`).
    var dictionary: [DictionaryEntry] { didSet { save(dictionary, "dictionary") } }

    /// Self-corrections and spoken lists fixed with Apple's on-device model.
    var smartFormatting: Bool { didSet { defaults.set(smartFormatting, forKey: "smartFormatting") } }

    /// Offer words the user corrects after a dictation for the dictionary.
    var learnWords: Bool { didSet { defaults.set(learnWords, forKey: "learnWords") } }
    /// Suggestions the user declined: never offered again.
    var declinedWords: [String] { didSet { save(declinedWords, "declinedWords") } }

    /// Voice shortcuts that expand into longer text (see `Snippets`).
    var snippets: [Snippet] { didSet { save(snippets, "snippets") } }

    var selectedModelID: String { didSet { defaults.set(selectedModelID, forKey: "selectedModelID") } }

    /// Keep the microphone stream open so recording starts instantly and the
    /// moment *before* the key press is captured too (pre-roll).
    var instantStart: Bool { didSet { defaults.set(instantStart, forKey: "instantStart") } }

    /// CoreAudio device UID; `nil` = system default input.
    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }

    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Transcribe only the parts with speech (Silero VAD).
    var skipSilence: Bool { didSet { defaults.set(skipSilence, forKey: "skipSilence") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: "insertionMethod") } }
    var trailingSpace: Bool { didSet { defaults.set(trailingSpace, forKey: "trailingSpace") } }
    var removeFillerWords: Bool { didSet { defaults.set(removeFillerWords, forKey: "removeFillerWords") } }
    /// Keep each dictation's recording with the history, to replay it or
    /// transcribe it again.
    var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: "keepAudio") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    Log.app.error("Launch at login change failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            "selectedModelID": ModelCatalog.defaultModelID,
            "instantStart": false,
            "playSounds": true,
            "skipSilence": true,
            "restoreClipboard": true,
            "trailingSpace": false,
            "removeFillerWords": true,
            "keepAudio": true,
            "learnWords": true,
            "smartFormatting": true,
            "hasCompletedOnboarding": false,
        ])
        #if DEBUG
        // Screenshots show the default shortcuts, whatever this Mac has saved.
        let useDefaults = DebugSample.isEnabled
        #else
        let useDefaults = false
        #endif
        holdShortcut = useDefaults ? .holdDefault : Self.load("holdShortcut", from: defaults) ?? .holdDefault
        lockShortcut = useDefaults ? .lockDefault : Self.load("lockShortcut", from: defaults) ?? .lockDefault
        pasteLastShortcut = useDefaults ? .pasteLastDefault : Self.load("pasteLastShortcut", from: defaults) ?? .pasteLastDefault
        spokenLanguages = Self.load("spokenLanguages", from: defaults) ?? ["en"]
        dictionary = Self.load("dictionary", from: defaults) ?? []
        snippets = Self.load("snippets", from: defaults) ?? []
        learnWords = defaults.bool(forKey: "learnWords")
        smartFormatting = defaults.bool(forKey: "smartFormatting")
        declinedWords = Self.load("declinedWords", from: defaults) ?? []
        selectedModelID = defaults.string(forKey: "selectedModelID") ?? ModelCatalog.defaultModelID
        instantStart = defaults.bool(forKey: "instantStart")
        microphoneUID = defaults.string(forKey: "microphoneUID")
        playSounds = defaults.bool(forKey: "playSounds")
        skipSilence = defaults.bool(forKey: "skipSilence")
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        insertionMethod = defaults.string(forKey: "insertionMethod").flatMap(InsertionMethod.init(rawValue:)) ?? .paste
        trailingSpace = defaults.bool(forKey: "trailingSpace")
        removeFillerWords = defaults.bool(forKey: "removeFillerWords")
        keepAudio = defaults.bool(forKey: "keepAudio")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    var insertOptions: InsertOptions {
        InsertOptions(method: insertionMethod, restoreClipboard: restoreClipboard, trailingSpace: trailingSpace)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
