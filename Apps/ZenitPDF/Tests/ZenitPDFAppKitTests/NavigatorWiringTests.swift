import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The app half of the Navigator work: real thumbnails come from the engine-barrier-wrapped
/// raster source. A drop on the page column is `ProjectWindowController.handleNavigatorDrop`'s,
/// covered with the drawing set (NextLevelDocumentsMultiDrawingTests).
@MainActor
@Suite(.appTierSerialised)
struct NavigatorWiringTests {

    @Test("The window wires the Navigator's thumbnails to the real page renderer")
    func thumbnailsComeFromTheRasterSource() async throws {
        let url = try AppTestSupport.writeFixturePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait {
            controller.contentViewController is ProjectWindowLayoutController
        })
        let shell = try #require(document.shell)
        let provider = try #require(
            shell.navigatorThumbnails.provider,
            "the app must inject the thumbnail provider once the drawing exists"
        )

        // The provider produces a real render of page 0 within the pixel cap, and the
        // loader serves it through the placeholder-then-fill path.
        let image = try #require(await provider(0, NavigatorThumbnailLoader.maximumPixelSize))
        #expect(max(image.width, image.height) <= NavigatorThumbnailLoader.maximumPixelSize)
        #expect(min(image.width, image.height) > 0)

        // The live Navigator may already have requested page 0 through its own
        // placeholder-then-fill task — that is the wiring working, not a precondition to
        // assert away. Requesting again must end with the image cached either way.
        let pageID = try #require(document.core?.document.pages.first?.id)
        await shell.navigatorThumbnails.request(pageID: pageID, pageIndex: 0)
        #expect(shell.navigatorThumbnails.image(for: pageID) != nil)

        document.close()
    }
}
