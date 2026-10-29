import Foundation

/// Fixtures that exercise page boxes, `/Rotate` and page counts rather than shapes.
enum PageGeometryFixtures {

    // MARK: - Rotation

    /// An asymmetric marker, so that a rotation applied in the wrong direction is
    /// visible rather than self-cancelling.
    static let rotationMarker: [FixturePoint] = [
        FixturePoint(72, 72),
        FixturePoint(72, 672),
        FixturePoint(172, 672)
    ]

    static func rotation(_ degrees: Int) throws -> FixtureBuild {
        let kind: FixtureKind
        switch degrees {
        case 0: kind = .rotation0
        case 90: kind = .rotation90
        case 180: kind = .rotation180
        case 270: kind = .rotation270
        default:
            // Any other angle would be filed under a kind whose name contradicts the
            // /Rotate the page carries.
            throw FixtureError.generationFailed(
                kind: .rotation270,
                reason: "rotation fixtures exist for 0, 90, 180 and 270 degrees, not \(degrees)"
            )
        }

        let path = FixturePath(
            id: "rotation-marker",
            pageIndex: 0,
            kind: .openPolyline,
            points: rotationMarker,
            length: 600 + 100,
            area: 0,
            derivation: .closedForm(
                "Two axis-aligned segments: (72,72)->(72,672) is 672-72 = 600, "
                    + "(72,672)->(172,672) is 172-72 = 100. Total 700.",
                magnitudeFloor: 700
            ),
            notes: [
                "These are page-space coordinates *before* /Rotate is applied. /Rotate is a "
                    + "presentation instruction: it does not move the content, it rotates the "
                    + "rendered page clockwise by \(degrees) degrees for display."
            ]
        )

        let manifest = FixtureManifest(
            kind: kind,
            title: "Single Letter page with /Rotate \(degrees)",
            purpose: "Coordinate conversion must honour /Rotate without moving page-space "
                + "geometry.",
            fileName: kind.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: FixturePageSize.letter, rotation: degrees)],
            paths: [path],
            notes: [
                "The page dictionary carries an explicit /Rotate \(degrees) entry, even for 0, so a "
                    + "reader's handling of the key itself is exercised rather than the inherited default."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: kind)
            var content = PDFContentStream()
            content.setLineWidth(2)
            content.setStrokeGray(0)
            content.appendRing(rotationMarker, close: false)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(
                mediaBox: FixturePageSize.letter,
                rotation: degrees,
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Crop boxes

    static let cropSmallerMedia = FixturePageSize.letter
    static let cropSmallerCrop = FixtureRect(llx: 72, lly: 72, urx: 540, ury: 720)
    static let cropSmallerRect = FixtureRect(x: 100, y: 100, width: 200, height: 150)

    static func cropBoxSmallerThanMediaBox() throws -> FixtureBuild {
        let path = FixturePath(
            id: "crop-marker",
            pageIndex: 0,
            kind: .closedPolygon,
            points: cropSmallerRect.counterClockwiseCorners,
            length: 2 * (200 + 150),
            area: 200 * 150,
            derivation: .closedForm(
                "Rectangle 200 x 150 at (100, 100): area 30000, perimeter 700. "
                    + "Its coordinates are in media-box space; a converter that silently rebases "
                    + "on the crop box reports (28, 28) for the lower-left corner instead.",
                conditionNumber: 2.1666666666666665,
                magnitudeFloor: 30_000
            )
        )

        let manifest = FixtureManifest(
            kind: .cropBoxSmallerThanMediaBox,
            title: "Crop box strictly inside the media box",
            purpose: "The crop box, not the media box, defines the visible page; page space is "
                + "still measured from the media box origin unless the contract says otherwise.",
            fileName: FixtureKind.cropBoxSmallerThanMediaBox.fileName,
            pageCount: 1,
            pages: [
                FixturePage(index: 0, mediaBox: cropSmallerMedia, cropBox: cropSmallerCrop)
            ],
            paths: [path],
            notes: [
                "MediaBox [0 0 612 792], CropBox [72 72 540 720] — 468 x 648 visible."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            try simpleRectangleDocument(
                kind: .cropBoxSmallerThanMediaBox,
                mediaBox: cropSmallerMedia,
                cropBox: cropSmallerCrop,
                rect: cropSmallerRect
            )
        }
    }

    static let negativeMedia = FixtureRect(llx: -100, lly: -50, urx: 512, ury: 742)
    static let negativeCrop = FixtureRect(llx: -50, lly: -25, urx: 250, ury: 375)
    static let negativeLineStart = FixturePoint(-100, -50)
    static let negativeLineEnd = FixturePoint(140, 270)

    static func cropBoxNegativeOrigin() throws -> FixtureBuild {
        let path = FixturePath(
            id: "negative-origin-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [negativeLineStart, negativeLineEnd],
            length: 400,
            area: 0,
            derivation: .closedForm(
                "sqrt((140 - -100)^2 + (270 - -50)^2) = sqrt(240^2 + 320^2) = "
                    + "sqrt(57600 + 102400) = sqrt(160000) = 400. A 3-4-5 triple scaled by 80.",
                magnitudeFloor: 400
            )
        )

        let manifest = FixtureManifest(
            kind: .cropBoxNegativeOrigin,
            title: "Media and crop boxes with a negative lower-left corner",
            purpose: "Nothing may assume a box origin at (0, 0). The line starts exactly on the "
                + "media box corner, at (-100, -50).",
            fileName: FixtureKind.cropBoxNegativeOrigin.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: negativeMedia, cropBox: negativeCrop)],
            paths: [path],
            notes: [
                "MediaBox [-100 -50 512 742] — 612 x 792.",
                "CropBox [-50 -25 250 375] — 300 x 400."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .cropBoxNegativeOrigin)
            var content = PDFContentStream()
            content.setLineWidth(2)
            content.setStrokeGray(0)
            content.move(to: negativeLineStart)
            content.line(to: negativeLineEnd)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(
                mediaBox: negativeMedia,
                cropBox: negativeCrop,
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Sheet sizes

    /// Inset used by every sheet fixture, so a page's marker is derived from its own
    /// box rather than from a hard-coded rectangle.
    static let sheetInset: Double = 36

    static func insetRect(in box: FixtureRect) -> FixtureRect {
        FixtureRect(
            llx: box.llx + sheetInset,
            lly: box.lly + sheetInset,
            urx: box.urx - sheetInset,
            ury: box.ury - sheetInset
        )
    }

    private static func sheetPath(
        id: String,
        pageIndex: Int,
        box: FixtureRect,
        label: String
    ) -> FixturePath {
        let inset = insetRect(in: box)
        let width = box.width - 2 * sheetInset
        let height = box.height - 2 * sheetInset
        return FixturePath(
            id: id,
            pageIndex: pageIndex,
            kind: .closedPolygon,
            points: inset.counterClockwiseCorners,
            length: 2 * (width + height),
            area: width * height,
            derivation: .closedForm(
                "\(label): media box \(PDFNumber.string(box.width)) x "
                    + "\(PDFNumber.string(box.height)) pt, border inset 36 pt on every side. "
                    + "Border rectangle is (w - 72) x (h - 72) = "
                    + "\(PDFNumber.string(width)) x \(PDFNumber.string(height)); "
                    + "area = (w-72)*(h-72), perimeter = 2*((w-72)+(h-72)).",
                conditionNumber: shoelaceConditionNumber(inset.counterClockwiseCorners),
                magnitudeFloor: width * height
            )
        )
    }

    /// κ = Σ|xᵢyᵢ₊₁ − xᵢ₊₁yᵢ| / |Σ(xᵢyᵢ₊₁ − xᵢ₊₁yᵢ)| for one closed ring, the definition
    /// the corpus records for every area (QUALITY_BAR 2.6, bound M-A3).
    static func shoelaceConditionNumber(_ ring: [FixturePoint]) -> Double {
        guard ring.count >= 3 else { return .infinity }
        var signed = 0.0
        var absolute = 0.0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let term = a.x * b.y - b.x * a.y
            signed += term
            absolute += abs(term)
        }
        return absolute / abs(signed)
    }

    /// Left and right margin around the 1000-point scale bar of `singleSheet`.
    static let scaleBarMargin: Double = 100

    static func singleSheet(_ kind: FixtureKind, box: FixtureRect, label: String) throws -> FixtureBuild {
        // The bar runs from llx + 100 to llx + 1100; a narrower sheet would record
        // geometry outside its own media box.
        guard box.width >= 1000 + 2 * scaleBarMargin else {
            throw FixtureError.generationFailed(
                kind: kind,
                reason: "sheet is \(PDFNumber.string(box.width)) pt wide; the 1000 pt scale bar "
                    + "needs at least \(PDFNumber.string(1000 + 2 * scaleBarMargin)) pt"
            )
        }
        let border = sheetPath(id: "border", pageIndex: 0, box: box, label: label)
        // A scale bar of exactly 1000 points, so a calibration test has an exact
        // reference length on a realistically sized sheet.
        let barStart = FixturePoint(box.llx + 100, box.lly + 100)
        let barEnd = FixturePoint(box.llx + 1100, box.lly + 100)
        let bar = FixturePath(
            id: "scale-bar",
            pageIndex: 0,
            kind: .openPolyline,
            points: [barStart, barEnd],
            length: 1000,
            area: 0,
            derivation: .closedForm(
                "Horizontal bar from x = llx + 100 to x = llx + 1100 at y = lly + 100: "
                    + "length exactly 1100 - 100 = 1000 points.",
                magnitudeFloor: 1000
            )
        )

        let manifest = FixtureManifest(
            kind: kind,
            title: label,
            purpose: "A construction-sized sheet, so page-box handling is exercised at the "
                + "dimensions Zenit actually meets in the field.",
            fileName: kind.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: box)],
            paths: [border, bar],
            notes: [
                "Media box: \(PDFNumber.array(box)).",
                "The scale bar is exactly 1000 points long."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: kind)
            var content = PDFContentStream()
            content.setLineWidth(2)
            content.setStrokeGray(0)
            content.appendRing(insetRect(in: box).counterClockwiseCorners, close: true)
            content.stroke()
            content.setLineWidth(4)
            content.move(to: barStart)
            content.line(to: barEnd)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: box, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Mixed page sizes

    static let mixedBoxes: [(FixtureRect, String)] = [
        (FixturePageSize.letter, "US Letter 612 x 792"),
        (FixturePageSize.a4, "ISO A4 210 x 297 mm"),
        (FixturePageSize.a1, "ISO A1 594 x 841 mm"),
        (FixturePageSize.archD, "ARCH D 24 x 36 in")
    ]

    static func mixedPageSizes() throws -> FixtureBuild {
        var pages: [FixturePage] = []
        var paths: [FixturePath] = []
        for (index, entry) in mixedBoxes.enumerated() {
            pages.append(FixturePage(index: index, mediaBox: entry.0))
            paths.append(sheetPath(id: "border-\(index)", pageIndex: index, box: entry.0, label: entry.1))
        }

        let manifest = FixtureManifest(
            kind: .mixedPageSizes,
            title: "Four pages, four different sheet sizes",
            purpose: "Per-page geometry must be resolved per page. A reader that caches the "
                + "first page's box reports the wrong size for pages 2 to 4.",
            fileName: FixtureKind.mixedPageSizes.fileName,
            pageCount: mixedBoxes.count,
            pages: pages,
            paths: paths,
            notes: mixedBoxes.enumerated().map { "Page \($0.offset): \($0.element.1)." }
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .mixedPageSizes)
            for entry in mixedBoxes {
                var content = PDFContentStream()
                content.setLineWidth(2)
                content.setStrokeGray(0)
                content.appendRing(insetRect(in: entry.0).counterClockwiseCorners, close: true)
                content.stroke()
                let contents = try builder.addContentStream(content)
                builder.addPage(mediaBox: entry.0, contentObject: contents)
            }
            return try builder.data()
        }
    }

    // MARK: - Many pages

    /// Marker line drawn on every page of the large-page-count fixtures.
    static let manyPagesLineStart = FixturePoint(72, 72)
    static let manyPagesLineEnd = FixturePoint(172, 72)

    /// Builds the 300- and 1 000-page fixtures.
    ///
    /// The bytes are produced by a `RawPDFWriter` whose object provider builds one
    /// object at a time, so the streaming path never holds more than a single page's
    /// content in memory regardless of page count.
    static func manyPages(_ kind: FixtureKind, pageCount: Int) throws -> FixtureBuild {
        guard pageCount >= 1, pageCount <= 2_000 else {
            throw FixtureError.generationFailed(kind: kind, reason: "page count \(pageCount) out of range")
        }

        let box = FixturePageSize.letter
        var pages: [FixturePage] = []
        var paths: [FixturePath] = []
        var texts: [FixtureText] = []
        pages.reserveCapacity(pageCount)
        paths.reserveCapacity(pageCount)
        texts.reserveCapacity(pageCount)

        let lengthDerivation = FixtureDerivation.closedForm(
            "Horizontal marker from (72, 72) to (172, 72) on every page: length 172 - 72 = 100.",
            magnitudeFloor: 100
        )
        for index in 0..<pageCount {
            pages.append(FixturePage(index: index, mediaBox: box, hasTextLayer: true))
            paths.append(
                FixturePath(
                    id: "marker-\(index)",
                    pageIndex: index,
                    kind: .openPolyline,
                    points: [manyPagesLineStart, manyPagesLineEnd],
                    length: 100,
                    area: 0,
                    derivation: lengthDerivation
                )
            )
            texts.append(
                FixtureText(
                    id: "page-number-\(index)",
                    pageIndex: index,
                    string: "PAGE \(index + 1) OF \(pageCount)",
                    origin: FixturePoint(72, 40),
                    fontSize: 10,
                    fontName: "Helvetica"
                )
            )
        }

        let manifest = FixtureManifest(
            kind: kind,
            title: "\(pageCount) uniform Letter pages",
            purpose: "Page-tree traversal, page-count reporting and lazy page loading at a scale "
                + "where eager loading is measurably wrong.",
            fileName: kind.fileName,
            pageCount: pageCount,
            pages: pages,
            paths: paths,
            texts: texts,
            notes: [
                "Every page carries the searchable string \"PAGE n OF \(pageCount)\" at (72, 40), "
                    + "so a page-label test has a per-page ground truth.",
                "Written page by page: peak generator memory is one page, not one document."
            ]
        )

        let layout = ManyPagesLayout(kind: kind, pageCount: pageCount, box: box)
        return FixtureBuild(
            manifest: manifest,
            makeData: { try layout.writer().data() },
            streamTo: { handle, path in try layout.writer().write(to: handle, path: path) }
        )
    }

    /// Object layout for the large-page-count fixtures.
    ///
    /// Objects are laid out so that page `i` and its content stream can be produced on
    /// demand from `i` alone:
    ///
    ///   1                catalogue
    ///   2                page tree
    ///   3                Helvetica
    ///   4                info
    ///   5 + 2i           page i
    ///   6 + 2i           content stream for page i
    private struct ManyPagesLayout {
        let kind: FixtureKind
        let pageCount: Int
        let box: FixtureRect

        var catalogNumber: Int { 1 }
        var pagesNumber: Int { 2 }
        var fontNumber: Int { 3 }
        var infoNumber: Int { 4 }
        func pageNumber(_ index: Int) -> Int { 5 + 2 * index }
        func contentNumber(_ index: Int) -> Int { 6 + 2 * index }
        var objectCount: Int { 4 + 2 * pageCount }

        func writer() -> RawPDFWriter {
            RawPDFWriter(
                kind: kind,
                objectCount: objectCount,
                rootObject: catalogNumber,
                infoObject: infoNumber,
                body: body
            )
        }

        private func body(_ number: Int) throws -> PDFObjectBody? {
            switch number {
            case catalogNumber:
                return .verbatim("<< /Type /Catalog /Pages \(pagesNumber) 0 R >>")
            case pagesNumber:
                var kids = "["
                kids.reserveCapacity(pageCount * 10)
                for index in 0..<pageCount {
                    if index > 0 { kids += " " }
                    kids += "\(pageNumber(index)) 0 R"
                }
                kids += "]"
                return .verbatim("<< /Type /Pages /Kids \(kids) /Count \(pageCount) >>")
            case fontNumber:
                return .verbatim(
                    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
                )
            case infoNumber:
                return .verbatim(
                    "<< /Producer (ZPDFTestingSupport) /Title (\(kind.rawValue)) "
                        + "/CreationDate (D:20260101000000Z) /ModDate (D:20260101000000Z) >>"
                )
            default:
                let offset = number - 5
                guard offset >= 0, offset < 2 * pageCount else {
                    throw FixtureError.generationFailed(kind: kind, reason: "object \(number) out of range")
                }
                let index = offset / 2
                if offset % 2 == 0 { return try pageObject(index) }
                return try contentObject(index)
            }
        }

        private func pageObject(_ index: Int) throws -> PDFObjectBody {
            .verbatim(
                "<< /Type /Page /Parent \(pagesNumber) 0 R /MediaBox \(PDFNumber.array(box)) "
                    + "/Resources << /Font << /F1 \(fontNumber) 0 R >> >> "
                    + "/Contents \(contentNumber(index)) 0 R >>"
            )
        }

        private func contentObject(_ index: Int) throws -> PDFObjectBody {
            var content = PDFContentStream()
            content.setLineWidth(1)
            content.setStrokeGray(0)
            content.move(to: manyPagesLineStart)
            content.line(to: manyPagesLineEnd)
            content.stroke()
            let label = try PDFSyntax.literalString("PAGE \(index + 1) OF \(pageCount)", kind: kind)
            content.showText(label, font: "F1", size: 10, at: FixturePoint(72, 40))
            return .stream(dictionaryEntries: "", data: try content.data(kind: kind))
        }
    }

    // MARK: - Helpers

    private static func simpleRectangleDocument(
        kind: FixtureKind,
        mediaBox: FixtureRect,
        cropBox: FixtureRect?,
        rect: FixtureRect
    ) throws -> Data {
        let builder = PDFDocumentBuilder(kind: kind)
        var content = PDFContentStream()
        content.setLineWidth(2)
        content.setStrokeGray(0)
        content.appendRing(rect.counterClockwiseCorners, close: true)
        content.stroke()
        let contents = try builder.addContentStream(content)
        builder.addPage(mediaBox: mediaBox, cropBox: cropBox, contentObject: contents)
        return try builder.data()
    }
}
