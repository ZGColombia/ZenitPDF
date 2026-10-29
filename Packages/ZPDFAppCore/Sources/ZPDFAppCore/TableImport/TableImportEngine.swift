import Foundation
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Turns a user-chosen page rectangle into at most one ``TableImportProposal``.
///
/// Feature 31: a schedule printed on the sheet becomes ledger rows nobody types. The engine
/// stands on the two indexes the product already has — the recognised text lines that
/// `ScaleProposalEngine` also consumes, and the vector primitives of `ZPDFVectorExtraction`,
/// whose rule lines are the table's own grid.
///
/// Two jobs, both narrow:
///
/// 1. **Find the grid.** Vertical rule lines first; failing those, clustered text alignment.
///    A region that yields fewer than two columns is a typed ``TableImportRefusal``, never a
///    one-column guess presented confidently.
/// 2. **File the text.** Every recognised line lands in the cell whose row band and column
///    span contain its centre, verbatim. A cell with nothing in it stays empty and is
///    flagged (``TableImportCell/isUnread``), never invented.
///
/// It measures nothing. No scale is consulted, no geometry becomes a quantity, and the
/// proposal it emits is exactly as strong as what was printed on the sheet — which is the
/// whole point of ADR-0012's `.read` provenance on the rows an accepted proposal becomes.
public struct TableImportEngine: Hashable, Sendable {

    /// How far a rule line's endpoints may differ on the ruled axis and still count as
    /// straight, in points. Plotter output is exact; scanned-and-retraced grids are not.
    public let ruleAxisTolerance: Double
    /// The fraction of the region's extent a rule must span to count as table structure
    /// rather than an underline or a stray tick.
    public let minimumRuleSpanFraction: Double
    /// Rules closer together than this merge into one boundary, in points.
    public let boundaryMergeTolerance: Double
    /// A boundary closer than this to the region's edge is the table frame, not a column
    /// separator, in points.
    public let edgeTolerance: Double
    /// Leading edges of text lines closer together than this cluster into one alignment
    /// column, in points.
    public let alignmentTolerance: Double
    /// Text lines whose vertical centres sit within this of each other share a row band,
    /// in points.
    public let rowBandTolerance: Double

    /// Creates an engine. The defaults suit drawing schedules printed at typical text
    /// sizes (8–12 pt); every knob exists so a test can tighten or loosen one claim at
    /// a time.
    public init(
        ruleAxisTolerance: Double = 0.75,
        minimumRuleSpanFraction: Double = 0.6,
        boundaryMergeTolerance: Double = 3.0,
        edgeTolerance: Double = 4.0,
        alignmentTolerance: Double = 6.0,
        rowBandTolerance: Double = 4.0
    ) {
        self.ruleAxisTolerance = ruleAxisTolerance
        self.minimumRuleSpanFraction = minimumRuleSpanFraction
        self.boundaryMergeTolerance = boundaryMergeTolerance
        self.edgeTolerance = edgeTolerance
        self.alignmentTolerance = alignmentTolerance
        self.rowBandTolerance = rowBandTolerance
    }

    // MARK: - Entry points

    /// Proposes a table for the region, or refuses with a reason.
    ///
    /// - Parameters:
    ///   - region: the user-chosen rectangle, in canonical page space.
    ///   - recognisedLines: the page's recognised text, the same vocabulary
    ///     ``ScaleProposalEngine`` consumes. Lines outside the region are ignored; lines
    ///     inside it without bounds are carried as unplaced, never dropped silently.
    ///   - ruleLines: straight segments from the page's vector extraction. Pass
    ///     ``ruleLines(in:)``'s result when starting from a `VectorPageExtraction`.
    public func propose(
        region: PDFRectValue,
        recognisedLines: [RecognisedTextLine],
        ruleLines: [VectorLine]
    ) -> Result<TableImportProposal, TableImportRefusal> {
        guard region.size.width > 0, region.size.height > 0 else {
            return .failure(.emptyRegion)
        }

        // 1. The text inside the region, split by whether it can be placed.
        var placeable: [PlacedLine] = []
        var unplaced: [String] = []
        for line in recognisedLines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let bounds = line.boundsInPageSpace {
                if intersects(bounds, region) {
                    placeable.append(PlacedLine(text: trimmed, bounds: bounds))
                }
            } else {
                unplaced.append(trimmed)
            }
        }
        guard !placeable.isEmpty else {
            return .failure(
                unplaced.isEmpty ? .emptyRegion : .textWithoutPositions(lineCount: unplaced.count)
            )
        }

