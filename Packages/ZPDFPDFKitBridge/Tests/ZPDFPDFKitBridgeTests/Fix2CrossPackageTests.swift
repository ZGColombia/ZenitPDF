import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ZPDFPDFKitBridge
import ZPDFContracts

/// Changes other packages needed from the bridge.
@Suite("Fix 2 — cross-package changes in the bridge")
struct Fix2CrossPackageTests {

    private func cgDocument(_ url: URL) throws -> CGPDFDocument {
        try #require(CGPDFDocument(url as CFURL))
    }

    @Test("BH-221: /RBGroups in the /D configuration dictionary is read")
    func radioGroupsInDefaultConfiguration() throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            catalogExtra: "/OCProperties << /OCGs [5 0 R 6 0 R 7 0 R] /D << /Order [5 0 R 6 0 R 7 0 R] /RBGroups [[6 0 R 7 0 R]] >> >>",
            additional: [
                "<< /Type /OCG /Name (Walls) >>",
                "<< /Type /OCG /Name (Doors) >>",
                "<< /Type /OCG /Name (Grid) >>"
            ],
            label: "rbgroups-in-d"
        )
        let tree = try #require(try LayerCatalogReader.read(document: try cgDocument(url), limits: .standard))
        // Old output: [] — only /OCProperties was searched, where the standard never puts it.
        #expect(tree.radioGroups == [[.ocg(atIndex: 1), .ocg(atIndex: 2)]])
    }

    @Test("BH-221: a producer that writes /RBGroups beside /OCGs is still honoured")
    func radioGroupsAtPropertiesLevelFallback() throws {
        let url = try HandBuiltPDF.onePage(
            content: "",
            catalogExtra: "/OCProperties << /OCGs [5 0 R 6 0 R] /RBGroups [[5 0 R 6 0 R]] /D << /Order [5 0 R 6 0 R] >> >>",
            additional: [
                "<< /Type /OCG /Name (Doors) >>",
                "<< /Type /OCG /Name (Grid) >>"
            ],
            label: "rbgroups-in-properties"
        )
        let tree = try #require(try LayerCatalogReader.read(document: try cgDocument(url), limits: .standard))
        #expect(tree.radioGroups == [[.ocg(atIndex: 0), .ocg(atIndex: 1)]])
    }

    // MARK: - BH-079: the complete page appearance for flatten and print

    /// A 200 x 200 bitmap, white, into which a page is drawn onto the whole sheet.
    private func render(_ draw: (CGContext) -> Void) throws -> CGContext {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        draw(context)
        return context
    }

    /// Red-dominant pixels in a band, counted from the bitmap's own rows.
    private func redPixels(_ context: CGContext, in band: CGRect) -> Int {
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        var count = 0
        for y in Int(band.minY)..<Int(band.maxY) {
            // Bitmap rows run top-down; the band is in bottom-up page space.
            let row = context.height - 1 - y
            for x in Int(band.minX)..<Int(band.maxX) {
                let offset = row * context.bytesPerRow + x * 4
                if bytes[offset] > 180, bytes[offset + 1] < 90, bytes[offset + 2] < 90 { count += 1 }
            }
        }
        return count
    }

    private func annotatedDrawing(label: String, contentOnLayer: Bool = false) throws -> URL {
        // Content: a grey bar, marked with layer MC0 when asked. Annotation: a thick red
        // square border bound to layer 5 (Clouds). A content-stream replay draws only the bar.
        let content = contentOnLayer
            ? "/OC /MC0 BDC 0.5 g 20 20 160 10 re f EMC"
            : "0.5 g 20 20 160 10 re f"
        return try HandBuiltPDF.write(
            [
                "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 7 0 R] /D << /Order [5 0 R 7 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Properties << /MC0 7 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>",
                HandBuiltPDF.stream(content),
                "<< /Type /OCG /Name (Clouds) >>",
                "<< /Type /Annot /Subtype /Square /Rect [50 50 150 150] /C [1 0 0] /BS << /W 10 >> /F 4 /OC 5 0 R >>",
                "<< /Type /OCG /Name (Walls) >>"
            ],
            label: label
        )
    }

    @Test("BH-079: the appearance drawer puts the drawing's annotations on the sheet; a content replay does not")
    func appearanceIncludesAnnotations() throws {
        let url = try annotatedDrawing(label: "appearance-annotations")
        let document = try cgDocument(url)
        let bindings = AnnotationLayerBindingReader.read(from: document)
        let sheet = CGRect(x: 0, y: 0, width: 200, height: 200)
        let border = CGRect(x: 50, y: 140, width: 100, height: 10)

        let replay = try render { context in
            guard let page = document.page(at: 1) else { return }
            context.drawPDFPage(page)
        }
        // Old output (content replay only): no red at all — the annotation is lost.
        #expect(redPixels(replay, in: border) == 0)

        let drawer = try #require(PDFPageAppearanceDrawer(url: url, bindings: bindings))
        var drew = false
        let full = try render { context in
            drew = drawer.drawPageAppearance(sourcePageIndex: 0, into: context, rect: sheet, page: nil)
        }
        #expect(drew)
        #expect(redPixels(full, in: border) > 300, "the annotation's border must be on the sheet")

        // Hidden with its layer, as on the canvas.
        let tree = try #require(try LayerCatalogReader.read(document: document, limits: .standard))
        let hiding = try #require(PDFPageAppearanceDrawer(
            url: url, layerTree: tree, bindings: bindings, hiddenLayerIDs: [.ocg(atIndex: 0)]
        ))
        let hidden = try render { context in
            _ = hiding.drawPageAppearance(sourcePageIndex: 0, into: context, rect: sheet, page: nil)
        }
        #expect(redPixels(hidden, in: border) == 0)
        #expect(!hiding.drawPageAppearance(sourcePageIndex: 5, into: hidden, rect: sheet, page: nil))
    }

    @Test("BH-079: page content on a layer the project hides is refused, so the next source can draw it")
    func contentLayerOverrideIsRefused() throws {
        let url = try annotatedDrawing(label: "appearance-content-layer", contentOnLayer: true)
        let document = try cgDocument(url)
        let tree = try #require(try LayerCatalogReader.read(document: document, limits: .standard))
        let drawer = try #require(PDFPageAppearanceDrawer(
            url: url, layerTree: tree, bindings: AnnotationLayerBindingReader.read(from: document),
            hiddenLayerIDs: [.ocg(atIndex: 1)]
        ))
        #expect(drawer.pagesRefusedForLayerVisibility == [0])
        _ = try render { context in
            #expect(!drawer.drawPageAppearance(
                sourcePageIndex: 0, into: context, rect: CGRect(x: 0, y: 0, width: 200, height: 200), page: nil
            ))
        }
    }

    @Test("BH-079: a /Rotate 90 page lands on the sheet the way the markups are mapped")
    func rotatedPageRegisters() throws {
        // A 200 x 100 landscape media box turned a quarter clockwise: a 100 x 200 sheet. The red
        // block at the page's left end (x 0...20) must land at the sheet's top (y 180...200).
        let url = try HandBuiltPDF.onePage(
            content: "1 0 0 rg 0 0 20 100 re f",
            mediaBox: "[0 0 200 100]",
            pageExtra: "/Rotate 90",
            label: "appearance-rotated"
        )
        let drawer = try #require(PDFPageAppearanceDrawer(url: url))
        let context = try #require(CGContext(
            data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        #expect(drawer.drawPageAppearance(
            sourcePageIndex: 0, into: context, rect: CGRect(x: 0, y: 0, width: 100, height: 200), page: nil
        ))
        #expect(redPixels(context, in: CGRect(x: 10, y: 182, width: 80, height: 16)) > 1000)
        #expect(redPixels(context, in: CGRect(x: 10, y: 10, width: 80, height: 160)) == 0)
    }

    // MARK: - BH-167: fill colour in imported vector artwork

    @Test("BH-167: a white background rectangle is paper, not ink; a single-ink seal keeps the stamp colour")
    func whiteBackgroundIsDropped() async throws {
        let url = try HandBuiltPDF.onePage(
            content: "1 1 1 rg 0 0 100 100 re f 1 0 0 rg 20 20 60 60 re f",
            mediaBox: "[0 0 100 100]",
            label: "white-background-seal"
        )
        let artwork = try await StampArtworkImporter().importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        // Old output: 2 regions, the white sheet imported as a stamp-coloured slab covering
        // the whole seal.
        #expect(artwork.geometry.regions.count == 1)
        #expect(artwork.geometry.regions.first?.color == nil, "single ink recolours with the stamp")
    }

    @Test("BH-167: a two-ink seal keeps each region's own colour, and a white knockout stays white")
    func multiInkKeepsColours() async throws {
        let url = try HandBuiltPDF.onePage(
            content: "1 1 1 rg 0 0 100 100 re f 1 0 0 rg 10 10 40 40 re f 0 0 1 rg 50 50 40 40 re f 1 1 1 rg 20 20 10 10 re f",
            mediaBox: "[0 0 100 100]",
            label: "two-ink-seal"
        )
        let artwork = try await StampArtworkImporter().importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        let colors = artwork.geometry.regions.map(\.color)
        // Old output: 4 colourless regions — background, both inks and the knockout all drawn
        // in the one stamp colour.
        #expect(colors == [
            RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
            RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        ])
    }
}
