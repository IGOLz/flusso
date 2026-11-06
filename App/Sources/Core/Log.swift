import os

nonisolated enum Log {
    static let app = Logger(subsystem: "dev.igol.flusso", category: "app")
    static let audio = Logger(subsystem: "dev.igol.flusso", category: "audio")
    static let hotkey = Logger(subsystem: "dev.igol.flusso", category: "hotkey")
    static let engine = Logger(subsystem: "dev.igol.flusso", category: "engine")
    static let paste = Logger(subsystem: "dev.igol.flusso", category: "paste")
    static let models = Logger(subsystem: "dev.igol.flusso", category: "models")
}
