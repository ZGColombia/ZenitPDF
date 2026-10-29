import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFVectorExtraction

/// Turns the three geometry sources of `SNAP_CONTRACT` 13.2 into a ``SnapIndex``.
///
/// The builder is a value type with no state beyond its limits, so it is safe to construct one
/// per incremental update.
public struct SnapIndexBuilder: Sendable {

    public let limits: SnapIndexLimits

    public init(limits: SnapIndexLimits = .standard) {
        self.limits = limits
    }

    // MARK: - Whole index

    /// - Parameter hiddenLayerIDs: marked-content property names of the layers the user has
    ///   hidden (S23). A primitive on a hidden layer never becomes a snap entry, so a hidden
    ///   layer is structurally not snappable — the same rule the renderer applies to drawing.
    ///   Unlayered content is never filtered here.
    public func build(
        page: PageDescriptor,
        extraction: VectorPageExtraction?,
        availability: SnapIndexAvailability? = nil,
        markups: [SnapMarkupGeometry] = [],
        boundaries: [SnapBoundary] = [],
        hiddenLayerIDs: Set<String> = [],
        cancellation: SnapCancellation = .never
    ) throws -> SnapIndex {
        try page.validate()

        var vector = try SnapLayer(entries: [])
        var resolved: SnapIndexAvailability = availability ?? .unavailable(.noVectorContent)

        if let extraction {
            let built = try vectorLayer(
                from: extraction, hiddenLayerIDs: hiddenLayerIDs, cancellation: cancellation
            )
            vector = built.layer
            resolved = availability ?? built.availability
        }

        // One markup or boundary that cannot be indexed — a traced ring over
        // `maximumRingVertices`, which Region Trace permits up to twice over — is left out on its
        // own, exactly as the incremental path (`SnapIndex.upsert`, whose caller drops what it
        // refuses) and the vector bridge (which skips an over-long ring) leave it out. Throwing
        // here took the whole page's vector, markup and grid snap down with it, and the
        // markup-only retry hit the same markup (U-088). The whole-index primitive cap below
        // still refuses a page that is too large as a whole.
        var markupEntryList: [SnapIndexEntry] = []
        for markup in markups {
            guard let entries = try? markupEntries(markup) else { continue }
            markupEntryList.append(contentsOf: entries)
        }
        var boundaryEntryList: [SnapIndexEntry] = []
        for boundary in boundaries {
            guard let entries = try? boundaryEntries(boundary) else { continue }
            boundaryEntryList.append(contentsOf: entries)
        }

        let total = vector.count + markupEntryList.count + boundaryEntryList.count
        guard total <= limits.maximumPrimitives else {
            throw SnapEngineError.indexTooLarge(count: total, limit: limits.maximumPrimitives)
        }

        return SnapIndex(
            page: page,
            availability: resolved,
            limits: limits,
            vectorLayer: vector,
            markupLayer: try SnapLayer(entries: resolveCollisions(markupEntryList)),
            boundaryLayer: try SnapLayer(entries: resolveCollisions(boundaryEntryList)),
            boundaries: Dictionary(boundaries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        )
    }

    // MARK: - Vector layer

    struct BuiltVectorLayer {
        let layer: SnapLayer
        let availability: SnapIndexAvailability
    }

    /// Bridges `ZPDFVectorExtraction`'s `CGPoint`-based primitives into the frozen
    /// `SnapPrimitive` vocabulary of SNAP_CONTRACT.
    ///
    /// Curves stay curves: a cubic becomes `.cubicCurve`, never a chord. Clipping-only and
    /// filtered content never reaches this function — the extractor has already dropped it, and
    /// the giant background rectangle with it.
    func vectorLayer(
        from extraction: VectorPageExtraction,
        hiddenLayerIDs: Set<String> = [],
        cancellation: SnapCancellation
    ) throws -> BuiltVectorLayer {
        var entries: [SnapIndexEntry] = []
        entries.reserveCapacity(extraction.primitives.count)

        var sinceCheck = 0
        var hiddenCount = 0
        for primitive in extraction.primitives {
            sinceCheck += 1
            if sinceCheck >= cancellation.checkInterval {
                sinceCheck = 0
                if cancellation.isCancelled() { throw SnapEngineError.cancelled }
            }
            if let layerID = primitive.layerID, hiddenLayerIDs.contains(layerID) {
                hiddenCount += 1
                continue
            }
            guard let entry = try bridge(primitive) else { continue }
            entries.append(entry)
        }

        guard entries.count <= limits.maximumPrimitives else {
            throw SnapEngineError.indexTooLarge(count: entries.count, limit: limits.maximumPrimitives)
        }

        // An extraction that reports `available` but yields no bridgeable primitive is not
        // available: reporting "Vector Snap on" for a page with nothing to snap to is the kind
        // of quiet lie `QUALITY_BAR` 3.6 forbids.
        var availability = SnapIndexAvailability(
            extraction.availability,
            partialReasons: extraction.partialReasons
        )
        //
        // Why it is empty matters to the user. A page whose drawing sits entirely on layers the
        // user has hidden is not a page with no vector content — it is a vector page whose
        // geometry was filtered — and telling them it is was the wrong message (BH-665).
        if entries.isEmpty, availability.allowsVectorCandidates {
            availability = hiddenCount > 0
                ? .unavailable(.onlyFilteredGeometry(filteredCount: hiddenCount))
                : .unavailable(.noVectorContent)
        }

        return BuiltVectorLayer(
            layer: try SnapLayer(entries: resolveCollisions(entries)),
            availability: availability
        )
    }

    private func bridge(_ primitive: VectorPrimitive) throws -> SnapIndexEntry? {
        let geometry: PrimitiveGeometry
        let kindSet: SnapEntryKindSet

        switch primitive.geometry {
        case .line(let line):
            guard !line.isDegenerate else { return nil }
            geometry = .segment(
                SegmentGeometry(start: Self.point(line.start), end: Self.point(line.end))
            )
            kindSet = .pdfVector

        case .cubic(let cubic):
            geometry = .cubicCurve(
                start: Self.point(cubic.p0),
                control1: Self.point(cubic.p1),
                control2: Self.point(cubic.p2),
                end: Self.point(cubic.p3)
            )
            kindSet = .pdfVector

        case .rectangle(let quad):
            // A `re` rectangle under a rotating or shearing CTM is a parallelogram, not an
            // axis-aligned rect, so it is stored as a closed polyline of its four transformed
            // corners rather than flattened into a `PDFRect` that would lose the rotation.
            geometry = .polyline(points: quad.corners.map(Self.point), isClosed: true)
            kindSet = .pdfVectorShape

        case .ring(let ring):
            guard ring.vertices.count >= 2 else { return nil }
            guard ring.vertices.count <= limits.maximumRingVertices else { return nil }
            if ring.containsCurves {
                // The ring records only its on-curve vertices, and the polygon through them
                // is chords, not outline: a four-Bézier circle bridged as that polygon put
                // midpoint, edge and intersection candidates 42 pt inside the arc, where
                // nothing is drawn (CR-35). The outline itself is already in the index — the
                // ring's child `.cubic` and `.line` primitives are entries of their own. What
                // the ring alone can vouch for is its centre, and only when the outline is
                // centrally symmetric; that one point is bridged, and nothing else.
                guard ring.isClosed,
                      let centre = Self.symmetricCentre(of: ring, bounds: primitive.bounds)
                else { return nil }
                geometry = .point(centre)
                kindSet = .pdfVectorCurvedShapeCentre
            } else {
                geometry = .polyline(
                    points: ring.vertices.map(Self.point),
                    isClosed: ring.isClosed
                )
                kindSet = .pdfVectorShape
            }
        }

        let bounds: PDFRect
        if case .point(let centre) = geometry {
            // A centre-only entry is found by the R-tree exactly when its one point is inside
            // the search box, so it never outranks nearer primitives in the truncation order.
            bounds = PDFRect(origin: centre, size: .zero)
        } else {
            bounds = PDFRect(
                x: primitive.bounds.minX,
                y: primitive.bounds.minY,
                width: primitive.bounds.width,
                height: primitive.bounds.height
            )
        }
        guard bounds.isFinite else { return nil }

        let snap = SnapPrimitive(
            id: primitive.id,
            bounds: bounds,
            kind: geometry.kind,
            geometry: geometry,
            sourceObjectID: primitive.sourceObjectID,
            confidence: primitive.confidence,
            layerID: primitive.layerID
        )
        guard snap.isConsistent else { throw SnapEngineError.inconsistentPrimitive(id: snap.id) }

        return SnapIndexEntry(
            primitive: snap,
            source: primitive.nestingDepth > 0 ? .pdfFormObject : .pdfPathObject,
            ownerID: nil,
            kindSet: kindSet
        )
    }

    private static func point(_ p: CGPoint) -> PDFPoint {
        PDFPoint(x: Double(p.x), y: Double(p.y))
    }

    /// The centre of a curved ring, when the ring can vouch for one.
    ///
    /// `bounds` is the extractor's box of the *outline* — it includes every curve's extrema —
    /// so for a centrally symmetric outline (a circle, an ellipse, a rounded rectangle) the
    /// box's centre is the outline's centre, exactly. Central symmetry is checked on the
    /// ring's on-curve vertices: every vertex must have its mirror image through the centre
    /// among the vertices, to within a relative `1e-9`. An outline without that symmetry has
    /// no centre worth a priority-5 label, for the same reason an L-shape has none (CR-40).
    static func symmetricCentre(of ring: VectorRing, bounds: VectorBounds) -> PDFPoint? {
        guard ring.vertices.count >= 2 else { return nil }
        let centre = PDFPoint(
            x: (bounds.minX + bounds.maxX) / 2,
            y: (bounds.minY + bounds.maxY) / 2
        )
        guard centre.isFinite else { return nil }
        let quantum = 1e-9 * Swift.max(1, bounds.width, bounds.height)

        struct Cell: Hashable {
            let x: Int64
            let y: Int64
        }
        func cell(_ x: Double, _ y: Double) -> Cell? {
            let sx = (x / quantum).rounded()
            let sy = (y / quantum).rounded()
            guard sx.isFinite, sy.isFinite,
                  Swift.abs(sx) < 1e15, Swift.abs(sy) < 1e15 else { return nil }
            return Cell(x: Int64(sx), y: Int64(sy))
        }

        var present = Set<Cell>(minimumCapacity: ring.vertices.count)
        for vertex in ring.vertices {
            guard let key = cell(Double(vertex.x), Double(vertex.y)) else { return nil }
            present.insert(key)
        }
        for vertex in ring.vertices {
            let mirrorX = 2 * centre.x - Double(vertex.x)
            let mirrorY = 2 * centre.y - Double(vertex.y)
            guard let key = cell(mirrorX, mirrorY) else { return nil }
            // The mirror image may round into a neighbouring cell.
            var found = false
            search: for dx in -1...1 {
                for dy in -1...1 where present.contains(Cell(x: key.x + Int64(dx), y: key.y + Int64(dy))) {
                    found = true
                    break search
                }
            }
            guard found else { return nil }
        }
        return centre
    }

    // MARK: - Markup layer

    public func markupEntries(_ markup: SnapMarkupGeometry) throws -> [SnapIndexEntry] {
        let owner = markup.id.rawValue.uuidString
        return try entries(
            ownerID: owner,
            domain: .markup,
            geometry: markup.geometry,
            source: .zenitMarkup,
            kindSet: { component in
                switch markup.role(at: component) {
                case .outline: .zenitMarkup
                case .smoothCurve: .zenitMarkupSmoothCurve
                case .centre: .zenitMarkupCentre
                }
            },
            layerID: markup.layerID,
            confidence: 1.0
        )
    }

    // MARK: - Boundary layer

    public func boundaryEntries(_ boundary: SnapBoundary) throws -> [SnapIndexEntry] {
        try entries(
            ownerID: boundary.id,
            domain: .boundary,
            geometry: boundary.geometry,
            source: boundary.category.source,
            kindSet: { _ in boundary.category.kindSet },
            layerID: boundary.layerID,
            confidence: boundary.confidence
        )
    }

    private func entries(
        ownerID: String,
        domain: SnapIdentifierDomain,
        geometry: [PrimitiveGeometry],
        source: SnapGeometrySource,
        kindSet: (Int) -> SnapEntryKindSet,
        layerID: String?,
        confidence: Float
    ) throws -> [SnapIndexEntry] {
        var result: [SnapIndexEntry] = []
        result.reserveCapacity(geometry.count)

        for (component, piece) in geometry.enumerated() {
            if case .polyline(let points, _) = piece {
                guard points.count <= limits.maximumRingVertices else {
                    throw SnapEngineError.indexTooLarge(
                        count: points.count,
                        limit: limits.maximumRingVertices
                    )
                }
            }
            guard let bounds = Self.bounds(of: piece), bounds.isFinite else { continue }

            let id = SnapIdentifier.make(domain: domain, ownerID: ownerID, component: component)
            let primitive = SnapPrimitive(
                id: id,
                bounds: bounds,
                kind: piece.kind,
                geometry: piece,
                sourceObjectID: nil,
                confidence: confidence,
                layerID: layerID
            )
            guard primitive.isConsistent else {
                throw SnapEngineError.inconsistentPrimitive(id: id)
            }
            result.append(
                SnapIndexEntry(
                    primitive: primitive,
                    source: source,
                    ownerID: ownerID,
                    kindSet: kindSet(component)
                )
            )
        }
        return result
    }

    /// Resolves identifier collisions deterministically.
    ///
    /// Content-derived identifiers can collide. Probing in ascending identifier order — never
    /// in insertion order and never in `Set` order — means the resolution is a function of the
    /// entry set alone, so shuffling the input cannot change which entry keeps the original
    /// identifier.
    func resolveCollisions(_ entries: [SnapIndexEntry]) throws -> [SnapIndexEntry] {
        guard entries.count > 1 else { return entries }
        var seen = Set<UInt64>(minimumCapacity: entries.count)
        var result: [SnapIndexEntry] = []
        result.reserveCapacity(entries.count)

        for entry in entries.sorted(by: Self.stableOrder) {
            var id = entry.id
            if seen.contains(id) {
                var probe = 0
                repeat {
                    probe += 1
                    guard probe <= 64 else { throw SnapEngineError.duplicateIdentifier(id: entry.id) }
                    id = entry.id &+ UInt64(probe)
                } while seen.contains(id)
                let rewritten = SnapPrimitive(
                    id: id,
                    bounds: entry.primitive.bounds,
                    kind: entry.primitive.kind,
                    geometry: entry.primitive.geometry,
                    sourceObjectID: entry.primitive.sourceObjectID,
                    confidence: entry.primitive.confidence,
                    layerID: entry.primitive.layerID
                )
                result.append(
                    SnapIndexEntry(
                        primitive: rewritten,
                        source: entry.source,
                        ownerID: entry.ownerID,
                        kindSet: entry.kindSet
                    )
                )
            } else {
                result.append(entry)
            }
            seen.insert(id)
        }
        return result
    }

    /// A total order over entries that does not depend on hashing or on insertion order.
    private static func stableOrder(_ a: SnapIndexEntry, _ b: SnapIndexEntry) -> Bool {
        if a.id != b.id { return a.id < b.id }
        if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
        if a.bounds.minY != b.bounds.minY { return a.bounds.minY < b.bounds.minY }
        if a.bounds.maxX != b.bounds.maxX { return a.bounds.maxX < b.bounds.maxX }
        if a.bounds.maxY != b.bounds.maxY { return a.bounds.maxY < b.bounds.maxY }
        return a.primitive.kind.rawValue < b.primitive.kind.rawValue
    }

    static func bounds(of geometry: PrimitiveGeometry) -> PDFRect? {
        switch geometry {
        case .point(let p):
            return PDFRect(origin: p, size: .zero)
        case .segment(let s):
            return s.bounds
        case .polyline(let points, _):
            return PDFRect.boundingBox(of: points)
        case .cubicCurve(let start, let c1, let c2, let end):
            return PDFRect.boundingBox(of: [start, c1, c2, end])
        case .quadraticCurve(let start, let control, let end):
            return PDFRect.boundingBox(of: [start, control, end])
        case .rectangle(let r):
            return r.standardized
        case .circle(let c):
            return c.bounds
        case .ellipticalArc(let a):
            // The arc's own box (W-087). Its whole circle made a shallow arc — a 400 pt chord
            // with bulge 0.02 has r ≈ 5000 pt — a distance-0 entry under every cursor on the
            // sheet. A markup arc's centre, which lies off this box, is a piece of its own
            // (``SnapMarkupGeometry/from(_:unprojectedCutouts:)``).
            return a.bounds
        }
    }
}
