import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Scan clean-up for sheets that arrive as pictures (NL-PDF-12): straighten, correct the
/// perspective of a phone photo, trim the scanner's border, turn, and enhance for print.
///
/// Every step runs on this Mac — Core Image and Vision, no network — and every step is pure on
/// its input image, so a test drives each one with a synthetic sheet and measures the result.
///
/// # What never happens
///
/// A cleaned sheet is written as a **new PDF** at the page's own physical size — or, when a trim
/// or a perspective correction changed the picture's shape, at the size of the picture itself at
/// the resolution it was cleaned at, so both axes keep one scale (W-054). The drawing the person
/// measured on is not touched, so no markup can move under a rotation it did not follow; the new
/// file starts uncalibrated, and the report says so.
public enum ScanCleanup {

    /// What to do to each page.
    public struct Options: Sendable, Hashable {
        /// Measure the skew of the lines on the sheet and turn it straight.
        public var straightens: Bool
        /// Find the sheet's four corners in a photo and rectify it to a rectangle.
        public var correctsPerspective: Bool
        /// Cut away the scanner lid's dark or light border around the sheet.
        public var trimsBorder: Bool
        /// Quarter turns, clockwise.
        public var quarterTurns: Int
        public var enhancement: Enhancement
        /// Resolution the page is rendered at for cleaning, in dots per inch.
        public var dpi: Double

        public enum Enhancement: String, Sendable, Hashable, CaseIterable {
            case none
            /// Grey, with the paper lifted to white and the ink deepened.
            case greyscale
            /// One bit: ink black, paper white.
            case blackAndWhite
        }

        public init(
            straightens: Bool = true,
            correctsPerspective: Bool = false,
            trimsBorder: Bool = false,
            quarterTurns: Int = 0,
            enhancement: Enhancement = .greyscale,
            dpi: Double = 200
        ) {
            self.straightens = straightens
            self.correctsPerspective = correctsPerspective
            self.trimsBorder = trimsBorder
            self.quarterTurns = quarterTurns
            self.enhancement = enhancement
            self.dpi = dpi
        }
    }

    /// What was done to one page.
    public struct PageReport: Sendable, Hashable {
        public var pageIndex: Int
        /// The skew measured, degrees counter-clockwise; `nil` when straightening was off or the
        /// page had too little linework to measure.
        public var measuredSkew: Double?
        /// Whether a sheet outline was found and rectified.
        public var perspectiveCorrected: Bool
        public var trimmed: Bool
        /// The resolution the sheet was rendered at for cleaning, in dots per inch: the
        /// requested ``Options/dpi``, or the largest whole dpi within the pixel budget when the
        /// sheet at the requested one would exceed it. `nil` when the sheet could not be rendered
        /// at all and was copied as it is, drawn from its own content, uncleaned (U-053).
        public var renderedDPI: Double? = nil

        public init(pageIndex: Int, measuredSkew: Double? = nil, perspectiveCorrected: Bool = false, trimmed: Bool = false,
                    renderedDPI: Double? = nil) {
            self.pageIndex = pageIndex
            self.measuredSkew = measuredSkew
            self.perspectiveCorrected = perspectiveCorrected
            self.trimmed = trimmed
            self.renderedDPI = renderedDPI
        }

        /// Whether the sheet was cleaned, at whatever resolution.
        public var wasCleaned: Bool { renderedDPI != nil }

        /// Whether the sheet was cleaned below the requested resolution, `requestedDPI`.
        public func wasReduced(from requestedDPI: Double) -> Bool {
            guard let renderedDPI else { return false }
            return renderedDPI < requestedDPI
        }
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreadable
        case noPages
        /// More pages than one clean-up writes; nothing is written (U-053: every page past the
        /// limit used to be cut off without a word).
        case tooManyPages(count: Int, limit: Int)
        /// A page the drawing lists but whose content could not be read; nothing is written, so
        /// no later sheet moves up into its place.
        case unreadablePage(Int)
        /// The drawing is password-protected and the password given does not open it (V-054).
        /// A locked drawing lists its pages but hands none of them out, so this used to be
        /// reported as "sheet 1 of the drawing could not be read".
        case locked

