import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Bug hunt 2: the measurement tools' own rules — what they ask for and how many points they
/// need — must match what the engine will accept.
@Suite("Fix2 measurement tool rules")
@MainActor
struct Fix2MeasurementRulesTests {

    /// BH-052. Old output: `MeasurementKind.slope.requiredParameter` was nil, so a Slope commit
    /// went to `SlopeCalculator` without a magnitude and was refused with
    /// `missingParameter(.riseRun)` — and there was no field to type one into.
    @Test("Slope asks for the steepness the engine requires")
    func slopeAsksForItsSteepness() {
        #expect(MeasurementKind.slope.requiredParameter == .slopePercent)
        #expect(MeasurementKind.trueSlopedLength.requiredParameter == .slopePercent)
        #expect(MeasurementKind.trueSlopedArea.requiredParameter == .slopePercent)
        let hungry = MeasurementKind.allCases.filter { $0.requiredParameter != nil }
        #expect(Set(hungry) == [.volume, .wallArea, .riseDrop, .slope, .trueSlopedLength, .trueSlopedArea])
    }

    /// BH-768. Old output: "Enter a slope before finishing: a true length needs the plane's
    /// steepness." — shown for True Sloped Area, which produces an area.
    @Test("The missing-slope note does not name a length")
    func missingSlopeNoteIsToolNeutral() {
        let note = MeasurementParameterRequirement.slopePercent.missingValueNote
        #expect(!note.localizedCaseInsensitiveContains("length"))
        #expect(!note.isEmpty)
    }

    /// BH-270. Old output: `MeasurementKind.arcLength.minimumPointCount == 2`, so a two-point
    /// Arc Length was committed and `ArcLengthCalculator` threw `unsupportedGeometry`.
    /// BH-767. Old output: `temporaryMeasure.minimumPointCount == 1`, committing an empty entry.
    @Test("Arc Length needs three points and Temporary Measure two")
    func pointMinimaMatchTheCalculators() {
        #expect(MeasurementKind.arcLength.minimumPointCount == 3)
        #expect(MeasurementKind.temporaryMeasure.minimumPointCount == 2)
        #expect(MeasurementKind.count.minimumPointCount == 1)
    }

    /// BH-785. Old output: "Length needs 1 more points before it can be finished."
    @Test("The too-few-points refusal is pluralised")
    func refusalIsPluralised() {
        let presenter = MockMeasurementToolPresenter()
        presenter.activate(kind: .length)
        presenter.placePoint(PDFPointValue(x: 10, y: 10))
        let one = presenter.commitRefusalReason ?? ""
        #expect(one.contains("1 more point "), "\(one)")
        #expect(!one.contains("1 more points"))

        presenter.activate(kind: .area)
        let many = presenter.commitRefusalReason ?? ""
        #expect(many.contains("3 more points"), "\(many)")
    }

    /// The shared plural helper: the English fallback, and a catalogue rule when one exists.
    @Test("LocalizedPlural falls back to one/other and honours a stringsdict")
    func pluralHelper() throws {
        #expect(LocalizedPlural.string("%lld pages", count: 1, one: "%lld page", other: "%lld pages") == "1 page")
        #expect(LocalizedPlural.string("%lld pages", count: 0, one: "%lld page", other: "%lld pages") == "0 pages")
        #expect(LocalizedPlural.string("%lld pages", count: 2, one: "%lld page", other: "%lld pages") == "2 pages")

        // A throwaway bundle carrying a Plurals.stringsdict with a rule the fallback cannot know.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fix2Plurals-\(UUID().uuidString)", isDirectory: true)
        let lproj = root.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = [
            "%lld pages": [
                "NSStringLocalizedFormatKey": "%#@pages@",
                "pages": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    "one": "exactly %lld sheet",
                    "other": "%lld sheets"
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: lproj.appendingPathComponent("Plurals.stringsdict"))
        let info: [String: Any] = ["CFBundleDevelopmentRegion": "en", "CFBundleIdentifier": "fix2.plurals"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(LocalizedPlural.string("%lld pages", count: 1, one: "%lld page", other: "%lld pages", bundle: bundle) == "exactly 1 sheet")
        #expect(LocalizedPlural.string("%lld pages", count: 4, one: "%lld page", other: "%lld pages", bundle: bundle) == "4 sheets")
    }
}
