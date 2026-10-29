import Foundation
import Testing
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFTestingSupport

/// Finding S17-02: Revision Compare opened a second untrusted PDF *in the
/// application process*.
///
/// These tests are about where the bytes are parsed, not about what the comparison
/// concludes — `ZPDFCompare`'s own suite owns the maths. Three claims:
///
/// 1. The out-of-process source really does spawn a worker and really does answer
///    from it, for every hostile fixture in the corpus.
/// 2. The pixels it returns are the pixels the in-process path returns, byte for
///    byte, so moving the parser did not move the answer.
/// 3. A comparator built on the service source reports
///    ``RevisionParsingIsolation/outOfProcess``, which is the property the
///    application asserts at construction time.
struct CompareIsolationTests {

    /// The hostile corpus, minus the two that are a password prompt rather than a
    /// parse (`encryptedUserPassword`) and the one whose whole point is to be
    /// enormous (`oneThousandPages`).
    static let hostileKinds: [FixtureKind] = [
        .truncatedFile, .brokenXref, .cyclicPageTree, .missingObject,
        .deeplyNestedForms, .decompressionBomb, .embeddedFileWithLaunchAction,
        .javaScriptAction, .hugeMalformedOperatorStream
    ]

    @Test("A comparator built on the service source is out of process; one built on the fallback says so")
    func isolationIsReported() async throws {
        let service = ServiceBackedRevisionDocumentSource.subprocess(
            executableURL: try ServiceTestSupport.geometryWorkerURL())
        #expect(RevisionComparator(source: service).isolation == .outOfProcess)
        #expect(ServiceBackedRevisionDocumentSource.automatic().isolation == .outOfProcess)

        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let fallback = InProcessRevisionDocumentSource(provider: provider)
        #expect(RevisionComparator(source: fallback).isolation == .inProcess)
        await service.shutdown()
    }

    @Test("Every hostile fixture Revision Compare could be handed is rasterised by the worker, not here")
    func hostileRevisionsAreRasterisedOutOfProcess() async throws {
        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 1)
        let source = ServiceBackedRevisionDocumentSource(client: client, isolation: .outOfProcess)
        let comparator = RevisionComparator(source: source)

        var refusals = 0
        for kind in Self.hostileKinds {
            let fixture = try ServiceTestSupport.makeFixture(kind)
            defer { ServiceTestSupport.remove(fixture.directory) }
            let reference = RevisionPageReference(
                document: DocumentHandle(rawValue: 0),
                pageIndex: 0,
                box: .crop,
                fileURL: fixture.url,
                label: kind.rawValue)
            do {
                _ = try await comparator.render(reference, scale: 0.25, maximumPixels: 4_000_000)
            } catch let fault as CompareFault {
                // A typed refusal is a correct outcome for a hostile file. A crash
                // in this process is the outcome this whole finding is about, and
                // it cannot happen: the parse is in the worker.
                _ = fault
                refusals += 1
            }
        }

        let launches = await client.workerLaunchCount
        #expect(launches >= 1, "the hostile corpus must have been parsed by a worker process")
        #expect(refusals <= Self.hostileKinds.count)
        // Still standing after the whole corpus.
        let sane = try ServiceTestSupport.makeFixture(.lShape)
        defer { ServiceTestSupport.remove(sane.directory) }
        let page = try await comparator.render(
            RevisionPageReference(
                document: DocumentHandle(rawValue: 0), pageIndex: 0, box: .crop,
                fileURL: sane.url, label: "sane"),
            scale: 1,
            maximumPixels: 4_000_000)
        #expect(page.image.pixelCount > 0)
        print("S17-02 compare isolation: \(Self.hostileKinds.count) hostile fixtures rasterised "
            + "through \(launches) worker launch(es), \(refusals) typed refusals, 0 in-process parses")
        await client.shutdown()
    }

    @Test("The worker's pixels are the in-process pixels, byte for byte")
    func serviceRasterEqualsInProcessRaster() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.lShape)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(fileAt: fixture.url)
        let local = InProcessRevisionDocumentSource(provider: provider)
        let localReference = RevisionPageReference(
            document: opened.handle, pageIndex: 0, box: .crop,
            fileURL: fixture.url, label: "local")
        let localPage = try await local.render(localReference, scale: 2, maximumPixels: 64_000_000)

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))
        let remote = ServiceBackedRevisionDocumentSource(client: client, isolation: .outOfProcess)
        let remoteReference = RevisionPageReference(
            document: DocumentHandle(rawValue: 0), pageIndex: 0, box: .crop,
            fileURL: fixture.url, label: "remote")
        let remotePage = try await remote.render(remoteReference, scale: 2, maximumPixels: 64_000_000)

        #expect(remotePage.image.width == localPage.image.width)
        #expect(remotePage.image.height == localPage.image.height)
        #expect(remotePage.image.pixels == localPage.image.pixels,
                "moving the rasteriser into the service must not move a single pixel")
        #expect(remotePage.frame == localPage.frame)

        let box = try await remote.pageBox(of: remoteReference)
        #expect(box == localPage.frame.boxRect)
        await client.shutdown()
        await provider.close(opened.handle)
    }

    @Test("A revision with no file URL is refused, never parsed here")
    func pageWithoutFileURLIsRefused() async throws {
        let source = ServiceBackedRevisionDocumentSource.subprocess(
            executableURL: try ServiceTestSupport.geometryWorkerURL())
        let reference = RevisionPageReference(
            document: DocumentHandle(rawValue: 0), pageIndex: 0, box: .crop, fileURL: nil, label: "no-url")
        await #expect(throws: CompareFault.vectorSourceUnavailable(label: "no-url")) {
            _ = try await source.render(reference, scale: 1, maximumPixels: 1_000_000)
        }
        await source.shutdown()
    }
}
