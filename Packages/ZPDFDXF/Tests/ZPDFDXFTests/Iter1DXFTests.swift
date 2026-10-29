import Foundation
import Testing
@testable import ZPDFDXF

/// Iteration 1: block expansion has a work budget and a cancellation point (R-192) that
/// charge the points drawn, not only the entities, and decodes each block member once (R-192
/// re-fix); the sheet writer groups entities by layer once (R-194).
@Suite("DXF — iteration 1")
struct Iter1DXFTests {

    private typealias Intake = DXFIntakeTests

    private static func block(_ name: String, _ body: String) -> String {
        "0\nBLOCK\n2\n\(name)\n10\n0\n20\n0\n" + body + "0\nENDBLK\n"
    }

    private static func insert(_ name: String, columns: Int, rows: Int) -> String {
        "0\nINSERT\n8\n0\n2\n\(name)\n10\n0\n20\n0\n70\n\(columns)\n71\n\(rows)\n44\n1\n45\n1\n"
    }

    @Test("R-192: nested arrays of an empty block are refused by the expansion budget, not run 10^8 times")
    func nestedEmptyArraysAreRefused() {
        // 100 × 100 instances of a block holding 100 × 100 instances of an empty block: 10^8
        // placements that draw nothing. `produced` never moves, so the old reader ran all of them.
        let blocks = Self.block("EMPTY", "") + Self.block("MID", Self.insert("EMPTY", columns: 100, rows: 100))
        let file = Intake.dxf(layers: ["0"], blocks: blocks,
                              entities: Self.insert("MID", columns: 100, rows: 100) + Intake.line("0", 0, 0, 1, 0))
        let limits = DXFLimits(maximumEntities: 10_000)
        #expect(limits.maximumExpansionSteps == 40_000)
        let started = Date()
        #expect(throws: DXFError.tooManyEntities(limit: 10_000)) { try DXFReader.read(file, limits: limits) }
        #expect(Date().timeIntervalSince(started) < 10, "refused in bounded time")
    }

