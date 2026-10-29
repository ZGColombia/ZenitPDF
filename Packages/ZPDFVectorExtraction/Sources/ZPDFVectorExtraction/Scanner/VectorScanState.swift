import CoreGraphics
import Foundation

/// The mutable state of one page scan.
///
/// Deliberately a plain class and deliberately **not** `Sendable`: it is created inside
/// one call of ``VectorExtractor/extract(documentAt:pageIndex:)``, handed to
/// `CGPDFScanner` as an opaque `info` pointer, used only on that call's thread, and
/// dropped before the call returns. Nothing here ever crosses an isolation boundary.
final class VectorScanState {

    // MARK: Configuration

    let options: VectorExtractionOptions
    let pageTransform: VectorPageTransform
    /// The crop box expressed in the same space as the emitted primitives.
    let cropBoxInPageSpace: VectorBounds
    let budget: VectorExtractionBudget

    // MARK: Graphics state

    var state: VectorGraphicsState
    private var stateStack: [VectorGraphicsState] = []
    /// The `q` depth. Bounded: a stream of nothing but `q` must not grow the stack
    /// without limit.
    static let maximumStateStackDepth = 4096

    // MARK: Path construction

    var subpaths: [VectorSubpathBuilder] = []
    var current: VectorSubpathBuilder?
    /// Set by `W` or `W*`, consumed by the next path-painting operator.
    var pendingClip = false

    // MARK: Form recursion

    var nestingDepth = 0
    /// Stream identities on the current recursion path, so a form that draws itself is
    /// cut at the repeat rather than recursed into until the stack dies.
    var activeFormStreams: [UInt] = []
    /// The `Do` resource names on the current recursion path, outermost first. They
    /// qualify a form-local layer name the page does not know (BH-865).
    private(set) var activeFormNames: [String] = []

    // MARK: Output

    private(set) var primitives: [VectorPrimitive] = []
    /// `CGPoint`s held in the *heap* storage of emitted primitives — that is, in the
    /// vertex array of every `.ring`. Tracked as primitives are appended rather than
    /// derived on demand, because ``estimatedMemoryBytes`` is read once per subpath and
    /// walking every emitted primitive to re-count would make the budget check O(n²).
    private(set) var storedRingPointCount = 0
    private(set) var rasterRegions: [VectorRasterRegion] = []
    private(set) var filterDecisions: [VectorFilterDecision] = []
    /// Subpaths that were filtered, counted whether or not a ``VectorFilterDecision`` was
    /// kept for them. ``filterDecisions`` is a bounded diagnostic; this is the truth.
    private(set) var filteredSubpathCount = 0
    /// `true` once ``filterDecisions`` stopped growing and decisions are being counted
    /// but not stored.
    private(set) var filterDecisionsTruncated = false

    /// Ceiling on the stored per-subpath diagnostics.
    ///
    /// `filterDecisions` is explanatory output, not a result: it exists so a page that
    /// emitted nothing can say why. It used to be unbounded, and it is itself charged to
    /// the memory budget, which produced the worst kind of cap failure — a page of a
    /// million degenerate subpaths emits zero primitives, so neither the primitive-count
    /// nor the memory guard in `emit` ever runs, while the diagnostics alone grow past
    /// the budget. 50 000 entries is far more than anyone reads and costs under 5 MB.
    static let maximumFilterDecisions = 50_000
    private var partialReasonSet: [VectorPartialReason] = []

    // MARK: Counters

    private(set) var operatorCount = 0
    private(set) var paintedPathCount = 0
    private(set) var subpathCount = 0
    private(set) var formInvocationCount = 0
    private(set) var maximumNestingDepthReached = 0
    private(set) var inlineImageCount = 0
    private(set) var malformedOperandCount = 0
    private(set) var hiddenSubpathCount = 0
    private(set) var contentBytesEntered = 0
    private(set) var contentBytesCompleted = 0

    private var nextIdentifier: UInt64
    private var nextSourceObjectID: UInt64 = 0
    private var operatorsSinceBudgetCheck = 0
    private let startNanoseconds: UInt64
    private(set) var elapsedNanoseconds: UInt64 = 0

    /// Set once a budget fires or the task is cancelled. Every callback returns
    /// immediately afterwards: `CGPDFScannerScan` has no interruption point, so the rest
    /// of the stream is walked and ignored rather than processed.
    private(set) var stopRequested = false
    private(set) var stopBudget: VectorBudgetKind?
    private(set) var wasCancelled = false

    /// Optional-content groups switched off in the document's default configuration,
    /// by dictionary identity.
    let hiddenOptionalContentGroups: Set<UInt>

    /// The operator table, kept so a nested form scan reuses it rather than rebuilding
    /// one per `Do`.
    var operatorTable: CGPDFOperatorTableRef?

    /// One entry per open `BMC`/`BDC`, recording what the section changed so `EMC` can
    /// put it back. Bounded, like every other stack here.
    private var markedContentStack: [(hidesContent: Bool, previousLayerID: String?)] = []
    static let maximumMarkedContentDepth = 4096
    /// The stack depth at entry to the innermost form. An `EMC` inside a form can end only
    /// sections that form began: a stray one used to pop the *page's* `/OC` entry and
    /// un-hide the rest of a hidden section (BH-867). Marked content is lexical to its
    /// stream (PDF 32000-1 8.11.3.2 / 14.6), and a form's stream is a separate lexical unit.
    private var markedContentFloor = 0

