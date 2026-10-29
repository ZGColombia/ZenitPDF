import AppKit
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// The chip host on its own. The whole-lens layout check needs a window, so it lives in the
/// application tier's serialised suites (MeasurementLoupeAnimationTests), never here.
@MainActor
struct MeasurementLoupeIsolationTests {
    @Test("Chip sizing follows its visible label and vanishes with no candidate")
    func chipSizingAndReducedMotion() {
        let snap = SnapFeedbackSnapshot(kind: .endpoint, pagePoint: PDFPointValue(x: 1, y: 2),
                                        sourceLabel: "wall", pageID: UUID())
        let host = MeasurementLoupeChipHost(snap: nil, reduceMotion: true)
        #expect(host.chipSize == .zero)
        host.update(snap: snap, reduceMotion: true)
        #expect(host.chipSize.width > 0 && host.chipSize.height > 0)
        #expect(host.chipSize == host.fittingSize)
        let size = host.chipSize
        host.update(snap: snap, reduceMotion: true)
        #expect(host.chipSize == size)
        host.update(snap: nil, reduceMotion: true)
        #expect(host.chipSize == .zero)
        #expect(host.hitTest(.zero) == nil)
    }
}
