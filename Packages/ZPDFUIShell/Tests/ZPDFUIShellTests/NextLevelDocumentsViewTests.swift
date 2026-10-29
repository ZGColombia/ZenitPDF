import CoreGraphics
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Round 2 documents, shell tier: a card shows its sheet turned and cropped (NL-DOCS-07/16), says
/// "No scale" in words (NL-MEASURE-02), and offers the view and removal items only once
/// the app wires them.
@MainActor
@Suite("Next level documents — the sheet's view on its card", .shellTierSerialised)
struct NextLevelDocumentsViewTests {

    /// A 40 × 20 px image of a 400 × 200 pt page: the left half black, the right half white.
    private func halfBlack() -> CGImage {
        let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        return context.makeImage()!
    }

    private func page(rotation: Int = 0, crop: PDFRectValue? = nil) -> PageDescriptor {
        let box = PDFRectValue(x: 0, y: 0, width: 400, height: 200)
        return PageDescriptor(
            id: UUID(), index: 0, label: "1", mediaBox: box, cropBox: box, rotation: .degrees0,
            viewRotation: rotation, viewCrop: crop
        )
    }

    private func grey(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel: [UInt8] = [0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[0]
    }

    @Test("Cropped to the right half: 20 × 20 px, all white (hand-derived from 10 px per 100 pt)")
    func cropThumbnail() throws {
        let cropped = try #require(NavigatorThumbnailLoader.viewImage(
            halfBlack(), for: page(crop: PDFRectValue(x: 200, y: 0, width: 200, height: 200))
        ))
        #expect(cropped.width == 20 && cropped.height == 20)
        #expect(grey(cropped, x: 2, y: 2) > 200 && grey(cropped, x: 17, y: 17) > 200)
    }

    @Test("Turned 90°: 20 × 40 px, the black left half now on top")
    func turnedThumbnail() throws {
        let turned = try #require(NavigatorThumbnailLoader.viewImage(halfBlack(), for: page(rotation: 90)))
        #expect(turned.width == 20 && turned.height == 40)
        #expect(grey(turned, x: 10, y: 5) < 60, "clockwise: the left edge goes to the top")
        #expect(grey(turned, x: 10, y: 35) > 200)
    }

    @Test("The card's fit follows the view: a turned 400 × 200 sheet is portrait")
    func fitFollowsView() {
        let size = NavigatorPageThumbnail.sheetSize(for: page(rotation: 90))
        #expect(size.height > size.width)
        #expect(page(rotation: 270).displayRotation == 270)
        #expect(page(crop: PDFRectValue(x: -50, y: 0, width: 100, height: 100)).viewBox
            == PDFRectValue(x: 0, y: 0, width: 50, height: 100), "a crop is clamped to the crop box")
    }

    @Test("\"No scale\" is spoken with the card, never colour alone")
    func noScaleSpoken() {
        let label = NavigatorPageCard.accessibilityLabel(for: page(), pageCount: 3, position: 0, isUnscaled: true)
        #expect(label.hasSuffix(", No scale"))
        #expect(NavigatorPageCard.accessibilityLabel(for: page(), pageCount: 3, position: 0, isUnscaled: false) == "Page 1 of 3")
    }

    @Test("View items: titles, and a removal names its count")
    func viewItemTitles() {
        #expect(NavigatorViewAction.rotateRight.title(count: 1) == "Rotate View Right")
        #expect(NavigatorViewAction.removeFromSet.title(count: 1) == "Remove from Set")
        #expect(NavigatorViewAction.removeFromSet.title(count: 3) == "Remove 3 Sheets from Set")
        #expect(NavigatorRemovedSheetsSection.header(count: 2) == "Removed from Set (2)")
        let environment = ProjectShellEnvironment.mock()
        #expect(environment.onRotatePages == nil && environment.onSetPagesRemoved == nil, "no dead items before the app wires them")
    }
}
