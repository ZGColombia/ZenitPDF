import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFRenderer
@testable import ZPDFExport

/// Iteration 4: C-10 and the review items U-049, U-050,
/// U-051, U-054 and U-055. Each test says what the code before the fix wrote.
@Suite("Iteration 4 — PDF export", .sharedHeap, .serialized)
struct Iter4ExportPDFTests {

    static func lines(_ rendered: LedgerExportProfile.Rendered) -> [String] {
        String(decoding: rendered.data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: - U-049: one ledger column listed twice in a grouped profile

    @Test("U-049: a grouped profile listing Plan Area in m² and in ft² sums each row once")
    func groupedProfileWithARepeatedKeySumsOnce() throws {
        var profile = LedgerExportProfile(
            name: "Twice",
            columns: [
                .init(key: "subject", header: "Subject"),
                .init(key: "planArea", header: "Area m2", decimals: 3, unit: "m2"),
                .init(key: "planArea", header: "Area ft2", decimals: 3, unit: "ft2"),
            ],
            delimiter: ";", decimalSeparator: ".", encoding: .utf8, lineEnding: .lf
        )
        profile.grouping = .init(key: "subject", subtotals: true, subtotalLabel: "{group} subtotal", grandTotal: true, grandTotalLabel: "Total")
        let rendered = try profile.renderDetailed(try ExportFixture.projection(try ExportFixture.goldenReport()))
        // Plan areas (i+1)/8 m²; Concrete rows 0, 2, 4 = 0.125 + 0.375 + 0.625 = 1.125 m²
        // = 1.125 / 0.09290304 = 12.1094 ft²; Steel 0.25 + 0.5 + 0.75 = 1.5 m² = 16.1459 ft²;
        // together 2.625 m² = 28.2553 ft².
        // Old: every row added twice — "Concrete subtotal;2.250;24.219",
        // "Steel subtotal;3.000;32.292", "Total;5.250;56.511".
        #expect(Self.lines(rendered) == [
            "Subject;Area m2;Area ft2",
            "Concrete;0.125;1.345",
            "Concrete;0.375;4.036",
            "Concrete;0.625;6.727",
            "Concrete subtotal;1.125;12.109",
            "Steel;0.250;2.691",
            "Steel;0.500;5.382",
            "Steel;0.750;8.073",
            "Steel subtotal;1.500;16.146",
            "Total;2.625;28.255",
        ])
        #expect(rendered.unitMismatchKeys.isEmpty)
        #expect(rendered.missingKeys.isEmpty)
    }

    // MARK: - U-050: every contract unit is a profile unit

    @Test("U-050: every length, area and volume unit of the contract is a profile unit, with the contract's factor")
    func everyContractUnitIsAProfileUnit() throws {
        func check<Unit: DisplayUnit>(_: Unit.Type) {
            for unit in Unit.allCases {
                for spelling in [unit.rawValue, unit.symbol] {
                    // Old: nil for mi, km2/km², in2/in², acre, mi2/mi², cm3/cm³ and in3/in³.
                    let profileUnit = ProfileUnit(symbol: spelling)
                    #expect(profileUnit?.symbol == unit.rawValue, "\(spelling)")
                    #expect(profileUnit?.sizeInSI == unit.factorToBase, "\(spelling)")
                    #expect(profileUnit?.lengthPower == Unit.dimension.lengthPower, "\(spelling)")
                }
            }
        }
        check(LengthUnit.self)
        check(AreaUnit.self)
        check(VolumeUnit.self)
        // The extras the file format has always read.
        #expect(ProfileUnit(symbol: "pcs")?.lengthPower == 0)
        #expect(ProfileUnit(symbol: "sq ft")?.symbol == "ft2")
        #expect(ProfileUnit(symbol: "L")?.symbol == "l")
        #expect(ProfileUnit(symbol: "furlong") == nil)
        // 1 acre = 4046.8564224 m² exactly; 1 mi² = 2 589 988.110336 m².
        #expect(ProfileUnit(symbol: "acre")?.convert(fromSI: Decimal(string: "4046.8564224")!) == 1)
        #expect(ProfileUnit(symbol: "mi2")?.convert(fromSI: Decimal(string: "2589988.110336")!) == 1)
    }

