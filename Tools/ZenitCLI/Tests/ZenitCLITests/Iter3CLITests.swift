import Foundation
import Testing
import ZPDFPersistence
@testable import ZenitCLICore

/// Iteration 3: the CLI's private copy of a project leaves the saved-version slots
/// and the post-save pictures behind (T-088).
@Suite("Iteration 3 — CLI snapshot", .serialized)
struct Iter3CLITests {

    private static func files(under url: URL) -> [String] {
        let base = url.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let item = item as? URL, (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return String(item.standardizedFileURL.path.dropFirst(base.count + 1))
        }.sorted()
    }

    /// Old output: the copy carried every file of `versions/latest/` — a whole second package —
    /// and the pictures in `thumbnails/`; across volumes each was a real copy.
    @Test("T-088: the snapshot leaves versions/ and the pictures behind, and the project still loads and verifies")
    func snapshotLeavesTheVersionSlotsBehind() async throws {
        let saved = try await ZenitCLIEndToEndTests.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let thumbnails = saved.package.appendingPathComponent(ProjectPackageLayout.thumbnails, isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try Data("summary".utf8).write(to: thumbnails.appendingPathComponent("summary.json"))
        let original = Self.files(under: saved.package)
        #expect(original.contains { $0.hasPrefix("\(ProjectPackageLayout.versions)/") }, "the fixture's save filled a version slot")

        let copied = try await ProjectReader.withSnapshot(of: saved.package) { copy -> [String] in
            for excluded in ProjectReader.snapshotExclusions {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: copy.appendingPathComponent(excluded).path, isDirectory: &isDirectory)
                let wasThere = FileManager.default.fileExists(atPath: saved.package.appendingPathComponent(excluded).path)
                #expect(exists == wasThere && (!exists || isDirectory.boolValue), "\(excluded) keeps its place, empty")
            }
            return Self.files(under: copy)
        }
        let expected = original.filter { path in
            !ProjectReader.snapshotExclusions.contains { path == $0 || path.hasPrefix("\($0)/") }
        }
        #expect(copied == expected, "everything else is copied, byte for byte in name")
        #expect(copied.contains(ProjectPackageLayout.manifest))
        #expect(copied.contains(ProjectPackageLayout.database))
        #expect(copied.contains(ProjectPackageLayout.integrity))

        // The commands that read the copy still work on it.
        let loaded = try await ProjectReader(url: saved.package).load()
        #expect(loaded.markupCount == 3)
        let verification = try await ProjectReader.verify(saved.package)
        #expect(verification.isSound)
        #expect(verification.closedCleanly)
    }
}
