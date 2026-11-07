import Foundation

/// A voice shortcut: saying `trigger` inserts `text` instead (an address, a
/// link, a signature…).
nonisolated struct Snippet: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// What the user says, e.g. "my calendly link".
    var trigger: String
    /// What gets inserted, possibly several lines.
    var text: String
}

/// Expands snippets in a transcript.
///
/// The trigger matches as whole words, case-insensitively, with any spaces or
/// light punctuation the model put between its words ("my calendly, link").
/// When the dictation is only the trigger (plus the model's final period),
/// the result is exactly the snippet text.
nonisolated enum Snippets {
    /// - Parameter transform: applied to the text *around* the snippets only
    ///   (the dictionary), so an expansion is always inserted verbatim.
    static func expand(_ text: String, snippets: [Snippet],
                       transform: (String) -> String = { $0 }) -> String {
        let usable = snippets
            .map { ($0, normalizedTrigger($0.trigger)) }
            .filter { !$0.1.isEmpty && !$0.0.text.isEmpty }
            // Longest first, so "my work email" wins over "my work".
            .sorted { $0.1.joined(separator: " ").count > $1.1.joined(separator: " ").count }
        guard !usable.isEmpty, !text.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{M}\\p{N}])(?:" + usable.map { "(" + pattern(for: $0.1) + ")" }.joined(separator: "|") + ")(?![\\p{L}\\p{M}\\p{N}])",
                options: [.caseInsensitive])
        else { return transform(text) }

        let text = text.precomposedStringWithCanonicalMapping
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return transform(text) }

        func expansion(of match: NSTextCheckingResult) -> String {
            for index in usable.indices where match.range(at: index + 1).location != NSNotFound {
                return usable[index].0.text
            }
            return ns.substring(with: match.range)
        }

        // Only the trigger was said: insert the snippet as is.
        if matches.count == 1 {
            let match = matches[0]
            let before = ns.substring(to: match.range.location)
            let after = ns.substring(from: match.range.location + match.range.length)
            if isFiller(before) && isFiller(after) { return expansion(of: match) }
        }

        var out = ""
        var cursor = 0
        for match in matches {
            out += transform(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            out += expansion(of: match)
            cursor = match.range.location + match.range.length
        }
        out += transform(ns.substring(from: cursor))
        return out
    }

    /// The trigger's words, lowercased, without surrounding punctuation.
    static func normalizedTrigger(_ trigger: String) -> [String] {
        trigger.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Compares triggers the way the case-insensitive matcher does ("straße"
    /// and "STRASSE" are the same trigger).
    static func triggerKey(_ trigger: String) -> String {
        normalizedTrigger(trigger).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: nil)
    }

    private static func pattern(for words: [String]) -> String {
        words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s,.;:!?…-]+")
    }

    /// Nothing but spaces and punctuation the model adds around a phrase.
    private static func isFiller(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace || $0.isPunctuation }
    }
}
