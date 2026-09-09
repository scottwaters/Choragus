/// L10nCatalogTests.swift — The translation contract: every key in the
/// String Catalog carries all supported languages, every `L10n` accessor
/// resolves to a catalog key and every catalog key has an accessor, format
/// placeholders agree across languages, and lookup follows the in-app
/// language setting with an English fallback.
import XCTest
@testable import SonosKit

final class L10nCatalogTests: XCTestCase {

    private static let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SonosKit")
    private static let catalogURL = sourcesDir.appendingPathComponent("Resources/Localizable.xcstrings")
    private static let accessorsURL = sourcesDir.appendingPathComponent("Localization/L10n.swift")

    private struct Catalog {
        let strings: [String: [String: String]]   // key -> language -> value
        let rawKeyCount: Int
    }

    private static let catalog: Catalog = {
        let data = try! Data(contentsOf: catalogURL)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = json["strings"] as! [String: Any]
        var out: [String: [String: String]] = [:]
        for (key, entry) in strings {
            let locs = (entry as! [String: Any])["localizations"] as? [String: Any] ?? [:]
            var byLang: [String: String] = [:]
            for (lang, unit) in locs {
                byLang[lang] = ((unit as! [String: Any])["stringUnit"] as! [String: Any])["value"] as? String
            }
            out[key] = byLang
        }
        // JSONSerialization keeps the last of two duplicate keys silently; count
        // the key lines in the pretty-printed source to detect a duplicate.
        let text = String(decoding: data, as: UTF8.self)
        let keyLines = text.components(separatedBy: "\n").filter { line in
            line.hasPrefix("    \"") && line.hasSuffix("\" : {")
        }
        return Catalog(strings: out, rawKeyCount: keyLines.count)
    }()

    private static let accessorKeys: Set<String> = {
        let text = try! String(contentsOf: accessorsURL, encoding: .utf8)
        let regex = try! NSRegularExpression(pattern: #"tr\("([^"]+)"\)"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(regex.matches(in: text, range: range).map {
            String(text[Range($0.range(at: 1), in: text)!])
        })
    }()

    func testEveryKeyCarriesEveryLanguage() {
        let languages = Set(AppLanguage.allCases.map(\.rawValue))
        var gaps: [String] = []
        for (key, byLang) in Self.catalog.strings {
            for lang in languages where (byLang[lang] ?? "").isEmpty {
                gaps.append("\(key):\(lang)")
            }
        }
        XCTAssertEqual(languages.count, 13)
        XCTAssertTrue(gaps.isEmpty, "Missing translations: \(gaps.sorted().prefix(20))")
    }

    func testCatalogHasNoDuplicateKeys() {
        XCTAssertEqual(Self.catalog.rawKeyCount, Self.catalog.strings.count,
                       "A duplicate key in Localizable.xcstrings would be dropped silently at load")
    }

    func testAccessorsAndCatalogKeysAgree() {
        let catalogKeys = Set(Self.catalog.strings.keys)
        let unresolved = Self.accessorKeys.subtracting(catalogKeys)
        let orphaned = catalogKeys.subtracting(Self.accessorKeys)
        XCTAssertTrue(unresolved.isEmpty, "Accessors without a catalog entry: \(unresolved.sorted().prefix(20))")
        XCTAssertTrue(orphaned.isEmpty, "Catalog entries without an accessor: \(orphaned.sorted().prefix(20))")
    }

    /// Every language must consume the same placeholders as English: the same
    /// count and types, in any order, since translations reorder arguments
    /// with `%1$@` / `%2$@`. Positional indices, when used, must be complete.
    func testFormatPlaceholdersMatchEnglish() {
        let regex = try! NSRegularExpression(pattern: #"%(\d+)?\$?(l{0,2}[@dfsu])"#)
        func placeholders(_ s: String) -> (types: [String], positionsComplete: Bool) {
            let r = NSRange(s.startIndex..<s.endIndex, in: s)
            let matches = regex.matches(in: s, range: r)
            let types = matches.map { String(s[Range($0.range(at: 2), in: s)!]) }.sorted()
            let positions = matches.compactMap { m -> Int? in
                Range(m.range(at: 1), in: s).map { Int(s[$0])! }
            }
            let complete = positions.isEmpty || Set(positions) == Set(1...types.count)
            return (types, complete)
        }
        var mismatches: [String] = []
        for (key, byLang) in Self.catalog.strings {
            guard let en = byLang["en"] else { continue }
            let expected = placeholders(en).types
            for (lang, value) in byLang where lang != "en" {
                let got = placeholders(value)
                if got.types != expected || !got.positionsComplete { mismatches.append("\(key):\(lang)") }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "Placeholder mismatch vs English: \(mismatches.sorted().prefix(20))")
    }

    func testLookupFollowsAppLanguageAndFallsBackToEnglish() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: UDKey.appLanguage)
        defer { defaults.set(saved, forKey: UDKey.appLanguage) }

        defaults.set("de", forKey: UDKey.appLanguage)
        XCTAssertEqual(L10n.done, Self.catalog.strings["done"]?["de"])
        defaults.set("zh-Hans", forKey: UDKey.appLanguage)
        XCTAssertEqual(L10n.cancel, Self.catalog.strings["cancel"]?["zh-Hans"])
        defaults.set("xx", forKey: UDKey.appLanguage)
        XCTAssertEqual(L10n.done, Self.catalog.strings["done"]?["en"], "unknown language falls back to English")
        defaults.set("en", forKey: UDKey.appLanguage)
        XCTAssertEqual(L10n.tr("no.such.key"), "no.such.key", "unknown key returns the key")
    }
}