    @Test("U-050: a profile column in acres validates and converts; a ledger column in acres converts its overridden rows")
    func acreColumnsExport() throws {
        // Footprints (i+1)·10 m²; / 4046.8564224 = 0.0024711, 0.0049421, 0.0074132, 0.0098842,
        // 0.0123553, 0.0148263 acres → six places.
        let expected = ["Subject;Acres", "Concrete;0.002471", "Steel;0.004942", "Concrete;0.007413",
                        "Steel;0.009884", "Concrete;0.012355", "Steel;0.014826"]
        let asked = LedgerExportProfile(
            name: "Acres", columns: [.init(key: "subject", header: "Subject"), .init(key: "footprint", header: "Acres", decimals: 6, unit: "acre")],
            delimiter: ";", decimalSeparator: ".", encoding: .utf8, lineEnding: .lf
        )
        // Old: ProfileError.invalid("“acre” is not a unit this build converts to …").
        #expect(try LedgerExportProfile.read(try asked.encoded()) == asked)
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let byProfile = try asked.renderDetailed(projection)
        #expect(Self.lines(byProfile) == expected)
        #expect(byProfile.unitMismatchKeys.isEmpty)

        // The ledger column shown in acres, its rows in ft² of their own (NL-MEASURE-10): no
        // profile unit, so each row converts back to the column's acres. Old: every cell empty
        // and "footprint" in unitMismatchKeys, because the hand-typed table had no acre.
        let columns = projection.table.columns.map { column in
            column.key != "footprint" ? column : ExportColumn(
                key: column.key, title: column.title, kind: column.kind, unitSymbol: "acre", decimalPlaces: 6,
                numberFormatCode: column.numberFormatCode, aggregationSemantics: column.aggregationSemantics,
                formulaCanonicalText: column.formulaCanonicalText, columnID: column.columnID
            )
        }
        let base = projection.table
        let acreTable = ExportTable(columns: columns, groups: base.groups, rows: base.rows, grandTotals: base.grandTotals,
                                    metadata: base.metadata, carriesRowTraces: base.carriesRowTraces,
                                    carriesProvenanceLabels: base.carriesProvenanceLabels)
        let own = LedgerExportProfile(
            name: "Own", columns: [.init(key: "subject", header: "Subject"), .init(key: "footprint", header: "Acres")],
            delimiter: ";", decimalSeparator: ".", encoding: .utf8, lineEnding: .lf
        )
        let byLedger = try own.renderDetailed(ExportProjection(table: acreTable, numberLocale: projection.numberLocale))
        #expect(Self.lines(byLedger) == expected)
        #expect(byLedger.unitMismatchKeys.isEmpty)
    }

    // MARK: - U-051: one copy of the painter's shared resources per sheet

