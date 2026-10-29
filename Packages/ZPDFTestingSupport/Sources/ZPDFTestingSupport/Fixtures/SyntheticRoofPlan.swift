import Foundation

/// The Synthetic Roof Plan — a construction sheet drawn from scratch, standing in for a real
/// one in every test that needs a heavy, realistic A1 drawing.
///
/// Every coordinate below is a design decision, written down before any engine looked at the
/// sheet. The values a test asserts — areas, centres, counts — are derived by hand from these
/// coordinates in `FIXTURES.md` and in the tests' own comments; none was read back from the
/// code under test.
///
/// # What is on the sheet
///
/// One A1 landscape page, `/MediaBox` = `/CropBox` = `[0 0 2383.94 1683.78]`, no optional
/// content, drawn at a nominal 1:50:
///
/// - a **hip roof** over a 600 × 1000 pt house, its north-east hip kinked so the east facet is
///   a five-cornered ring;
/// - a **snow-guard strip** inside the east facet, tied to the eave by one short stub;
/// - **dash-dot grid axes**, three horizontal and two vertical, written one stroke per dash and
///   per dot, each axis labelled in a circle;
/// - a **sedum-roofed annex** split into three faces by two hip lines, each face covered by
///   three-stroke glyphs on a triangular lattice — 4 695 glyphs, 14 085 short strokes, each in
///   its own `q … Q` group with its own graphics state, line width and colour;
/// - three **double-frame symbols** marked "TH" (one turned a quarter), and two distractors;
/// - a **100 mm control ruler** — 100 × 72 / 25.4 = 36000/127 pt of paper, 5 000 mm at 1:50;
/// - a **free measuring band** between the roof plan and the title column that no linework
///   comes within 40 pt of;
/// - a **fictional title block** whose text runs reproduce a real title block's reading
///   order: "SKALA" over "1:50", and "KV" beside "1:10 EXEMPELPARK";
/// - two **masked RGB rasters** in the title block, a graphic scale bar and a north arrow;
/// - a **paved forecourt** and two **boundary fences**, where nothing is traced or measured:
///   load, so the sheet holds as many painted paths as the real CAD-exported A1 whose raster
///   cost the viewer budgets were measured on (`FIXTURES.md`, "Calibration").
///
/// # Identity
///
/// The bytes are deterministic: no clock, no randomness, no platform compressor. Raster data
/// is run-length encoded by this package, content streams are stored uncompressed. A change
/// to any byte bumps ``version`` and the pinned ``sha256`` / ``byteCount``, which the
/// CORE_LOOP acceptance gate checks independently.
public enum SyntheticRoofPlan {

    // MARK: - Identity

    /// Bumped whenever a byte of `synthetic-roof-plan.pdf` changes.
    public static let version = 1
    /// `"synthetic-roof-plan/<version>"`, printed by the acceptance gate's open marker.
    public static var identityName: String { "synthetic-roof-plan/\(version)" }
    /// SHA-256 of `synthetic-roof-plan.pdf` at ``version``, lowercase hex.
    public static let sha256 = "424c2fad6aa7284bcdc410d9c209c24d10e7eac8b4d1027dd4fd1b2952295d44"
    /// Size of `synthetic-roof-plan.pdf` at ``version``, in bytes.
    public static let byteCount = 1398025

    // MARK: - Sheet

    /// ISO A1 landscape: 841 × 594 mm = 2383.94 × 1683.78 pt (rounded to 0.01 pt, as CAD
    /// exports write it).
    public static let pageBox = FixtureRect(llx: 0, lly: 0, urx: 2383.94, ury: 1683.78)
    /// The drawn sheet border, 14 pt inside the page edge.
    public static let border = FixtureRect(llx: 14, lly: 14, urx: 2369.94, ury: 1669.78)
    /// The printed scale the sheet is drawn at.
    public static let scaleDenominator = 50.0
    /// Metres of building per point of paper at 1:50: 50 × 0.0254 / 72 = 1.27 / 72.
    public static let metresPerPoint = 1.27 / 72
    /// The title column's left edge; the title block is its lower part, the notes its upper.
    public static let titleColumnLeft = 2050.0
    /// Where the title block ends and the notes column begins.
    public static let titleBlockTop = 640.0

    // MARK: - The control ruler

    /// 100 mm of paper: 100 × 72 / 25.4 = 36000 / 127 = 283.46456692913387 pt.
    public static let rulerLength = 36000.0 / 127.0
    /// The ruler's base line runs from here …
    public static let rulerLeft = FixturePoint(1050, 42)
    /// … to here: x = 1050 + 36000/127, evaluated as one correctly rounded `Double` addition.
    public static let rulerRight = FixturePoint(1050 + 36000.0 / 127.0, 42)
    /// Tick height, 5 mm: 1800 / 127 pt.
    public static let rulerTickHeight = 1800.0 / 127.0
    /// The eleven ticks' x, every 10 mm: 1050 + 3600·k / 127 for k = 0 … 10.
    public static var rulerTickXs: [Double] { (0...10).map { 1050 + Double(3600 * $0) / 127.0 } }

    // MARK: - The free measuring band

    /// Nothing is drawn inside this rectangle, and nothing within 40 pt of it except the title
    /// column's divider at x = 2050 (5 pt beyond its right edge, 21.5 pt beyond the furthest
    /// point a test picks). A snap therefore never moves a vertex picked inside it.
    public static let freeBand = FixtureRect(llx: 1720, lly: 520, urx: 2045, ury: 1200)

    // MARK: - The hip roof

    /// The house's eave rectangle.
    public static let eave = FixtureRect(llx: 900, lly: 300, urx: 1500, ury: 1300)
    /// The ridge runs north–south from its foot to its head.
    public static let ridgeFoot = FixturePoint(1200, 600)
    public static let ridgeHead = FixturePoint(1200, 1000)
    /// The north-east hip's kink, so the east facet is five-cornered.
    public static let hipKink = FixturePoint(1340, 1120)

    /// The east facet, counter-clockwise from the ridge foot: area 207 000 pt².
    public static var eastFacet: [FixturePoint] {
        [ridgeFoot, FixturePoint(1500, 300), FixturePoint(1500, 1300), hipKink, ridgeHead]
    }
    /// The south facet: a triangle of area 90 000 pt².
    public static var southFacet: [FixturePoint] {
        [FixturePoint(900, 300), FixturePoint(1500, 300), ridgeFoot]
    }
    /// The west facet: a trapezoid of area 210 000 pt².
    public static var westFacet: [FixturePoint] {
        [FixturePoint(900, 300), ridgeFoot, ridgeHead, FixturePoint(900, 1300)]
    }
    /// The north facet: area 93 000 pt².
    public static var northFacet: [FixturePoint] {
        [ridgeHead, hipKink, FixturePoint(1500, 1300), FixturePoint(900, 1300)]
    }

    /// The snow-guard strip inside the east facet, 3 × 280 pt = 840 pt².
    public static let snowGuard = FixtureRect(llx: 1483, lly: 480, urx: 1486, ury: 760)
    /// The one line tying the strip to the eave.
    public static let snowGuardStub = (start: FixturePoint(1486, 620), end: FixturePoint(1500, 620))

    // MARK: - Grid axes

