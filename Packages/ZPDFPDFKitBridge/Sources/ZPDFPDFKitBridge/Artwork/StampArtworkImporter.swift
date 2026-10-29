import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFVectorExtraction

/// Turning a chosen PDF page or image into stamp and count-symbol artwork.
///
/// # The two rules this type exists to keep
///
/// **Vector stays vector.** A PDF page is *compiled into geometry* — through
/// `ZPDFVectorExtraction.VectorExtractor`, the same `CGPDFScanner` path Vector Snap uses, so
/// there is exactly one PDF path scanner in this product and no chance of two of them
/// disagreeing. The compiled form is contours in a `0...1` box, which the renderer draws as
/// ordinary polylines and filled polygons. There is no image anywhere in that pipeline, so
/// magnification multiplies coordinates and cannot resample: a stamp is sharp at 400 %.
///
/// **A raster is accepted and marked, never silently degraded.** An imported image is compiled
/// to a bounded cell mosaic and flagged ``StampArtworkKind/raster``, so the preset editor can
/// say — with a number — the magnification above which it stops adding detail. The estimator
/// finds out at import, not on a plot.
///
/// # Imported artwork is data
///
/// Everything here treats the file as hostile input (ADR-0011 §2.5):
///
/// - the source is bounded before it is read, and the raster's pixel count is read from the
///   image source's metadata and refused *before* a decode is attempted;
/// - the compiled geometry is bounded again, by ``ArtworkGeometry/limitViolation()`` — the one
///   implementation of the limits, which every decoder of stored artwork calls as well, because
///   a value read back off disk is input again;
/// - every refusal is an ``ArtworkImportRefusal`` carrying the number it hit;
/// - **nothing in the file is executed.** This type reads path-construction and path-painting
///   operators and image samples. It never evaluates `/OpenAction`, `/AA`, `/JavaScript`,
///   `/Launch` or `/SubmitForm`, never resolves an external reference, and never touches the
///   network — the guarantees ``PDFBridgeSecurityPolicy`` states for the rest of this package,
///   restated here because an import is the one place a person hands the product a file
///   chosen for its picture rather than for its content.
public struct StampArtworkImporter: Sendable {

    /// The extraction budget artwork import runs under.
    ///
    /// Deliberately tighter than the Vector Snap budget: snap scans a drawing sheet the person
    /// is already looking at, and import scans a file they have just been handed. The nesting
    /// depth is ``ArtworkLimits/maximumNestingDepth`` so a self-referential form XObject
    /// terminates inside the scanner rather than inside our loop.
    public static var budget: VectorExtractionBudget {
        VectorExtractionBudget(
            maximumOperatorCount: 2_000_000,
            maximumPrimitiveCount: ArtworkLimits.maximumContours,
            wallClockLimitNanoseconds: 20_000_000_000,
            memoryLimitBytes: 256 * 1024 * 1024,
            maximumFormNestingDepth: ArtworkLimits.maximumNestingDepth,
            maximumPointsPerSubpath: ArtworkLimits.maximumPointsPerContour
        )
    }

    /// The extraction options artwork import runs under.
    ///
    /// The background filter is **off**. It exists to stop a snap index being dominated by a
    /// sheet's white background rectangle; an imported seal's outer box is the artwork, and
    /// dropping it because it is the biggest thing on the page would delete the stamp's border.
    /// Geometry lying entirely outside the crop box is dropped by ``compile(_:)`` instead,
    /// which the filter's own switch cannot do without also enabling the page-sized rule
    /// (BH-026).
    ///
    /// The page space is the **displayed** one — crop-box relative, `/Rotate` applied — because
    /// the person chose the picture they saw. Unrotated user space imports a `/Rotate 90`
    /// title block sideways (BH-025).
    public static var extractionOptions: VectorExtractionOptions {
        VectorExtractionOptions(
            budget: budget,
            backgroundFilter: .disabled,
            pageSpaceConvention: .cropBoxRotated,
            emitsClipDerivedPrimitives: false,
            emitsShapePrimitives: true
        )
    }

    /// Points a flattened cubic contributes, tip to tail.
    ///
    /// Fixed rather than adaptive: the artwork is compiled once and stored, so the cost is
    /// paid once, and a fixed count makes the compiled output a pure function of the input —
    /// which is what lets a digest address a picture.
    static let curveSampleCount = 12

