import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence

/// NL-COLLAB-09: XFDF export and import.
@Suite("XFDF review exchange")
struct XFDFTests {

    @MainActor
    private func populated() async throws -> (AppCoreEnvironment, ProjectDatabaseActor, URL, [MarkupID]) {
        let (a, db, dir) = try await SharedReviewSyncTests.machine()
        var cloud = SharedReviewSyncTests.cloud()
        cloud.comment = "Check <this> & that"
        cloud.status = .inProgress
        var slab = SharedReviewSyncTests.area(width: 200)
        slab.status = .accepted
        let pageID = SharedReviewSyncTests.pageID
        let arrow = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: SharedReviewSyncTests.documentID, pageID: pageID, kind: .arrow, author: "Bo",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 10, y: 20), PDFPoint(x: 90.5, y: 80.25)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let box = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: SharedReviewSyncTests.documentID, pageID: pageID, kind: .text, author: "Ada",
            caption: "EXISTING WALL",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 500, y: 500), PDFPoint(x: 600, y: 530)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        for record in [cloud, slab, arrow, box] { try await a.commands.perform(.addMarkup(record)) }
        a.review.actorNameProvider = { "Cy" }
        #expect(a.review.addReply("Agreed", to: cloud.id.rawValue) != nil)
        await a.review.settle()
        return (a, db, dir, [cloud.id, slab.id, arrow.id, box.id])
    }

    @Test("Export → import into an empty copy reproduces geometry, author, note, status and replies; re-export is identical")
    @MainActor
    func roundTrip() async throws {
        let (a, dbA, dirA, ids) = try await populated()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let xml = await a.exportXFDF(drawingName: "Plan A-101.pdf", drawingDigest: "abc123")
        let text = String(decoding: xml, as: UTF8.self)
        #expect(text.contains("Check &lt;this&gt; &amp; that"))
        #expect(text.contains(#"state="Accepted" statemodel="Review""#))
        #expect(text.contains(#"intent="PolygonCloud""#))

        let reading = try XFDF.read(xml)
        try XFDF.check(reading, drawingDigest: "ABC123")
        let plan = await b.planXFDFImport(reading)
        #expect(plan.newMarkups.count == 4)
        #expect(plan.replies.count == 1)
        try await b.acceptReviewImport(plan)
        await b.review.settle()
        for id in ids {
            let mine = await a.session.markup(id)
            let theirs = await b.session.markup(id)
            #expect(theirs?.author == mine?.author)
            // The measured slab's note says where its geometry came from (NL-MEASURE-16).
            if id != ids[1] { #expect(theirs?.comment == mine?.comment) }
            #expect(theirs?.status == mine?.status, "\(String(describing: mine?.kind)): status survives (standard state or zenit:status)")
        }
        #expect(await b.session.markup(ids[2])?.geometry?.points == [PDFPoint(x: 10, y: 20), PDFPoint(x: 90.5, y: 80.25)])
        #expect(await b.session.markup(ids[3])?.caption == "EXISTING WALL")
        #expect(b.review.entries.map(\.body) == ["Agreed"])
        #expect(b.review.entries.first?.authorName == "Cy")

        // A measured area on a calibrated sheet arrives as a measurement Zenit measures again at
        // B's own scale (NL-MEASURE-16, which supersedes round 1's "an import never mints a
        // quantity"): the geometry is the file's, the number B's. 200 × 50 pt at 1 pt = 1 cm is
        // 2 m × 0.5 m = 1 m² on both machines, and the capture says it was read from the file.
        let slab = try #require(await b.session.markup(ids[1]))
        #expect(slab.tool == .area)
        #expect(slab.measurement?.values[.planArea]?.value == 1)
        #expect(await a.session.markup(ids[1])?.measurement?.values[.planArea]?.value == 1)
        #expect(slab.measurement?.provenance?.capture.kind == .importedAnnotation)
        #expect(slab.comment == "Measured from a PDF measurement annotation.")

        // Export → import → export: the same XML, line for line, with one deliberate difference
        // set aside — the note the import wrote on the measured slab.
        let again = await b.exportXFDF(drawingName: "Plan A-101.pdf", drawingDigest: "abc123")
        func normalised(_ data: Data) -> [String] {
            String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "<contents>Measured from a PDF measurement annotation.</contents>", with: "")
                .split(separator: "\n").map(String.init).sorted()
        }
        #expect(normalised(again) == normalised(xml))
        try? await dbA.close()
        try? await dbB.close()
    }

    /// The extension namespace URI earlier exports wrote.
    static let earlierZenitNamespace = "https://zenitgroup.com/ns/zenit-review/1"

    @Test("An XFDF written under the earlier extension namespace URI imports exactly as a current one")
    @MainActor
    func earlierNamespaceImports() async throws {
        let (a, dbA, dirA, ids) = try await populated()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let current = String(decoding: await a.exportXFDF(drawingName: "Plan A-101.pdf", drawingDigest: "abc123"), as: UTF8.self)
        #expect(current.contains(#"xmlns:zenit="https://zenitgroup.com.co/ns/zenit-review/1""#))
        let earlier = current.replacingOccurrences(of: XFDF.zenitNamespace, with: Self.earlierZenitNamespace)
        #expect(earlier.contains(#"xmlns:zenit="\#(Self.earlierZenitNamespace)""#))

        // The reader matches the `zenit:` prefix: the drawing digest and every `zenit:status`
        // read the same under either URI.
        let reading = try XFDF.read(Data(earlier.utf8))
        let currentReading = try XFDF.read(Data(current.utf8))
        #expect(reading.drawingDigest == "abc123")
        #expect(reading.annotations == currentReading.annotations)
        #expect(reading.annotations.filter(\.zenitOwned).count == 4)
        #expect(throws: XFDF.XFDFError.otherDrawing(fileDrawing: "Plan A-101.pdf")) {
            try XFDF.check(reading, drawingDigest: "ffff")
        }

        // The cloud's in-progress status has no standard XFDF state; only `zenit:status` carries it.
        let plan = await b.planXFDFImport(reading)
        #expect(plan.newMarkups.count == 4)
        try await b.acceptReviewImport(plan)
        await b.review.settle()
        for id in ids {
            let mine = await a.session.markup(id)
            let theirs = await b.session.markup(id)
            #expect(theirs?.status == mine?.status)
        }
        #expect(await b.session.markup(ids[0])?.status == .inProgress)
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("An XFDF naming another drawing is refused by name; external entities are never resolved")
    func refusalsAndXXE() throws {
        let other = #"<?xml version="1.0"?><xfdf xmlns="http://ns.adobe.com/xfdf/" xmlns:zenit="https://zenitgroup.com.co/ns/zenit-review/1"><f href="Villa.pdf"/><zenit:drawing sha256="ffff"/><annots/></xfdf>"#
        let reading = try XFDF.read(Data(other.utf8))
        #expect(throws: XFDF.XFDFError.otherDrawing(fileDrawing: "Villa.pdf")) {
            try XFDF.check(reading, drawingDigest: "abc123")
        }
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-xxe-\(UUID().uuidString).txt")
        try Data("TOP SECRET".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE xfdf [ <!ENTITY leak SYSTEM "\(secret.absoluteString)"> ]>
        <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots>
        <text page="0" rect="0,0,10,10" name="n1" title="X"><contents>&leak;</contents></text>
        </annots></xfdf>
        """
        let parsed = try? XFDF.read(Data(xxe.utf8))
        #expect(parsed?.annotations.first?.contents?.contains("TOP SECRET") != true, "the external entity was not read")
        #expect(throws: XFDF.XFDFError.self) { _ = try XFDF.read(Data("not xml".utf8)) }
    }
}
