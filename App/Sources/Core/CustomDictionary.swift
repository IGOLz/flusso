import Foundation

/// A word the user wants transcribed exactly as written (names, brands,
/// jargon). Optionally with what the model typically writes instead, for
/// words too different to be caught by fuzzy matching.
nonisolated struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// How it must be written, e.g. "Flusso", "SwiftUI", "Craciun".
    var term: String
    /// Optional: what the transcript contains instead, e.g. "suift ui".
    /// Replaced exactly (case-insensitive, whole words).
    var spokenAs: String?
}

/// Applies the user dictionary to a transcript.
///
/// Same approach as Handy's custom words: every 1–3 word window of the
/// transcript is compared to each dictionary term with a normalized
/// Levenshtein distance, boosted when the two also sound alike (Soundex);
/// the closest match under the threshold replaces the window, keeping the
/// surrounding punctuation and the capitalization of the first word.
nonisolated enum CustomDictionary {
    /// Handy's default `word_correction_threshold`.
    static let threshold = 0.18

    static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var out = applyReplacements(text, entries: entries)
        out = applyFuzzy(out, terms: entries.map(\.term))
        return out
    }

    // MARK: - Exact replacements ("spoken as" → term)

    private static func applyReplacements(_ text: String, entries: [DictionaryEntry]) -> String {
        var out = text
        // Longest first, so "open ai api" wins over "open ai".
        let pairs = entries.compactMap { entry -> (String, String)? in
            guard let spoken = entry.spokenAs?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !spoken.isEmpty else { return nil }
            return (spoken, entry.term)
        }.sorted { $0.0.count > $1.0.count }

        for (spoken, term) in pairs {
            let words = spoken.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            // Words may be separated by spaces or light punctuation in the transcript.
            let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: term)
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    // MARK: - Fuzzy matching

    /// A dictionary term, normalized once per call.
    private struct Key {
        let termIndex: Int
        let chars: [Character]
        let soundex: String?
    }

    /// A non-whitespace run of the transcript, with its range in the original.
    private struct Token {
        let range: Range<String.Index>
        let text: Substring
        let key: String
    }

    /// Phonetic similarity may only rescue near misses: above this raw
    /// edit ratio ("pane" vs "Pino" = 0.5) words count as different.
    static let maxPhoneticRatio = 0.34

    private static func applyFuzzy(_ text: String, terms: [String]) -> String {
        var keys: [Key] = []
        for (index, term) in terms.enumerated() {
            var variants = [matchKey(term)]
            if term.contains("&") { variants.append(matchKey(term.replacingOccurrences(of: "&", with: " and "))) }
            for key in Set(variants) where isSupported(key) {
                keys.append(Key(termIndex: index, chars: Array(key), soundex: isAlphabetic(key) ? soundex(key) : nil))
            }
        }
        guard !keys.isEmpty else { return text }

        var tokens: [Token] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let start = text[cursor...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let word = text[start..<end]
            tokens.append(Token(range: start..<end, text: word, key: matchKey(String(word))))
            cursor = end
        }

        var edits: [(Range<String.Index>, String)] = []
        var i = 0
        while i < tokens.count {
            var best: (n: Int, termIndex: Int, score: Double)?
            for n in stride(from: 3, through: 1, by: -1) where i + n <= tokens.count {
                let window = tokens[i..<(i + n)]
                // Don't merge across punctuation ("Charge B, che").
                if window.dropLast().contains(where: { !punctuation(String($0.text)).suffix.isEmpty }) { continue }
                let candidate = Array(window.map(\.key).joined())
                guard let (termIndex, matchScore) = bestMatch(candidate, keys: keys),
                      best == nil || matchScore < best!.score else { continue }
                // An extra leading/trailing word ("a ChatGPT") must not be
                // swallowed: skip the window if it matches as well without it.
                if n > 1 {
                    let termKeys = keys.filter { $0.termIndex == termIndex }
                    let withoutFirst = Array(window.dropFirst().map(\.key).joined())
                    let withoutLast = Array(window.dropLast().map(\.key).joined())
                    if termKeys.contains(where: { score(withoutFirst, $0) <= matchScore || score(withoutLast, $0) <= matchScore }) {
                        continue
                    }
                }
                best = (n, termIndex, matchScore)
            }
            guard let best else {
                i += 1
                continue
            }
            let first = tokens[i], last = tokens[i + best.n - 1]
            let term = terms[best.termIndex]
            let original = text[first.range.lowerBound..<last.range.upperBound]
            if original != term {
                let replacement = rebuild(term: term, firstWord: String(first.text), lastWord: String(last.text))
                if replacement != original {
                    edits.append((first.range.lowerBound..<last.range.upperBound, replacement))
                }
            }
            i += best.n
        }

        guard !edits.isEmpty else { return text }
        var out = text
        for (range, replacement) in edits.reversed() {
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    /// The term with the window's surrounding punctuation and capitalization.
    /// Punctuation that belongs to the term itself ("C++", ".NET") is not
    /// duplicated.
    private static func rebuild(term: String, firstWord: String, lastWord: String) -> String {
        var prefix = punctuation(firstWord).prefix
        var suffix = punctuation(lastWord).suffix
        let termPunctuation = punctuation(term)
        if !termPunctuation.prefix.isEmpty, prefix.hasSuffix(termPunctuation.prefix) {
            prefix.removeLast(termPunctuation.prefix.count)
        }
        if !termPunctuation.suffix.isEmpty, suffix.hasPrefix(termPunctuation.suffix) {
            suffix.removeFirst(termPunctuation.suffix.count)
        }
        return prefix + preserveCase(of: firstWord, in: term) + suffix
    }

    private static func bestMatch(_ candidate: [Character], keys: [Key]) -> (Int, Double)? {
        guard !candidate.isEmpty, candidate.count <= 50,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let candidateSoundex = candidate.allSatisfy(\.isLetter) ? soundex(String(candidate)) : nil
        var best: (Int, Double)?
        for key in keys {
            let s = score(candidate, key, candidateSoundex: candidateSoundex)
            if s < threshold, best == nil || s < best!.1 {
                best = (key.termIndex, s)
            }
        }
        return best
    }

    /// 0 = identical; lower is closer; `.infinity` when clearly different.
    private static func score(_ candidate: [Character], _ key: Key, candidateSoundex: String? = nil) -> Double {
        guard !candidate.isEmpty else { return .infinity }
        let maxLen = max(candidate.count, key.chars.count)
        let lenDiff = abs(candidate.count - key.chars.count)
        if Double(lenDiff) > max(Double(maxLen) * 0.25, 2) { return .infinity }
        // Nothing above this many edits can pass, even with the phonetic boost.
        let maxEdits = Int(Double(maxLen) * maxPhoneticRatio)
        guard let distance = levenshtein(candidate, key.chars, limit: maxEdits) else { return .infinity }
        var s = Double(distance) / Double(maxLen)
        let phonetic = candidateSoundex ?? (candidate.allSatisfy(\.isLetter) ? soundex(String(candidate)) : nil)
        if let phonetic, let keySoundex = key.soundex, phonetic == keySoundex {
            s *= 0.3 // sounds alike: strong boost
        }
        return s
    }

    // MARK: - Helpers

    /// Lowercased letters and digits only, diacritics folded ("Perché" → "perche").
    private static func matchKey(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }

    private static func isSupported(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isAlphabetic(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func punctuation(_ word: String) -> (prefix: String, suffix: String) {
        let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let first = word.firstIndex(where: isWordChar),
              let last = word.lastIndex(where: isWordChar) else { return (word, "") }
        return (String(word[..<first]), String(word[word.index(after: last)...]))
    }

    private static func preserveCase(of original: String, in replacement: String) -> String {
        let letters = original.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return replacement.uppercased() }
        // Only capitalize (never lowercase) the user's spelling: "iPhone" stays "iPhone".
        if let first = original.first(where: \.isLetter), first.isUppercase,
           let r = replacement.first, r.isLowercase {
            return r.uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Edit distance, or nil as soon as it must exceed `limit`.
    private static func levenshtein(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        if a.isEmpty { return b.count <= limit ? b.count : nil }
        if b.isEmpty { return a.count <= limit ? a.count : nil }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return nil }
            swap(&previous, &current)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }

    /// American Soundex (letter + 3 digits).
    static func soundex(_ word: String) -> String {
        let letters = Array(word.uppercased().filter { $0.isASCII && $0.isLetter })
        guard let first = letters.first else { return "" }
        func code(_ c: Character) -> Character? {
            switch c {
            case "B", "F", "P", "V": "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": "2"
            case "D", "T": "3"
            case "L": "4"
            case "M", "N": "5"
            case "R": "6"
            default: nil // vowels, H, W, Y
            }
        }
        var result = String(first)
        var last = code(first)
        for c in letters.dropFirst() {
            let digit = code(c)
            if let digit, digit != last { result.append(digit) }
            // H and W don't separate equal codes; vowels do.
            if c != "H" && c != "W" { last = digit }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
