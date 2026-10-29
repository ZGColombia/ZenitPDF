import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Templates per job type: a template captures the whole rig, reproduces it
/// exactly, and cannot carry a scale — not "does not", *cannot*.
///
/// | Rule | Test |
/// |---|---|
/// | Capture → encode → decode reproduces the rig, field by field | ``roundTripReproducesTheRigFieldByField()`` |
/// | The encoded form has no key that is or contains a scale | ``theEncodedFormHasNoPlaceForAScale()`` |
/// | A file smuggling scale keys decodes to the same template, and they do not survive | ``aSmuggledScaleKeyIsIgnoredAndDoesNotSurvive()`` |
/// | Applying to a calibrated project leaves every page's scale bit-identical | ``applyingATemplateLeavesEveryScaleUntouched()`` |
/// | Applying reproduces column order and visibility through the presenter | ``applyingReproducesColumnOrderAndVisibility()`` |
/// | The pure column rule arranges, hides and keeps unnamed columns | ``theColumnRuleArrangesAndKeepsTheRest()`` |
@Suite("Job templates")
struct JobTemplateTests {

    // MARK: - A rig worth capturing

    /// A digest-shaped string for artwork references. The value only has to be stable and
    /// distinct; no artwork store is consulted at this level.
    private static let drainDigest = String(repeating: "a", count: 64)

    /// The rig: the six built-in presets, a custom count symbol, subjects with colours,
    /// reordered columns and imperial units — every field of the template exercised.
    private static func makeTemplate() -> JobTemplate {
        let drain = CustomCountSymbol(
            id: UUID(uuidString: "7B00A001-0000-4000-8000-000000000001")!,
            name: "Floor Drain",
            artwork: StampArtworkDescriptor(
                kind: .vector,
                digest: drainDigest,
                byteCount: 2_048,
                sourceName: "drain-symbol.pdf",
                sourcePageIndex: 0
            ),
            colorRGBA: ColorRGBA(red: 0.25, green: 0.5, blue: 1),
            defaultSubject: "Drains"
        )
        var presets = DefaultToolSet.presets
        presets.append(drain.asPreset(sortIndex: presets.count))
        return JobTemplate(
            id: UUID(uuidString: "7B00A001-0000-4000-8000-00000000000A")!,
            name: "Groundwork",
            createdAt: Date(timeIntervalSince1970: 1_756_400_000),
            presets: presets,
            subjects: JobTemplateApplier.subjects(from: presets),
            columnPreferences: [
                JobTemplateColumnPreference(columnID: LedgerColumnID.subject.rawValue, visible: true),
                JobTemplateColumnPreference(columnID: LedgerColumnID.label.rawValue, visible: false),
                JobTemplateColumnPreference(columnID: "custom.costCode", visible: true)
            ],
            units: JobTemplateUnits(selection: .imperial)
        )
    }

    // MARK: - Round trip

    @Test("Capture, export and import reproduce the rig field by field")
    func roundTripReproducesTheRigFieldByField() throws {
        let template = Self.makeTemplate()
        let data = try JobTemplateFile.export(template)
        let decoded = try JobTemplateFile.read(data)

        #expect(decoded.id == template.id)
        #expect(decoded.formatVersion == template.formatVersion)
        #expect(decoded.name == template.name)
        #expect(decoded.createdAt == template.createdAt)
        #expect(decoded.presets == template.presets)
        #expect(decoded.subjects == template.subjects)
        #expect(decoded.columnPreferences == template.columnPreferences)
        #expect(decoded.units == template.units)
        #expect(decoded == template)

        // The units block resolves back to the live selection it captured.
        #expect(decoded.units.selection == DisplayUnitSelection.imperial)
        // The subject vocabulary carries names and colours, in first-appearance order.
        #expect(decoded.subjects.first?.name == "Exterior Wall")
        #expect(decoded.subjects.contains { $0.name == "Drains" })
    }

    // MARK: - No place for a scale

