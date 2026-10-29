import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Asserts that the mock sample project is internally consistent, so that every UI
/// package previewing against it is previewing against data that could really exist.
@Suite("Sample project consistency")
struct SampleProjectConsistencyTests {

    let project = ZenitSampleProject.shared

    /// Columns whose rows roll up into a total.
    var sumColumns: [LedgerColumn] {
        project.columns.filter { $0.dimension != nil && $0.aggregate == .sum }
    }

    // MARK: Shape

    @Test("Three sheets, two Scale Regions, forty markups, four zones")
    func sampleShape() {
        #expect(project.pages.count == 3)
        #expect(project.scaleRegions.count == 2)
        #expect(project.markups.count == 40)
        #expect(project.rows.count == 40)
        #expect(project.zones.count == 4)
        #expect(project.rootGroups.count == 4)
    }

    @Test("The takeoff covers counts, lengths, areas and volumes")
    func takeoffCoversEveryDimension() {
        var byDimension: [Int: Int] = [:]
        for markup in project.markups {
            guard let kind = markup.measurementKind else { continue }
            byDimension[kind.dimension.lengthPower, default: 0] += 1
        }
        #expect((byDimension[0] ?? 0) > 0, "counts")
        #expect((byDimension[1] ?? 0) > 0, "lengths")
        #expect((byDimension[2] ?? 0) > 0, "areas")
        #expect((byDimension[3] ?? 0) > 0, "volumes")
    }

    @Test("Four custom columns, exactly one of them a formula column")
    func customColumns() throws {
        let custom = project.columns.filter(\.id.isCustom)
        #expect(custom.count == 4)
        let formulaColumns = project.columns.filter { $0.kind == .formula }
        #expect(formulaColumns.count == 1)
        let formula = try #require(formulaColumns.first)
        #expect(formula.id == ZenitSampleProject.extendedCostColumn)
        #expect(formula.formulaSource == ZenitSampleProject.extendedCostFormula)
        #expect(formula.isEditable == false)
    }

    @Test("Column identifiers are unique")
    func columnIdentifiersAreUnique() {
        let ids = project.columns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Referential integrity

    @Test("Every markup points at a known page and zone")
    func markupsReferenceKnownPagesAndZones() throws {
        let pageLabels = Dictionary(uniqueKeysWithValues: project.pages.map { ($0.id, $0.label) })
        let zoneNames = Set(project.zones.map(\.name))

        for markup in project.markups {
            let storedLabel = pageLabels[markup.pageID]
            let label = try #require(storedLabel, "unknown page on \(markup.label)")
            #expect(markup.pageLabel == label)
            let zone = try #require(markup.zone)
            #expect(zoneNames.contains(zone), "unknown zone \(zone)")
        }
    }

    @Test("Zone markup counts match the markups")
    func zoneCounts() {
        for zone in project.zones {
            let actual = project.markups.filter { $0.zone == zone.name }.count
            #expect(zone.markupCount == actual, "zone \(zone.name)")
        }
    }

    @Test("Scale Regions live on known pages and have real polygons")
    func scaleRegionsAreWellFormed() {
        let pageIDs = Set(project.pages.map(\.id))
        for region in project.scaleRegions {
            #expect(pageIDs.contains(region.pageID))
            #expect(region.boundary.count >= 3)
            #expect(region.boundsInPageSpace != nil)
        }
    }

    @Test("Every ledger row maps to exactly one markup")
    func rowsMapToMarkups() {
        let markupIDs = Set(project.markups.map(\.id))
        for row in project.rows {
            #expect(markupIDs.contains(row.markupID))
        }
        #expect(Set(project.rows.map(\.markupID)).count == project.rows.count)
    }

    // MARK: Dimensional safety

    @Test("Every measurement field carries the dimension its field declares")
    func fieldDimensions() {
        for markup in project.markups {
            for field in markup.measurementFields {
                #expect(
                    field.quantity.dimension == field.field.dimension,
                    "\(markup.label) field \(field.field.rawValue)"
                )
            }
        }
    }

    @Test("Every markup carries its tool's primary field")
    func primaryFields() throws {
        for markup in project.markups {
            guard let kind = markup.measurementKind else { continue }
            let primary = try #require(markup.primaryField, "\(markup.label) has no primary field")
            #expect(primary.field == kind.primaryField)
            #expect(primary.quantity.dimension == kind.dimension)
        }
    }

    /// Every cell in a column must resolve to that column's dimension, or its total refuses to
    /// sum (ADR-0014, QUALITY_BAR 4.3).
    ///
    /// Two cases, and only one of them can disagree. A **stored quantity** carries a dimension
    /// of its own — it was measured — and must match the column it sits in. A **free-typed
    /// number** carries none, so the column's declaration supplies it; that half agrees by
    /// construction, which is exactly the rule ADR-0014 §3 asks for and is asserted here so a
    /// future change that reintroduces a per-cell guess is caught.
    @Test("Every quantity cell matches the dimension of its column")
    func cellDimensions() throws {
        let byID = Dictionary(uniqueKeysWithValues: project.columns.map { ($0.id, $0) })
        for row in project.rows {
            for (columnID, value) in row.values {
                let storedColumn = byID[columnID]
                let column = try #require(storedColumn, "unknown column \(columnID.rawValue)")
                guard let dimension = column.dimension else { continue }
                if case .quantity(let stored) = value {
                    #expect(stored.dimension == dimension, "column \(columnID.rawValue)")
                    continue
                }
                guard let resolved = value.asQuantity(inColumn: dimension) else { continue }
                #expect(resolved.dimension == dimension, "column \(columnID.rawValue)")
            }
        }
    }

