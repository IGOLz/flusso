import Foundation

nonisolated enum EngineError: LocalizedError {
    case loadFailed(String)
    case notLoaded
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let s): "Impossibile caricare il modello (\(s))."
        case .notLoaded: "Nessun modello caricato."
        case .runFailed(let s): "Trascrizione non riuscita (\(s))."
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

    nonisolated init() {
        queue.async {
            // Drop library/ggml chatter except errors.
            transcribe_log_set({ level, message, _ in
                guard level == TRANSCRIBE_LOG_LEVEL_ERROR, let message else { return }
                Log.engine.error("\(String(cString: message), privacy: .public)")
            }, nil)
            _ = transcribe_init_backends_default()
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
    nonisolated func transcribe(_ samples: [Float], language: String?) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try self.run(samples, language: language))
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

    private nonisolated func freeSession() {
        if let session { transcribe_session_free(session) }
        session = nil
        loadedPath = nil
    }
}