    /// Every dictionary key of the exported JSON, recursively.
    private func allKeys(in object: Any) -> [String] {
        var keys: [String] = []
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                keys.append(key)
                keys.append(contentsOf: allKeys(in: value))
            }
        } else if let array = object as? [Any] {
            for value in array {
                keys.append(contentsOf: allKeys(in: value))
            }
        }
        return keys
    }

    @Test("The encoded form has no key that is or contains a scale")
    func theEncodedFormHasNoPlaceForAScale() throws {
        let data = try JobTemplateFile.export(Self.makeTemplate())
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = allKeys(in: object)
        #expect(!keys.isEmpty, "the scan has to have scanned something")
        let scaleLike = keys.filter { $0.lowercased().contains("scale") }
        #expect(
            scaleLike.isEmpty,
            "a template must be structurally unable to carry a scale; found \(scaleLike)"
        )
        let calibrationLike = keys.filter { $0.lowercased().contains("calibrat") }
        #expect(calibrationLike.isEmpty, "nor a calibration; found \(calibrationLike)")
    }

    @Test("A template JSON smuggling scale keys decodes to the same template, and the keys do not survive")
    func aSmuggledScaleKeyIsIgnoredAndDoesNotSurvive() throws {
        // A template of exactly representable values, so pushing its file through
        // JSONSerialization and back cannot move a number.
        let template = JobTemplate(
            id: UUID(uuidString: "7B00A001-0000-4000-8000-00000000000B")!,
            name: "Roofing",
            createdAt: Date(timeIntervalSince1970: 1_756_400_000),
            subjects: [JobTemplateSubject(name: "Roof", colorRGBA: ColorRGBA(red: 1, green: 0.5, blue: 0.25))],
            columnPreferences: [
                JobTemplateColumnPreference(columnID: LedgerColumnID.subject.rawValue, visible: true)
            ],
            units: JobTemplateUnits(selection: .metric)
        )
        let exported = try JobTemplateFile.export(template)

        var envelope = try #require(
            try JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        var body = try #require(envelope["template"] as? [String: Any])
        body["scale"] = ["metresPerPoint": 4]
        body["pageScales"] = [["pageID": "smuggled", "metresPerPoint": 4]]
        body["calibration"] = ["knownLength": 10]
        envelope["template"] = body
        let smuggled = try JSONSerialization.data(withJSONObject: envelope)

        // Ignored: the decoder has no key for any of it, so the template that arrives is the
        // template that was sent — and the digest still matches, because the canonical form
        // never contained the smuggled members.
        let decoded = try JobTemplateFile.read(smuggled)
        #expect(decoded == template)

        // And it does not survive: re-exporting what was read carries no trace.
        let reExported = try JobTemplateFile.export(decoded)
        let keys = allKeys(in: try JSONSerialization.jsonObject(with: reExported))
        #expect(keys.allSatisfy { !$0.lowercased().contains("scale") })
        #expect(keys.allSatisfy { !$0.lowercased().contains("calibrat") })
    }

    // MARK: - Applying never touches a scale

    private struct Fixture {
        let environment: AppCoreEnvironment
        let documentID: DocumentID
        let pageA: ZPDFContracts.PageDescriptor
        let pageB: ZPDFContracts.PageDescriptor
    }

    /// A project with **two** differently calibrated sheets, so "every scale untouched"
    /// quantifies over more than one scale.
    @MainActor
    private func makeCalibratedFixture() async throws -> Fixture {
        let documentID = DocumentID(UUID())
        let pageA = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let pageB = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 1,
            label: "A-102",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [pageA, pageB])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: pageA.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        try await environment.commands.calibrate(
            page: pageB.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 200, y: 0),
            knownLength: 5,
            knownLengthUnit: .metre
        )
        return Fixture(environment: environment, documentID: documentID, pageA: pageA, pageB: pageB)
    }

    @Test("Applying a template to a calibrated project leaves every scale bit-identical")
    @MainActor
    func applyingATemplateLeavesEveryScaleUntouched() async throws {
        let fixture = try await makeCalibratedFixture()
        let environment = fixture.environment
        let session = environment.session

        let scalesBefore = await session.pageScales
        #expect(scalesBefore.count == 2, "both sheets are calibrated before the template arrives")

        let template = Self.makeTemplate()
        let receipt = JobTemplateApplier.apply(
            template,
            toolLibrary: environment.toolLibrary,
            ledger: environment.ledger
        )

        // The rig arrived…
        #expect(environment.toolLibrary.presets == template.presets)
        #expect(receipt.appliedPresetCount == template.presets.count)
        #expect(receipt.units == DisplayUnitSelection.imperial)
        #expect(receipt.subjects == template.subjects)

        // …and every scale is exactly what it was: same pages, same transforms, compared as
        // whole values, plus per page through the resolution path a measurement would take.
        let scalesAfter = await session.pageScales
        #expect(scalesAfter == scalesBefore)
        let pageAScaleAfter = await session.scale(onPage: fixture.pageA.id)
        let pageBScaleAfter = await session.scale(onPage: fixture.pageB.id)
        #expect(pageAScaleAfter == scalesBefore[fixture.pageA.id])
        #expect(pageBScaleAfter == scalesBefore[fixture.pageB.id])
    }

    @Test("Applying reproduces column order and visibility through the presenter's own API")
    @MainActor
    func applyingReproducesColumnOrderAndVisibility() async throws {
        let fixture = try await makeCalibratedFixture()
        let ledger = fixture.environment.ledger
        let originalColumns = ledger.columns
        try #require(originalColumns.count >= 3, "the default ledger has columns to rearrange")

        // The template asks for the third column first and hidden, then the first, visible —
        // plus one column this project does not have, which must be reported, not invented.
        let third = originalColumns[2]
        let first = originalColumns[0]
        var template = JobTemplate(name: "Rearranged")
        template.columnPreferences = [
            JobTemplateColumnPreference(columnID: third.id.rawValue, visible: false),
            JobTemplateColumnPreference(columnID: first.id.rawValue, visible: true),
            JobTemplateColumnPreference(columnID: "custom.notInThisProject", visible: true)
        ]

        let receipt = JobTemplateApplier.apply(
            template,
            toolLibrary: fixture.environment.toolLibrary,
            ledger: ledger
        )

        #expect(ledger.columns[0].id == third.id)
        #expect(ledger.columns[0].visible == false)
        #expect(ledger.columns[1].id == first.id)
        #expect(ledger.columns[1].visible == true)
        #expect(ledger.columns.count == originalColumns.count, "a template arranges columns, it never adds or removes one")
        #expect(receipt.appliedColumnIDs == [third.id.rawValue, first.id.rawValue])
        #expect(receipt.unknownColumnIDs == ["custom.notInThisProject"])
    }

    @Test("The pure column rule arranges the named columns and keeps the rest in order")
    func theColumnRuleArrangesAndKeepsTheRest() {
        let columns = [
            LedgerColumn(id: "alpha", title: "Alpha", kind: .text, width: 100),
            LedgerColumn(id: "beta", title: "Beta", kind: .text, width: 100),
            LedgerColumn(id: "gamma", title: "Gamma", kind: .text, width: 100),
            LedgerColumn(id: "delta", title: "Delta", kind: .text, width: 100)
        ]
        let arranged = JobTemplateApplier.columns(
            applying: [
                JobTemplateColumnPreference(columnID: "gamma", visible: false),
                JobTemplateColumnPreference(columnID: "alpha", visible: true),
                JobTemplateColumnPreference(columnID: "missing", visible: true),
                JobTemplateColumnPreference(columnID: "gamma", visible: true)
            ],
            to: columns
        )
        #expect(arranged.map(\.id) == ["gamma", "alpha", "beta", "delta"])
        #expect(arranged[0].visible == false, "the first preference for a column wins; a duplicate does not reapply")
        #expect(arranged[1].visible == true)
        #expect(arranged[2].visible == true && arranged[3].visible == true, "columns the template does not name keep their state")
    }
}
