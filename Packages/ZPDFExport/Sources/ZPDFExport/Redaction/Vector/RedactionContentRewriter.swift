import CoreGraphics
import Foundation

/// New objects the rewrite creates — copied form XObjects, blanked images, new content
/// streams — numbered in a range no source object can reach, so the writer can tell them apart.
struct RedactionObjectPool {
    static let syntheticBase = 1 << 40
    private(set) var objects: [Int: PDFObject] = [:]
    private var next = syntheticBase

    mutating func add(_ object: PDFObject) -> PDFObject {
        let number = next
        next += 1
        objects[number] = object
        return .reference(number: number, generation: 0)
    }

    mutating func reserve() -> Int {
        let number = next
        next += 1
        return number
    }

    mutating func set(_ number: Int, _ object: PDFObject) { objects[number] = object }
}

/// What one page's rewrite removed, for the report and for the verifier.
struct RedactionPageWork {
    var removedGlyphs = 0
    /// Each removed glyph's box on the sheet (four corners), excluded from the pixel comparison
    /// because removing it is the point.
    var removedGlyphQuads: [[CGPoint]] = []
    /// Words whose every glyph was removed, in the text the fonts say they stand for.
    var removedWords: [String] = []
}

/// The shared state of one redaction: the source file, the boxes, the new objects, and what the
/// rewrite learned about which source objects lay under a box.
final class RedactionRewriteContext {
    let scan: PDFDocumentScan
    var pool: RedactionObjectPool
    var work = RedactionPageWork()
    /// Page space; the exclusion clip covers this less the boxes.
    var frame: CGRect = .zero
    /// The redaction boxes — or, while a copy is cut down to `cropRect`, the strips outside it.
    var boxes: [CGRect] = []
    /// Set while a copy of something shown only in part is cut down to the part it shows.
    var cropRect: CGRect?
    /// The page's visible area (crop box ∩ media box): where every clip starts.
    var visibleBox: CGRect = .infinite
    /// Whether this pass records what it removed. Only the rewrite of a marked sheet under its
    /// own boxes records; cropped copies and unmarked sheets never do.
    var recording = true
    /// Source objects whose content was cut or removed because it lay under a box: blanked or
    /// removed pictures and their masks, forms rewritten under a box, patterns and shadings cut
    /// or removed, fonts that lost glyphs. Their originals must not travel unless a use shows
    /// them whole (ADR-0033 §11).
    var tainted: Set<Int> = []
    /// Fonts that lost a glyph under a box (a subset of `tainted`); the copy keeps them reduced
    /// to the codes still drawn.
    var taintedFonts: Set<Int> = []
    /// Tainted objects and every object that reaches one: an untouched use of one is examined.
    var dirty: Set<Int> = []
    /// Tainted objects kept in their original form because a use shows them whole.
    var justified: Set<Int> = []
    /// For each tainted font, the codes still drawn anywhere in the copy.
    var drawnCodes: [Int: Set<RedactionFont.Code>] = [:]
    /// Set while a sheet that becomes a picture anyway is read only to learn what lay under its
    /// boxes: a construct that cannot be cut exactly then marks the objects involved instead of
    /// stopping the rewrite.
    var surveying = false
    private var fontCache: [String: Result<RedactionFont, RedactionUnsupported>] = [:]
    private var splitterCache: [Int: Result<RedactionCodeSplitter, RedactionUnsupported>] = [:]
    fileprivate var formStack: [Int] = []
    private var dummies: [Int: PDFObject] = [:]

    init(scan: PDFDocumentScan, pool: RedactionObjectPool) {
        self.scan = scan
        self.pool = pool
    }

    func resolve(_ object: PDFObject?) -> PDFObject? { scan.object(object) }

    /// Whether the boxes are redaction boxes (not the strips of a crop).
    var redacting: Bool { cropRect == nil && !boxes.isEmpty }
    var records: Bool { redacting && recording }

    func taint(_ reference: PDFObject?) {
        guard records, let number = reference?.referenceValue?.number else { return }
        tainted.insert(number)
    }

    func needsExamination(_ reference: PDFObject?) -> Bool {
        guard !surveying, let number = reference?.referenceValue?.number else { return false }
        return dirty.contains(number) || tainted.contains(number)
    }

    /// Marks objects as having lain under a box during a survey.
    func surveyTaint(_ references: [PDFObject?]) {
        for reference in references {
            guard let number = reference?.referenceValue?.number else { continue }
            tainted.insert(number)
            if resolve(reference)?.dictionaryValue?["Type"]?.nameValue == "Font" { taintedFonts.insert(number) }
        }
    }

    func splitter(_ reference: PDFObject?) throws -> RedactionCodeSplitter {
        guard let number = reference?.referenceValue?.number, let dictionary = resolve(reference)?.dictionaryValue else {
            throw RedactionUnsupported("a font resource is missing")
        }
        if let cached = splitterCache[number] { return try cached.get() }
        let result: Result<RedactionCodeSplitter, RedactionUnsupported>
        do {
            result = .success(try RedactionCodeSplitter(dictionary: dictionary, resolve: { self.resolve($0) }))
        } catch let error as RedactionUnsupported {
            result = .failure(error)
        } catch {
            result = .failure(RedactionUnsupported("a font cannot be read"))
        }
        splitterCache[number] = result
        return try result.get()
    }

    func font(_ reference: PDFObject?) throws -> RedactionFont {
        let key: String
        if let number = reference?.referenceValue?.number {
            key = "ref:\(number)"
        } else {
            key = "inline:\(reference.map { String(decoding: $0.serialized.prefix(512), as: UTF8.self) } ?? "")"
        }
        if let cached = fontCache[key] { return try cached.get() }
        let result: Result<RedactionFont, RedactionUnsupported>
        if let dictionary = resolve(reference)?.dictionaryValue {
            do {
                result = .success(try RedactionFont(dictionary: dictionary, resolve: { self.resolve($0) }))
            } catch let error as RedactionUnsupported {
                result = .failure(error)
            } catch {
                result = .failure(RedactionUnsupported("a font cannot be read"))
            }
        } else {
            result = .failure(RedactionUnsupported("a font resource is missing"))
        }
        fontCache[key] = result
        return try result.get()
    }

    /// An empty tiling pattern, for a pattern name a content stream still sets although nothing
    /// it paints uses the original any more.
    func dummyPattern(paintType: Int) -> PDFObject {
        if let existing = dummies[paintType] { return existing }
        let dummy = pool.add(.stream(dictionary: [
            "Type": .name("Pattern"), "PatternType": .integer(1), "PaintType": .integer(paintType), "TilingType": .integer(1),
            "BBox": .array([.integer(0), .integer(0), .integer(1), .integer(1)]), "XStep": .integer(1), "YStep": .integer(1),
            "Resources": .dictionary([:])
        ], data: Data()))
        dummies[paintType] = dummy
        return dummy
    }

    /// Four rectangles covering `frame` (grown far out) less `visible`.
    func strips(outside visible: CGRect) -> [CGRect] {
        let outer = frame.union(visible).insetBy(dx: -100_000, dy: -100_000)
        let rects = [
            CGRect(x: outer.minX, y: outer.minY, width: visible.minX - outer.minX, height: outer.height),
            CGRect(x: visible.maxX, y: outer.minY, width: outer.maxX - visible.maxX, height: outer.height),
            CGRect(x: visible.minX, y: outer.minY, width: visible.width, height: visible.minY - outer.minY),
            CGRect(x: visible.minX, y: visible.maxY, width: visible.width, height: outer.maxY - visible.maxY)
        ]
        return rects.filter { $0.width > 0 && $0.height > 0 }
    }
}

/// Rewrites one content stream so nothing under a box survives in it (NL-PDF-14 phase 2,
/// ADR-0033 §3 and §11).
///
/// It interprets the stream the way a reader draws it — graphics state, CTM, clip, colours,
/// text state and text matrices — and for each drawing operation decides, in page space,
/// whether it touches a box:
///
/// - **not at all:** the operation is copied unchanged — unless it draws something cut under a
///   box elsewhere, which is kept whole only where it shows whole and otherwise replaced by a
///   copy holding only what this placement shows;
/// - **text:** exactly the glyphs whose boxes intersect a box are removed, and each removed run
///   becomes a `TJ` adjustment equal to its advance, so every kept glyph stays where it was;
/// - **paths:** fills and clips become the region less the boxes, strokes are cut at the box
///   edges (Béziers split exactly), dash phases carried across the cut;
/// - **images:** covered samples are blanked in the data; the image is drawn clipped to the
///   area outside the boxes;
/// - **form XObjects:** rewritten recursively for this placement and written as a new object;
/// - **tiling patterns:** a fill whose cell is painted once is cut like a form for that tile; a
///   cell painted repeatedly across a box cannot be cut exactly;
/// - **smooth shadings:** removed when they paint only under a box; a shading, shading pattern
///   or mesh painted partly under one cannot be cut exactly.
///
/// Anything it cannot do exactly is a ``RedactionUnsupported`` for the whole sheet.
///
/// With no boxes it only prunes resources and examines what is drawn (an unmarked sheet that
/// shares something with a marked one); with ``RedactionRewriteContext/cropRect`` set it cuts a
/// copy down to what one placement shows.
struct RedactionContentRewriter {

    struct Output {
        var operations: [RedactionOperation]
        var changed: Bool
        var resources: [String: PDFObject]
        /// The stream left a text object open (BT without ET).
        var endsInText: Bool
        /// The stream painted with a pattern colour set before it began (in a parent stream).
        var paintedInheritedFill: Bool
        var paintedInheritedStroke: Bool
    }

