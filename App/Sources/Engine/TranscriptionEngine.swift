import Foundation

nonisolated enum EngineError: LocalizedError {
    case loadFailed(String)
    case notLoaded
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let s): "Couldn't load the model (\(s))."
        case .notLoaded: "No model loaded."
        case .runFailed(let s): "Transcription failed (\(s))."
        }
    }
}

/// Swift wrapper around transcribe.cpp (GGUF models on ggml + Metal), the
/// same engine Handy uses. Every C call runs on one serial queue: a session
/// is single-threaded, and loads/runs must never overlap.
nonisolated final class TranscriptionEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.igol.flusso.engine", qos: .userInitiated)
    // Only touched on `queue`.
    private var session: OpaquePointer?
    private var loadedPath: String?
    /// Silero VAD (bundled, 1 MB), to skip silence before transcribing.
    private var vadModel: OpaquePointer?
    private var vadSession: OpaquePointer?

    nonisolated init() {
        queue.async {
            // Drop library/ggml chatter except errors.
            transcribe_log_set({ level, message, _ in
                guard level == TRANSCRIBE_LOG_LEVEL_ERROR, let message else { return }
                Log.engine.error("\(String(cString: message), privacy: .public)")
            }, nil)
            _ = transcribe_init_backends_default()
            self.loadVAD()
        }
    }

    /// Loads a model (replacing any loaded one) and warms it up so the first
    /// real dictation is as fast as the following ones.
    nonisolated func load(path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.loadedPath == path, self.session != nil {
                    cont.resume()
                    return
                }
                self.freeSession()
                let start = Date()
                var session: OpaquePointer?
                let status = transcribe_open(path, nil, nil, &session)
                guard status == TRANSCRIBE_OK, let session else {
                    let message = String(cString: transcribe_status_string(Int32(status.rawValue)))
                    cont.resume(throwing: EngineError.loadFailed(message))
                    return
                }
                self.session = session
                self.loadedPath = path
                let backend = String(cString: transcribe_model_backend(transcribe_get_model(session)))
                Log.engine.info("Loaded \(path, privacy: .public) on \(backend, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
                self.warmUp()
                Log.engine.info("Warm-up done after \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
                cont.resume()
            }
        }
    }

    nonisolated func unload() {
        queue.async { self.freeSession() }
    }

    /// Transcribes 16 kHz mono float PCM.
    /// - Parameter skipSilence: transcribe only the parts with speech (and
    ///   nothing at all when no one spoke).
    nonisolated func transcribe(_ samples: [Float], language: String?, skipSilence: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                do {
                    var audio = samples
                    if skipSilence {
                        guard let speech = self.speechOnly(samples) else {
                            Log.engine.info("No speech detected, nothing to transcribe")
                            cont.resume(returning: "")
                            return
                        }
                        audio = speech
                    }
                    cont.resume(returning: try self.run(audio, language: language))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-confined

    private nonisolated func run(_ samples: [Float], language: String?) throws -> String {
        guard let session else { throw EngineError.notLoaded }
        guard !samples.isEmpty else { return "" }
        let start = Date()
        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        let status: transcribe_status = samples.withUnsafeBufferPointer { pcm in
            if let language {
                return language.withCString { lang in
                    params.language = lang
                    return transcribe_run(session, pcm.baseAddress, Int32(pcm.count), &params)
                }
            }
            return transcribe_run(session, pcm.baseAddress, Int32(pcm.count), &params)
        }
        guard status == TRANSCRIBE_OK else {
            throw EngineError.runFailed(String(cString: transcribe_status_string(Int32(status.rawValue))))
        }
        let text = transcribe_full_text(session).map { String(cString: $0) } ?? ""
        Log.engine.info("Transcribed \(Double(samples.count) / 16_000, format: .fixed(precision: 2))s of audio in \(Date().timeIntervalSince(start) * 1000, format: .fixed(precision: 0)) ms")
        return text
    }

    /// The first run per input length compiles Metal pipelines and sizes the
    /// scheduler; do that now with quiet noise of typical lengths.
    private nonisolated func warmUp() {
        for seconds in [1.0, 3.0, 8.0] {
            let count = Int(seconds * 16_000)
            var noise = [Float](repeating: 0, count: count)
            for i in noise.indices { noise[i] = Float.random(in: -0.001...0.001) }
            _ = try? run(noise, language: nil)
        }
    }

    // MARK: - Voice activity (queue-confined)

    private nonisolated func loadVAD() {
        let name = "silero-vad-v6.2-F32"
        guard let url = Bundle.main.url(forResource: name, withExtension: "gguf")
                ?? Bundle.main.url(forResource: name, withExtension: "gguf", subdirectory: "VAD") else {
            Log.engine.error("VAD model missing from the app bundle")
            return
        }
        var model: OpaquePointer?
        guard transcribe_model_load_file(url.path, nil, &model) == TRANSCRIBE_OK, let model else {
            Log.engine.error("VAD model failed to load")
            return
        }
        var vad: OpaquePointer?
        guard transcribe_vad_session_init(model, nil, &vad) == TRANSCRIBE_OK, let vad else {
            transcribe_model_free(model)
            Log.engine.error("VAD session failed to start")
            return
        }
        vadModel = model
        vadSession = vad
    }

    /// Longest pause kept inside a dictation; longer ones are shortened.
    private static let maxPause = 0.5

    /// The speech in `samples`, with silence at the ends removed and long
    /// pauses shortened; `nil` when there is clearly no speech at all.
    /// Returns the input unchanged when the VAD is unavailable or unsure.
    private nonisolated func speechOnly(_ samples: [Float]) -> [Float]? {
        guard let vadSession, samples.count >= 512 else { return samples }
        var params = transcribe_vad_params()
        transcribe_vad_params_init(&params)
        // Lenient settings: losing a short word is worse than keeping some silence.
        params.threshold = 0.4
        params.min_speech_ms = 90
        params.min_silence_ms = 300
        params.speech_pad_ms = 200
        let status = samples.withUnsafeBufferPointer {
            transcribe_vad_run(vadSession, $0.baseAddress, Int32($0.count), &params)
        }
        guard status == TRANSCRIBE_OK else { return samples }
        var result = transcribe_vad_result()
        transcribe_vad_result_init(&result)
        guard transcribe_vad_get_result(vadSession, &result) == TRANSCRIBE_OK else { return samples }

        var segments: [Range<Int>] = []
        for i in 0..<Int(result.n_segments) {
            var segment = transcribe_vad_segment()
            transcribe_vad_segment_init(&segment)
            transcribe_vad_get_segment(vadSession, Int32(i), &segment)
            let start = max(0, min(Int(segment.start_sample), samples.count))
            let end = max(start, min(Int(segment.end_sample), samples.count))
            if end > start { segments.append(start..<end) }
        }

        let probs: [Float] = transcribe_vad_probs(vadSession).map {
            Array(UnsafeBufferPointer(start: $0, count: Int(max(0, result.n_probs))))
        } ?? []

        if segments.isEmpty {
            // Some frames looked a bit like speech: let the model decide.
            return (probs.max() ?? 0) >= 0.2 ? samples : nil
        }

        // Quiet speech scores low: grow each segment over the neighbouring
        // frames that still look a little like speech (across dips of up to
        // `bridge` frames between words), then pad it.
        let frame = 512
        let pad = 4_000 // 250 ms
        let weak: Float = 0.1
        let bridge = 10 // 320 ms
        var grown: [Range<Int>] = []
        for segment in segments {
            // `first`/`last`: frame range [first, last) known to hold speech.
            var first = min(segment.lowerBound / frame, probs.count)
            while let j = (max(0, first - bridge)..<first).first(where: { probs[$0] >= weak }) { first = j }
            var last = min((segment.upperBound + frame - 1) / frame, probs.count)
            while let j = (last..<min(probs.count, last + bridge)).last(where: { probs[$0] >= weak }) { last = j + 1 }
            let start = max(0, min(segment.lowerBound, first * frame - pad))
            let end = min(samples.count, max(segment.upperBound, last * frame + pad))
            if let previous = grown.last, start <= previous.upperBound {
                grown[grown.count - 1] = previous.lowerBound..<max(previous.upperBound, end)
            } else {
                grown.append(start..<end)
            }
        }
        segments = grown

        let maxGap = Int(Self.maxPause * 16_000)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let gap = segments[index - 1].upperBound..<segment.lowerBound
                if gap.count <= maxGap {
                    out.append(contentsOf: samples[gap])
                } else {
                    // Keep the start and end of the pause, so it still sounds like one.
                    out.append(contentsOf: samples[gap.lowerBound..<(gap.lowerBound + maxGap / 2)])
                    out.append(contentsOf: samples[(gap.upperBound - maxGap / 2)..<gap.upperBound])
                }
            }
            out.append(contentsOf: samples[segment])
        }
        Log.engine.info("Speech: \(Double(out.count) / 16_000, format: .fixed(precision: 2))s of \(Double(samples.count) / 16_000, format: .fixed(precision: 2))s")
        return out
    }

    private nonisolated func freeSession() {
        if let session { transcribe_session_free(session) }
        session = nil
        loadedPath = nil
    }
}
