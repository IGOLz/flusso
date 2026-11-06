import CryptoKit
import Foundation
import Observation

/// A downloadable transcription model (GGUF for transcribe.cpp), mirroring
/// the entries in Handy's catalog.
nonisolated struct ModelInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let repository: String
    let revision: String
    let filename: String
    let sizeBytes: Int64
    let sha256: String
    let languages: String
    let isRecommended: Bool

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    static let defaultModelID = "parakeet-ultra"

    static let models: [ModelInfo] = [
        ModelInfo(
            id: "parakeet-ultra",
            name: "Parakeet Ultra",
            summary: "Il modello consigliato da Handy: massima precisione in 25 lingue europee, italiano incluso.",
            repository: "handy-computer/parakeet-ultra-gguf",
            revision: "39eeb55181f0d354fd934f06e92fd8d5037fed8e",
            filename: "parakeet-ultra-Q8_0.gguf",
            sizeBytes: 740_363_168,
            sha256: "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59",
            languages: "25 lingue · rilevamento automatico",
            isRecommended: true
        ),
        ModelInfo(
            id: "parakeet-tdt-0.6b-v3",
            name: "Parakeet V3",
            summary: "Il modello multilingue originale di NVIDIA. Veloce e preciso, leggermente meno di Ultra.",
            repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
            revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de",
            filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            sizeBytes: 739_508_576,
            sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
            languages: "25 lingue · rilevamento automatico",
            isRecommended: false
        ),
    ]

    static func model(id: String) -> ModelInfo? { models.first { $0.id == id } }
}

enum ModelState: Equatable {
    case notDownloaded
    /// `progress` in 0...1.
    case downloading(progress: Double, received: Int64, total: Int64)
    case verifying
    case downloaded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: true
        default: false
        }
    }
}

/// Downloads, verifies (SHA-256), stores and deletes models.
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var states: [String: ModelState] = [:]

    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 3
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    @ObservationIgnored private let delegate = DownloadDelegate()

    /// Called when a model becomes available on disk (after download+verify).
    @ObservationIgnored var onModelInstalled: ((ModelInfo) -> Void)?

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Flusso/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        delegate.manager = self
        refresh()
    }

    func fileURL(for model: ModelInfo) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.filename)
    }

    func isInstalled(_ model: ModelInfo) -> Bool {
        state(for: model) == .downloaded
    }

    func state(for model: ModelInfo) -> ModelState {
        states[model.id] ?? .notDownloaded
    }

    func refresh() {
        for model in ModelCatalog.models where !(states[model.id]?.isBusy ?? false) {
            let url = fileURL(for: model)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            states[model.id] = (size == model.sizeBytes) ? .downloaded : .notDownloaded
        }
    }

    func download(_ model: ModelInfo) {
        guard !state(for: model).isBusy, tasks[model.id] == nil else { return }
        Log.models.info("Downloading \(model.id) from \(model.downloadURL.absoluteString)")
        states[model.id] = .downloading(progress: 0, received: 0, total: model.sizeBytes)
        let task = session.downloadTask(with: model.downloadURL)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancelDownload(_ model: ModelInfo) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        states[model.id] = .notDownloaded
    }

    func delete(_ model: ModelInfo) {
        try? FileManager.default.removeItem(at: fileURL(for: model))
        states[model.id] = .notDownloaded
    }

    // MARK: Delegate callbacks (hopped to the main actor)

    private func isCurrent(_ id: String, task: Int) -> Bool {
        tasks[id]?.taskIdentifier == task
    }

    fileprivate func didProgress(id: String, task: Int, received: Int64, expected: Int64) {
        guard isCurrent(id, task: task), let model = ModelCatalog.model(id: id) else { return }
        let total = expected > 0 ? expected : model.sizeBytes
        states[id] = .downloading(progress: min(1, Double(received) / Double(total)), received: received, total: total)
    }

    fileprivate func didFinish(id: String, task: Int, stagedFile: URL) {
        guard isCurrent(id, task: task) else {
            try? FileManager.default.removeItem(at: stagedFile)
            return
        }
        tasks[id] = nil
        guard let model = ModelCatalog.model(id: id) else { return }
        states[id] = .verifying
        let destination = fileURL(for: model)
        Task.detached(priority: .userInitiated) {
            let result = Self.verifyAndInstall(staged: stagedFile, model: model, destination: destination)
            await MainActor.run {
                switch result {
                case .success:
                    self.states[id] = .downloaded
                    Log.models.info("Installed \(id)")
                    self.onModelInstalled?(model)
                case .failure(let error):
                    self.states[id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    fileprivate func didFail(id: String, task: Int, error: Error) {
        guard isCurrent(id, task: task) else { return } // cancelled or superseded
        tasks[id] = nil
        Log.models.error("Download \(id) failed: \(error.localizedDescription)")
        states[id] = .failed("Download non riuscito: \(error.localizedDescription)")
    }

    private nonisolated static func verifyAndInstall(staged: URL, model: ModelInfo, destination: URL) -> Result<Void, Error> {
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            let digest = try sha256(of: staged)
            guard digest == model.sha256 else {
                throw ModelError.checksumMismatch
            }
            // Write a new file and rename over the old one: the engine memory-maps models.
            let fm = FileManager.default
            let temp = destination.appendingPathExtension("partial")
            try? fm.removeItem(at: temp)
            try fm.moveItem(at: staged, to: temp)
            do {
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: destination)
                }
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum ModelError: LocalizedError {
    case checksumMismatch
    var errorDescription: String? {
        switch self {
        case .checksumMismatch: "Il file scaricato è corrotto (checksum errato). Riprova."
        }
    }
}

nonisolated private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: ModelManager?

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let task = downloadTask.taskIdentifier
        Task { @MainActor in
            self.manager?.didProgress(id: id, task: task, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let task = downloadTask.taskIdentifier
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            Task { @MainActor in self.manager?.didFail(id: id, task: task, error: error) }
            return
        }
        // The system deletes `location` when this method returns: move it first.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("flusso-\(UUID().uuidString).gguf")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor in self.manager?.didFinish(id: id, task: task, stagedFile: staged) }
        } catch {
            Task { @MainActor in self.manager?.didFail(id: id, task: task, error: error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let identifier = task.taskIdentifier
        Task { @MainActor in self.manager?.didFail(id: id, task: identifier, error: error) }
    }
}