    private struct TextState {
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var horizontalScale = 1.0
        var leading = 0.0
        var fontSize = 0.0
        var rise = 0.0
        var renderMode = 0
        var fontReference: PDFObject?
    }

    /// The clip in page space: its bounding box, and whether it is exactly that rectangle.
    struct Clip {
        var bounds: CGRect
        var exact: Bool

        func intersecting(_ rect: CGRect, exact rectIsExact: Bool) -> Clip {
            let intersection = bounds.intersection(rect)
            return Clip(bounds: intersection, exact: exact && rectIsExact)
        }
    }

    /// The current fill or stroke colour: the operators that set it, and the pattern it names.
    private struct PaintColour {
        var spaceOperation: RedactionOperation?
        var colourOperation: RedactionOperation?
        var spaceIsPattern = false
        var pattern: String?
        /// The depth of the content stream whose resources the pattern name belongs to.
        var patternDepth = 0
    }

    private struct GraphicsState {
        var ctm: CGAffineTransform
        var clip: Clip
        var softMasked = false
        var lineWidth = 1.0
        /// `J`, `j` and `M` (ISO 32000-1 §8.4.3.3–5): how far a stroke reaches past its path.
        var lineCap = 0
        var lineJoin = 0
        var miterLimit = 10.0
        var dashArray: [Double] = []
        var dashPhase = 0.0
        var text = TextState()
        var fill = PaintColour()
        var stroke = PaintColour()
    }

    private struct MarkedContent {
        var outputIndex: Int
        var tag: PDFObject
        var properties: [String: PDFObject]?
        var resourceName: String?
        var dirty = false
        var keptText = ""
        var textKnown = true
    }

    private let context: RedactionRewriteContext
    private let resources: [String: PDFObject]
    private let depth: Int
    /// Pattern space → page: the pattern matrix maps into the default space of the stream a
    /// pattern is painted in (the page's, or a form's or pattern cell's placement).
    private let patternBase: CGAffineTransform
    private var state: GraphicsState
    private var stack: [GraphicsState] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var inText = false
    private var textClipPending = false
    /// Marked-content depth when the current text object began: a sequence opened inside it
    /// must not be split by the ET/BT a clip needs.
    private var markedDepthAtBT = 0
    private var marked: [MarkedContent] = []
    private var out: [RedactionOperation] = []
    private var changed = false
    private var used: [String: Set<String>] = [:]
    private var added: [String: [String: PDFObject]] = [:]
    private var propertyUses: [String: Int] = [:]
    /// Pattern names a colour operator sets; those no kept paint uses become empty patterns.
    private var referencedPatterns: Set<String> = []
    private var cutPatterns: [String: String] = [:]
    private var paintedInheritedFill = false
    private var paintedInheritedStroke = false

    // Path under construction.
    private var pathOperations: [RedactionOperation] = []
    private var subpaths: [RedactionSubpath] = []
    private var currentPoint: CGPoint?
    private var clipRule: String?
    private var pathCTM: CGAffineTransform?

    init(context: RedactionRewriteContext, resources: [String: PDFObject], ctm: CGAffineTransform, depth: Int = 0) {
        self.context = context
        self.resources = resources
        self.depth = depth
        self.patternBase = ctm
        self.state = GraphicsState(ctm: ctm, clip: Clip(bounds: context.visibleBox, exact: !context.visibleBox.isInfinite))
    }

    /// A form XObject starts with the graphics state — text state, colours and dash included —
    /// of the `Do` that paints it; a pattern cell with a fresh one at its tile.
    private init(context: RedactionRewriteContext, resources: [String: PDFObject], inherited: GraphicsState, depth: Int, patternBase: CGAffineTransform) {
        self.context = context
        self.resources = resources
        self.depth = depth
        self.patternBase = patternBase
        self.state = inherited
    }

    private var boxes: [CGRect] { context.boxes }
    private var cutting: Bool { !context.boxes.isEmpty }

    /// Something that cannot be cut exactly: the sheet falls back — unless the sheet is being
    /// read only to learn what lay under its boxes, when the objects involved count as having
    /// lain under a box and the reading carries on.
    private func cannotCut(_ reason: String, tainting references: [PDFObject?] = []) throws {
        guard context.surveying else { throw RedactionUnsupported(reason) }
        context.surveyTaint(references)
    }

    private func category(_ name: String) -> [String: PDFObject]? {
        context.resolve(resources[name])?.dictionaryValue
    }

    private mutating func use(_ category: String, _ name: String) {
        used[category, default: []].insert(name)
    }

    private mutating func addResource(_ kind: String, _ object: PDFObject, prefix: String) -> String {
        let existing = category(kind) ?? [:]
        var index = (added[kind]?.count ?? 0) + 1
        var name = "\(prefix)\(index)"
        while existing[name] != nil || added[kind]?[name] != nil {
            index += 1
            name = "\(prefix)\(index)"
        }
        added[kind, default: [:]][name] = object
        return name
    }

    // MARK: - Driving

    mutating func rewrite(_ operations: [RedactionOperation]) throws -> Output {
        for operation in operations {
            try handle(operation)
        }
        if !pathOperations.isEmpty {
            // A path never painted draws nothing; it is not copied.
            if pathHull().map({ hull in boxes.contains { RedactionGeometry.intersects(hull, $0) } }) ?? false {
                changed = true
            } else {
                out.append(contentsOf: pathOperations)
            }
            resetPath()
        }
        while !marked.isEmpty { closeMarkedContent() }
        return Output(
            operations: out, changed: changed, resources: prunedResources(), endsInText: inText,
            paintedInheritedFill: paintedInheritedFill, paintedInheritedStroke: paintedInheritedStroke
        )
    }

    private mutating func handle(_ operation: RedactionOperation) throws {
        let operands = operation.operands
        func number(_ index: Int) -> Double { index < operands.count ? (operands[index].doubleValue ?? 0) : 0 }

        switch operation.name {
        // Path construction.
        case "m", "l", "c", "v", "y", "h", "re":
            try construct(operation)
        case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
            try paint(operation)
        case "W", "W*":
            clipRule = operation.name
            if pathOperations.isEmpty { out.append(operation) } else { pathOperations.append(operation) }

        // Graphics state.
        case "q":
            try interruptPath()
            stack.append(state)
            if stack.count > 256 { throw RedactionUnsupported("the graphics state is nested deeper than 256") }
            out.append(operation)
        case "Q":
            try interruptPath()
            if let restored = stack.popLast() { state = restored }
            out.append(operation)
        case "cm":
            try interruptPath()
            guard operands.count == 6 else { throw RedactionUnsupported("a cm operator has the wrong operand count") }
            let matrix = CGAffineTransform(a: number(0), b: number(1), c: number(2), d: number(3), tx: number(4), ty: number(5))
            state.ctm = matrix.concatenating(state.ctm)
            out.append(operation)
        case "d":
            state.dashArray = (operands.first?.arrayValue ?? []).compactMap(\.doubleValue)
            state.dashPhase = number(1)
            out.append(operation)
        case "w":
            state.lineWidth = number(0)
            out.append(operation)
        case "J":
            state.lineCap = Int(exactly: number(0).rounded()) ?? 0
            out.append(operation)
        case "j":
            state.lineJoin = Int(exactly: number(0).rounded()) ?? 0
            out.append(operation)
        case "M":
            state.miterLimit = number(0)
            out.append(operation)
        case "gs":
            try graphicsStateParameters(operation)
        case "ri", "i":
            out.append(operation)

        // Colour.
        case "CS", "cs":
            var colour = PaintColour()
            colour.spaceOperation = operation
            if let name = operands.first?.nameValue {
                if name == "Pattern" {
                    colour.spaceIsPattern = true
                } else if !["DeviceGray", "DeviceRGB", "DeviceCMYK"].contains(name) {
                    use("ColorSpace", name)
                    let space = context.resolve(category("ColorSpace")?[name])
                    let family = space?.nameValue ?? space?.arrayValue?.first.flatMap { context.resolve($0)?.nameValue }
                    colour.spaceIsPattern = family == "Pattern"
                }
            }
            if operation.name == "cs" { state.fill = colour } else { state.stroke = colour }
            out.append(operation)
        case "SCN", "scn":
            var colour = operation.name == "scn" ? state.fill : state.stroke
            colour.colourOperation = operation
            colour.pattern = nil
            if colour.spaceIsPattern, let name = operands.last?.nameValue {
                referencedPatterns.insert(name)
                colour.pattern = name
                colour.patternDepth = depth
                try refuseMeshPattern(name)
            }
            if operation.name == "scn" { state.fill = colour } else { state.stroke = colour }
            out.append(operation)
        case "SC", "sc":
            if operation.name == "sc" { state.fill.colourOperation = operation; state.fill.pattern = nil } else {
                state.stroke.colourOperation = operation; state.stroke.pattern = nil
            }
            out.append(operation)
        case "G", "g", "RG", "rg", "K", "k":
            let colour = PaintColour(spaceOperation: nil, colourOperation: operation)
            if ["g", "rg", "k"].contains(operation.name) { state.fill = colour } else { state.stroke = colour }
            out.append(operation)

        // Text.
        case "BT":
            inText = true
            markedDepthAtBT = marked.count
            textMatrix = .identity
            lineMatrix = .identity
            out.append(operation)
        case "ET":
            inText = false
            // Text shown in a clipping mode clips to the glyph outlines: the clip keeps its
            // bounds but is no longer exactly a rectangle.
            if textClipPending { state.clip.exact = false; textClipPending = false }
            out.append(operation)
        case "Tc": state.text.charSpacing = number(0); out.append(operation)
        case "Tw": state.text.wordSpacing = number(0); out.append(operation)
        case "Tz": state.text.horizontalScale = number(0) / 100; out.append(operation)
        case "TL": state.text.leading = number(0); out.append(operation)
        case "Ts": state.text.rise = number(0); out.append(operation)
        case "Tr":
            // Converted exactly, as J and j are: `99999999999999999999 Tr` lexes as the real 1e20
            // and `Int(1e20)` trapped (T-039). A mode outside 0…7 says nothing about what a viewer
            // draws, so the sheet goes to the raster path rather than being cut by a guess.
            guard let mode = Int(exactly: number(0).rounded(.towardZero)), (0...7).contains(mode) else {
                throw RedactionUnsupported("a Tr operator sets a text render mode outside 0 to 7")
            }
            state.text.renderMode = mode
            out.append(operation)
        case "Tf":
            guard let name = operands.first?.nameValue else { throw RedactionUnsupported("a Tf operator names no font") }
            state.text.fontReference = category("Font")?[name] ?? .null
            state.text.fontSize = number(1)
            use("Font", name)
            out.append(operation)
        case "Td":
            lineMatrix = CGAffineTransform(translationX: number(0), y: number(1)).concatenating(lineMatrix)
            textMatrix = lineMatrix
            out.append(operation)
        case "TD":
            state.text.leading = -number(1)
            lineMatrix = CGAffineTransform(translationX: number(0), y: number(1)).concatenating(lineMatrix)
            textMatrix = lineMatrix
            out.append(operation)
        case "Tm":
            guard operands.count == 6 else { throw RedactionUnsupported("a Tm operator has the wrong operand count") }
            lineMatrix = CGAffineTransform(a: number(0), b: number(1), c: number(2), d: number(3), tx: number(4), ty: number(5))
            textMatrix = lineMatrix
            out.append(operation)
        case "T*":
            nextLine()
            out.append(operation)
        case "Tj", "TJ", "'", "\"":
            try showText(operation)

        // XObjects, images, shadings.
        case "Do":
            try paintXObject(operation)
        case "BI":
            try paintInlineImage(operation)
        case "sh":
            try paintShading(operation)

        // Marked content.
        case "BMC":
            out.append(operation)
            marked.append(MarkedContent(outputIndex: out.count - 1, tag: operands.first ?? .name("Span"), properties: nil))
        case "BDC":
            out.append(operation)
            var properties: [String: PDFObject]?
            var resourceName: String?
            if operands.count > 1 {
                if let name = operands[1].nameValue {
                    propertyUses[name, default: 0] += 1
                    resourceName = name
                    properties = context.resolve(category("Properties")?[name])?.dictionaryValue
                } else {
                    properties = operands[1].dictionaryValue
                }
            }
            let carriesText = properties.map { $0["ActualText"] != nil || $0["Alt"] != nil || $0["E"] != nil } ?? false
            marked.append(MarkedContent(
                outputIndex: out.count - 1, tag: operands.first ?? .name("Span"),
                properties: carriesText ? properties : nil, resourceName: resourceName
            ))
        case "EMC":
            out.append(operation)
            if !marked.isEmpty { closeMarkedContent() }
        case "MP":
            out.append(operation)
        case "DP":
            if operands.count > 1, let name = operands[1].nameValue { propertyUses[name, default: 0] += 1 }
            out.append(operation)
        case "BX", "EX":
            out.append(operation)
        case "d0", "d1":
            out.append(operation)

        default:
            // An operator no reader draws, e.g. PostScript or a private extension: its
            // operands could carry anything, so it is not copied.
            changed = true
        }
    }

