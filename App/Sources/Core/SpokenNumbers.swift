import Foundation
import NaturalLanguage

/// Always-on number formatting, independent of the optional language models.
/// Cardinal numbers in Italian and English; articles and ordinal words stay words.
enum SpokenNumbers {
    private struct Token {
        let word: String
        let range: Range<String.Index>
    }

    private enum Language: String {
        case italian = "it", english = "en"

        var decimal: String { self == .italian ? "," : "." }
        var point: String { self == .italian ? "virgola" : "point" }
        var minus: String { self == .italian ? "meno" : "minus" }
        var and: String { self == .italian ? "e" : "and" }
    }

    private static let tokens = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+")
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // ICU's Italian spellings contain soft hyphens, which its parser requires
    // even though speech models write ordinary joined words such as ventitré.
    private static let italian: [String: Int64] = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.numberStyle = .spellOut
        return Dictionary((0..<1000).map {
            (key(formatter.string(from: NSNumber(value: $0))!), Int64($0))
        }, uniquingKeysWith: { first, _ in first })
    }()

    private static let english: [String: Int64] = {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                     "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        var words = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($0.element, Int64($0.offset)) })
        for (i, word) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
            words[word] = Int64((i + 2) * 10)
        }
        return words
    }()

    static func normalize(_ text: String) -> String {
        let all = tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Token(word: key(String(text[range])), range: range)
        }
        let protected = links.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.italian, range: text.startIndex..<text.endIndex)
        var output = "", cursor = text.startIndex, i = 0
        while i < all.count {
            let token = all[i]
            guard !protected.contains(where: { $0.overlaps(token.range) }) else { i += 1; continue }
            var best: (end: Int, text: String)?
            for language in [Language.italian, .english] {
                if language == .italian, token.word == "sei", isVerb(i, in: all, tagger: tagger) { continue }
                if language == .italian, token.word == "uno", i + 1 < all.count,
                   value(all[i + 1].word, language: .italian) == nil,
                   tagger.tag(at: token.range.lowerBound, unit: .word, scheme: .lexicalClass).0 == .determiner { continue }
                if let number = parse(all, from: i, in: text, language: language),
                   best == nil || number.end > best!.end {
                    best = number
                }
            }
            guard let best, !protected.contains(where: { $0.overlaps(token.range.lowerBound..<all[best.end - 1].range.upperBound) }) else {
                i += 1
                continue
            }
            let end = all[best.end - 1].range.upperBound
            output += text[cursor..<token.range.lowerBound] + best.text
            cursor = end
            i = best.end
        }
        return output + text[cursor...]
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
            .replacingOccurrences(of: "\u{00AD}", with: "")
    }

    private static func value(_ word: String, language: Language) -> Int64? {
        if word.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int64(word) }
        if language == .english { return english[word] }
        if let value = italian[word] { return value }
        if word.hasPrefix("mille") {
            let rest = String(word.dropFirst(5))
            if let rest = italian[rest], rest > 0 { return 1000 + rest }
        }
        if let range = word.range(of: "mila"),
           let count = italian[String(word[..<range.lowerBound])] ?? italian[String(word[..<range.lowerBound]) + "o"], count >= 2 {
            let rest = String(word[range.upperBound...])
            if rest.isEmpty { return count * 1000 }
            if let rest = italian[rest], rest > 0 { return count * 1000 + rest }
        }
        return nil
    }

    private static func scale(_ word: String, language: Language) -> Int64? {
        switch (language, word) {
        case (.italian, "mille"), (.italian, "mila"), (.english, "thousand"): 1000
        case (.italian, "milione"), (.italian, "milioni"), (.english, "million"): 1_000_000
        case (.italian, "miliardo"), (.italian, "miliardi"), (.english, "billion"): 1_000_000_000
        default: nil
        }
    }

    private static func parse(_ tokens: [Token], from start: Int, in text: String, language: Language, allowDecimal: Bool = true) -> (end: Int, text: String)? {
        var i = start, total: Int64 = 0, group: Int64 = 0
        var lastScale = Int64.max, hasNumber = false, negative = false
        func connected(_ index: Int) -> Bool {
            guard index > start else { return true }
            let gap = text[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]
            return !gap.isEmpty && (gap.allSatisfy { $0 == " " || $0 == "\t" } || (language == .english && gap == "-"))
        }
        if tokens[i].word == language.minus { negative = true; i += 1 }
        while i < tokens.count, connected(i) {
            let word = tokens[i].word
            if word == language.and, (group >= 100 && group % 100 == 0 || total > 0 && group == 0),
               i + 1 < tokens.count, connected(i + 1),
               let next = value(tokens[i + 1].word, language: language), next > 0, next < 100 {
                i += 1
                continue
            }
            if language == .english, word == "hundred", group < 10, group > 0 || !hasNumber {
                group = max(1, group) * 100
            } else if let multiplier = scale(word, language: language), multiplier < lastScale, group < multiplier {
                let product = max(1, group).multipliedReportingOverflow(by: multiplier)
                let sum = total.addingReportingOverflow(product.partialValue)
                guard !product.overflow, !sum.overflow else { break }
                total = sum.partialValue
                group = 0
                lastScale = multiplier
            } else if language == .italian, word == "un", !hasNumber, i + 1 < tokens.count,
                      scale(tokens[i + 1].word, language: language) != nil {
                group = 1
            } else if language == .english, word == "a", !hasNumber, i + 1 < tokens.count,
                      tokens[i + 1].word == "hundred" || scale(tokens[i + 1].word, language: language) != nil {
                group = 1
            } else if let next = value(word, language: language) {
                if hasNumber, word.allSatisfy(\.isNumber), tokens[i - 1].word.allSatisfy(\.isNumber) { break }
                if !hasNumber || (group == 0 && total > 0 && next < lastScale) {
                    group = next
                } else if group >= 1000, group % 1000 == 0, next > 0, next < 1000 {
                    group += next
                } else if group >= 100, group % 100 == 0, next > 0, next < 100 {
                    group += next
                } else if group >= 20, group % 10 == 0, next > 0, next < 10 {
                    group += next
                } else { break }
            } else { break }
            hasNumber = true
            i += 1
        }
        guard hasNumber else { return nil }
        let sum = total.addingReportingOverflow(group)
        guard !sum.overflow else { return nil }
        var result = String(sum.partialValue)
        // Keep existing digit strings such as phone numbers with leading zeros.
        if i == start + 1, tokens[start].word.allSatisfy(\.isNumber) { result = tokens[start].word }
        if allowDecimal, i < tokens.count, connected(i), tokens[i].word == language.point {
            var j = i + 1, fraction = ""
            while j < tokens.count, connected(j), value(tokens[j].word, language: language) != nil,
                  let part = parse(tokens, from: j, in: text, language: language, allowDecimal: false) {
                fraction += part.text
                j = part.end
            }
            if !fraction.isEmpty { result += language.decimal + fraction; i = j }
        }
        return (i, (negative ? "-" : "") + result)
    }

    private static func isVerb(_ i: Int, in tokens: [Token], tagger: NLTagger) -> Bool {
        // shortcut: "sei" is ambiguous in Italian. Use local grammar tagging,
        // with explicit numeric contexts; richer ambiguity needs semantic analysis.
        if tokens.count == 1 { return false }
        let previous = i > 0 ? tokens[i - 1].word : ""
        let next = i + 1 < tokens.count ? tokens[i + 1].word : ""
        if ["e", "o"].contains(previous), i >= 2, value(tokens[i - 2].word, language: .italian) != nil { return false }
        if ["numero", "numeri", "le", "alle", "dalle", "ai", "dai", "voglio", "sono", "erano"].contains(previous) { return false }
        if ["euro", "dollari", "centesimi", "chilometri", "metri", "centimetri", "millimetri", "chili", "grammi",
            "litri", "ore", "minuti", "secondi", "giorni", "settimane", "mesi", "anni", "percento", "virgola"].contains(next) { return false }
        return tagger.tag(at: tokens[i].range.lowerBound, unit: .word, scheme: .lexicalClass).0 == .verb
    }
}