    /// The dash-dot linetype, written one stroke per element: a 20 pt dash, a 3.5 pt gap, a
    /// 5 pt dot, a 3.5 pt gap — period 32 pt.
    public static let axisDash = 20.0
    public static let axisDot = 5.0
    public static let axisGap = 3.5
    /// Horizontal axes A, B, C: each at its y, from x = `from` to x = `to`, labelled at its east
    /// end. Each axis starts where it does so that no dash or dot ends within 4 pt of an eave, a
    /// hip, the ridge, the snow guard, the annex outline or a symbol: every element either crosses
    /// a line well clear of its own ends or stops more than the 3 pt bridging tolerance short of
    /// it, so no traced facet gains or loses a sliver to an axis.
    /// Each starts inside the west facet and runs well past the east eave: the tracer reads a
    /// dash-dot line through a room as an axis only when the pattern goes on past both walls it
    /// crosses (`DashedLineProbe`), and the annex leaves no room for that west of the house.
    /// 640 pt = 20 periods = 40 elements each.
    public static let horizontalAxes: [(name: String, y: Double, from: Double, to: Double)] = [
        ("A", 456, 917.25, 1557.25), ("B", 800, 908, 1548), ("C", 1150, 910.5, 1550.5)
    ]
    /// Vertical axes 1, 2: each at its x, from y = `from` to y = `to`, labelled at its north end.
    /// 1140 pt = 35 periods + a whole 20 pt dash = 71 elements each.
    public static let verticalAxes: [(name: String, x: Double, from: Double, to: Double)] = [
        ("1", 1000, 230, 1370), ("2", 1406, 228, 1368)
    ]
    /// Axis label circles: radius 12, centred 20 pt beyond the axis's labelled end — the east end of
    /// a horizontal axis, the north end of a vertical one.
    public static let axisLabelRadius = 12.0

    /// The axis's elements as `[start, end]` along its own coordinate: from `from`, a dash,
    /// then alternately a gap and a dot or a dash, the last element cut at `to`.
    public static func axisElements(from: Double, to: Double) -> [(start: Double, end: Double)] {
        var result: [(Double, Double)] = []
        var position = from
        var isDash = true
        while position < to {
            let length = isDash ? axisDash : axisDot
            result.append((position, Swift.min(position + length, to)))
            position += length + axisGap
            isDash.toggle()
        }
        return result
    }

    // MARK: - The sedum annex

    /// The annex's outline.
    public static let sedumRoof = FixtureRect(llx: 460, lly: 300, urx: 880, ury: 1300)
    /// Its two hip lines, at 45° from the west corners.
    public static let sedumLowerHip = (start: FixturePoint(460, 300), end: FixturePoint(880, 720))
    public static let sedumUpperHip = (start: FixturePoint(460, 1300), end: FixturePoint(880, 880))
    /// The middle face between the hips: a trapezoid of area 243 600 pt².
    public static var sedumMiddleFace: [FixturePoint] {
        [FixturePoint(460, 300), FixturePoint(880, 720), FixturePoint(880, 880), FixturePoint(460, 1300)]
    }
    /// The lower face: a triangle of area 88 200 pt².
    public static var sedumLowerFace: [FixturePoint] {
        [FixturePoint(460, 300), FixturePoint(880, 300), FixturePoint(880, 720)]
    }
    /// The upper face: a triangle of area 88 200 pt².
    public static var sedumUpperFace: [FixturePoint] {
        [FixturePoint(460, 1300), FixturePoint(880, 880), FixturePoint(880, 1300)]
    }

    /// One hatch glyph: three strokes from its base point, to the left, up and to the right.
    /// Neighbouring tips are √(2.125² + 1.25²) = 2.4654 pt apart; the outer two 4.25 pt.
    public static let glyphProngs: [FixturePoint] = [
        FixturePoint(-2.125, 1.25), FixturePoint(0, 2.5), FixturePoint(2.125, 1.25)
    ]
    /// Rows of the triangular lattice: y = 305 + 5·r for r = 0 … 197.
    public static let glyphRowCount = 198
    /// Lattice points per row: x = 467 + 17·c on even rows and 475.5 + 17·c on odd rows,
    /// c = 0 … 23 — 198 × 24 = 4 752 points.
    public static let glyphsPerRow = 24
    /// The hatch is laid face by face, the way a CAD hatch is filled region by region: a glyph is
    /// drawn only when its base and its three tips all lie on one side of each hip line, at least
    /// 0.5 pt clear of it. With s = x − y − 160 (the lower hip, s = 0) and u = x + y − 1760 (the
    /// upper hip, u = 0) at the base, the tips sit at s − 3.375, s − 2.5, s + 0.875 and
    /// u − 0.875, u + 2.5, u + 3.375, and 0.5 pt is 0.5·√2 = 0.7071 in s or u, so a glyph is left
    /// out when −1.5821 ≤ s ≤ 4.0821 or −4.0821 ≤ u ≤ 1.5821. Both are multiples of 0.5 on this
    /// lattice, so exactly: when −1.5 ≤ s ≤ 4 or −4 ≤ u ≤ 1.5. That leaves out 57 of the 4 752.
    public static func glyphIsDrawn(_ base: FixturePoint) -> Bool {
        let s = base.x - base.y - 160
        let u = base.x + base.y - 1760
        return !(s >= -1.5 && s <= 4) && !(u >= -4 && u <= 1.5)
    }
    /// 4 752 − 57 = 4 695 glyphs.
    public static let glyphCount = 4_695
    /// The drawn glyphs' base points, row by row.
    public static var glyphBases: [FixturePoint] {
        var result: [FixturePoint] = []
        result.reserveCapacity(glyphRowCount * glyphsPerRow)
        for row in 0..<glyphRowCount {
            let y = 305 + 5 * Double(row)
            let x0 = row % 2 == 0 ? 467.0 : 475.5
            for column in 0..<glyphsPerRow {
                let base = FixturePoint(x0 + 17 * Double(column), y)
                if glyphIsDrawn(base) { result.append(base) }
            }
        }
        return result
    }

    // MARK: - Site paving

    /// A paved forecourt north of the buildings: 14 rows of 121 vertical 8 pt strokes, 12 pt
    /// apart both ways — x = 90 + 12·c, y = 1450 + 12·r … + 8. Its job is load: with it the sheet
    /// holds about as many painted paths as a real CAD-exported A1 roof plan (see `FIXTURES.md`,
    /// "Calibration"), and it sits where no test traces, measures or matches.
    public static let pavingRows = 14
    public static let pavingColumns = 121
    public static let pavingStroke = 8.0
    public static let pavingPitch = 12.0
    public static let pavingOrigin = FixturePoint(90, 1450)

    // MARK: - Boundary fences

    /// Two boundary fences of 62 slats each, one west of the annex (x = 335 → 450) and one east of
    /// the house (x = 1605 → 1675), slat k from y = 305 + 16·k rising 4 pt along its length. Like
    /// the paving, they are load for the viewer's central viewports and stand where nothing is
    /// traced, measured or matched.
    public static let fenceSlats = 62
    public static let westFence = (from: 335.0, to: 450.0)
    public static let eastFence = (from: 1605.0, to: 1675.0)

    // MARK: - Symbols

    /// One double-frame symbol: an inner 40 × 28 pt frame inside a 50 × 35 pt one — the outer
    /// frame is the inner scaled by exactly 1.25 about the same centre — drawn as eight
    /// separate lines, with "TH" written inside.
    public static let symbolInnerSize = (width: 40.0, height: 28.0)
    public static let symbolOuterSize = (width: 50.0, height: 35.0)
    /// The three symbols' centres; the third is turned a quarter.
    public static let symbolCentres: [FixturePoint] = [
        FixturePoint(1040, 1060), FixturePoint(1040, 990), FixturePoint(1100, 640)
    ]
    public static let symbolQuarterTurned: [Bool] = [false, false, true]
    /// A square-in-square distractor (28 and 40 pt squares) and a circle-in-square distractor
    /// (a 44 pt square round a radius-15 circle).
    public static let squareDistractorCentre = FixturePoint(1100, 710)
    public static let circleDistractorCentre = FixturePoint(1115, 990)