        // 2. Columns: the drawn grid first, text alignment second, refusal third.
        let verticalRuns = interiorBoundaryRuns(of: ruleLines, in: region, axis: .vertical)
        let horizontalRuns = interiorBoundaryRuns(of: ruleLines, in: region, axis: .horizontal)
        let interiorVerticals = verticalRuns.map(\.position)

        // L-64: a box drawn a little too large took the title above the table as a header row
        // and the margin beside it as an all-unread "Column 1". The drawn grid bounds the table:
        // text above or below its column rules, or beside its row rules, is not the table's.
        // Never everything — a grid that would leave no text keeps the box's text.
        var tableText = placeable
        if let bottom = verticalRuns.map(\.start).min(), let top = verticalRuns.map(\.end).max() {
            tableText = tableText.filter { $0.midY >= bottom - rowBandTolerance && $0.midY <= top + rowBandTolerance }
        }
        if let left = horizontalRuns.map(\.start).min(), let right = horizontalRuns.map(\.end).max() {
            tableText = tableText.filter { $0.midX >= left - edgeTolerance && $0.midX <= right + edgeTolerance }
        }
        if tableText.isEmpty { tableText = placeable }

        var columnSpans: [ClosedRange<Double>]
        let columnSource: TableImportColumnSource
        var alignmentClusterCount = 0
        if !interiorVerticals.isEmpty {
            columnSpans = spans(between: interiorVerticals, from: region.minX, to: region.maxX)
            // L-64: the space between the box's edge and the table's outer rule holds no text;
            // it is not a column, and its empty cells are not "cells that could not be read".
            while columnSpans.count > 2, let first = columnSpans.first,
                  !tableText.contains(where: { first.contains($0.midX) }) {
                columnSpans.removeFirst()
            }
            while columnSpans.count > 2, let last = columnSpans.last,
                  !tableText.contains(where: { last.contains($0.midX) }) {
                columnSpans.removeLast()
            }
            columnSource = .ruleLines
        } else {
            let clusters = alignmentClusters(of: tableText)
            alignmentClusterCount = clusters.count
            guard clusters.count >= 2 else {
                return .failure(.noColumnStructure(
                    interiorRuleCount: 0,
                    alignmentClusterCount: clusters.count
                ))
            }
            columnSpans = spans(
                between: columnCuts(for: clusters, lines: tableText, regionMinX: region.minX),
                from: region.minX,
                to: region.maxX
            )
            columnSource = .textAlignment
        }
        guard columnSpans.count >= 2 else {
            // The clusters the engine found are reported as found. This said 0 after the
            // clustering branch had already found two or more (BH-461).
            return .failure(.noColumnStructure(
                interiorRuleCount: interiorVerticals.count,
                alignmentClusterCount: alignmentClusterCount
            ))
        }

        // 3. Rows: horizontal rules when the grid has them, vertical clustering when not.
        let interiorHorizontals = horizontalRuns.map(\.position)
        let bands = rowBands(
            of: tableText,
            separators: interiorHorizontals,
            region: region
        )
        guard !bands.isEmpty else { return .failure(.noRows) }

        // 4. Cells, verbatim.
        let builtRows = bands.map { band in
            row(from: band, columnSpans: columnSpans)
        }

