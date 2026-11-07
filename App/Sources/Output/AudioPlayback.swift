import AppKit
import AVFoundation
import Observation

/// Plays history recordings, one at a time.
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    /// The history item being played.
    private(set) var playingID: HistoryItem.ID?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ item: HistoryItem) {
        if playingID == item.id {
            stop()
            return
        }
        stop()
        guard let fileName = item.audioFile else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: HistoryAudio.url(for: fileName))
            player.delegate = self
            guard player.play() else { return }
            self.player = player
            playingID = item.id
        } catch {
            Log.app.error("Playback failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finished { self.stop() }
        }
    }
}
