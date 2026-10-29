import Foundation
import Testing
@testable import ZPDFSpreadsheet

/// R-212: one stored-zip format. The streaming writer Send Project uses and the in-memory
/// writer the packs use produce the same bytes, and the reader reads both back.
@Suite("Stored zip — one format, streamed or in memory (R-212)")
struct ZipStoredStreamWriterTests {

    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-stream-\(UUID().uuidString).zip", isDirectory: false)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    @Test("The streamed archive is byte for byte the in-memory archive, and reads back with its CRCs")
    func streamedEqualsInMemory() throws {
        let entries: [(String, Data)] = [
            ("Project.zpdfproj/manifest.json", Data(#"{"a":1}"#.utf8)),
            ("Project.zpdfproj/documents/original.pdf", Data((0..<70_000).map { UInt8($0 % 251) })),
            ("Project.zpdfproj/empty.bin", Data())
        ]
        var memory = ZipStoredWriter()
        for (name, data) in entries { try memory.add(name, data: data) }
        let expected = try memory.archive()

        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        var stream = ZipStoredStreamWriter(writingTo: handle)
        for (name, data) in entries { try stream.addFile(name, data: data) }
        try stream.finish()
        try handle.close()
        let streamed = try Data(contentsOf: url)

        #expect(streamed == expected)
        let reader = try ZipArchiveReader(data: streamed)
        for (name, data) in entries {
            // `contents(of:)` verifies each entry's CRC-32 against the bytes.
            #expect(try reader.contents(of: name) == data)
        }
    }

    @Test("A directory entry is its name with a slash and no bytes; unsafe and duplicate names are refused")
    func directoriesAndRefusals() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var stream = ZipStoredStreamWriter(writingTo: handle)
        try stream.addDirectory("Project.zpdfproj/recovery")
        #expect(throws: ZipStoredWriter.WriteError.unsafeName("../escape")) {
            try stream.addFile("../escape", data: Data([1]))
        }
        #expect(throws: ZipStoredWriter.WriteError.unsafeName("a\\b")) {
            try stream.addFile("a\\b", data: Data([1]))
        }
        try stream.addFile("Project.zpdfproj/x", data: Data([1]))
        #expect(throws: ZipStoredWriter.WriteError.duplicateEntry("Project.zpdfproj/x")) {
            try stream.addFile("Project.zpdfproj/x", data: Data([2]))
        }
        try stream.finish()
        let reader = try ZipArchiveReader(data: try Data(contentsOf: url))
        #expect(reader.entries.map(\.name) == ["Project.zpdfproj/recovery/", "Project.zpdfproj/x"])
        #expect(reader.entry(named: "Project.zpdfproj/recovery/")?.uncompressedSize == 0)
    }

    @Test("CRC-32 matches the published check value")
    func crcCheckValue() {
        // The standard CRC-32/ISO-HDLC check value for "123456789".
        #expect(ZipCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