    // MARK: - Graphics state parameters

    private mutating func graphicsStateParameters(_ operation: RedactionOperation) throws {
        guard let name = operation.operands.first?.nameValue else { throw RedactionUnsupported("a gs operator names nothing") }
        use("ExtGState", name)
        out.append(operation)
        let reference = category("ExtGState")?[name]
        guard let parameters = context.resolve(reference)?.dictionaryValue else { return }
        if context.needsExamination(reference) {
            throw RedactionUnsupported("a graphics state holds something that lay under a box")
        }
        if let width = context.resolve(parameters["LW"])?.doubleValue { state.lineWidth = width }
        if let cap = context.resolve(parameters["LC"])?.integerValue { state.lineCap = cap }
        if let join = context.resolve(parameters["LJ"])?.integerValue { state.lineJoin = join }
        if let limit = context.resolve(parameters["ML"])?.doubleValue { state.miterLimit = limit }
        if let dash = context.resolve(parameters["D"])?.arrayValue, dash.count == 2 {
            state.dashArray = (context.resolve(dash[0])?.arrayValue ?? []).compactMap { context.resolve($0)?.doubleValue }
            state.dashPhase = context.resolve(dash[1])?.doubleValue ?? 0
        }
        if let font = context.resolve(parameters["Font"])?.arrayValue, font.count == 2 {
            state.text.fontReference = font[0]
            state.text.fontSize = context.resolve(font[1])?.doubleValue ?? 0
        }
        if let maskValue = parameters["SMask"] {
            if context.resolve(maskValue)?.nameValue == "None" {
                state.softMasked = false
            } else if let mask = context.resolve(maskValue)?.dictionaryValue {
                state.softMasked = true
                if case let .stream(group, _)? = context.resolve(mask["G"]) {
                    let matrix = Self.matrix(context.resolve(group["Matrix"]), context) ?? .identity
                    let bbox = Self.rect(context.resolve(group["BBox"]), context) ?? .infinite
                    let placed = bbox.isInfinite ? CGRect.infinite : bbox.applying(matrix.concatenating(state.ctm))
                    if context.redacting, boxes.contains(where: { RedactionGeometry.intersects(placed, $0) }) {
                        try cannotCut("a soft mask is drawn under a box", tainting: [reference])
                    }
                }
            }
        }
    }

    // MARK: - Paths

    private mutating func construct(_ operation: RedactionOperation) throws {
        let values = operation.operands.compactMap(\.doubleValue)
        func point(_ index: Int) -> CGPoint { CGPoint(x: values[index], y: values[index + 1]) }
        if pathOperations.isEmpty { pathCTM = state.ctm } else if pathCTM != state.ctm {
            throw RedactionUnsupported("a path changes its coordinate system while it is built")
        }
        switch operation.name {
        case "m":
            guard values.count == 2 else { throw RedactionUnsupported("an m operator has the wrong operand count") }
            subpaths.append(RedactionSubpath(start: point(0), segments: [], closed: false))
            currentPoint = point(0)
        case "l":
            guard values.count == 2, let from = currentPoint else { throw RedactionUnsupported("an l operator has no current point") }
            appendSegment(.line(from, point(0)))
            currentPoint = point(0)
        case "c":
            guard values.count == 6, let from = currentPoint else { throw RedactionUnsupported("a c operator has no current point") }
            appendSegment(.cubic(from, point(0), point(2), point(4)))
            currentPoint = point(4)
        case "v":
            guard values.count == 4, let from = currentPoint else { throw RedactionUnsupported("a v operator has no current point") }
            appendSegment(.cubic(from, from, point(0), point(2)))
            currentPoint = point(2)
        case "y":
            guard values.count == 4, let from = currentPoint else { throw RedactionUnsupported("a y operator has no current point") }
            appendSegment(.cubic(from, point(0), point(2), point(2)))
            currentPoint = point(2)
        case "h":
            if var last = subpaths.popLast() {
                last.closed = true
                subpaths.append(last)
                currentPoint = last.start
                // A later segment starts a new subpath at the same point.
                subpaths.append(RedactionSubpath(start: last.start, segments: [], closed: false))
            }
        case "re":
            guard values.count == 4 else { throw RedactionUnsupported("an re operator has the wrong operand count") }
            let x = values[0], y = values[1], w = values[2], h = values[3]
            let a = CGPoint(x: x, y: y), b = CGPoint(x: x + w, y: y), c = CGPoint(x: x + w, y: y + h), d = CGPoint(x: x, y: y + h)
            subpaths.append(RedactionSubpath(start: a, segments: [.line(a, b), .line(b, c), .line(c, d), .line(d, a)], closed: true))
            subpaths.append(RedactionSubpath(start: a, segments: [], closed: false))
            currentPoint = a
        default:
            break
        }
        pathOperations.append(operation)
    }

    private mutating func appendSegment(_ segment: RedactionSegment) {
        if subpaths.isEmpty { subpaths.append(RedactionSubpath(start: segment.start, segments: [], closed: false)) }
        subpaths[subpaths.count - 1].segments.append(segment)
    }

    private func pathHull() -> CGRect? {
        let ctm = pathCTM ?? state.ctm
        var hull: CGRect?
        for subpath in subpaths {
            let placed = subpath.applying(ctm).hull
            hull = hull.map { $0.union(placed) } ?? placed
        }
        return hull
    }

    private mutating func resetPath() {
        pathOperations.removeAll(keepingCapacity: true)
        subpaths.removeAll(keepingCapacity: true)
        currentPoint = nil
        clipRule = nil
        pathCTM = nil
    }

    private mutating func interruptPath() throws {
        guard !pathOperations.isEmpty else { return }
        guard cutting else {
            // No boxes: the path is passed on as written, and a clip it may have set is no longer
            // known to be a rectangle.
            out.append(contentsOf: pathOperations)
            if clipRule != nil { state.clip.exact = false }
            resetPath()
            return
        }
        throw RedactionUnsupported("a path is interrupted by a graphics-state operator before it is painted")
    }

