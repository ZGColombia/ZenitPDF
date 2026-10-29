import CoreGraphics
import Testing
@testable import ZenitPDFAppKit

/// Zooming keeps the page point under the pointer under the pointer.
///
/// Every zoom used to land the view towards the top-left corner, when the point held under the
/// pointer is exactly where a finished zoom must land.
///
/// The cause was one subtraction. `NSClipView.convert(_:from: nil)` returns a point in the clip
/// view's **bounds**, and a clip view's `bounds.origin` *is* its scroll offset — so the converted
/// point already carries how far the document is scrolled. Subtracting it whole removed the
/// offset a second time and landed the reader `bounds.origin` closer to the top-left corner.
///
/// The tell is in the arithmetic: at scroll origin the error is exactly zero, which is why it
/// survived every check made at the top of a page.
@Suite(.appTierSerialised)
struct ZoomAnchorTests {

    /// The old, wrong formula, kept so the difference can be asserted rather than described.
    private func buggyOrigin(
        anchorInDocumentAfterZoom: CGPoint,
        anchorInClipBounds: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: anchorInDocumentAfterZoom.x - anchorInClipBounds.x,
            y: anchorInDocumentAfterZoom.y - anchorInClipBounds.y
        )
    }

    @Test("At the top-left corner the old formula was already right, which is why nobody saw it")
    func atOriginBothAgree() {
        let after = CGPoint(x: 900, y: 640)
        let inBounds = CGPoint(x: 300, y: 200)   // no scroll, so bounds == visible
        let fixed = ZoomMath.scrollOrigin(
            anchorInDocumentAfterZoom: after,
            anchorInClipBounds: inBounds,
            clipBoundsOrigin: .zero
        )
        #expect(fixed == buggyOrigin(anchorInDocumentAfterZoom: after, anchorInClipBounds: inBounds))
    }

    @Test("Scrolled away from the corner, the old formula is wrong by exactly the scroll offset")
    func errorEqualsTheScrollOffset() {
        let after = CGPoint(x: 1800, y: 1250)
        let scroll = CGPoint(x: 640, y: 480)
        // The pointer sits 300 × 200 into the visible rectangle; converted into clip bounds that
        // is the scroll offset plus that.
        let inBounds = CGPoint(x: scroll.x + 300, y: scroll.y + 200)

        let fixed = ZoomMath.scrollOrigin(
            anchorInDocumentAfterZoom: after,
            anchorInClipBounds: inBounds,
            clipBoundsOrigin: scroll
        )
        let buggy = buggyOrigin(anchorInDocumentAfterZoom: after, anchorInClipBounds: inBounds)

        #expect(fixed == CGPoint(x: after.x - 300, y: after.y - 200))
        // The old result is short by the whole scroll offset, in both axes — towards the corner.
        #expect(buggy.x == fixed.x - scroll.x)
        #expect(buggy.y == fixed.y - scroll.y)
    }

    @Test("The further the reader has scrolled, the worse the old formula got")
    func errorGrowsWithScroll() {
        let after = CGPoint(x: 2000, y: 1500)
        var previousError: CGFloat = -1
        for offset in stride(from: CGFloat(0), through: 2000, by: 400) {
            let scroll = CGPoint(x: offset, y: offset)
            let inBounds = CGPoint(x: scroll.x + 120, y: scroll.y + 90)
            let fixed = ZoomMath.scrollOrigin(
                anchorInDocumentAfterZoom: after,
                anchorInClipBounds: inBounds,
                clipBoundsOrigin: scroll
            )
            let buggy = buggyOrigin(anchorInDocumentAfterZoom: after, anchorInClipBounds: inBounds)
            let error = fixed.x - buggy.x
            #expect(error >= previousError, "the error should grow with the scroll offset")
            previousError = error
        }
        #expect(previousError == 2000, "at a 2000 pt scroll the old formula was 2000 pt out")
    }

    @Test("The anchor's position inside the visible rectangle is what decides the new origin")
    func onlyThePositionInsideTheVisibleRectMatters() {
        // Two very different scroll offsets, same pointer position within the window: the same
        // page point must land under it either way.
        let after = CGPoint(x: 1000, y: 700)
        let a = ZoomMath.scrollOrigin(
            anchorInDocumentAfterZoom: after,
            anchorInClipBounds: CGPoint(x: 0 + 250, y: 0 + 175),
            clipBoundsOrigin: .zero
        )
        let b = ZoomMath.scrollOrigin(
            anchorInDocumentAfterZoom: after,
            anchorInClipBounds: CGPoint(x: 3333 + 250, y: 1111 + 175),
            clipBoundsOrigin: CGPoint(x: 3333, y: 1111)
        )
        #expect(a == b)
        #expect(a == CGPoint(x: 750, y: 525))
    }
}