        public var description: String {
            switch self {
            case .unreadable: "the drawing could not be read"
            case .noPages: "the drawing has no pages to clean up"
            case let .tooManyPages(count, limit):
                "the drawing has \(count) pages, and a clean-up writes at most \(limit): split it and clean each part"
            case let .unreadablePage(index): "sheet \(index + 1) of the drawing could not be read"
            case .locked: "the drawing is password-protected, and the password does not open it"
            }
        }
    }

    /// The most pages one clean-up writes.
    public static let pageLimit = 2_000
    /// The most pixels a sheet is rendered at for cleaning (about 800 MB of RGBA).
    public static let pixelBudget = 200_000_000

    static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    // MARK: - Straighten

    /// The skew of the page's linework in degrees (counter-clockwise positive), measured by the
    /// projection profile: the angle at which the dark pixels line up into the sharpest rows.
    /// Searched over ±`range` degrees, coarse then fine; accurate to about 0.05°. `nil` when the
    /// page has almost no ink.
    public static func skewAngle(of image: CGImage, range: Double = 8) -> Double? {
        let edge = 900
        let scale = min(1, Double(edge) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = gray.data else { return nil }
        gray.setFillColor(gray: 1, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: width, height: height))
        gray.interpolationQuality = .medium
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        var points: [(Double, Double)] = []
        points.reserveCapacity(width * height / 20)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 160 {
                points.append((Double(x), Double(y)))
            }
        }
        guard points.count > 200, Double(points.count) < Double(width * height) * 0.5 else { return nil }
        func score(_ degrees: Double) -> Double {
            let radians = degrees * .pi / 180
            let s = sin(radians), c = cos(radians)
            var bins = [Double](repeating: 0, count: height * 2 + width * 2)
            let offset = Double(width + height / 2)
            for (x, y) in points {
                let row = Int((y * c - x * s + offset).rounded())
                if row >= 0, row < bins.count { bins[row] += 1 }
            }
            return bins.reduce(0) { $0 + $1 * $1 }
        }
        var best = 0.0, bestScore = -1.0
        var angle = -range
        while angle <= range + 1e-9 {
            let value = score(angle)
            if value > bestScore { bestScore = value; best = angle }
            angle += 0.5
        }
        var fine = best - 0.5
        let coarse = best
        while fine <= coarse + 0.5 + 1e-9 {
            let value = score(fine)
            if value > bestScore { bestScore = value; best = fine }
            fine += 0.05
        }
        // The profile measures in image rows (y down); counter-clockwise on the sheet is the
        // opposite sense.
        return -best
    }

    /// `image` turned by `degrees` counter-clockwise about its centre, on white, same size.
    public static func rotated(_ image: CGImage, degrees: Double) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // Straightening a sheet skewed by +θ turns it by −θ.
        context.rotate(by: CGFloat(-degrees * .pi / 180))
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    // MARK: - Perspective

    /// The sheet's corners in a photo, normalised 0…1 with the origin bottom-left, or `nil`
    /// when no convincing rectangle covers at least a quarter of the picture.
    public static func sheetQuadrilateral(in image: CGImage) -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.6
        request.minimumSize = 0.25
        request.minimumAspectRatio = 0.3
        request.quadratureTolerance = 30
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    /// The photo rectified to the sheet's rectangle, or `nil` when there is no sheet to find.
    public static func perspectiveCorrected(_ image: CGImage) -> CGImage? {
        guard let quad = sheetQuadrilateral(in: image) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(point(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(quad.topRight), forKey: "inputTopRight")
        filter.setValue(point(quad.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(quad.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage else { return nil }
        // The filter sizes its output by the longer of each pair of opposite edges, which
        // stretches the near side's length onto the far side. The sheet's own proportions are
        // closer to the mean of opposite edges, so the result is resampled to that.
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
        }
        let width = (length(quad.topLeft, quad.topRight) + length(quad.bottomLeft, quad.bottomRight)) / 2
        let height = (length(quad.topLeft, quad.bottomLeft) + length(quad.topRight, quad.bottomRight)) / 2
        guard width > 1, height > 1, output.extent.width > 0, output.extent.height > 0 else { return nil }
        let resized = output.transformed(by: CGAffineTransform(
            scaleX: width / output.extent.width, y: height / output.extent.height
        ))
        return context.createCGImage(resized, from: resized.extent.integral)
    }

    // MARK: - Trim, turn, enhance

    /// The rectangle inside the scanner's border: the rows and columns from each edge inward
    /// until one is mostly paper-coloured (the sheet), in pixels, origin bottom-left.
    public static func contentBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = gray.data else { return nil }
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        // Row 0 of the buffer is the top of the image.
        func rowIsPaper(_ y: Int) -> Bool {
            var light = 0
            for x in 0..<width where pixels[y * width + x] > 170 { light += 1 }
            return light > width * 6 / 10
        }
        func columnIsPaper(_ x: Int, _ top: Int, _ bottom: Int) -> Bool {
            var light = 0
            for y in top...bottom where pixels[y * width + x] > 170 { light += 1 }
            return light > (bottom - top + 1) * 6 / 10
        }
        var top = 0, bottom = height - 1
        while top < bottom, !rowIsPaper(top) { top += 1 }
        while bottom > top, !rowIsPaper(bottom) { bottom -= 1 }
        guard bottom - top > height / 4 else { return nil }
        var left = 0, right = width - 1
        while left < right, !columnIsPaper(left, top, bottom) { left += 1 }
        while right > left, !columnIsPaper(right, top, bottom) { right -= 1 }
        guard right - left > width / 4 else { return nil }
        guard top > 0 || left > 0 || bottom < height - 1 || right < width - 1 else { return nil }
        return CGRect(x: left, y: height - 1 - bottom, width: right - left + 1, height: bottom - top + 1)
    }

    /// `image` turned by quarter turns clockwise.
    public static func turned(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let input = CIImage(cgImage: image)
        let orientation: CGImagePropertyOrientation = [.right, .down, .left][turns - 1]
        let output = input.oriented(orientation)
        return context.createCGImage(output, from: output.extent)
    }

    /// `image` enhanced for printing.
    public static func enhanced(_ image: CGImage, _ enhancement: Options.Enhancement) -> CGImage? {
        guard enhancement != .none else { return image }
        var output = CIImage(cgImage: image)
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: enhancement == .blackAndWhite ? 1.6 : 1.25,
            kCIInputBrightnessKey: 0.05
        ])
        if enhancement == .blackAndWhite, let filter = CIFilter(name: "CIColorThreshold") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(0.55, forKey: "inputThreshold")
            output = filter.outputImage ?? output
        }
        return context.createCGImage(output, from: output.extent)
    }

    // MARK: - One page, and a whole document

    /// Cleans one rendered page.
    public static func clean(_ image: CGImage, pageIndex: Int, options: Options) -> (image: CGImage, report: PageReport) {
        var current = image
        var report = PageReport(pageIndex: pageIndex, measuredSkew: nil, perspectiveCorrected: false, trimmed: false)
        if options.correctsPerspective, let rectified = perspectiveCorrected(current) {
            current = rectified
            report.perspectiveCorrected = true
        }
        if options.trimsBorder, let bounds = contentBounds(of: current),
           let cropped = current.cropping(to: topLeftPixelRect(bounds, imageHeight: current.height)) {
            current = cropped
            report.trimmed = true
        }
        if options.straightens, let skew = skewAngle(of: current) {
            report.measuredSkew = skew
            if abs(skew) >= 0.05, let straight = rotated(current, degrees: skew) { current = straight }
        }
        if options.quarterTurns % 4 != 0, let turnedImage = turned(current, quarterTurns: options.quarterTurns) { current = turnedImage }
        if let enhancedImage = enhanced(current, options.enhancement) { current = enhancedImage }
        return (current, report)
    }

    /// `rect`, in pixels with the origin bottom-left (``contentBounds(of:)``), as the rectangle
    /// `CGImage.cropping(to:)` takes: origin top-left, row 0 the top of the picture. W-053: the
    /// bottom-left rectangle used to be passed straight in, so a sheet off-centre on the glass lost
    /// paper at one edge and kept the scanner's border at the other.
    package static func topLeftPixelRect(_ rect: CGRect, imageHeight: Int) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(imageHeight) - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Renders every page of `input` at `options.dpi`, cleans it, and writes a new PDF whose pages
    /// keep each source page's physical size (its crop box, turned when quarter turns change the
    /// orientation). A page whose picture changed shape in cleaning — trimmed, or rectified from a
    /// photo — is instead the picture's own size at the resolution it was cleaned at, so X and Y
    /// keep one scale (W-054: the picture used to be stretched onto the source page's box).
    /// Pictures are embedded as JPEG.
    ///
    /// Every page of the drawing is in the copy, in its place. A chosen sheet too large for the
    /// pixel budget at `options.dpi` is cleaned at the largest whole dpi that fits, and one that
    /// cannot be rendered at all is copied as it is; each says so in its report
    /// (``PageReport/renderedDPI``). A drawing past ``pageLimit`` pages is refused whole.
    ///
    /// `password` opens a protected drawing — the one the project opened it with; a drawing it
    /// does not open is refused as ``Refusal/locked``.
    @discardableResult
    public static func cleanDocument(
        at input: URL, password: String? = nil, to output: URL, pages: Set<Int>? = nil, options: Options
    ) throws -> [PageReport] {
        try cleanDocument(at: input, password: password, to: output, pages: pages, options: options, pixelBudget: pixelBudget)
    }

    /// ``cleanDocument(at:password:to:pages:options:)`` with the pixel budget named, so a test can
    /// reach the reduced-resolution path without an 800 MB raster. `package`: the release gate
    /// builds this package's tests without `@testable`.
    @discardableResult
    package static func cleanDocument(
        at input: URL, password: String? = nil, to output: URL, pages: Set<Int>? = nil, options: Options, pixelBudget: Int
    ) throws -> [PageReport] {
        guard let document = CGPDFDocument(input as CFURL) else { throw Refusal.unreadable }
        // A locked drawing lists its pages and hands none of them out (V-054).
        if document.isEncrypted, !document.isUnlocked {
            guard let password, document.unlockWithPassword(password) else { throw Refusal.locked }
        }
        guard document.numberOfPages > 0 else { throw Refusal.noPages }
        // Refused whole rather than cut off at the limit: the copy used to end at page 2,000
        // with nothing to say the rest was gone (U-053).
        guard document.numberOfPages <= pageLimit else {
            throw Refusal.tooManyPages(count: document.numberOfPages, limit: pageLimit)
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "Zenit PDF"] as CFDictionary)
        else { throw Refusal.unreadable }
        var reports: [PageReport] = []
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { throw Refusal.unreadablePage(number - 1) }
            let crop = page.getBoxRect(.cropBox)
            let turnsPage = ((page.rotationAngle / 90) % 2) != 0
            var paper = turnsPage ? CGSize(width: crop.height, height: crop.width) : crop.size
            /// The page copied as it is, drawn from its own content.
            func copyAsIs() {
                var box = CGRect(origin: .zero, size: paper)
                pdf.beginPage(mediaBox: &box)
                pdf.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                pdf.drawPDFPage(page)
                pdf.endPage()
            }
            guard pages == nil || pages!.contains(number - 1) else {
                copyAsIs()
                continue
            }
            // A sheet that does not fit the budget at the requested resolution is rendered at the
            // largest whole dpi that does. It used to be skipped: the copy lost the sheet and every
            // later one moved up a place, and no report mentioned it (U-053).
            guard let dpi = renderingDPI(paper: paper, requested: options.dpi, pixelBudget: pixelBudget),
                  let rendered = render(page, paper: paper, dpi: dpi)
            else {
                reports.append(PageReport(pageIndex: number - 1, measuredSkew: nil, perspectiveCorrected: false, trimmed: false))
                copyAsIs()
                continue
            }
            var cleaned = clean(rendered, pageIndex: number - 1, options: options)
            cleaned.report.renderedDPI = dpi
            reports.append(cleaned.report)
            paper = cleanedPaper(paper, rendered: rendered, cleaned: cleaned.image, quarterTurns: options.quarterTurns, dpi: dpi)
            var box = CGRect(origin: .zero, size: paper)
            pdf.beginPage(mediaBox: &box)
            pdf.interpolationQuality = .high
            pdf.draw(jpegImage(cleaned.image) ?? cleaned.image, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
        try (data as Data).write(to: output, options: .atomic)
        return reports
    }

    /// The page size, in points, a cleaned picture is written at. `paper` is the source page's
    /// (turned) crop box and `rendered` the raster made of it at `dpi`. When the cleaned picture is
    /// exactly that raster's size, or its quarter-turned size, the page keeps `paper` (turned with
    /// it), exact to the point. When cleaning changed the picture's shape — a trim or a perspective
    /// correction — the page is the picture's own size at `dpi`, so one calibration holds on both
    /// axes. W-054: `paper` used to be kept whatever the picture's shape, stretching a rectified
    /// photo by about 17.5 % in X against Y.
    package static func cleanedPaper(_ paper: CGSize, rendered: CGImage, cleaned: CGImage, quarterTurns: Int, dpi: Double) -> CGSize {
        let turns = quarterTurns % 2 != 0
        let turnedPaper = turns ? CGSize(width: paper.height, height: paper.width) : paper
        let expected = turns ? (rendered.height, rendered.width) : (rendered.width, rendered.height)
        if (cleaned.width, cleaned.height) == expected { return turnedPaper }
        return CGSize(width: Double(cleaned.width) * 72 / dpi, height: Double(cleaned.height) * 72 / dpi)
    }

    /// The resolution a sheet of `paper` points is rendered at: `requested`, or the largest whole
    /// dpi at which it fits `pixelBudget` pixels; `nil` when not even 1 dpi fits.
    package static func renderingDPI(paper: CGSize, requested: Double, pixelBudget: Int) -> Double? {
        guard paper.width > 0, paper.height > 0, requested.isFinite, requested > 0 else { return nil }
        func pixelCount(_ dpi: Double) -> Double {
            let scale = dpi / 72
            return max(1, (paper.width * scale).rounded()) * max(1, (paper.height * scale).rounded())
        }
        let budget = Double(pixelBudget)
        if pixelCount(requested) <= budget { return requested }
        var dpi = min(requested, (72 * (budget / (paper.width * paper.height)).squareRoot()).rounded(.down))
        while dpi >= 1, pixelCount(dpi) > budget { dpi -= 1 }
        return dpi >= 1 ? dpi : nil
    }

    /// `page` rendered at `dpi` on white, filling the raster, or `nil` when the raster cannot be
    /// made. `paper` is the page's crop box in points, turned by its `/Rotate`.
    ///
    /// The drawing transform is asked for `paper` itself, so it only turns the page and moves its
    /// crop box to the origin; the scale to pixels is applied here. `getDrawingTransform` scales a
    /// page down to fit a rectangle but never up, so asked for the pixel rectangle it left the
    /// sheet at 72 dpi, centred in white — at 200 dpi a third of the raster across, which the
    /// clean-up then trimmed, rectified and wrote as the whole page (found with W-054).
    package static func render(_ page: CGPDFPage, paper: CGSize, dpi: Double) -> CGImage? {
        let scale = dpi / 72
        let pixels = CGSize(width: max(1, (paper.width * scale).rounded()), height: max(1, (paper.height * scale).rounded()))
        guard paper.width > 0, paper.height > 0,
              let raster = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                     bytesPerRow: Int(pixels.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        raster.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        raster.fill(CGRect(origin: .zero, size: pixels))
        raster.scaleBy(x: pixels.width / paper.width, y: pixels.height / paper.height)
        raster.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: paper), rotate: 0, preserveAspectRatio: true))
        raster.drawPDFPage(page)
        return raster.makeImage()
    }

    /// The image as a JPEG-backed image, so a PDF context embeds it as `/DCTDecode`.
    static func jpegImage(_ image: CGImage, quality: Double = 0.85) -> CGImage? {
        let out = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(writer), let provider = CGDataProvider(data: out) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension ScanCleanup.Refusal: LocalizedError {
    public var errorDescription: String? { description }
}
