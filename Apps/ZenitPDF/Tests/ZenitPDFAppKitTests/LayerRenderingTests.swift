import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFGeometry
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Gap 10, the app half: the content-stream render path draws exactly the layers the
/// effective visibility allows, and a Navigator toggle travels the whole wire — model,
/// snap rebuild, re-render decision — through the shipping document.
@MainActor
@Suite(.appTierSerialised)
struct LayerRenderingTests {

    /// The fixture's marked-content property names, from its manifest notes.
    private static let wallsName = "L0"
    private static let gridName = "L2"

    private static func makeFixture() throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try ZPDFFixtures.make(.threeLayers, in: directory)
        return (handle.url, directory)
    }

    /// Mean darkness (0 = white, 1 = black) in a small window around one page point.
    private static func ink(
        in image: CGImage,
        around pagePoint: PDFPointValue,
        page: ZPDFUIPresentation.PageDescriptor,
        scale: CGFloat
    ) -> Double {
        let transform = PageDisplayTransform(
            pageBox: page.visibleBox,
            rotation: page.rotation.rawValue,
            zoom: scale,
            origin: .zero
        )
        let view = transform.viewPoint(from: pagePoint)
        let radius = 3
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        var total = 0.0
        var samples = 0.0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = Int(view.x) + dx
                let y = Int(view.y) + dy
                guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < data.count else { continue }
                let red = Double(data[offset]) / 255
                let green = Double(data[offset + 1]) / 255
                let blue = Double(data[offset + 2]) / 255
                total += 1 - (red + green + blue) / 3
                samples += 1
            }
        }
        return samples > 0 ? total / samples : 0
    }

    /// A plan that covers the whole page at `scale` device pixels per point, so the tests that
    /// predate viewport rendering keep asserting about the same picture. Production never asks
    /// for this at a working zoom: gate Z8 refuses a whole A1 above 199.6 %.
    static func wholePagePlan(page: ZPDFUIPresentation.PageDescriptor, scale: CGFloat) -> ViewportRasterPlan {
        let transform = PageDisplayTransform(
            pageBox: page.visibleBox,
            rotation: page.rotation.rawValue,
            zoom: scale,
            origin: .zero
        )
        // Backing scale 1 with the zoom carrying the whole factor, so the plan's device space
        // and the render's pixel space are the same space.
        return (try? ViewportRasterPlanner.plan(
            transform: transform,
            visibleViewRect: transform.pageFrame,
            backingScale: 1,
            overscanViewPoints: 0
        )) ?? ViewportRasterPlan(
            pageRegion: page.visibleBox,
            visiblePageRegion: page.visibleBox,
            pixelSize: RenderPixelSize(width: 1, height: 1),
            scale: scale,
            backingScale: 1,
            destination: .zero,
            deviceRect: .zero,
            originInPageDevicePixels: .zero
        )
    }

    @Test("The content-stream path draws visible layers and omits hidden ones, pixel-for-pixel")
    func filteredRenderOmitsHiddenLayers() async throws {
        let (url, directory) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = try await DocumentSessionLoader.load(pdfAt: url)
        defer { Task { await loaded.rasterSource.close() } }
        let contractPage = loaded.pages[0]
        let page = ZPDFUIPresentation.PageDescriptor(
            id: contractPage.id.rawValue,
            index: contractPage.index,
            label: contractPage.label,
            mediaBox: PDFRectValue(
                x: contractPage.boxes.media.origin.x,
                y: contractPage.boxes.media.origin.y,
                width: contractPage.boxes.media.size.width,
                height: contractPage.boxes.media.size.height
            ),
            cropBox: PDFRectValue(
                x: contractPage.boxes.crop.origin.x,
                y: contractPage.boxes.crop.origin.y,
                width: contractPage.boxes.crop.size.width,
                height: contractPage.boxes.crop.size.height
            ),
            rotation: ZPDFUIPresentation.PageRotation(rawValue: contractPage.rotation.rawValue) ?? .degrees0
        )

        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let extraction = try #require(
            try? await VectorExtractor(options: options).extract(documentAt: url, pageIndex: 0)
        )

        let scale: CGFloat = 2
        // Grid ships hidden (`/D /OFF`), so the truthful default hides exactly it.
        let defaultRender = try #require(LayerFilteredPageRenderer.render(
            filtering: .init(extraction: extraction, hiddenLayerIDs: [Self.gridName]),
            page: page,
            plan: Self.wholePagePlan(page: page, scale: scale)
        ))
        // The walls rectangle's left edge (x=100, y 600-700) carries ink…
        let wallsEdge = PDFPointValue(x: 100, y: 650)
        #expect(Self.ink(in: defaultRender, around: wallsEdge, page: page, scale: scale) > 0.05)
        // …and the default-hidden grid line (y=300) does not.
        let gridPoint = PDFPointValue(x: 250, y: 300)
        #expect(Self.ink(in: defaultRender, around: gridPoint, page: page, scale: scale) < 0.01)

        // Hide Walls, show Grid: the same points swap roles. That is the whole point of
        // the content-stream path — the native renderers cannot draw this state at all.
        let overridden = try #require(LayerFilteredPageRenderer.render(
            filtering: .init(extraction: extraction, hiddenLayerIDs: [Self.wallsName]),
            page: page,
            plan: Self.wholePagePlan(page: page, scale: scale)
        ))
        #expect(Self.ink(in: overridden, around: wallsEdge, page: page, scale: scale) < 0.01)
        #expect(Self.ink(in: overridden, around: gridPoint, page: page, scale: scale) > 0.05)
    }

    @Test("A Navigator toggle rebuilds the snap index and demands the content-stream render")
    func toggleTravelsTheWholeWire() async throws {
        let (url, directory) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil })
        #expect(await AppTestSupport.wait { document.layerVisibility.hasLayers })
        let shell = try #require(document.shell)
        #expect(await AppTestSupport.wait { !shell.navigatorLayers.rows.isEmpty })
        #expect(shell.navigatorLayers.rows.map(\.name) == ["Walls", "Doors", "Grid", "Walls"])
        #expect(shell.navigatorLayers.rows.first?.isVisible == true)

        var renders: [LayerFilteredPageRenderer.Filtering?] = []
        document.onLayerRenderingChange = { renders.append($0) }

        // The Navigator's checkbox: hide the first Walls layer.
        let walls = try #require(shell.navigatorLayers.rows.first)
        shell.navigatorLayers.setVisible(false, layerID: walls.id)
        #expect(await AppTestSupport.wait { !renders.isEmpty })

        // Overrides differ from the document default: the render must be the filtered one,
        // with Walls (and the default-hidden Grid) in its hidden set.
        let filtering = try #require(renders.last ?? nil)
        #expect(filtering.hiddenLayerIDs.contains(Self.wallsName))
        #expect(filtering.hiddenLayerIDs.contains(Self.gridName))
        // The Navigator now shows the state actually in force.
        #expect(shell.navigatorLayers.rows.first?.isVisible == false)
        // The hidden layer is structurally un-snappable in the session (S23).
        let core = try #require(document.core)
        let contractPage = try #require(document.drawing?.pages.first)
        let resolution = try? await core.session.resolveSnap(
            pageID: contractPage.id,
            pagePoint: PDFPoint(x: 102, y: 602),
            layout: PageViewLayout(zoom: 1, backingScale: 2)
        )
        #expect(resolution?.winner == nil, "the Walls corner must not snap while Walls is hidden")

        // Toggling back to the document default returns the canvas to the native render.
        renders = []
        shell.navigatorLayers.setVisible(true, layerID: walls.id)
        #expect(await AppTestSupport.wait { !renders.isEmpty })
        #expect(renders.last.flatMap { $0 } == nil, "defaults again: the native raster is truthful")

        document.close()
    }
}
