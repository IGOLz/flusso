import CryptoKit
import Foundation
import Observation

/// A downloadable model: a transcription model (GGUF for transcribe.cpp,
/// mirroring Handy's catalog) or the local formatting model (llama.cpp).
nonisolated struct ModelInfo: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case transcription, formatting }

    let id: String
    var kind: Kind = .transcription
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
        sizeBytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US")))
    }
}

enum ModelCatalog {
    static let defaultModelID = "parakeet-ultra"

    static let models: [ModelInfo] = [
        ModelInfo(
            id: "parakeet-ultra",
            name: "Parakeet Ultra",
            summary: "Handy's recommended model: top accuracy across 25 European languages.",
            repository: "handy-computer/parakeet-ultra-gguf",
            revision: "39eeb55181f0d354fd934f06e92fd8d5037fed8e",
            filename: "parakeet-ultra-Q8_0.gguf",
            sizeBytes: 740_363_168,
            sha256: "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59",
            languages: "25 languages · automatic detection",
            isRecommended: true
        ),
        ModelInfo(
            id: "parakeet-tdt-0.6b-v3",
            name: "Parakeet V3",
            summary: "NVIDIA's original multilingual model. Fast and accurate, slightly behind Ultra.",
            repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
            revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de",
            filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            sizeBytes: 739_508_576,
            sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
            languages: "25 languages · automatic detection",
            isRecommended: false
        ),
    ]

    /// Smart formatting's local model (see `LocalFormatter`).
    static let formattingModel = ModelInfo(
        id: "gemma-4-e4b",
        kind: .formatting,
        name: "Gemma 4 E4B",
        summary: "Google's open model, run on this Mac by llama.cpp.",
        repository: "unsloth/gemma-4-E4B-it-GGUF",
        revision: "bfc15c382204943c3a8fff0c750b94ae2364d7a3",
        filename: "gemma-4-E4B-it-Q4_K_M.gguf",
        sizeBytes: 4_977_171_584,
        sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
        languages: "140 languages",
        isRecommended: false
    )

    /// Every downloadable model; `models` lists the transcription ones.
    static var all: [ModelInfo] { models + [formattingModel] }

    static func model(id: String) -> ModelInfo? { all.first { $0.id == id } }
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
    @ObservationIgnored var onDirectoryChanged: (() -> Void)?

    private(set) var modelsDirectory: URL = ModelStorage.defaultDirectory
    private(set) var isMovingModels = false

    var isStorageBusy: Bool { isMovingModels || states.values.contains(where: \.isBusy) }

    func changeDirectory(to directory: URL) async throws {
        guard !isStorageBusy else { throw ModelError.storageBusy }
        let destination = directory.resolvingSymlinksInPath().standardizedFileURL
        guard destination.path != modelsDirectory.resolvingSymlinksInPath().standardizedFileURL.path else { return }
        let bookmark = try destination.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let source = modelsDirectory
        let filenames = ModelCatalog.all.map(\.filename)
        isMovingModels = true
        defer { isMovingModels = false }
        let originals = try await Task.detached(priority: .userInitiated) {
            try ModelStorage.copyModels(from: source, to: destination, filenames: filenames)
        }.value
        UserDefaults.standard.set(bookmark, forKey: "modelsDirectoryBookmark")
        UserDefaults.standard.set(destination.path, forKey: "modelsDirectoryPath")
        modelsDirectory = destination
        for url in originals { try? FileManager.default.removeItem(at: url) }
        refresh()
        onDirectoryChanged?()
    }

    private init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "modelsDirectoryPath") {
            modelsDirectory = URL(fileURLWithPath: path, isDirectory: true)
            if let data = defaults.data(forKey: "modelsDirectoryBookmark") {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                           relativeTo: nil, bookmarkDataIsStale: &stale) {
                    modelsDirectory = resolved
                    defaults.set(resolved.path, forKey: "modelsDirectoryPath")
                    if stale, let updated = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        defaults.set(updated, forKey: "modelsDirectoryBookmark")
                    }
                }
            }
        }
        delegate.manager = self
        refresh()
    }

    func fileURL(for model: ModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    func isInstalled(_ model: ModelInfo) -> Bool {
        state(for: model) == .downloaded
    }

    func state(for model: ModelInfo) -> ModelState {
        states[model.id] ?? .notDownloaded
    }

    func refresh() {
        for model in ModelCatalog.all where !(states[model.id]?.isBusy ?? false) {
            let url = fileURL(for: model)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            states[model.id] = (size == model.sizeBytes) ? .downloaded : .notDownloaded
        }
    }

    func download(_ model: ModelInfo) {
        guard !isMovingModels, !state(for: model).isBusy, tasks[model.id] == nil else { return }
        do {
            try ModelStorage.prepare(modelsDirectory, create: UserDefaults.standard.string(forKey: "modelsDirectoryPath") == nil)
        } catch {
            states[model.id] = .failed("Model folder unavailable. Connect the disk or choose another folder in Settings › Models. \(error.localizedDescription)")
            return
        }
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
        guard !isMovingModels else { return }
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
        states[id] = .failed("Download failed: \(error.localizedDescription)")
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
    case storageBusy
    var errorDescription: String? {
        switch self {
        case .storageBusy: "Wait for model downloads and transfers to finish before changing the folder."
        case .checksumMismatch: "The downloaded file is corrupted (checksum mismatch). Try again."
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