        // 5. Header: claimed only when the evidence is one-sided, absent otherwise.
        let headerRow: TableImportRow?
        var dataRows = builtRows
        // The first row is a ruled row when a drawn row rule runs between it and the second.
        let firstRowIsRuled: Bool = {
            guard builtRows.count >= 2,
                  let first = builtRows[0].boundsInPageSpace,
                  let second = builtRows[1].boundsInPageSpace else { return false }
            let firstMid = (first.minY + first.maxY) / 2
            let secondMid = (second.minY + second.maxY) / 2
            return interiorHorizontals.contains { $0 <= firstMid && $0 >= secondMid }
        }()
        if builtRows.count >= 2,
           readsAsHeader(first: builtRows[0], rest: builtRows.dropFirst(), firstRowIsRuled: firstRowIsRuled) {
            headerRow = builtRows[0]
            dataRows = Array(builtRows.dropFirst())
        } else {
            headerRow = nil
        }
        guard !dataRows.isEmpty else { return .failure(.noRows) }

        let columns = columnSpans.enumerated().map { index, span -> TableImportColumn in
            var headerText: String?
            if let headerRow, !headerRow.cells[index].isUnread {
                headerText = headerRow.cells[index].text
            }
            return TableImportColumn(
                index: index,
                minX: span.lowerBound,
                maxX: span.upperBound,
                headerText: headerText
            )
        }

