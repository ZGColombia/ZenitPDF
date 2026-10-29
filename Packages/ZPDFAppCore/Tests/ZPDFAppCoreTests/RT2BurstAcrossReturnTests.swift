import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// RT-2: machine-speed click bursts through the real event
/// queue, about 10 ms apart, could interleave vertices across a Return commit; at human speed
/// every measurement was right.
///
/// Reproduced here at the presenter, with nothing but synthetic calls in the order a burst makes
/// them and no settling between them — exactly what the window's Finish does
/// (`ProjectWindowController.performShell`): take the commit fence synchronously in the key
/// handler's turn, then, in a task, settle the snap queue up to the fence, commit, and release the
/// fence so the clicks made after Return open the next measurement.
@Suite("RT-2: a burst of clicks across Return keeps every vertex in its own measurement")
struct RT2BurstAcrossReturnTests {

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

    /// Return, as the window performs it: the fence now, the commit once the queue has drained.
    @MainActor
    private func pressReturn(_ m: AppMeasurementToolPresenter) -> Task<Void, Never> {
        let fence = m.beginCommitFence()
        return Task { @MainActor in
            await m.settleCommitFence(fence)
            m.commitActiveMeasurement()
            m.releaseCommitFence(fence)
        }
    }

    private static func square(at x: Double, _ y: Double) -> [PDFPointValue] {
        [
            PDFPointValue(x: x, y: y), PDFPointValue(x: x + 100, y: y),
            PDFPointValue(x: x + 100, y: y + 100), PDFPointValue(x: x, y: y + 100)
        ]
    }

    /// The outer ring each committed area carries, in commit order.
    private static func rings(_ records: [MarkupRecord]) -> [[PDFPoint]] {
        records.map { $0.geometry?.polygons.first?.outer.points ?? $0.geometry?.points ?? [] }
    }

    private static func pdf(_ points: [PDFPointValue]) -> [PDFPoint] { points.map { PDFPoint(shown: $0) } }

    @Test("Four clicks, Return, four clicks: the second four open the next area")
    @MainActor
    func oneReturnInsideTheBurst() async throws {
        let env = try await makeEnvironment()
        let m = env.measurement
        var records: [MarkupRecord] = []
        let forward = m.onCommit
        m.onCommit = { records.append($0); forward?($0) }
        m.activate(kind: .area)
        let a = Self.square(at: 100, 100), b = Self.square(at: 500, 500)

        for point in a { m.placePoint(point) }
        let first = pressReturn(m)
        for point in b { m.placePoint(point) }
        await first.value
        await m.settlePlacements()

        #expect(Self.rings(records) == [Self.pdf(a)], "committed: \(Self.rings(records))")
        #expect(m.placedPoints == b, "the next area holds the four after-Return clicks: \(m.placedPoints)")
    }

    /// The burst RT-2 describes: a second Return arrives while the first commit is still waiting
    /// for its snaps. Old output: the second `beginCommitFence()` overwrote the first fence, so the
    /// first Finish's settle found "not my fence", cut nothing and committed A1–A4 + B1–B4 as one
    /// eight-vertex area; the second Finish then had nothing to commit and B vanished — vertices of
    /// the next measurement interleaved into the previous one across Return.
    @Test("Four clicks, Return, four clicks, Return — before the first commit lands: two areas, four vertices each")
    @MainActor
    func secondReturnBeforeTheFirstLands() async throws {
        let env = try await makeEnvironment()
        let m = env.measurement
        var records: [MarkupRecord] = []
        let forward = m.onCommit
        m.onCommit = { records.append($0); forward?($0) }
        m.activate(kind: .area)
        let a = Self.square(at: 100, 100), b = Self.square(at: 500, 500)

        for point in a { m.placePoint(point) }
        let first = pressReturn(m)
        for point in b { m.placePoint(point) }
        let second = pressReturn(m)
        await first.value
        await second.value
        await m.settlePlacements()

        #expect(Self.rings(records) == [Self.pdf(a), Self.pdf(b)], "committed: \(Self.rings(records))")
        #expect(m.placedPoints.isEmpty, "nothing left over: \(m.placedPoints)")
    }

    /// Three areas and two clicks of a fourth in one uninterrupted burst, every Return issued
    /// before any snap has resolved. Each commit holds exactly its own clicks, in click order.
    @Test("A long burst — three Returns before anything lands — keeps every vertex with its own area, in order")
    @MainActor
    func threeReturnsInOneBurst() async throws {
        let env = try await makeEnvironment()
        let m = env.measurement
        var records: [MarkupRecord] = []
        let forward = m.onCommit
        m.onCommit = { records.append($0); forward?($0) }
        m.activate(kind: .area)
        let shapes = [Self.square(at: 100, 100), Self.square(at: 300, 300), Self.square(at: 500, 500)]
        let tail = Array(Self.square(at: 700, 700).prefix(2))

        var finishes: [Task<Void, Never>] = []
        for shape in shapes {
            for point in shape { m.placePoint(point) }
            finishes.append(pressReturn(m))
        }
        for point in tail { m.placePoint(point) }
        for finish in finishes { await finish.value }
        await m.settlePlacements()

        #expect(Self.rings(records) == shapes.map(Self.pdf), "committed: \(Self.rings(records))")
        #expect(m.placedPoints == tail, "the fourth area holds its two clicks: \(m.placedPoints)")
    }

    /// A Finish waiting for an earlier Return's commit must not wait forever when the
    /// measurement is cancelled under it: the cancel drops every fence and wakes the waiters.
    @Test("Escape while two Finishes are queued: both end, nothing is committed", .timeLimit(.minutes(1)))
    @MainActor
    func cancelWakesAQueuedFinish() async throws {
        let env = try await makeEnvironment()
        let m = env.measurement
        var records: [MarkupRecord] = []
        let forward = m.onCommit
        m.onCommit = { records.append($0); forward?($0) }
        m.activate(kind: .area)

        for point in Self.square(at: 100, 100) { m.placePoint(point) }
        let first = pressReturn(m)
        for point in Self.square(at: 500, 500) { m.placePoint(point) }
        let second = pressReturn(m)
        m.cancelActiveMeasurement()
        await first.value
        await second.value
        await m.settlePlacements()

        #expect(records.isEmpty, "a cancelled burst commits nothing: \(Self.rings(records))")
        #expect(m.placedPoints.isEmpty)
    }
}
