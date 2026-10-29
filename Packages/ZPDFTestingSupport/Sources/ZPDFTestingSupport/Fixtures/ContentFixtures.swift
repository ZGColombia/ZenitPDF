import Foundation

/// Fixtures whose subject is page *content*: a real drawing sheet with searchable
/// text, a page that only looks like a drawing because it is a bitmap, and one that
/// mixes the two.
enum ContentFixtures {

    // MARK: - Title-block drawing sheet

    /// ARCH D, so the sheet is a plausible construction drawing and the numbers stay
    /// exact (24 × 36 in is exactly 1728 × 2592 pt).
    static let sheetBox = FixturePageSize.archD
    static let borderRect = FixtureRect(llx: 36, lly: 36, urx: 1692, ury: 2556)
    static let titleBlockRect = FixtureRect(llx: 1128, lly: 36, urx: 1692, ury: 288)
    static let room101Rect = FixtureRect(x: 144, y: 1728, width: 720, height: 576)
    static let room102Rect = FixtureRect(x: 864, y: 1728, width: 720, height: 576)

    /// Every string on the sheet, with its exact baseline origin.
    static let sheetStrings: [(id: String, text: String, origin: FixturePoint, size: Double, titleBlock: Bool)] = [
        ("title", "ZENIT PDF FIXTURE SHEET", FixturePoint(1152, 240), 18, true),
        ("drawing-number", "DRAWING NO ZP-0001", FixturePoint(1152, 204), 12, true),
        ("scale", "SCALE 1:50", FixturePoint(1152, 168), 12, true),
        ("revision", "REVISION A", FixturePoint(1152, 132), 12, true),
        ("date", "DATE 2026-01-01", FixturePoint(1152, 96), 12, true),
        ("room-101", "ROOM 101", FixturePoint(200, 2000), 14, false),
        ("room-102", "ROOM 102", FixturePoint(920, 2000), 14, false),
        ("corridor", "CORRIDOR", FixturePoint(200, 1600), 14, false),
        ("grid", "GRID A1", FixturePoint(120, 120), 10, false)
    ]

