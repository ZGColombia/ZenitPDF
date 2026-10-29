import Foundation
import Testing
@testable import ZPDFSpreadsheet

/// Live test 8, L-67: a pack listed "Väster Testmall" as "V+?ster Testmall", and the `unzip` that
/// ships with macOS refused to extract it ("Illegal byte sequence"). The names were UTF-8 and
/// flagged so (general-purpose bit 11), but the central record said the archive was made on
/// MS-DOS, and an `unzip` that does not read bit 11 translates every MS-DOS name from an OEM
/// code page. The records now say Unix, with ordinary permissions.
@Suite("L-67 — UTF-8 entry names a stock unzip reads")
struct L8ZipEntryNameTests {

    static let name = "templates/Väster Testmall.zpdftemplate"

    /// Every central-directory record: (version made by, flags, external attributes, name).
    static func centralRecords(_ data: Data) -> [(madeBy: Int, flags: Int, external: UInt32, name: String)] {
        let bytes = [UInt8](data)
        func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func le32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        var records: [(Int, Int, UInt32, String)] = []
        var index = 0
        while index + 46 <= bytes.count {
            if le32(index) == 0x0201_4b50 {
                let nameLength = le16(index + 28)
                let name = String(decoding: bytes[(index + 46)..<(index + 46 + nameLength)], as: UTF8.self)
                records.append((le16(index + 4), le16(index + 8), le32(index + 38), name))
                index += 46 + nameLength
            } else {
                index += 1
            }
        }
        return records.map { (madeBy: $0.0, flags: $0.1, external: $0.2, name: $0.3) }
    }

    @Test("The central record says Unix, the name is flagged UTF-8, and a file reads rw-r--r--")
    func recordsSayUnix() throws {
        var writer = ZipStoredWriter()
        try writer.add(Self.name, data: Data("{}".utf8))
        let archive = try writer.archive()
        let records = Self.centralRecords(archive)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.name == Self.name)
        // Old output: 0x0014 — host 0, MS-DOS — with external attributes 0.
        #expect(record.madeBy == 0x0314)
        #expect(record.flags & 0x0800 != 0, "the name is flagged UTF-8")
        #expect(record.external >> 16 == 0o100644)
        // The reader still reads it back, byte for byte.
        #expect(try ZipArchiveReader(data: archive).contents(of: Self.name) == Data("{}".utf8))
    }

    @Test("A directory entry streamed into an archive reads as a directory with drwxr-xr-x")
    func directoryAttributes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("l8-zip-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        var stream = ZipStoredStreamWriter(writingTo: handle)
        try stream.addDirectory("Väster.zpdfproj")
        try stream.addFile("Väster.zpdfproj/manifest.json", data: Data("{}".utf8))
        try stream.finish()
        try handle.close()
        let records = Self.centralRecords(try Data(contentsOf: url))
        #expect(records.map(\.name) == ["Väster.zpdfproj/", "Väster.zpdfproj/manifest.json"])
        #expect(records[0].external >> 16 == 0o040755)
        #expect(records[0].external & 0x10 != 0)
        #expect(records[1].external >> 16 == 0o100644)
        #expect(records.allSatisfy { $0.madeBy == 0x0314 })
    }

    @Test("The system unzip lists and extracts the name as it was written")
    func systemUnzipReadsTheName() throws {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l8-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var writer = ZipStoredWriter()
        try writer.add(Self.name, data: Data("{}".utf8))
        let archive = folder.appendingPathComponent("Pack.zpdfpack")
        try writer.archive().write(to: archive)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: unzip)
        process.arguments = ["-q", archive.path, "-d", folder.appendingPathComponent("out").path]
        process.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // Old output: "error: cannot create out/templates/V+?ster Testmall.zpdftemplate — Illegal
        // byte sequence", exit status 50, and nothing extracted.
        #expect(process.terminationStatus == 0)
        let extracted = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("out/templates").path)
        #expect(extracted.map { $0.precomposedStringWithCanonicalMapping } == ["Väster Testmall.zpdftemplate"])
    }
}
