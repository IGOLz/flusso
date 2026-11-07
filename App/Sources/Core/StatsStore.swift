import Foundation
import Observation

/// Dictation totals for one calendar day.
nonisolated struct DayStats: Codable, Hashable, Sendable {
    var words = 0
    var transcriptions = 0
    /// Recorded audio, in seconds.
    var seconds = 0.0
}

/// Lifetime dictation statistics, kept separately from the history (which
/// only holds the last 100 transcriptions and can be cleared).
@Observable
final class StatsStore {
    static let shared = StatsStore()

    /// Keyed by local calendar day, "yyyy-MM-dd".
    private(set) var days: [String: DayStats] = [:]

    @ObservationIgnored private let writer = DispatchQueue(label: "dev.igol.flusso.stats", qos: .utility)

    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Flusso", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: DayStats].self, from: data) {
            days = decoded
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            // First launch with statistics: start from the existing history.
            for item in HistoryStore.shared.items {
                add(words: Self.wordCount(item.text), seconds: item.duration, on: item.date)
            }
            save()
        }
    }

    func record(text: String, seconds: Double, date: Date = .now) {
        add(words: Self.wordCount(text), seconds: seconds, on: date)
        save()
    }

    func reset() {
        days = [:]
        save()
    }

    /// Statistics by start of day, for `DictationStats`.
    func byDay(calendar: Calendar = .current) -> [Date: DayStats] {
        var out: [Date: DayStats] = [:]
        for (key, stats) in days {
            guard let date = Self.date(from: key) else { continue }
            out[calendar.startOfDay(for: date)] = stats
        }
        return out
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func add(words: Int, seconds: Double, on date: Date) {
        let key = Self.key(for: date)
        var day = days[key] ?? DayStats()
        day.words += words
        day.transcriptions += 1
        day.seconds += seconds
        days[key] = day
    }

    /// Keys are Gregorian dates in the local time zone, whatever calendar
    /// the user picks in System Settings.
    private static var keyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func key(for date: Date) -> String {
        let c = keyCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Midday of the key's day (never ambiguous around DST changes).
    private static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return keyCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private func save() {
        let snapshot = days
        let url = fileURL
        writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
