import Foundation

/// How formal the inserted text looks, chosen per app (like Wispr Flow's
/// styles): only capitalization and punctuation change, never the words.
nonisolated enum DictationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// As the model wrote it.
    case asSpoken
    /// Capital letter at the start, full punctuation.
    case formal
    /// No period at the end, like a chat message.
    case casual
    /// No capitals and lighter punctuation, like texting a friend.
    case veryCasual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asSpoken: "As spoken"
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        }
    }

    static let example = "Hey Anna, are you free for lunch tomorrow? Let’s meet at noon."

    func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        switch self {
        case .asSpoken:
            return text
        case .formal:
            var out = text
            // The first letter, after any opening quote or bracket.
            if let index = out.firstIndex(where: \.isLetter), out[index].isLowercase,
               out[..<index].allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                out.replaceSubrange(index...index, with: out[index].uppercased())
            }
            // A single sentence or paragraph ends with a period (lists don't).
            if !out.contains("\n"), let last = Self.lastMeaningful(out), last.isLetter || last.isNumber {
                out.append(".")
            }
            return out
        case .casual:
            return Self.dropFinalPeriod(text)
        case .veryCasual:
            var out = ""
            var word = ""
            for character in text {
                if character.isWhitespace {
                    out += Self.lowercasedIfCapitalized(word)
                    out.append(character)
                    word = ""
                } else {
                    word.append(character)
                }
            }
            out += Self.lowercasedIfCapitalized(word)
            // Commas between words go ("3,5" stays); ? and ! stay.
            out = out.replacingOccurrences(of: ",(?=\\s)", with: "", options: .regularExpression)
            return Self.dropFinalPeriod(out)
        }
    }

    /// Closing quotes and brackets after the last word.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

    private static func lastMeaningful(_ text: String) -> Character? {
        text.last { !closers.contains($0) && !$0.isWhitespace }
    }

    /// The final "." of the text (before closing quotes or brackets) is
    /// removed; an ellipsis stays.
    private static func dropFinalPeriod(_ text: String) -> String {
        guard let index = text.lastIndex(where: { !closers.contains($0) && !$0.isWhitespace }),
              text[index] == "." else { return text }
        if index > text.startIndex, text[text.index(before: index)] == "." { return text }
        var out = text
        out.remove(at: index)
        return out
    }

    /// "Hey" → "hey", but "API", "iPhone", "macOS" and "I" stay as they are.
    private static func lowercasedIfCapitalized(_ word: String) -> String {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1, let first = letters.first, first.isUppercase,
              letters.dropFirst().allSatisfy({ !$0.isUppercase }) else { return word }
        return word.lowercased()
    }
}

/// A style chosen for one app.
nonisolated struct AppStyle: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var style: DictationStyle

    var id: String { bundleID }
}
