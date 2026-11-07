import AppKit
import Foundation
import Observation

struct HistoryItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var date: Date
    /// `false` when the text could not be pasted anywhere (no focused field).
    var wasPasted: Bool
    var appName: String?
    /// Recorded audio length in seconds.
    var duration: Double
    /// The recording, in `HistoryAudio.directory` (nil when not kept).
    var audioFile: String?
}

/// The most recent transcriptions, kept on disk so nothing dictated is lost.
@Observable
final class HistoryStore {
    static let shared = HistoryStore()
    static let limit = 100

    private(set) var items: [HistoryItem] = []

    /// Serial writer: snapshots are written in the order they were taken.
    @ObservationIgnored private let writer = DispatchQueue(label: "dev.igol.flusso.history", qos: .utility)

    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Flusso", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
        removeOrphanedAudio()
    }

    /// Adds a transcription; `audio` (16 kHz mono) is kept with it when given.
    func add(_ item: HistoryItem, audio: [Float]? = nil) {
        if let audio, !audio.isEmpty {
            let id = item.id
            let fileName = "\(id.uuidString).wav"
            // The item shows its recording only once the file is on disk.
            writer.async {
                do {
                    try HistoryAudio.write(audio, to: HistoryAudio.url(for: fileName))
                } catch {
                    Log.app.error("Couldn't save the recording: \(error.localizedDescription)")
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HistoryStore.shared.attachAudio(fileName, to: id) }
                }
            }
        }
        items.insert(item, at: 0)
        if items.count > Self.limit {
            deleteAudio(of: Array(items[Self.limit...]))
            items.removeLast(items.count - Self.limit)
        }
        save()
    }

    func delete(_ item: HistoryItem) {
        deleteAudio(of: items.filter { $0.id == item.id })
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        deleteAudio(of: items)
        items.removeAll()
        save()
    }

    private func attachAudio(_ fileName: String, to id: HistoryItem.ID) {
        guard AppSettings.shared.keepAudio, let index = items.firstIndex(where: { $0.id == id }) else {
            // Deleted (or recordings turned off) while the file was written.
            writer.async { HistoryAudio.delete(fileName) }
            return
        }
        items[index].audioFile = fileName
        save()
    }

    /// Replaces the text of a transcription (transcribed again).
    func updateText(of id: HistoryItem.ID, to text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
        save()
    }

    /// Deletes every kept recording (the transcriptions stay).
    func deleteAllAudio() {
        deleteAudio(of: items)
        for index in items.indices { items[index].audioFile = nil }
        save()
        writer.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: HistoryAudio.directory, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    var hasAudio: Bool { items.contains { $0.audioFile != nil } }

    /// Removed on the writer queue, after any pending write of the same file.
    private func deleteAudio(of removed: [HistoryItem]) {
        let names = removed.compactMap(\.audioFile)
        guard !names.isEmpty else { return }
        writer.async { names.forEach(HistoryAudio.delete) }
    }

    /// Recordings left behind by a crash or an older version.
    private func removeOrphanedAudio() {
        let kept = Set(items.compactMap(\.audioFile))
        writer.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: HistoryAudio.directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func copy(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    /// Total words dictated (for the home screen).
    var totalWords: Int {
        items.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private func save() {
        let snapshot = items
        let url = fileURL
        writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