    @Test("R-192: arrays of a block of skipped entity types are refused too")
    func arraysOfSkippedTypesAreRefused() {
        // A HATCH is only counted as skipped; a million of them used to cost a million visits
        // each time the array was placed, with nothing drawn.
        let blocks = Self.block("HATCHES", "0\nHATCH\n8\n0\n")
            + Self.block("MID", Self.insert("HATCHES", columns: 100, rows: 100))
        let file = Intake.dxf(layers: ["0"], blocks: blocks,
                              entities: Self.insert("MID", columns: 100, rows: 100) + Intake.line("0", 0, 0, 1, 0))
        #expect(throws: DXFError.tooManyEntities(limit: 10_000)) {
            try DXFReader.read(file, limits: DXFLimits(maximumEntities: 10_000))
        }
    }

    @Test("R-192: a cancelled read stops at the next cancellation point")
    func cancelledReadStops() async {
        let blocks = Self.block("EMPTY", "") + Self.block("MID", Self.insert("EMPTY", columns: 1_000, rows: 1_000))
        let file = Intake.dxf(layers: ["0"], blocks: blocks,
                              entities: Self.insert("MID", columns: 1_000, rows: 1_000) + Intake.line("0", 0, 0, 1, 0))
        let task = Task { try DXFReader.read(file) }
        task.cancel()
        // Old output: no cancellation point anywhere in ZPDFDXF — the read ran 10^12 placements.
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A legitimate array still expands in full, under the budget")
    func legitimateArrayExpands() throws {
        let dot = Self.block("DOT", Intake.line("0", 0, 0, 1, 0))
        let file = Intake.dxf(layers: ["0"], blocks: dot, entities: Self.insert("DOT", columns: 50, rows: 40))
        let (drawing, statistics) = try DXFReader.readCounting(file, limits: DXFLimits(maximumEntities: 2_000))
        // 50 × 40 = 2 000 lines, exactly the entity cap; 2 000 placements + 2 000 visits = 4 000
        // steps, half the 8 000 budget; 4 000 points; the block's line decoded once.
        #expect(drawing.entities.count == 2_000)
        #expect(statistics.steps == 4_000 && statistics.points == 4_000 && statistics.decoded == 2)
    }

    // MARK: - R-192 re-fix: the budget charges points, not only entities

    private static func lwpolyline(vertices: Int, bulge: Double = 0) -> String {
        var text = "0\nLWPOLYLINE\n8\n0\n90\n\(vertices)\n70\n0\n"
        for index in 0..<vertices { text += "10\n\(index)\n20\n\(index % 2)\n" + (bulge == 0 ? "" : "42\n\(bulge)\n") }
        return text
    }

    private static func placement(_ name: String, scaleY: Double = 1) -> String {
        "0\nINSERT\n8\n0\n2\n\(name)\n10\n0\n20\n0\n41\n1\n42\n\(scaleY)\n"
    }

    /// The read's outcome in a few words: a failing expectation must not print a drawing of
    /// millions of points.
    private static func outcome(_ file: Data, limits: DXFLimits = .standard) -> String {
        do {
            let (drawing, statistics) = try DXFReader.readCounting(file, limits: limits)
            return "accepted: \(drawing.entities.count) entities, \(statistics.points) points"
        } catch let error as DXFError {
            return "\(error)"
        } catch {
            return "other: \(error)"
        }
    }

    @Test("R-192 re-fix: a 2 000-vertex polyline in an array under the entity cap and the step budget is refused by the points budget, at once")
    func longPolylineArrayIsRefusedByPoints() {
        let limits = DXFLimits.standard
        let refusal = DXFError.tooManyPoints(limit: 50_000_000).description
        let poly = Self.block("POLY", Self.lwpolyline(vertices: 2_000))
        // The review's probe: 1 000 × 1 000 placements = 10^6 entities (exactly the cap) and
        // 2 × 10^6 steps (half the budget) — accepted before, at 2 × 10^9 points.
        #expect(limits.maximumEntities == 1_000_000 && limits.maximumExpansionSteps == 4_000_000)
        let probe = Intake.dxf(layers: ["0"], blocks: poly, entities: Self.insert("POLY", columns: 1_000, rows: 1_000))
        var started = Date()
        #expect(Self.outcome(probe) == refusal)
        #expect(Date().timeIntervalSince(started) < 1, "refused before the first placement")
        // 160 × 160 = 25 600 entities, 51 200 steps, 51.2 million points. The unfixed reader
        // accepted this after 52.9 s at 1.3 GB resident (debug build, run in this pass).
        let over = Intake.dxf(layers: ["0"], blocks: poly, entities: Self.insert("POLY", columns: 160, rows: 160))
        started = Date()
        #expect(Self.outcome(over) == refusal)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("R-192 re-fix: placements outside an array are charged one by one, up to the budget exactly")
    func separatePlacementsAreChargedToTheBudget() throws {
        let poly = Self.block("POLY", Self.lwpolyline(vertices: 2_000))
        let limits = DXFLimits(maximumPoints: 100_000)
        // 50 placements × 2 000 vertices = 100 000 points: exactly the budget.
        let fifty = Intake.dxf(layers: ["0"], blocks: poly, entities: String(repeating: Self.placement("POLY"), count: 50))
        let (drawing, statistics) = try DXFReader.readCounting(fifty, limits: limits)
        #expect(drawing.entities.count == 50)
        #expect(statistics.points == 100_000)
        // The 51st passes it. Each INSERT alone fits, so only the running total can refuse it.
        let fiftyOne = Intake.dxf(layers: ["0"], blocks: poly, entities: String(repeating: Self.placement("POLY"), count: 51))
        #expect(Self.outcome(fiftyOne, limits: limits) == DXFError.tooManyPoints(limit: 100_000).description)
    }

    @Test("R-192 re-fix: bulges sampled under a non-uniform scale are charged as they are sampled")
    func sampledBulgesAreCharged() throws {
        // Bulge 0.5 bends each segment by 4·atan(0.5) = 1.854590 rad; at π/64 a sample that is
        // ceil(37.78) = 38 steps, so 38 new points a segment. 1 000 vertices, open: 999 segments,
        // 1 + 999 × 38 = 37 963 points for one placement stretched 1 × 2.
        let arcs = Self.block("ARCS", Self.lwpolyline(vertices: 1_000, bulge: 0.5))
        let limits = DXFLimits(maximumPoints: 50_000)
        let once = Intake.dxf(layers: ["0"], blocks: arcs, entities: Self.placement("ARCS", scaleY: 2))
        let (drawing, statistics) = try DXFReader.readCounting(once, limits: limits)
        #expect(statistics.points == 37_963)
        if case let .polyline(points, _, _) = drawing.entities.first?.shape { #expect(points.count == 37_963) } else { Issue.record("no polyline") }
        // Twice is 75 926: refused, though the vertices alone (2 × 1 000) fit.
        let twice = Intake.dxf(layers: ["0"], blocks: arcs, entities: String(repeating: Self.placement("ARCS", scaleY: 2), count: 2))
        #expect(Self.outcome(twice, limits: limits) == DXFError.tooManyPoints(limit: 50_000).description)
    }

    @Test("R-192 re-fix: a cancelled read stops within 4 096 points, however few steps it takes")
    func cancelledReadStopsOnPoints() async {
        // 40 × 40 placements: 3 200 steps, under the 4 096 the old check waited for, and 3.2
        // million points. The unfixed reader ran it to the end with the task cancelled.
        let file = Intake.dxf(layers: ["0"], blocks: Self.block("POLY", Self.lwpolyline(vertices: 2_000)),
                              entities: Self.insert("POLY", columns: 40, rows: 40))
        let task = Task { try DXFReader.read(file).entities.count }
        task.cancel()
        var outcome = "other error"
        switch await task.result {
        case let .success(count): outcome = "completed: \(count) entities"
        case let .failure(error): if error is CancellationError { outcome = "cancelled" }
        }
        #expect(outcome == "cancelled")
    }

    @Test("R-192 re-fix: a block member is decoded once, however often the block is placed")
    func blockMembersAreDecodedOnce() throws {
        // 20 000 x values and no y: an LWPOLYLINE that draws nothing. Placed 2 500 times it was
        // parsed 2 500 times — 19.5 s in the unfixed reader, with no point drawn and no step
        // budget reached.
        var junk = "0\nLWPOLYLINE\n8\n0\n"
        for index in 0..<20_000 { junk += "10\n\(index)\n" }
        let file = Intake.dxf(layers: ["0"], blocks: Self.block("MIXED", junk + Intake.line("0", 0, 0, 1, 0)),
                              entities: Self.insert("MIXED", columns: 50, rows: 50) + Intake.line("0", 0, 0, 1, 0))
        let started = Date()
        let (drawing, statistics) = try DXFReader.readCounting(file, limits: .standard)
        #expect(Date().timeIntervalSince(started) < 2)
        // Model space: the INSERT and the LINE; the block: the junk and its LINE — four, once each.
        #expect(statistics.decoded == 4)
        #expect(drawing.entities.count == 2_501)
        // 2 500 placements + 2 500 visits of the drawn LINE; 2 points per line.
        #expect(statistics.steps == 5_000)
        #expect(statistics.points == 5_002)
    }

    @Test("Many layers read in bounded time; layer and type names are bounded before they are hashed per entity")
    func layersAndNamesAreBounded() throws {
        // 30 000 layers took 62.7 s in the unfixed reader (list membership, twice over).
        let names = (0..<30_000).map { "L\($0)" }
        let many = Intake.dxf(layers: names, entities: names.map { Intake.line($0, 0, 0, 1, 0) }.joined())
        let started = Date()
        #expect(try DXFReader.read(many).layers == names)
        #expect(Date().timeIntervalSince(started) < 5)
        // A 100 000-letter layer name, in the table and on the line, is kept as its first 255
        // letters in both places; a 1 000-letter entity type is reported as its first 255.
        let long = String(repeating: "W", count: 100_000)
        let odd = "0\n" + String(repeating: "Q", count: 1_000) + "\n8\n0\n"
        let drawing = try DXFReader.read(Intake.dxf(layers: [long], entities: Intake.line(long, 0, 0, 1, 0) + odd))
        #expect(drawing.layers == [String(repeating: "W", count: 255)])
        #expect(drawing.entities.first?.layer == String(repeating: "W", count: 255))
        #expect(drawing.skipped == [String(repeating: "Q", count: 255): 1])
    }

    @Test("R-194: the sheet keeps layer order, and entity order within each layer")
    func sheetGroupsByLayerInOrder() throws {
        let entities = Intake.line("B", 0, 0, 1, 0) + Intake.line("A", 0, 0, 2, 0)
            + Intake.line("B", 0, 0, 3, 0) + Intake.line("A", 0, 0, 4, 0)
        let drawing = try DXFReader.read(Intake.dxf(layers: ["A", "B"], entities: entities))
        #expect(drawing.layers == ["A", "B"])
        var options = DXFSheetWriter.Options()
        options.compress = false
        options.scaleDenominator = 1
        let sheet = try DXFSheetWriter.write(drawing, title: "order", options: options)
        let text = String(decoding: sheet.pdf, as: UTF8.self)
        let groups = text.components(separatedBy: "BDC\n").dropFirst().map { $0.components(separatedBy: "EMC")[0] }
        #expect(groups.count == 2)
        // Each layer's segments, in file order: A's run to x = 2 then 4 units, B's to 1 then 3
        // (1 unit = 1 mm at 1:1 = 72 / 25.4 pt, offset by the 10 mm margin).
        func endXs(_ group: String) -> [Double] {
            group.split(separator: "\n").filter { $0.hasSuffix(" l") }.compactMap { Double($0.split(separator: " ")[0]) }
        }
        let margin = 10.0 / 25.4 * 72, unit = 72.0 / 25.4
        #expect(endXs(groups[0]).map { (($0 - margin) / unit).rounded() } == [2, 4])
        #expect(endXs(groups[1]).map { (($0 - margin) / unit).rounded() } == [1, 3])
    }
}
