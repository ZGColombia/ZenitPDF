#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import ZPDFDesignSystem
import ZPDFUIPresentation

/// NL-MARKUP-01 (LT3-01): the palette that replaced the invisible colour well, its inks, the
/// recent colours and the colour-panel route. None of these tests creates or shows a window
/// or the shared colour panel.
@MainActor
final class ColourPaletteTests: XCTestCase {

    func testPaletteInksPassTheSelfCheck() {
        let report = ZPDFSelfCheck.verifyMarkupPalette()
        XCTAssertTrue(report.passed, report.failures.map(\.description).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(report.assertionCount, ZPDFMarkupInk.allCases.count + 5)
    }

    func testFirstThreeInksAreTheDesignSystemInkTokens() {
        XCTAssertEqual(ZPDFMarkupInk.blue.rgba, ZPDFColor.rgba(.inkBlue, .light))
        XCTAssertEqual(ZPDFMarkupInk.red.rgba, ZPDFColor.rgba(.inkRed, .light))
        XCTAssertEqual(ZPDFMarkupInk.green.rgba, ZPDFColor.rgba(.inkGreen, .light))
    }

    /// The default markup ink (`ToolStyleSelection.zenitInk`, #1A55CF) is the palette's Blue,
    /// so a fresh markup shows as selected in the palette.
    func testZenitInkIsThePaletteBlue() {
        XCTAssertEqual(ZPDFMarkupInk.matching(ToolStyleSelection.zenitInk.stroke), .blue)
        XCTAssertEqual(ZPDFMarkupInk.matching(ToolStyleSelection.zenitInk.fill), .blue, "a 20 % fill still reads as its hue")
        XCTAssertNil(ZPDFMarkupInk.matching(nil))
    }

    func testSameHueIgnoresAlphaAndRoundTripNoise() {
        let ink = ZPDFMarkupInk.red.color
        let roundTripped = ColorRGBA(nsColor: ink.nsColor)
        XCTAssertTrue(ZPDFColourMath.sameHue(ink, roundTripped))
        var translucent = ink
        translucent.alpha = 0.2
        XCTAssertTrue(ZPDFColourMath.sameHue(ink, translucent))
        XCTAssertFalse(ZPDFColourMath.sameHue(ink, ZPDFMarkupInk.orange.color))
        XCTAssertEqual(ZPDFColourMath.opaque(translucent).alpha, 1)
    }

    func testRecentColoursAreNewestFirstDedupedAndCapped() {
        let recents = ZPDFRecentColours()
        recents.record(ZPDFMarkupInk.red.color)
        recents.record(ZPDFMarkupInk.blue.color)
        var translucentRed = ZPDFMarkupInk.red.color
        translucentRed.alpha = 0.3
        recents.record(translucentRed)
        XCTAssertEqual(recents.colours.count, 2)
        XCTAssertTrue(ZPDFColourMath.sameHue(recents.colours[0], ZPDFMarkupInk.red.color))
        XCTAssertEqual(recents.colours[0].alpha, 1, "a recent colour is offered opaque")
        for ink in ZPDFMarkupInk.allCases { recents.record(ink.color) }
        XCTAssertEqual(recents.colours.count, ZPDFRecentColours.capacity)
        // The newest is the last ink recorded (round 2 appended navy and olive after black).
        XCTAssertTrue(ZPDFColourMath.sameHue(recents.colours[0], ZPDFMarkupInk.allCases.last!.color))
    }

    /// Stored through the storage it was given and read back by a fresh store. No defaults
    /// domain is named: the test tier keeps its hands off `cfprefsd`, so a test run never
    /// leaves preference files behind.
    func testRecentColoursPersistOnlyThroughTheInjectedStorage() {
        final class Box { var data: Data? }
        let box = Box()
        ZPDFRecentColours(load: { box.data }, save: { box.data = $0 }).record(ZPDFMarkupInk.teal.color)
        XCTAssertNotNil(box.data)
        let reread = ZPDFRecentColours(load: { box.data }, save: { box.data = $0 })
        XCTAssertEqual(reread.colours.count, 1)
        XCTAssertTrue(ZPDFColourMath.sameHue(reread.colours[0], ZPDFMarkupInk.teal.color))
        XCTAssertTrue(ZPDFRecentColours().colours.isEmpty, "the default store is in memory")
        XCTAssertTrue(ZPDFRecentColours(defaults: nil).colours.isEmpty, "no defaults, no persistence")
    }

    // MARK: Colour panel route

    final class FakeSurface: ZPDFColourPanelSurface {
        var colour = ColorRGBA(red: 1, green: 1, blue: 1)
        var target: AnyObject?
        var action: Selector?
        var shown = 0
        var hidden = 0
        var prepared = 0
        func prepare() { prepared += 1 }
        func connect(target: AnyObject?, action: Selector?) {
            self.target = target
            self.action = action
        }
        func show() { shown += 1 }
        func hide() { hidden += 1 }
    }

    func testAttachSeedsConnectsAndShowsWithoutForwardingTheSeed() {
        let surface = FakeSurface()
        let controller = ZPDFColourPanelController(surface: { surface })
        let owner = NSObject()
        var received: [ColorRGBA] = []
        controller.attach(owner: owner, initial: ZPDFMarkupInk.green.color) { received.append($0) }
        XCTAssertEqual(surface.shown, 1)
        XCTAssertEqual(surface.prepared, 1)
        XCTAssertTrue(surface.target === controller)
        XCTAssertNotNil(surface.action)
        XCTAssertTrue(ZPDFColourMath.sameHue(surface.colour, ZPDFMarkupInk.green.color))
        // The seed coming back is not a pick (CR-117).
        controller.deliver(ZPDFMarkupInk.green.color)
        XCTAssertTrue(received.isEmpty)
        // A real pick is forwarded, opaque.
        var picked = ZPDFMarkupInk.purple.color
        picked.alpha = 0.5
        controller.deliver(picked)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(ZPDFColourMath.sameHue(received[0], ZPDFMarkupInk.purple.color))
        XCTAssertEqual(received[0].alpha, 1)
    }

    /// The panel's action really reaches the controller: fire the selector it was given.
    func testThePanelActionSelectorDeliversTheSurfaceColour() throws {
        let surface = FakeSurface()
        let controller = ZPDFColourPanelController(surface: { surface })
        let owner = NSObject()
        var received: [ColorRGBA] = []
        controller.attach(owner: owner, initial: ZPDFMarkupInk.blue.color) { received.append($0) }
        surface.colour = ZPDFMarkupInk.magenta.color
        let action = try XCTUnwrap(surface.action)
        let target = try XCTUnwrap(surface.target as? NSObject)
        XCTAssertTrue(target.responds(to: action))
        _ = target.perform(action, with: nil)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(ZPDFColourMath.sameHue(received[0], ZPDFMarkupInk.magenta.color))
    }

    func testDetachUnhooksAndHidesAndOnlyTheOwnerCanDetach() {
        let surface = FakeSurface()
        let controller = ZPDFColourPanelController(surface: { surface })
        let owner = NSObject()
        let stranger = NSObject()
        var received = 0
        controller.attach(owner: owner, initial: nil) { _ in received += 1 }
        controller.detach(owner: stranger)
        XCTAssertTrue(controller.isAttached(owner))
        XCTAssertEqual(surface.hidden, 0)
        controller.detach(owner: owner)
        XCTAssertFalse(controller.isAttached(owner))
        XCTAssertNil(surface.target)
        XCTAssertEqual(surface.hidden, 1)
        controller.deliver(ZPDFMarkupInk.red.color)
        XCTAssertEqual(received, 0, "a detached panel writes nothing")
    }

    func testASecondOwnerTakesThePanelOver() {
        let surface = FakeSurface()
        let controller = ZPDFColourPanelController(surface: { surface })
        let first = NSObject()
        let second = NSObject()
        var firstCount = 0
        var secondCount = 0
        controller.attach(owner: first, initial: nil) { _ in firstCount += 1 }
        controller.attach(owner: second, initial: ZPDFMarkupInk.black.color) { _ in secondCount += 1 }
        controller.deliver(ZPDFMarkupInk.red.color)
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
        controller.detach(owner: first)
        XCTAssertTrue(controller.isAttached(second), "the old owner going away does not close the new owner's panel")
    }

    // MARK: Palette view

    func testPaletteMarkerIdentifiersAreUnique() {
        var ids = ZPDFMarkupInk.allCases.map(ZPDFColourPalette.markerIdentifier(for:))
        ids += (0..<ZPDFRecentColours.capacity).map(ZPDFColourPalette.recentMarkerIdentifier(index:))
        ids += [ZPDFColourPalette.moreMarkerIdentifier, ZPDFColourPalette.noneMarkerIdentifier]
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testPaletteWidthFitsTheGrid() {
        XCTAssertEqual(
            ZPDFColourPalette.width,
            5 * ZPDFColourPalette.cell + 4 * ZPDFColourPalette.gap + 2 * ZPDFSpacing.l
        )
        XCTAssertGreaterThanOrEqual(ZPDFColourPalette.cell, ZPDFSpacing.Control.minimumHitTarget)
    }

    /// The marker never takes a click, so the control drawn over it always does.
    func testMarkerViewNeverHitTests() {
        let marker = ZPDFViewMarker.MarkerView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertNil(marker.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(marker.acceptsFirstResponder)
    }
}
#endif