    private let extractor: VectorExtractor

    /// Creates an importer.
    ///
    /// - Parameter extractor: the shared page scanner. The default is configured for import,
    ///   which is not the same configuration Vector Snap runs.
    public init(extractor: VectorExtractor? = nil) {
        self.extractor = extractor ?? VectorExtractor(options: Self.extractionOptions)
    }

    // MARK: - Import

    /// Imports artwork from a chosen source.
    ///
    /// - Throws: ``ArtworkImportRefusal`` and nothing else. Every failure names the limit or
    ///   the property that produced it.
    public func importArtwork(from source: ArtworkSource) async throws -> ImportedArtwork {
        let bytes = try Self.readBoundedSource(at: source.url)
        switch source {
        case let .pdfPage(url, pageIndex):
            return try await importPDFPage(sourceBytes: bytes, sourceURL: url, pageIndex: pageIndex)
        case let .image(url):
            let compiled = try Self.compileImage(bytes: bytes)
            return ImportedArtwork(
                geometry: compiled.geometry,
                digest: FileDigestReader.digest(of: bytes).sha256,
                sourceBytes: bytes,
                sourceName: url.lastPathComponent,
                pixelWidth: compiled.pixelWidth,
                pixelHeight: compiled.pixelHeight
            )
        }
    }

    /// Compiles a PDF page from **the bytes that were read**, not from the file again.
    ///
    /// The digest and the stored ``ImportedArtwork/sourceBytes`` describe `sourceBytes`; if the
    /// scanner reopened `sourceURL`, a file rewritten between the two reads (a title block
    /// re-exported while the chooser is open, a syncing folder) would store a digest that does
    /// not describe the compiled geometry, and the content-addressed store would later dedupe
    /// those bytes onto the wrong picture (BH-567). So the bytes are snapshotted into a private
    /// temporary file and the scanner reads the snapshot.
    func importPDFPage(sourceBytes bytes: Data, sourceURL url: URL, pageIndex: Int) async throws -> ImportedArtwork {
        let snapshot = try Self.writeSnapshot(bytes)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        let compiled = try await compilePDFPage(at: snapshot, pageIndex: pageIndex)
        // The digest folds in the page index: two pages of one PDF must address different
        // artwork, or the store's `INSERT OR IGNORE` on the digest drops the second (CR-72).
        return ImportedArtwork(
            geometry: compiled.geometry,
            digest: FileDigestReader.digest(of: bytes, pageIndex: pageIndex).sha256,
            sourceBytes: bytes,
            sourceName: url.lastPathComponent,
            sourcePageIndex: pageIndex,
            sourceInk: compiled.sourceInk
        )
    }

