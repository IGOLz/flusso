import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Hold to record, release to transcribe. Any of them works.
    var holdShortcuts: [Shortcut] { didSet { save(holdShortcuts, "holdShortcuts") } }
    /// Press once to lock recording on, press again to stop and transcribe.
    var lockShortcuts: [Shortcut] { didSet { save(lockShortcuts, "lockShortcuts") } }
    /// Pastes the latest transcription again. Empty = disabled.
    var pasteLastShortcuts: [Shortcut] { didSet { save(pasteLastShortcuts, "pasteLastShortcuts") } }

    /// The first shortcut of each action, for short hints ("Hold fn to dictate").
    var holdShortcut: Shortcut { holdShortcuts.first ?? .none }
    var lockShortcut: Shortcut { lockShortcuts.first ?? .none }

    /// A dictation shortcut uses the fn key (see `FnKeyTip`).
    var dictationUsesFn: Bool {
        (holdShortcuts + lockShortcuts).contains { $0.modifiers.contains(.function) }
    }

    /// Languages the user speaks. Empty = automatic detection.
    /// Parakeet detects the language on its own; this list is a hint and
    /// drives filler-word cleanup.
    var spokenLanguages: [String] { didSet { save(spokenLanguages, "spokenLanguages") } }

    /// Words to always spell as written (see `CustomDictionary`).
    var dictionary: [DictionaryEntry] { didSet { save(dictionary, "dictionary") } }

    /// Self-corrections and spoken lists fixed by a language model.
    var smartFormatting: Bool { didSet { defaults.set(smartFormatting, forKey: "smartFormatting") } }
    /// Which model: Apple's (built in) or Gemma (downloaded, see `LocalFormatter`).
    var formattingEngine: FormattingEngine { didSet { defaults.set(formattingEngine.rawValue, forKey: "formattingEngine") } }

    /// Style for apps without their own (see `DictationStyle`).
    var defaultStyle: DictationStyle { didSet { defaults.set(defaultStyle.rawValue, forKey: "defaultStyle") } }
    /// Styles chosen for specific apps.
    var appStyles: [AppStyle] { didSet { save(appStyles, "appStyles") } }

    func style(forApp bundleID: String?) -> DictationStyle {
        guard let bundleID else { return defaultStyle }
        return appStyles.first { $0.bundleID == bundleID }?.style ?? defaultStyle
    }

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
        holdShortcuts = useDefaults ? [.holdDefault] : Self.loadShortcuts("hold", .holdDefault, from: defaults)
        lockShortcuts = useDefaults ? [.lockDefault] : Self.loadShortcuts("lock", .lockDefault, from: defaults)
        pasteLastShortcuts = useDefaults ? [.pasteLastDefault] : Self.loadShortcuts("pasteLast", .pasteLastDefault, from: defaults)
        spokenLanguages = Self.load("spokenLanguages", from: defaults) ?? ["en"]
        dictionary = Self.load("dictionary", from: defaults) ?? []
        snippets = Self.load("snippets", from: defaults) ?? []
        learnWords = defaults.bool(forKey: "learnWords")
        smartFormatting = defaults.bool(forKey: "smartFormatting")
        formattingEngine = defaults.string(forKey: "formattingEngine").flatMap(FormattingEngine.init(rawValue:)) ?? .apple
        defaultStyle = defaults.string(forKey: "defaultStyle").flatMap(DictationStyle.init(rawValue:)) ?? .asSpoken
        appStyles = Self.load("appStyles", from: defaults) ?? []
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

    /// Reads `<name>Shortcuts`, falling back to the single `<name>Shortcut`
    /// saved before Flusso supported several shortcuts per action.
    private static func loadShortcuts(_ name: String, _ fallback: Shortcut, from defaults: UserDefaults) -> [Shortcut] {
        if let list: [Shortcut] = load("\(name)Shortcuts", from: defaults) { return list.filter { !$0.isEmpty } }
        let legacy: Shortcut = load("\(name)Shortcut", from: defaults) ?? fallback
        return legacy.isEmpty ? [] : [legacy]
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
