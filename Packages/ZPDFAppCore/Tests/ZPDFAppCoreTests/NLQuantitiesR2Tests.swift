import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFFormulaEngine
import ZPDFQuantityLedger

/// Quantities round 2, AppCore half: decimal feet and per-markup display units in the
/// one formatter (NL-MEASURE-10), and the report template's round-2 fields (NL-QTY-09/11/13).
@Suite("Quantities, round 2 — application core")
struct NLQuantitiesR2Tests {

    /// 3.81 m is exactly 12.5 ft (3.81 / 0.3048 = 12.5) and exactly 150 in (3.81 / 0.0254).
    static let length = Shown.Quantity(value: Decimal(string: "3.81")!, dimension: .length)

    @Test("Decimal feet renders 12.50 ft and never 12'-6\"; decimal inches 150.00 in")
    func decimalFeet() {
        let marks = QuantityFormatter(units: .imperial)
        #expect(marks.textWithUnit(Self.length) == "12'-6\"")

        let feet = QuantityFormatter(units: DisplayUnitSelection.imperial.withImperialLengthStyle(.decimalFeet))
        #expect(feet.text(Self.length) == "12.50")
        #expect(feet.textWithUnit(Self.length) == "12.50 ft")
        // The ledger's column set, and therefore every export, gets decimals too.
        #expect(feet.units.domainPolicy.precision == .decimalPlaces(2))
        #expect(feet.units.domainPolicy.length == .foot)

        let inches = QuantityFormatter(units: DisplayUnitSelection.imperial.withImperialLengthStyle(.decimalInches))
        #expect(inches.textWithUnit(Self.length) == "150.00 in")
        // Area is untouched by a length style: 1 m² = 10.763910… ft², two places.
        let area = Shown.Quantity(value: 1, dimension: .area)
        #expect(feet.textWithUnit(area) == "10.76 ft²")
        // From metric, decimal feet moves the length to the foot.
        #expect(DisplayUnitSelection.metric.withImperialLengthStyle(.decimalFeet).length == .foot)
    }

    @Test("A per-markup display policy formats through the same formatter: metres, 2 places, in an imperial project")
    func perMarkupPolicy() {
        let project = QuantityFormatter(units: .imperial)
        let rebar = project.overriding(DisplayUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre, precision: .decimalPlaces(2)))
        #expect(rebar.textWithUnit(Self.length) == "3.81 m")
        #expect(rebar.localeIdentifier == project.localeIdentifier)
        // A decimal precision on feet is decimal feet; a fraction precision is feet and inches.
        let decimalFeet = project.overriding(DisplayUnitPolicy(length: .foot, precision: .decimalPlaces(1)))
        #expect(decimalFeet.textWithUnit(Self.length) == "12.5 ft")
        let eighths = QuantityFormatter(units: .metric)
            .overriding(DisplayUnitPolicy(length: .foot, precision: .imperialFraction(.eighth)))
        // 1 m = 3.28084 ft = 3 ft 3.3701 in → nearest 1/8 is 3 3/8.
        #expect(eighths.textWithUnit(Shown.Quantity(value: 1, dimension: .length)) == "3'-3 3/8\"")
    }

    @Test("A template saved before round 2 reads back with every new field at its default")
    func oldTemplateDecodes() throws {
        let old = """
        {"id":"8B1D1C3A-6C57-4F0F-9F2A-2E6C1B0D9A11","name":"Old","format":"pdfReport","usesOnScreenView":true,
         "grouping":[],"columns":[],"pageSize":"a4","landscape":false,"includeCoverPage":true,
         "includeGroupHeadings":true,"includeGroupSubtotals":true,"footerNote":"x",
         "includeAuditTrail":false,"includeMeasurementTrace":false,"workbookSubtotalRows":true,
         "workbookRawColumns":false,"workbookLiveFormulas":false}
        """
        let template = try JSONDecoder().decode(LedgerReportTemplate.self, from: Data(old.utf8))
        #expect(template.name == "Old")
        #expect(template.companyBlock == "")
        #expect(template.logoDigest == nil)
        #expect(!template.includePageImages)
        #expect(template.matrixAxes == nil)
        #expect(!template.workbookGroupSheets)
    }

    @Test("The round-2 fields survive the store; the logo is kept once, by digest")
    func templateRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-r2-templates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerReportTemplateStore(directory: directory)
        let logo = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let digest = try store.saveLogo(logo)
        #expect(try store.saveLogo(logo) == digest, "same bytes, same file")
        #expect(digest.count == 64)
        #expect(store.logo(digest: digest) == logo)
        #expect(store.logo(digest: String(repeating: "0", count: 64)) == nil)
        #expect(store.logo(digest: "../../etc/passwd") == nil, "a digest is never a path")

        var template = LedgerReportTemplate(name: "Client summary", format: .pdfReport)
        template.companyBlock = "Zenit Group S.A.S.\nBogotá"
        template.logoDigest = digest
        template.includePageImages = true
        template.matrixRows = "subject"
        template.matrixColumns = "pageLabel"
        template.workbookGroupSheets = true
        try store.save(template)
        let read = try #require(try store.read().first)
        #expect(read.companyBlock == "Zenit Group S.A.S.\nBogotá")
        #expect(read.logoDigest == digest)
        #expect(read.includePageImages)
        #expect(read.workbookGroupSheets)
        #expect(read.matrixAxes?.rows == LedgerColumnID("subject"))
        #expect(read.matrixAxes?.columns == LedgerColumnID("pageLabel"))
        // The same grouping both ways is no matrix.
        template.matrixColumns = "subject"
        #expect(template.matrixAxes == nil)
    }
}

