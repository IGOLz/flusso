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

    /// Languages the user speaks. Empty = automatic detection.
    /// Parakeet detects the language on its own; this list is a hint and
    /// drives filler-word cleanup.
    var spokenLanguages: [String] { didSet { save(spokenLanguages, "spokenLanguages") } }

    /// Words to always spell as written (see `CustomDictionary`).
    var dictionary: [DictionaryEntry] { didSet { save(dictionary, "dictionary") } }

    var selectedModelID: String { didSet { defaults.set(selectedModelID, forKey: "selectedModelID") } }

    /// Keep the microphone stream open so recording starts instantly and the
    /// moment *before* the key press is captured too (pre-roll).
    var instantStart: Bool { didSet { defaults.set(instantStart, forKey: "instantStart") } }

    /// CoreAudio device UID; `nil` = system default input.
    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }

    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    var removeFillerWords: Bool { didSet { defaults.set(removeFillerWords, forKey: "removeFillerWords") } }
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
            "restoreClipboard": true,
            "removeFillerWords": true,
            "hasCompletedOnboarding": false,
        ])
        holdShortcut = Self.load("holdShortcut", from: defaults) ?? .holdDefault
        lockShortcut = Self.load("lockShortcut", from: defaults) ?? .lockDefault
        spokenLanguages = Self.load("spokenLanguages", from: defaults) ?? ["it"]
        dictionary = Self.load("dictionary", from: defaults) ?? []
        selectedModelID = defaults.string(forKey: "selectedModelID") ?? ModelCatalog.defaultModelID
        instantStart = defaults.bool(forKey: "instantStart")
        microphoneUID = defaults.string(forKey: "microphoneUID")
        playSounds = defaults.bool(forKey: "playSounds")
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        removeFillerWords = defaults.bool(forKey: "removeFillerWords")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