    /// Depth of `BDC` marked-content sections whose optional content is off.
    ///
    /// Lexical, not graphics state: it is changed by `BDC`/`EMC` only and is untouched by
    /// `q`/`Q`. Keeping it in ``VectorGraphicsState`` made `BDC q … EMC … Q` restore a hidden
    /// depth of 1 and drop every later visible stroke, and made `q BDC … Q` un-hide content
    /// whose section had not ended (CR-39).
    private(set) var hiddenContentDepth = 0
    /// The innermost `BDC /OC` layer name in force, with the same lexical scope.
    private(set) var layerID: String?

    /// The page's own `/Resources /Properties` names, by the identity of the dictionary each
    /// one names. A form XObject's `/Properties` are form-local: `/L0` inside a form may be a
    /// different group from the page's `/L0`, or the same group under another name. Layer
    /// identity for a primitive is therefore resolved through the dictionary, and reported
    /// under the page-level name when the page has one for it (CR-48).
    var pageLevelLayerNames: [UInt: String] = [:]
    /// Layer IDs assigned during this scan to groups the page's `/Properties` does not
    /// name, by dictionary identity, so one group met under several form-local names is
    /// one layer and two groups met under the same local name are two (BH-865).
    private var unknownGroupNames: [UInt: String] = [:]
    /// Every ID handed out through ``unknownGroupNames``, for collision checks.
    private var assignedUnknownNames: Set<String> = []

    /// The point a new subpath begins at when the next construction operator is not `m`.
    ///
    /// After `h` (and after `re`, which is `m … h`) the current point is the closed subpath's
    /// *start* point, and a following `l` or `c` begins a new subpath there
    /// (PDF 32000-1 8.5.2.1). Treating that `l` as malformed and starting at its own end
    /// point lost the segment and marked the page partial (CR-42).
    private var pendingSubpathStart: CGPoint?

    init(
        options: VectorExtractionOptions,
        pageTransform: VectorPageTransform,
        hiddenOptionalContentGroups: Set<UInt>
    ) {
        self.options = options
        self.pageTransform = pageTransform
        self.cropBoxInPageSpace = pageTransform.canonicalCropBox
        self.budget = options.budget
        self.hiddenOptionalContentGroups = hiddenOptionalContentGroups
        self.state = .initial
        self.nextIdentifier = options.identifierPlan.first
        self.startNanoseconds = options.timeSource.nanoseconds()
    }

    // MARK: - Identifiers

    private func takeIdentifier() -> UInt64 {
        let value = nextIdentifier
        nextIdentifier = nextIdentifier &+ options.identifierPlan.step
        return value
    }

    // MARK: - Budgets

    /// Called once per dispatched operator. Returns `false` when the scan should stop.
    @discardableResult
    func noteOperator() -> Bool {
        if stopRequested { return false }
        operatorCount += 1
        operatorsSinceBudgetCheck += 1
        if operatorCount > budget.maximumOperatorCount {
            stop(budget: .operatorCount)
            return false
        }
        if operatorsSinceBudgetCheck >= budget.budgetCheckInterval {
            operatorsSinceBudgetCheck = 0
            return checkPeriodicBudgets()
        }
        return true
    }

    /// The checks that are too expensive to run on every single operator.
    private func checkPeriodicBudgets() -> Bool {
        if Task.isCancelled {
            wasCancelled = true
            stopRequested = true
            return false
        }
        let now = options.timeSource.nanoseconds()
        elapsedNanoseconds = now >= startNanoseconds ? now - startNanoseconds : 0
        if elapsedNanoseconds > budget.wallClockLimitNanoseconds {
            stop(budget: .wallClock)
            return false
        }
        if estimatedMemoryBytes > budget.memoryLimitBytes {
            stop(budget: .memory)
            return false
        }
        return true
    }

    func stop(budget kind: VectorBudgetKind) {
        guard !stopRequested else { return }
        stopRequested = true
        stopBudget = kind
        finaliseElapsed()
    }

    func finaliseElapsed() {
        let now = options.timeSource.nanoseconds()
        elapsedNanoseconds = now >= startNanoseconds ? now - startNanoseconds : elapsedNanoseconds
    }

    /// A deliberately simple model: the stored size of a primitive plus the vertex
    /// storage a ring holds. Exact enough to stop a runaway page, cheap enough to
    /// evaluate thousands of times a second.
    var estimatedMemoryBytes: Int {
        let primitiveStride = MemoryLayout<VectorPrimitive>.stride
        let pointStride = MemoryLayout<CGPoint>.stride
        // A `VectorPrimitive` is a fixed-size value *except* for `.ring`, whose vertices
        // live in a heap array that can hold up to `maximumPointsPerSubpath` points —
        // a million, by default, or 16 MB for a single primitive. Charging every
        // primitive a flat four points, as this once did, counted that ring as 64 bytes
        // and let the memory budget be exceeded by orders of magnitude without ever
        // firing. Line, cubic and rectangle geometry is genuinely inline, so it costs
        // the stride and nothing more.
        return primitives.count * primitiveStride
            + storedRingPointCount * pointStride
            + rasterRegions.count * MemoryLayout<VectorRasterRegion>.stride
            + filterDecisions.count * MemoryLayout<VectorFilterDecision>.stride
    }

    // MARK: - Reasons

    func note(_ reason: VectorPartialReason) {
        // Reasons that carry a count are folded rather than appended, so a page with a
        // thousand inline images produces one reason and not a thousand.
        switch reason {
        case .inlineImageSkipped, .malformedContentStream, .hiddenOptionalContentExcluded:
            partialReasonSet.removeAll { sameCase($0, reason) }
            partialReasonSet.append(reason)
        default:
            guard !partialReasonSet.contains(reason) else { return }
            partialReasonSet.append(reason)
        }
    }

