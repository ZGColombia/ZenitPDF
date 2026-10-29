import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// CR-2: `placedPoints` and `placedSequences` are a pair; ⌥-unplace and raw appends used
/// to touch only the points, and the commit fence then sliced past the end.
@Suite("Commit fence keeps its two lists paired")
struct FencePairingTests {

    @MainActor
    private func makeEnvironment() async throws -> AppCoreEnvironment {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        return environment
    }

    @Test("Un-placing count marks then fencing a late click neither traps nor mis-assigns")
    @MainActor
    func unplaceThenFence() async throws {
        let env = try await makeEnvironment()
        let m = env.measurement
        m.activate(kind: .count)
        for p in [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 200, y: 100), PDFPointValue(x: 300, y: 100)] {
            m.placePoint(p)
        }
        await m.settlePlacements()
        #expect(m.removePoint(near: PDFPointValue(x: 100, y: 100), tolerance: 1))
        #expect(m.removePoint(near: PDFPointValue(x: 200, y: 100), tolerance: 1))
        #expect(m.placedPoints.count == 1)
        let fence = m.beginCommitFence()
        m.placePoint(PDFPointValue(x: 400, y: 100))   // after the fence: next measurement's
        await m.settleCommitFence(fence)              // used to be placedPoints[3...] on 2 → trap
        #expect(m.placedPoints.count == 1, "the pre-fence mark stays; the late click is carried")
        m.releaseCommitFence(fence)
        #expect(m.placedPoints.count == 2, "the carried click joins the next measurement")
    }

    @Test("Raw appends stay paired with the fence too")
    @MainActor
    func rawAppendsArePaired() async throws {
        let env = try await makeEnvironment()
        let m = env.measurement
        m.activate(kind: .area)
        m.appendRawPoints([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0), PDFPointValue(x: 50, y: 50), PDFPointValue(x: 0, y: 50)])
        let fence = m.beginCommitFence()
        m.placePoint(PDFPointValue(x: 500, y: 500))
        await m.settleCommitFence(fence)
        #expect(m.placedPoints.count == 4, "the four raw corners commit; the late click does not steal or lose one")
        m.releaseCommitFence(fence)
        #expect(m.placedPoints.count == 5)
    }
}