    /// The current path is exactly one axis-aligned rectangle on the page.
    private func pathIsPageRectangle(_ ctm: CGAffineTransform) -> Bool {
        let constructors = pathOperations.filter { !["W", "W*"].contains($0.name) }
        guard constructors.count == 1, constructors[0].name == "re" else { return false }
        return (abs(ctm.b) < 1e-9 && abs(ctm.c) < 1e-9) || (abs(ctm.a) < 1e-9 && abs(ctm.d) < 1e-9)
    }

    /// The painted area of a stroke: the path's hull grown by how far the placed stroke reaches
    /// past its centreline — half the line width, times the longest mitre or square cap the path
    /// actually draws (S-067). The stretch is the transform's largest singular value, which bounds
    /// every direction a sheared or unevenly scaled width can take.
    private func strokeHull(_ hull: CGRect, _ ctm: CGAffineTransform) -> CGRect {
        let reach = RedactionGeometry.strokeReach(
            subpaths, lineCap: state.lineCap, lineJoin: state.lineJoin, miterLimit: state.miterLimit
        )
        let half = max(state.lineWidth, 1) * RedactionGeometry.largestStretch(ctm) / 2 * reach + 1
        return hull.insetBy(dx: -half, dy: -half)
    }

    private mutating func paint(_ operation: RedactionOperation) throws {
        let ctm = pathCTM ?? state.ctm
        defer { resetPath() }
        let name = operation.name
        // s, b and b* close the current subpath before they paint (h S, h B, h B*). Closed here,
        // before anything is measured, so the closing join and the join at the start vertex
        // count in the stroke's reach — for the touched test, the pattern cut's area and the
        // geometry that is cut (S-067). A current subpath holding only a moveto closes nothing.
        if ["s", "b", "b*"].contains(name), let last = subpaths.indices.last, !subpaths[last].segments.isEmpty {
            subpaths[last].closed = true
        }
        let fills = ["f", "F", "f*", "B", "B*", "b", "b*"].contains(name)
        let strokes = ["S", "s", "B", "B*", "b", "b*"].contains(name)
        let hull = pathHull()
        // A stroke paints half its width either side of the centreline: a thick wall line
        // running just outside a box still inks inside it, and must be cut (R-111).
        let touched = hull.map { hull in
            let painted = strokes ? strokeHull(hull, ctm) : hull
            return boxes.contains { RedactionGeometry.intersects(painted, $0) }
        } ?? false
        defer { if clipRule != nil { updateClip(hull: hull, exactRectangle: !touched && pathIsPageRectangle(ctm)) } }
        guard touched else {
            if fills { try paintsWithPattern(fill: true) }
            if strokes { try paintsWithPattern(fill: false) }
            out.append(contentsOf: pathOperations)
            out.append(operation)
            return
        }
        changed = true
        markRemoval()
        let geometry = subpaths.filter { !$0.segments.isEmpty }
        let determinant = ctm.a * ctm.d - ctm.b * ctm.c
        guard abs(determinant) > 1e-12 else {
            // A degenerate coordinate system paints nothing visible; the path goes, and a clip
            // it set becomes empty.
            if let rule = clipRule { out.append(contentsOf: Self.emptyClip(rule)) }
            return
        }
        let inverse = ctm.inverted()
        let placed = geometry.map { $0.applying(ctm) }
        let evenOdd = name.hasSuffix("*")

        if fills {
            let region = RedactionGeometry.difference(placed, boxes: boxes)
            if region.isEmpty {
                // Everything this fill painted lay under the boxes; so did its pattern's cell.
                if state.fill.pattern != nil, state.fill.patternDepth == depth { context.taint(category("Pattern")?[state.fill.pattern ?? ""]) }
            } else {
                let replacement = try patternForCut(fill: true, area: hull ?? .null)
                out.append(contentsOf: replacement?.before ?? [])
                out.append(contentsOf: Self.emit(region, inverse))
                out.append(RedactionOperation(evenOdd ? "f*" : "f"))
                out.append(contentsOf: replacement?.after ?? [])
            }
        }
        if strokes {
            let pieces = RedactionGeometry.clipStroke(placed, boxes: boxes) { $0.applying(inverse).length }
            if pieces.isEmpty {
                if state.stroke.pattern != nil, state.stroke.patternDepth == depth { context.taint(category("Pattern")?[state.stroke.pattern ?? ""]) }
            } else {
                let replacement = try patternForCut(fill: false, area: strokeHull(hull ?? .null, ctm))
                out.append(RedactionOperation("q"))
                out.append(contentsOf: replacement?.before ?? [])
                out.append(contentsOf: exclusionClip(inverse))
                let dashed = !state.dashArray.isEmpty && state.dashArray.contains { $0 > 0 }
                if dashed {
                    for piece in pieces {
                        if !piece.startsOriginal {
                            out.append(RedactionOperation("d", [.array(state.dashArray.map { .real($0) }), .real(state.dashPhase + piece.offset)]))
                        }
                        out.append(contentsOf: Self.emit([piece.subpath], inverse))
                        out.append(RedactionOperation("S"))
                        if !piece.startsOriginal {
                            out.append(RedactionOperation("d", [.array(state.dashArray.map { .real($0) }), .real(state.dashPhase)]))
                        }
                    }
                } else {
                    out.append(contentsOf: Self.emit(pieces.map(\.subpath), inverse))
                    out.append(RedactionOperation("S"))
                }
                out.append(RedactionOperation("Q"))
            }
        }
        if let rule = clipRule {
            let region = RedactionGeometry.difference(placed, boxes: boxes)
            if region.isEmpty {
                out.append(contentsOf: Self.emptyClip(rule))
            } else {
                out.append(contentsOf: Self.emit(region, inverse))
                out.append(RedactionOperation(rule))
                out.append(RedactionOperation("n"))
            }
        }
    }

    private mutating func updateClip(hull: CGRect?, exactRectangle: Bool) {
        guard let hull, !subpaths.allSatisfy({ $0.segments.isEmpty }) else {
            state.clip = Clip(bounds: .null, exact: true)
            return
        }
        state.clip = state.clip.intersecting(hull, exact: exactRectangle)
    }

    private static func emptyClip(_ rule: String) -> [RedactionOperation] {
        [RedactionOperation("re", [.integer(0), .integer(0), .integer(0), .integer(0)]), RedactionOperation(rule), RedactionOperation("n")]
    }

    /// Path operators for subpaths given in page space, written in the current user space.
    static func emit(_ subpaths: [RedactionSubpath], _ inverse: CGAffineTransform) -> [RedactionOperation] {
        var ops: [RedactionOperation] = []
        func p(_ point: CGPoint) -> [PDFObject] {
            let user = point.applying(inverse)
            return [.real(Double(user.x)), .real(Double(user.y))]
        }
        for subpath in subpaths where !subpath.segments.isEmpty {
            ops.append(RedactionOperation("m", p(subpath.start)))
            for segment in subpath.segments {
                switch segment {
                case let .line(_, b): ops.append(RedactionOperation("l", p(b)))
                case let .cubic(_, c1, c2, e): ops.append(RedactionOperation("c", p(c1) + p(c2) + p(e)))
                }
            }
            if subpath.closed { ops.append(RedactionOperation("h")) }
        }
        return ops
    }

    /// `W n` over everything outside the boxes, in the current user space.
    private func exclusionClip(_ inverse: CGAffineTransform) -> [RedactionOperation] {
        let region = RedactionGeometry.outside(of: boxes, within: context.frame)
        return Self.emit(region, inverse) + [RedactionOperation("W"), RedactionOperation("n")]
    }

    /// Whether everything inside `corners` (a placed image or form box) shows: the clip is
    /// exactly a rectangle that holds it, and no soft mask can hide part of it.
    private func showsWhole(_ corners: [CGPoint]) -> Bool {
        guard state.clip.exact, !state.softMasked, !state.clip.bounds.isNull else { return false }
        let bounds = state.clip.bounds.insetBy(dx: -0.01, dy: -0.01)
        return corners.allSatisfy { bounds.contains($0) }
    }

    /// What `corners` can show at most: their bounds within the clip.
    private func visibleRect(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let extent = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        return state.clip.bounds.intersection(extent)
    }

    // MARK: - Patterns

    /// A mesh shading used through a pattern falls back like one painted with `sh` (finding 7).
    private func refuseMeshPattern(_ name: String) throws {
        let reference = category("Pattern")?[name]
        guard context.redacting, let pattern = context.resolve(reference)?.dictionaryValue,
              context.resolve(pattern["PatternType"])?.integerValue == 2,
              let shading = context.resolve(pattern["Shading"])?.dictionaryValue,
              let type = context.resolve(shading["ShadingType"])?.integerValue, (4...7).contains(type) else { return }
        try cannotCut("a mesh shading (type \(type)) is painted through a pattern on a sheet with a box", tainting: [reference])
    }

    /// A kept paint uses the current fill or stroke pattern in its original form.
    private mutating func paintsWithPattern(fill: Bool) throws {
        let colour = fill ? state.fill : state.stroke
        guard let name = colour.pattern else { return }
        guard colour.patternDepth == depth else {
            // Set in a parent stream: the parent learns it was painted with.
            if fill { paintedInheritedFill = true } else { paintedInheritedStroke = true }
            return
        }
        if context.needsExamination(category("Pattern")?[name]) {
            throw RedactionUnsupported("a pattern painted under a box is painted elsewhere as well")
        }
        use("Pattern", name)
    }

    private func patternIsExamined(_ colour: PaintColour) -> Bool {
        guard let name = colour.pattern else { return false }
        guard colour.patternDepth == depth else { return true }
        return context.needsExamination(category("Pattern")?[name])
    }

