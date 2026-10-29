import Foundation
import ZPDFContracts

/// Drawing **imported** artwork — a compiled PDF page or a compiled image — as the shapes this
/// renderer already has.
///
/// ``StampArtworkScene`` draws artwork the product itself composed. This extension draws
/// artwork that came out of a file somebody chose, which differs in exactly two ways and in no
/// others:
///
/// - a compiled region may carry **its own colour**, because a raster mosaic without colour is
///   not a picture, while a compiled PDF page carries none and takes the markup's style colour
///   (the extractor records paint role and stroke width, not ink — ADR-0011 §2.4);
/// - a compiled contour carries a **width fraction** rather than a width, so one compilation
///   serves a 96-point stamp and a 400-point one without re-deriving anything.
///
/// Everything else is deliberately the same. There is no image in this path, no texture, no
/// atlas: `ArtworkGeometry` is contours in a unit box and an affine placement maps them into
/// page space, so magnification multiplies coordinates. That is the whole of the "sharp at
/// 400 %" claim, and it is structural rather than a quality setting.
extension StampArtworkScene {

    /// The shapes one placement of imported artwork contributes to a page.
    ///
    /// - Parameters:
    ///   - artwork: compiled artwork in unit space.
    ///   - labels: resolved stamp fields, in unit space. Empty for a count symbol.
    ///   - center: the placement's anchor in page space.
    ///   - size: the artwork's box in PDF points.
    ///   - rotationDegrees: rotation about ``center``, counter-clockwise.
    ///   - style: the stroke and fill a region without its own colour takes.
    ///   - baseID: the placed markup's identity, so the whole placement selects as one markup.
    ///   - zIndex: painter's-algorithm order.
    public static func markups(
        artwork: ArtworkGeometry,
        labels: [StampSceneLabel] = [],
        center: PDFPoint,
        size: PDFSize,
        rotationDegrees: Double = 0,
        style: RenderStyle = .default,
        baseID: MarkupID,
        zIndex: Int = 0
    ) -> [RenderableMarkup] {
        // The artwork is letterboxed inside the box by its own aspect ratio, exactly as the
        // canvas draws it (`CanvasStampPlacement.fittedArtworkSize`); the labels keep the whole
        // box, because a field's frame is a slot in the stamp, not in the picture. Mapping the
        // unit box straight onto `size` stretched an oval seal into a circle in every export
        // while the sheet showed the oval (BH-203). For a count symbol the size passed in is
        // already fitted, and fitting a fitted size is the identity.
        let artworkSize = fittedSize(aspectRatio: artwork.sourceAspectRatio, inBox: size)
        let place = placement(center: center, size: artworkSize, rotationDegrees: rotationDegrees)
        let labelPlace = placement(center: center, size: size, rotationDegrees: rotationDegrees)
        let reference = Swift.min(abs(artworkSize.width), abs(artworkSize.height))
        var output: [RenderableMarkup] = []
        output.reserveCapacity(artwork.primitiveCount + labels.count)
        var ordinal = 0
        func nextID() -> MarkupID {
            defer { ordinal += 1 }
            return shapeIdentity(base: baseID, ordinal: ordinal)
        }

        for region in artwork.regions {
            var regionStyle = style
            if let color = region.color {
                // A mosaic cell paints itself. It is a fill and never a stroke: a one-pixel
                // outline on every cell would double the ink and turn a photograph into a grid.
                regionStyle.fill = color
                regionStyle.stroke = nil
            } else {
                // A compiled PDF page's region carries no ink (ADR-0011 §2.4), and it is still a
                // *solid area*: the canvas fills it with the markup's ink. Keeping the style
                // unchanged drew it as a hollow outline whenever the style was stroke-only —
                // which `RenderStyle.default` and the snippet's stamp style both are — so the
                // exported seal disagreed with the sheet (BH-032). The style's fill wins when it
                // has one; otherwise the ink is the stroke colour. Never an outline.
                regionStyle.fill = style.fill ?? style.stroke
                regionStyle.stroke = nil
            }
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: zIndex,
                shape: .filledPolygon(RenderPolygon(
                    outer: region.outer.map(place),
                    holes: region.holes.map { $0.map(place) }
                )),
                style: regionStyle
            ))
        }

        for contour in artwork.strokes {
            var contourStyle = style
            if reference > 0 {
                // `0` is "the renderer's default" in the contract, and the default is a fraction
                // of the box like every declared width — the canvas's `max(0.5, 2 % of the
                // smaller edge)` — so an undeclared contour scales with the stamp too. Falling
                // back to the style's fixed width made the export's line weights disagree with
                // the sheet and ignore the box size (BH-632).
                contourStyle.lineWidth = contour.widthFraction > 0
                    ? contour.widthFraction * reference
                    : Swift.max(
                        Self.minimumDefaultContourWidthPoints,
                        Self.defaultContourWidthFraction * reference
                    )
            }
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: zIndex,
                shape: .polyline(RenderPolyline(
                    points: contour.points.map(place),
                    isClosed: contour.isClosed
                )),
                style: contourStyle
            ))
        }

        output.append(contentsOf: labelMarkups(
            labels, place: labelPlace, size: size, rotationDegrees: rotationDegrees, style: style,
            baseID: baseID, firstOrdinal: ordinal, zIndex: zIndex
        ))
        return output
    }

    /// The width a contour with `widthFraction == 0` is drawn at, as a fraction of the artwork
    /// box's smaller edge — the value the canvas painters use. See BH-632.
    public static let defaultContourWidthFraction = 0.02
    /// The floor under ``defaultContourWidthFraction``, in points.
    public static let minimumDefaultContourWidthPoints = 0.5

    /// The box artwork of `aspectRatio` occupies inside `box`, aspect preserved and centred —
    /// letterboxed, never stretched. An unusable ratio or box returns `box` unchanged.
    public static func fittedSize(aspectRatio: Double, inBox box: PDFSize) -> PDFSize {
        let width = abs(box.width), height = abs(box.height)
        guard aspectRatio.isFinite, aspectRatio > 0,
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return box }
        let boxAspect = width / height
        let fitted = aspectRatio >= boxAspect
            ? PDFSize(width: width, height: width / aspectRatio)
            : PDFSize(width: height * aspectRatio, height: height)
        // Keep the caller's signs, so a mirrored box stays mirrored.
        return PDFSize(
            width: box.width < 0 ? -fitted.width : fitted.width,
            height: box.height < 0 ? -fitted.height : fitted.height
        )
    }

    /// The box imported artwork occupies inside a square of `sizePoints`, aspect preserved.
    ///
    /// A count symbol is asked for by one number — "12 points" — and artwork is rarely square.
    /// Stretching it to the square is the wrong answer: an oval company mark placed a thousand
    /// times is a thousand wrong marks, and nobody notices until the plot.
    public static func fittedSize(
        aspectRatio: Double,
        inSquareOf sizePoints: Double
    ) -> PDFSize {
        guard aspectRatio.isFinite, aspectRatio > 0, sizePoints.isFinite, sizePoints > 0 else {
            return PDFSize(width: Swift.max(0, sizePoints), height: Swift.max(0, sizePoints))
        }
        return aspectRatio >= 1
            ? PDFSize(width: sizePoints, height: sizePoints / aspectRatio)
            : PDFSize(width: sizePoints * aspectRatio, height: sizePoints)
    }

    /// One count mark drawn from imported artwork.
    ///
    /// A count symbol rides exactly the pipeline a stamp's artwork rides — a count mark with
    /// a chosen symbol is a supported feature, and the chosen symbol is the same kind of
    /// thing a stamp's picture is. That is why there is no second compiler, no second store and
    /// no second renderer path: a count mark with imported artwork is a small stamp with no
    /// fields on it.
    public static func countSymbol(
        artwork: ArtworkGeometry,
        center: PDFPoint,
        sizePoints: Double,
        rotationDegrees: Double = 0,
        style: RenderStyle = .default,
        baseID: MarkupID,
        zIndex: Int = 0
    ) -> [RenderableMarkup] {
        markups(
            artwork: artwork,
            labels: [],
            center: center,
            size: fittedSize(aspectRatio: artwork.sourceAspectRatio, inSquareOf: sizePoints),
            rotationDegrees: rotationDegrees,
            style: style,
            baseID: baseID,
            zIndex: zIndex
        )
    }

    /// The shapes one ``MarkupSymbol`` contributes, resolving imported artwork when the store
    /// has it and falling back to a built-in glyph when it does not.
    ///
    /// The fallback is the honest part. A project that reaches a build whose artwork store has
    /// been emptied — a hand-edited package, a partial restore — must draw *something* at the
    /// mark's own size and position rather than nothing at all, because a count of 40 that
    /// silently renders 12 marks is a wrong quantity and a mark drawn as a plain circle is a
    /// visible one.
    public static func markups(
        symbol: MarkupSymbol,
        artwork: ArtworkGeometry?,
        center: PDFPoint,
        style: RenderStyle = .default,
        baseID: MarkupID,
        zIndex: Int = 0
    ) -> [RenderableMarkup] {
        let size = symbol.sizePoints.isFinite
            && symbol.sizePoints >= ArtworkLimits.minimumBoxPoints
            && symbol.sizePoints <= ArtworkLimits.maximumBoxPoints
            ? symbol.sizePoints
            : 12
        // A non-finite angle is drawn upright, as the canvas painter does. Forwarding it made
        // cos/sin NaN, every placed point NaN, and the compiler rejected every shape — the mark
        // vanished from the export while the sheet still showed it (BH-633).
        let rotation = symbol.rotationDegrees.isFinite ? symbol.rotationDegrees : 0
        if let artwork, !artwork.isEmpty, symbol.usesImportedArtwork {
            return countSymbol(
                artwork: artwork,
                center: center,
                sizePoints: size,
                rotationDegrees: rotation,
                style: style,
                baseID: baseID,
                zIndex: zIndex
            )
        }
        let glyph = symbol.builtInGlyph.flatMap(CountSymbol.init(name:)) ?? .filledCircle
        return [RenderableMarkup(
            id: baseID,
            zIndex: zIndex,
            // The fallback turns with the mark, as the artwork path and the canvas do; it used
            // to be built without the angle and exported upright (BH-634).
            shape: .countSymbol(RenderCountSymbol(
                center: center,
                symbol: glyph,
                size: size,
                rotationDegrees: rotation
            )),
            style: style
        )]
    }

    /// The label half of ``markups(artwork:labels:center:size:rotationDegrees:style:baseID:zIndex:)``,
    /// shared with the composed-artwork path so a field sits in the same place either way.
    ///
    /// A field is part of the seal and turns with it (`rotationDegrees`), as the canvas draws
    /// it. Before T-065 the anchor turned but the text stayed screen-upright, so a 90° stamp
    /// printed its fields across a tall, narrow box in every export.
    static func labelMarkups(
        _ labels: [StampSceneLabel],
        place: (PDFPoint) -> PDFPoint,
        size: PDFSize,
        rotationDegrees: Double,
        style: RenderStyle,
        baseID: MarkupID,
        firstOrdinal: Int,
        zIndex: Int
    ) -> [RenderableMarkup] {
        let rotation = rotationDegrees.isFinite ? rotationDegrees : 0
        return labels.enumerated().compactMap { offset, label in
            guard !label.text.isEmpty else { return nil }
            let frame = label.normalizedFrame
            let anchorPoint = labelAnchorPoint(frame: frame, anchor: label.anchor)
            return RenderableMarkup(
                id: shapeIdentity(base: baseID, ordinal: firstOrdinal + offset),
                zIndex: zIndex,
                shape: .textLabel(RenderTextLabel(
                    anchorPoint: place(anchorPoint),
                    text: label.text,
                    fontName: label.fontName,
                    // The font scales with the stamp box, so one template is legible at 96
                    // points and at 400 without a second layout.
                    fontSize: Swift.max(1, label.fontSizeFraction * size.height),
                    anchor: label.anchor,
                    rotationDegrees: rotation
                )),
                style: style
            )
        }
    }
}

