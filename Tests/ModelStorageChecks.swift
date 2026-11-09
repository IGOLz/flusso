// xcrun swiftc -default-isolation MainActor App/Sources/Core/{ModelStorage,ModelManager,Log}.swift Tests/ModelStorageChecks.swift -o build/model-storage-checks
import Foundation

@main
struct ModelStorageChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flusso-storage-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try ModelStorage.prepare(source, create: true)
        try ModelStorage.prepare(destination, create: true)
        let bytes = Data("model contents".utf8)
        let original = source.appendingPathComponent("speech.gguf")
        try bytes.write(to: original)
        let originals = try ModelStorage.copyModels(from: source, to: destination,
                                                   filenames: ["speech.gguf", "missing.gguf"])
        assert(originals == [original])
        assert(tryData(original) == bytes, "Original must survive until the preference is committed")
        assert(tryData(destination.appendingPathComponent("speech.gguf")) == bytes)

        // A collision must preserve both existing files and leave no partial copies.
        try bytes.write(to: source.appendingPathComponent("format.gguf"))
        let existing = Data("existing destination".utf8)
        try existing.write(to: destination.appendingPathComponent("speech.gguf"))
        do {
            _ = try ModelStorage.copyModels(from: source, to: destination,
                                            filenames: ["format.gguf", "speech.gguf"])
            fatalError("Expected a collision")
        } catch {
            assert(tryData(destination.appendingPathComponent("speech.gguf")) == existing)
            assert(!fm.fileExists(atPath: destination.appendingPathComponent("format.gguf").path))
            assert(tryData(original) == bytes)
            let remaining = try fm.contentsOfDirectory(atPath: destination.path)
            assert(remaining == ["speech.gguf"])
        }

        // An offline/missing selected folder must never be recreated.
        let offline = root.appendingPathComponent("offline/Models")
        do {
            try ModelStorage.prepare(offline)
            fatalError("Expected missing directory error")
        } catch { assert(!fm.fileExists(atPath: offline.path)) }

        let empty = root.appendingPathComponent("empty")
        try ModelStorage.prepare(empty, create: true)
        let absent = root.appendingPathComponent("absent")
        let moved = try ModelStorage.copyModels(from: absent, to: empty, filenames: ["speech.gguf"])
        assert(moved.isEmpty, "First-run folder selection must work before any download")
        // Exercise the real manager without touching Flusso's preference domain.
        let defaults = UserDefaults.standard
        let keys = ["modelsDirectoryPath", "modelsDirectoryBookmark"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(source.path, forKey: keys[0])
        defaults.removeObject(forKey: keys[1])
        let manager = ModelManager.shared
        assert(manager.modelsDirectory.path == source.path)
        let model = ModelCatalog.models[0]
        let modelFile = source.appendingPathComponent(model.filename)
        try bytes.write(to: modelFile)
        var notified = false
        manager.onDirectoryChanged = { notified = true }
        try await manager.changeDirectory(to: empty)
        assert(!manager.isStorageBusy && notified)
        assert(manager.modelsDirectory.path == empty.resolvingSymlinksInPath().path)
        assert(tryData(manager.fileURL(for: model)) == bytes)
        assert(!fm.fileExists(atPath: modelFile.path))
        assert(defaults.string(forKey: keys[0]) == manager.modelsDirectory.path)
        let bookmark = defaults.data(forKey: keys[1])!
        var stale = false
        let restored = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        assert(restored.resolvingSymlinksInPath().path == manager.modelsDirectory.resolvingSymlinksInPath().path)

        // A failed switch must keep the preference and installed files in place.
        try bytes.write(to: destination.appendingPathComponent(model.filename))
        do {
            try await manager.changeDirectory(to: destination)
            fatalError("Expected a collision")
        } catch {
            assert(manager.modelsDirectory.path == empty.resolvingSymlinksInPath().path)
            assert(defaults.data(forKey: keys[1]) == bookmark)
            assert(!manager.isStorageBusy)
            assert(tryData(manager.fileURL(for: model)) == bytes)
        }
        try fm.removeItem(at: empty)
        manager.download(model)
        guard case .failed = manager.state(for: model) else {
            fatalError("An unavailable folder must reject downloads")
        }
        assert(!fm.fileExists(atPath: empty.path))
        print("Model storage checks passed")
    }

    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
