import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// L-81 (live test 8, re-fix): an image placed with Edit ▸ Insert Image keeps its resolution in
/// every file the flatten painter writes — the flattened PDF (and so print, which paints the same
/// sheets), the layered export and the annotated export (ADR-0043 §3, as amended).
///
/// Old output: the renderer had no image shape, so the picture reached each of these as its
/// 96-cell mosaic — 96 × 64 filled squares for a 2 400 × 1 600 px picture, and no image at all.
@Suite(.sharedHeap)
struct L8InsertedImageExportTests {

    static let pixelWidth = 2_400
    static let pixelHeight = 1_600

    /// A 2 400 × 1 600 px sketch: 3-px black lines every 40 px on white.
    static func sketchJPEG() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 20, to: pixelWidth, by: 40) { context.fill(CGRect(x: x, y: 0, width: 3, height: pixelHeight)) }
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        return data as Data
    }

    /// The picture placed 240 × 160 pt on the 400 × 300 pt fixture sheet.
    static func picture() throws -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID()),
            zIndex: 0,
            shape: .image(RenderImage(
                origin: PDFPoint(x: 80, y: 70), xEnd: PDFPoint(x: 320, y: 70), yEnd: PDFPoint(x: 80, y: 230),
                source: try sketchJPEG()
            )),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 1)
        )
    }

    /// Collects the stream values of a PDF dictionary (an `/XObject` resource dictionary).
    private final class StreamCollector {
        var streams: [CGPDFStreamRef] = []
    }

    private static func streams(in dictionary: CGPDFDictionaryRef) -> [CGPDFStreamRef] {
        let collector = StreamCollector()
        CGPDFDictionaryApplyFunction(dictionary, { _, object, info in
            guard let info else { return }
            let collector = Unmanaged<StreamCollector>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { collector.streams.append(stream) }
        }, Unmanaged.passUnretained(collector).toOpaque())
        return collector.streams
    }

    /// The `/Width` and `/Height` of every image XObject a page draws — through its resources,
    /// the forms they name, and its annotations' appearance forms.
    static func imageSizes(in data: Data) -> [(width: Int, height: Int)] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return [] }
        var sizes: [(width: Int, height: Int)] = []
        var seen = Set<CGPDFStreamRef>()
        func visit(_ resources: CGPDFDictionaryRef, depth: Int) {
            guard depth < 6 else { return }
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
            for stream in streams(in: xObjects) where seen.insert(stream).inserted {
                guard let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
                var subtype: UnsafePointer<CChar>?
                _ = CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
                switch subtype.map({ String(cString: $0) }) {
                case "Image":
                    var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                    _ = CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                    _ = CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                    sizes.append((width, height))
                case "Form":
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner { visit(inner, depth: depth + 1) }
                default:
                    break
                }
            }
        }
        for index in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: index)?.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources { visit(resources, depth: 0) }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { continue }
            for slot in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var appearances: CGPDFDictionaryRef?
                var normal: CGPDFStreamRef?
                guard CGPDFArrayGetDictionary(annotations, slot, &annotation), let annotation,
                      CGPDFDictionaryGetDictionary(annotation, "AP", &appearances), let appearances,
                      CGPDFDictionaryGetStream(appearances, "N", &normal), let normal,
                      let form = CGPDFStreamGetDictionary(normal) else { continue }
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(form, "Resources", &inner), let inner { visit(inner, depth: 1) }
            }
        }
        return sizes
    }

    @Test("The flattened PDF (and print, which paints the same sheet) holds the picture at its 2 400 × 1 600 px")
    func flattenedSheetKeepsThePicture() throws {
        let page = FlattenedPDFWriterTests.page()
        let markup = try Self.picture()
        // The one entry on the flattened sheet's image allow-list.
        #expect(FlattenedVectorTextTests.imageAllowance(markup.shape) != nil)
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [markup])],
            content: nil
        )
        let sizes = Self.imageSizes(in: data)
        // Old output: no image — 96 × 64 mosaic squares painted as `f`.
        #expect(sizes.count == 1, "\(sizes)")
        #expect(sizes.first?.width == Self.pixelWidth && sizes.first?.height == Self.pixelHeight, "\(sizes)")
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(output.xObjectInvocations == 1, "the picture is drawn once")
        #expect(output.inlineImages == 0)
    }

    @Test("The layered export carries the picture at its own resolution inside the markup layer")
    func layeredExportKeepsThePicture() throws {
        let source = LayeredSourceFixtures.plain()
        let before = Self.imageSizes(in: source).count
        let page = FlattenedPDFWriterTests.page()
        let produced = try LayeredMarkupExporter().data(
            source: source,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [try Self.picture()])]
        )
        let added = Self.imageSizes(in: produced.data).dropFirst(before)
        #expect(added.count == 1, "\(Array(added))")
        #expect(added.first?.width == Self.pixelWidth && added.first?.height == Self.pixelHeight)
        #expect(produced.outcome.markupSpanCount == 1)
        #expect(produced.outcome.rejectedMarkupCount == 0)
    }

    @Test("The annotated export's appearance shows the picture at its own resolution")
    func annotatedExportKeepsThePicture() throws {
        let page = FlattenedPDFWriterTests.page()
        let markup = try Self.picture()
        let annotation = StandardAnnotation(
            id: markup.id.rawValue, geometry: .stamp, subject: "Image", appearance: [markup]
        )
        let produced = try StandardAnnotationWriter().data(
            source: LayeredSourceFixtures.plain(),
            pages: [StandardAnnotationPage(page: page, sourcePageIndex: 0, annotations: [annotation])]
        )
        let sizes = Self.imageSizes(in: produced.data)
        #expect(sizes.contains { $0.width == Self.pixelWidth && $0.height == Self.pixelHeight }, "\(sizes)")
    }
}