    /// Writes `bytes` to a fresh, private directory under the temporary directory.
    static func writeSnapshot(_ bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-artwork-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent("source.pdf", isDirectory: false)
            try bytes.write(to: url, options: [.atomic])
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ArtworkImportRefusal.unreadableSource
        }
    }

    /// What a chosen PDF holds, read **without importing anything from it**.
    ///
    /// A multi-page PDF was silently importing its first page, because nothing could tell the
    /// chooser there were others. Answering "how many pages"
    /// is the same bounded, exception-guarded probe ``refuseUnusablePDF(at:pageIndex:)`` already
    /// runs before the scanner is pointed at a file — the size bound, the encryption check and
    /// the page count — so the question costs one catalogue read and cannot be answered by a
    /// path that disagrees with the import's own.
    ///
    /// - Throws: ``ArtworkImportRefusal`` and nothing else, so a file the import would refuse
    ///   is refused here too, before the person has chosen a page out of it.
    public func inspectPDF(at url: URL) throws -> ArtworkSourceInspection {
        _ = try Self.readBoundedSource(at: url)
        // Page zero always exists in a document with pages, so this is the page-count probe
        // and the encryption refusal with no extra surface of its own.
        try Self.refuseUnusablePDF(at: url, pageIndex: 0)
        let pages = try Self.pageCount(at: url)
        return ArtworkSourceInspection(fileName: url.lastPathComponent, pageCount: pages)
    }

    /// The page count of a PDF, behind the same exception barrier the import uses.
    static func pageCount(at url: URL) throws -> Int {
        do {
            return try EngineBarrier.guarded("artworkProbe") {
                CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
            }
        } catch {
            throw ArtworkImportRefusal.unreadableSource
        }
    }

    /// Reads a source file, refusing one that is larger than the limit **before** reading it.
    static func readBoundedSource(at url: URL) throws -> Data {
        let byteCount: Int
        do {
            byteCount = try FileDigestReader.fileByteCount(at: url)
        } catch {
            throw ArtworkImportRefusal.unreadableSource
        }
        guard byteCount <= ArtworkLimits.maximumSourceBytes else {
            throw ArtworkImportRefusal.sourceTooLarge(
                bytes: byteCount, limit: ArtworkLimits.maximumSourceBytes
            )
        }
        guard byteCount > 0 else { throw ArtworkImportRefusal.empty }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ArtworkImportRefusal.unreadableSource
        }
        return Data(data)
    }

    // MARK: - PDF page

    /// Compiles one PDF page into unit-space geometry, and names its ink when it has one.
    func compilePDFPage(at url: URL, pageIndex: Int) async throws -> CompiledPage {
        try Self.refuseUnusablePDF(at: url, pageIndex: pageIndex)

        let extraction: VectorPageExtraction
        do {
            extraction = try await extractor.extract(documentAt: url, pageIndex: pageIndex)
        } catch let error as VectorExtractionError {
            throw Self.refusal(for: error)
        } catch {
            throw ArtworkImportRefusal.unreadableSource
        }
        if case let .partial(reason) = extraction.availability, reason.meansGeometryWasMissed {
            throw Self.refusal(for: reason, primitiveCount: extraction.primitives.count)
        }
        if case .unavailable = extraction.availability {
            throw Self.refusalForUnavailablePage(extraction)
        }
        return try Self.compilePage(extraction)
    }

    /// Why a page with no path geometry is refused.
    ///
    /// "There is nothing to draw on that page" is false for the two commonest cases: a page
    /// whose picture is a `/Stamp` or other annotation appearance (what most stamp-export tools
    /// write), and a scanned page whose picture is an image. Saying which one it is tells the
    /// person what to do next — flatten the PDF, or import the image (BH-568).
    static func refusalForUnavailablePage(_ extraction: VectorPageExtraction) -> ArtworkImportRefusal {
        if extraction.partialReasons.contains(.annotationAppearanceStreamsNotExtracted) {
            return .incompleteArtwork(
                detail: "the picture is drawn by an annotation; flatten the PDF and import it again"
            )
        }
        if !extraction.rasterRegions.isEmpty {
            return .incompleteArtwork(
                detail: "the page holds an image, not linework; import the image file instead"
            )
        }
        return .empty
    }

    /// The checks that must happen before the scanner is pointed at the file.
    ///
    /// Encryption and page count come from CoreGraphics rather than PDFKit, and are read
    /// behind the same Objective-C exception barrier the rest of this package uses, because a
    /// malformed catalogue is exactly the input that raises.
    static func refuseUnusablePDF(at url: URL, pageIndex: Int) throws {
        let inspection: (encrypted: Bool, pages: Int)
        do {
            inspection = try EngineBarrier.guarded("artworkProbe") {
                guard let document = CGPDFDocument(url as CFURL) else {
                    return (false, 0)
                }
                // An encrypted document that CoreGraphics could not unlock exposes no pages,
                // and Zenit does not carry a password into an artwork import.
                let encrypted = document.isEncrypted && !document.isUnlocked
                return (encrypted, document.numberOfPages)
            }
        } catch {
            throw ArtworkImportRefusal.unreadableSource
        }
        if inspection.encrypted { throw ArtworkImportRefusal.encryptedSource }
        guard inspection.pages > 0 else { throw ArtworkImportRefusal.unreadableSource }
        guard pageIndex >= 0, pageIndex < inspection.pages else {
            throw ArtworkImportRefusal.pageOutOfRange(
                requested: pageIndex, pageCount: inspection.pages
            )
        }
    }

    /// Maps the scanner's failures onto refusals the person can read.
    static func refusal(for error: VectorExtractionError) -> ArtworkImportRefusal {
        switch error {
        case let .documentEncrypted(name):
            _ = name
            return .encryptedSource
        case let .pageIndexOutOfRange(index, pageCount):
            return .pageOutOfRange(requested: index, pageCount: pageCount)
        case .documentHasNoPages, .contentStreamUnavailable:
            return .empty
        case .cancelled:
            return .incompleteArtwork(detail: "the import was cancelled")
        case let .invalidOption(name, reason):
            return .incompleteArtwork(detail: "\(name): \(reason)")
        case .documentUnreadable, .fileUnreadable, .cacheDecodingFailed:
            return .unreadableSource
        }
    }

    /// Maps an incomplete extraction onto a refusal.
    ///
    /// Vector Snap's contract is "degrade to fewer candidates, never to wrong candidates, and
    /// always say so". Artwork has no equivalent: half a seal is not a smaller seal, it is the
    /// wrong picture, and a stamp is placed on 312 sheets before anybody looks closely. So a
    /// partial extraction that missed geometry is refused here, with the scanner's own reason
    /// in the sentence, even though the same condition is only a warning for snap.
    static func refusal(for reason: VectorPartialReason, primitiveCount: Int) -> ArtworkImportRefusal {
        switch reason {
        case let .budgetExceeded(kind, _):
            if kind == .primitiveCount {
                return .tooManyContours(
                    found: primitiveCount, limit: ArtworkLimits.maximumContours
                )
            }
            return .incompleteArtwork(detail: "the \(kind.name) budget stopped the scan")
        case let .formNestingDepthExceeded(limit):
            return .nestingTooDeep(depth: limit, limit: ArtworkLimits.maximumNestingDepth)
        case .cyclicFormReference:
            return .nestingTooDeep(
                depth: ArtworkLimits.maximumNestingDepth, limit: ArtworkLimits.maximumNestingDepth
            )
        case .type3GlyphGeometryNotExtracted:
            return .incompleteArtwork(detail: "the page draws linework with Type 3 glyphs")
        case .shadingGeometryNotExtracted:
            return .incompleteArtwork(detail: "the page uses shading no path describes")
        case .softMaskNotComposited:
            return .incompleteArtwork(detail: "the page uses a soft mask")
        case let .malformedContentStream(failures):
            return .incompleteArtwork(detail: "\(failures) malformed operators")
        case let .hiddenOptionalContentExcluded(count):
            return .incompleteArtwork(detail: "\(count) hidden optional-content groups")
        case .annotationAppearanceStreamsNotExtracted, .inlineImageSkipped:
            // Neither means a path was missed; the scanner says so itself.
            return .incompleteArtwork(detail: "informational")
        }
    }

    /// Turns extracted page-space primitives into unit-space artwork.
    ///
    /// # Why the selection looks the way it does
    ///
    /// The extractor emits a *shape* primitive for a rectangle or a closed subpath **and**
    /// leaf primitives for the segments inside it, with `parentID` linking them. Taking both
    /// would draw every closed outline twice, at double weight. So: fills and closed outlines
    /// come from the shapes, and open geometry comes from the leaves that have no parent.
    static func compile(_ extraction: VectorPageExtraction) throws -> ArtworkGeometry {
        try compilePage(extraction).geometry
    }

    /// A compiled PDF page: the geometry that is stored and drawn, and the page's one ink.
    struct CompiledPage: Sendable {
        let geometry: ArtworkGeometry
        /// See ``ImportedArtwork/sourceInk``.
        let sourceInk: RGBAColor?
    }

    /// The single ink a page is drawn in, or `nil` when it has none, several, or one the
    /// extractor could not state.
    ///
    /// Decided 2026-09-23 (BH-167 follow-up, ADR-0011 §2.4): an imported one-colour seal
    /// looks as drawn by default. Its regions stay colourless in the geometry, so the stamp's
    /// colour still recolours fills and strokes together; this is the colour that stamp colour
    /// starts at. The rules:
    ///
    /// - every painted role counts — a fill's colour for a filled path, a stroke's colour for
    ///   a stroked one — because a seal of rings alone is still a red seal;
    /// - opaque white is never ink: painted first it is paper, painted over ink it is a
    ///   knockout, and either way it keeps its own treatment in ``compilePage(_:)``;
    /// - a role whose colour is `nil` (a pattern, a separation, an unreadable operand) makes the
    ///   answer `nil`: a colour this product cannot state is not guessed, and the stamp keeps
    ///   the tool's colour exactly as before.
    static func sourceInk(of primitives: [VectorPrimitive]) -> RGBAColor? {
        var inks = Set<VectorColor>()
        for primitive in primitives {
            var roles: [VectorColor?] = []
            if primitive.paint.contains(.filled) { roles.append(primitive.fillColor) }
            if primitive.paint.contains(.stroked) { roles.append(primitive.strokeColor) }
            for role in roles {
                guard let color = role else { return nil }
                if !color.isOpaqueWhite { inks.insert(color) }
            }
        }
        guard inks.count == 1, let ink = inks.first else { return nil }
        return RGBAColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
    }

    /// ``compile(_:)``, keeping the page's ink beside the geometry.
    static func compilePage(_ extraction: VectorPageExtraction) throws -> CompiledPage {
        guard !extraction.primitives.isEmpty else { throw ArtworkImportRefusal.empty }
        for primitive in extraction.primitives {
            let box = primitive.bounds
            guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite
            else { throw ArtworkImportRefusal.nonFiniteGeometry }
        }

        // Geometry that misses the crop box entirely is invisible on the page the person
        // chose. Letting it into the bounding box made a seal cropped out of a sheet import
        // as the whole sheet with the seal in one corner (BH-026). Geometry that merely runs
        // past the crop edge is kept: it is part of what is visible.
        let cropBox = extraction.pageTransform.canonicalCropBox
        let primitives = extraction.primitives.filter { primitive in
            !(cropBox.width > 0 && cropBox.height > 0) || cropBox.intersects(primitive.bounds)
        }
        guard !primitives.isEmpty else { throw ArtworkImportRefusal.empty }

        var bounds: VectorBounds?
        for primitive in primitives {
            let box = primitive.bounds
            bounds = bounds.map { $0.union(box) } ?? box
        }
        guard let box = bounds, box.width > 0, box.height > 0 else {
            throw ArtworkImportRefusal.degenerateBounds
        }

        // The artwork's own bounding box becomes the unit box; the aspect ratio is reported
        // so a caller can propose a stamp box that does not distort it.
        func unit(_ point: CGPoint) -> PDFPoint {
            PDFPoint(
                x: (point.x - box.minX) / box.width,
                y: (point.y - box.minY) / box.height
            )
        }
        let widthFraction = { (strokeWidth: Double) -> Double in
            let reference = Swift.min(box.width, box.height)
            guard reference > 0, strokeWidth.isFinite, strokeWidth > 0 else { return 0 }
            return Swift.min(0.5, strokeWidth / reference)
        }

        // A subpath that contains curves is emitted as a *ring* of its on-curve vertices plus
        // child `.cubic` primitives carrying the real curve. Taking the ring alone turns an
        // imported circle into a diamond — which is what the first run of
        // `curvesAreFlattenedNotDropped` actually did — so the children are indexed here and
        // walked in emission order to rebuild the outline.
        var children: [UInt64: [VectorPrimitive]] = [:]
        for primitive in primitives {
            guard let parent = primitive.parentID else { continue }
            children[parent, default: []].append(primitive)
        }
        for key in children.keys {
            children[key]?.sort { ($0.subpathIndex, $0.id) < ($1.subpathIndex, $1.id) }
        }

        /// The outline of a shape, following its children when it has curves in it.
        func outline(of primitive: VectorPrimitive, ring: VectorRing) -> [PDFPoint] {
            guard ring.containsCurves, let parts = children[primitive.id], !parts.isEmpty else {
                return ring.vertices.map(unit)
            }
            var points: [PDFPoint] = []
            func append(_ point: PDFPoint) {
                if let last = points.last,
                   abs(last.x - point.x) < 1e-12, abs(last.y - point.y) < 1e-12 { return }
                points.append(point)
            }
            for part in parts {
                switch part.geometry {
                case let .line(line):
                    append(unit(line.start))
                    append(unit(line.end))
                case let .cubic(cubic):
                    for step in 0...curveSampleCount {
                        append(unit(cubic.point(at: Double(step) / Double(curveSampleCount))))
                    }
                case let .rectangle(quad):
                    for corner in quad.corners { append(unit(corner)) }
                case let .ring(inner):
                    for vertex in inner.vertices { append(unit(vertex)) }
                }
            }
            return points.count >= 3 ? points : ring.vertices.map(unit)
        }

        var strokes: [ArtworkContour] = []
        var regions: [ArtworkRegion] = []

        // Fill colour (BH-167; the extractor now records ink).
        //
        // - An opaque-white fill painted before any ink is the sheet's paper, not the seal:
        //   dropped. Imported as a region it would draw a stamp-coloured slab over the drawing.
        // - An opaque-white fill painted *over* ink is a knockout: kept, in white, so the hole
        //   it cuts stays a hole instead of filling with the stamp's colour.
        // - Every other fill keeps the single-ink behaviour of ADR-0011 §2.4 — no own colour,
        //   so the seal recolours with the stamp's style — unless the page genuinely carries
        //   more than one ink, when each region keeps the colour it was painted in.
        //   A single-ink seal still looks as drawn by default: its ink is reported beside the
        //   geometry (`sourceInk(of:)`) and becomes the stamp's colour on import, so fills and
        //   strokes — which carry no colour in the contract — stay one colour together.
        let inkColors = Set(primitives.compactMap { primitive -> VectorColor? in
            guard primitive.paint.contains(.filled), let color = primitive.fillColor,
                  !color.isOpaqueWhite else { return nil }
            return color
        })
        let isMultiInk = inkColors.count > 1
        var inkSeen = false
        func regionColor(_ primitive: VectorPrimitive) -> RGBAColor?? {
            guard let color = primitive.fillColor else { return .some(nil) }
            if color.isOpaqueWhite {
                return inkSeen ? .some(RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)) : .none
            }
            guard isMultiInk else { return .some(nil) }
            return .some(RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
        }

        for primitive in primitives {
            let isFilled = primitive.paint.contains(.filled)
            let isStroked = primitive.paint.contains(.stroked)
            guard isFilled || isStroked else { continue }
            // `.none` — a paper-white background, not ink: nothing to import for the fill.
            let fill: RGBAColor?? = isFilled ? regionColor(primitive) : .none
            defer {
                if isStroked || (isFilled && primitive.fillColor?.isOpaqueWhite != true) { inkSeen = true }
            }

            switch primitive.geometry {
            case let .rectangle(quad):
                let corners = quad.corners.map(unit)
                if case let .some(color) = fill { regions.append(ArtworkRegion(outer: corners, color: color)) }
                if isStroked {
                    strokes.append(ArtworkContour(
                        points: corners,
                        isClosed: true,
                        widthFraction: widthFraction(primitive.strokeWidth)
                    ))
                }
            case let .ring(ring):
                let vertices = outline(of: primitive, ring: ring)
                guard vertices.count >= 2 else { continue }
                if case let .some(color) = fill { regions.append(ArtworkRegion(outer: vertices, color: color)) }
                if isStroked {
                    strokes.append(ArtworkContour(
                        points: vertices,
                        isClosed: ring.isClosed,
                        widthFraction: widthFraction(primitive.strokeWidth)
                    ))
                }
            case let .line(line):
                // A leaf inside a shape is already drawn by the shape.
                guard primitive.parentID == nil, isStroked else { continue }
                strokes.append(ArtworkContour(
                    points: [unit(line.start), unit(line.end)],
                    isClosed: false,
                    widthFraction: widthFraction(primitive.strokeWidth)
                ))
            case let .cubic(cubic):
                guard primitive.parentID == nil, isStroked else { continue }
                let samples = (0...curveSampleCount).map {
                    unit(cubic.point(at: Double($0) / Double(curveSampleCount)))
                }
                strokes.append(ArtworkContour(
                    points: samples,
                    isClosed: false,
                    widthFraction: widthFraction(primitive.strokeWidth)
                ))
            }
        }

        let artwork = ArtworkGeometry(
            kind: .vector,
            strokes: strokes,
            regions: regions,
            sourceAspectRatio: box.width / box.height
        )
        if artwork.isEmpty { throw ArtworkImportRefusal.empty }
        if let violation = artwork.limitViolation() { throw violation }
        return CompiledPage(geometry: artwork, sourceInk: sourceInk(of: primitives))
    }

    // MARK: - Image

    /// A compiled raster, with the pixel count the editor's warning is derived from.
    struct CompiledRaster: Sendable {
        let geometry: ArtworkGeometry
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Compiles an image into a bounded cell mosaic.
    ///
    /// The mosaic is geometry, so both renderer backends draw it with the shapes they already
    /// have — no texture, no atlas, no second golden pipeline. Its cost is a property of
    /// ``ArtworkLimits/maximumRasterSampleEdge`` and **not** of the imported file, so a 40-megapixel
    /// scan and a 200-pixel icon cost the same to place 312 times.
    ///
    /// The degradation this produces is deliberate and visible: magnify a raster stamp and its
    /// sample cells grow, in a grid whose size was fixed at import. That is a better answer
    /// than a soft blur whose cause the estimator has to guess at, and the preset editor's
    /// warning says which stamps it applies to.
    static func compileImage(bytes: Data) throws -> CompiledRaster {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw ArtworkImportRefusal.unreadableSource }

        // Read the declared size from metadata and refuse before decoding: a decode bomb that
        // is measured after it is decoded has already won.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let declaredWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let declaredHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            declaredWidth > 0, declaredHeight > 0
        else { throw ArtworkImportRefusal.unreadableSource }

        let declaredPixels = declaredWidth.multipliedReportingOverflow(by: declaredHeight)
        guard !declaredPixels.overflow,
              declaredPixels.partialValue <= ArtworkLimits.maximumRasterPixels
        else {
            throw ArtworkImportRefusal.rasterTooLarge(
                pixels: declaredPixels.overflow ? Int.max : declaredPixels.partialValue,
                limit: ArtworkLimits.maximumRasterPixels
            )
        }

        // Decode straight to the mosaic's resolution. ImageIO downsamples during decode, so
        // the full-size bitmap is never allocated even for a legal but very large image.
        let edge = ArtworkLimits.maximumRasterSampleEdge
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { throw ArtworkImportRefusal.unreadableSource }

        let columns = Swift.max(1, Swift.min(edge, image.width))
        let rows = Swift.max(1, Swift.min(edge, image.height))
        let samples = try sampleRGBA(image, columns: columns, rows: rows)
        let regions = mosaic(samples: samples, columns: columns, rows: rows)
        guard !regions.isEmpty else { throw ArtworkImportRefusal.empty }

        // The thumbnail above applies the EXIF orientation, so the mosaic is built in the
        // *displayed* orientation. The declared pixel size is the *stored* one; for the four
        // orientations that turn the picture a quarter (5-8) the two disagree, and reporting
        // the stored size squashes a portrait phone photo into a landscape box (BH-168).
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let quarterTurn = (5...8).contains(orientation)
        let displayedWidth = quarterTurn ? declaredHeight : declaredWidth
        let displayedHeight = quarterTurn ? declaredWidth : declaredHeight

        let artwork = ArtworkGeometry(
            kind: .raster,
            strokes: [],
            regions: regions,
            sourceAspectRatio: Double(displayedWidth) / Double(displayedHeight)
        )
        if let violation = artwork.limitViolation() { throw violation }
        return CompiledRaster(
            geometry: artwork, pixelWidth: displayedWidth, pixelHeight: displayedHeight
        )
    }

    /// Draws the image into a `columns x rows` premultiplied RGBA buffer and reads it back.
    ///
    /// Row 0 of the returned buffer is the **top** row of the picture, which is how a
    /// `CGBitmapContext`'s memory is laid out. The mosaic flips it into PDF's bottom-left
    /// unit space, and `rasterMosaicKeepsItsOrientation` is the test that says so rather than
    /// this comment being the only thing that does.
    static func sampleRGBA(_ image: CGImage, columns: Int, rows: Int) throws -> [UInt8] {
        let bytesPerRow = columns * 4
        var storage = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let drawn: Bool = storage.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: base,
                    width: columns,
                    height: rows,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { throw ArtworkImportRefusal.unreadableSource }
        return storage
    }

    /// Builds the mosaic: transparent cells dropped, colour quantised, horizontally adjacent
    /// cells of equal colour merged into one run.
    ///
    /// Run merging is what keeps the primitive count sane on real artwork — a seal is mostly
    /// flat regions — without making the cost depend on the imported file.
    static func mosaic(samples: [UInt8], columns: Int, rows: Int) -> [ArtworkRegion] {
        guard columns > 0, rows > 0, samples.count >= columns * rows * 4 else { return [] }
        let cellWidth = 1.0 / Double(columns)
        let cellHeight = 1.0 / Double(rows)
        var regions: [ArtworkRegion] = []
        regions.reserveCapacity(columns)

        for row in 0..<rows {
            // Memory row 0 is the top of the picture; unit space has its origin at the bottom.
            let top = 1.0 - Double(row) * cellHeight
            let bottom = top - cellHeight
            var runStart = 0
            var runKey: UInt32? = nil

            func flush(end: Int) {
                guard let key = runKey, end > runStart else { return }
                // Cells overlap their neighbours by ``ArtworkLimits/rasterCellBleed``, so the
                // pixel on a shared edge is fully covered rather than half-covered twice.
                // Without it every cell boundary carries a hairline seam, and the two renderer
                // backends draw that seam differently.
                // The overlap is *interior only*: the artwork's silhouette stays exactly where
                // the image's edge was, and the compiled geometry stays inside the unit box.
                let bleedX = cellWidth * ArtworkLimits.rasterCellBleed
                let bleedY = cellHeight * ArtworkLimits.rasterCellBleed
                let left = Swift.max(0, Double(runStart) * cellWidth - bleedX)
                let right = Swift.min(1, Double(end) * cellWidth + bleedX)
                let low = Swift.max(0, bottom - bleedY)
                let high = Swift.min(1, top + bleedY)
                regions.append(ArtworkRegion(
                    outer: [
                        PDFPoint(x: left, y: low), PDFPoint(x: right, y: low),
                        PDFPoint(x: right, y: high), PDFPoint(x: left, y: high)
                    ],
                    color: color(from: key)
                ))
            }

            for column in 0..<columns {
                let offset = (row * columns + column) * 4
                let alpha = samples[offset + 3]
                // The sample buffer is `premultipliedLast`; the stored channels are colour×α.
                // Quantising them as if straight renders a 50%-alpha seal edge at a quarter of
                // its colour — a dark halo on every antialiased edge (CR-78). Un-premultiply
                // back to straight colour before quantising.
                let key: UInt32? = alpha < 8 ? nil : quantised(
                    red: Self.unpremultiply(samples[offset], alpha: alpha),
                    green: Self.unpremultiply(samples[offset + 1], alpha: alpha),
                    blue: Self.unpremultiply(samples[offset + 2], alpha: alpha),
                    alpha: alpha
                )
                if key != runKey {
                    flush(end: column)
                    runKey = key
                    runStart = column
                }
            }
            flush(end: columns)
        }
        return regions
    }

    /// Recovers a straight-alpha colour component from a premultiplied one: `straight = premul /
    /// α`, rounded and clamped. `α == 0` is fully transparent and has no colour (CR-78).
    static func unpremultiply(_ component: UInt8, alpha: UInt8) -> UInt8 {
        guard alpha > 0 else { return 0 }
        let straight = (Int(component) * 255 + Int(alpha) / 2) / Int(alpha)
        return UInt8(Swift.min(255, straight))
    }

    /// Five bits per channel, so near-identical neighbours merge into one run instead of
    /// producing one primitive per pixel of a gradient.
    static func quantised(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> UInt32 {
        (UInt32(red >> 3) << 15) | (UInt32(green >> 3) << 10)
            | (UInt32(blue >> 3) << 5) | UInt32(alpha >> 3)
    }

    /// The inverse of ``quantised(red:green:blue:alpha:)``, expanded back to the top of each
    /// bucket's range so a full-white pixel stays full white.
    static func color(from key: UInt32) -> RGBAColor {
        func expand(_ value: UInt32) -> Double {
            Double((value << 3) | (value >> 2)) / 255.0
        }
        return RGBAColor(
            red: expand((key >> 15) & 0x1F),
            green: expand((key >> 10) & 0x1F),
            blue: expand((key >> 5) & 0x1F),
            alpha: expand(key & 0x1F)
        )
    }
}
