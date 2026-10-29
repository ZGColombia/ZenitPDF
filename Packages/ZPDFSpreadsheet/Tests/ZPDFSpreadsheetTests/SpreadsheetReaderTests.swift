import Compression
import Foundation
import Testing
@testable import ZPDFSpreadsheet

/// NL-PLAT-07, the reader: a workbook comes back as cell texts, and a hostile archive is refused
/// before anything is inflated.
@Suite("Spreadsheet reader — NL-PLAT-07")
struct SpreadsheetReaderTests {

    // MARK: A minimal zip writer for fixtures (stored or raw-DEFLATE entries)

    struct FixtureEntry {
        var name: String
        var data: Data
        var deflate = true
        /// Overrides for hostile fixtures.
        var declaredSize: Int?
        var crc: UInt32?
    }

    static func rawDeflate(_ data: Data) -> Data {
        let capacity = max(64, data.count + 1024)
        var output = Data(count: capacity)
        let written = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        output.count = written
        return output
    }

    static func zip(_ entries: [FixtureEntry]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var out = Data()
        var central = Data()
        for entry in entries {
            let payload = entry.deflate ? rawDeflate(entry.data) : entry.data
            let crc = entry.crc ?? ZipCRC32.checksum(entry.data)
            let size = UInt32(entry.declaredSize ?? entry.data.count)
            let name = Data(entry.name.utf8)
            let offset = UInt32(out.count)
            out.append(contentsOf: le32(0x0403_4b50) + le16(20) + le16(0) + le16(entry.deflate ? 8 : 0) + le16(0) + le16(0))
            out.append(contentsOf: le32(crc) + le32(UInt32(payload.count)) + le32(size) + le16(name.count) + le16(0))
            out.append(name); out.append(payload)
            central.append(contentsOf: le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(entry.deflate ? 8 : 0) + le16(0) + le16(0))
            central.append(contentsOf: le32(crc) + le32(UInt32(payload.count)) + le32(size) + le16(name.count) + le16(0) + le16(0))
            central.append(contentsOf: le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count))
        out.append(contentsOf: le32(UInt32(central.count)) + le32(centralOffset) + le16(0))
        return out
    }

    static func workbook(sheetXML: String, sharedStrings: [String]) -> Data {
        let sst = "<?xml version=\"1.0\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + sharedStrings.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
        return zip([
            FixtureEntry(name: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            FixtureEntry(name: "xl/workbook.xml", data: Data("""
            <?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Ledger" sheetId="1" r:id="rId1"/><sheet name="Zenit" sheetId="2" r:id="rId2"/></sheets></workbook>
            """.utf8)),
            FixtureEntry(name: "xl/_rels/workbook.xml.rels", data: Data("""
            <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="worksheet" Target="worksheets/sheet2.xml"/></Relationships>
            """.utf8), deflate: false),
            FixtureEntry(name: "xl/sharedStrings.xml", data: Data(sst.utf8)),
            FixtureEntry(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8)),
            FixtureEntry(name: "xl/worksheets/sheet2.xml", data: Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Format</t></is></c></row></sheetData></worksheet>".utf8)),
        ])
    }

    // MARK: Reading

    @Test("Shared strings, inline strings, numbers as literal text, and gaps in rows and columns")
    func readsCells() throws {
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
        <row r="3"><c r="A3" t="inlineStr"><is><t>Slab &amp; beam</t></is></c><c r="B3"><v>12.345678901234567890</v></c><c r="C3" t="b"><v>1</v></c></row>
        </sheetData></worksheet>
        """
        let reader = try XLSXWorkbookReader(data: Self.workbook(sheetXML: sheet, sharedStrings: ["Subject", "Unit Cost (SEK)"]))
        let ledger = try #require(reader.sheet(named: "Ledger"))
        #expect(ledger.cell(row: 0, column: 0) == "Subject")
        #expect(ledger.cell(row: 0, column: 1) == nil)
        #expect(ledger.cell(row: 0, column: 2) == "Unit Cost (SEK)")
        #expect(ledger.cell(row: 1, column: 0) == nil)
        #expect(ledger.cell(row: 2, column: 0) == "Slab & beam")
        #expect(ledger.cell(row: 2, column: 1) == "12.345678901234567890", "the literal, never a Double")
        #expect(ledger.cell(row: 2, column: 2) == "TRUE")
        #expect(reader.sheet(named: "Zenit")?.cell(row: 0, column: 0) == "Format")
        #expect(XLSXWorkbookReader.columnIndex(of: "AA10") == 26)
        #expect(XLSXWorkbookReader.columnIndex(of: "XFD1") == 16_383)
    }

    // MARK: Hostile archives

    @Test("A zip bomb is refused from its directory, before inflation")
    func zipBombRefused() throws {
        let zeros = Data(count: 20_000_000)   // deflates to ~20 KB: a ratio near 1000
        let bomb = Self.zip([FixtureEntry(name: "xl/worksheets/sheet1.xml", data: zeros)])
        #expect(bomb.count < 100_000)
        do {
            _ = try ZipArchiveReader(data: bomb)
            Issue.record("the bomb was accepted")
        } catch let ZipError.suspiciousRatio(entry, ratio, limit) {
            #expect(entry == "xl/worksheets/sheet1.xml")
            #expect(ratio > limit)
        }
    }

    @Test("An entry that inflates past its declared size is stopped at the declared size")
    func lyingHeaderStopped() throws {
        let body = Data(repeating: UInt8(ascii: "a"), count: 50_000)
        let lying = Self.zip([FixtureEntry(name: "x.xml", data: body, declaredSize: 1_000)])
        let reader = try ZipArchiveReader(data: lying, limits: ZipLimits(maximumCompressionRatio: 10_000))
        #expect(throws: ZipError.self) { try reader.contents(of: "x.xml") }
    }

    @Test("Too many entries, a bad checksum, encryption-free junk and a non-zip are each refused")
    func otherRefusals() throws {
        let many = Self.zip((0..<30).map { FixtureEntry(name: "e\($0)", data: Data("x".utf8), deflate: false) })
        #expect(throws: ZipError.tooManyEntries(count: 30, limit: 10)) {
            try ZipArchiveReader(data: many, limits: ZipLimits(maximumEntryCount: 10))
        }
        let badCRC = Self.zip([FixtureEntry(name: "a", data: Data("hello".utf8), deflate: false, crc: 1)])
        #expect(throws: ZipError.checksumMismatch(entry: "a")) { try ZipArchiveReader(data: badCRC).contents(of: "a") }
        #expect(throws: ZipError.notAZip) { try ZipArchiveReader(data: Data("not a zip at all, just text".utf8)) }
        #expect(throws: SpreadsheetError.self) { try XLSXWorkbookReader(data: Self.zip([FixtureEntry(name: "a", data: Data("x".utf8))])) }
    }
}
