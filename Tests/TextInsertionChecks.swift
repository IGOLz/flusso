// xcrun swiftc -default-isolation MainActor App/Sources/Core/Log.swift \
//   App/Sources/Output/TextInserter.swift Tests/TextInsertionChecks.swift \
//   -o build/text-insertion-checks && build/text-insertion-checks
import Foundation

@main
struct TextInsertionChecks {
    static func main() {
        let before = InsertionSnapshot(value: "Hello", selection: NSRange(location: 5, length: 0))
        assert(InsertionSnapshot.wasRejected(before: before, after: before))
        let inserted = InsertionSnapshot(value: "Hello world", selection: NSRange(location: 11, length: 0))
        assert(!InsertionSnapshot.wasRejected(before: before, after: inserted))
        let selected = InsertionSnapshot(value: "Hello", selection: NSRange(location: 0, length: 5))
        assert(!InsertionSnapshot.wasRejected(before: selected, after: before),
               "Replacing selected text with itself must count as insertion")
        assert(!InsertionSnapshot.wasRejected(before: nil, after: before))
        assert(!InsertionSnapshot.wasRejected(before: before, after: nil))
        assert(!InsertionSnapshot.wasRejected(before: nil, after: nil),
               "Custom editors without AX text must retain their paste support")
        print("Text insertion checks passed: rejected, inserted, selection replacement, unavailable AX")
    }
}
