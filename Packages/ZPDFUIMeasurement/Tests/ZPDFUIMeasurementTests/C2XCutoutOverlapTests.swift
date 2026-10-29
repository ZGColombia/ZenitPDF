import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Quality-loop iteration 7, cycle 2 follow-up X-cutout-ui, the input half: the engine accepts a
/// cutout that only partly overlaps its area and subtracts the part inside (ADR-0015); the input
/// flow refused it with a containment rule of its own. The flow now refuses only a first point in
/// no area; whether a finished cutout overlaps its area at all is the engine's verdict, given by
/// the application tier's measurement presenter (ZPDFAppCore `C2XCutoutOverlapPresenterTests`).
@MainActor
@Suite("X-cutout-ui: a cutout partly over its area is not refused by the input flow")
struct C2XCutoutOverlapTests {

    private static func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private static let slabID = UUID(uuidString: "C2C2C2C2-0000-4000-8000-000000000001") ?? UUID()

    /// The 400 × 300 pt area (100, 100)–(500, 400).
    private static let slab = CutoutParentCandidate(
        markupID: slabID,
        outerRing: [p(100, 100), p(500, 100), p(500, 400), p(100, 400)],
        subject: "Slab"
    )

    private static func isRefusal(_ effect: MeasurementInputEffect) -> Bool {
        if case .rejectFinish = effect { return true }
        return false
    }

    /// A Polygon Cutout started inside the slab, (120, 200), with its other corners past the
    /// slab's left edge: the engine accepts it and subtracts the part inside.
    ///
    /// Old output: the second click, (50, 200), was refused with "This point is outside Slab.
    /// Every cutout corner must stay inside the area it subtracts from." — a `rejectFinish`, no
    /// point placed, and the cutout could not be drawn at all.
    @Test("A polygon cutout partly over its area is drawn and committed with no refusal")
    func partialPolygonCutoutCommits() {
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.polygonCutout))
        machine.handle(.setCutoutParents([Self.slab]))
        var effects: [MeasurementInputEffect] = []
        for point in [Self.p(120, 200), Self.p(50, 200), Self.p(50, 300), Self.p(120, 300)] {
            effects += machine.handle(.placePoint(point))
        }
        #expect(!effects.contains(where: Self.isRefusal), "\(effects)")
        #expect(machine.state.cutoutRefusal == nil)
        #expect(machine.state.vertices == [Self.p(120, 200), Self.p(50, 200), Self.p(50, 300), Self.p(120, 300)])
        #expect(machine.state.cutoutParent?.markupID == Self.slabID)

        let finished = machine.handle(.finish)
        #expect(!finished.contains(where: Self.isRefusal), "\(finished)")
        #expect(finished.contains(.commitCutout(parentMarkupID: Self.slabID)))
    }

    /// An Ellipse Cutout whose box (50, 200)–(150, 300) hangs over the slab's left edge; its centre
    /// (100, 250) is on that edge, so the slab is its parent.
    ///
    /// Old output: refused at the second corner with "This opening reaches outside Slab. An
    /// elliptical cutout must fit inside the area it subtracts from."
    @Test("An elliptical cutout partly over its area is committed with no refusal")
    func partialEllipseCutoutCommits() {
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.ellipseCutout))
        machine.handle(.setCutoutParents([Self.slab]))
        machine.handle(.placePoint(Self.p(50, 200)))
        let effects = machine.handle(.placePoint(Self.p(150, 300)))
        #expect(!effects.contains(where: Self.isRefusal), "\(effects)")
        #expect(effects.contains(.commitCutout(parentMarkupID: Self.slabID)))
    }

    /// What the flow still refuses on its own: a first point in no area, which leaves the cutout
    /// with no parent to be measured against. Unchanged.
    @Test("A cutout whose first point is in no area is still refused at that point")
    func firstPointInNoAreaIsRefused() {
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.polygonCutout))
        machine.handle(.setCutoutParents([Self.slab]))
        let effects = machine.handle(.placePoint(Self.p(700, 700)))
        #expect(effects.contains(.rejectFinish(CutoutRefusalReason.noAreaUnderPoint.message)))
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.cutoutParent == nil)
    }
}
