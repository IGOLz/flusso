#if DEBUG
import AVFoundation
import Foundation

/// Debug-only pipeline check, run from the command line:
///   Flusso -selfTest <model.gguf> <audio-file | mic:SECONDS>
/// Loads the model, transcribes a file (or the microphone), prints the
/// result and timings, and exits.
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-selfTest"), i + 2 < args.count else { return false }
        let modelPath = args[i + 1]
        let input = args[i + 2]
        Task {
            do {
                let engine = TranscriptionEngine()
                var t = Date()
                try await engine.load(path: modelPath)
                print("SELFTEST load+warmup: \(Int(Date().timeIntervalSince(t) * 1000)) ms")

                var samples: [Float]
                if input.hasPrefix("mic:") {
                    let seconds = Double(input.dropFirst(4)) ?? 4
                    let recorder = AudioRecorder(levels: AudioLevelMeter())
                    recorder.configure(warm: true, deviceUID: nil)
                    try await Task.sleep(for: .milliseconds(800))
                    t = Date()
                    recorder.beginCapture(preRoll: 0.3)
                    print("SELFTEST beginCapture: \(String(format: "%.3f", Date().timeIntervalSince(t) * 1000)) ms")
                    try await Task.sleep(for: .seconds(seconds))
                    samples = await recorder.endCapture()
                } else {
                    samples = try readAudio(URL(fileURLWithPath: input))
                }

                // FLUSSO_SELFTEST_PAD=<seconds>: quiet noise before and after (silence skipping test).
                if let pad = ProcessInfo.processInfo.environment["FLUSSO_SELFTEST_PAD"].flatMap(Double.init) {
                    let noise = (0..<Int(pad * 16_000)).map { _ in Float.random(in: -0.002...0.002) }
                    samples = noise + samples + noise
                }
                print("SELFTEST audio: \(String(format: "%.2f", Double(samples.count) / 16_000)) s, peak \(samples.map(abs).max() ?? 0)")
                let skipSilence = ProcessInfo.processInfo.environment["FLUSSO_SELFTEST_SKIP_SILENCE"] == "1"
                t = Date()
                let raw = try await engine.transcribe(samples, language: nil, skipSilence: skipSilence)
                print("SELFTEST transcribe: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                print("SELFTEST text: \(TextCleanup.clean(raw, removeFillers: true))")
                exit(0)
            } catch {
                print("SELFTEST error: \(error.localizedDescription)")
                exit(1)
            }
        }
        return true
    }

    private static func readAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let capacity = AVAudioFrameCount(Double(source.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var done = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
#endif