extension CountSymbol {

    /// The glyph's stable name, which is what a ``MarkupSymbol`` stores.
    ///
    /// A name rather than the raw value, because the raw value is a wire format for the GPU
    /// instance buffer and a persisted markup should not be pinned to a byte in a shader.
    public var name: String {
        switch self {
        case .filledCircle: "filledCircle"
        case .hollowCircle: "hollowCircle"
        case .filledSquare: "filledSquare"
        case .hollowSquare: "hollowSquare"
        case .filledTriangle: "filledTriangle"
        case .hollowTriangle: "hollowTriangle"
        case .filledDiamond: "filledDiamond"
        case .cross: "cross"
        case .plus: "plus"
        case .star: "star"
        }
    }

    /// The glyph with the given name, or `nil` for a name this build does not know.
    ///
    /// `nil` rather than a default, so a caller decides what an unknown glyph means. The
    /// renderer's own fallback is a filled circle and it is stated at the one place it happens.
    public init?(name: String) {
        guard let match = CountSymbol.allCases.first(where: { $0.name == name }) else {
            return nil
        }
        self = match
    }
}

extension StampArtworkScene {

    /// The identity of the *n*-th shape of a multi-shape placement.
    ///
    /// # Why a stamp cannot be one identity
    ///
    /// Every index in this renderer is keyed by ``MarkupID`` and holds **one entry per
    /// identity**: `InstanceArena.slots`, `ScenePreparer`'s bounds map, the hit tester's
    /// spatial index. That is not an implementation detail to be worked around — it is what
    /// makes an incremental frame possible, because "this markup changed" has to name a slot.
    ///
    /// ADR-0010 gave every shape of a stamp the *same* id so a stamp would select and delete as
    /// one markup. Nothing rendered a stamp at first, and when something finally did, the
    /// Metal backend drew **one shape per stamp**: twenty-two contours upserted into one slot,
    /// each overwriting the last. The reference backend drew all of them, so the two backends
    /// disagreed by 99 % of the ink — see §2.6 of ADR-0011, which is the record of it.
    ///
    /// So a shape gets its own identity, derived from the placement's: the first twelve bytes
    /// are the stamp's and the last four are the ordinal. Painter order within a stamp becomes
    /// exactly emission order, which it was not before — `(zIndex, id)` could not order shapes
    /// that shared both — and ``isPart(_:of:)`` answers "does this shape belong to that stamp?"
    /// for selection and deletion, which is the property ADR-0010 actually wanted.
    public static func shapeIdentity(base: MarkupID, ordinal: Int) -> MarkupID {
        let bytes = base.rawValue.uuid
        let index = UInt32(truncatingIfNeeded: ordinal)
        return MarkupID(UUID(uuid: (
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            UInt8((index >> 24) & 0xFF), UInt8((index >> 16) & 0xFF),
            UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF)
        )))
    }

    /// Whether `id` is a shape of the placement identified by `base`.
    ///
    /// The family key is the first twelve bytes — ninety-six bits of a version-4 UUID, so two
    /// unrelated markups sharing it is not a case anybody will meet.
    public static func isPart(_ id: MarkupID, of base: MarkupID) -> Bool {
        let a = id.rawValue.uuid
        let b = base.rawValue.uuid
        return a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3
            && a.4 == b.4 && a.5 == b.5 && a.6 == b.6 && a.7 == b.7
            && a.8 == b.8 && a.9 == b.9 && a.10 == b.10 && a.11 == b.11
    }
}