/// NL-QTY-07 round 2: a derived row selects its source on the canvas, and sits under it.
@Suite("Quantities, round 2 — assemblies")
@MainActor
struct NLQuantitiesR2AssemblyTests {

    @Test("Selecting a derived row selects its wall on the canvas; every derived row names the wall as its parent")
    func derivedRowSelectsItsSource() async throws {
        let base = NLQuantitiesAssemblyTests()
        let wall = try await base.makeWall()
        let assembly = try base.applier(wall)
        let timber = try #require(assembly.availableAssemblies.first { $0.name == "Timber stud wall" })
        let receipt = await assembly.applyAssembly(
            timber.id,
            parameters: ["Height": .init(value: Decimal(string: "2.4")!, dimension: .length),
                         "Spacing": .init(value: Decimal(string: "0.6")!, dimension: .length)],
            to: [wall.wall.rawValue]
        )
        #expect(!receipt.didFail)
        let ledger = wall.environment.ledger
        let derived = (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.filter { $0.markupID != wall.wall.rawValue }
        #expect(derived.count == 4)
        #expect(derived.allSatisfy { $0.parentID == wall.wall.rawValue }, "stepped in under the wall")

        // Old behaviour: the canvas was handed the derived row's own id, which no markup has,
        // and selected nothing.
        let stud = try #require(derived.first)
        ledger.select(rowIDs: [stud.markupID], additive: false)
        #expect(wall.environment.canvas.selectedMarkupIDs == [wall.wall.rawValue])
        // A measured row still selects itself.
        ledger.select(rowIDs: [wall.wall.rawValue], additive: false)
        #expect(wall.environment.canvas.selectedMarkupIDs == [wall.wall.rawValue])
        #expect(ledger.canvasSelection(for: [stud.markupID, wall.wall.rawValue]) == [wall.wall.rawValue])
    }
}

/// NL-QTY-07 round 2: office-library recipes, shared as `.zpdfassembly` files, carried in the
/// project.
@Suite("Quantities, round 2 — office assemblies")
@MainActor
struct NLQuantitiesR2OfficeAssemblyTests {

    /// Paint both faces of a wall: Length × Height × 2. A 10 m wall at 2.5 m is 10 × 2.5 × 2 = 50 m².
    static func paint() throws -> ZPDFFormulaEngine.AssemblyDefinition {
        ZPDFFormulaEngine.AssemblyDefinition(
            id: UUID(uuidString: "7C1B2F3E-1111-4A2B-9C3D-000000000001")!,
            name: "Painted wall",
            note: "Both faces.",
            inputs: [
                ZPDFFormulaEngine.AssemblyInput(name: "Length", dimension: .length),
                ZPDFFormulaEngine.AssemblyInput(name: "Height", dimension: .length)
            ],
            lines: [ZPDFFormulaEngine.AssemblyLine(name: "Paint", source: "Length * Height * 2", outputDimension: .area)]
        )
    }

    @Test("A recipe file round-trips; a file with a bad or built-in recipe is refused whole")
    func recipeFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-assemblies-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AssemblyRecipeLibrary(directory: directory)
        #expect(try library.read().isEmpty)
        let file = directory.appendingPathComponent("office.zpdfassembly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AssemblyRecipeLibrary.encode([try Self.paint()]).write(to: file)
        #expect(try library.importFile(at: file) == ["Painted wall"])
        #expect(try library.read().map(\.id) == [try Self.paint().id])
        // Importing again replaces, never duplicates.
        try library.importFile(at: file)
        #expect(try library.read().count == 1)

        let original = LedgerAssemblyLibrary.standard[0]
        let builtIn = ZPDFFormulaEngine.AssemblyDefinition(
            id: original.id, name: "Copy", note: nil, inputs: original.inputs, lines: original.lines
        )
        #expect(throws: AssemblyRecipeLibrary.Refusal.self) { try AssemblyRecipeLibrary.decode(try AssemblyRecipeLibrary.encode([builtIn])) }
        let paint = try Self.paint()
        let empty = ZPDFFormulaEngine.AssemblyDefinition(id: paint.id, name: paint.name, note: nil, inputs: paint.inputs, lines: [])
        #expect(throws: AssemblyRecipeLibrary.Refusal.self) { try AssemblyRecipeLibrary.decode(try AssemblyRecipeLibrary.encode([empty])) }
        #expect(throws: AssemblyRecipeLibrary.Refusal.self) { try AssemblyRecipeLibrary.decode(Data("{}".utf8)) }
    }

    @Test("An office recipe derives 50 m² from a 10 m wall at 2.5 m, and still does once the library is gone")
    func officeRecipeTravelsInTheProject() async throws {
        let base = NLQuantitiesAssemblyTests()
        let wall = try await base.makeWall()
        let ledger = wall.environment.ledger
        ledger.officeAssemblies = [try Self.paint()]
        let assembly = try base.applier(wall)
        #expect(assembly.availableAssemblies.map(\.name).contains("Painted wall"))
        let receipt = await assembly.applyAssembly(
            try Self.paint().id,
            parameters: ["Height": .init(value: Decimal(string: "2.5")!, dimension: .length)],
            to: [wall.wall.rawValue]
        )
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(base.derived(wall) == ["Paint": 50])

        // The library is not installed here any more: the rows still derive from the recipe the
        // project carries.
        ledger.officeAssemblies = []
        await ledger.refresh()
        #expect(base.derived(wall) == ["Paint": 50])
        #expect(!assembly.availableAssemblies.map(\.name).contains("Painted wall"))
    }
}
