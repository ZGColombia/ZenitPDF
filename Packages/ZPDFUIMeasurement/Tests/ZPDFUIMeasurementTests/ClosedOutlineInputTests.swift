import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Closed-outline tools finish the same way, and the count symbol comes from the configuration.
@Suite("Closed outlines and count symbols")
struct ClosedOutlineInputTests {

    private func machine() -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(initialCursor: PDFPointValue(x: 100, y: 100))
        )
    }

    /// R-143. Volume's base is an outline the canvas draws closed and filled, but
    /// `closesOnFirstVertex` left it out. Old output: the click at (2, 3) — inside the 6 pt close
    /// tolerance of (0, 0) — appended a fourth vertex stacked on the first, with no commit.
    @Test("Clicking the first vertex closes a Volume outline instead of stacking a vertex")
    func volumeClosesOnFirstVertex() {
        var flow = machine()
        flow.handle(.armTool(.volume))
        flow.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        flow.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        flow.handle(.placePoint(PDFPointValue(x: 100, y: 100)))
        flow.handle(.pointerMoved(PDFPointValue(x: 2, y: 3)))
        #expect(flow.state.firstVertexCloseTarget(configuration: flow.configuration) == PDFPointValue(x: 0, y: 0))

        let effects = flow.handle(.placePointAtCursor)
        #expect(effects.contains(.commitMeasurement))
        #expect(!effects.contains { if case .placePoint = $0 { return true } else { return false } })
        #expect(flow.state.vertices.isEmpty)
        #expect(flow.state.phase == .armed)
    }

    /// Every polygon tool the canvas draws as a closed outline closes on its first vertex, so
    /// the affordance and the drawing agree.
    @Test("Every closed-outline polygon tool closes on its first vertex")
    func closedOutlineToolsClose() {
        for kind in [MeasurementKind.area, .volume, .polygonCutout, .perimeter, .trueSlopedArea] {
            let gesture = ZenitToolMode.measure(kind).gesture
            #expect(gesture.closesOutline, "\(kind)")
            #expect(kind.closesOnFirstVertex, "\(kind)")
            #expect(gesture.closesOnFirstVertex, "\(kind)")
        }
        #expect(!MeasurementKind.polylength.closesOnFirstVertex)
        #expect(!MeasurementKind.wallArea.closesOnFirstVertex)
    }

    /// S-095: the closed outline and the close-on-first-vertex rule are one fact, for every
    /// kind — not a hard-coded list that a new kind can be missing from. Before, `closesOutline`
    /// was a second literal list beside `closesOnFirstVertex`, and the test above was a third,
    /// so a kind added to only one of them still passed.
    @Test("For every measurement kind, the outline closes exactly when the first vertex closes it")
    func closesOutlineFollowsTheCloseRule() {
        for kind in MeasurementKind.allCases {
            let gesture = ZenitToolMode.measure(kind).gesture
            #expect(gesture.closesOutline == kind.closesOnFirstVertex, "\(kind)")
            #expect(gesture.closesOnFirstVertex == kind.closesOnFirstVertex, "\(kind)")
        }
    }

    /// IM-020, kept after R-141 removed the options model that used to build the configuration:
    /// the symbol in the input configuration is the one the running total draws.
    @Test("The configured count symbol is the one the running total carries")
    func configuredCountSymbol() {
        var configuration = MeasurementInputConfiguration.standard
        configuration.countSymbol = .star
        var flow = MeasurementInputStateMachine(configuration: configuration)
        flow.handle(.armTool(.count))
        flow.handle(.placePoint(PDFPointValue(x: 1, y: 1)))
        #expect(flow.state.countSymbol == .star)
        #expect(flow.state.vertices.count == 1)
    }
}
