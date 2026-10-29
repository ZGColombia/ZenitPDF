import Foundation
import Testing
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport
import ZPDFVectorExtraction
@testable import ZPDFGeometryServiceCore
@testable import ZPDFRepairServiceCore
@testable import ZPDFServiceClient
@testable import ZPDFServiceWire

/// Bug hunt 2, `ZPDFServiceClient`: BH-211..214 (medium) and BH-650..659 (low).
///
/// Nothing here launches an XPC service. The one test that goes through an
/// `NSXPCConnection` names a service this test host does not embed, which is
/// exactly the missing-bundle case BH-214 is about; the stdio-worker tests kill
/// whatever they spawn.
struct BugHunt2ServiceTests {

    // MARK: - Helpers

    /// Runs `body` in a task that is already cancelled before `body` starts.
    private static func runCancelled<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        let task = Task { () async throws -> T in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await body()
        }
        do { return .success(try await task.value) } catch { return .failure(error) }
    }

    private static func reference(_ url: URL) -> RevisionPageReference {
        RevisionPageReference(
            document: DocumentHandle(rawValue: 0), pageIndex: 0, box: .crop,
            fileURL: url, label: "Current")
    }

    // MARK: - BH-211: raster / page-box cancel inside PDFKit

    /// Old output: `WireFailure(domain: "ZPDFGeometryRaster", code: 100, message:
    /// "cancelled", isCancellation: false)`, which the client surfaced as
    /// `.remoteFailure(domain: "ZPDFGeometryRaster", code: 100, message: "cancelled")`.
    @Test("BH-211: PDFKit's own cancellation error maps to a wire cancellation")
    func bridgeCancellationIsACancellation() {
        let failure = GeometryServiceCore.rasterFailure(from: PDFBridgeError.cancelled)
        #expect(failure.isCancellation)
        #expect(failure.serviceError == .cancelled)
        // A real document failure is still a document failure.
        let other = GeometryServiceCore.rasterFailure(from: PDFBridgeError.passwordRequired)
        #expect(!other.isCancellation)
        #expect(other.domain == "ZPDFGeometryRaster")
    }

    /// Cancelled before the work starts, so the cancel lands inside the PDFKit
    /// provider (its `checkCancellation` throws `PDFBridgeError.cancelled`), not in
    /// the debug sleep the older tests used. Old output: a rendered page and a page
    /// box returned to a cancelled caller (the cancel never reached the work, BH-654).
    @Test("BH-211/BH-654: a raster or page box cancelled inside PDFKit comes back as .cancelled")
    func cancelledRasterIsCancelled() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFGeometryServiceClient(backend: .inProcess)
        let url = fixture.url

        let raster = await Self.runCancelled {
            try await client.rasterizePage(documentAt: url, pageIndex: 0, box: .crop, scale: 1)
        }
        guard case .failure(let rasterError) = raster else {
            Issue.record("a cancelled raster returned a page")
            return
        }
        #expect(rasterError as? ZPDFServiceError == .cancelled, "got \(rasterError)")

        let box = await Self.runCancelled {
            try await client.pageBox(documentAt: url, pageIndex: 0, box: .crop)
        }
        guard case .failure(let boxError) = box else {
            Issue.record("a cancelled page-box read returned a box")
            return
        }
        #expect(boxError as? ZPDFServiceError == .cancelled, "got \(boxError)")
    }

    // MARK: - BH-654: in-process raster ignores caller cancellation

    /// Old output: the 10 s debug delay ran out and a page came back — `Issue
    /// recorded: a cancelled in-process raster returned a page` after ~10 s.
    @Test("BH-654: cancelling an in-process raster or page box stops it promptly")
    func inProcessRasterHonoursCancellation() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFGeometryServiceClient(backend: .inProcess)
        let url = fixture.url

        let started = ContinuousClock.now
        let raster = Task {
            try await client.rasterizePage(
                documentAt: url, pageIndex: 0, box: .crop, scale: 1, debugDelayMilliseconds: 10_000)
        }
        let box = Task {
            try await client.pageBox(
                documentAt: url, pageIndex: 0, box: .crop, debugDelayMilliseconds: 10_000)
        }
        try await Task.sleep(for: .milliseconds(200))
        raster.cancel()
        box.cancel()
        do {
            _ = try await raster.value
            Issue.record("a cancelled in-process raster returned a page")
        } catch {
            #expect(error as? ZPDFServiceError == .cancelled, "got \(error)")
        }
        do {
            _ = try await box.value
            Issue.record("a cancelled in-process page-box read returned a box")
        } catch {
            #expect(error as? ZPDFServiceError == .cancelled, "got \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(5), "cancellation must not wait out the delay")
    }

    // MARK: - BH-212: one full-file copy per request

    /// Old behaviour: `stage` copied the whole document for every request and
    /// deleted it afterwards — two requests on one document, two full copies.
    @Test("BH-212: requests on one document share one staged copy; a changed file restages")
    func stagedCopyIsReused() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore()

        for _ in 0..<3 {
            let handle = try FileHandle(forReadingFrom: fixture.url)
            let outcome = await core.extract(
                request: GeometryWireRequest(pageIndex: 0), fileDescriptor: handle.fileDescriptor)
            try handle.close()
            guard case .success = outcome else {
                Issue.record("extraction through a descriptor failed: \(outcome)")
                return
            }
        }
        let rasterHandle = try FileHandle(forReadingFrom: fixture.url)
        let raster = await core.rasterize(
            request: RasterWireRequest(pageIndex: 0, scale: 0.5),
            fileDescriptor: rasterHandle.fileDescriptor)
        try rasterHandle.close()
        guard case .success = raster else {
            Issue.record("raster through a descriptor failed: \(raster)")
            return
        }
        #expect(await core.stagingCopyCount == 1, "four requests on one document, one copy")

        // Rewriting the file (a different size) must not serve the stale copy.
        let other = try ServiceTestSupport.makeFixture(.polygonThreeHoles)
        defer { ServiceTestSupport.remove(other.directory) }
        let replacement = try Data(contentsOf: other.url)
        try replacement.write(to: fixture.url)
        let changed = try FileHandle(forReadingFrom: fixture.url)
        let outcome = await core.extract(
            request: GeometryWireRequest(pageIndex: 0), fileDescriptor: changed.fileDescriptor)
        try changed.close()
        guard case .success(let data) = outcome else {
            Issue.record("extraction of the rewritten file failed: \(outcome)")
            return
        }
        #expect(await core.stagingCopyCount == 2, "a rewritten file stages afresh")
        let fresh = try await ZPDFGeometryServiceClient(backend: .inProcess)
            .extractPageGeometry(documentAt: other.url, pageIndex: 0)
        #expect(try VectorExtractionCodecProbe.primitives(data) == fresh.primitives.count,
                "the answer is the rewritten file's, not the staged copy of the old one")
        #expect(await core.stagedDocumentCount <= GeometryServiceCore.stagedDocumentCapacity)
        await core.removeIdleStagedDocuments()
        #expect(await core.stagedDocumentCount == 0)
    }

    @Test("BH-212: an idle staged copy is deleted after the idle expiry")
    func idleStagedCopyExpires() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore(stagingIdleExpiry: .milliseconds(100))
        let handle = try FileHandle(forReadingFrom: fixture.url)
        _ = await core.pageBox(
            request: RasterWireRequest(pageIndex: 0, scale: 1), fileDescriptor: handle.fileDescriptor)
        try handle.close()
        #expect(await core.stagedDocumentCount == 1)
        for _ in 0..<40 where await core.stagedDocumentCount > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await core.stagedDocumentCount == 0, "an idle copy must not live for the service's lifetime")
    }

    /// Old behaviour: a flat 30 s whatever the document's size.
    @Test("BH-212: the geometry deadline grows with the bytes the service must stage")
    func deadlineBudgetsForStaging() {
        #expect(ZPDFServiceDeadline.geometry.extended(forStagingBytes: 0) == .geometry)
        // 1.5 GB at 25 MB/s is 60 s on top of the 30 s.
        #expect(ZPDFServiceDeadline.geometry.extended(forStagingBytes: 1_500_000_000)
                == ZPDFServiceDeadline(.seconds(90)))
    }

    // MARK: - BH-213: compare cancellation laundered into a document fault

    /// Old output: `CompareFault.vectorExtraction(label: "Current", reason: "cancelled")`
    /// from all three source methods, which the presenter showed as a failed compare.
    @Test("BH-213: a cancelled compare source throws CancellationError, not a vector-extraction fault")
    func compareCancellationStaysCancellation() async throws {
        #expect(ServiceBackedRevisionDocumentSource.fault(
            for: ZPDFServiceError.cancelled, label: "Current") is CancellationError)
        #expect(ServiceBackedRevisionDocumentSource.fault(
            for: CancellationError(), label: "Current") is CancellationError)
        let real = ServiceBackedRevisionDocumentSource.fault(
            for: ZPDFServiceError.remoteFailure(domain: "d", code: 1, message: "m"), label: "Current")
        #expect(real as? CompareFault == .vectorExtraction(
            label: "Current", reason: String(describing: ZPDFServiceError.remoteFailure(
                domain: "d", code: 1, message: "m"))))

        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let source = ServiceBackedRevisionDocumentSource(
            client: ZPDFGeometryServiceClient(backend: .inProcess), isolation: .inProcess)
        let reference = Self.reference(fixture.url)

        let render = await Self.runCancelled {
            try await source.render(reference, scale: 0.5, maximumPixels: 4_000_000)
        }
        guard case .failure(let renderError) = render else {
            Issue.record("a cancelled render returned a page")
            return
        }
        #expect(renderError is CancellationError, "got \(renderError)")

        let box = await Self.runCancelled { try await source.pageBox(of: reference) }
        guard case .failure(let boxError) = box else {
            Issue.record("a cancelled page-box read returned a box")
            return
        }
        #expect(boxError is CancellationError, "got \(boxError)")
    }

    // MARK: - BH-214: missing XPC service reported as a crash

    /// Old output: `.serviceCrashed(service: "RepairService", detail: "Couldn’t
    /// communicate with a helper application.")`, after a wasted restart.
    @Test("BH-214: an invalid XPC connection is serviceUnavailable; an interrupted one is a crash")
    func xpcErrorMapping() {
        let invalid = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        guard case .serviceUnavailable = xpcBoundaryError(invalid, service: "RepairService") else {
            Issue.record("NSXPCConnectionInvalid must be serviceUnavailable")
            return
        }
        let interrupted = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        guard case .serviceCrashed = xpcBoundaryError(interrupted, service: "RepairService") else {
            Issue.record("NSXPCConnectionInterrupted must be serviceCrashed")
            return
        }
    }

    /// The real thing: `swift test`'s host embeds no `RepairService.xpc`, so this is
    /// the missing-bundle build. Nothing is launched — there is nothing to launch.
    @Test("BH-214: a build without the service bundle fails with serviceUnavailable, not serviceCrashed")
    func missingServiceIsUnavailable() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFRepairServiceClient(
            backend: .xpcService, maximumRestarts: 1, deadline: .milliseconds(10_000))
        do {
            _ = try await client.inspect(fixture.url)
            Issue.record("no service bundle exists, the request cannot succeed")
        } catch let error as ZPDFServiceError {
            guard case .serviceUnavailable = error else {
                Issue.record("expected serviceUnavailable, got \(error)")
                await client.shutdown()
                return
            }
        }
        await client.shutdown()
    }

    // MARK: - BH-650 / BH-651: fileName spliced into the staging path

    /// Old output: `.failure(WireFailure(domain: "ZPDFGeometryService", code: 3,
    /// message: "could not stage inherited descriptor: …"))` — ENAMETOOLONG.
    @Test("BH-650/651: a 250-byte document name stages and extracts through a descriptor")
    func longFileNameStages() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        // 123 two-byte letters + ".pdf": 250 UTF-8 bytes, legal on APFS (255).
        let longName = String(repeating: "ö", count: 123) + ".pdf"
        #expect(longName.utf8.count == 250)

        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }
        let core = GeometryServiceCore()
        let geometry = await core.extract(
            request: GeometryWireRequest(pageIndex: 0, fileName: longName),
            fileDescriptor: handle.fileDescriptor)
        guard case .success = geometry else {
            Issue.record("geometry staging failed for a long name: \(geometry)")
            return
        }

        await core.removeIdleStagedDocuments()

        let repair = await RepairServiceCore().perform(
            request: RepairWireRequest(operation: .inspect, fileName: longName),
            inputDescriptor: handle.fileDescriptor, outputDescriptor: nil)
        guard case .success = repair else {
            Issue.record("repair staging failed for a long name: \(repair)")
            return
        }
    }

    // MARK: - BH-652: repair worker names the wrong kind

    /// Old output: `geometryExtract is not a repair operation` for every one of the
    /// three geometry kinds.
    @Test("BH-652: the repair worker's refusal names the kind that was sent")
    func repairRefusalNamesTheKind() async {
        let handler = RepairStdioHandler()
        for kind in [WireRequestKind.geometryExtract, .geometryRasterize, .geometryPageBox] {
            let reply = await handler.handle(WireRequestFrame(kind: kind))
            #expect(reply.failure?.message == "\(kind.rawValue) is not a repair operation")
        }
    }

    // MARK: - BH-653: output descriptor leaked on a failed input dup

    /// Old behaviour: the output was dup'ed before the input's result was checked
    /// and only the input was closed on failure — one descriptor leaked.
    @Test("BH-653: a failed descriptor dup leaves nothing open")
    func failedDupLeaksNothing() {
        final class Table: @unchecked Sendable {
            var open: Set<Int32> = []
            var next: Int32 = 100
        }
        let table = Table()
        func fakeDup(failing: Int32) -> (Int32) -> Int32 {
            { source in
                if source == failing { return -1 }
                table.next += 1
                table.open.insert(table.next)
                return table.next
            }
        }
        let close: (Int32) -> Void = { table.open.remove($0) }

        // Input dup fails, output would succeed.
        #expect(RepairXPCExported.duplicateDescriptors(
            input: 3, output: 4, dup: fakeDup(failing: 3), close: close) == nil)
        #expect(table.open.isEmpty, "leaked \(table.open)")

        // Output dup fails after the input succeeded.
        #expect(RepairXPCExported.duplicateDescriptors(
            input: 3, output: 4, dup: fakeDup(failing: 4), close: close) == nil)
        #expect(table.open.isEmpty, "leaked \(table.open)")

        // Both succeed: both are handed over, nothing closed early.
        let both = RepairXPCExported.duplicateDescriptors(
            input: 3, output: 4, dup: fakeDup(failing: -99), close: close)
        #expect(both != nil && both?.output != nil)
        #expect(table.open.count == 2)
    }

    // MARK: - BH-655: unbounded debug delay traps

    /// Old output: a trap — `Fatal error: arithmetic overflow` in
    /// `UInt64(request.debugDelayMilliseconds) * 1_000_000`, in this process.
    @Test("BH-655: an Int.max debug delay neither traps nor sleeps unboundedly")
    func hugeDebugDelayIsClamped() async throws {
        #expect(WireDebugDelay.nanoseconds(forMilliseconds: .max)
                == UInt64(WireDebugDelay.maximumMilliseconds) * 1_000_000)
        #expect(WireDebugDelay.nanoseconds(forMilliseconds: -5) == 0)
        #expect(WireDebugDelay.nanoseconds(forMilliseconds: 250) == 250_000_000)

        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFGeometryServiceClient(backend: .inProcess)
        let url = fixture.url
        let extract = Task {
            try await client.extractPageGeometry(
                documentAt: url, pageIndex: 0, debugDelayMilliseconds: .max)
        }
        let raster = Task {
            try await client.rasterizePage(
                documentAt: url, pageIndex: 0, box: .crop, scale: 1, debugDelayMilliseconds: .max)
        }
        try await Task.sleep(for: .milliseconds(200))
        extract.cancel()
        raster.cancel()
        await #expect(throws: ZPDFServiceError.cancelled) { _ = try await extract.value }
        await #expect(throws: ZPDFServiceError.cancelled) { _ = try await raster.value }
    }

    // MARK: - BH-656: decode ignores the request's pixel budget

    /// Old behaviour: `decode` checked only the absolute 256 Mpx ceiling, and the
    /// client passed no budget, so an over-budget page came back unchecked.
    @Test("BH-656: a reply larger than the request's budget is refused on decode")
    func decodeEnforcesTheRequestBudget() throws {
        let frame = RasterWireFrame(
            boxX: 0, boxY: 0, boxWidth: 100, boxHeight: 100,
            regionX: 0, regionY: 0, regionWidth: 100, regionHeight: 100,
            rotation: 0, scale: 1, pixelWidth: 100, pixelHeight: 100)
        let payload = try RasterWireCodec.encode(
            frame: frame, pixels: [UInt8](repeating: 255, count: 10_000))

        #expect(throws: RasterWireCodecError.exceedsRequestedBudget(pixels: 10_000, budget: 9_999)) {
            _ = try RasterWireCodec.decode(payload, maximumPixels: 9_999)
        }
        let accepted = try RasterWireCodec.decode(payload, maximumPixels: 10_000)
        #expect(accepted.frame == frame && accepted.pixels.count == 10_000)

        // The in-place reader must honour a Data slice whose indices do not start at 0.
        let padded = Data([0xAA, 0xBB, 0xCC]) + payload
        let slice = padded[padded.startIndex.advanced(by: 3)...]
        #expect(try RasterWireCodec.decode(slice) == accepted)
    }

    // MARK: - BH-657: worker outlives its parent while a handler runs

    /// Old behaviour: stdin closed, the discarding task group waited for the
    /// 20 s handler, and the worker lived on for the whole delay.
    @Test("BH-657: EOF on stdin ends the worker even while a handler is still running")
    func workerExitsOnEOFMidRequest() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let process = Process()
        process.executableURL = try ServiceTestSupport.geometryWorkerURL()
        process.arguments = ["--stdio"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let request = GeometryWireRequest(pageIndex: 0, debugDelayMilliseconds: 20_000)
        let frame = WireRequestFrame(
            kind: .geometryExtract, body: try JSONEncoder().encode(request), filePath: fixture.url.path)
        try stdin.fileHandleForWriting.write(contentsOf: try WireFraming.encode(frame))
        try await Task.sleep(for: .milliseconds(300))
        try stdin.fileHandleForWriting.close()

        let started = ContinuousClock.now
        while process.isRunning, ContinuousClock.now - started < .seconds(5) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!process.isRunning, "the worker must exit on EOF, not wait out its handler")
    }

    // MARK: - BH-658: cancel before the request registers

    /// Old output: `.success(…)` after the full 5 s delay — the early cancel was a
    /// no-op lookup.
    @Test("BH-658: a cancel that reaches the core before its request is honoured")
    func earlyCancelIsHonoured() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let core = GeometryServiceCore()
        let request = GeometryWireRequest(pageIndex: 0, debugDelayMilliseconds: 5000)
        await core.cancel(request.requestID)
        let started = ContinuousClock.now
        let outcome = await core.extract(request: request, documentAt: fixture.url)
        guard case .failure(let failure) = outcome else {
            Issue.record("an extraction cancelled before it registered ran to completion")
            return
        }
        #expect(failure.isCancellation)
        #expect(ContinuousClock.now - started < .seconds(3))

        let repairCore = RepairServiceCore()
        let repair = RepairWireRequest(operation: .inspect, debugDelayMilliseconds: 5000)
        await repairCore.cancel(repair.requestID)
        let repairOutcome = await repairCore.perform(
            request: repair, inputAt: fixture.url, outputPath: nil)
        guard case .failure(let repairFailure) = repairOutcome else {
            Issue.record("an inspect cancelled before it registered ran to completion")
            return
        }
        #expect(repairFailure.isCancellation)
    }

    // MARK: - BH-659: split length prefix

    /// Measured on this platform: `FileHandle.read(upToCount:)` on a pipe waits for
    /// the full count (or EOF), so the split header the finding describes is
    /// already reassembled. The reader now loops explicitly anyway; this pins the
    /// behaviour end to end with a header split across two writes.
    @Test("BH-659: a frame whose 4-byte header arrives in two writes is answered")
    func splitHeaderIsAnswered() async throws {
        let process = Process()
        process.executableURL = try ServiceTestSupport.geometryWorkerURL()
        process.arguments = ["--stdio"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let frame = WireRequestFrame(kind: .ping)
        let bytes = try WireFraming.encode(frame)
        try stdin.fileHandleForWriting.write(contentsOf: bytes.prefix(2))
        try await Task.sleep(for: .milliseconds(300))
        try stdin.fileHandleForWriting.write(contentsOf: bytes.dropFirst(2))

        let reader = stdout.fileHandleForReading
        let header = try #require(StdioServiceLoop.readExactly(4, from: reader))
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).byteSwapped }
        let body = try #require(StdioServiceLoop.readExactly(Int(length), from: reader))
        let reply = try WireFraming.decodeBody(WireReplyFrame.self, from: body)
        #expect(reply.id == frame.id)
        #expect(reply.body == Data("\(GeometryServiceCore.protocolVersion)".utf8))
        try stdin.fileHandleForWriting.close()
    }
}

/// Counts the primitives in a `VectorExtractionCodec` payload.
private enum VectorExtractionCodecProbe {
    static func primitives(_ data: Data) throws -> Int {
        try VectorExtractionCodec.decode(data).primitives.count
    }
}