    private func sameCase(_ lhs: VectorPartialReason, _ rhs: VectorPartialReason) -> Bool {
        switch (lhs, rhs) {
        case (.inlineImageSkipped, .inlineImageSkipped): return true
        case (.malformedContentStream, .malformedContentStream): return true
        case (.hiddenOptionalContentExcluded, .hiddenOptionalContentExcluded): return true
        default: return false
        }
    }

    /// Sorted by severity then by textual form, so the order never depends on the order
    /// in which the content stream happened to trip them.
    var sortedPartialReasons: [VectorPartialReason] {
        var reasons = partialReasonSet
        if malformedOperandCount > 0 {
            reasons.removeAll { if case .malformedContentStream = $0 { return true } else { return false } }
            reasons.append(.malformedContentStream(operandFailures: malformedOperandCount))
        }
        if inlineImageCount > 0 {
            reasons.removeAll { if case .inlineImageSkipped = $0 { return true } else { return false } }
            reasons.append(.inlineImageSkipped(count: inlineImageCount))
        }
        if hiddenSubpathCount > 0 {
            reasons.removeAll { if case .hiddenOptionalContentExcluded = $0 { return true } else { return false } }
            reasons.append(.hiddenOptionalContentExcluded(count: hiddenSubpathCount))
        }
        if let kind = stopBudget {
            reasons.removeAll { if case .budgetExceeded = $0 { return true } else { return false } }
            reasons.append(.budgetExceeded(kind, consumedFraction: streamFractionConsumed))
        }
        return reasons.sorted { lhs, rhs in
            if lhs.severityRank != rhs.severityRank { return lhs.severityRank < rhs.severityRank }
            return String(describing: lhs) < String(describing: rhs)
        }
    }

    var streamFractionConsumed: Double {
        guard contentBytesEntered > 0 else { return 1.0 }
        return Swift.min(1.0, Double(contentBytesCompleted) / Double(contentBytesEntered))
    }

    func noteMalformedOperands() {
        malformedOperandCount += 1
    }

    func noteContentStreamEntered(bytes: Int) {
        contentBytesEntered += Swift.max(0, bytes)
    }

    func noteContentStreamCompleted(bytes: Int) {
        contentBytesCompleted += Swift.max(0, bytes)
    }

    func noteInlineImage() {
        inlineImageCount += 1
    }

    func noteDepth(_ depth: Int) {
        maximumNestingDepthReached = Swift.max(maximumNestingDepthReached, depth)
    }

    // MARK: - Graphics state stack

    func saveState() {
        guard stateStack.count < Self.maximumStateStackDepth else {
            // A stream of nothing but `q` is malformed. Refusing to grow is the only
            // safe response; the matching `Q` will simply find nothing to pop.
            noteMalformedOperands()
            return
        }
        stateStack.append(state)
    }

    func restoreState() {
        guard let previous = stateStack.popLast() else {
            // Unbalanced `Q`. Real files contain these; the graphics state is left as it
            // is, which is what a forgiving renderer does.
            noteMalformedOperands()
            return
        }
        state = previous
    }

    /// The state stack depth, so a form's scan can restore what its content unbalanced.
    var stateStackDepth: Int { stateStack.count }

    func truncateStateStack(to depth: Int) {
        while stateStack.count > depth { _ = stateStack.popLast() }
    }

    func concatenate(_ matrix: CGAffineTransform) {
        state.ctm = matrix.concatenating(state.ctm)
    }

    // MARK: - Page-space mapping

    /// User space, through the CTM and then through the page transform, in one step.
    func toPageSpace(_ point: CGPoint) -> CGPoint {
        point.applying(state.ctm).applying(pageTransform.matrix)
    }

    // MARK: - Path construction

    func moveTo(_ point: CGPoint) {
        flushCurrentSubpath()
        pendingSubpathStart = nil
        current = VectorSubpathBuilder(startPoint: toPageSpace(point))
    }

    /// The builder a segment operator appends to when no subpath is open.
    ///
    /// After `h` or `re` the current point is the closed subpath's start, so the segment
    /// legitimately begins a new subpath there. With no current point at all, PDF calls
    /// the operator an error; treating it as a `m` to `fallback` keeps the rest of the
    /// subpath usable and costs nothing.
    private func builderForSegmentWithoutCurrentPoint(fallback: CGPoint) -> VectorSubpathBuilder {
        if let start = pendingSubpathStart {
            pendingSubpathStart = nil
            return VectorSubpathBuilder(startPoint: start)
        }
        noteMalformedOperands()
        return VectorSubpathBuilder(startPoint: fallback)
    }

    func lineTo(_ point: CGPoint) {
        let mapped = toPageSpace(point)
        guard var builder = current else {
            current = builderForSegmentWithoutCurrentPoint(fallback: mapped)
            if current?.startPoint != mapped { lineTo(point) }
            return
        }
        guard builder.vertices.count < budget.maximumPointsPerSubpath else {
            noteMalformedOperands()
            return
        }
        // Ownership is taken before the append: with `current` still holding the same
        // buffers, every append was a non-unique copy of the whole subpath (IM-037).
        current = nil
        builder.append(.line(VectorLine(start: builder.currentPoint, end: mapped)))
        builder.vertices.append(mapped)
        builder.currentPoint = mapped
        builder.rectangleQuad = nil
        current = builder
    }

