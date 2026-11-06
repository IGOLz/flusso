import AppKit

/// Subtle start/stop cues (preloaded so they play instantly).
final class Sounds {
    private let start: NSSound? = {
        let s = NSSound(named: "Tink")
        s?.volume = 0.18
        return s
    }()

    private let stop: NSSound? = {
        let s = NSSound(named: "Pop")
        s?.volume = 0.18
        return s
    }()

    func playStart() { replay(start) }
    func playStop() { replay(stop) }

    private func replay(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
