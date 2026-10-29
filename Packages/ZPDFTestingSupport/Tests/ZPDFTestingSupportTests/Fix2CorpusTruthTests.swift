import CoreGraphics
import Foundation
import os
import SQLite3
import Testing
@testable import ZPDFTestingSupport

/// The corpus must say what its files contain, and its plumbing must not
/// fail or go stale on its own. Each test names the finding it pins.
struct Fix2CorpusTruthTests {

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func latin1(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .isoLatin1))
    }

    // MARK: - BH-700 / BH-701: concurrent streaming generation

    @Test("BH-700/BH-701: concurrent cold-cache makes of a streaming fixture all succeed")
    func concurrentStreamingMakesDoNotRace() throws {
        // The old exists-then-moveItem window is microseconds wide and did not trip in 40
        // rounds of 16 writers on this machine, so this stress test guards the outcome
        // and `moveIntoPlaceReplacesAnExistingFile` pins the mechanism.
        for round in 0..<8 {
            let directory = try makeTemporaryDirectory("Fix2Race\(round)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let failures = OSAllocatedUnfairLock(initialState: [String]())
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    _ = try ZPDFFixtures.make(.threeHundredPages, in: directory)
                } catch {
                    failures.withLock { $0.append("\(error)") }
                }
            }
            let messages = failures.withLock { $0 }
            #expect(messages.isEmpty, "round \(round): \(messages)")
            let expected = try ZPDFFixtures.data(.threeHundredPages).data
            #expect(try Data(contentsOf: directory.appendingPathComponent(FixtureKind.threeHundredPages.fileName)) == expected)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".partial") }
            #expect(leftovers.isEmpty, "partial files left behind: \(leftovers)")
        }
    }

    @Test("BH-700/BH-701: moving a finished file into place replaces one that appeared meanwhile")
    func moveIntoPlaceReplacesAnExistingFile() throws {
        // Old: the streaming path branched on fileExists and then called moveItem, which
        // throws NSFileWriteFileExistsError when another writer published first.
        let directory = try makeTemporaryDirectory("Fix2Move")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("fixture.pdf")
        let partial = directory.appendingPathComponent(".fixture.pdf.x.partial")

        try Data("first".utf8).write(to: partial)
        try ZPDFFixtures.moveIntoPlace(partial, over: destination)
        #expect(try Data(contentsOf: destination) == Data("first".utf8))

        // Another writer's file is already at the destination: rename over it.
        try Data("second".utf8).write(to: partial)
        #expect(throws: (any Error).self) { try FileManager.default.moveItem(at: partial, to: destination) }
        try ZPDFFixtures.moveIntoPlace(partial, over: destination)
        #expect(try Data(contentsOf: destination) == Data("second".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - BH-676 / BH-677 / BH-698 / BH-699: cache stamp

    @Test("BH-676/BH-677/BH-698/BH-699: a same-length change to a cached file is regenerated, not served")
    func sameLengthEditIsNotServedFromCache() throws {
        // Old output: make(.rectangle) returned wasGenerated == false and handed back the
        // edited bytes, because the stamp held only (generatorVersion, byteCount).
        let directory = try makeTemporaryDirectory("Fix2Stamp")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ZPDFFixtures.make(.rectangle, in: directory)
        var bytes = try Data(contentsOf: first.url)
        let text = try latin1(bytes)
        // Rewrite one media-box digit in place: same length, different geometry.
        let range = try #require(text.range(of: "/MediaBox [0 0 612 792]"))
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + "/MediaBox [0 0 61".count
        bytes[offset] = UInt8(ascii: "3")
        try bytes.write(to: first.url)
        #expect(bytes.count == first.byteCount)

        let second = try ZPDFFixtures.make(.rectangle, in: directory)
        #expect(second.wasGenerated)
        #expect(try Data(contentsOf: second.url) == ZPDFFixtures.data(.rectangle).data)
    }

    @Test("BH-676/BH-698: a stamp for a different manifest, or in the old two-field format, is not a cache hit")
    func stampCarriesTheManifestDigest() throws {
        let directory = try makeTemporaryDirectory("Fix2StampManifest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ZPDFFixtures.make(.lShape, in: directory)
        let stampURL = directory.appendingPathComponent(FixtureKind.lShape.fileName + ".stamp")
        let stampText = try String(contentsOf: stampURL, encoding: .utf8)
        var stamp = try #require(ZPDFFixtures.CacheStamp(text: stampText))
        #expect(stamp.manifestDigest == (try ZPDFFixtures.digest(of: first.manifest)))

        // The generator's manifest moved (a vertex, a name, a note): the cached file is stale.
        stamp.manifestDigest = try ZPDFFixtures.digest(of: ZPDFFixtures.manifest(for: .rectangle))
        try stamp.text.write(to: stampURL, atomically: true, encoding: .utf8)
        #expect(try ZPDFFixtures.make(.lShape, in: directory).wasGenerated)

        // An old-format stamp (version, byte count) is never trusted.
        try "\(ZPDFFixtures.generatorVersion)\n\(first.byteCount)\n".write(to: stampURL, atomically: true, encoding: .utf8)
        #expect(try ZPDFFixtures.make(.lShape, in: directory).wasGenerated)
        #expect(try !ZPDFFixtures.make(.lShape, in: directory).wasGenerated)
    }

    // MARK: - BH-220 / BH-680 / BH-681 / BH-682: missingObject

    @Test("BH-220/BH-680/BH-681/BH-682: missingObject's notes describe only defects the file carries")
    func missingObjectNotesMatchTheFile() throws {
        // Old output: the manifest note said "object 2's body is present in the xref table
        // but omitted from the file body", while the file contained "2 0 obj" in full.
        let fixture = try ZPDFFixtures.data(.missingObject)
        let text = try latin1(fixture.data)
        let sizeRange = try #require(text.range(of: #"/Size (\d+)"#, options: .regularExpression))
        let size = try #require(Int(text[sizeRange].dropFirst("/Size ".count)))
        for number in 1..<size {
            #expect(text.contains("\n\(number) 0 obj\n"), "object \(number) is declared but has no body")
        }
        #expect(!text.contains("\(HostileFixtures.missingObjectNumber) 0 obj"))
        let notes = fixture.manifest.notes.joined(separator: " ")
        #expect(!notes.contains("omitted from the file body"))
        #expect(notes.contains("object 2"))
    }

    // MARK: - BH-221: /RBGroups location

    @Test("BH-221: threeLayers carries /RBGroups in the /D configuration dictionary")
    func radioGroupsLiveInTheDefaultConfiguration() throws {
        // Old output: CGPDFDictionaryGetArray(/D, "RBGroups") was false — the array sat
        // beside /OCGs in /OCProperties, where PDF 32000-1 Table 100 has no such key.
        let fixture = try ZPDFFixtures.data(.threeLayers)
        let provider = try #require(CGDataProvider(data: fixture.data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let catalog = try #require(document.catalog)
        var properties: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties))
        var configuration: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(try #require(properties), "D", &configuration))
        var groups: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(try #require(configuration), "RBGroups", &groups))
        let radio = try #require(groups)
        #expect(CGPDFArrayGetCount(radio) == 1)
        var members: CGPDFArrayRef?
        #expect(CGPDFArrayGetArray(radio, 0, &members))
        #expect(CGPDFArrayGetCount(try #require(members)) == 2)
        // The transitional copy beside /OCGs is gone now the layer reader reads /D (BH-221):
        // /OCProperties carries no /RBGroups key of its own.
        var stray: CGPDFArrayRef?
        #expect(!CGPDFDictionaryGetArray(try #require(properties), "RBGroups", &stray))
    }

    // MARK: - BH-675: raster dimensions

    @Test("BH-675: an image whose samples do not fill its declared size is refused")
    func rasterDimensionsMustMatchSamples() throws {
        // Old: addGrayImage wrote /Width 9000 over 8192 x 10 clamped samples, silently.
        let samples = RasterPattern.scannedTextPage(width: 9_000, height: 10, seed: 7)
        #expect(samples.count == RasterPattern.maximumSide * 10)
        let builder = PDFDocumentBuilder(kind: .scannedLookPage)
        #expect(throws: FixtureError.self) {
            _ = try ContentFixtures.addGrayImage(
                builder: builder, kind: .scannedLookPage, samples: samples, width: 9_000, height: 10
            )
        }
        let fitting = RasterPattern.scannedTextPage(width: 64, height: 10, seed: 7)
        _ = try ContentFixtures.addGrayImage(
            builder: builder, kind: .scannedLookPage, samples: fitting, width: 64, height: 10
        )
    }

    // MARK: - BH-678 / BH-679: unbalanced Q

    @Test("BH-678/BH-679: the malformed stream's note states its real unbalanced-Q count")
    func unbalancedRestoreCountMatchesTheNote() throws {
        // Old output: the note said "12 unbalanced `Q` operators"; the stream has 18 951.
        let fixture = try ZPDFFixtures.data(.hugeMalformedOperatorStream)
        let text = try latin1(fixture.data)
        let start = try #require(text.range(of: "stream\n"))
        let end = try #require(text.range(of: "\nendstream", range: start.upperBound..<text.endIndex))
        let tokens = text[start.upperBound..<end.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\n" })
        let saves = tokens.filter { $0 == "q" }.count
        let restores = tokens.filter { $0 == "Q" }.count
        let unbalanced = restores - saves
        #expect(unbalanced == GeometricFixtures.malformedStreamUnbalancedRestores)
        #expect(unbalanced > 12)
        let notes = fixture.manifest.notes.joined(separator: " ")
        #expect(notes.contains("\(unbalanced) unbalanced `Q`"))
        #expect(!notes.contains(" 12 unbalanced"))
    }

    // MARK: - BH-683 / BH-684 / BH-685: bomb size

    @Test("BH-683/BH-684/BH-685: the bomb inflates to exactly declaredInflatedByteCount")
    func bombInflatesToTheDeclaredSize() throws {
        // Old output: inflated 67 108 860 bytes against a declared 67 108 864.
        let fixture = try ZPDFFixtures.data(.decompressionBomb)
        let declared = try #require(fixture.manifest.declaredInflatedByteCount)
        let data = fixture.data
        let text = try latin1(data)
        let lengthRange = try #require(text.range(of: #"/Length (\d+) /Filter /FlateDecode"#, options: .regularExpression))
        let lengthText = text[lengthRange].split(separator: " ")[1]
        let length = try #require(Int(lengthText))
        let streamStart = try #require(text.range(of: "stream\n", range: lengthRange.upperBound..<text.endIndex))
        let offset = text.distance(from: text.startIndex, to: streamStart.upperBound)
        let zlib = data.subdata(in: offset..<(offset + length))
        // RFC 1950: drop the two-byte header and the four-byte Adler-32 trailer.
        let deflate = zlib.subdata(in: 2..<(zlib.count - 4))
        let inflated = try (deflate as NSData).decompressed(using: .zlib) as Data
        #expect(inflated.count == declared)
        #expect(declared == 64 * 1024 * 1024)
    }

    // MARK: - BH-686: WAL survives executeSQL

    @Test("BH-686: executeSQL keeps committed transactions that are still in the -wal")
    func executeSQLKeepsCommittedWALFrames() throws {
        // Old output: the row count after executeSQL was 1 — the -wal holding the killed
        // writer's committed row was deleted before the edit ran.
        let staging = try makeTemporaryDirectory("Fix2WALStaging")
        let package = try makeTemporaryDirectory("Fix2WALPackage")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: package)
        }
        let stagedDB = staging.appendingPathComponent(HostileProjectPackage.databasePath)
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(stagedDB.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let connection = try #require(writer)
        for sql in [
            "PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
            "CREATE TABLE markup (id TEXT PRIMARY KEY NOT NULL)",
            "PRAGMA wal_checkpoint(TRUNCATE)",
            "INSERT INTO markup VALUES ('committed-in-wal')"
        ] {
            #expect(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        // Snapshot the files while the writer is still open: this is what a killed writer
        // leaves behind — the insert is committed, but only in the -wal.
        for suffix in ["", "-wal", "-shm"] {
            let source = stagedDB.path + suffix
            guard FileManager.default.fileExists(atPath: source) else { continue }
            try FileManager.default.copyItem(
                atPath: source,
                toPath: package.appendingPathComponent(HostileProjectPackage.databasePath).path + suffix
            )
        }
        sqlite3_close_v2(connection)
        #expect(FileManager.default.fileExists(
            atPath: package.appendingPathComponent(HostileProjectPackage.databasePath).path + "-wal"))

        try HostileProjectPackage.executeSQL(inPackageAt: package, ["INSERT INTO markup VALUES ('fixture-edit')"])

        // The main file alone (no -wal left to replay) must hold both rows.
        let mainFile = package.appendingPathComponent(HostileProjectPackage.databasePath)
        let walSize = (try? FileManager.default.attributesOfItem(atPath: mainFile.path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        #expect(walSize == 0)
        var reader: OpaquePointer?
        #expect(sqlite3_open_v2(mainFile.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let readConnection = try #require(reader)
        defer { sqlite3_close_v2(readConnection) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(readConnection, "SELECT count(*) FROM markup", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 2)
    }

    // MARK: - BH-687 / BH-688 / BH-690: page geometry

    @Test("BH-687: a rotation fixture for a non-canonical angle is refused, not filed as rotation270")
    func nonCanonicalRotationIsRefused() throws {
        // Old: rotation(45) returned a .rotation270 manifest whose page carried /Rotate 45.
        for degrees in [45, -90, 360] {
            #expect(throws: FixtureError.self) { _ = try PageGeometryFixtures.rotation(degrees) }
        }
        #expect(try PageGeometryFixtures.rotation(270).manifest.kind == .rotation270)
    }

    @Test("BH-688: the rotation0 fixture carries the explicit /Rotate 0 its title names")
    func rotationZeroIsExplicit() throws {
        // Old: the page dictionary had no /Rotate key at all.
        let fixture = try ZPDFFixtures.data(.rotation0)
        #expect(fixture.manifest.title.contains("/Rotate 0"))
        #expect(try latin1(fixture.data).contains("/Rotate 0 "))
    }

    @Test("BH-690: a sheet too narrow for the 1000 pt scale bar is refused")
    func narrowSheetIsRefused() throws {
        // Old: the bar was recorded from llx + 100 to llx + 1100 on a 612 pt page.
        #expect(throws: FixtureError.self) {
            _ = try PageGeometryFixtures.singleSheet(.sizeA1, box: FixturePageSize.letter, label: "Letter")
        }
    }

    // MARK: - BH-689: condition numbers

    @Test("BH-689: every area record carries a condition number", arguments: FixtureKind.allCases)
    func everyAreaHasAConditionNumber(kind: FixtureKind) throws {
        // Old: the sizeA1, sizeArchD and mixedPageSizes borders had conditionNumber == nil.
        let manifest = try ZPDFFixtures.manifest(for: kind)
        for path in manifest.paths where path.kind == .closedPolygon || path.kind == .polygonWithHoles {
            guard path.area > 0 else { continue }
            let recorded = path.derivation.conditionNumber
            #expect(recorded != nil, "\(kind.rawValue)/\(path.id) has an area but no kappa")
            if let recorded {
                let measured = IndependentGeometry.shoelaceConditionNumber([path.points] + path.holes)
                #expect(IndependentGeometry.relativeError(measured, recorded, floor: 1) <= 1e-9)
            }
        }
    }

    // MARK: - BH-691 / BH-692: fuzz corpus

    @Test("BH-691/BH-692: every fuzz seed kind generates, and a failure would be listed")
    func fuzzCorpusIsComplete() {
        // Old: a throwing kind vanished from FuzzCorpus.bytes through try? with no record.
        #expect(FuzzCorpus.generationFailures.isEmpty, "\(FuzzCorpus.generationFailures)")
        #expect(FuzzCorpus.isComplete)
        #expect(FuzzCorpus.bytes.count == FuzzCorpus.kinds.count)
    }

    // MARK: - BH-693: builder idempotence

    @Test("BH-693: serialising one builder twice yields identical bytes")
    func builderIsIdempotent() throws {
        // Old: the second data() appended a second /Info object, so /Size and length grew.
        let builder = PDFDocumentBuilder(kind: .singleLine)
        var content = PDFContentStream()
        content.move(to: FixturePoint(0, 0))
        content.line(to: FixturePoint(10, 10))
        content.stroke()
        builder.addPage(mediaBox: FixturePageSize.letter, contentObject: try builder.addContentStream(content))
        let first = try builder.data()
        let second = try builder.data()
        #expect(first == second)
        #expect(try latin1(second).components(separatedBy: "/Producer").count - 1 == 1)
    }

    // MARK: - BH-694 / BH-695: tiny numbers

    @Test("BH-694/BH-695: values below 1e-4 are written exponent-free and round-trip exactly")
    func tinyValuesRoundTrip() {
        // Old output: 6.123233995736766e-17 was written "0"; 1.2345678901e-5 as
        // "0.000012345679"; 1/(1000*72/25.4) lost its digits past the twelfth decimal.
        let values: [Double] = [
            1.2345678901e-5, 6.123233995736766e-17, 1 / (1_000 * 72 / 25.4),
            -3.0e-9, 5e-324, 9.999999999999999e-5, -1.0e-10, 0.00001
        ]
        for value in values {
            let text = PDFNumber.string(value)
            #expect(!text.contains("e") && !text.contains("E"), "\(value) -> \(text)")
            #expect(PDFNumber.roundTrips(value), "\(value) -> \(text)")
        }
        #expect(PDFNumber.string(1.2345678901e-5) == "0.000012345678901")
        #expect(PDFNumber.string(-3.0e-9) == "-0.000000003")
    }

    // MARK: - BH-696 / BH-697: writer arithmetic

    @Test("BH-696: a NaN truncation fraction is a typed error, not a trap")
    func nanTruncationIsTyped() throws {
        // Old: Int(NaN) trapped and took the test process down.
        let builder = PDFDocumentBuilder(kind: .truncatedFile)
        var content = PDFContentStream()
        content.move(to: FixturePoint(0, 0))
        content.line(to: FixturePoint(1, 1))
        content.stroke()
        builder.addPage(mediaBox: FixturePageSize.letter, contentObject: try builder.addContentStream(content))
        #expect(throws: FixtureError.self) { _ = try builder.data(corruption: .truncate(keepFraction: .nan)) }
    }

    @Test("BH-697: xref offsets above Int32.max keep their 10-digit field")
    func largeCrossReferenceOffsets() {
        // Old output: "%010d" printed 3 000 000 000 as "-1294967296" (11 characters).
        #expect(RawPDFWriter.crossReferenceOffsetField(3_000_000_000) == "3000000000")
        #expect(RawPDFWriter.crossReferenceOffsetField(Int(Int32.max) + 1) == "2147483648")
        #expect(RawPDFWriter.crossReferenceOffsetField(15) == "0000000015")
        #expect(RawPDFWriter.crossReferenceOffsetField(-4) == "0000000000")
        #expect(RawPDFWriter.crossReferenceOffsetField(20_000_000_000) == "9999999999")
    }
}