    func curveTo(control1: CGPoint, control2: CGPoint, end: CGPoint) {
        let c1 = toPageSpace(control1)
        let c2 = toPageSpace(control2)
        let p3 = toPageSpace(end)
        guard var builder = current else {
            current = builderForSegmentWithoutCurrentPoint(fallback: p3)
            if current?.startPoint != p3 { curveTo(control1: control1, control2: control2, end: end) }
            return
        }
        guard builder.vertices.count < budget.maximumPointsPerSubpath else {
            noteMalformedOperands()
            return
        }
        current = nil  // IM-037: unique buffers before the append.
        builder.append(.cubic(VectorCubic(p0: builder.currentPoint, p1: c1, p2: c2, p3: p3)))
        builder.vertices.append(p3)
        builder.currentPoint = p3
        builder.containsCurves = true
        builder.rectangleQuad = nil
        current = builder
    }

    /// `v`: the first control point coincides with the current point.
    func curveToFromCurrentPoint(control2: CGPoint, end: CGPoint) {
        let c2 = toPageSpace(control2)
        let p3 = toPageSpace(end)
        guard var builder = current else {
            current = builderForSegmentWithoutCurrentPoint(fallback: p3)
            if current?.startPoint != p3 { curveToFromCurrentPoint(control2: control2, end: end) }
            return
        }
        guard builder.vertices.count < budget.maximumPointsPerSubpath else {
            noteMalformedOperands()
            return
        }
        current = nil  // IM-037: unique buffers before the append.
        let p0 = builder.currentPoint
        builder.append(.cubic(VectorCubic(p0: p0, p1: p0, p2: c2, p3: p3)))
        builder.vertices.append(p3)
        builder.currentPoint = p3
        builder.containsCurves = true
        builder.rectangleQuad = nil
        current = builder
    }

    /// `true` when the optional-content dictionary is switched off in the document's
    /// default configuration.
    ///
    /// A group is hidden when the default configuration lists it under `/OFF`. A membership
    /// dictionary (`/OCMD`) is evaluated by its `/VE` visibility expression when it has one,
    /// otherwise by its `/OCGs` under its `/P` policy — `/AnyOn` by default, and `/AllOn`,
    /// `/AnyOff` and `/AllOff` as PDF 32000-1 8.11.2.2 defines them (CR-48). The rule itself
    /// is ``OptionalContentVisibility``; this function only reads the dictionary.
    func isHidden(optionalContentDictionary dictionary: CGPDFDictionaryRef) -> Bool {
        let identity = PDFObject.identity(dictionary: dictionary)
        if hiddenOptionalContentGroups.contains(identity) { return true }
        guard PDFObject.nameEntry(dictionary, "Type") == "OCMD" else { return false }
        let membership = OptionalContentVisibility.membership(
            of: dictionary, isGroupHidden: { self.hiddenOptionalContentGroups.contains($0) }
        )
        return OptionalContentVisibility.isHidden(membership)
    }

    /// The name a primitive drawn inside `BDC /OC /name` reports as its layer.
    ///
    /// Resolved through the dictionary the name refers to: when the page's own
    /// `/Properties` has a name for that same dictionary, that name is reported, so a
    /// form-local alias of a page layer and the page layer itself are one layer to the snap
    /// filter. At page level a name stays as written.
    ///
    /// A group the page does not know is identified by the dictionary, not by the local
    /// name: two forms that each say `/oc0` for *different* groups used to report one
    /// layer `"oc0"`, so hiding it hid both and no override could tell them apart, while one
    /// group under two local names split in two (BH-865). The first time such a group is
    /// met it is given the local name qualified by the `Do` path it was met on
    /// (`"Fx/oc0"`), made unique against the page's names and every earlier assignment;
    /// every later meeting of the same dictionary, under any name, reports that ID. Scan
    /// order is deterministic, so the assignment is a function of the file's bytes.
    func layerID(forPropertyName name: String, resolving dictionary: CGPDFDictionaryRef?) -> String {
        guard nestingDepth > 0, let dictionary else { return name }
        return layerID(for: dictionary, fallbackName: name)
    }

    /// The layer ID of an optional-content dictionary met anywhere: see
    /// ``layerID(forPropertyName:resolving:)``. `fallbackName` is the local name it was
    /// met under (a property name, or the XObject name for an `/OC` entry on a form).
    func layerID(for dictionary: CGPDFDictionaryRef, fallbackName: String) -> String {
        let identity = PDFObject.identity(dictionary: dictionary)
        if let pageName = pageLevelLayerNames[identity] { return pageName }
        if let assigned = unknownGroupNames[identity] { return assigned }
        let pageNames = Set(pageLevelLayerNames.values)
        let base = (activeFormNames + [fallbackName]).joined(separator: "/")
        var candidate = base
        var suffix = 1
        while pageNames.contains(candidate) || assignedUnknownNames.contains(candidate) {
            suffix += 1
            candidate = "\(base)#\(suffix)"
        }
        unknownGroupNames[identity] = candidate
        assignedUnknownNames.insert(candidate)
        return candidate
    }

    /// `h`: closes the current subpath.
    ///
    /// PDF 32000-1 8.5.2.1, Table 59: "If the current subpath is already closed, `h`
    /// shall do nothing." After `h` or `re` there is no open builder but there is a
    /// current point — the closed subpath's start — so a second `h`, or an `h` after
    /// `re`, is a legal no-op and not a malformed operand; counting it marked a valid page
    /// `partial` (BH-866). With no current point at all it remains an error.
    func closeSubpath() {
        guard var builder = current else {
            if pendingSubpathStart == nil { noteMalformedOperands() }
            return
        }
        closeInPlace(&builder)
        current = builder
        flushCurrentSubpath()
        pendingSubpathStart = builder.startPoint
    }

