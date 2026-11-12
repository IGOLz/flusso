// Run: xcrun swiftc -default-isolation MainActor App/Sources/Core/SpokenNumbers.swift \
//   Tests/SpokenNumbersChecks.swift -o build/spoken-numbers-checks && build/spoken-numbers-checks
import Foundation

@main
struct SpokenNumbersChecks {
    static func main() {
        let cases: [(String, String)] = [
            ("Il numero tre, il numero dieci e il numero cinquanta.", "Il numero 3, il numero 10 e il numero 50."),
            ("Tre dieci cinquanta", "3 10 50"),
            ("Ho ventitré gatti e duecentottanta libri.", "Ho 23 gatti e 280 libri."),
            ("Ventuno, ventotto, trentatré, centotto, centottanta, novecentonovantanove.", "21, 28, 33, 108, 180, 999."),
            ("Duemilaventisei e mille duecento trenta quattro.", "2026 e 1234."),
            ("Due milioni trecentomila quattro euro.", "2300004 euro."),
            ("Un milione e cinquanta euro.", "1000050 euro."),
            ("Meno tre virgola zero cinque.", "-3,05."),
            ("Due virgola venticinque", "2,25"),
            ("Tre virgola centoventicinque", "3,125"),
            ("Three point twenty five", "3.25"),
            ("tre, cinque; dieci\ncinquanta", "3, 5; 10\n50"),
            ("Sei pronto? Tu sei molto gentile.", "Sei pronto? Tu sei molto gentile."),
            ("Ho sei gatti. Sono le sei. Sei euro. Il numero sei. Ne voglio sei.", "Ho 6 gatti. Sono le 6. 6 euro. Il numero 6. Ne voglio 6."),
            ("sei", "6"),
            ("Un amico e una casa, nessuno e qualcuno.", "Un amico e una casa, nessuno e qualcuno."),
            ("Sei uno sviluppatore. Ho uno zaino. Ne voglio uno.", "Sei uno sviluppatore. Ho uno zaino. Ne voglio 1."),
            ("Uno due tre", "1 2 3"),
            ("Tre e sei", "3 e 6"),
            ("Prima il primo, poi il secondo punto.", "Prima il primo, poi il secondo punto."),
            ("Il trecentenario, stage3, tre_foo e cinquantesimo.", "Il trecentenario, stage3, tre_foo e cinquantesimo."),
            ("Apri https://example.com/tre e scrivi a tre@example.com.", "Apri https://example.com/tre e scrivi a tre@example.com."),
            ("Pago 3,50 euro, versione 1.2.3, codice 007 e +39 0123.", "Pago 3,50 euro, versione 1.2.3, codice 007 e +39 0123."),
            ("20 3 100 5 007", "20 3 100 5 007"),
            ("Cento venti e cinque", "120 e 5"),
            ("Punto uno: compra tre mele. Punto due: compra dieci pere.", "Punto 1: compra 3 mele. Punto 2: compra 10 pere."),
            ("Three, ten and fifty.", "3, 10 and 50."),
            ("One hundred and twenty three tickets.", "123 tickets."),
            ("A hundred and fifty, a thousand, hundred.", "150, 1000, 100."),
            ("A cat and an apple.", "A cat and an apple."),
            ("Two thousand twenty-six euros.", "2026 euros."),
            ("Minus three point zero five.", "-3.05."),
            ("One two three", "1 2 3"),
            ("Three million two hundred thousand five.", "3200005."),
            ("", ""),
        ]
        for (input, expected) in cases {
            let result = SpokenNumbers.normalize(input)
            assert(result == expected, "\(input)\nExpected: \(expected)\nActual:   \(result)")
            assert(SpokenNumbers.normalize(result) == result, "Not idempotent: \(result)")
            let withoutGrammar = SpokenNumbers.normalize(input, useGrammar: false)
            assert(withoutGrammar == expected, "Without grammar assets: \(input)\nExpected: \(expected)\nActual: \(withoutGrammar)")
        }
        // Canonical spellings cover elisions, accents, hyphens and compound numbers.
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        let numbers = Array(0..<1000) + Array(stride(from: 1000, through: 999_999, by: 997)) + [1_000_000, 1_000_000_000]
        for locale in ["it_IT", "en_US"] {
            formatter.locale = Locale(identifier: locale)
            for n in numbers {
                let spoken = formatter.string(from: NSNumber(value: n))!.replacingOccurrences(of: "\u{00AD}", with: "")
                assert(SpokenNumbers.normalize(spoken) == String(n), "Failed \(locale) number \(n): \(spoken)")
            }
        }
        print("Spoken number checks passed: \(cases.count) sentences and \(numbers.count * 2) Italian/English numbers")
    }
}