    /// A paint touching a box with a pattern colour: the operators to paint it with a copy of the
    /// pattern cut for the one tile it covers, and to set the colour back after, or `nil` when
    /// the pattern paints nothing under the boxes and the original may be kept (findings 1, 5,
    /// 15). A cell repeated across the painted area, or a shading pattern, cannot be cut exactly.
    private mutating func patternForCut(fill: Bool, area: CGRect) throws -> (before: [RedactionOperation], after: [RedactionOperation])? {
        let colour = fill ? state.fill : state.stroke
        guard let name = colour.pattern else { return nil }
        guard context.redacting else {
            try paintsWithPattern(fill: fill)
            return nil
        }
        guard colour.patternDepth == depth else {
            try cannotCut("a pattern set outside a form is painted under a box inside it")
            return nil
        }
        let reference = category("Pattern")?[name]
        guard case let .stream(dictionary, data)? = context.resolve(reference) else {
            if let pattern = context.resolve(reference)?.dictionaryValue, context.resolve(pattern["PatternType"])?.integerValue == 2 {
                try cannotCut("a shading pattern is painted partly under a box", tainting: [reference])
                return nil
            }
            try paintsWithPattern(fill: fill)
            return nil
        }
        guard let layout = tiles(dictionary, covering: area) else {
            try cannotCut("a tiling pattern painted under a box has no usable cell", tainting: [reference])
            return nil
        }
        if layout.many {
            // Its cell shows in every other tile as well, so it is not marked as lying under the box.
            try cannotCut("a repeating pattern is painted under a box")
            return nil
        }
        guard let tile = layout.tiles.first else {
            // No tile of the cell reaches the painted area: the pattern paints nothing here.
            try paintsWithPattern(fill: fill)
            return nil
        }
        // One copy per tile: the cell is cut where that tile puts it on the sheet.
        let key = "\(name)|\(tile.0)|\(tile.1)"
        let replacement: String
        if let cached = cutPatterns[key] {
            replacement = cached
        } else {
            let attempt: String?
            do {
                attempt = try cutPattern(reference: reference, dictionary: dictionary, data: data, placement: layout.matrix, area: area)
            } catch let error as RedactionUnsupported where context.surveying {
                _ = error
                context.surveyTaint([reference])
                return nil
            }
            guard let cut = attempt else {
                try paintsWithPattern(fill: fill)
                return nil
            }
            replacement = cut
            cutPatterns[key] = cut
        }
        func operators(_ patternName: String) -> [RedactionOperation] {
            var ops: [RedactionOperation] = []
            if let space = colour.spaceOperation { ops.append(space) }
            if var set = colour.colourOperation, let last = set.operands.indices.last {
                set.operands[last] = .name(patternName)
                ops.append(set)
            }
            return ops
        }
        return (operators(replacement), operators(name))
    }