    func appendRectangle(x: Double, y: Double, width: Double, height: Double) {
        flushCurrentSubpath()
        let c0 = toPageSpace(CGPoint(x: x, y: y))
        let c1 = toPageSpace(CGPoint(x: x + width, y: y))
        let c2 = toPageSpace(CGPoint(x: x + width, y: y + height))
        let c3 = toPageSpace(CGPoint(x: x, y: y + height))
        var builder = VectorSubpathBuilder(startPoint: c0)
        builder.setSegments([
            .line(VectorLine(start: c0, end: c1)),
            .line(VectorLine(start: c1, end: c2)),
            .line(VectorLine(start: c2, end: c3)),
            .line(VectorLine(start: c3, end: c0))
        ])
        builder.vertices = [c0, c1, c2, c3]
        builder.currentPoint = c0
        builder.isClosed = true
        builder.rectangleQuad = VectorQuad(c0: c0, c1: c1, c2: c2, c3: c3)
        subpaths.append(builder)
        current = nil
        // `re` is `x y m … h`: the current point afterwards is `(x, y)`.
        pendingSubpathStart = c0
    }

    func flushCurrentSubpath() {
        guard let builder = current else { return }
        subpaths.append(builder)
        current = nil
    }

    func discardPath() {
        current = nil
        pendingSubpathStart = nil
        subpaths.removeAll(keepingCapacity: true)
        pendingClip = false
    }

    // MARK: - Painting

    /// Handles every path-painting operator, including `n`.
    func paintPath(stroke: Bool, fill: Bool, closesPath: Bool) {
        guard !stopRequested else {
            discardPath()
            return
        }
        flushCurrentSubpath()
        if closesPath, let last = subpaths.indices.last, !subpaths[last].isClosed {
            // PDF 32000-1 Table 60: `s` is "Close and stroke the path. Same effect as
            // `h S`", and 8.5.2.1 says `h` closes the *current* subpath — the last one
            // begun. Closing every open subpath stroked a phantom edge from each earlier
            // subpath's end back to its start, a snap target no renderer draws (BH-330).
            // `b` and `b*` reach the fill loop below, which closes them all as `f` does.
            closeInPlace(&subpaths[last])
        }
        if fill {
            // A filled subpath is closed implicitly, whether or not `h` appeared.
            for index in subpaths.indices where !subpaths[index].isClosed {
                closeInPlace(&subpaths[index])
            }
        }

        defer {
            subpaths.removeAll(keepingCapacity: true)
            pendingClip = false
            // Painting consumes the path; there is no current point until the next `m`.
            pendingSubpathStart = nil
        }

        let sourceObjectID = nextSourceObjectID
        nextSourceObjectID &+= 1
        if !subpaths.isEmpty { paintedPathCount += 1 }
        subpathCount += subpaths.count

        let pathBounds = subpaths.reduce(into: VectorBounds?.none) { partial, subpath in
            partial = partial.map { $0.union(subpath.bounds) } ?? subpath.bounds
        }

        // The clip is intersected first, so a primitive emitted by this very operator
        // is not tested against a clip that only takes effect afterwards.
        let clipInForce = state.clip
        let clipWasEmpty = state.clipIsEmpty
        if pendingClip, let pathBounds {
            state.intersectClip(with: pathBounds)
        }

        var paint: VectorPaintRole = []
        if stroke { paint.insert(.stroked) }
        if fill { paint.insert(.filled) }

        for (subpathIndex, subpath) in subpaths.enumerated() {
            emit(
                subpath: subpath,
                subpathIndex: subpathIndex,
                sourceObjectID: sourceObjectID,
                paint: paint,
                clipInForce: clipInForce,
                clipIsEmpty: clipWasEmpty
            )
        }
    }

    /// Closes a subpath: adds the closing segment when the pen is not already back at
    /// the start, and drops a trailing vertex that merely repeats the first.
    ///
    /// The repeated vertex matters. A ring drawn as `m c c c c h` ends its last curve
    /// exactly on its first point, so the naive vertex list carries that point twice and
    /// a consumer counting corners finds five on a four-corner ring. The manifest
    /// convention in `ZPDFTestingSupport` — "the first vertex is not repeated at the
    /// end" — is the one adopted here.
    func closeInPlace(_ builder: inout VectorSubpathBuilder) {
        if builder.currentPoint != builder.startPoint, !builder.segments.isEmpty {
            builder.append(.line(VectorLine(start: builder.currentPoint, end: builder.startPoint)))
            builder.currentPoint = builder.startPoint
        }
        if builder.vertices.count > 1, let last = builder.vertices.last, last == builder.startPoint {
            builder.vertices.removeLast()
        }
        builder.isClosed = true
    }

