import AppKit
import ApplicationServices

/// A word the user corrected by hand after a dictation, to offer for the
/// dictionary.
struct LearnedWord: Equatable {
    /// How the user wrote it, e.g. "SwiftUI".
    let term: String
    /// What the model wrote, when fuzzy matching alone wouldn't fix it next
    /// time (e.g. "swift you eye"); nil otherwise.
    let spokenAs: String?
}

/// After a dictation is inserted into a text field, watches that field for a
/// minute: when the user replaces a word or two of the dictated text (a name
/// the model got wrong), `onCorrection` offers it for the dictionary, like
/// Wispr Flow.
///
/// Reads the field's text through Accessibility only; nothing is stored.
final class CorrectionWatcher {
    var onCorrection: ((LearnedWord) -> Void)?

    private static let pollInterval: Duration = .milliseconds(1500)
    private static let watchDuration: TimeInterval = 60
    /// Text around the dictation used to find it again after edits.
    private static let anchorLength = 24
    /// Fields longer than this aren't read again and again.
    nonisolated private static let maxFieldLength = 100_000

    private var task: Task<Void, Never>?

    /// Starts watching `element`, where `text` was just inserted.
    func watch(_ element: AXUIElement, inserted text: String) {
        stop()
        let dictated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.words(dictated).isEmpty else { return }
        let field = Field(element: element)
        task = Task { [weak self] in
            await self?.run(field, dictated: dictated)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run(_ field: Field, dictated: String) async {
        // Let the paste land.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let first = await field.read(withCursor: true),
              let anchors = Self.anchors(of: dictated, in: first.value, cursor: first.cursor),
              // The anchors must lead back to exactly the dictation.
              Self.region(in: first.value, anchors: anchors) == dictated else { return }

        let deadline = Date().addingTimeInterval(Self.watchDuration)
        var previous: String?
        while Date() < deadline {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            guard let value = await field.read(withCursor: false)?.value else { return }
            guard !Task.isCancelled else { return }
            guard let region = Self.region(in: value, anchors: anchors) else { continue }
            // Wait until the edit is finished (unchanged for one interval).
            let stable = region == previous
            previous = region
            guard stable, region != dictated else { continue }
            if let word = Self.correction(from: dictated, to: region, openEnded: anchors.after.isEmpty) {
                onCorrection?(word)
                return
            }
        }
    }

    /// The watched text field. AX calls block until the other app answers
    /// (up to the timeout), so they run off the main thread.
    nonisolated private struct Field: @unchecked Sendable {
        let element: AXUIElement

        init(element: AXUIElement) {
            AXUIElementSetMessagingTimeout(element, 0.2)
            self.element = element
        }

        func read(withCursor: Bool) async -> (value: String, cursor: Int?)? {
            await Task.detached(priority: .utility) { () -> (value: String, cursor: Int?)? in
                guard !CorrectionWatcher.isSecure(element),
                      let length = CorrectionWatcher.characterCount(of: element), length <= CorrectionWatcher.maxFieldLength,
                      let value = CorrectionWatcher.value(of: element) else { return nil }
                return (value, withCursor ? CorrectionWatcher.cursor(of: element) : nil)
            }.value
        }
    }

    // MARK: - Finding the dictation again

    private struct Anchors {
        let before: String
        let after: String
        /// Where the dictation started (UTF-16 offset), to search nearby.
        let location: Int
        let length: Int
    }

    private static func anchors(of dictated: String, in value: String, cursor: Int?) -> Anchors? {
        let ns = value as NSString
        guard ns.length <= maxFieldLength else { return nil }
        // The occurrence ending closest before the cursor (where it was pasted).
        let limit = min(cursor.map { $0 } ?? ns.length, ns.length)
        let found = ns.range(of: dictated, options: .backwards, range: NSRange(location: 0, length: limit))
        let range = found.location != NSNotFound ? found : ns.range(of: dictated, options: .backwards)
        guard range.location != NSNotFound else { return nil }
        let beforeStart = max(0, range.location - anchorLength)
        let afterEnd = min(ns.length, range.location + range.length + anchorLength)
        return Anchors(
            before: ns.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
            after: ns.substring(with: NSRange(location: range.location + range.length,
                                              length: afterEnd - range.location - range.length)),
            location: range.location, length: range.length)
    }

    /// The text now between the anchors, or nil if they can't be found.
    private static func region(in value: String, anchors: Anchors) -> String? {
        let ns = value as NSString
        guard ns.length <= maxFieldLength else { return nil }
        let beforeLength = (anchors.before as NSString).length

        var start = 0
        if beforeLength > 0 {
            // The occurrence of the leading anchor closest to where the
            // dictation was (text may have been added or removed above it).
            let expected = anchors.location - beforeLength
            let windowStart = max(0, expected - 2_000)
            let windowEnd = min(ns.length, expected + beforeLength + 2_000)
            guard windowEnd > windowStart else { return nil }
            var best: NSRange?
            var searchStart = windowStart
            while searchStart < windowEnd {
                let r = ns.range(of: anchors.before, options: [],
                                 range: NSRange(location: searchStart, length: windowEnd - searchStart))
                guard r.location != NSNotFound else { break }
                if best == nil || abs(r.location - expected) < abs(best!.location - expected) { best = r }
                searchStart = r.location + 1
            }
            guard let best else { return nil }
            start = best.location + best.length
        } else if anchors.location != 0 {
            return nil
        }
        // At most a few words longer than the dictation.
        let maxEnd = min(ns.length, start + anchors.length + 200)
        guard maxEnd >= start else { return nil }
        var end = maxEnd
        if !anchors.after.isEmpty {
            let r = ns.range(of: anchors.after, options: [], range: NSRange(location: start, length: maxEnd - start))
            guard r.location != NSNotFound else { return nil }
            end = r.location
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Spotting a correction

    /// A short replacement inside otherwise unchanged text, or nil.
    /// - Parameter openEnded: the dictation ended the field, so text typed
    ///   after it shows up at the end of `edited`.
    static func correction(from dictated: String, to edited: String, openEnded: Bool = false) -> LearnedWord? {
        let old = words(dictated), new = words(edited)
        guard !old.isEmpty, !new.isEmpty else { return nil }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // Words typed after the dictation must not become part of a term:
        // at the open end only an equal-length replacement is a correction.
        if openEnded, suffix == 0, new.count != old.count { return nil }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        // One name (up to 3 words) replacing up to 4 dictated words; most of
        // the dictation must be unchanged (not a rewrite).
        guard (1...4).contains(oldMiddle.count), (1...3).contains(newMiddle.count),
              old.count - oldMiddle.count >= min(2, old.count - 1) else { return nil }

        let term = newMiddle.joined(separator: " ")
        let spoken = oldMiddle.joined(separator: " ")
        guard term.count >= 2, term.count <= 40, term.contains(where: \.isLetter) else { return nil }
        // Just lowercasing, or a word deleted/added around the same text: not a term.
        if term.compare(spoken, options: .caseInsensitive) == .orderedSame {
            guard term.contains(where: \.isUppercase), term != spoken else { return nil }
            return LearnedWord(term: term, spokenAs: nil)
        }
        // The dictionary's fuzzy matching will fix it on its own next time?
        let fuzzyFixes = CustomDictionary.apply(spoken, entries: [DictionaryEntry(term: term)])
            .compare(term, options: .caseInsensitive) == .orderedSame
        // Otherwise only accept an unrelated replacement when the term looks
        // like a name (capitals, digits, symbols): "pasta" → "rice" is an
        // edit, not a word the model misheard.
        if !fuzzyFixes {
            // A capital that only starts the sentence doesn't make a name.
            let raw = dictated.split(whereSeparator: \.isWhitespace)
            let startsSentence = prefix == 0
                || (raw.count == old.count && raw[prefix - 1].last.map { ".!?…".contains($0) } == true)
            let checked = startsSentence ? String(term.dropFirst()) : term
            let looksLikeName = checked.contains(where: { $0.isUppercase || $0.isNumber })
                || term.contains(where: { !$0.isLetter && !$0.isWhitespace })
            guard looksLikeName else { return nil }
        }
        // An exact replacement only for multi-word mishearings ("swift you
        // eye"): a single word ("mark" → "Marco") is a real word that must
        // keep being written in other dictations.
        return LearnedWord(term: term, spokenAs: fuzzyFixes || oldMiddle.count < 2 ? nil : spoken.lowercased())
    }

    /// Words without the sentence punctuation around them ("Flusso," →
    /// "Flusso"), keeping what belongs to a name (".NET", "C++", "#tag").
    static func words(_ text: String) -> [String] {
        let leading = CharacterSet(charactersIn: "\"'“”‘’«»([{¿¡")
        let trailing = CharacterSet(charactersIn: ".,;:!?…\"'“”‘’«»)]}")
        return text.split(whereSeparator: \.isWhitespace)
            .map { word -> String in
                var w = Substring(word)
                while let c = w.unicodeScalars.first, leading.contains(c) { w = w.dropFirst() }
                while let c = w.unicodeScalars.last, trailing.contains(c) { w = w.dropLast() }
                return String(w)
            }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    // MARK: - Accessibility

    nonisolated private static func characterCount(of element: AXUIElement) -> Int? {
        var count: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success else {
            return nil
        }
        return (count as? NSNumber)?.intValue
    }

    nonisolated private static func value(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func cursor(of element: AXUIElement) -> Int? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    nonisolated private static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == "AXSecureTextField"
    }
}
