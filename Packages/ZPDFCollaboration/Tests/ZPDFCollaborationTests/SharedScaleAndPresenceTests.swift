import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFCollaboration

/// NL-COLLAB-12, round 2: scale changes are operations, merged last-writer-wins per page; presence
/// says where each person is looking; a watcher can tell someone wrote without reading.
@Suite("Shared Review Folder: scales, presence, watching")
struct SharedScaleAndPresenceTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let metric = ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre, angle: .degree, precision: .decimalPlaces(2))

    /// 1:50 at 72 pt/in: 0.0254 / 72 × 50 m per point = 0.017638… m — written as the exact ratio.
    static func ratio(_ denominator: Decimal, label: String) -> SharedPageScale {
        let metresPerPoint = Decimal(string: "0.0254")! / 72 * denominator
        return SharedPageScale(pageID: page, matrix: AffineScaleMatrix(a: metresPerPoint, b: 0, c: 0, d: metresPerPoint),
                               units: metric, label: label, source: .preset)
    }

    static func operation(_ payload: ReviewOperation.Payload, millis: Int64, node: String) -> ReviewOperation {
        ReviewOperation(clock: HLCTimestamp(physicalMillis: millis, counter: 0, node: node), participantID: node, authorName: node, payload: payload)
    }

    @Test("Two scale changes to one page: the later clock stands, whichever log is read first")
    func lastScaleWins() {
        let a = Self.operation(.setPageScale(Self.ratio(50, label: "1:50")), millis: 10, node: "a")
        let b = Self.operation(.setPageScale(Self.ratio(100, label: "1:100")), millis: 20, node: "b")
        #expect(MergedReview.merge([a, b]).pageScales[Self.page]?.label == "1:100")
        #expect(MergedReview.merge([b, a]) == MergedReview.merge([a, b]))
    }

    @Test("A scale changed here is published once; one that measures like the agreed one is not")
    func publishOnlyWhatChanged() {
        var base = SharedReviewBase(participantID: "a")
        let fifty = Self.ratio(50, label: "1:50")
        let first = SharedReviewSyncPlanner.operationsToPublish(
            local: [], localReplies: [], base: &base, observed: .zero, participantID: "a", authorName: "Ada", now: Self.t0,
            localScales: [fifty])
        #expect(first.map(\.payload) == [.setPageScale(fifty)])
        base.pageScales[Self.page] = fifty
        var restamped = fifty
        restamped.source = .inherited   // another identity or source on this machine, same measure
        let again = SharedReviewSyncPlanner.operationsToPublish(
            local: [], localReplies: [], base: &base, observed: .zero, participantID: "a", authorName: "Ada", now: Self.t0,
            localScales: [restamped])
        #expect(again.isEmpty)
    }

    @Test("The merged scale reaches a machine that measures by another; one already alike is left alone")
    func localChangesCarryScales() {
        var merged = MergedReview()
        merged.pageScales[Self.page] = Self.ratio(100, label: "1:100")
        let other = SharedReviewSyncPlanner.localChanges(merged: merged, local: [], localReplies: [], known: [],
                                                          localScales: [Self.ratio(50, label: "1:50")])
        #expect(other.scales.map(\.label) == ["1:100"])
        let alike = SharedReviewSyncPlanner.localChanges(merged: merged, local: [], localReplies: [], known: [],
                                                          localScales: [Self.ratio(100, label: "1:100")])
        #expect(alike.scales.isEmpty && alike.isEmpty)
        // Installed under the local identity, one version on.
        let local = ScaleTransform(id: ScaleID(UUID()), pageID: Self.page, version: 3, matrix: Self.ratio(50, label: "").matrix,
                                   units: Self.metric, source: .preset, label: "1:50")
        let installed = Self.ratio(100, label: "1:100").transform(replacing: local)
        #expect(installed.id == local.id && installed.version == 4 && installed.label == "1:100")
    }

    @Test("A base written before scales were shared still reads")
    func oldBaseDecodes() throws {
        let base = SharedReviewBase(participantID: "a")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] ?? [:]
        object["pageScales"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SharedReviewBase.self, from: old)
        #expect(decoded.pageScales.isEmpty)
    }

    @Test("Presence says the sheet and the selection; a file cannot speak for someone else; an old file still reads")
    func presence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-presence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shared = SharedReviewFolder(url: folder)
        try shared.prepare(projectID: "p", projectName: "Tower", now: Self.t0)
        try shared.writePresence(.init(participantID: "a", name: "Ada", lastSync: Self.t0, pageLabel: "A-201", selectedCount: 2))
        // A file named for "b" that claims to be "a" is not believed.
        let impostor = try JSONEncoder().encode(SharedReviewFolder.Presence(participantID: "a", name: "Mallory", lastSync: Self.t0))
        try impostor.write(to: folder.appendingPathComponent("participants/b.presence"))
        // A round-1 file has no sheet or selection.
        try Data(#"{"participantID":"c","name":"Cy","lastSync":"2026-09-20T10:00:00Z"}"#.utf8)
            .write(to: folder.appendingPathComponent("participants/c.presence"))
        let presences = shared.presences()
        #expect(presences.map(\.name) == ["Ada", "Cy"])
        #expect(presences.first?.pageLabel == "A-201" && presences.first?.selectedCount == 2)
        #expect(presences.last?.pageLabel == nil)
    }

    @Test("The fingerprint changes when someone else writes, and not when this participant does")
    func fingerprint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shared = SharedReviewFolder(url: folder)
        try shared.prepare(projectID: "p", projectName: "Tower", now: Self.t0)
        let before = shared.fingerprint(excluding: "a")
        try shared.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1, node: "a")], participant: "a")
        #expect(shared.fingerprint(excluding: "a") == before, "my own write is not news")
        try shared.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 2, node: "b")], participant: "b")
        #expect(shared.fingerprint(excluding: "a") != before)
    }
}
