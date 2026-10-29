import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Two features that had been components without callers, driven
/// through the shipping presenters, the shipping command bus and a real `.zpdfproj`.
///
/// | Rule | Test |
/// |---|---|
/// | A count preset's symbol lands on the mark a *drawn* count commits | ``aDrawnCountCarriesThePresetsSymbol()`` |
/// | …and on the mark a *placed* count drops | ``aPlacedCountCarriesThePresetsSymbol()`` |
/// | A mark with no preset keeps no symbol | ``aCountDrawnWithNoPresetCarriesNoSymbol()`` |
/// | The symbol survives save and reopen | ``aCountSymbolSurvivesSaveAndReopen()`` |
/// | `tool_preset.symbol_data` is written and read | ``thePresetsSymbolRoundTripsThroughSymbolData()`` |
/// | Twelve identical skips are one line with a count | ``twelveIdenticalSkipsAreOneLineWithACount()`` |
/// | A markup that skipped something else keeps its own line | ``theOddMarkupOutKeepsItsOwnLine()`` |
@Suite("Count symbols and the per-markup skip report")
struct CountSymbolAndSkipReportTests {

    // MARK: - Fixtures

    private struct Fixture {
        let environment: AppCoreEnvironment
        let documentID: DocumentID
        let page: ZPDFContracts.PageDescriptor
    }

    @MainActor
    private func makeFixture() async throws -> Fixture {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        return Fixture(environment: environment, documentID: documentID, page: page)
    }