    static func titleBlockSheet() throws -> FixtureBuild {
        let border = FixturePath(
            id: "border",
            pageIndex: 0,
            kind: .closedPolygon,
            points: borderRect.counterClockwiseCorners,
            length: 2 * (1656 + 2520),
            area: 1656 * 2520,
            derivation: .closedForm(
                "Sheet border [36 36 1692 2556]: 1656 x 2520. Area = 1656*2520 = 4173120, "
                    + "perimeter = 2*(1656+2520) = 8352.",
                conditionNumber: 1.036024844720497,
                magnitudeFloor: 4_173_120
            )
        )
        let titleBlock = FixturePath(
            id: "title-block",
            pageIndex: 0,
            kind: .closedPolygon,
            points: titleBlockRect.counterClockwiseCorners,
            length: 2 * (564 + 252),
            area: 564 * 252,
            derivation: .closedForm(
                "Title block [1128 36 1692 288]: 564 x 252. Area = 564*252 = 142128, "
                    + "perimeter = 2*(564+252) = 1632.",
                conditionNumber: 3.142857142857143,
                magnitudeFloor: 142_128
            )
        )
        // The two rooms are congruent, but the shoelace condition number depends on how
        // far the polygon sits from the origin, so each carries its own kappa.
        let room101 = FixturePath(
            id: "room-101-outline",
            pageIndex: 0,
            kind: .closedPolygon,
            points: room101Rect.counterClockwiseCorners,
            length: 2 * (720 + 576),
            area: 720 * 576,
            derivation: .closedForm(
                "Room rectangle 720 x 576 at (144, 1728). Area = 720*576 = 414720, "
                    + "perimeter = 2*(720+576) = 2592.",
                conditionNumber: 4.2,
                magnitudeFloor: 414_720
            )
        )
        let room102 = FixturePath(
            id: "room-102-outline",
            pageIndex: 0,
            kind: .closedPolygon,
            points: room102Rect.counterClockwiseCorners,
            length: 2 * (720 + 576),
            area: 720 * 576,
            derivation: .closedForm(
                "Room rectangle 720 x 576 at (864, 1728). Area = 720*576 = 414720, "
                    + "perimeter = 2*(720+576) = 2592. Congruent to room 101 but further from "
                    + "the origin, so its shoelace condition number is 5.2 rather than 4.2.",
                conditionNumber: 5.2,
                magnitudeFloor: 414_720
            )
        )

        let texts = sheetStrings.map {
            FixtureText(
                id: $0.id,
                pageIndex: 0,
                string: $0.text,
                origin: $0.origin,
                fontSize: $0.size,
                fontName: "Helvetica",
                isTitleBlock: $0.titleBlock
            )
        }

        let manifest = FixtureManifest(
            kind: .titleBlockSheet,
            title: "ARCH D drawing sheet with a title block",
            purpose: "Text extraction and search: nine strings at exactly known baseline origins, "
                + "five of them inside the title block, plus four measurable rectangles.",
            fileName: FixtureKind.titleBlockSheet.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: sheetBox, hasTextLayer: true)],
            paths: [border, titleBlock, room101, room102],
            texts: texts,
            notes: [
                "All text is Helvetica with WinAnsiEncoding and is placed with an explicit "
                    + "text matrix `1 0 0 1 x y Tm`, so the recorded origin is the exact baseline "
                    + "origin of the first glyph.",
                "The two room rectangles are identical in size and differ only in position, so a "
                    + "search result must be disambiguated by coordinate, not by area."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .titleBlockSheet)
            let font = try builder.addBase14Font(baseFont: "Helvetica")
            var content = PDFContentStream()
            content.setLineWidth(2)
            content.setStrokeGray(0)
            for rect in [borderRect, titleBlockRect, room101Rect, room102Rect] {
                content.appendRing(rect.counterClockwiseCorners, close: true)
                content.stroke()
            }
            content.setFillGray(0)
            for entry in sheetStrings {
                let literal = try PDFSyntax.literalString(entry.text, kind: .titleBlockSheet)
                content.showText(literal, font: "F1", size: entry.size, at: entry.origin)
            }
            let contents = try builder.addContentStream(content)
            builder.addPage(
                mediaBox: sheetBox,
                resources: "<< /Font << /F1 \(font) 0 R >> >>",
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Scanned-look page

    static let scannedBox = FixturePageSize.letter
    static let scannedPixelWidth = 612
    static let scannedPixelHeight = 792

    static func scannedLookPage() throws -> FixtureBuild {
        let raster = FixtureRaster(
            id: "scan",
            pageIndex: 0,
            placement: scannedBox,
            pixelWidth: scannedPixelWidth,
            pixelHeight: scannedPixelHeight,
            bitsPerComponent: 8,
            colorSpace: "DeviceGray"
        )

        let manifest = FixtureManifest(
            kind: .scannedLookPage,
            title: "Rasterised page with no text layer",
            purpose: "The OCR path and the \"Vector Snap unavailable\" path. Text extraction must "
                + "return nothing at all, and vector extraction must return no paths.",
            fileName: FixtureKind.scannedLookPage.fileName,
            pageCount: 1,
            pages: [
                FixturePage(
                    index: 0,
                    mediaBox: scannedBox,
                    hasTextLayer: false,
                    hasRasterContent: true
                )
            ],
            rasters: [raster],
            notes: [
                "One 612 x 792 DeviceGray image at 1 sample per point, filling the media box.",
                "The page dictionary has no /Font resource at all, so there is nothing for a "
                    + "text extractor to find even by accident.",
                "The image is generated by a fixed linear-congruential rule, so the bytes are "
                    + "identical on every run and on every machine."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .scannedLookPage)
            let samples = RasterPattern.scannedTextPage(
                width: scannedPixelWidth,
                height: scannedPixelHeight,
                seed: 0x5A45_4E49
            )
            let image = try addGrayImage(
                builder: builder,
                kind: .scannedLookPage,
                samples: samples,
                width: scannedPixelWidth,
                height: scannedPixelHeight
            )
            var content = PDFContentStream()
            content.saveState()
            // An image XObject draws into the unit square, so the CTM is the placement.
            content.concat(
                FixtureMatrix(
                    a: scannedBox.width, b: 0, c: 0, d: scannedBox.height,
                    e: scannedBox.llx, f: scannedBox.lly
                )
            )
            content.drawXObject(named: "Scan")
            content.restoreState()
            let contents = try builder.addContentStream(content)
            builder.addPage(
                mediaBox: scannedBox,
                resources: "<< /XObject << /Scan \(image) 0 R >> >>",
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Mixed text and raster

    static let mixedRasterPlacement = FixtureRect(llx: 0, lly: 396, urx: 612, ury: 792)
    static let mixedPixelWidth = 612
    static let mixedPixelHeight = 396
    static let mixedStrings: [(id: String, text: String, origin: FixturePoint)] = [
        ("vector-note-1", "VECTOR LAYER BELOW", FixturePoint(72, 300)),
        ("vector-note-2", "SCANNED BLOCK ABOVE", FixturePoint(72, 270)),
        ("vector-note-3", "ROOM 201", FixturePoint(72, 240))
    ]
    static let mixedLineStart = FixturePoint(72, 120)
    static let mixedLineEnd = FixturePoint(372, 120)

    static func mixedTextAndRaster() throws -> FixtureBuild {
        let line = FixturePath(
            id: "vector-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [mixedLineStart, mixedLineEnd],
            length: 300,
            area: 0,
            derivation: .closedForm(
                "Horizontal line y = 120 from x = 72 to x = 372: length 372 - 72 = 300.",
                magnitudeFloor: 300
            )
        )

        let texts = mixedStrings.map {
            FixtureText(
                id: $0.id,
                pageIndex: 0,
                string: $0.text,
                origin: $0.origin,
                fontSize: 12,
                fontName: "Helvetica"
            )
        }

        let raster = FixtureRaster(
            id: "scan-block",
            pageIndex: 0,
            placement: mixedRasterPlacement,
            pixelWidth: mixedPixelWidth,
            pixelHeight: mixedPixelHeight,
            bitsPerComponent: 8,
            colorSpace: "DeviceGray"
        )

        let manifest = FixtureManifest(
            kind: .mixedTextAndRaster,
            title: "One page, raster upper half and vector/text lower half",
            purpose: "The realistic case: a scanned detail pasted onto a vector sheet. Vector snap "
                + "must work in the lower half and report unavailable in the upper half, and text "
                + "extraction must find exactly the three vector strings.",
            fileName: FixtureKind.mixedTextAndRaster.fileName,
            pageCount: 1,
            pages: [
                FixturePage(
                    index: 0,
                    mediaBox: FixturePageSize.letter,
                    hasTextLayer: true,
                    hasRasterContent: true
                )
            ],
            paths: [line],
            texts: texts,
            rasters: [raster],
            notes: [
                "Raster occupies [0 396 612 792]; everything below y = 396 is vector.",
                "Exactly three extractable strings; the raster contains glyph-shaped marks that "
                    + "are not text and must not appear in extraction output."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .mixedTextAndRaster)
            let font = try builder.addBase14Font(baseFont: "Helvetica")
            let samples = RasterPattern.scannedTextPage(
                width: mixedPixelWidth,
                height: mixedPixelHeight,
                seed: 0x2026_0823
            )
            let image = try addGrayImage(
                builder: builder,
                kind: .mixedTextAndRaster,
                samples: samples,
                width: mixedPixelWidth,
                height: mixedPixelHeight
            )

            var content = PDFContentStream()
            content.saveState()
            content.concat(
                FixtureMatrix(
                    a: mixedRasterPlacement.width, b: 0, c: 0, d: mixedRasterPlacement.height,
                    e: mixedRasterPlacement.llx, f: mixedRasterPlacement.lly
                )
            )
            content.drawXObject(named: "Scan")
            content.restoreState()

            content.setLineWidth(1)
            content.setStrokeGray(0)
            content.move(to: mixedLineStart)
            content.line(to: mixedLineEnd)
            content.stroke()

            content.setFillGray(0)
            for entry in mixedStrings {
                let literal = try PDFSyntax.literalString(entry.text, kind: .mixedTextAndRaster)
                content.showText(literal, font: "F1", size: 12, at: entry.origin)
            }

            let contents = try builder.addContentStream(content)
            builder.addPage(
                mediaBox: FixturePageSize.letter,
                resources: "<< /Font << /F1 \(font) 0 R >> /XObject << /Scan \(image) 0 R >> >>",
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Helpers

    /// Adds an 8-bit DeviceGray image XObject.
    ///
    /// Refuses samples that do not fill `/Width` x `/Height` exactly. `RasterPattern`
    /// clamps each side to `RasterPattern.maximumSide`, so a larger request would
    /// otherwise write a stream shorter than its declared dimensions and a manifest
    /// raster whose pixel size is not the file's.
    static func addGrayImage(
        builder: PDFDocumentBuilder,
        kind: FixtureKind,
        samples: Data,
        width: Int,
        height: Int
    ) throws -> Int {
        guard width >= 1, height >= 1,
              width <= RasterPattern.maximumSide, height <= RasterPattern.maximumSide,
              samples.count == width * height
        else {
            throw FixtureError.generationFailed(
                kind: kind,
                reason: "image declares \(width) x \(height) samples (each side 1...\(RasterPattern.maximumSide)) "
                    + "but carries \(samples.count)"
            )
        }
        let compressed = try PDFFlate.zlibStream(samples, kind: kind)
        let entries = "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) "
            + "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode"
        return builder.addStream(entries: entries, data: compressed)
    }
}

/// Deterministic bitmap generation.
///
/// A real scan would be a photograph; the corpus only needs something that has the
/// statistical shape of scanned text — dark runs on light paper, arranged in lines —
/// and that is byte-identical on every machine.
enum RasterPattern {

    /// Generates an 8-bit grayscale page of pseudo-text.
    ///
    /// Rows are laid out as text lines of 24 samples with a 10-sample baseline band;
    /// inside the band, runs of dark samples are placed by a fixed 32-bit linear
    /// congruential generator, so no floating point and no platform RNG is involved.
    /// The largest side `scannedTextPage` generates; larger requests are clamped, and
    /// `ContentFixtures.addGrayImage` refuses to declare dimensions the samples lack.
    static let maximumSide = 8_192

    static func scannedTextPage(width: Int, height: Int, seed: UInt32) -> Data {
        let safeWidth = max(1, min(width, maximumSide))
        let safeHeight = max(1, min(height, maximumSide))
        var samples = [UInt8](repeating: 0xF4, count: safeWidth * safeHeight)
        var state = seed | 1

        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state
        }

        let lineHeight = 24
        let margin = min(48, safeWidth / 8)
        var row = margin
        while row + lineHeight < safeHeight - margin {
            let bandTop = row + 6
            let bandBottom = row + 16
            var column = margin
            while column < safeWidth - margin {
                let gap = Int(next() % 4) + 1
                let run = Int(next() % 7) + 2
                column += gap
                let end = min(column + run, safeWidth - margin)
                if column >= end { break }
                var y = bandTop
                while y < bandBottom {
                    // Vary the ink so the block does not compress away to nothing.
                    let ink = 0x10 &+ UInt8(truncatingIfNeeded: next() & 0x1F)
                    var x = column
                    let base = y * safeWidth
                    while x < end {
                        samples[base + x] = ink
                        x += 1
                    }
                    y += 1
                }
                column = end
            }
            row += lineHeight
        }
        return Data(samples)
    }
}