        return .success(TableImportProposal(
            region: region,
            columns: columns,
            headerRow: headerRow,
            rows: dataRows,
            columnSource: columnSource,
            unplacedTexts: unplaced
        ))
    }

    /// The straight segments of a vector extraction, as the rule-line input of
    /// ``propose(region:recognisedLines:ruleLines:)``.
    ///
    /// Lines come through as they are; rectangles (the `re` operator — how many CAD
    /// exporters draw a table's cells) contribute their four edges. Curves contribute
    /// nothing: a curved edge is not table structure.
    public func ruleLines(in extraction: VectorPageExtraction) -> [VectorLine] {
        var lines: [VectorLine] = []
        for primitive in extraction.primitives {
            switch primitive.geometry {
            case .line(let line):
                lines.append(line)
            case .rectangle(let quad):
                lines.append(VectorLine(start: quad.c0, end: quad.c1))
                lines.append(VectorLine(start: quad.c1, end: quad.c2))
                lines.append(VectorLine(start: quad.c2, end: quad.c3))
                lines.append(VectorLine(start: quad.c3, end: quad.c0))
            case .cubic, .ring:
                continue
            }
        }
        return lines
    }

    // MARK: - Grid detection

    private enum Axis { case vertical, horizontal }

    /// One merged interior boundary: where it is on its axis, and the run it covers along the
    /// other axis — a column rule's bottom and top, a row rule's left and right.
    private struct BoundaryRun {
        var position: Double
        var start: Double
        var end: Double
    }

    /// The merged interior boundaries on one axis: x-positions of vertical rules,
    /// y-positions of horizontal ones. Frame lines at the region's edges are excluded —
    /// they bound the table, they do not divide it.
    private func interiorBoundaryRuns(
        of ruleLines: [VectorLine],
        in region: PDFRectValue,
        axis: Axis
    ) -> [BoundaryRun] {
        let regionSpan: ClosedRange<Double>
        let regionExtent: Double
        let interiorRange: ClosedRange<Double>
        switch axis {
        case .vertical:
            regionSpan = region.minY...region.maxY
            regionExtent = region.size.height
            interiorRange = (region.minX + edgeTolerance)...(region.maxX - edgeTolerance)
        case .horizontal:
            regionSpan = region.minX...region.maxX
            regionExtent = region.size.width
            interiorRange = (region.minY + edgeTolerance)...(region.maxY - edgeTolerance)
        }
        guard interiorRange.lowerBound < interiorRange.upperBound, regionExtent > 0 else {
            return []
        }

        // Collected per segment and merged per position *before* the span test. A CAD export
        // that draws one `re` per cell, or one short segment per cell edge, gives each piece a
        // run of one row's height — far under the span fraction — so every edge of a fully
        // ruled table used to be discarded and the engine fell back to text alignment
        // (BH-120). Collinear pieces now add up to the rule they draw.
        var segments: [(position: Double, start: Double, end: Double)] = []
        for line in ruleLines where !line.isDegenerate {
            let position: Double
            let runStart: Double
            let runEnd: Double
            switch axis {
            case .vertical:
                guard abs(line.start.x - line.end.x) <= ruleAxisTolerance else { continue }
                position = (line.start.x + line.end.x) / 2
                runStart = Swift.min(line.start.y, line.end.y)
                runEnd = Swift.max(line.start.y, line.end.y)
            case .horizontal:
                guard abs(line.start.y - line.end.y) <= ruleAxisTolerance else { continue }
                position = (line.start.y + line.end.y) / 2
                runStart = Swift.min(line.start.x, line.end.x)
                runEnd = Swift.max(line.start.x, line.end.x)
            }
            guard interiorRange.contains(position) else { continue }
            // Span inside the region, so a rule that continues past the selection still
            // counts only for the part the user selected.
            let clippedStart = Swift.max(runStart, regionSpan.lowerBound)
            let clippedEnd = Swift.min(runEnd, regionSpan.upperBound)
            guard clippedEnd > clippedStart else { continue }
            segments.append((position, clippedStart, clippedEnd))
        }
        guard !segments.isEmpty else { return [] }

        var positions: [BoundaryRun] = []
        var group: [(position: Double, start: Double, end: Double)] = []
        func flush() {
            guard !group.isEmpty else { return }
            // Union of the runs, bridging only gaps no wider than the merge tolerance.
            let runs = group.sorted { $0.start < $1.start }
            var covered = 0.0
            var currentStart = runs[0].start
            var currentEnd = runs[0].end
            for run in runs.dropFirst() {
                if run.start <= currentEnd + boundaryMergeTolerance {
                    currentEnd = Swift.max(currentEnd, run.end)
                } else {
                    covered += currentEnd - currentStart
                    currentStart = run.start
                    currentEnd = run.end
                }
            }
            covered += currentEnd - currentStart
            if covered >= minimumRuleSpanFraction * regionExtent {
                positions.append(BoundaryRun(
                    position: group.map(\.position).reduce(0, +) / Double(group.count),
                    start: runs[0].start,
                    end: runs.map(\.end).max() ?? runs[0].end
                ))
            }
            group = []
        }
        for segment in segments.sorted(by: { $0.position < $1.position }) {
            if let last = group.last, segment.position - last.position > boundaryMergeTolerance {
                flush()
            }
            group.append(segment)
        }
        flush()
        return merged(positions, tolerance: boundaryMergeTolerance)
    }

    /// Sorts and merges near-coincident boundaries into their mean position and the union of
    /// their runs.
    private func merged(_ boundaries: [BoundaryRun], tolerance: Double) -> [BoundaryRun] {
        guard !boundaries.isEmpty else { return [] }
        var result: [BoundaryRun] = []
        var cluster: [BoundaryRun] = []
        func close() {
            guard !cluster.isEmpty else { return }
            result.append(BoundaryRun(
                position: cluster.map(\.position).reduce(0, +) / Double(cluster.count),
                start: cluster.map(\.start).min() ?? 0,
                end: cluster.map(\.end).max() ?? 0
            ))
            cluster = []
        }
        for boundary in boundaries.sorted(by: { $0.position < $1.position }) {
            if let last = cluster.last, boundary.position - last.position > tolerance { close() }
            cluster.append(boundary)
        }
        close()
        return result
    }

    /// Column start positions from clustered leading edges of the text, for tables whose
    /// grid was never drawn. A cluster must hold at least two lines: one line starting
    /// somewhere is a line, not a column.
    private func alignmentClusters(of lines: [PlacedLine]) -> [(mean: Double, minimum: Double)] {
        let edges = lines.map(\.bounds.minX).sorted()
        var clusters: [(mean: Double, minimum: Double)] = []
        var cluster: [Double] = []
        func close() {
            if cluster.count >= 2, let first = cluster.first {
                clusters.append((cluster.reduce(0, +) / Double(cluster.count), first))
            }
            cluster = []
        }
        for edge in edges {
            if let last = cluster.last, edge - last > alignmentTolerance { close() }
            cluster.append(edge)
        }
        close()
        return clusters
    }

    /// Where each column after the first begins: in the whitespace before it, not at the mean
    /// of its leading edges.
    ///
    /// The mean sat inside the column. With left-aligned OCR jitter (edges 260, 262, 266) a
    /// narrow line starting at 260 had its centre left of the mean and was filed into the
    /// previous column; with a right-aligned quantity column, the wide value's lone leading edge
    /// was dropped as a one-line cluster, the cut sat at the narrow values' edge, and the wide
    /// value landed in the description cell (BH-119). The cut is now the middle of the
    /// right-most horizontal gap no text covers, between the previous cut and the cluster —
    /// the gutter a person sees between two columns — and the cluster's first leading edge
    /// when the text leaves no gap.
    private func columnCuts(
        for clusters: [(mean: Double, minimum: Double)],
        lines: [PlacedLine],
        regionMinX: Double
    ) -> [Double] {
        let covered = lines
            .map { (start: $0.bounds.minX, end: $0.bounds.maxX) }
            .sorted { $0.start < $1.start }
        var cuts: [Double] = []
        var lower = Swift.max(regionMinX, clusters.first?.minimum ?? regionMinX)
        for cluster in clusters.dropFirst() {
            let upper = cluster.mean
            var best: Double?
            var cursor = lower
            for interval in covered {
                guard interval.end > cursor else { continue }
                if interval.start > cursor {
                    let gapEnd = Swift.min(interval.start, upper)
                    if gapEnd > cursor { best = (cursor + gapEnd) / 2 }
                }
                cursor = Swift.max(cursor, interval.end)
                if cursor >= upper { break }
            }
            if cursor < upper { best = (cursor + upper) / 2 }
            let cut = best ?? cluster.minimum
            cuts.append(cut)
            lower = Swift.max(lower, cut)
        }
        return cuts
    }

    /// The column spans between interior boundaries, region edge to region edge.
    private func spans(
        between boundaries: [Double],
        from start: Double,
        to end: Double
    ) -> [ClosedRange<Double>] {
        let cuts = [start] + boundaries.filter { $0 > start && $0 < end } + [end]
        return zip(cuts, cuts.dropFirst()).compactMap { lower, upper in
            lower < upper ? lower...upper : nil
        }
    }

    // MARK: - Rows and cells

    private struct PlacedLine: Hashable {
        let text: String
        let bounds: PDFRectValue
        var midX: Double { (bounds.minX + bounds.maxX) / 2 }
        var midY: Double { (bounds.minY + bounds.maxY) / 2 }
    }

    /// Groups the placed lines into row bands, top row first.
    ///
    /// Horizontal rule boundaries win when the grid has them; otherwise lines cluster by
    /// vertical centre. Either way a band is a set of lines, and empty bands simply do
    /// not exist — an empty *cell* does (``TableImportCell/isUnread``), an empty row is
    /// nothing to import.
    private func rowBands(
        of lines: [PlacedLine],
        separators: [Double],
        region: PDFRectValue
    ) -> [[PlacedLine]] {
        if !separators.isEmpty {
            let cuts = [region.minY] + separators.sorted() + [region.maxY]
            var bands: [[PlacedLine]] = []
            // A line admitted because it overlaps the region but whose centre lies just outside
            // it is banded by its centre clamped into the region, and the top band's upper
            // bound is inclusive. It used to fall into no band at all and vanish from rows,
            // source text and unplaced text alike, while the no-rule path kept it (BH-462).
            func clampedMidY(_ line: PlacedLine) -> Double {
                Swift.min(Swift.max(line.midY, region.minY), region.maxY)
            }
            for (lower, upper) in zip(cuts, cuts.dropFirst()).reversed() {
                let isTop = upper >= region.maxY
                let band = lines.filter {
                    let y = clampedMidY($0)
                    return y >= lower && (y < upper || (isTop && y <= upper))
                }
                if !band.isEmpty { bands.append(band.sorted { $0.midX < $1.midX }) }
            }
            return bands
        }

        var bands: [[PlacedLine]] = []
        for line in lines.sorted(by: { $0.midY > $1.midY }) {
            if var band = bands.last,
               let anchor = band.first,
               abs(anchor.midY - line.midY) <= rowBandTolerance {
                band.append(line)
                bands[bands.count - 1] = band
            } else {
                bands.append([line])
            }
        }
        return bands.map { $0.sorted { $0.midX < $1.midX } }
    }

    /// Files one band's lines into cells by column span, verbatim.
    private func row(
        from band: [PlacedLine],
        columnSpans: [ClosedRange<Double>]
    ) -> TableImportRow {
        var cellLines = Array(repeating: [PlacedLine](), count: columnSpans.count)
        for line in band {
            if let index = columnSpans.firstIndex(where: { $0.contains(line.midX) }) {
                cellLines[index].append(line)
            }
        }
        let cells = cellLines.map { lines -> TableImportCell in
            let text = lines.map(\.text).joined(separator: " ")
            return TableImportCell(text: text, boundsInPageSpace: union(of: lines.map(\.bounds)))
        }
        return TableImportRow(
            cells: cells,
            sourceText: band.map(\.text).joined(separator: " "),
            boundsInPageSpace: union(of: band.map(\.bounds))
        )
    }

    /// Whether the topmost row reads as a header: none of its cells carries a digit (a unit
    /// such as "m2" or "m³" in a column name is not one), and either at least one lower row
    /// does, or the row is the grid's own first ruled row with every cell printed. Anything
    /// less one-sided is not claimed — a wrongly promoted header turns a data row into column
    /// names, which is a value silently lost.
    ///
    /// L-64: "Room | Area m2 | Floor | Finish" was read as data because of the 2 in "m2", so
    /// the columns stayed "Column 1–4", the header landed in the ledger as a row and the Area
    /// column, holding the word "Area m2", was suggested as Text.
    private func readsAsHeader(
        first: TableImportRow,
        rest: ArraySlice<TableImportRow>,
        firstRowIsRuled: Bool
    ) -> Bool {
        let digits = CharacterSet.decimalDigits
        let firstHasDigits = first.cells.contains {
            Self.withoutUnitTokens($0.text).rangeOfCharacter(from: digits) != nil
        }
        guard !firstHasDigits else { return false }
        let firstHasText = first.cells.contains { !$0.isUnread }
        guard firstHasText else { return false }
        if firstRowIsRuled, first.cells.allSatisfy({ !$0.isUnread }) { return true }
        return rest.contains { row in
            row.cells.contains { $0.text.rangeOfCharacter(from: digits) != nil }
        }
    }

    /// `text` without the area and volume units a column name carries — "m2", "m3", "mm2",
    /// "ft2", "m^2" — so their digit is not taken for a value.
    static func withoutUnitTokens(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)(?<![\p{L}\d])(mm|cm|dm|m|km|ft|in|yd)\^?[23](?![\p{L}\d])"#,
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - Geometry helpers

    private func intersects(_ a: PDFRectValue, _ b: PDFRectValue) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    private func union(of rects: [PDFRectValue]) -> PDFRectValue? {
        guard let first = rects.first else { return nil }
        var minX = first.minX
        var minY = first.minY
        var maxX = first.maxX
        var maxY = first.maxY
        for rect in rects.dropFirst() {
            minX = Swift.min(minX, rect.minX)
            minY = Swift.min(minY, rect.minY)
            maxX = Swift.max(maxX, rect.maxX)
            maxY = Swift.max(maxY, rect.maxY)
        }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