    /// The eight lines of a symbol centred on `centre`: inner frame first, then outer, each
    /// bottom, right, top, left.
    public static func symbolLines(centre: FixturePoint, quarterTurn: Bool) -> [(FixturePoint, FixturePoint)] {
        func frame(_ width: Double, _ height: Double) -> [(FixturePoint, FixturePoint)] {
            let (w, h) = quarterTurn ? (height / 2, width / 2) : (width / 2, height / 2)
            let a = FixturePoint(centre.x - w, centre.y - h), b = FixturePoint(centre.x + w, centre.y - h)
            let c = FixturePoint(centre.x + w, centre.y + h), d = FixturePoint(centre.x - w, centre.y + h)
            return [(a, b), (b, c), (c, d), (d, a)]
        }
        return frame(symbolInnerSize.width, symbolInnerSize.height)
            + frame(symbolOuterSize.width, symbolOuterSize.height)
    }

    // MARK: - Title block text

    /// Every text run on the sheet, with its baseline origin and size. ASCII only (WinAnsi).
    static let titleRuns: [(id: String, text: String, origin: FixturePoint, size: Double)] = {
        var runs: [(String, String, FixturePoint, Double)] = []
        // Full-width cells, top to bottom; label 6.5 pt at top − 9, value 13 pt at top − 26.
        let cells: [(top: Double, label: String, value: String)] = [
            (510, "PROJEKTNAMN", "EXEMPELPROJEKT"),
            (460, "OMRADE", ""),
            (410, "PROJEKTNUMMER", "100-0001"),
            (360, "FORETAG", "EXEMPELARKITEKTER AB"),
            (310, "SKAPAD AV", "A. Berg"),
            (260, "GODKAND AV", "B. Lund"),
            (210, "SYSTEM", "A-00-0 DEMO"),
            (160, "SPECIFIKATION", "DEMO ROOF")
        ]
        for (index, cell) in cells.enumerated() {
            runs.append(("cell-\(index)-label", cell.label, FixturePoint(2056, cell.top - 9), 6.5))
            if !cell.value.isEmpty {
                runs.append(("cell-\(index)-value", cell.value, FixturePoint(2056, cell.top - 26), 13))
            }
        }
        // The area field: "KV" and its designation as two runs, 32.66 pt of daylight between
        // "KV" (13 pt Helvetica: (667 + 667) / 1000 × 13 = 17.342 pt wide) and the value.
        runs.append(("area-kv", "KV", FixturePoint(2056, 434), 13))
        runs.append(("area-value", "1:10 EXEMPELPARK", FixturePoint(2106, 434), 13))
        // Bottom row: number, scale and format cells.
        runs.append(("number-label", "DOKUMENTNUMMER", FixturePoint(2056, 101), 6.5))
        runs.append(("number-value", "A-00-0-001", FixturePoint(2056, 80), 19.5))
        runs.append(("scale-label", "SKALA", FixturePoint(2196, 101), 6.5))
        runs.append(("scale-value", "1:50", FixturePoint(2196, 84), 13))
        runs.append(("format-label", "FORMAT", FixturePoint(2286, 101), 6.5))
        runs.append(("format-value", "A1", FixturePoint(2286, 84), 13))
        runs.append(("date-label", "DATUM", FixturePoint(2286, 51), 6.5))
        runs.append(("date-value", "2026-01-15", FixturePoint(2286, 36), 8))
        // The logo row's caption.
        runs.append(("logo-caption", "EXEMPELARKITEKTER", FixturePoint(2072, 510 + 4), 6.5))
        return runs.map { (id: $0.0, text: $0.1, origin: $0.2, size: $0.3) }
    }()

    /// Annotation text on the roof facets, two columns of eight lines: text is no vector
    /// primitive, so it loads the viewer's central viewports without touching a traced face.
    static let roofAnnotations: [(text: String, origin: FixturePoint)] = (0..<16).map { index in
        let x = index % 2 == 0 ? 910.0 : 1240.0
        let y = 590.0 + 24 * Double(index / 2)
        let side = index % 2 == 0 ? "WEST" : "EAST"
        return ("\(side) PLANE, SEAM PANEL \(index / 2 + 1)", FixturePoint(x, y))
    }

    /// The notes column: plain sentences, no ratio anywhere (a ratio is a scale candidate).
    static let noteLines: [String] = [
        "NOTES",
        "SYNTHETIC TEST SHEET. NOT A CONSTRUCTION DOCUMENT.",
        "ALL DIMENSIONS IN MILLIMETRES UNLESS STATED.",
        "CHECK THE PRINTED SCALE AGAINST THE 100 MM RULER",
        "AT THE FOOT OF THE SHEET BEFORE MEASURING.",
        "ROOF FINISH, HOUSE: STANDING SEAM, GREY.",
        "ROOF FINISH, ANNEX: SEDUM ON DRAINAGE MAT.",
        "SNOW GUARD ALONG THE EAST EAVE, SEE DETAIL.",
        "GRID AXES A TO C AND 1 TO 2 ARE SETTING-OUT LINES.",
        "TH: ROOF HATCH, SEE SCHEDULE.",
        "HIP AND RIDGE FLASHINGS TO MATCH ROOF FINISH.",
        "RAINWATER TO GUTTERS AT EAVE LEVEL.",
        "VENT PIPES TO BE COORDINATED ON SITE.",
        "ACCESS TO ROOF VIA HATCH TH ONLY.",
        "FALL PROTECTION TO BE AGREED BEFORE WORK STARTS.",
        "SEDUM MAT TO BE WATERED UNTIL ESTABLISHED.",
        "EAVE BOARDS PAINTED TO MATCH FACADE.",
        "ALL FIXINGS STAINLESS STEEL.",
        "UNDERLAY TO MANUFACTURER'S INSTRUCTIONS.",
        "VERIFY ALL LEVELS ON SITE.",
        "THIS SHEET EXISTS TO EXERCISE SOFTWARE.",
        "ANY RESEMBLANCE TO A REAL BUILDING IS COINCIDENTAL.",
        "REVISIONS",
        "-  FIRST ISSUE",
        "LEGEND",
        "DASH-DOT LINE: GRID AXIS",
        "HATCHED AREA: SEDUM ROOF",
        "DOUBLE FRAME: ROOF HATCH",
        "THIN STRIP: SNOW GUARD"
    ]
}

// MARK: - The generator

/// The synthetic drawing sheets. See ``SyntheticRoofPlan`` for the design and `FIXTURES.md` for
/// the hand-derived numbers.
enum SyntheticRoofPlanFixtures {

    // MARK: Primitive arithmetic

    /// Primitives a vector extractor emits for page 0 of `synthetic-roof-plan.pdf`, by part.
    /// Each line of the drawing is its own painted path; a `re` rectangle is one rectangle
    /// primitive plus its four edges; a closed four-curve circle is one closed-subpath primitive
    /// plus its four curves; a closed filled triangle is one closed subpath plus three edges.
    static let primitiveCounts: [(part: String, count: Int)] = [
        ("sheet border (re)", 5),
        ("title column divider, title-block rules and bottom-row dividers", 1 + 10 + 2),
        ("control ruler: base line and eleven ticks", 1 + 11),
        ("graphic scale bar: ten re boxes", 10 * 5),
        ("north arrow: filled triangle and ring", 4 + 5),
        ("sedum hatch: 4 695 glyphs of three strokes", 4_695 * 3),
        ("sedum outline and its two hips", 4 + 2),
        ("house: four eaves, four hips (one kinked: two segments), ridge", 4 + 5 + 1),
        ("snow guard: four sides and the stub", 4 + 1),
        ("grid axes: three of 40 horizontal elements and two of 71 vertical", 3 * 40 + 2 * 71),
        ("axis label circles: five of one ring and four curves", 5 * 5),
        ("three symbols of eight lines", 3 * 8),
        ("square-in-square distractor", 8),
        ("circle-in-square distractor: four lines and a ring", 4 + 5),
        ("site paving: 14 rows of 121 strokes", 14 * 121),
        ("boundary fences: two of 62 slats", 2 * 62)
    ]

