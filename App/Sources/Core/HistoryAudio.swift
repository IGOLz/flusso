import Foundation

/// Recordings kept with the history (16 kHz mono 16-bit WAV, ~32 KB/s), so a
/// dictation can be replayed or transcribed again.
nonisolated enum HistoryAudio {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Flusso/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Writes 16 kHz mono float samples as a 16-bit PCM WAV file.
    static func write(_ samples: [Float], to url: URL) throws {
        let sampleRate = UInt32(AudioRecorder.sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(sampleRate)
        append(sampleRate * 2) // byte rate
        append(UInt16(2)) // block align
        append(UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Reads a file written by `write(_:to:)`.
    static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[36..<40].elementsEqual("data".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = (data.count - 44) / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 44 + i * 2, as: Int16.self))
                samples[i] = Float(value) / Float(Int16.max)
            }
        }
        return samples
    }

    static func delete(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
