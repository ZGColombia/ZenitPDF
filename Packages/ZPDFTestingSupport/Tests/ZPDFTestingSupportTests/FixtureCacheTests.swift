import Foundation
import Testing
import ZPDFTestingSupport

/// The caching contract: a fixture is generated once per directory, reused afterwards,
/// and regenerated when the file on disk no longer matches its stamp.
struct FixtureCacheTests {

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZPDFFixtureCache-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A fixture is generated once and reused afterwards")
    func secondCallReusesTheFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ZPDFFixtures.make(.rectangle, in: directory)
        #expect(first.wasGenerated)

        let second = try ZPDFFixtures.make(.rectangle, in: directory)
        #expect(!second.wasGenerated)
        #expect(second.url == first.url)
        #expect(second.byteCount == first.byteCount)
        #expect(second.manifest == first.manifest)
    }

    @Test("A missing stamp forces regeneration")
    func missingStampForcesRegeneration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ZPDFFixtures.make(.lShape, in: directory)
        #expect(first.wasGenerated)

        let stamp = directory.appendingPathComponent(FixtureKind.lShape.fileName + ".stamp")
        try FileManager.default.removeItem(at: stamp)

        let second = try ZPDFFixtures.make(.lShape, in: directory)
        #expect(second.wasGenerated)
    }

    @Test("A file whose size no longer matches its stamp is regenerated")
    func staleFileIsRegenerated() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ZPDFFixtures.make(.singleLine, in: directory)
        #expect(first.wasGenerated)

        // Corrupt the cached file by truncating it.
        try Data("not a pdf".utf8).write(to: first.url, options: .atomic)

        let second = try ZPDFFixtures.make(.singleLine, in: directory)
        #expect(second.wasGenerated)
        #expect(second.byteCount == first.byteCount)
        let bytes = try Data(contentsOf: second.url)
        #expect(bytes.starts(with: Array("%PDF-1.7".utf8)))
    }

    @Test("make(_:in:) creates the directory when it does not exist")
    func directoryIsCreated() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)

        let handle = try ZPDFFixtures.make(.rotation90, in: nested)
        #expect(FileManager.default.fileExists(atPath: handle.url.path))
    }

    @Test("A path that exists and is not a directory is a typed error, not a crash")
    func nonDirectoryPathIsTypedError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("occupied", isDirectory: false)
        try Data("x".utf8).write(to: file)

        #expect(throws: FixtureError.self) {
            _ = try ZPDFFixtures.make(.rectangle, in: file)
        }
    }

    @Test("makeAll writes the whole corpus into one directory")
    func makeAllWritesEverything() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handles = try ZPDFFixtures.makeAll(in: directory)
        #expect(handles.count == FixtureKind.allCases.count)
        for handle in handles {
            #expect(FileManager.default.fileExists(atPath: handle.url.path), "\(handle.kind.rawValue) missing")
            #expect(handle.byteCount > 0)
        }
        #expect(Set(handles.map(\.url)).count == handles.count, "two fixtures share a file name")
    }

    @Test("The streaming path produces the same bytes as the buffered path")
    func streamingMatchesBuffered() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for kind in [FixtureKind.threeHundredPages, .oneThousandPages] {
            let handle = try ZPDFFixtures.make(kind, in: directory)
            let streamed = try Data(contentsOf: handle.url)
            let buffered = try ZPDFFixtures.data(kind)
            #expect(streamed == buffered.data, "\(kind.rawValue): streamed and buffered bytes differ")
        }
    }
}