    private func record(
        _ rule: VectorFilterRule,
        subpath: VectorSubpathBuilder,
        subpathIndex: Int,
        sourceObjectID: UInt64,
        measuredValue: Double? = nil,
        threshold: Double? = nil
    ) {
        // Once a budget has tripped the page is already `partial` and the reason is
        // recorded. Every subpath after that point still reaches `emit`, fails the same
        // guard and would record the same decision again: on a ten-thousand-subpath page
        // that is 9 718 identical entries, 933 KB of diagnostics charged to a 64 KB
        // memory budget. The stop reason says it once.
        guard !stopRequested else {
            filterDecisionsTruncated = true
            return
        }
        filteredSubpathCount += 1
        guard filterDecisions.count < Self.maximumFilterDecisions else {
            filterDecisionsTruncated = true
            return
        }
        filterDecisions.append(
            VectorFilterDecision(
                rule: rule,
                sourceObjectID: sourceObjectID,
                subpathIndex: subpathIndex,
                nestingDepth: nestingDepth,
                bounds: subpath.bounds,
                measuredValue: measuredValue,
                threshold: threshold
            )
        )
    }

    private func emit(
        subpath: VectorSubpathBuilder,
        subpathIndex: Int,
        sourceObjectID: UInt64,
        paint requestedPaint: VectorPaintRole,
        clipInForce: VectorBounds?,
        clipIsEmpty: Bool
    ) {
        var paint = requestedPaint

        if hiddenContentDepth > 0 {
            hiddenSubpathCount += 1
            record(.hiddenOptionalContent, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
            return
        }

        if subpath.isDegenerate {
            record(.degenerateGeometry, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
            return
        }

        if paint.isEmpty {
            if pendingClip {
                guard options.emitsClipDerivedPrimitives else {
                    record(.clippingOnly, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
                    return
                }
                paint = .clipDerived
            } else {
                record(.discardedWithoutPainting, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
                return
            }
        }

        if !paint.contains(.clipDerived) {
            let strokeVisible = paint.contains(.stroked) && state.strokeAlpha > 0
            let fillVisible = paint.contains(.filled) && state.fillAlpha > 0
            if !strokeVisible && !fillVisible {
                record(.invisiblePaint, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
                return
            }
            if !strokeVisible { paint.remove(.stroked) }
            if !fillVisible { paint.remove(.filled) }
        }

        let bounds = subpath.bounds
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite else {
            record(.degenerateGeometry, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
            return
        }

        if let rule = backgroundRule(for: subpath, bounds: bounds, paint: paint) {
            record(
                rule.rule,
                subpath: subpath,
                subpathIndex: subpathIndex,
                sourceObjectID: sourceObjectID,
                measuredValue: rule.measured,
                threshold: rule.threshold
            )
            return
        }

        var clipRelation = VectorClipRelation.unclipped
        if clipIsEmpty {
            // An empty clip admits nothing, wherever the subpath sits (BH-329, BH-331).
            clipRelation = .outsideClip
        } else if let clip = clipInForce {
            if !clip.intersects(bounds) {
                clipRelation = .outsideClip
            } else if clip.contains(bounds) {
                clipRelation = .insideClip
            } else {
                clipRelation = .partiallyClipped
            }
        }
        if clipRelation == .outsideClip, options.excludesGeometryOutsideClip {
            record(.entirelyOutsideClip, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
            return
        }

        let segmentCount = subpath.segments.count
        let shapeCount = (options.emitsShapePrimitives && subpath.isClosed) ? 1 : 0
        // Both caps are re-checked here, per subpath, and not only in the periodic
        // operator check. A single `S` can paint ten thousand subpaths, so a check that
        // only runs between operators would let one operator blow through both budgets.
        guard primitives.count + segmentCount + shapeCount <= budget.maximumPrimitiveCount else {
            record(.primitiveBudgetExhausted, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
            stop(budget: .primitiveCount)
            return
        }
        // Predictive, exactly as the count guard above is. Checking the memory already
        // spent would let one subpath overshoot the budget by everything it is about to
        // emit — up to `maximumPointsPerSubpath` primitives, hundreds of megabytes — and
        // a budget that is only enforced after the allocation is not a budget. The ring
        // vertex count is charged whenever a shape primitive will be emitted; when the
        // subpath turns out to be a rectangle the charge is four points too high, which
        // is the correct direction for a cap to err in.
        let projectedBytes = estimatedMemoryBytes
            + (segmentCount + shapeCount) * MemoryLayout<VectorPrimitive>.stride
            + (shapeCount == 1 ? subpath.vertices.count * MemoryLayout<CGPoint>.stride : 0)
        guard projectedBytes <= budget.memoryLimitBytes else {
            // The stop diagnostic is charged to the budget it reports, so it is stored only
            // when it still fits. Recording it unconditionally let the final estimate land
            // one `VectorFilterDecision` past the ceiling whenever the primitives had filled
            // the budget to within 96 bytes — which the larger primitive of extractor
            // version 4 (fill and stroke colour, BH-167) made happen on the 64 KiB fixture:
            // 210 × 312 + 96 = 65 616 > 65 536. The subpath is still counted as filtered.
            let decisionStride = MemoryLayout<VectorFilterDecision>.stride
            if estimatedMemoryBytes + decisionStride <= budget.memoryLimitBytes {
                record(.primitiveBudgetExhausted, subpath: subpath, subpathIndex: subpathIndex, sourceObjectID: sourceObjectID)
            } else {
                filteredSubpathCount += 1
                filterDecisionsTruncated = true
            }
            stop(budget: .memory)
            return
        }

        let confidence = VectorConfidence.value(paint: paint, clipRelation: clipRelation)
        let strokeWidth = paint.contains(.stroked) ? state.pageSpaceLineWidth() : 0
        let layerID = self.layerID
        // The colour of each paint role the primitive kept, with its constant alpha. A
        // role removed above (alpha 0) or never requested carries no colour.
        let fillColor = paint.contains(.filled) ? state.paintedFillColor : nil
        let strokeColor = paint.contains(.stroked) ? state.paintedStrokeColor : nil

        var parentID: UInt64?
        if shapeCount == 1 {
            let shapeID = takeIdentifier()
            parentID = shapeID
            let geometry: VectorGeometry
            let kind: VectorPrimitiveKind
            if let quad = subpath.rectangleQuad {
                geometry = .rectangle(quad)
                kind = .rectangle
            } else {
                geometry = .ring(
                    VectorRing(
                        vertices: subpath.vertices,
                        isClosed: true,
                        containsCurves: subpath.containsCurves
                    )
                )
                kind = .closedSubpath
            }
            if case let .ring(ring) = geometry { storedRingPointCount += ring.vertices.count }
            primitives.append(
                VectorPrimitive(
                    id: shapeID,
                    parentID: nil,
                    kind: kind,
                    geometry: geometry,
                    bounds: bounds,
                    sourceObjectID: sourceObjectID,
                    subpathIndex: subpathIndex,
                    nestingDepth: nestingDepth,
                    paint: paint,
                    strokeWidth: strokeWidth,
                    strokeIsDashed: state.isDashed,
                    clipRelation: clipRelation,
                    clipBounds: clipInForce,
                    confidence: confidence,
                    layerID: layerID,
                    fillColor: fillColor,
                    strokeColor: strokeColor
                )
            )
        }

        for (segment, segmentBounds) in zip(subpath.segments, subpath.segmentBounds) {
            if segmentBounds.width == 0 && segmentBounds.height == 0 { continue }
            let geometry: VectorGeometry
            let kind: VectorPrimitiveKind
            switch segment {
            case .line(let line):
                geometry = .line(line)
                kind = .lineSegment
            case .cubic(let cubic):
                geometry = .cubic(cubic)
                kind = .cubicCurve
            }
            primitives.append(
                VectorPrimitive(
                    id: takeIdentifier(),
                    parentID: parentID,
                    kind: kind,
                    geometry: geometry,
                    bounds: segmentBounds,
                    sourceObjectID: sourceObjectID,
                    subpathIndex: subpathIndex,
                    nestingDepth: nestingDepth,
                    paint: paint,
                    strokeWidth: strokeWidth,
                    strokeIsDashed: state.isDashed,
                    clipRelation: clipRelation,
                    clipBounds: clipInForce,
                    confidence: confidence,
                    layerID: layerID,
                    fillColor: fillColor,
                    strokeColor: strokeColor
                )
            )
        }
    }

    /// The background heuristic, evaluated in the order the rules are documented on
    /// ``VectorBackgroundFilter``.
    private func backgroundRule(
        for subpath: VectorSubpathBuilder,
        bounds: VectorBounds,
        paint: VectorPaintRole
    ) -> (rule: VectorFilterRule, measured: Double?, threshold: Double?)? {
        let filter = options.backgroundFilter
        guard filter.isEnabled else { return nil }
        let cropBox = cropBoxInPageSpace
        let cropArea = cropBox.area

        if filter.filtersGeometryOutsideCropBox, !cropBox.intersects(bounds) {
            return (.entirelyOutsideCropBox, nil, nil)
        }

        let grown = cropBox.inset(by: -filter.cropBoxOvershootMargin)
        if bounds.contains(grown) {
            return (.enclosesCropBox, bounds.area, grown.area)
        }

        guard subpath.isClosed, cropArea > 0 else { return nil }
        let isRectangleLike = subpath.rectangleQuad != nil
            || (subpath.vertices.count == 4 && !subpath.containsCurves)
        guard isRectangleLike else { return nil }
        if filter.filtersFilledOnly {
            guard paint.contains(.filled), !paint.contains(.stroked) else { return nil }
        }
        let fraction = bounds.area / cropArea
        if fraction >= filter.minimumCropBoxAreaFraction {
            return (.pageSizedBackground, fraction, filter.minimumCropBoxAreaFraction)
        }
        return nil
    }

    // MARK: - Marked content

    func beginMarkedContent(hidesContent: Bool, layerID: String?) {
        guard markedContentStack.count < Self.maximumMarkedContentDepth else {
            noteMalformedOperands()
            return
        }
        // The entry records the layer in force *before* this section, so `EMC` can put it
        // back; the parameter of the same name is the section's own layer.
        markedContentStack.append((hidesContent, self.layerID))
        if hidesContent { hiddenContentDepth += 1 }
        if let layerID { self.layerID = layerID }
    }

    func endMarkedContent() {
        guard markedContentStack.count > markedContentFloor, let entry = markedContentStack.popLast() else {
            // Unbalanced `EMC` — for the stream as a whole, or for the form being scanned:
            // a form may end only the sections it began (BH-867). Ignore it rather than
            // letting the hidden-content counter go negative and start hiding, or a
            // page's hidden section end early and start showing, the rest of the page.
            noteMalformedOperands()
            return
        }
        if entry.hidesContent, hiddenContentDepth > 0 { hiddenContentDepth -= 1 }
        layerID = entry.previousLayerID
    }

    var markedContentDepth: Int { markedContentStack.count }

    func truncateMarkedContentStack(to depth: Int) {
        // The floor is lowered first: the scope being left may have set it to `depth`,
        // and the entries above it are exactly the ones this pops.
        markedContentFloor = Swift.min(markedContentFloor, depth)
        while markedContentStack.count > depth { endMarkedContent() }
    }

    // MARK: - Form recursion

    /// Clears any half-built path. A form XObject starts with no current path, and a
    /// path left open across the boundary is a malformed stream, not shared geometry.
    func resetPathForFormBoundary() {
        current = nil
        pendingSubpathStart = nil
        subpaths.removeAll(keepingCapacity: true)
        pendingClip = false
    }

    /// What ``endFormScope(_:)`` needs to put the scanner back where a `Do` found it.
    struct FormScope {
        let outerState: VectorGraphicsState
        let stateDepthBeforeSave: Int
        let markedContentDepth: Int
        /// The floor in force outside the form, restored on exit.
        let outerMarkedContentFloor: Int
    }

    /// Enters the implicit `q` a form XObject is drawn inside.
    ///
    /// The graphics state in force is captured **by value** before the `q` is attempted.
    /// At the `q`-stack cap `saveState()` refuses to push, and a matching `Q` would then
    /// pop somebody else's state — the caller's own, or the page's (CR-51). Restoring the
    /// captured value, and truncating the stack to the depth measured before the save,
    /// puts the outer stream back exactly whether or not the push happened.
    func beginFormScope() -> FormScope {
        let scope = FormScope(
            outerState: state,
            stateDepthBeforeSave: stateStackDepth,
            markedContentDepth: markedContentDepth,
            outerMarkedContentFloor: markedContentFloor
        )
        saveState()
        // Sections begun outside the form are out of the form's reach (BH-867).
        markedContentFloor = markedContentDepth
        return scope
    }

    /// Leaves the form: closes what the form left open and restores the outer state.
    func endFormScope(_ scope: FormScope) {
        truncateMarkedContentStack(to: scope.markedContentDepth)
        markedContentFloor = scope.outerMarkedContentFloor
        truncateStateStack(to: scope.stateDepthBeforeSave)
        state = scope.outerState
    }

    func pushForm(streamIdentity: UInt, resourceName: String = "", contentDigest: UInt64 = 0, formToPage: CGAffineTransform = .identity) {
        activeFormStreams.append(streamIdentity)
        activeFormNames.append(resourceName)
        nestingDepth += 1
        noteDepth(nestingDepth)
        formInvocationCount += 1
        openFormInvocations.append(OpenFormInvocation(
            contentDigest: contentDigest, start: primitives.count, depth: nestingDepth, transform: formToPage
        ))
    }

    func popForm() {
        if !activeFormStreams.isEmpty { activeFormStreams.removeLast() }
        if !activeFormNames.isEmpty { activeFormNames.removeLast() }
        if let open = openFormInvocations.popLast() {
            let identity = open.identity
            // The parent's identity covers what this drawing drew (W-080). Folded whether or
            // not the child produced primitives, so a clip that empties one nested drawing
            // leaves the composite's identity alone and it is still reported as partial.
            if !openFormInvocations.isEmpty {
                openFormInvocations[openFormInvocations.count - 1].fold(childIdentity: identity)
            }
            if primitives.count > open.start {
                formInvocations.append(VectorFormInvocation(
                    formIdentity: identity,
                    firstPrimitiveIndex: open.start,
                    primitiveCount: primitives.count - open.start,
                    depth: open.depth,
                    transform: open.transform
                ))
            }
        }
        if nestingDepth > 0 { nestingDepth -= 1 }
    }

    /// Form drawings that produced primitives, closed in scan order (NL-AUTO-12).
    private(set) var formInvocations: [VectorFormInvocation] = []
    private var openFormInvocations: [OpenFormInvocation] = []

    /// A form drawing whose content is still being scanned.
    ///
    /// Its block identity is the digest of its own content bytes **and** of the identities of
    /// the forms it drew directly, in drawing order (W-080). A composite form's bytes only
    /// name its sub-forms (`/Fm0 Do /Fm1 Do`); what those names resolve to lives in the
    /// resources, so two byte-identical composites over different sub-forms draw different
    /// assemblies and must not count as one block. A child's identity already covers its own
    /// descendants. A form that draws no other form keeps its bare content digest.
    private struct OpenFormInvocation {
        let contentDigest: UInt64
        let start: Int
        let depth: Int
        let transform: CGAffineTransform
        private var composite: FNVHash?

        init(contentDigest: UInt64, start: Int, depth: Int, transform: CGAffineTransform) {
            self.contentDigest = contentDigest
            self.start = start
            self.depth = depth
            self.transform = transform
        }

        mutating func fold(childIdentity: UInt64) {
            if composite == nil {
                var hash = FNVHash()
                hash.combine(contentDigest)
                composite = hash
            }
            composite?.combine(childIdentity)
        }

        var identity: UInt64 { composite?.value ?? contentDigest }
    }
    /// Content digests per stream object, so a form drawn many times is hashed once.
    var formDigestCache: [UInt: UInt64] = [:]

    // MARK: - Raster

    func appendRasterRegion(isInline: Bool, resourceName: String?) {
        let transform = state.ctm.concatenating(pageTransform.matrix)
        let quad = VectorQuad(
            c0: CGPoint(x: 0, y: 0).applying(transform),
            c1: CGPoint(x: 1, y: 0).applying(transform),
            c2: CGPoint(x: 1, y: 1).applying(transform),
            c3: CGPoint(x: 0, y: 1).applying(transform)
        )
        let sourceObjectID = nextSourceObjectID
        nextSourceObjectID &+= 1
        rasterRegions.append(
            VectorRasterRegion(
                id: takeIdentifier(),
                placement: quad,
                bounds: quad.bounds,
                nestingDepth: nestingDepth,
                sourceObjectID: sourceObjectID,
                isInline: isInline,
                resourceName: resourceName
            )
        )
    }
}