    /// The tiles of a tiling pattern whose cell box meets `area` (page space).
    private func tiles(_ dictionary: [String: PDFObject], covering area: CGRect) -> (matrix: CGAffineTransform, tiles: [(Int, Int)], many: Bool)? {
        let matrix = (Self.matrix(context.resolve(dictionary["Matrix"]), context) ?? .identity).concatenating(patternBase)
        guard abs(matrix.a * matrix.d - matrix.b * matrix.c) > 1e-12, !area.isNull,
              let cell = Self.rect(context.resolve(dictionary["BBox"]), context),
              let xStep = context.resolve(dictionary["XStep"])?.doubleValue, let yStep = context.resolve(dictionary["YStep"])?.doubleValue,
              abs(xStep) > 1e-9, abs(yStep) > 1e-9 else { return nil }
        let inverse = matrix.inverted()
        let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                       CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)].map { $0.applying(inverse) }
        switch RedactionGeometry.tileCover(corners: corners, cell: cell, xStep: xStep, yStep: yStep) {
        case .none: return (matrix, [], false)
        case .many: return (matrix, [], true)
        case let .one(i, j):
            return (CGAffineTransform(translationX: Double(i) * abs(xStep), y: Double(j) * abs(yStep)).concatenating(matrix), [(i, j)], false)
        }
    }

    /// A copy of the pattern whose cell is rewritten for the tile `placement` puts on the sheet
    /// (pattern space → page), under a new resource name; `nil` when nothing of the cell lies
    /// under a box there.
    private mutating func cutPattern(
        reference: PDFObject?, dictionary: [String: PDFObject], data: Data, placement: CGAffineTransform, area: CGRect
    ) throws -> String? {
        let number = reference?.referenceValue?.number ?? -1
        if context.formStack.contains(number) { throw RedactionUnsupported("a pattern paints itself") }
        guard depth < 24 else { throw RedactionUnsupported("patterns and forms nest deeper than 24") }
        let cellResources = context.resolve(dictionary["Resources"])?.dictionaryValue ?? [:]
        let content = try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data
        let operations = try RedactionContentLexer.parse(content)
        let cell = Self.rect(context.resolve(dictionary["BBox"]), context) ?? .null
        var cellState = GraphicsState(ctm: placement, clip: Clip(bounds: cell.applying(placement).intersection(area), exact: false))
        cellState.fill = PaintColour()
        cellState.stroke = PaintColour()
        context.formStack.append(number)
        defer { context.formStack.removeLast() }
        var inner = RedactionContentRewriter(context: context, resources: cellResources, inherited: cellState, depth: depth + 1, patternBase: placement)
        let result = try inner.rewrite(operations)
        guard result.changed else { return nil }
        var copy = dictionary
        for key in ["Filter", "DecodeParms", "Length", "Metadata", "PieceInfo", "StructParents", "StructParent"] { copy.removeValue(forKey: key) }
        copy["Resources"] = .dictionary(result.resources)
        let serialized = RedactionContentLexer.serialize(result.operations)
        var stream = serialized
        if let flate = PDFStreamCodec.flateEncode(serialized) {
            stream = flate
            copy["Filter"] = .name("FlateDecode")
        }
        let object = context.pool.add(.stream(dictionary: copy, data: stream))
        context.taint(reference)
        return addResource("Pattern", object, prefix: "ZRdPt")
    }

    // MARK: - Text

    private mutating func nextLine() {
        lineMatrix = CGAffineTransform(translationX: 0, y: -state.text.leading).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    private mutating func showText(_ operation: RedactionOperation) throws {
        guard inText || !cutting else { throw RedactionUnsupported("text is shown outside a text object") }
        var elements: [PDFObject]
        var prefix: [RedactionOperation] = []
        switch operation.name {
        case "Tj":
            elements = Array(operation.operands.prefix(1))
        case "TJ":
            elements = operation.operands.first?.arrayValue ?? []
        case "'":
            nextLine()
            prefix = [RedactionOperation("T*")]
            elements = Array(operation.operands.suffix(1))
        default: // "
            guard operation.operands.count == 3 else { throw RedactionUnsupported("a \" operator has the wrong operand count") }
            state.text.wordSpacing = operation.operands[0].doubleValue ?? 0
            state.text.charSpacing = operation.operands[1].doubleValue ?? 0
            nextLine()
            prefix = [RedactionOperation("Tw", [operation.operands[0]]), RedactionOperation("Tc", [operation.operands[1]]), RedactionOperation("T*")]
            elements = [operation.operands[2]]
        }
        let text = state.text
        if text.renderMode >= 4 { textClipPending = true }
        let fontReference = text.fontReference
        let fontNumber = fontReference?.referenceValue?.number
        let fillsGlyphs = [0, 2, 4, 6].contains(text.renderMode), strokesGlyphs = [1, 2, 5, 6].contains(text.renderMode)
        if !cutting {
            // No boxes: glyph positions do not matter; a font is read only to learn which codes
            // it still draws (a font that lost glyphs under a box elsewhere).
            if let fontNumber, context.dirty.contains(fontNumber), !context.taintedFonts.contains(fontNumber),
               context.resolve(fontReference)?.dictionaryValue?["CharProcs"] != nil {
                throw RedactionUnsupported("a Type 3 font draws something that lay under a box")
            }
            if fillsGlyphs { try paintsWithPattern(fill: true) }
            if strokesGlyphs { try paintsWithPattern(fill: false) }
            if let fontNumber, context.taintedFonts.contains(fontNumber) {
                let splitter = try context.splitter(fontReference)
                for element in elements {
                    guard let bytes = Self.stringBytes(element) else { continue }
                    context.drawnCodes[fontNumber, default: []].formUnion(try splitter.codes(bytes))
                }
            }
            out.append(operation)
            return
        }
        let font: RedactionFont
        do {
            font = try context.font(fontReference)
        } catch let error as RedactionUnsupported where context.surveying {
            // A font the rewriter cannot measure, on a sheet becoming a picture: any of its glyphs
            // may have stood under a box.
            _ = error
            context.surveyTaint([fontReference])
            out.append(operation)
            return
        }
        if let fontNumber, !context.surveying, context.dirty.contains(fontNumber), !context.taintedFonts.contains(fontNumber), font.kind == .type3 {
            throw RedactionUnsupported("a Type 3 font draws something that lay under a box")
        }
        let size = text.fontSize
        let scale = text.horizontalScale
        let startMatrix = textMatrix
        var inkNearBox = false
        // Text space for a font size of 1 → page: [size·Th 0 0 size 0 rise] × Tm × CTM.
        var newElements: [PDFObject] = []
        var pendingAdjustment = 0.0
        var run: [UInt8] = []
        var runIsHex = false
        var removedAny = false
        var glyphs: [(text: String?, removed: Bool)] = []
        var keptCodes: [RedactionFont.Code] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if pendingAdjustment != 0 { newElements.append(.real(pendingAdjustment)); pendingAdjustment = 0 }
            newElements.append(runIsHex ? .hexString(run) : .string(run))
            run = []
        }

        for element in elements {
            if let adjustment = element.doubleValue {
                if !run.isEmpty { flushRun() }
                pendingAdjustment += adjustment
                textMatrix = CGAffineTransform(translationX: -adjustment / 1000 * size * scale, y: 0).concatenating(textMatrix)
                continue
            }
            let bytes: [UInt8]
            let isHex: Bool
            switch element {
            case let .string(value): bytes = value; isHex = false
            case let .hexString(value): bytes = value; isHex = true
            default: continue
            }
            if !run.isEmpty, runIsHex != isHex { flushRun() }
            runIsHex = isHex
            let codes = try font.codes(bytes)
            var offset = 0
            for code in codes {
                let codeBytes = Array(bytes[offset..<(offset + code.length)])
                offset += code.length
                let advanceWidth = font.width(code)
                let spacing = text.charSpacing + (font.takesWordSpacing(code) ? text.wordSpacing : 0)
                let advance = (advanceWidth * size + spacing) * scale
                let glyph = font.box(code)
                let toPage = CGAffineTransform(a: size * scale, b: 0, c: 0, d: size, tx: 0, ty: text.rise)
                    .concatenating(textMatrix).concatenating(state.ctm)
                let corners = [CGPoint(x: glyph.minX, y: glyph.minY), CGPoint(x: glyph.maxX, y: glyph.minY),
                               CGPoint(x: glyph.maxX, y: glyph.maxY), CGPoint(x: glyph.minX, y: glyph.maxY)].map { $0.applying(toPage) }
                let hit: Bool
                if let crop = context.cropRect {
                    // Cut down to what shows: a glyph goes only when none of it shows.
                    hit = !Self.quad(corners, intersects: crop)
                } else {
                    hit = boxes.contains { Self.quad(corners, intersects: $0) }
                }
                if hit {
                    if text.renderMode >= 4 || abs(size) <= 1e-12 {
                        try cannotCut(text.renderMode >= 4 ? "text that clips is drawn under a box" : "text of size zero is drawn under a box",
                                      tainting: [fontReference])
                        out.append(operation)
                        return
                    }
                    flushRun()
                    // The removed glyph's advance, as a TJ adjustment: tx = −n/1000 · size · Th.
                    pendingAdjustment += -(advanceWidth * size + spacing) * 1000 / size
                    removedAny = true
                    if context.records {
                        context.work.removedGlyphs += 1
                        context.work.removedGlyphQuads.append(corners)
                    }
                    markRemoval()
                } else {
                    run.append(contentsOf: codeBytes)
                    keptCodes.append(code)
                    if !inkNearBox, text.renderMode != 3 {
                        let ink = font.inkEnvelope(code)
                        let inkCorners = [CGPoint(x: ink.minX, y: ink.minY), CGPoint(x: ink.maxX, y: ink.minY),
                                          CGPoint(x: ink.maxX, y: ink.maxY), CGPoint(x: ink.minX, y: ink.maxY)].map { $0.applying(toPage) }
                        inkNearBox = boxes.contains { Self.quad(inkCorners, intersects: $0) }
                    }
                    let unicode = font.unicode(code)
                    for index in marked.indices where marked[index].properties != nil {
                        if let unicode { marked[index].keptText += unicode } else { marked[index].textKnown = false }
                    }
                }
                glyphs.append((font.unicode(code), hit))
                textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
            }
        }
        // A kept glyph whose ink may reach into a box is drawn under a clip to the area outside
        // the boxes, so nothing at all is painted under them.
        let clip = inkNearBox ? textClip(from: startMatrix, to: textMatrix) : nil
        if removedAny || clip != nil {
            // Glyphs painted with a pattern colour show its cell; the cell cannot be cut per glyph.
            if (fillsGlyphs && state.fill.pattern != nil) || (strokesGlyphs && state.stroke.pattern != nil) {
                try cannotCut("text painted with a pattern is cut by a box",
                              tainting: [category("Pattern")?[state.fill.pattern ?? ""], category("Pattern")?[state.stroke.pattern ?? ""]])
            }
        } else {
            if fillsGlyphs { try paintsWithPattern(fill: true) }
            if strokesGlyphs { try paintsWithPattern(fill: false) }
        }
        if let fontNumber {
            if removedAny, context.records { context.taintedFonts.insert(fontNumber); context.tainted.insert(fontNumber) }
            if context.taintedFonts.contains(fontNumber) { context.drawnCodes[fontNumber, default: []].formUnion(keptCodes) }
        } else if removedAny, context.records {
            try cannotCut("a font defined inline in the resources has glyphs under a box")
        }
        guard removedAny || clip != nil else {
            out.append(operation)
            return
        }
        changed = true
        if removedAny {
            flushRun()
            if pendingAdjustment != 0 { newElements.append(.real(pendingAdjustment)) }
            if context.records { recordRemovedWords(glyphs) }
        } else {
            newElements = elements
        }
        out.append(contentsOf: prefix)
        let show = newElements.isEmpty ? [] : [RedactionOperation("TJ", [.array(newElements)])]
        if let clip {
            out.append(contentsOf: clip.before)
            out.append(contentsOf: show)
            out.append(contentsOf: clip.after)
        } else {
            out.append(contentsOf: show)
        }
    }

    private static func stringBytes(_ element: PDFObject) -> [UInt8]? {
        switch element {
        case let .string(value), let .hexString(value): value
        default: nil
        }
    }

    /// The operators that end the text object, clip to the area outside the boxes, and resume
    /// it at the same text position — and the ones that undo the clip and resume it at the end
    /// position. `nil` when that cannot be done exactly (a marked-content sequence opened inside
    /// the text object, clipping text, a degenerate matrix); the verifier then decides.
    private func textClip(from start: CGAffineTransform, to end: CGAffineTransform) -> (before: [RedactionOperation], after: [RedactionOperation])? {
        let text = state.text
        guard text.renderMode < 4, marked.count == markedDepthAtBT else { return nil }
        let unit = text.fontSize * text.horizontalScale
        let determinant = lineMatrix.a * lineMatrix.d - lineMatrix.b * lineMatrix.c
        let ctmDeterminant = state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c
        guard abs(unit) > 1e-12, abs(determinant) > 1e-12, abs(ctmDeterminant) > 1e-12 else { return nil }
        let inverseLine = lineMatrix.inverted()
        // Within a line the text matrix is the line matrix moved along x in text space.
        func offset(_ matrix: CGAffineTransform) -> Double? {
            let relative = matrix.concatenating(inverseLine)
            guard abs(relative.a - 1) < 1e-6, abs(relative.d - 1) < 1e-6, abs(relative.b) < 1e-6, abs(relative.c) < 1e-6, abs(relative.ty) < 1e-6 else { return nil }
            return relative.tx
        }
        guard let startOffset = offset(start), let endOffset = offset(end) else { return nil }
        let line = RedactionOperation("Tm", [lineMatrix.a, lineMatrix.b, lineMatrix.c, lineMatrix.d, lineMatrix.tx, lineMatrix.ty].map { .real(Double($0)) })
        func move(_ tx: Double) -> [RedactionOperation] {
            abs(tx) < 1e-9 ? [] : [RedactionOperation("TJ", [.array([.real(-tx * 1000 / unit)])])]
        }
        let before = [RedactionOperation("ET"), RedactionOperation("q")] + exclusionClip(state.ctm.inverted())
            + [RedactionOperation("BT"), line] + move(startOffset)
        let after = [RedactionOperation("ET"), RedactionOperation("Q"), RedactionOperation("BT"), line] + move(endOffset)
        return (before, after)
    }

    private func recordRemovedWords(_ glyphs: [(text: String?, removed: Bool)]) {
        var word = ""
        var wholeRemoved = true
        func finish() {
            if !word.isEmpty, wholeRemoved { context.work.removedWords.append(word) }
            word = ""
            wholeRemoved = true
        }
        for glyph in glyphs {
            guard let text = glyph.text else { wholeRemoved = false; continue }
            if text.allSatisfy({ $0.isWhitespace }) { finish(); continue }
            word += text
            if !glyph.removed { wholeRemoved = false }
        }
        finish()
    }

    /// Separating-axis test of a parallelogram against an axis-aligned box's open interior.
    static func quad(_ corners: [CGPoint], intersects box: CGRect) -> Bool {
        let e = RedactionGeometry.epsilon
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard (xs.max() ?? 0) > box.minX + e, (xs.min() ?? 0) < box.maxX - e,
              (ys.max() ?? 0) > box.minY + e, (ys.min() ?? 0) < box.maxY - e else { return false }
        let boxCorners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                          CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        for index in 0..<2 {
            let a = corners[index], b = corners[index + 1]
            let axis = CGPoint(x: -(b.y - a.y), y: b.x - a.x)
            guard hypot(axis.x, axis.y) > 1e-12 else { continue }
            let project = { (p: CGPoint) in p.x * axis.x + p.y * axis.y }
            let q = corners.map(project), r = boxCorners.map(project)
            let tolerance = e * hypot(axis.x, axis.y)
            if (q.max() ?? 0) <= (r.min() ?? 0) + tolerance || (r.max() ?? 0) <= (q.min() ?? 0) + tolerance { return false }
        }
        return true
    }

    /// Something inside the open marked-content sequences was cut: their replacement text and
    /// alternate descriptions can no longer be trusted to describe only what is left.
    private mutating func markRemoval() {
        for index in marked.indices { marked[index].dirty = true }
    }

    private mutating func closeMarkedContent() {
        guard let entry = marked.popLast() else { return }
        guard entry.dirty, var properties = entry.properties else { return }
        properties.removeValue(forKey: "Alt")
        properties.removeValue(forKey: "E")
        if properties["ActualText"] != nil {
            if entry.textKnown, !entry.keptText.isEmpty {
                properties["ActualText"] = .hexString([0xFE, 0xFF] + entry.keptText.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            } else {
                properties.removeValue(forKey: "ActualText")
            }
        }
        out[entry.outputIndex] = RedactionOperation("BDC", [entry.tag, .dictionary(properties)])
        // The named property list still holds the old text; it is no longer referenced here.
        if let name = entry.resourceName { propertyUses[name, default: 1] -= 1 }
        changed = true
    }

    // MARK: - XObjects

    private mutating func paintXObject(_ operation: RedactionOperation) throws {
        guard let name = operation.operands.first?.nameValue else { throw RedactionUnsupported("a Do operator names nothing") }
        let reference = category("XObject")?[name]
        guard case let .stream(dictionary, data)? = context.resolve(reference) else {
            // A missing XObject draws nothing.
            changed = true
            return
        }
        switch context.resolve(dictionary["Subtype"])?.nameValue {
        case "Image":
            try paintImage(name: name, reference: reference, dictionary: dictionary, data: data, operation: operation)
        case "Form":
            try paintForm(name: name, reference: reference, dictionary: dictionary, data: data, operation: operation)
        case "PS":
            changed = true
        default:
            throw RedactionUnsupported("an XObject of an unknown kind is drawn")
        }
    }

    private static func unitSquare(_ ctm: CGAffineTransform) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { $0.applying(ctm) }
    }

    /// Whether an image placed by `ctm` touches the boxes (or, in a crop, reaches outside what
    /// shows), and whether all of it goes (wholly inside one box; wholly outside a crop).
    private func imageCoverage(_ ctm: CGAffineTransform) -> (touches: Bool, removeWhole: Bool) {
        let corners = Self.unitSquare(ctm)
        let touches = boxes.contains { Self.quad(corners, intersects: $0) }
        if let crop = context.cropRect { return (touches, !Self.quad(corners, intersects: crop)) }
        let insideOne = boxes.contains { box in corners.allSatisfy { $0.x >= box.minX && $0.x <= box.maxX && $0.y >= box.minY && $0.y <= box.maxY } }
        return (touches, insideOne)
    }

    private var imageRule: RedactionImages.Rule {
        if let crop = context.cropRect { return .keepCellsMeeting(crop) }
        return .blankCentresIn(boxes)
    }

    private mutating func paintImage(
        name: String, reference: PDFObject?, dictionary: [String: PDFObject], data: Data, operation: RedactionOperation
    ) throws {
        let isMask = context.resolve(dictionary["ImageMask"]) == .boolean(true)
        let coverage = imageCoverage(state.ctm)
        guard coverage.touches else {
            if isMask { try paintsWithPattern(fill: true) }
            if context.needsExamination(reference) {
                // A picture cut under a box elsewhere (finding 8): kept whole only where it shows
                // whole; otherwise a copy with only the samples this placement can show.
                let corners = Self.unitSquare(state.ctm)
                if showsWhole(corners) {
                    justify(reference, dictionary)
                } else {
                    try paintCroppedImage(dictionary: dictionary, data: data, visible: visibleRect(corners))
                    return
                }
            }
            use("XObject", name)
            out.append(operation)
            return
        }
        if isMask, state.fill.pattern != nil {
            try cannotCut("a stencil mask painted with a pattern is cut by a box", tainting: [category("Pattern")?[state.fill.pattern ?? ""]])
        }
        changed = true
        markRemoval()
        context.taint(reference)
        for key in ["SMask", "Mask"] where dictionary[key]?.referenceValue != nil { context.taint(dictionary[key]) }
        let determinant = state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c
        if coverage.removeWhole || abs(determinant) < 1e-12 {
            return
        }
        let copy: PDFObject
        do {
            copy = try blankedImage(dictionary: dictionary, data: data, rule: imageRule)
        } catch let error as RedactionUnsupported where context.surveying {
            _ = error
            context.surveyTaint([reference, dictionary["SMask"], dictionary["Mask"]])
            return
        }
        let newName = addResource("XObject", copy, prefix: "ZRdIm")
        out.append(RedactionOperation("q"))
        out.append(contentsOf: exclusionClip(state.ctm.inverted()))
        out.append(RedactionOperation("Do", [.name(newName)]))
        out.append(RedactionOperation("Q"))
    }

    private func justify(_ reference: PDFObject?, _ dictionary: [String: PDFObject]) {
        for object in [reference, dictionary["SMask"], dictionary["Mask"]] {
            if let number = object?.referenceValue?.number, context.tainted.contains(number) { context.justified.insert(number) }
        }
    }

    /// The image (with its soft mask and mask) blanked by `rule`, as a new object.
    private func blankedImage(dictionary: [String: PDFObject], data: Data, rule: RedactionImages.Rule) throws -> PDFObject {
        let colorSpaces = category("ColorSpace")
        let result = try RedactionImages.redactXObject(
            dictionary: dictionary, data: data, placement: state.ctm, rule: rule, colorSpaces: colorSpaces,
            resolve: { self.context.resolve($0) }
        )
        var newDictionary = result.dictionary
        for key in ["SMask", "Mask"] {
            guard case let .stream(maskDictionary, maskData)? = context.resolve(dictionary[key]) else { continue }
            let mask = try RedactionImages.redactXObject(
                dictionary: maskDictionary, data: maskData, placement: state.ctm, rule: rule, colorSpaces: colorSpaces,
                resolve: { self.context.resolve($0) }
            )
            newDictionary[key] = context.pool.add(.stream(dictionary: mask.dictionary, data: mask.data))
        }
        return context.pool.add(.stream(dictionary: newDictionary, data: result.data))
    }

    private mutating func paintCroppedImage(dictionary: [String: PDFObject], data: Data, visible: CGRect) throws {
        changed = true
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        let copy = try blankedImage(dictionary: dictionary, data: data, rule: .keepCellsMeeting(visible))
        let newName = addResource("XObject", copy, prefix: "ZRdCr")
        out.append(RedactionOperation("Do", [.name(newName)]))
    }

    private mutating func paintForm(
        name: String, reference: PDFObject?, dictionary: [String: PDFObject], data: Data, operation: RedactionOperation
    ) throws {
        let matrix = Self.matrix(context.resolve(dictionary["Matrix"]), context) ?? .identity
        let placement = matrix.concatenating(state.ctm)
        let bbox = Self.rect(context.resolve(dictionary["BBox"]), context)
        var corners: [CGPoint] = []
        let touches: Bool
        if let bbox {
            corners = [CGPoint(x: bbox.minX, y: bbox.minY), CGPoint(x: bbox.maxX, y: bbox.minY),
                       CGPoint(x: bbox.maxX, y: bbox.maxY), CGPoint(x: bbox.minX, y: bbox.maxY)].map { $0.applying(placement) }
            touches = boxes.contains { Self.quad(corners, intersects: $0) }
        } else {
            touches = true
        }
        guard touches else {
            let examined = context.needsExamination(reference)
            if !examined, !patternIsExamined(state.fill), !patternIsExamined(state.stroke) {
                // Copied as it is; it may paint with the current colours.
                try paintsWithPattern(fill: true)
                try paintsWithPattern(fill: false)
                use("XObject", name)
                out.append(operation)
                return
            }
            // A form holding something cut under a box elsewhere (findings 4, 8): cut down to
            // what this placement shows when the form itself was cut and does not show whole,
            // otherwise rewritten here without boxes so what it draws is examined in turn.
            let formTainted = reference?.referenceValue.map { context.tainted.contains($0.number) } ?? false
            if formTainted, !showsWhole(corners) {
                let visible = visibleRect(corners)
                guard !visible.isNull, visible.width > 0, visible.height > 0 else {
                    changed = true
                    return
                }
                let saved = (context.boxes, context.cropRect)
                context.cropRect = visible
                context.boxes = context.strips(outside: visible)
                defer { (context.boxes, context.cropRect) = saved }
                let result = try rewriteForm(reference: reference, dictionary: dictionary, data: data, placement: placement, corners: corners)
                changed = true
                out.append(RedactionOperation("Do", [.name(copyForm(dictionary, result: result, data: nil, prefix: "ZRdCr"))]))
                return
            }
            let result = try rewriteForm(reference: reference, dictionary: dictionary, data: data, placement: placement, corners: corners)
            if result.paintedInheritedFill { try paintsWithPattern(fill: true) }
            if result.paintedInheritedStroke { try paintsWithPattern(fill: false) }
            let original = normalisedResources(context.resolve(dictionary["Resources"])?.dictionaryValue ?? resources)
            if !result.changed, result.resources == original {
                if let number = reference?.referenceValue?.number, context.tainted.contains(number) { context.justified.insert(number) }
                use("XObject", name)
                out.append(operation)
                return
            }
            changed = true
            out.append(RedactionOperation("Do", [.name(copyForm(dictionary, result: result, data: result.changed ? nil : data, prefix: "ZRdFm"))]))
            return
        }
        if dictionary["Ref"] != nil, context.redacting {
            try cannotCut("a reference XObject (a page imported from another file) is drawn under a box", tainting: [reference])
            return
        }
        let result: Output
        do {
            result = try rewriteForm(reference: reference, dictionary: dictionary, data: data, placement: placement, corners: corners)
        } catch let error as RedactionUnsupported where context.surveying {
            _ = error
            context.surveyTaint([reference])
            return
        }
        if result.paintedInheritedFill { try paintsWithPattern(fill: true) }
        if result.paintedInheritedStroke { try paintsWithPattern(fill: false) }
        guard result.changed else {
            use("XObject", name)
            out.append(operation)
            return
        }
        changed = true
        markRemoval()
        context.taint(reference)
        out.append(RedactionOperation("Do", [.name(copyForm(dictionary, result: result, data: nil, prefix: "ZRdFm"))]))
    }

    /// Rewrites a form's content for one placement.
    private mutating func rewriteForm(
        reference: PDFObject?, dictionary: [String: PDFObject], data: Data, placement: CGAffineTransform, corners: [CGPoint]
    ) throws -> Output {
        let number = reference?.referenceValue?.number ?? -1
        if context.formStack.contains(number) { throw RedactionUnsupported("a form XObject draws itself") }
        guard depth < 24 else { throw RedactionUnsupported("form XObjects nest deeper than 24") }
        let formResources = context.resolve(dictionary["Resources"])?.dictionaryValue ?? resources
        let content = try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data
        let operations = try RedactionContentLexer.parse(content)
        context.formStack.append(number)
        defer { context.formStack.removeLast() }
        var inherited = state
        inherited.ctm = placement
        if !corners.isEmpty {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            let axisAligned = (abs(placement.b) < 1e-9 && abs(placement.c) < 1e-9) || (abs(placement.a) < 1e-9 && abs(placement.d) < 1e-9)
            inherited.clip = state.clip.intersecting(box, exact: axisAligned)
        }
        var inner = RedactionContentRewriter(context: context, resources: formResources, inherited: inherited, depth: depth + 1, patternBase: placement)
        return try inner.rewrite(operations)
    }

    /// A new form object from `dictionary` with the rewrite's resources, and its content (`data`
    /// when the content itself is unchanged), under a new resource name.
    private mutating func copyForm(_ dictionary: [String: PDFObject], result: Output, data: Data?, prefix: String) -> String {
        var newDictionary = dictionary
        for key in ["Length", "Metadata", "PieceInfo", "LastModified", "StructParents", "StructParent", "OPI", "PS", "Subtype2"] {
            newDictionary.removeValue(forKey: key)
        }
        newDictionary["Resources"] = .dictionary(result.resources)
        let payload: Data
        if let data {
            payload = data
        } else {
            newDictionary.removeValue(forKey: "Filter")
            newDictionary.removeValue(forKey: "DecodeParms")
            let serialized = RedactionContentLexer.serialize(result.operations)
            if let flate = PDFStreamCodec.flateEncode(serialized) {
                payload = flate
                newDictionary["Filter"] = .name("FlateDecode")
            } else {
                payload = serialized
            }
        }
        let copy = context.pool.add(.stream(dictionary: newDictionary, data: payload))
        return addResource("XObject", copy, prefix: prefix)
    }

    /// A resource dictionary with each category resolved to a direct dictionary, for comparing
    /// with what a rewrite keeps.
    private func normalisedResources(_ original: [String: PDFObject]) -> [String: PDFObject] {
        var out: [String: PDFObject] = [:]
        for (key, value) in original {
            if ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"].contains(key),
               let dictionary = context.resolve(value)?.dictionaryValue {
                if !dictionary.isEmpty { out[key] = .dictionary(dictionary) }
            } else {
                out[key] = value
            }
        }
        return out
    }

    private mutating func paintInlineImage(_ operation: RedactionOperation) throws {
        guard let image = operation.inlineImage else { return }
        if case let .name(space)? = image.dictionary["CS"] ?? image.dictionary["ColorSpace"],
           RedactionInlineImageKeys.colorSpaceExpansions[space] == nil,
           !["DeviceGray", "DeviceRGB", "DeviceCMYK", "Indexed"].contains(space) {
            use("ColorSpace", space)
        }
        let isMask = (image.dictionary["IM"] ?? image.dictionary["ImageMask"]) == .boolean(true)
        let coverage = imageCoverage(state.ctm)
        guard coverage.touches else {
            if isMask { try paintsWithPattern(fill: true) }
            out.append(operation)
            return
        }
        if isMask, state.fill.pattern != nil {
            try cannotCut("a stencil mask painted with a pattern is cut by a box", tainting: [category("Pattern")?[state.fill.pattern ?? ""]])
        }
        changed = true
        markRemoval()
        let determinant = state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c
        if coverage.removeWhole || abs(determinant) < 1e-12 {
            return
        }
        let blanked: RedactionInlineImage
        do {
            blanked = try RedactionImages.redactInline(
                image, placement: state.ctm, rule: imageRule, colorSpaces: category("ColorSpace"), resolve: { self.context.resolve($0) }
            )
        } catch let error as RedactionUnsupported where context.surveying {
            _ = error
            return
        }
        out.append(RedactionOperation("q"))
        out.append(contentsOf: exclusionClip(state.ctm.inverted()))
        out.append(RedactionOperation("BI", [], inlineImage: blanked))
        out.append(RedactionOperation("Q"))
    }

    /// `sh` paints its shading over the whole clip. A shading painted only under the boxes goes
    /// with its definition; one painted partly under a box cannot be cut exactly — its function
    /// data (a sampled function is a picture) describes what lay under the box (finding 6).
    private mutating func paintShading(_ operation: RedactionOperation) throws {
        guard let name = operation.operands.first?.nameValue else { throw RedactionUnsupported("an sh operator names nothing") }
        let reference = category("Shading")?[name]
        guard let shading = context.resolve(reference)?.dictionaryValue else {
            changed = true
            return
        }
        let type = context.resolve(shading["ShadingType"])?.integerValue ?? 0
        if !(1...3).contains(type), context.redacting {
            try cannotCut("a mesh shading (type \(type)) is drawn on a sheet with a box", tainting: [reference])
            return
        }
        let determinant = state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c
        guard abs(determinant) > 1e-12 else { use("Shading", name); out.append(operation); return }
        var painted = state.clip.bounds
        if let bbox = Self.rect(context.resolve(shading["BBox"]), context) { painted = painted.intersection(bbox.applying(state.ctm)) }
        if type == 1 {
            let domain = context.resolve(shading["Domain"])?.arrayValue?.compactMap { context.resolve($0)?.doubleValue } ?? [0, 1, 0, 1]
            if domain.count == 4 {
                let matrix = Self.matrix(context.resolve(shading["Matrix"]), context) ?? .identity
                let area = CGRect(x: min(domain[0], domain[1]), y: min(domain[2], domain[3]), width: abs(domain[1] - domain[0]), height: abs(domain[3] - domain[2]))
                painted = painted.intersection(area.applying(matrix.concatenating(state.ctm)))
            }
        }
        guard !painted.isNull, painted.width > 0, painted.height > 0 else {
            // Paints nothing.
            changed = true
            return
        }
        if let crop = context.cropRect {
            guard RedactionGeometry.intersects(painted, crop) else { changed = true; return }
            if context.needsExamination(reference) { throw RedactionUnsupported("a shading painted under a box is painted elsewhere as well") }
            use("Shading", name)
            out.append(operation)
            return
        }
        guard boxes.contains(where: { RedactionGeometry.intersects(painted, $0) }) else {
            if context.needsExamination(reference) { throw RedactionUnsupported("a shading painted under a box is painted elsewhere as well") }
            use("Shading", name)
            out.append(operation)
            return
        }
        let inside = boxes.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(painted) }
        guard inside else {
            try cannotCut("a smooth shading is painted partly under a box", tainting: [reference])
            return
        }
        changed = true
        markRemoval()
        context.taint(reference)
    }

    // MARK: - Resources

    private func prunedResources() -> [String: PDFObject] {
        var result: [String: PDFObject] = [:]
        for (key, value) in resources where !["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"].contains(key) {
            result[key] = value
        }
        for key in ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"] {
            var entries: [String: PDFObject] = [:]
            let original = category(key) ?? [:]
            let names = key == "Properties" ? Set(propertyUses.filter { $0.value > 0 }.keys) : (used[key] ?? [])
            for name in names {
                if let value = original[name] { entries[name] = value }
            }
            if key == "Pattern" {
                // A pattern name still set by a colour operator whose original no kept paint uses:
                // an empty pattern of the same kind, so the operator stays valid.
                for name in referencedPatterns where entries[name] == nil && original[name] != nil {
                    let pattern = context.resolve(original[name])?.dictionaryValue
                    let paintType = context.resolve(pattern?["PaintType"])?.integerValue == 2 ? 2 : 1
                    entries[name] = context.dummyPattern(paintType: paintType)
                }
            }
            for (name, value) in added[key] ?? [:] { entries[name] = value }
            // Colour spaces are small and a pattern or image may name one indirectly; keep them.
            if key == "ColorSpace" { for (name, value) in original where entries[name] == nil { entries[name] = value } }
            if !entries.isEmpty { result[key] = .dictionary(entries) }
        }
        return result
    }

    // MARK: - Helpers

    static func matrix(_ object: PDFObject?, _ context: RedactionRewriteContext) -> CGAffineTransform? {
        guard let values = object?.arrayValue?.compactMap({ context.resolve($0)?.doubleValue }), values.count == 6 else { return nil }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    static func rect(_ object: PDFObject?, _ context: RedactionRewriteContext) -> CGRect? {
        guard let values = object?.arrayValue?.compactMap({ context.resolve($0)?.doubleValue }), values.count == 4 else { return nil }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]), width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }
}