    @Test("U-051: twenty translucent areas on one sheet share one copy of the painter's ICC profile and ExtGState")
    func annotatedExportCopiesSharedResourcesOnce() throws {
        let fill = RGBAColor(red: 0.1, green: 0.33, blue: 0.81, alpha: 0.5)
        let stroke = RGBAColor(red: 0.1, green: 0.33, blue: 0.81, alpha: 1)
        let annotations = (0..<20).map { index -> StandardAnnotation in
            let id = UUID()
            let x = 20 + Double(index % 5) * 70, y = 20 + Double(index / 5) * 60
            let outline = [PDFPoint(x: x, y: y), PDFPoint(x: x + 50, y: y), PDFPoint(x: x + 50, y: y + 40), PDFPoint(x: x, y: y + 40)]
            return StandardAnnotation(
                id: id, geometry: .polygon(outline), subject: "Area \(index)", stroke: stroke, fill: fill,
                appearance: [RenderableMarkup(id: MarkupID(id), shape: .filledPolygon(RenderPolygon(outer: outline)),
                                              style: RenderStyle(stroke: stroke, fill: fill, lineWidth: 1))]
            )
        }
        let source = LayeredSourceFixtures.plain()
        let page = StandardAnnotationPage(page: StandardAnnotationWriterTests.fixture().page, sourcePageIndex: 0, annotations: annotations)
        let produced = try StandardAnnotationWriter().data(source: source, pages: [page])
        #expect(produced.outcome.writtenAnnotationCount == 20)

        let before = try PDFDocumentScan(data: source)
        let scan = try PDFDocumentScan(data: produced.data)
        let added = scan.objects.filter { $0.key >= before.nextObjectNumber }.map(\.value.object)
        let iccProfiles = added.filter { object in
            guard case let .stream(dictionary, _) = object else { return false }
            return dictionary["N"] != nil && dictionary["Subtype"] == nil
        }
        // An ExtGState: a constant alpha and no /Subtype (the annotations carry /CA and /ca too).
        let graphicsStates = added.filter { object in
            guard let dictionary = object.dictionaryValue, dictionary["Subtype"] == nil else { return false }
            return dictionary["ca"] != nil || dictionary["CA"] != nil
        }
        // Old: a memo per annotation — 20 ICC profiles (≈ 2.6 KB each) and 20 ExtGStates.
        #expect(iccProfiles.count == 1)
        #expect(graphicsStates.count == 1)
        // Every form still carries its resources: each /AP /N form names a colour space.
        let forms = added.filter { object in
            guard case let .stream(dictionary, _) = object else { return false }
            return dictionary["Subtype"] == .name("Form")
        }
        #expect(forms.count == 20)
        #expect(forms.allSatisfy { form in
            guard case let .stream(dictionary, _) = form, let resources = dictionary["Resources"]?.dictionaryValue else { return false }
            return resources["ColorSpace"] != nil
        })
    }

    // MARK: - U-054: feet and inches name their units already

    @Test("U-054: a group keyed on a feet-and-inches column is headed 3'-4 13/16\", not 3'-4 13/16\" ft")
    func imperialGroupHeadingHasOneUnit() throws {
        // Old: "3'-4 13/16\" ft" and "40 13/16\" in" in every format that prints the label.
        let feet = try Fix2E1ProjectionTests.projection(try Fix2E1ProjectionTests.report(grouping: [Fix2E1ProjectionTests.runID]))
        #expect(feet.table.groups.map(\.label) == ["3'-4 13/16\""])
        #expect(feet.table.groups.map(\.printedLabel) == ["3'-4 13/16\""])
        let inches = try Fix2E1ProjectionTests.projection(try Fix2E1ProjectionTests.report(grouping: [Fix2E1ProjectionTests.runInchID]))
        #expect(inches.table.groups.map(\.label) == ["40 13/16\""])
        // A decimal column keeps its unit: 1.5 m and 2.25 m to three places.
        let metres = try Fix2E1ProjectionTests.projection(try Fix2E1ProjectionTests.report(grouping: [Fix2E1ProjectionTests.lengthID]))
        #expect(metres.table.groups.map(\.label) == ["1.500 m", "2.250 m"])
    }

    @Test("U-054: a snippet caption quoting a feet-and-inches value names no second unit")
    func imperialCaptionHasOneUnit() throws {
        let projection = try Fix2E1ProjectionTests.projection(try Fix2E1ProjectionTests.report())
        let id = MarkupID(ExportFixture.uuid(9_000))
        func caption(_ key: String) -> [String] {
            SnippetCaptionBuilder.build(
                detail: .compact, markupIDs: [id], projection: projection,
                source: SnippetSource(documentName: "E1", pageIndex: 0),
                options: SnippetCaptionOptions(valueColumnKey: key)
            ).lines
        }
        // The fixture's columns hold no label, so the caption names the subject alone.
        // Old: "Concrete: 3'-4 13/16\" ft" and "Concrete: 40 13/16\" in".
        #expect(caption("run") == ["Concrete: 3'-4 13/16\""])
        #expect(caption("runInches") == ["Concrete: 40 13/16\""])
        #expect(caption("length") == ["Concrete: 1.500 m"])
    }

    // MARK: - U-055: one formula guard for every workbook

    @Test("U-055: the ledger sheet quote-prefixes a subject that starts like a formula, through the one shared rule")
    func ledgerSheetFormulaGuard() throws {
        var markups: [MarkupRecord] = []
        for (index, subject) in ["=SUM(A1:A9)", "+Concrete", "Steel"].enumerated() {
            markups.append(MarkupRecord(
                id: MarkupID(ExportFixture.uuid(9_400 + index)),
                documentID: DocumentID(ExportFixture.uuid(-941)),
                pageID: PageID(ExportFixture.uuid(-942)),
                kind: .measurement, tool: .length, subject: subject, label: "G\(index)", author: "A. Berg",
                customValues: [Fix2E1ProjectionTests.lengthID: .number(.length(1))],
                createdAt: ExportFixture.epoch, modifiedAt: ExportFixture.epoch
            ))
        }
        let store = try LedgerStore(markups: markups, columns: try Fix2E1ProjectionTests.columns())
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(LedgerViewSpec()), title: "Guard")
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(try ExportProjector().project(report), to: url)
        let sheet = try XLSXInspector(url: url)
        // The cellXfs, in index order: a cell's style index names one of them.
        let cellXfs = try #require(sheet.stylesXML.range(of: "<cellXfs").flatMap { start in
            sheet.stylesXML.range(of: "</cellXfs>", range: start.upperBound..<sheet.stylesXML.endIndex).map { sheet.stylesXML[start.lowerBound..<$0.lowerBound] }
        })
        let formats = cellXfs.components(separatedBy: "<xf ").dropFirst().map { String($0) }
        func quoted(_ text: String) throws -> Bool {
            let cell = try #require(sheet.cells.first { $0.value == text }, "\(text)")
            // No `s` attribute is the default format, index 0.
            return formats[cell.styleIndex ?? 0].contains("quotePrefix=\"1\"")
        }
        #expect(XLSXTextTable.needsFormulaGuard("=SUM(A1:A9)"))
        #expect(try quoted("=SUM(A1:A9)"))
        #expect(try quoted("+Concrete"))
        #expect(try !quoted("Steel"))
    }

    // MARK: - C-10: one zone for a date group's bucket, label and heading

    /// Two markups either side of midnight in Stockholm, both on 1 September in UTC:
    /// 21:30Z is 23:30 on 1 September in Stockholm (CEST, UTC+2), 22:30Z is 00:30 on 2 September.
    static func nearMidnightReport(dayCalendar: Calendar) throws -> LedgerReport {
        let instants = [Fix2E1ProjectionTests.nearMidnight.addingTimeInterval(-3_600), Fix2E1ProjectionTests.nearMidnight]
        var markups: [MarkupRecord] = []
        for (index, instant) in instants.enumerated() {
            markups.append(MarkupRecord(
                id: MarkupID(ExportFixture.uuid(9_500 + index)),
                documentID: DocumentID(ExportFixture.uuid(-951)),
                pageID: PageID(ExportFixture.uuid(-952)),
                kind: .measurement, tool: .length, subject: "Wall", label: "D\(index)", author: "A. Berg",
                customValues: [Fix2E1ProjectionTests.lengthID: .number(.length(Decimal(index + 1)))],
                createdAt: instant, modifiedAt: instant
            ))
        }
        var plan = LedgerAggregationPlan()
        plan.add(AggregateKey(column: Fix2E1ProjectionTests.lengthID, function: .sum))
        let spec = LedgerViewSpec(
            grouping: [LedgerGroupingField(column: ExportFixture.standardID(.created))],
            aggregation: plan, dayCalendar: dayCalendar
        )
        let store = try LedgerStore(markups: markups, columns: try Fix2E1ProjectionTests.columns())
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch)).makeReport(store.makeView(spec), title: "Days")
    }

    @Test("C-10: a date group cut in Stockholm is labelled and headed with the Stockholm day, at a day boundary")
    func dateGroupsUseTheBucketZone() throws {
        let stockholm = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let report = try Self.nearMidnightReport(dayCalendar: ExportProjector.calendar(in: stockholm))
        #expect(report.metadata.dayTimeZone == stockholm)

        // Projected with the default (UTC) date zone. Old: labels "2026-08-31T22:00:00Z" and
        // "2026-09-01T22:00:00Z" — Stockholm midnights as UTC instants — headed "31 Aug 2026"
        // and "1 Sep 2026", each a day before the bucket it heads.
        let utcDates = try ExportProjector().project(report)
        #expect(utcDates.table.groups.map(\.label) == ["2026-09-01", "2026-09-02"])
        #expect(utcDates.table.groups.map(\.printedLabel) == ["1 Sep 2026", "2 Sep 2026"])
        #expect(utcDates.table.groups.map(\.rowCount) == [1, 1])

        // Projected in the ledger's zone, as the application does: every heading names the day
        // its date cells print.
        let local = try ExportProjector().project(report, options: ExportProjectionOptions(humanDateTimeZone: stockholm))
        let created = try Fix2E1ProjectionTests.index("created", in: local.table)
        for group in local.table.groups {
            for row in group.rows {
                guard case .date(let date) = row.cells[created] else {
                    Issue.record("created is not a date cell")
                    continue
                }
                #expect(date.humanText == group.printedLabel)
            }
        }
        let headings = PDFReportRenderer.flatten(table: local.table, options: PDFReportOptions()).compactMap { line -> String? in
            if case .groupHeading(let label, _, _) = line { return label }
            return nil
        }
        #expect(headings == ["1 Sep 2026", "2 Sep 2026"])
        // The parsed formats carry the same day.
        let csv = String(decoding: try CSVExporter().export(local), as: UTF8.self)
        #expect(csv.contains("2026-09-02"))
        #expect(!csv.contains("T22:00:00Z"))
    }

    @Test("C-10: the same two markups cut in UTC are one group, labelled and headed 1 September")
    func dateGroupsInUTCAreOneDay() throws {
        let report = try Self.nearMidnightReport(dayCalendar: ExportProjector.calendar(in: .gmt))
        let projection = try ExportProjector().project(report)
        #expect(projection.table.groups.map(\.label) == ["2026-09-01"])
        #expect(projection.table.groups.map(\.printedLabel) == ["1 Sep 2026"])
        #expect(projection.table.groups.map(\.rowCount) == [2])
    }
}
