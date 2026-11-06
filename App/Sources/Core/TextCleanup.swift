import Foundation

/// Light post-processing of the raw transcript.
enum TextCleanup {
    /// Hesitation sounds that are not words in any supported language
    /// (same universal list Handy uses).
    private static let fillers = ["uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm", "mm"]

    private static let fillerRegex: NSRegularExpression = {
        let alternatives = fillers.joined(separator: "|")
        // The filler, optional trailing punctuation, and following spaces.
        return try! NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])(\(alternatives))(?![\\p{L}\\p{N}])[,.…]*\\s*")
    }()

    static func clean(_ text: String, removeFillers: Bool) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return "" }

        if removeFillers {
            let startsUpper = out.first?.isUppercase ?? false
            let range = NSRange(out.startIndex..., in: out)
            out = fillerRegex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            out = out.replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Removing a leading filler leaves a lowercase start.
            if startsUpper, let first = out.first, first.isLowercase {
                out = first.uppercased() + out.dropFirst()
            }
        }

        // A lone punctuation mark (e.g. ".") is not worth pasting.
        if out.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return "" }
        return out
    }
}