    @Test("Incompatible dimensions refuse to be added")
    func incompatibleDimensionsThrow() throws {
        let length = DecimalQuantity.metres(3)
        let area = DecimalQuantity.squareMetres(3)
        let error = #expect(throws: QuantityError.self) { try length.adding(area) }
        #expect(error == .incompatibleDimensions(.length, .area))
        let sum = try length.adding(.metres(2))
        #expect(sum == DecimalQuantity.metres(5))
    }

    @Test("Unit factors are exact and conversions are dimension-checked")
    func unitFactors() throws {
        #expect(LengthUnit.foot.metresPerUnit == Decimal(string: "0.3048"))
        #expect(LengthUnit.inch.metresPerUnit == Decimal(string: "0.0254"))
        #expect(AreaUnit.squareFoot.squareMetresPerUnit == Decimal(string: "0.09290304"))
        #expect(VolumeUnit.cubicYard.cubicMetresPerUnit == Decimal(string: "0.764554857984"))

        let tenFeet = DecimalQuantity.metres(Decimal(string: "3.048") ?? 0)
        let feet = try tenFeet.converted(to: .foot)
        #expect(feet == 10)
        #expect(throws: QuantityError.self) { try tenFeet.converted(to: .squareMetre) }
    }

    // MARK: Totals

