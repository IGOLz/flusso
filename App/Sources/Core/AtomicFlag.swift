import os

/// A lock-protected Bool, readable from any thread (macOS 13+; `Atomic`
/// needs macOS 15).
nonisolated final class AtomicFlag: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init() {}

    var value: Bool { lock.withLock { $0 } }

    func set(_ newValue: Bool) {
        lock.withLock { $0 = newValue }
    }
}