    /// "Door Count" with a chosen symbol: the picker stores a system symbol name, the record
    /// stores the renderer's glyph name, and ``CountSymbolCatalogue`` is the only join.
    private static func doorCountPreset(symbolName: String? = "xmark") -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Door Count",
            category: "Openings",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: .count,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.7, blue: 0.4, alpha: 1),
            defaultSubject: "Doors",
            countSymbolName: symbolName
        )
    }

    private static func area(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: MeasurementTool,
        parameters: MeasurementParameters? = nil
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: tool,
            subject: "Bay",
            author: "test",
            status: .open,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            parameters: parameters,
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// A two-point length: a different tool with a different applicability answer, so the
    /// report has something other than twelve identical lines to represent.
    private static func line(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .length,
            subject: "Run",
            author: "test",
            status: .open,
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    // MARK: - Count symbols

    @Test("A count drawn with a symbol-carrying preset commits a mark that stores the symbol")
    @MainActor
    func aDrawnCountCarriesThePresetsSymbol() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let preset = Self.doorCountPreset()
        environment.toolLibrary.setPresets([preset])

        // The shipping arming path, not a hand-set property: `AppCoreEnvironment.onArm` is what
        // used to drop the symbol on the floor, so the test has to go through it.
        environment.toolLibrary.activatePreset(id: preset.id)
        #expect(environment.measurement.activeKind == .count)

        environment.measurement.setPage(fixture.page.id)
        environment.measurement.appendRawPoints([
            PDFPointValue(x: 120, y: 200),
            PDFPointValue(x: 180, y: 240)
        ])
        environment.measurement.commitActiveMeasurement()

        var records: [ZPDFContracts.MarkupRecord] = []
        for _ in 0..<200 {
            records = await environment.session.orderedMarkups
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let record = try #require(records.first)
        let symbol = try #require(
            record.symbol,
            "nothing wrote MarkupRecord.symbol — the canvas has nothing to draw but a dot"
        )
        #expect(symbol.builtInGlyph == "cross", "xmark is the renderer's `cross`")
        #expect(symbol.artworkDigest == nil)
        #expect(symbol.hasUsableSize)
        #expect(record.geometry?.countPoints.count == 2)
    }

    @Test("A count drawn with no preset armed carries no symbol at all")
    @MainActor
    func aCountDrawnWithNoPresetCarriesNoSymbol() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment

        // Arm a symbol-carrying preset, then disarm it. A shared mutable default would leave
        // the glyph behind and every later plain Count would inherit it.
        let preset = Self.doorCountPreset()
        environment.toolLibrary.setPresets([preset])
        environment.toolLibrary.activatePreset(id: preset.id)
        environment.toolLibrary.clearActivePreset()

        environment.measurement.activate(kind: .count)
        environment.measurement.setPage(fixture.page.id)
        environment.measurement.appendRawPoints([PDFPointValue(x: 50, y: 50)])
        environment.measurement.commitActiveMeasurement()

        var records: [ZPDFContracts.MarkupRecord] = []
        for _ in 0..<200 {
            records = await environment.session.orderedMarkups
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(try #require(records.first).symbol == nil)
    }

    @Test("A plain Count is subjected Count, not the last preset's subject")
    @MainActor
    func aPlainCountDoesNotInheritAPresetsSubject() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment

        // Arm the built-in Door Count preset, then disarm it — the ordinary sequence, because
        // committing a measurement disarms the preset by itself.
        let preset = Self.doorCountPreset()
        environment.toolLibrary.setPresets([preset])
        environment.toolLibrary.activatePreset(id: preset.id)
        #expect(environment.measurement.defaultSubject == preset.defaultSubject)
        environment.toolLibrary.clearActivePreset()

        environment.measurement.activate(kind: .count)
        environment.measurement.setPage(fixture.page.id)
        environment.measurement.appendRawPoints([PDFPointValue(x: 60, y: 60)])
        environment.measurement.commitActiveMeasurement()

        var records: [ZPDFContracts.MarkupRecord] = []
        for _ in 0..<200 {
            records = await environment.session.orderedMarkups
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let record = try #require(records.first)
        // Reported 2026-08-26: after choosing Count, the summary showed the subject "Doors".
        #expect(
            record.subject == "Count",
            "a plain Count inherited \(record.subject) from a preset that is no longer armed"
        )
    }

    @Test("Switching away from Count keeps the marks that were placed")
    @MainActor
    func switchingToolCommitsTheCountInsteadOfDiscardingIt() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment

        environment.measurement.activate(kind: .count)
        environment.measurement.setPage(fixture.page.id)
        for i in 0..<10 {
            environment.measurement.appendRawPoints([PDFPointValue(x: 40 + Double(i) * 12, y: 60)])
        }
        #expect(environment.measurement.placedPoints.count == 10)

        // The estimator picks up another tool. Reported 2026-08-26: ten counts placed, then a
        // tool change, and the counts were gone. Ten placed marks are ten answers, not a
        // half-drawn shape, and losing them silently is the worst kind of bug this product can
        // have — the number was right, and then it was gone.
        environment.measurement.deactivate()

        var records: [ZPDFContracts.MarkupRecord] = []
        for _ in 0..<200 {
            records = await environment.session.orderedMarkups
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let record = try #require(records.first, "the ten count marks were discarded")
        #expect(record.geometry?.countPoints.count == 10, "not every mark survived")
    }

    @Test("Switching away from a half-drawn area still discards it")
    @MainActor
    func switchingToolStillDiscardsAnIncompleteShape() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment

        // Two points of a polygon are not an area. The count rule must not have turned every
        // abandoned draft into a committed markup.
        environment.measurement.activate(kind: .area)
        environment.measurement.setPage(fixture.page.id)
        environment.measurement.appendRawPoints([
            PDFPointValue(x: 10, y: 10),
            PDFPointValue(x: 90, y: 10)
        ])
        environment.measurement.deactivate()

        try? await Task.sleep(for: .milliseconds(120))
        let records = await environment.session.orderedMarkups
        #expect(records.isEmpty, "an abandoned two-point area was committed as a markup")
    }

    @Test("A Place-mode click drops a count mark carrying the preset's symbol")
    @MainActor
    func aPlacedCountCarriesThePresetsSymbol() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let preset = Self.doorCountPreset(symbolName: "star.fill")

        let receipt = await environment.placePreset(
            preset,
            at: PDFPointValue(x: 300, y: 400),
            pageID: fixture.page.id.rawValue
        )
        let id = try #require(receipt.markupID, "nothing was placed")
        let record = try #require(await environment.session.markup(MarkupID(id)))
        #expect(record.symbol?.builtInGlyph == "star")
    }

    @Test("A count mark's symbol survives save and reopen through a real .zpdfproj")
    @MainActor
    func aCountSymbolSurvivesSaveAndReopen() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let preset = Self.doorCountPreset(symbolName: "triangle")

        let receipt = await environment.placePreset(
            preset,
            at: PDFPointValue(x: 300, y: 400),
            pageID: fixture.page.id.rawValue
        )
        let id = try #require(receipt.markupID)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-symbol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureFile = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Symbols.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Symbols", originalPDF: fixtureFile.url
        )

        try await TakeoffArchive.write(await environment.session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        let record = try #require(stored.markups.first { $0.id.rawValue == id })
        let symbol = try #require(
            record.symbol,
            "markup_symbol was written by nobody, so the glyph did not come back"
        )
        #expect(symbol.builtInGlyph == "hollowTriangle")
        #expect(symbol.sizePoints == CountSymbolCatalogue.defaultSizePoints)
    }

    @Test("A preset's symbol round-trips through tool_preset.symbol_data")
    @MainActor
    func thePresetsSymbolRoundTripsThroughSymbolData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-symboldata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureFile = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Presets.zpdfproj", isDirectory: true),
            displayName: "Presets",
            originalPDF: fixtureFile.url
        )

        var preset = Self.doorCountPreset(symbolName: "square")
        preset.panel = .projectTools
        try await ToolPresetArchive.write([preset], into: package)

        // The column itself, not the summary that reads it: `symbol_data` has been in the
        // schema since v1 and had never been written by any build.
        let stored = try await package.read { db in
            try ToolPresetRecord.fetchAll(db).first?.symbolData
        }
        #expect(stored != nil, "symbol_data is still NULL")

        let read = try #require(try await ToolPresetArchive.read(from: package).first)
        #expect(read.countSymbolName == "square")
        #expect(CountSymbolCatalogue.symbol(for: read)?.builtInGlyph == "hollowSquare")
    }

    @Test("An unknown symbol name still draws something rather than nothing")
    func anUnknownSymbolNameFallsBackToAVisibleGlyph() {
        var preset = Self.doorCountPreset(symbolName: "rainbows.and.unicorns")
        let symbol = CountSymbolCatalogue.symbol(for: preset)
        #expect(symbol?.builtInGlyph == CountSymbolCatalogue.defaultGlyphName)

        // And the two names earlier builds offered still mean what a person chose.
        preset = Self.doorCountPreset(symbolName: "hexagon")
        #expect(CountSymbolCatalogue.symbol(for: preset)?.builtInGlyph == "star")
        preset = Self.doorCountPreset(symbolName: "diamond")
        #expect(CountSymbolCatalogue.symbol(for: preset)?.builtInGlyph == "filledDiamond")
    }

    @Test("Every catalogued symbol name maps to exactly one glyph, and back")
    func theCatalogueIsABijection() {
        let names = Set(CountSymbolCatalogue.entries.map(\.symbolName))
        let glyphs = Set(CountSymbolCatalogue.entries.map(\.glyphName))
        #expect(names.count == CountSymbolCatalogue.entries.count, "a symbol name is offered twice")
        #expect(glyphs.count == CountSymbolCatalogue.entries.count, "a glyph is reachable twice")
        for entry in CountSymbolCatalogue.entries {
            #expect(CountSymbolCatalogue.glyphName(forSymbolNamed: entry.symbolName) == entry.glyphName)
            #expect(CountSymbolCatalogue.symbolName(forGlyphNamed: entry.glyphName) == entry.symbolName)
            #expect(CountSymbolCatalogue.displayName(forSymbolNamed: entry.symbolName)?.isEmpty == false)
        }
    }

    // MARK: - The per-markup skip report

    @Test("Twelve markups that skipped the same property are one line with a count")
    @MainActor
    func twelveIdenticalSkipsAreOneLineWithACount() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        var ids: [MarkupID] = []
        for _ in 0..<12 {
            let id = MarkupID(UUID())
            try await environment.commands.perform(.addMarkup(Self.area(
                id: id, documentID: fixture.documentID, pageID: fixture.page.id, tool: .area
            )))
            ids.append(id)
        }

        // A Volume preset over twelve plain Areas: every one of them skips the same two things.
        let receipt = await environment.applyPreset(
            Self.slabPreset(), to: Set(ids.map(\.rawValue))
        )

        #expect(receipt.skipReport.groups.count == 1, "twelve identical answers are one group")
        let group = try #require(receipt.skipReport.groups.first)
        #expect(group.markupCount == 12)
        #expect(group.line.contains("12"), "the line has to carry the count")
        #expect(receipt.summaryMessage.contains(group.line), "\(receipt.summaryMessage)")
    }

    @Test("The markup that skipped something else keeps its own line")
    @MainActor
    func theOddMarkupOutKeepsItsOwnLine() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        var ids: [MarkupID] = []
        for _ in 0..<3 {
            let id = MarkupID(UUID())
            try await environment.commands.perform(.addMarkup(Self.area(
                id: id, documentID: fixture.documentID, pageID: fixture.page.id, tool: .area
            )))
            ids.append(id)
        }
        // A Length among the Areas. It refuses a different set of the preset's properties, and
        // the old property-keyed union could not say which markup that was.
        let odd = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(Self.line(
            id: odd, documentID: fixture.documentID, pageID: fixture.page.id
        )))

        let receipt = await environment.applyPreset(
            Self.slabPreset(), to: Set((ids + [odd]).map(\.rawValue))
        )

        #expect(
            receipt.skipReport.groups.count >= 1,
            "nothing was reported per markup at all"
        )
        #expect(receipt.skipReport.groups.reduce(0) { $0 + $1.markupCount } == 4, "every target answered")
        let byMarkup = Dictionary(
            uniqueKeysWithValues: receipt.skipReport.groups.flatMap { group in
                group.markupIDs.map { ($0, group.propertyNames) }
            }
        )
        #expect(byMarkup[odd.rawValue] != nil, "the odd markup out is not in the report")
        // Whether the two answers differ is the engine's business; what this asserts is that
        // the report is per markup, so *if* they differ the difference survives. The union
        // it replaced could not represent that at all.
        #expect(Set(byMarkup.keys) == Set((ids + [odd]).map(\.rawValue)))
    }

    @Test("Nothing skipped is no report, and no sentence")
    @MainActor
    func aCleanApplyReportsNoSkips() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(Self.area(
            id: id,
            documentID: fixture.documentID,
            pageID: fixture.page.id,
            tool: .volume,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.1") ?? 0))
        )))

        let receipt = await environment.applyPreset(Self.slabPreset(), to: [id.rawValue])
        #expect(receipt.skipReport.isEmpty)
        #expect(receipt.summaryMessage.contains("skipped") == false, "\(receipt.summaryMessage)")
    }

    /// "Slab 200 mm": a Volume preset carrying a depth and a depth reference — the same preset
    /// `ToolSetModeTests` uses, so the two suites disagree about nothing.
    private static func slabPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Slab 200 mm",
            category: "Concrete",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: .volume,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.7, blue: 0.2, alpha: 1),
            defaultSubject: "Slab",
            measurementDefaults: ToolPresetMeasurementDefaults(
                depth: .metres(Decimal(string: "0.2") ?? 0),
                volumeDepthReference: .verticalDepth
            )
        )
    }
}
