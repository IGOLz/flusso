import Foundation

struct SpokenLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let flag: String
    var id: String { code }
}

enum Languages {
    /// The 25 European languages supported by Parakeet Ultra / Parakeet v3.
    static let all: [SpokenLanguage] = [
        .init(code: "en", name: "English", flag: "🇬🇧"),
        .init(code: "it", name: "Italian", flag: "🇮🇹"),
        .init(code: "es", name: "Spanish", flag: "🇪🇸"),
        .init(code: "fr", name: "French", flag: "🇫🇷"),
        .init(code: "de", name: "German", flag: "🇩🇪"),
        .init(code: "pt", name: "Portuguese", flag: "🇵🇹"),
        .init(code: "nl", name: "Dutch", flag: "🇳🇱"),
        .init(code: "ro", name: "Romanian", flag: "🇷🇴"),
        .init(code: "pl", name: "Polish", flag: "🇵🇱"),
        .init(code: "ru", name: "Russian", flag: "🇷🇺"),
        .init(code: "uk", name: "Ukrainian", flag: "🇺🇦"),
        .init(code: "el", name: "Greek", flag: "🇬🇷"),
        .init(code: "sv", name: "Swedish", flag: "🇸🇪"),
        .init(code: "da", name: "Danish", flag: "🇩🇰"),
        .init(code: "fi", name: "Finnish", flag: "🇫🇮"),
        .init(code: "cs", name: "Czech", flag: "🇨🇿"),
        .init(code: "sk", name: "Slovak", flag: "🇸🇰"),
        .init(code: "sl", name: "Slovenian", flag: "🇸🇮"),
        .init(code: "hr", name: "Croatian", flag: "🇭🇷"),
        .init(code: "hu", name: "Hungarian", flag: "🇭🇺"),
        .init(code: "bg", name: "Bulgarian", flag: "🇧🇬"),
        .init(code: "et", name: "Estonian", flag: "🇪🇪"),
        .init(code: "lv", name: "Latvian", flag: "🇱🇻"),
        .init(code: "lt", name: "Lithuanian", flag: "🇱🇹"),
        .init(code: "mt", name: "Maltese", flag: "🇲🇹"),
    ]

    static func language(for code: String) -> SpokenLanguage? {
        all.first { $0.code == code }
    }
}
