import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFVectorExtraction

/// NL-AUTO-17: a symbol saved in one project is found in another.
struct SymbolLibraryTests {

    static func temporaryLibrary() -> SymbolLibrary {
        SymbolLibrary(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-symbols-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.json"))
    }

    @Test("Save D-12 in project A; in project B the library exemplar finds the D-12s")
    func learnsByExample() throws {
        let library = Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.fileURL.deletingLastPathComponent()) }
        // Project A: the door at (100, 100), boxed and saved.
        let projectA = SymbolCountReviewTests.door(10, at: CGPoint(x: 100, y: 100))
        let exemplar = try SymbolExemplar(primitives: projectA, region: VectorBounds(minX: 95, minY: 95, maxX: 125, maxY: 117))
        try library.add(designation: "D-12", exemplar: exemplar, at: Date(timeIntervalSince1970: 1_000))

        // Project B, another file on another day: three doors at other places, one rotated.
        var projectB = SymbolCountReviewTests.door(500, at: CGPoint(x: 40, y: 700))
        projectB += SymbolCountReviewTests.door(600, at: CGPoint(x: 300, y: 50))
        projectB += SymbolCountReviewTests.door(700, at: CGPoint(x: 520, y: 400))
        let saved = try #require(try library.entries().first)
        #expect(saved.designation == "D-12")
        #expect(saved.exemplar == exemplar, "the exemplar survives the file exactly")
        let report = try SymbolMatcher().matches(exemplar: saved.exemplar, in: projectB)
        #expect(report.confirmed.count == 3)
    }

    @Test("Saving a designation again replaces it; removing and an unreadable file are handled honestly")
    func replaceRemoveAndRefuse() throws {
        let library = Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.fileURL.deletingLastPathComponent()) }
        let door = SymbolCountReviewTests.door(10, at: CGPoint(x: 100, y: 100))
        let exemplar = try SymbolExemplar(primitives: door, region: VectorBounds(minX: 95, minY: 95, maxX: 125, maxY: 117))
        try library.add(designation: "D-12", exemplar: exemplar, at: Date(timeIntervalSince1970: 1))
        try library.add(designation: "F-01", exemplar: exemplar, at: Date(timeIntervalSince1970: 2))
        let again = try library.add(designation: "d-12", exemplar: exemplar, at: Date(timeIntervalSince1970: 3))
        #expect(try library.entries().map(\.designation) == ["d-12", "F-01"])
        try library.remove(id: again.id)
        #expect(try library.entries().map(\.designation) == ["F-01"])

        try Data("not a library".utf8).write(to: library.fileURL)
        #expect(throws: SymbolLibrary.LibraryError.self) { try library.entries() }
        // Refusing to read never overwrote what was there.
        #expect(try String(contentsOf: library.fileURL, encoding: .utf8) == "not a library")
    }
}
