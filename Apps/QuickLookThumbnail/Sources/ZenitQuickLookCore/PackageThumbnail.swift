import CoreGraphics
import Foundation
import ImageIO
import os

/// What a Zenit PDF project looks like in Finder (NL-PLAT-21).
///
/// Two sources, in order:
///
/// 1. **The picture the application saved** — `thumbnails/package.png` inside the package: the
///    first sheet as the person last saw it, markups included. Reading it parses no drawing.
/// 2. **The drawing's first sheet** — `documents/working.pdf`, else `documents/original.pdf`,
///    drawn with CoreGraphics on white paper. This runs in the extension's own sandboxed process,
///    never in Finder and never in the application.
///
/// Every file is untrusted: a member that is a symbolic link, is not a regular file, or is larger
/// than the caps below is not read, and a PDF with no first page or a nonsensical page box is no
/// thumbnail at all — Finder then shows the document icon, which is the honest answer.
public enum PackageThumbnail {

    public static let storedImageMember = "thumbnails/package.png"
    public static let drawingMembers = ["documents/working.pdf", "documents/original.pdf"]
    /// Largest stored picture read, in bytes.
    public static let maximumImageBytes = 32 * 1024 * 1024
    /// Largest drawing opened for a thumbnail, in bytes.
    public static let maximumDrawingBytes = 512 * 1024 * 1024

    public enum Source: Equatable, Sendable {
        case storedImage(URL)
        case drawing(URL)
    }

    /// Where the thumbnail should come from for the package at `package`, or `nil` when it has
    /// none: the first of ``sources(in:)``.
    public static func source(in package: URL) -> Source? {
        sources(in: package).first
    }

    /// Every source the package offers, best first: the stored picture, then each drawing member.
    /// Chosen on file type and size alone; ``resolve(package:)`` is what proves one opens.
    public static func sources(in package: URL) -> [Source] {
        var found: [Source] = []
        let image = package.appendingPathComponent(storedImageMember)
        if isReadableRegularFile(image, limit: maximumImageBytes) { found.append(.storedImage(image)) }
        for member in drawingMembers {
            let drawing = package.appendingPathComponent(member)
            if isReadableRegularFile(drawing, limit: maximumDrawingBytes) { found.append(.drawing(drawing)) }
        }
        return found
    }

    /// The first source of the package that opens and has a size — the thumbnail, or `nil`.
    ///
    /// S-125: the source used to be chosen on file type and size alone, so a `package.png` that
    /// did not decode (damaged, foreign, or larger than 8 192 px) cost the whole Finder
    /// thumbnail and the preview's sheet image, although the drawing was readable. A stored
    /// picture that does not open now costs only itself.
    public static func resolve(package: URL) -> Resolved? {
        for source in sources(in: package) {
            if let resolved = resolve(source), resolved.naturalSize != nil { return resolved }
        }
        return nil
    }

    /// A regular file — not a link, not a directory — no larger than `limit`.
    static func isReadableRegularFile(_ url: URL, limit: Int) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return info.st_size > 0 && info.st_size <= limit
    }

    /// A source opened once (R-210): the decoded picture, or the drawing's first page with the
    /// document that owns it. The size and the drawing both come from this, so a thumbnail costs
    /// one decode or one PDF open — the old path did each twice, once to size the reply and once
    /// again inside it.
    public enum Resolved {
        case image(CGImage)
        case page(CGPDFPage, document: CGPDFDocument)

        /// The natural size in points: the picture's pixels at 1×, or the page's crop box turned by
        /// the page's rotation; `nil` for a nonsensical page box.
        public var naturalSize: CGSize? {
            switch self {
            case let .image(image):
                return CGSize(width: image.width, height: image.height)
            case let .page(page, _):
                let box = page.getBoxRect(.cropBox)
                guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
                let turned = abs(page.rotationAngle) % 180 == 90
                return turned ? CGSize(width: box.height, height: box.width) : box.size
            }
        }

        /// Draws filling a context of `size`.
        public func draw(in context: CGContext, size: CGSize) {
            let rect = CGRect(origin: .zero, size: size)
            switch self {
            case let .image(image):
                context.interpolationQuality = .high
                context.draw(image, in: rect)
            case let .page(page, _):
                context.setFillColor(CGColor(gray: 1, alpha: 1))   // paper
                context.fill(rect)
                context.saveGState()
                context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                context.clip(to: page.getBoxRect(.cropBox))
                context.drawPDFPage(page)
                context.restoreGState()
            }
        }
    }

    /// Opens `source`: decodes the picture or opens the drawing, once. `nil` when it cannot be
    /// read, which is no thumbnail.
    public static func resolve(_ source: Source) -> Resolved? {
        switch source {
        case let .storedImage(url):
            return storedImage(url).map(Resolved.image)
        case let .drawing(url):
            guard let (page, document) = firstPage(url) else { return nil }
            return .page(page, document: document)
        }
    }

    /// `natural` scaled to fit inside `maximum`, keeping its proportions; never larger than it was.
    public static func fitted(_ natural: CGSize, into maximum: CGSize) -> CGSize {
        guard natural.width > 0, natural.height > 0, maximum.width > 0, maximum.height > 0 else { return .zero }
        let scale = min(maximum.width / natural.width, maximum.height / natural.height, 1)
        return CGSize(width: (natural.width * scale).rounded(.down), height: (natural.height * scale).rounded(.down))
    }

    /// Renders the thumbnail as an image no larger than `maximum` — what a test, or any caller
    /// without Quick Look's context, uses. One open of the source.
    public static func render(package: URL, maximum: CGSize) -> CGImage? {
        guard let resolved = resolve(package: package), let natural = resolved.naturalSize else { return nil }
        let size = fitted(natural, into: maximum)
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        resolved.draw(in: context, size: size)
        return context.makeImage()
    }

    /// Counts the opens made inside a test's scope — observability for R-210. Task-local, so a
    /// test counts only its own opens while other suites run beside it.
    final class OpenCounter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }
    @TaskLocal static var openCounter: OpenCounter?

    static func storedImage(_ url: URL) -> CGImage? {
        openCounter?.increment()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width <= 8_192, image.height <= 8_192
        else { return nil }
        return image
    }

    /// The first page, with the document that owns it: a `CGPDFPage` does not keep its document
    /// alive, so the two travel together.
    static func firstPage(_ url: URL) -> (CGPDFPage, CGPDFDocument)? {
        openCounter?.increment()
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted || document.unlockWithPassword(""),
              document.numberOfPages >= 1, let page = document.page(at: 1) else { return nil }
        return (page, document)
    }
}