    /// 16 341.
    static var roofPlanPrimitiveCount: Int { primitiveCounts.reduce(0) { $0 + $1.count } }

    // MARK: Painter

    /// Writes content and counts what it emits, so the generator's own tally can be compared
    /// with ``primitiveCounts`` in the package's tests.
    struct Painter {
        var content = PDFContentStream()
        private(set) var emitted = 0

        typealias RGB = (r: Double, g: Double, b: Double)
        static let black: RGB = (0, 0, 0)
        static let axisRed: RGB = (0.75, 0, 0)
        static let sedumGreen: RGB = (0.36, 0.5, 0.29)
        static let pavingGrey: RGB = (0.5, 0.5, 0.5)

        private mutating func begin(width: Double, stroke: RGB) {
            content.saveState()
            content.raw("/GS0 gs")
            content.setLineWidth(width)
            content.raw("\(PDFNumber.string(stroke.r)) \(PDFNumber.string(stroke.g)) \(PDFNumber.string(stroke.b)) RG")
        }

        /// One open polyline as its own painted path.
        mutating func line(_ points: [FixturePoint], width: Double, colour: RGB = Painter.black) {
            begin(width: width, stroke: colour)
            content.appendRing(points, close: false)
            content.stroke()
            content.restoreState()
            emitted += points.count - 1
        }

        mutating func segment(_ a: FixturePoint, _ b: FixturePoint, width: Double, colour: RGB = Painter.black) {
            line([a, b], width: width, colour: colour)
        }

        /// A `re` rectangle, stroked or filled.
        mutating func rectangle(_ rect: FixtureRect, width: Double, filled: Bool, colour: RGB = Painter.black) {
            begin(width: width, stroke: colour)
            if filled {
                content.raw("\(PDFNumber.string(colour.r)) \(PDFNumber.string(colour.g)) \(PDFNumber.string(colour.b)) rg")
            }
            content.appendRectangle(rect)
            if filled { content.fillNonZero() } else { content.stroke() }
            content.restoreState()
            emitted += 5
        }

        /// A closed, filled polygon.
        mutating func filledPolygon(_ points: [FixturePoint], colour: RGB = Painter.black) {
            content.saveState()
            content.raw("\(PDFNumber.string(colour.r)) \(PDFNumber.string(colour.g)) \(PDFNumber.string(colour.b)) rg")
            content.appendRing(points, close: true)
            content.fillNonZero()
            content.restoreState()
            emitted += 1 + points.count
        }

        /// A circle as four cubic Béziers, closed exactly on its start point.
        mutating func circle(centre: FixturePoint, radius: Double, width: Double, colour: RGB = Painter.black) {
            let k = 0.552 * radius
            let (x, y, r) = (centre.x, centre.y, radius)
            begin(width: width, stroke: colour)
            let start = FixturePoint(x + r, y)
            content.move(to: start)
            content.curve(FixtureCubic(p0: start, p1: FixturePoint(x + r, y + k), p2: FixturePoint(x + k, y + r), p3: FixturePoint(x, y + r)))
            content.curve(FixtureCubic(p0: FixturePoint(x, y + r), p1: FixturePoint(x - k, y + r), p2: FixturePoint(x - r, y + k), p3: FixturePoint(x - r, y)))
            content.curve(FixtureCubic(p0: FixturePoint(x - r, y), p1: FixturePoint(x - r, y - k), p2: FixturePoint(x - k, y - r), p3: FixturePoint(x, y - r)))
            content.curve(FixtureCubic(p0: FixturePoint(x, y - r), p1: FixturePoint(x + k, y - r), p2: FixturePoint(x + r, y - k), p3: start))
            content.closeSubpath()
            content.stroke()
            content.restoreState()
            emitted += 5
        }

        /// One text run. Words are separate strings in one `TJ` array, spaced by a −278 adjustment
        /// (Helvetica's space advance, 278/1000 em) instead of a space glyph — the way CAD
        /// exports commonly write a label — so a text layer reads each word with its own box.
        mutating func text(_ value: String, size: Double, at origin: FixturePoint, kind: FixtureKind) throws {
            let words = try value.split(separator: " ", omittingEmptySubsequences: true)
                .map { try PDFSyntax.literalString(String($0), kind: kind) }
            content.saveState()
            content.setFillGray(0)
            content.raw("BT")
            content.raw("/F1 \(PDFNumber.string(size)) Tf")
            content.raw("1 0 0 1 \(PDFNumber.string(origin)) Tm")
            content.raw("[" + words.joined(separator: " -278 ") + "] TJ")
            content.raw("ET")
            content.restoreState()
        }

        mutating func image(named name: String, matrix: FixtureMatrix) {
            content.saveState()
            content.concat(matrix)
            content.drawXObject(named: name)
            content.restoreState()
        }
    }

    // MARK: Raster logos

    /// The two masked RGB rasters, at the pixel sizes a CAD title block's logos commonly have.
    static let logoSize = (width: 944, height: 275)
    static let stripSize = (width: 90, height: 944)

