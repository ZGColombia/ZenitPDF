import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Bug hunt 2, the stores: tool library, archives, artwork, photos and remembered modes
/// (BH-007, 009, 095, 097, 098, 099, 426, 438, 439, 440, 441, 442).
@Suite("Bug hunt 2: stores")
struct BugHunt2StoreTests {

    private func workspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-bh2-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func preset(_ name: String, panel: ToolLibraryPanel) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: name, category: "C", panel: panel, markupKind: .measurement,
            measurementKind: .area, colorRGBA: ColorRGBA(red: 0.2, green: 0.5, blue: 0.9), defaultSubject: name
        )
    }

    /// A flat-colour image, encoded as `type`.
    private func image(width: Int, height: Int, type: UTType) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let made = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, made, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: BH-007

    @Test("A personal library this build cannot read is never overwritten")
    func unreadableLibraryIsNotOverwritten() async throws {
        let directory = try workspace("library")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = Data(#"{"format":"\#(ToolPresetContainerStore.formatIdentifier)","schemaVersion":99,"presets":[]}"#.utf8)
        try future.write(to: await container.fileURL)

        // Old output: write() replaced the file with the six built-ins.
        await #expect(throws: ToolPresetContainerStore.StoreError.self) {
            try await container.write([self.preset("Seeded", panel: .myTools)])
        }
        #expect(try Data(contentsOf: await container.fileURL) == future)
    }

    // MARK: BH-097, BH-098

    @Test("Rows this build cannot decode survive the next save")
    func undecodableRowsSurviveTheSave() async throws {
        let directory = try workspace("archive")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Keep.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Keep", originalPDF: fixture.url)
        defer { Task { try? await package.close() } }

        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let page = fixture.firstPage.id
        func area(_ subject: String) -> ZPDFContracts.MarkupRecord {
            var parameters = MeasurementParameters.default
            parameters.depth = .length(Decimal(string: "0.2")!)
            return ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: fixture.documentID, pageID: page, kind: .measurement, tool: .area,
                subject: subject, author: "t",
                geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
                ], isClosed: true))]),
                parameters: parameters,
                createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let kept = area("Readable")
        let future = area("From a newer build")
        _ = try await session.apply(.addMarkup(kept))
        _ = try await session.apply(.addMarkup(future))
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        // A newer build's parameter case this build cannot decode.
        let futureID = future.id.rawValue.uuidString
        try await package.write { db in
            try db.execute(sql: "UPDATE markup_extra SET parameters_json = ? WHERE markup_id = ?",
                           arguments: [#"{"futureOnly":true"#, futureID])
        }
        let stored = try #require(try await TakeoffArchive.read(from: package))
        #expect(stored.markups.map(\.id) == [kept.id])
        #expect(stored.unreadableMarkupIDs == [futureID])

        // The session holds only the readable markup — exactly what an open hydrates.
        let reopened = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        _ = try await reopened.apply(.addMarkup(kept))
        try await TakeoffArchive.write(await reopened.takeoffState(), into: package)
        // Old output: 1 — the save's DELETE erased the unreadable markup for good.
        let rows = try await package.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? 0 }
        #expect(rows == 2)
        #expect(try await TakeoffArchive.read(from: package)?.unreadableMarkupIDs == [futureID])

        // A deleted markup still goes: nothing but undecodable rows is carried.
        try await TakeoffArchive.write(await TakeoffSession(documentID: fixture.documentID, pages: fixture.pages).takeoffState(), into: package)
        #expect(try await package.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? 0 } == 1)

        // BH-098, presets: a row this build cannot decode survives a save of the library.
        let a = preset("Readable preset", panel: .projectTools)
        let b = preset("Future preset", panel: .projectTools)
        try await ToolPresetArchive.write([a, b], into: package)
        let bID = b.id.uuidString
        try await package.write { db in
            try db.execute(sql: "UPDATE tool_preset SET defaults_json = '{' WHERE id = ?", arguments: [bID])
        }
        #expect(try await ToolPresetArchive.read(from: package).map(\.name) == ["Readable preset"])
        try await ToolPresetArchive.write([a], into: package)
        // Old output: 1.
        #expect(try await package.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tool_preset") ?? 0 } == 2)
    }

    // MARK: BH-095, BH-426

    @Test("Stored artwork that cannot be decoded, or exceeds the limits, is refused by name")
    func storedArtworkIsBounded() throws {
        // Old output: nil — indistinguishable from "no artwork".
        #expect(throws: ProjectArtworkStore.ReadFailure.self) {
            try ProjectArtworkStore.decodeStoredGeometry("{", digest: "d")
        }
        let tooMany = ArtworkGeometry(
            kind: .vector,
            strokes: Array(repeating: ArtworkContour(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)]),
                           count: ArtworkLimits.maximumContours + 1)
        )
        let json = String(decoding: try JSONEncoder().encode(tooMany), as: UTF8.self)
        // Old output: the geometry, unchecked.
        #expect(throws: ProjectArtworkStore.ReadFailure.self) {
            try ProjectArtworkStore.decodeStoredGeometry(json, digest: "d")
        }
        let fine = ArtworkGeometry(kind: .vector, strokes: [ArtworkContour(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)])])
        let fineJSON = String(decoding: try JSONEncoder().encode(fine), as: UTF8.self)
        #expect(try ProjectArtworkStore.decodeStoredGeometry(fineJSON, digest: "d") == fine)
    }

    // MARK: BH-099

    @Test("Two open projects do not erase each other's remembered set modes")
    @MainActor
    func setModesMerge() {
        let defaults = ZPDFInMemoryDefaults()
        let store = ToolSetModeStore(defaults: defaults)
        let windowA = AppToolLibraryPresenter()
        let windowB = AppToolLibraryPresenter()
        windowA.onSetModesChanged = { store.write($0) }
        windowB.onSetModesChanged = { store.write($0) }

        windowA.setMode(.apply, for: .myTools)
        windowB.setMode(.place, for: .projectTools)
        // Old output: [projectTools: place] — window B's full map replaced A's decision.
        #expect(store.read() == [.myTools: .apply, .projectTools: .place])
        windowB.setMode(.draw, for: .projectTools)
        // Old output: [:] — an empty map cleared the key for every window.
        #expect(store.read() == [.myTools: .apply])
    }

    // MARK: BH-009

    @Test("A truncated leftover blob is rewritten, never adopted")
    func truncatedBlobIsRewritten() async throws {
        let first = try workspace("blob-a")
        let second = try workspace("blob-b")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let photo = try image(width: 64, height: 48, type: .jpeg)
        let reference = try await PhotoStore(directory: first).addPhoto(imageData: photo, to: MarkupID(UUID()))

        // A crash mid-write left half a file under the real digest.
        let blobs = second.appendingPathComponent(PhotoStore.blobsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: blobs.appendingPathComponent("\(reference.digest).jpg"))

        let store = try PhotoStore(directory: second)
        let attachment = try await store.addPhoto(imageData: photo, to: MarkupID(UUID()))
        // Old output: blobCorrupted forever — the truncated file was adopted unverified.
        let data = try await store.photoData(for: attachment)
        #expect(FileDurability.sha256(of: data) == attachment.digest)
    }

    // MARK: BH-438

    @Test("A format decoded in full is bounded tighter than one ImageIO subsamples")
    func fullDecodeFormatsAreBoundedTighter() async throws {
        let directory = try workspace("bomb")
        defer { try? FileManager.default.removeItem(at: directory) }
        var budget = PhotoBudget.standard
        budget.fullDecodeSourcePixels = 1_000
        let store = try PhotoStore(directory: directory, budget: budget)
        // 40 × 40 = 1 600 px, over the 1 000 px full-decode bound. Old output: accepted.
        await #expect(throws: PhotoImportRefusal.self) {
            try await store.addPhoto(imageData: try self.image(width: 40, height: 40, type: .png), to: MarkupID(UUID()))
        }
        // The same pixel count as JPEG is subsampled during decode and stays accepted.
        _ = try await store.addPhoto(imageData: try image(width: 40, height: 40, type: .jpeg), to: MarkupID(UUID()))
    }

    // MARK: BH-439

    @Test("The size bound follows a symbolic link to its target")
    func symlinkIsBoundedByItsTarget() async throws {
        let directory = try workspace("symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        var budget = PhotoBudget.standard
        budget.sourceBytes = 1_000
        let target = directory.appendingPathComponent("big.png")
        try Data(repeating: 0x41, count: 50_000).write(to: target)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = try PhotoStore(directory: directory.appendingPathComponent("store"), budget: budget)
        // Old behaviour: the link's own few bytes passed the guard and all 50 000 were read.
        await #expect(throws: PhotoImportRefusal.sourceTooLarge(bytes: 1_001, limit: 1_000)) {
            try await store.addPhoto(contentsOf: link, to: MarkupID(UUID()))
        }
    }

    // MARK: BH-440, BH-441

    @Test("A sub-second capture time survives reopen; interrupted temporary files are swept")
    func captureTimeAndTemporaryFiles() async throws {
        let directory = try workspace("manifest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let taken = Date(timeIntervalSince1970: 1_700_000_000.25)
        let added = try await PhotoStore(directory: directory).addPhoto(
            imageData: try image(width: 32, height: 32, type: .jpeg), to: MarkupID(UUID()), capturedAt: taken
        )
        let stray = directory.appendingPathComponent(".photo-manifest.json.DEADBEEF.tmp")
        try Data("half".utf8).write(to: stray)

        let reopened = try PhotoStore(directory: directory)
        // Old output: 1_700_000_000 — whole seconds only, so the attachment no longer matched.
        #expect(await reopened.allAttachments() == [added])
        // Old output: the stray stayed in the package forever.
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: BH-442

    @Test("A digit with a combining mark is not hex")
    func combiningMarkIsNotHex() {
        let hex = String(repeating: "a", count: 63)
        #expect(PhotoStore.isWellFormedDigest(hex + "5"))
        // Old output: true — "5\u{301}" sorted between "5" and "6".
        #expect(!PhotoStore.isWellFormedDigest(hex + "5\u{301}"))
    }
}
