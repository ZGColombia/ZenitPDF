import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// The spec 20.1 page operations, applied for real, against the fixture corpus.
///
/// The mixed-page-sizes fixture has four pages of four different sizes — Letter, A4, A1,
/// ARCH-D — so a reorder or an extract can be verified by the *size* of each resulting
/// page rather than by trusting the operation to have done what it said.
@Suite("Page operations")
struct PageOperationApplicationTests {

    struct Fixture {
        let provider: PDFKitDocumentProvider
        let handle: DocumentHandle
        let source: URL
        let scratch: URL
        let sha256Before: String
        let sizes: [CGSize]
    }

    func makeFixture(_ label: String) async throws -> Fixture {
        let scratch = try Corpus.scratchDirectory(label)
        let source = scratch.appendingPathComponent(FixtureKind.mixedPageSizes.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.mixedPageSizes), to: source)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: source)
        let pages = try await provider.pageDescriptors(of: opened.handle)
        return Fixture(
            provider: provider,
            handle: opened.handle,
            source: source,
            scratch: scratch,
            sha256Before: try FileDigestProbe.hex(of: source),
            sizes: pages.map(\.boxes.media.size)
        )
    }

    func sizes(of url: URL) async throws -> [CGSize] {
        let reader = PDFKitDocumentProvider()
        let opened = try await reader.open(fileAt: url)
        return try await reader.pageDescriptors(of: opened.handle).map(\.boxes.media.size)
    }

    /// Page boxes compared to a tenth of a micrometre.
    ///
    /// Exact equality is the wrong assertion here, and finding out why is the point of
    /// this helper: PDFKit re-serialises `/MediaBox` when it writes, rounding an ISO A1
    /// sheet's 1683.7795275590554 pt to 1683.78. That is 0.5 µm on a 594 mm sheet — far
    /// below any measurement tolerance in spec 12 — but it is a real property of every
    /// page operation that goes through PDFKit, and this package's tests state it rather
    /// than paper over it. See ``PDFDocumentProviding/applyPageOperations(_:on:to:)``.
    func expectSizes(_ produced: [CGSize], _ expected: [CGSize], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(produced.count == expected.count, sourceLocation: sourceLocation)
        for (a, b) in zip(produced, expected) {
            #expect(abs(a.width - b.width) < 0.01, "width \(a.width) vs \(b.width)", sourceLocation: sourceLocation)
            #expect(abs(a.height - b.height) < 0.01, "height \(a.height) vs \(b.height)", sourceLocation: sourceLocation)
        }
    }

    func rotations(of url: URL) async throws -> [Int] {
        let reader = PDFKitDocumentProvider()
        let opened = try await reader.open(fileAt: url)
        return try await reader.pageDescriptors(of: opened.handle).map(\.rotation)
    }

    @Test("Reorder produces the planned page order and leaves the original byte-identical")
    func reorder() async throws {
        let fixture = try await makeFixture("op-reorder")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("reordered.pdf"))
        let operations: [PageOperation] = [.reorder(order: [3, 1, 0, 2])]

        let plan = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        #expect(plan.resultingPages.count == 4)
        #expect(plan.summary.moved == 2) // relative-order moves (documents bug 6)
        #expect(plan.isNoOp == false)

        let receipt = try await fixture.provider.applyPageOperations(
            operations, on: fixture.handle, to: destination
        )
        #expect(receipt.pageCount == plan.resultingPages.count)
        #expect(receipt.sourceIsUnchanged)
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)

        expectSizes(try await sizes(of: destination.url), [3, 1, 0, 2].map { fixture.sizes[$0] })
    }

    @Test("Rotate writes the planned rotation and does not touch the source")
    func rotate() async throws {
        let fixture = try await makeFixture("op-rotate")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("rotated.pdf"))
        let operations: [PageOperation] = [
            .rotate(pageIndices: [0, 2], change: .relative(degrees: 90)),
            .rotate(pageIndices: [1], change: .absolute(degrees: 180))
        ]
        let plan = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        #expect(plan.resultingPages.map(\.rotation) == [90, 180, 90, 0])

        _ = try await fixture.provider.applyPageOperations(operations, on: fixture.handle, to: destination)
        #expect(try await rotations(of: destination.url) == [90, 180, 90, 0])
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("Delete removes exactly the named pages")
    func delete() async throws {
        let fixture = try await makeFixture("op-delete")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("deleted.pdf"))
        _ = try await fixture.provider.applyPageOperations(
            [.delete(pageIndices: [1, 2])], on: fixture.handle, to: destination
        )
        expectSizes(try await sizes(of: destination.url), [fixture.sizes[0], fixture.sizes[3]])
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("Extract writes only the named pages, in the order named")
    func extract() async throws {
        let fixture = try await makeFixture("op-extract")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("extracted.pdf"))
        let receipt = try await fixture.provider.extractPages(
            [3, 0], of: fixture.handle, to: destination
        )
        #expect(receipt.pageCount == 2)
        expectSizes(try await sizes(of: destination.url), [fixture.sizes[3], fixture.sizes[0]])
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("Insert pulls pages out of a second open document")
    func insert() async throws {
        let fixture = try await makeFixture("op-insert")
        let other = fixture.scratch.appendingPathComponent(FixtureKind.sizeArchD.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.sizeArchD), to: other)
        let otherBefore = try FileDigestProbe.hex(of: other)
        let second = try await fixture.provider.open(fileAt: other)

        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("inserted.pdf"))
        let operations: [PageOperation] = [
            .insert(pages: [PageReference(document: second.handle, pageIndex: 0)], atIndex: 1)
        ]
        let plan = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        #expect(plan.externalDocuments == [second.handle])
        #expect(plan.summary.inserted == 1)

        let receipt = try await fixture.provider.applyPageOperations(
            operations, on: fixture.handle, to: destination
        )
        #expect(receipt.pageCount == 5)
        let produced = try await sizes(of: destination.url)
        expectSizes([produced[1]], [CGSize(width: 1728, height: 2592)])
        expectSizes([produced[0]], [fixture.sizes[0]])
        // Both originals survive.
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
        #expect(try FileDigestProbe.hex(of: other) == otherBefore)
    }

    @Test("Merge concatenates whole documents in order")
    func merge() async throws {
        let fixture = try await makeFixture("op-merge")
        let other = fixture.scratch.appendingPathComponent(FixtureKind.rectangle.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.rectangle), to: other)
        let otherBefore = try FileDigestProbe.hex(of: other)
        let second = try await fixture.provider.open(fileAt: other)

        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("merged.pdf"))
        let receipt = try await fixture.provider.mergeDocuments(
            [fixture.handle, second.handle], to: destination
        )
        #expect(receipt.pageCount == 5)
        let produced = try await sizes(of: destination.url)
        expectSizes(Array(produced.prefix(4)), fixture.sizes)
        expectSizes([produced[4]], [CGSize(width: 612, height: 792)])
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
        #expect(try FileDigestProbe.hex(of: other) == otherBefore)
    }

    @Test("Merge keeps a foreign page's own rotation instead of flattening it to 0 (CR-75)")
    func mergeKeepsForeignRotation() async throws {
        let fixture = try await makeFixture("op-merge-rotation")
        // A separate document whose single page carries /Rotate 90.
        let rotated = fixture.scratch.appendingPathComponent(FixtureKind.rotation90.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.rotation90), to: rotated)
        let second = try await fixture.provider.open(fileAt: rotated)
        let secondRotation = try await fixture.provider.pageDescriptors(of: second.handle).map(\.rotation)
        #expect(secondRotation == [90], "fixture rotation90 should carry /Rotate 90, got \(secondRotation)")

        let operations: [PageOperation] = [.merge(document: second.handle, pageCount: 1)]
        // The plan must record the foreign rotation — the assertion CR-96 found missing here
        // (this test used to compare page sizes only). Old output: the planner hard-coded
        // `rotation: 0` for foreign pages, so this was 0 and the writer wrote 0 over the copied
        // page's own /Rotate 90 — a landscape sheet came out portrait.
        let plan = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        #expect(plan.resultingPages.last?.rotation == 90,
                "planned foreign rotation was \(String(describing: plan.resultingPages.last?.rotation))")

        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("merged-rot.pdf"))
        _ = try await fixture.provider.applyPageOperations(operations, on: fixture.handle, to: destination)
        let rotations = try await rotations(of: destination.url)
        #expect(rotations.count == 5)
        #expect(rotations.last == 90,
                "merged page came out rotation \(String(describing: rotations.last)), not 90")
        // The base document's own pages are untouched (all four unrotated).
        #expect(Array(rotations.prefix(4)) == [0, 0, 0, 0])
    }

    @Test("Insert keeps a foreign page's own rotation instead of flattening it to 0 (CR-75)")
    func insertKeepsForeignRotation() async throws {
        let fixture = try await makeFixture("op-insert-rotation")
        let rotated = fixture.scratch.appendingPathComponent(FixtureKind.rotation90.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.rotation90), to: rotated)
        let second = try await fixture.provider.open(fileAt: rotated)
        let operations: [PageOperation] = [
            .insert(pages: [PageReference(document: second.handle, pageIndex: 0)], atIndex: 1)
        ]
        // Old output: the planner hard-coded `rotation: 0` for an inserted foreign page, so the
        // plan said 0 and the writer wrote 0 over the copied page's own /Rotate 90.
        let plan = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        #expect(plan.resultingPages.count == 5)
        #expect(plan.resultingPages[1].rotation == 90,
                "planned inserted rotation was \(plan.resultingPages[1].rotation)")

        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("inserted-rot.pdf"))
        _ = try await fixture.provider.applyPageOperations(operations, on: fixture.handle, to: destination)
        let rotations = try await rotations(of: destination.url)
        #expect(rotations == [0, 90, 0, 0, 0], "written rotations were \(rotations)")
    }

    @Test("A batch composes, and the dry run predicts the result exactly")
    func composedBatch() async throws {
        let fixture = try await makeFixture("op-batch")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("batch.pdf"))
        let operations: [PageOperation] = [
            .delete(pageIndices: [1]),
            .duplicate(pageIndices: [0]),
            .rotate(pageIndices: [1], change: .absolute(degrees: 270)),
            .reorder(order: [3, 2, 1, 0])
        ]
        let plan = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        _ = try await fixture.provider.applyPageOperations(operations, on: fixture.handle, to: destination)

        expectSizes(
            try await sizes(of: destination.url),
            plan.resultingPages.map { fixture.sizes[$0.source.pageIndex] }
        )
        #expect(try await rotations(of: destination.url) == plan.resultingPages.map(\.rotation))
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("The dry run touches nothing at all")
    func dryRunWritesNothing() async throws {
        let fixture = try await makeFixture("op-dryrun")
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path)
        _ = try await fixture.provider.planPageOperations(
            [.reorder(order: [1, 0, 3, 2]), .rotate(pageIndices: [0], change: .relative(degrees: 90))],
            on: fixture.handle
        )
        let after = try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path)
        #expect(before == after)
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("An invalid batch is refused by both the dry run and the apply, and nothing is written")
    func invalidBatch() async throws {
        let fixture = try await makeFixture("op-invalid")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("never.pdf"))
        let operations: [PageOperation] = [.delete(pageIndices: [0, 1, 2, 3])]

        await #expect(throws: PDFBridgeError.pageOperation(.resultWouldBeEmpty)) {
            _ = try await fixture.provider.planPageOperations(operations, on: fixture.handle)
        }
        await #expect(throws: PDFBridgeError.pageOperation(.resultWouldBeEmpty)) {
            _ = try await fixture.provider.applyPageOperations(
                operations, on: fixture.handle, to: destination
            )
        }
        #expect(FileManager.default.fileExists(atPath: destination.url.path) == false)
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("A page operation cannot be written over the source or over another open original")
    func destinationGuard() async throws {
        let fixture = try await makeFixture("op-guard")
        await #expect(throws: PDFBridgeError.destinationIsSource(path: fixture.source.path)) {
            _ = try await fixture.provider.applyPageOperations(
                [.rotate(pageIndices: [0], change: .relative(degrees: 90))],
                on: fixture.handle,
                to: DocumentDestination(url: fixture.source, overwritePolicy: .replace)
            )
        }
        #expect(try FileDigestProbe.hex(of: fixture.source) == fixture.sha256Before)
    }

    @Test("An operation naming a closed document is refused")
    func closedContributor() async throws {
        let fixture = try await makeFixture("op-closed")
        let other = fixture.scratch.appendingPathComponent(FixtureKind.rectangle.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.rectangle), to: other)
        let second = try await fixture.provider.open(fileAt: other)
        await fixture.provider.close(second.handle)

        await #expect(throws: PDFBridgeError.self) {
            _ = try await fixture.provider.applyPageOperations(
                [.merge(document: second.handle, pageCount: 1)],
                on: fixture.handle,
                to: DocumentDestination(url: fixture.scratch.appendingPathComponent("x.pdf"))
            )
        }
    }

    @Test("Rotation carried by the source page is preserved and can be added to")
    func preservesExistingRotation() async throws {
        let scratch = try Corpus.scratchDirectory("op-rot-preserve")
        let source = scratch.appendingPathComponent(FixtureKind.rotation90.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.rotation90), to: source)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: source)

        let plain = DocumentDestination(url: scratch.appendingPathComponent("plain.pdf"))
        _ = try await provider.applyPageOperations([], on: opened.handle, to: plain)
        #expect(try await rotations(of: plain.url) == [90])

        let turned = DocumentDestination(url: scratch.appendingPathComponent("turned.pdf"))
        _ = try await provider.applyPageOperations(
            [.rotate(pageIndices: [0], change: .relative(degrees: 90))],
            on: opened.handle,
            to: turned
        )
        #expect(try await rotations(of: turned.url) == [180])
    }

    @Test("An in-memory document can be operated on and written out")
    func memorySourceWrite() async throws {
        let scratch = try Corpus.scratchDirectory("op-memory")
        let bytes = try Corpus.data(.mixedPageSizes)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(.data(bytes), password: nil, limits: .standard)
        let destination = DocumentDestination(url: scratch.appendingPathComponent("from-memory.pdf"))
        let receipt = try await provider.extractPages([2], of: opened.handle, to: destination)
        #expect(receipt.pageCount == 1)
        // No source file exists, so there is nothing to have mutated.
        #expect(receipt.sourceDigestBefore == nil)
        #expect(receipt.sourceIsUnchanged)
        #expect(try await sizes(of: destination.url).count == 1)
    }

    @Test("PDFKit rounds page boxes when it writes, and the rounding is bounded")
    func pageBoxRounding() async throws {
        // Recorded deliberately: an ISO A1 media box is 1683.7795275590554 pt wide, and
        // a page operation writes it back as 1683.78. Any future engine swap must not do
        // worse than this, and any code that depends on byte-identical page boxes must
        // not go through PDFKit.
        let fixture = try await makeFixture("op-rounding")
        let destination = DocumentDestination(url: fixture.scratch.appendingPathComponent("rounded.pdf"))
        _ = try await fixture.provider.applyPageOperations([], on: fixture.handle, to: destination)
        let produced = try await sizes(of: destination.url)
        for (a, b) in zip(produced, fixture.sizes) {
            #expect(abs(a.width - b.width) <= 0.005)
            #expect(abs(a.height - b.height) <= 0.005)
        }
    }
}
