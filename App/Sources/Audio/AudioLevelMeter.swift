import Foundation
import Synchronization

/// Thread-safe history of recent microphone levels for the waveform widget.
/// Written from the audio thread, read by the UI at display rate.
nonisolated final class AudioLevelMeter: Sendable {
    private struct State {
        var levels = [Float](repeating: 0, count: AudioLevelMeter.capacity)
        var head = 0
    }

    nonisolated static let capacity = 64
    private let state = Mutex(State())

    nonisolated init() {}

    /// Pushes one normalized level (0...1).
    nonisolated func push(_ level: Float) {
        state.withLock { s in
            s.levels[s.head] = level
            s.head = (s.head + 1) % Self.capacity
        }
    }

    nonisolated func reset() {
        state.withLock { s in
            for i in s.levels.indices { s.levels[i] = 0 }
        }
    }

    /// The most recent `count` levels, oldest first, each in 0...1.
    nonisolated func snapshot(count: Int) -> [Float] {
        let n = min(count, Self.capacity)
        return state.withLock { s in
            (0..<n).map { i in
                let idx = (s.head - n + i + Self.capacity * 2) % Self.capacity
                return s.levels[idx]
            }
        }
    }

    /// Converts a buffer RMS to a perceptual 0...1 level.
    nonisolated static func normalize(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)          // ~ -60 (silence) ... 0 (clipping)
        let floor: Float = -55, ceiling: Float = -12
        let x = (db - floor) / (ceiling - floor)
        return max(0, min(1, x))
    }
}
