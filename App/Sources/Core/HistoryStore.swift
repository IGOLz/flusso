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
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
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
