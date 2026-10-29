import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Bug hunt 2: cursor resolution and markup geometry.
@Suite("Fix2 tool cursor and geometry")
struct Fix2ToolGeometryTests {

    /// BH-281. Old output: `resolve(tool: .zoom, setMode: .place, hasArmedPreset: true)` was
    /// `.place` — the stamp-badge cursor over a click that zooms.
    @Test("Zoom and Pan keep their cursor over an armed preset")
    func zoomAndPanOwnTheClick() {
        for mode in [ToolSetMode.apply, .place, .draw] {
            #expect(CanvasCursorKind.resolve(tool: .zoom, setMode: mode, hasArmedPreset: true) == .zoom)
            #expect(CanvasCursorKind.resolve(tool: .pan, setMode: mode, hasArmedPreset: true) == .pan)
        }
        #expect(CanvasCursorKind.resolve(tool: .select, setMode: .apply, hasArmedPreset: true) == .apply)
    }

    /// BH-282. Old output: for a clockwise square every scallop apex lay inside the square.
    @Test("Cloud scallops bulge outward whichever way the ring was drawn")
    func cloudScallopsBulgeOutward() {
        let ccw = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0),
                   PDFPointValue(x: 100, y: 100), PDFPointValue(x: 0, y: 100)]
        let cw = Array(ccw.reversed())
        for ring in [ccw, cw] {
            let outline = ZenitMarkupGeometry.cloudOutline(ring, radius: 10)
            // Every point is on or outside the square, and some are clearly outside.
            let inside = outline.filter { $0.x > 0.5 && $0.x < 99.5 && $0.y > 0.5 && $0.y < 99.5 }
            #expect(inside.isEmpty, "\(inside.count) scallop points inside the ring")
            #expect(outline.contains { $0.y < -5 || $0.x > 105 })
        }
    }

    /// BH-797. Old output: `defaultTextBox(at: (50, 500))` spanned y 500…519.2, entirely above
    /// the click, while its contract puts the click at the box's top-left.
    @Test("A click's text box hangs below the click")
    func textBoxTopLeftIsTheClick() {
        let box = ZenitMarkupGeometry.defaultTextBox(at: PDFPointValue(x: 50, y: 500), fontSize: 12)
        #expect(box.minX == 50)
        #expect(abs((box.minY + box.size.height) - 500) < 1e-9)
    }
}