    @Test("Grand totals match an independent recomputation")
    func grandTotals() throws {
        for column in sumColumns {
            let contributions = project.rows.compactMap { $0.quantity(column.id) }
            guard !contributions.isEmpty else {
                #expect(project.grandTotals.total(column.id) == nil)
                continue
            }
            var expected = Decimal(0)
            for quantity in contributions {
                #expect(quantity.dimension == column.dimension)
                expected += quantity.value
            }
            let actual = try #require(
                project.grandTotals.total(column.id),
                "missing total for \(column.id.rawValue)"
            )
            #expect(actual.value == expected, "column \(column.id.rawValue)")
            #expect(actual.dimension == column.dimension)
        }
        #expect(project.grandTotals.rowCount == project.rows.count)
        #expect(project.grandTotals.incompatibleColumns.isEmpty)
    }

    @Test("Groups partition every row exactly once")
    func groupsPartitionRows() {
        let grouped = project.rootGroups.flatMap(\.allRows)
        #expect(grouped.count == project.rows.count)
        #expect(Set(grouped.map(\.markupID)) == Set(project.rows.map(\.markupID)))
    }

    @Test("Group totals add up to the grand totals")
    func groupTotalsAddUp() throws {
        // Summed by hand: `LedgerTotals.merging` was a second totals rule nothing shipping used,
        // removed with R-138.
        var rowCount = 0
        var sums: [LedgerColumnID: DecimalQuantity] = [:]
        for group in project.rootGroups {
            rowCount += group.totals.rowCount
            for column in sumColumns {
                guard let quantity = group.totals.total(column.id) else { continue }
                sums[column.id] = try sums[column.id].map { try $0.adding(quantity) } ?? quantity
            }
        }
        #expect(rowCount == project.grandTotals.rowCount)
        for column in sumColumns {
            #expect(
                sums[column.id]?.value == project.grandTotals.total(column.id)?.value,
                "column \(column.id.rawValue)"
            )
            #expect(sums[column.id]?.dimension == project.grandTotals.total(column.id)?.dimension)
        }
    }

    @Test("Each group total matches its own rows")
    func groupTotalsMatchTheirRows() throws {
        for group in project.rootGroups {
            #expect(group.totals.rowCount == group.rows.count, "group \(group.title)")
            for column in sumColumns {
                let contributions = group.rows.compactMap { $0.quantity(column.id) }
                guard !contributions.isEmpty else { continue }
                var expected = Decimal(0)
                for quantity in contributions { expected += quantity.value }
                let actual = try #require(group.totals.total(column.id))
                #expect(actual.value == expected, "\(group.title) / \(column.id.rawValue)")
            }
        }
    }

    // MARK: Cost arithmetic

    @Test("Total Cost is Unit Cost times the primary quantity")
    func totalCostArithmetic() throws {
        for row in project.rows {
            let kind = try #require(row.measurementKind)
            let primaryColumn = ZenitSampleProject.column(for: kind.primaryField)
            let primary = try #require(row.quantity(primaryColumn), "row \(row.markupID)")
            let unitCost = try #require(row.quantity(.unitCost))
            let totalCost = try #require(row.quantity(.totalCost))

            #expect(totalCost.value == unitCost.value * primary.value)
            #expect(totalCost.dimension == .currency(project.currencyCode))
        }
    }

    @Test("The formula column matches the source it declares")
    func formulaColumnArithmetic() throws {
        for row in project.rows {
            let totalCost = try #require(row.quantity(.totalCost))
            let waste = try #require(row.quantity(ZenitSampleProject.wasteFactorColumn))
            let extended = try #require(row.quantity(ZenitSampleProject.extendedCostColumn))

            #expect(extended.value == totalCost.value * (1 + waste.value))
            #expect(extended.value >= totalCost.value)
            #expect(extended.dimension == .currency(project.currencyCode))
        }
    }

    @Test("Display strings agree with the stored values")
    func displayStrings() {
        for row in project.rows {
            for column in sumColumns {
                guard let quantity = row.quantity(column.id) else { continue }
                #expect(
                    row.displayValue(column.id) == SampleFormatting.string(quantity),
                    "column \(column.id.rawValue)"
                )
            }
        }
    }

    // MARK: Vocabulary coverage

    @Test("The tool, snap and column vocabularies are complete")
    func vocabularies() {
        #expect(MeasurementKind.allCases.count == 22)
        #expect(SnapCandidateKind.allCases.count == 17)
        #expect(LedgerColumnID.standardColumns.count == 39)
        #expect(Set(LedgerColumnID.standardColumns).count == 39)

        for kind in MeasurementKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.shortHelp.isEmpty)
            #expect(kind.minimumPointCount >= 1)
        }
        for kind in SnapCandidateKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.symbolName.isEmpty)
        }
        for field in MeasurementField.allCases {
            #expect(!field.displayName.isEmpty)
        }
    }

    @Test("The palette uses the approved hex values")
    func palette() {
        #expect(ColorRGBA.Zenit.Dark.background.hexString == "#101317")
        #expect(ColorRGBA.Zenit.Dark.surface.hexString == "#171B21")
        #expect(ColorRGBA.Zenit.Dark.elevated.hexString == "#202630")
        #expect(ColorRGBA.Zenit.Dark.text.hexString == "#F5F7F9")
        #expect(ColorRGBA.Zenit.Dark.secondary.hexString == "#9DA8B4")
        #expect(ColorRGBA.Zenit.Dark.cyan.hexString == "#50D6DE")
        #expect(ColorRGBA.Zenit.Dark.blue.hexString == "#6E9FFF")
        #expect(ColorRGBA.Zenit.Dark.green.hexString == "#4FD095")
        #expect(ColorRGBA.Zenit.Dark.warning.hexString == "#EFB957")
        #expect(ColorRGBA.Zenit.Dark.danger.hexString == "#F0616E")
        #expect(ColorRGBA.Zenit.Dark.selection.hexString == "#2B6CB0")
        #expect(abs(ColorRGBA.Zenit.Dark.border.alpha - 0.10) < 0.0001)
        #expect(ColorRGBA.Zenit.Light.background.hexString == "#F3F5F7")
        #expect(ColorRGBA.Zenit.Light.surface.hexString == "#FFFFFF")
        #expect(ColorRGBA.Zenit.Light.elevated.hexString == "#E9EEF2")
        #expect(ColorRGBA.Zenit.Light.border.hexString == "#D3DCE3")
        #expect(ColorRGBA.Zenit.Light.text.hexString == "#11171D")
        #expect(ColorRGBA.Zenit.Light.secondary.hexString == "#5E6B77")
        #expect(ColorRGBA.Zenit.Light.cyan.hexString == "#087D84")
        #expect(ColorRGBA.Zenit.Light.blue.hexString == "#245FAF")
    }

    // MARK: Codable

    @Test("Value types survive a Codable round trip")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let row = try #require(project.rows.first)
        let decodedRow = try decoder.decode(LedgerRow.self, from: encoder.encode(row))
        #expect(decodedRow == row)

        let markup = try #require(project.markups.first)
        let decodedMarkup = try decoder.decode(MarkupSummary.self, from: encoder.encode(markup))
        #expect(decodedMarkup == markup)

        let group = try #require(project.rootGroups.first)
        let decodedGroup = try decoder.decode(LedgerGroupNode.self, from: encoder.encode(group))
        #expect(decodedGroup == group)

        let column = try #require(project.columns.last)
        let decodedColumn = try decoder.decode(LedgerColumn.self, from: encoder.encode(column))
        #expect(decodedColumn == column)

        let page = try #require(project.pages.last)
        let decodedPage = try decoder.decode(PageDescriptor.self, from: encoder.encode(page))
        #expect(decodedPage == page)
    }

    @Test("Ledger column identifiers encode as JSON object keys")
    func columnIDsEncodeAsKeys() throws {
        let values: [LedgerColumnID: LedgerCellValue] = [.subject: .text("Floor Screed")]
        let data = try JSONEncoder().encode(values)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"subject\""), "\(json)")
    }
}
