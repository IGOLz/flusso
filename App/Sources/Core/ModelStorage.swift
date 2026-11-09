import Foundation

nonisolated enum ModelStorage {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flusso/Models", isDirectory: true)
    }

    static func prepare(_ directory: URL, create: Bool = false) throws {
        let fm = FileManager.default
        if create { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let probe = directory.appendingPathComponent(".flusso-write-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try fm.removeItem(at: probe)
    }

    /// Copy first, commit the preference later, and only then remove the originals.
    static func copyModels(from source: URL, to destination: URL, filenames: [String]) throws -> [URL] {
        let fm = FileManager.default
        try prepare(destination)
        let staging = destination.appendingPathComponent(".flusso-transfer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var installed: [URL] = []
        var originals: [URL] = []
        do {
            for filename in filenames {
                let original = source.appendingPathComponent(filename)
                guard fm.fileExists(atPath: original.path) else { continue }
                let target = destination.appendingPathComponent(filename)
                guard !fm.fileExists(atPath: target.path) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
                }
                try fm.copyItem(at: original, to: staging.appendingPathComponent(filename))
                originals.append(original)
            }
            for original in originals {
                let target = destination.appendingPathComponent(original.lastPathComponent)
                try fm.moveItem(at: staging.appendingPathComponent(original.lastPathComponent), to: target)
                installed.append(target)
            }
            return originals
        } catch {
            for url in installed { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
