import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Platform fix: `Plurals.stringsdict` never reached the bundle. `Scripts/build-app.sh`
/// copied only `Apps/ZenitPDF/Bundle/<lang>.lproj`, so the built `en.lproj` held
/// `Localizable.strings` alone and every plural took the English one/other fallback.
@Suite("Plural rules ship with every language (NL-PLAT-19)")
struct PlatformPluralShippingTests {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func catalogue(_ language: String) throws -> [String: [String: Any]] {
        let url = repositoryRoot.appendingPathComponent(
            "Packages/ZPDFUIPresentation/Localization/\(language).lproj/Plurals.stringsdict")
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]])
    }

    private static func forms(_ entry: [String: Any]) -> [String: String] {
        (entry["count"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    private static func specifiers(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|@)")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    @Test("build-app.sh copies Plurals.stringsdict into each shipped .lproj and fails without it")
    func buildScriptShipsThePluralRules() throws {
        // Old code: the loop copied `${BUNDLE_SOURCE}/${lang}.lproj` and nothing else, and the
        // string "Plurals.stringsdict" did not occur in the script.
        let script = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("Localization/${lang}.lproj/Plurals.stringsdict"))
        #expect(script.contains("${RESOURCES_DIR}/${lang}.lproj/Plurals.stringsdict"))
        #expect(script.contains("missing plural rules for ${lang}"))
    }

    @Test("The Swedish twin has every English key, and each form keeps its conversions")
    func swedishTwinMatches() throws {
        let english = try Self.catalogue("en")
        let swedish = try Self.catalogue("sv")
        #expect(Set(english.keys) == Set(swedish.keys))
        for (key, entry) in english {
            let svForms = Self.forms(try #require(swedish[key]))
            for (category, text) in Self.forms(entry) where category == "one" || category == "other" {
                let svText = try #require(svForms[category], "sv \(key) lacks \(category)")
                #expect(Self.specifiers(svText) == Self.specifiers(text), "\(key) [\(category)]: \(svText)")
            }
        }
    }

    @Test("A one-tool set reads \"Add 1 Tool\" through the shipped rules, in both languages")
    func addToolsPluralises() throws {
        for (language, one, many) in [("en", "Add 1 Tool", "Add 3 Tools"), ("sv", "Lägg till 1 verktyg", "Lägg till 3 verktyg")] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PluralShipping-\(UUID().uuidString)", isDirectory: true)
            let lproj = root.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.copyItem(
                at: Self.repositoryRoot.appendingPathComponent(
                    "Packages/ZPDFUIPresentation/Localization/\(language).lproj/Plurals.stringsdict"),
                to: lproj.appendingPathComponent("Plurals.stringsdict"))
            let info: [String: Any] = ["CFBundleDevelopmentRegion": language, "CFBundleIdentifier": "plural.\(language)"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Info.plist"))
            let bundle = try #require(Bundle(url: root))
            #expect(LocalizedPlural.string("Add %lld Tools", count: 1, one: "x", other: "y", bundle: bundle) == one)
            #expect(LocalizedPlural.string("Add %lld Tools", count: 3, one: "x", other: "y", bundle: bundle) == many)
        }
    }
}
