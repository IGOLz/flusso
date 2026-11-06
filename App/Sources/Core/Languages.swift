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
        .init(code: "it", name: "Italiano", flag: "🇮🇹"),
        .init(code: "en", name: "Inglese", flag: "🇬🇧"),
        .init(code: "es", name: "Spagnolo", flag: "🇪🇸"),
        .init(code: "fr", name: "Francese", flag: "🇫🇷"),
        .init(code: "de", name: "Tedesco", flag: "🇩🇪"),
        .init(code: "pt", name: "Portoghese", flag: "🇵🇹"),
        .init(code: "nl", name: "Olandese", flag: "🇳🇱"),
        .init(code: "ro", name: "Rumeno", flag: "🇷🇴"),
        .init(code: "pl", name: "Polacco", flag: "🇵🇱"),
        .init(code: "ru", name: "Russo", flag: "🇷🇺"),
        .init(code: "uk", name: "Ucraino", flag: "🇺🇦"),
        .init(code: "el", name: "Greco", flag: "🇬🇷"),
        .init(code: "sv", name: "Svedese", flag: "🇸🇪"),
        .init(code: "da", name: "Danese", flag: "🇩🇰"),
        .init(code: "fi", name: "Finlandese", flag: "🇫🇮"),
        .init(code: "cs", name: "Ceco", flag: "🇨🇿"),
        .init(code: "sk", name: "Slovacco", flag: "🇸🇰"),
        .init(code: "sl", name: "Sloveno", flag: "🇸🇮"),
        .init(code: "hr", name: "Croato", flag: "🇭🇷"),
        .init(code: "hu", name: "Ungherese", flag: "🇭🇺"),
        .init(code: "bg", name: "Bulgaro", flag: "🇧🇬"),
        .init(code: "et", name: "Estone", flag: "🇪🇪"),
        .init(code: "lv", name: "Lettone", flag: "🇱🇻"),
        .init(code: "lt", name: "Lituano", flag: "🇱🇹"),
        .init(code: "mt", name: "Maltese", flag: "🇲🇹"),
    ]

    static func language(for code: String) -> SpokenLanguage? {
        all.first { $0.code == code }
    }
}
