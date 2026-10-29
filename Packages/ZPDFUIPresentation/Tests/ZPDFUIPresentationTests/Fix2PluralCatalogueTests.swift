import Foundation
import Testing
@testable import ZPDFUIPresentation

/// The plural catalogue that ships beside `Localizable.strings` must cover every
/// `LocalizedPlural` key the UI packages use, and must pluralise.
///
/// Source of truth: `Packages/ZPDFUIPresentation/Localization/en.lproj/Plurals.stringsdict`;
/// the app bundle copies it into `en.lproj`.
@Suite("Fix2 plural catalogue")
struct Fix2PluralCatalogueTests {

    private static let packagesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var catalogueURL: URL {
        packagesDirectory.appendingPathComponent("ZPDFUIPresentation/Localization/en.lproj/Plurals.stringsdict")
    }

    private func catalogue() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.catalogueURL)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Every LocalizedPlural key in the UI packages is in the catalogue")
    func everyKeyIsCatalogued() throws {
        let keys = Set(try catalogue().keys)
        let pattern = try NSRegularExpression(pattern: #"LocalizedPlural\.string\(\s*"([^"]+)""#)
        var used = Set<String>()
        // Every UI package that calls LocalizedPlural. ZPDFUIMeasurement (T-062's keys),
        // ZPDFUIWorkflows and ZPDFUILedger were outside this scan until iteration 3.
        for package in ["ZPDFUIShell", "ZPDFUIPresentation", "ZPDFDesignSystem", "ZPDFUIMeasurement", "ZPDFUIWorkflows", "ZPDFUILedger"] {
            let sources = Self.packagesDirectory.appendingPathComponent("\(package)/Sources")
            let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", url.lastPathComponent != "LocalizedPlural.swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { used.insert(String(text[range])) }
                }
            }
        }
        #expect(!used.isEmpty)
        #expect(used.subtracting(keys).isEmpty, "missing from Plurals.stringsdict: \(used.subtracting(keys).sorted())")
    }

    @Test("The catalogue pluralises through LocalizedPlural")
    func cataloguePluralises() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fix2PluralCatalogue-\(UUID().uuidString)", isDirectory: true)
        let lproj = root.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: Self.catalogueURL, to: lproj.appendingPathComponent("Plurals.stringsdict"))
        let info: [String: Any] = ["CFBundleDevelopmentRegion": "en", "CFBundleIdentifier": "fix2.catalogue"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        // Deliberately wrong fallbacks: the result must come from the catalogue.
        #expect(LocalizedPlural.string("%lld pages", count: 1, one: "x", other: "y", bundle: bundle) == "1 page")
        #expect(LocalizedPlural.string("%lld pages", count: 5, one: "x", other: "y", bundle: bundle) == "5 pages")
        #expect(LocalizedPlural.string("%lld warnings", count: 1, one: "x", other: "y", bundle: bundle) == "1 warning")
    }
}
