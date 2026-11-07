import AppKit

/// Debug-only visual demo: launch with `-overlayDemo` to cycle through all
/// overlay states in a loop, with fake microphone levels.
enum OverlayDemo {
    private static var started = false
    private static var levelTimer: Timer?

    static func start() {
        guard !started else { return }
        started = true
        startFakeLevels()
        Task { @MainActor in
            let overlay = OverlayController.shared
            while true {
                log("hold"); overlay.showRecording(mode: .hold)
                try? await Task.sleep(for: .seconds(2))
                log("locked"); overlay.showRecording(mode: .locked)
                try? await Task.sleep(for: .seconds(3))
                log("transcribing"); overlay.showTranscribing()
                try? await Task.sleep(for: .seconds(1.5))
                log("notPasted")
                overlay.showNotPasted(text: "Hi Mark, confirming tomorrow's meeting at ten. I'll bring the updated slides with this quarter's numbers.")
                try? await Task.sleep(for: .seconds(7))
                log("hidden"); overlay.hide()
                try? await Task.sleep(for: .seconds(1.5))
                log("learnWord")
                overlay.showLearnWord(LearnedWord(term: "SwiftUI", spokenAs: "swift you eye"))
                try? await Task.sleep(for: .seconds(4))
                log("hidden"); overlay.hide()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private static func log(_ s: String) {
        print("[overlayDemo] \(Date().timeIntervalSince1970) \(s)")
        fflush(stdout)
    }

    /// Speech-like envelope: syllables (~5 Hz) inside words, short pauses.
    private static func startFakeLevels() {
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.015, repeats: true) { _ in
            MainActor.assumeIsolated { pushFakeLevel(start: start) }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private static func pushFakeLevel(start: CFTimeInterval) {
        let t = CACurrentMediaTime() - start
        let syllable = 0.5 + 0.5 * sin(t * 2 * .pi * 4.7)
        let word = max(0, sin(t * 2 * .pi * 0.4) + 0.8)
        let noise = Double.random(in: 0.75...1.0)
        let level = Float(min(1, 0.3 + 0.7 * syllable * min(1, word) * noise))
        AppController.shared.levels.push(word < 0.05 ? Float.random(in: 0...0.04) : level)
    }
}