    /// A deterministic logo: a navy disc on white, three bars of "lettering" and a rule.
    static func logoPixels(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 3)
        let radius = Double(height) * 0.42
        let cx = Double(height) / 2, cy = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                var colour: (UInt8, UInt8, UInt8)? = nil
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy <= radius * radius {
                    colour = (dy < 0 ? (24, 48, 96) : (40, 96, 160))
                } else if x > height + 20 {
                    let bar = (y - 40) / 60
                    let inBar = y >= 40 && (y - 40) % 60 < 34 && bar < 3
                    let letter = (x - height - 20) / 46
                    if inBar && (x - height - 20) % 46 < 34 && letter < (14 - 3 * bar) { colour = (32, 32, 40) }
                    if y >= 236 && y < 244 { colour = (200, 40, 40) }
                }
                if let colour {
                    let index = (y * width + x) * 3
                    bytes[index] = colour.0
                    bytes[index + 1] = colour.1
                    bytes[index + 2] = colour.2
                }
            }
        }
        return bytes
    }

    /// A 1-bit stencil: `0` (painted) everywhere but a 6-pixel margin.
    static func maskBits(width: Int, height: Int) -> [UInt8] {
        let rowBytes = (width + 7) / 8
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width where x < 6 || y < 6 || x >= width - 6 || y >= height - 6 {
                bytes[y * rowBytes + x / 8] |= UInt8(0x80 >> (x % 8))
            }
        }
        return bytes
    }

    /// PDF `/RunLengthDecode` (PDF 32000-1 7.4.5): a run of 2…128 equal bytes as
    /// `257 − n, byte`; anything else as `n − 1, n literal bytes`; `128` ends the data.
    static func runLengthEncoded(_ input: [UInt8]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(input.count / 4)
        var index = 0
        var literal: [UInt8] = []
        func flushLiteral() {
            var start = 0
            while start < literal.count {
                let chunk = Swift.min(128, literal.count - start)
                out.append(UInt8(chunk - 1))
                out.append(contentsOf: literal[start..<start + chunk])
                start += chunk
            }
            literal.removeAll(keepingCapacity: true)
        }
        while index < input.count {
            var run = 1
            while index + run < input.count, run < 128, input[index + run] == input[index] { run += 1 }
            if run >= 2 {
                flushLiteral()
                out.append(UInt8(257 - run))
                out.append(input[index])
                index += run
            } else {
                literal.append(input[index])
                index += 1
            }
        }
        flushLiteral()
        out.append(128)
        return Data(out)
    }

    /// Adds the two image XObjects with their stencil masks; returns the `/XObject` resource map.
    static func addLogos(to builder: PDFDocumentBuilder) -> String {
        func add(width: Int, height: Int) -> Int {
            let mask = builder.addStream(
                entries: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) "
                    + "/ImageMask true /BitsPerComponent 1 /Filter /RunLengthDecode",
                data: runLengthEncoded(maskBits(width: width, height: height))
            )
            return builder.addStream(
                entries: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) "
                    + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /RunLengthDecode /Mask \(mask) 0 R",
                data: runLengthEncoded(logoPixels(width: width, height: height))
            )
        }
        let logo = add(width: logoSize.width, height: logoSize.height)
        let strip = add(width: stripSize.width, height: stripSize.height)
        return "<< /Im0 \(logo) 0 R /Im1 \(strip) 0 R >>"
    }

    // MARK: The drawing

    /// Which parts of the drawing go inside a marked-content section.
    struct LayerTags {
        var hatch: String?
        var axes: String?
        static let none = LayerTags()
    }

    /// The roof plan's content stream and the number of primitives it emits.
    static func roofPlanContent(kind: FixtureKind, layers: LayerTags = .none) throws -> (content: PDFContentStream, emitted: Int) {
        typealias Plan = SyntheticRoofPlan
        var p = Painter()

        // Sheet border and the title column.
        p.rectangle(FixtureRect(x: Plan.border.llx, y: Plan.border.lly, width: Plan.border.width, height: Plan.border.height),
                    width: 0.992, filled: false)
        let right = Plan.border.urx
        p.segment(FixturePoint(Plan.titleColumnLeft, Plan.border.lly), FixturePoint(Plan.titleColumnLeft, Plan.border.ury), width: 0.51)
        for y in [Plan.titleBlockTop, 510, 460, 410, 360, 310, 260, 210, 160, 110] {
            p.segment(FixturePoint(Plan.titleColumnLeft, y), FixturePoint(right, y), width: 0.51)
        }
        for x in [2190.0, 2280] {
            p.segment(FixturePoint(x, Plan.border.lly), FixturePoint(x, 110), width: 0.51)
        }
        for run in Plan.titleRuns {
            try p.text(run.text, size: run.size, at: run.origin, kind: kind)
        }
        for (index, note) in Plan.noteLines.enumerated() {
            try p.text(note, size: index == 0 ? 10 : 7, at: FixturePoint(2060, 1640 - 16 * Double(index)), kind: kind)
        }
        // The logos: Im0 upright, Im1 turned a quarter into a horizontal strip.
        p.image(named: "Im0", matrix: FixtureMatrix(a: 226.8, b: 0, c: 0, d: 66.1, e: 2072, f: 560))
        p.image(named: "Im1", matrix: FixtureMatrix(a: 0, b: -21.8, c: -226.8, d: 0, e: 2072 + 226.8, f: 524 + 21.8))

        // The control ruler and its labels.
        p.segment(Plan.rulerLeft, Plan.rulerRight, width: 0.312)
        for x in Plan.rulerTickXs {
            p.segment(FixturePoint(x, Plan.rulerLeft.y), FixturePoint(x, Plan.rulerLeft.y + Plan.rulerTickHeight), width: 0.312)
        }
        try p.text("0", size: 6.5, at: FixturePoint(1048, 30), kind: kind)
        try p.text("100 MM", size: 6.5, at: FixturePoint(1318, 30), kind: kind)
        try p.text("CONTROL RULER", size: 6.5, at: FixturePoint(1150, 62), kind: kind)

        // Graphic scale bar: ten 28 x 6 pt boxes, alternately filled.
        for index in 0..<10 {
            let box = FixtureRect(x: 100 + 28 * Double(index), y: 60, width: 28, height: 6)
            p.rectangle(box, width: 0.312, filled: index % 2 == 0)
        }
        try p.text("0", size: 6.5, at: FixturePoint(98, 50), kind: kind)
        try p.text("5 M", size: 6.5, at: FixturePoint(232, 50), kind: kind)
        try p.text("10 M", size: 6.5, at: FixturePoint(372, 50), kind: kind)

        // North arrow: a filled triangle inside a ring.
        p.filledPolygon([FixturePoint(1620, 1520), FixturePoint(1632, 1560), FixturePoint(1644, 1520)])
        p.circle(centre: FixturePoint(1632, 1540), radius: 30, width: 0.369)
        try p.text("N", size: 10, at: FixturePoint(1628, 1576), kind: kind)

        // The sedum hatch, drawn first so the annex's outline and hips lie on top of it.
        if let tag = layers.hatch { p.content.raw("/OC /\(tag) BDC") }
        for base in Plan.glyphBases {
            for prong in Plan.glyphProngs {
                p.segment(base, base + prong, width: 0.312, colour: Painter.sedumGreen)
            }
        }
        if layers.hatch != nil { p.content.raw("EMC") }
        let s = Plan.sedumRoof
        p.segment(FixturePoint(s.llx, s.lly), FixturePoint(s.urx, s.lly), width: 0.709)
        p.segment(FixturePoint(s.urx, s.lly), FixturePoint(s.urx, s.ury), width: 0.709)
        p.segment(FixturePoint(s.urx, s.ury), FixturePoint(s.llx, s.ury), width: 0.709)
        p.segment(FixturePoint(s.llx, s.ury), FixturePoint(s.llx, s.lly), width: 0.709)
        p.segment(Plan.sedumLowerHip.start, Plan.sedumLowerHip.end, width: 0.51)
        p.segment(Plan.sedumUpperHip.start, Plan.sedumUpperHip.end, width: 0.51)
        try p.text("ANNEX - SEDUM", size: 10, at: FixturePoint(570, 800), kind: kind)

        // The paved forecourt.
        for row in 0..<Plan.pavingRows {
            for column in 0..<Plan.pavingColumns {
                let x = Plan.pavingOrigin.x + Plan.pavingPitch * Double(column)
                let y = Plan.pavingOrigin.y + Plan.pavingPitch * Double(row)
                p.segment(FixturePoint(x, y), FixturePoint(x, y + Plan.pavingStroke), width: 0.25, colour: Painter.pavingGrey)
            }
        }
        try p.text("FORECOURT - PAVING", size: 10, at: FixturePoint(700, 1626), kind: kind)

        // The boundary fences.
        for fence in [Plan.westFence, Plan.eastFence] {
            for slat in 0..<Plan.fenceSlats {
                let y = 305 + 16 * Double(slat)
                p.segment(FixturePoint(fence.from, y), FixturePoint(fence.to, y + 4), width: 0.51)
            }
        }

        // The house: eaves, hips (the north-east one kinked), ridge.
        let e = Plan.eave
        p.segment(FixturePoint(e.llx, e.lly), FixturePoint(e.urx, e.lly), width: 0.709)
        p.segment(FixturePoint(e.urx, e.lly), FixturePoint(e.urx, e.ury), width: 0.709)
        p.segment(FixturePoint(e.urx, e.ury), FixturePoint(e.llx, e.ury), width: 0.709)
        p.segment(FixturePoint(e.llx, e.ury), FixturePoint(e.llx, e.lly), width: 0.709)
        p.segment(FixturePoint(e.llx, e.lly), Plan.ridgeFoot, width: 0.51)
        p.segment(FixturePoint(e.urx, e.lly), Plan.ridgeFoot, width: 0.51)
        p.segment(FixturePoint(e.llx, e.ury), Plan.ridgeHead, width: 0.51)
        p.line([FixturePoint(e.urx, e.ury), Plan.hipKink, Plan.ridgeHead], width: 0.51)
        p.segment(Plan.ridgeFoot, Plan.ridgeHead, width: 0.51)
        try p.text("HOUSE", size: 10, at: FixturePoint(1120, 1220), kind: kind)
        for note in Plan.roofAnnotations {
            try p.text(note.text, size: 8, at: note.origin, kind: kind)
        }

        // The snow guard and its stub.
        let g = Plan.snowGuard
        p.segment(FixturePoint(g.llx, g.lly), FixturePoint(g.urx, g.lly), width: 0.369)
        p.segment(FixturePoint(g.urx, g.lly), FixturePoint(g.urx, g.ury), width: 0.369)
        p.segment(FixturePoint(g.urx, g.ury), FixturePoint(g.llx, g.ury), width: 0.369)
        p.segment(FixturePoint(g.llx, g.ury), FixturePoint(g.llx, g.lly), width: 0.369)
        p.segment(Plan.snowGuardStub.start, Plan.snowGuardStub.end, width: 0.369)

        // Grid axes, one stroke per element, and their labels.
        if let tag = layers.axes { p.content.raw("/OC /\(tag) BDC") }
        for axis in Plan.horizontalAxes {
            for element in Plan.axisElements(from: axis.from, to: axis.to) {
                p.segment(FixturePoint(element.start, axis.y), FixturePoint(element.end, axis.y), width: 0.312, colour: Painter.axisRed)
            }
            let centre = FixturePoint(axis.to + 20, axis.y)
            p.circle(centre: centre, radius: Plan.axisLabelRadius, width: 0.312, colour: Painter.axisRed)
            try p.text(axis.name, size: 10, at: FixturePoint(centre.x - 3.5, centre.y - 3.5), kind: kind)
        }
        for axis in Plan.verticalAxes {
            for element in Plan.axisElements(from: axis.from, to: axis.to) {
                p.segment(FixturePoint(axis.x, element.start), FixturePoint(axis.x, element.end), width: 0.312, colour: Painter.axisRed)
            }
            let centre = FixturePoint(axis.x, axis.to + 20)
            p.circle(centre: centre, radius: Plan.axisLabelRadius, width: 0.312, colour: Painter.axisRed)
            try p.text(axis.name, size: 10, at: FixturePoint(centre.x - 3, centre.y - 3.5), kind: kind)
        }
        if layers.axes != nil { p.content.raw("EMC") }

        // Symbols and distractors.
        for (centre, turned) in zip(Plan.symbolCentres, Plan.symbolQuarterTurned) {
            for (a, b) in Plan.symbolLines(centre: centre, quarterTurn: turned) {
                p.segment(a, b, width: 0.369)
            }
            try p.text("TH", size: 9, at: FixturePoint(centre.x - 6.5, centre.y - 3), kind: kind)
        }
        let d1 = Plan.squareDistractorCentre
        for half in [14.0, 20.0] {
            let a = FixturePoint(d1.x - half, d1.y - half), b = FixturePoint(d1.x + half, d1.y - half)
            let c = FixturePoint(d1.x + half, d1.y + half), d = FixturePoint(d1.x - half, d1.y + half)
            for (u, v) in [(a, b), (b, c), (c, d), (d, a)] { p.segment(u, v, width: 0.369) }
        }
        let d2 = Plan.circleDistractorCentre
        do {
            let a = FixturePoint(d2.x - 22, d2.y - 22), b = FixturePoint(d2.x + 22, d2.y - 22)
            let c = FixturePoint(d2.x + 22, d2.y + 22), d = FixturePoint(d2.x - 22, d2.y + 22)
            for (u, v) in [(a, b), (b, c), (c, d), (d, a)] { p.segment(u, v, width: 0.369) }
            p.circle(centre: d2, radius: 15, width: 0.369)
        }
        return (p.content, p.emitted)
    }

    /// The page resources every roof-plan page uses.
    static func roofPlanResources(builder: PDFDocumentBuilder, extra: String = "") throws -> String {
        let font = try builder.addBase14Font(baseFont: "Helvetica")
        let state = builder.addObject("<< /Type /ExtGState /CA 1 >>")
        let images = addLogos(to: builder)
        return "<< /Font << /F1 \(font) 0 R >> /ExtGState << /GS0 \(state) 0 R >> /XObject \(images)\(extra) >>"
    }

    // MARK: Manifest content

    /// A closed facet with its hand-derived area, perimeter and shoelace condition number
    /// κ = Σ|xᵢyᵢ₊₁ − xᵢ₊₁yᵢ| / |Σ(xᵢyᵢ₊₁ − xᵢ₊₁yᵢ)|, each term written out in `FIXTURES.md`.
    static func closed(_ id: String, _ points: [FixturePoint], area: Double, perimeter: Double,
                       kappa: Double, detail: String) -> FixturePath {
        FixturePath(
            id: id, pageIndex: 0, kind: .closedPolygon, points: points,
            length: perimeter, area: area,
            derivation: .handComputation(detail, conditionNumber: kappa, magnitudeFloor: area)
        )
    }

    static func roofPlanPaths() -> [FixturePath] {
        let r2 = 2.0.squareRoot()
        // Hip lengths, each a 45° run: 300·√2; the kinked one: √(160² + 180²) + √(140² + 120²).
        let outerLeg: Double = (160.0 * 160.0 + 180.0 * 180.0).squareRoot()
        let innerLeg: Double = (140.0 * 140.0 + 120.0 * 120.0).squareRoot()
        let kinked: Double = outerLeg + innerLeg
        return [
            closed(
                "east-facet", SyntheticRoofPlan.eastFacet, area: 207_000,
                perimeter: 300 * r2 + 1000 + kinked + 400, kappa: 2_586_000.0 / 414_000.0,
                detail: "Five corners (1200,600) (1500,300) (1500,1300) (1340,1120) (1200,1000). Area between "
                    + "the upper hips and the lower hip over x = 1200…1500: upper = 140·(1000+1120)/2 + "
                    + "160·(1120+1300)/2 = 148400 + 193600 = 342000; lower = 300·(600+300)/2 = 135000; "
                    + "facet = 342000 − 135000 = 207000. Perimeter = lower hip 300√2 + eave 1000 + kinked "
                    + "hip √(160²+180²) + √(140²+120²) + ridge 400."
            ),
            closed(
                "south-facet", SyntheticRoofPlan.southFacet, area: 90_000,
                perimeter: 600 + 2 * 300 * r2, kappa: 900_000.0 / 180_000.0,
                detail: "Triangle (900,300) (1500,300) (1200,600): base 600, height 300, area 600·300/2 = 90000."
            ),
            closed(
                "west-facet", SyntheticRoofPlan.westFacet, area: 210_000,
                perimeter: 2 * 300 * r2 + 400 + 1000, kappa: 2_220_000.0 / 420_000.0,
                detail: "Trapezoid with parallel sides x = 900 (1000 long) and x = 1200 (400 long), 300 apart: "
                    + "300·(1000+400)/2 = 210000."
            ),
            closed(
                "north-facet", SyntheticRoofPlan.northFacet, area: 93_000,
                perimeter: kinked + 600 + 300 * r2, kappa: 1_506_000.0 / 186_000.0,
                detail: "Under y = 1300 over x = 900…1500 (600000), less the area under its lower boundary: "
                    + "the north-west hip 300·(1300+1000)/2 = 345000, the kinked hip 140·(1000+1120)/2 + "
                    + "160·(1120+1300)/2 = 342000 → 600·1300 − 345000 − 342000 = 93000."
            ),
            closed(
                "snow-guard", SyntheticRoofPlan.snowGuard.counterClockwiseCorners, area: 840,
                perimeter: 2 * (3 + 280), kappa: 835_040.0 / 1_680.0,
                detail: "Rectangle 3 × 280 at (1483, 480): area 840, perimeter 566."
            ),
            closed(
                "sedum-middle-face", SyntheticRoofPlan.sedumMiddleFace, area: 243_600,
                perimeter: 420 * r2 + 160 + 420 * r2 + 1000, kappa: 1_407_200.0 / 487_200.0,
                detail: "Trapezoid with parallel sides x = 460 (1000 long) and x = 880 (880 − 720 = 160 long), "
                    + "420 apart: 420·(1000+160)/2 = 243600."
            ),
            closed(
                "sedum-lower-face", SyntheticRoofPlan.sedumLowerFace, area: 88_200,
                perimeter: 420 + 420 + 420 * r2, kappa: 562_800.0 / 176_400.0,
                detail: "Right triangle with legs 420 and 420: 420²/2 = 88200."
            ),
            closed(
                "sedum-upper-face", SyntheticRoofPlan.sedumUpperFace, area: 88_200,
                perimeter: 420 + 420 + 420 * r2, kappa: 1_654_800.0 / 176_400.0,
                detail: "Right triangle with legs 420 and 420: 420²/2 = 88200."
            ),
            FixturePath(
                id: "control-ruler", pageIndex: 0, kind: .openPolyline,
                points: [SyntheticRoofPlan.rulerLeft, SyntheticRoofPlan.rulerRight],
                length: SyntheticRoofPlan.rulerRight.x - SyntheticRoofPlan.rulerLeft.x, area: 0,
                derivation: .closedForm(
                    "100 mm of paper = 100 × 72 / 25.4 = 36000/127 pt; drawn from x = 1050 to "
                        + "x = 1050 + 36000/127 at y = 42.",
                    magnitudeFloor: 283
                )
            )
        ]
    }

    static func roofPlanTexts() -> [FixtureText] {
        SyntheticRoofPlan.titleRuns.map {
            FixtureText(id: $0.id, pageIndex: 0, string: $0.text, origin: $0.origin, fontSize: $0.size,
                        fontName: "Helvetica", isTitleBlock: true)
        }
    }

    static func roofPlanRasters(pageIndex: Int = 0) -> [FixtureRaster] {
        [
            FixtureRaster(id: "logo", pageIndex: pageIndex, placement: FixtureRect(x: 2072, y: 560, width: 226.8, height: 66.1),
                          pixelWidth: logoSize.width, pixelHeight: logoSize.height, bitsPerComponent: 8, colorSpace: "DeviceRGB"),
            FixtureRaster(id: "strip", pageIndex: pageIndex, placement: FixtureRect(x: 2072, y: 524, width: 226.8, height: 21.8),
                          pixelWidth: stripSize.width, pixelHeight: stripSize.height, bitsPerComponent: 8, colorSpace: "DeviceRGB")
        ]
    }

    static let roofPlanNotes: [String] = [
        "One A1 landscape page; /MediaBox and /CropBox both [0 0 2383.94 1683.78]; no optional content.",
        "Every line is its own painted path inside q … Q with /GS0 gs, a line width and an RGB stroke "
            + "colour, the way a CAD export writes a sheet; content streams are stored uncompressed.",
        "Vector primitives on page 0: border 5 + title rules 13 + ruler 12 + scale bar 50 + north arrow 9 "
            + "+ hatch 14085 + annex outline and hips 6 + house 10 + snow guard 5 + axes 262 + axis circles 25 "
            + "+ symbols 24 + distractors 17 + paving 1694 + fences 124 = 16341.",
        "Hatch: a lattice of 198 rows (y = 305 + 5r) of 24 points (x = 467 + 17c, odd rows + 8.5); "
            + "4695 glyphs of three strokes, the 57 lattice points within 0.5 pt of a hip line left out.",
        "Axes: A, B and C 640 pt = 20 periods of 32 pt = 40 elements each; 1 and 2 1140 pt = 35 periods "
            + "+ a 20 pt dash = 71 elements each. No element ends within 4 pt of a boundary line.",
        "Text: Helvetica, WinAnsi, ASCII only. The only ratios printed are 1:50 (under SKALA) and "
            + "1:10 (after KV, a property designation).",
        "Rasters: 944 × 275 and 90 × 944 DeviceRGB, each with a 1-bit /ImageMask, /RunLengthDecode."
    ]

    // MARK: Fixtures

    static func roofPlan() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .syntheticRoofPlan,
            title: "Synthetic Roof Plan v\(SyntheticRoofPlan.version): A1 roof plan, 16 341 vector primitives",
            purpose: "The heavy, realistic construction sheet: calibration on a control ruler, measuring in a "
                + "free band, tracing roof facets past dash-dot axes and a dense hatch, symbol matching, the "
                + "scale proposal's title-block reading, and the viewer's raster budgets.",
            fileName: FixtureKind.syntheticRoofPlan.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                                hasTextLayer: true, hasRasterContent: true)],
            paths: roofPlanPaths(),
            texts: roofPlanTexts(),
            rasters: roofPlanRasters(),
            notes: roofPlanNotes,
            vectorPrimitiveCount: roofPlanPrimitiveCount
        )
        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .syntheticRoofPlan)
            let resources = try roofPlanResources(builder: builder)
            let drawn = try roofPlanContent(kind: .syntheticRoofPlan)
            let contents = try builder.addContentStream(drawn.content)
            builder.addPage(mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            resources: resources, contentObject: contents)
            return try builder.data()
        }
    }

    /// The large middle sheet of the set: 2 700 × 3 100 mm, twelve rooms and a title block at 1:100.
    static let planBBox = FixtureRect(llx: 0, lly: 0, urx: 2700 / 25.4 * 72, ury: 3100 / 25.4 * 72)

    /// What the revised roof plan adds over the original, in a corner the original leaves empty.
    static let revisionAdditions = "q 2 w 1 0 0 RG 1560 1420 120 80 re S 1560 1400 m 1700 1480 l S Q\n"

    static func threeSheetSet() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .syntheticRoofPlanSet,
            title: "Synthetic three-sheet set: roof plan, a large rooms sheet at 1:100, the roof plan revised",
            purpose: "Prepare This Set across sheets of very different size, with the roof plan's own content "
                + "stream drawn by sheets 1 and 3.",
            fileName: FixtureKind.syntheticRoofPlanSet.fileName,
            pageCount: 3,
            pages: [
                FixturePage(index: 0, mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            hasTextLayer: true, hasRasterContent: true),
                FixturePage(index: 1, mediaBox: planBBox, hasTextLayer: true),
                FixturePage(index: 2, mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            hasTextLayer: true, hasRasterContent: true)
            ],
            rasters: roofPlanRasters(pageIndex: 0) + roofPlanRasters(pageIndex: 2),
            notes: [
                "Page 1 and page 3 reference the same roof-plan content stream object; page 3 appends a second "
                    + "stream with a red 120 × 80 rectangle and a line.",
                "Page 2: twelve 1400 × 1900 pt rooms and the title-block runs RITNINGSNUMMER A-00-0-200 and "
                    + "SKALA 1:100, Helvetica 40 pt."
            ]
        )
        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .syntheticRoofPlanSet)
            let resources = try roofPlanResources(builder: builder)
            let roof = try builder.addContentStream(try roofPlanContent(kind: .syntheticRoofPlanSet).content)
            var planB = PDFContentStream()
            planB.raw("1 w 0 0 0 RG")
            for row in 0..<3 {
                for column in 0..<4 {
                    planB.appendRectangle(FixtureRect(x: Double(500 + column * 1500), y: Double(1500 + row * 2000),
                                                      width: 1400, height: 1900))
                    planB.stroke()
                }
            }
            planB.showText(try PDFSyntax.literalString("RITNINGSNUMMER A-00-0-200", kind: .syntheticRoofPlanSet),
                           font: "F1", size: 40, at: FixturePoint(5800, 240))
            planB.showText(try PDFSyntax.literalString("SKALA 1:100", kind: .syntheticRoofPlanSet),
                           font: "F1", size: 40, at: FixturePoint(5800, 160))
            let planBObject = try builder.addContentStream(planB)
            var revision = PDFContentStream()
            revision.raw(revisionAdditions.trimmingCharacters(in: .newlines))
            let revisionObject = try builder.addContentStream(revision)
            builder.addPage(mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            resources: resources, contentObject: roof)
            builder.addPage(mediaBox: planBBox, resources: resources, contentObject: planBObject)
            builder.addPage(mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            resources: resources, contentObjects: [roof, revisionObject])
            return try builder.data()
        }
    }

    /// Primitives on the layered variant's "Hatch" (L0) and "Grid" (L1) groups.
    static let layeredHatchPrimitives = 4_695 * 3
    static let layeredGridPrimitives = 3 * 40 + 2 * 71 + 5 * 5

    static func layered() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .syntheticRoofPlanLayered,
            title: "Synthetic Roof Plan with its hatch and grid on optional-content groups",
            purpose: "Hidden-layer paths on a heavy sheet: the sedum hatch on group Hatch (/L0, 14 085 primitives) "
                + "and the grid axes with their label circles on group Grid (/L1, 287 primitives), both on by default.",
            fileName: FixtureKind.syntheticRoofPlanLayered.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                                hasTextLayer: true, hasRasterContent: true)],
            paths: roofPlanPaths(),
            texts: roofPlanTexts(),
            rasters: roofPlanRasters(),
            notes: roofPlanNotes + [
                "OCGs in /OCProperties order: Hatch, Grid; both in /D /ON order, neither /OFF.",
                "Page /Resources /Properties: /L0 Hatch, /L1 Grid. 14085 primitives carry layer L0 and "
                    + "287 (axes 262 + circles 25) carry L1; the other 1969 carry none."
            ],
            vectorPrimitiveCount: roofPlanPrimitiveCount
        )
        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .syntheticRoofPlanLayered)
            let hatch = builder.addObject("<< /Type /OCG /Name (Hatch) >>")
            let grid = builder.addObject("<< /Type /OCG /Name (Grid) >>")
            builder.catalogExtraEntries = "/OCProperties << /OCGs [\(hatch) 0 R \(grid) 0 R] "
                + "/D << /Order [\(hatch) 0 R \(grid) 0 R] /ON [\(hatch) 0 R \(grid) 0 R] >> >>"
            let resources = try roofPlanResources(
                builder: builder, extra: " /Properties << /L0 \(hatch) 0 R /L1 \(grid) 0 R >>"
            )
            let drawn = try roofPlanContent(kind: .syntheticRoofPlanLayered, layers: LayerTags(hatch: "L0", axes: "L1"))
            let contents = try builder.addContentStream(drawn.content)
            builder.addPage(mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            resources: resources, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: Wall module

    /// The wall module's geometry, at a nominal 1:50 (56.692913… pt per metre).
    enum Walls {
        /// 250 mm at 1:50 = 5 mm of paper = 1800/127 pt.
        static let outerThickness = 1800.0 / 127.0
        /// 120 mm at 1:50 = 2.4 mm of paper = 864/127 pt.
        static let partitionThickness = 864.0 / 127.0
        /// 90 mm at 1:50 = 1.8 mm of paper = 648/127 pt.
        static let hatchSpacing = 648.0 / 127.0
        static let outer = FixtureRect(llx: 300, lly: 300, urx: 1300, ury: 900)
        static let partitionX = 800.0
        static let doorFrom = 500.0, doorTo = 550.0
        static let hatchLines = 20
        static let hatchX = (from: 1500.0, to: 1800.0)
        static let hatchY0 = 300.0
    }

    static func wallModule() throws -> FixtureBuild {
        let t = Walls.outerThickness
        let o = Walls.outer
        let inner = FixtureRect(llx: o.llx + t, lly: o.lly + t, urx: o.urx - t, ury: o.ury - t)
        let manifest = FixtureManifest(
            kind: .syntheticWallModule,
            title: "Synthetic wall module: 250 mm walls, a 120 mm partition and a 90 mm hatch on an A1 sheet",
            purpose: "Find Walls with classes derivable by hand: walls 120 and 250 mm, hatch classes at every "
                + "multiple of 90 mm up to 600 mm.",
            fileName: FixtureKind.syntheticWallModule.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                                hasTextLayer: true)],
            notes: [
                "Outer wall: rectangle [300 300 1300 900] and its inner face 1800/127 pt (250 mm at 1:50) inside it.",
                "Partition: faces x = 800 and x = 800 + 864/127 (120 mm), from the inner bottom face to the inner "
                    + "top face, broken by a door from y = 500 to y = 550.",
                "Hatch: 20 lines from x = 1500 to 1800 at y = 300 + k · 648/127 (90 mm), k = 0 … 19.",
                "Every face is its own open line: 8 + 4 + 20 = 32 vector primitives."
            ],
            vectorPrimitiveCount: 32
        )
        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .syntheticWallModule)
            let font = try builder.addBase14Font(baseFont: "Helvetica")
            let state = builder.addObject("<< /Type /ExtGState /CA 1 >>")
            var p = Painter()
            for rect in [o, inner] {
                p.segment(FixturePoint(rect.llx, rect.lly), FixturePoint(rect.urx, rect.lly), width: 0.5)
                p.segment(FixturePoint(rect.urx, rect.lly), FixturePoint(rect.urx, rect.ury), width: 0.5)
                p.segment(FixturePoint(rect.urx, rect.ury), FixturePoint(rect.llx, rect.ury), width: 0.5)
                p.segment(FixturePoint(rect.llx, rect.ury), FixturePoint(rect.llx, rect.lly), width: 0.5)
            }
            for x in [Walls.partitionX, Walls.partitionX + Walls.partitionThickness] {
                p.segment(FixturePoint(x, inner.lly), FixturePoint(x, Walls.doorFrom), width: 0.35)
                p.segment(FixturePoint(x, Walls.doorTo), FixturePoint(x, inner.ury), width: 0.35)
            }
            for k in 0..<Walls.hatchLines {
                let y = Walls.hatchY0 + Double(k) * Walls.hatchSpacing
                p.segment(FixturePoint(Walls.hatchX.from, y), FixturePoint(Walls.hatchX.to, y), width: 0.25)
            }
            try p.text("WALL MODULE - SYNTHETIC TEST SHEET", size: 14, at: FixturePoint(300, 1000), kind: .syntheticWallModule)
            let contents = try builder.addContentStream(p.content)
            builder.addPage(mediaBox: SyntheticRoofPlan.pageBox, cropBox: SyntheticRoofPlan.pageBox,
                            resources: "<< /Font << /F1 \(font) 0 R >> /ExtGState << /GS0 \(state) 0 R >> >>",
                            contentObject: contents)
            return try builder.data()
        }
    }
}
