import Foundation
import Testing
@testable import ZPDFExport

/// NL-PLAT-08: a saved profile reproduces a receiving system's CSV byte for byte. The reference
/// bytes are written out by hand from the golden ledger's own values.
@Suite("Ledger export profiles — NL-PLAT-08", .sharedHeap)
struct LedgerExportProfileTests {

    static let profile = LedgerExportProfile(
        name: "Nordic estimating import",
        columns: [
            .init(key: "label", header: "Pos"),
            .init(key: "subject", header: "Moment"),
            .init(key: "golden", header: "Mängd", decimals: 2),
            .init(key: "cost", header: "Á-pris", decimals: 1),
        ],
        delimiter: ";", decimalSeparator: ",", encoding: .windows1252, lineEnding: .lf,
        fileNamePattern: "{project} kalkyl {date}"
    )

    @Test("The golden ledger through a Windows-1252, semicolon, decimal-comma profile is the reference file, byte for byte")
    func reproducesReferenceBytes() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let (data, missing) = try Self.profile.render(projection)
        #expect(missing.isEmpty)
        // Golden 0.4449 / 1.005 / 2.675 / −0.004 / 1234567.891 / 8.125 at 2 places (half away from
        // zero, never "-0,00"); cost is golden × 100 at 1 place.
        let reference = "Pos;Moment;M\u{E4}ngd;\u{C1}-pris\n"
            + "L0;Concrete;0,44;44,5\n"
            + "L1;Steel;1,01;100,5\n"
            + "L2;Concrete;2,68;267,5\n"
            + "L3;Steel;0,00;-0,4\n"
            + "L4;Concrete;1234567,89;123456789,1\n"
            + "L5;Steel;8,13;812,5\n"
        let expected = Data(reference.unicodeScalars.map { UInt8($0.value) })   // Latin-1 range = Windows-1252 here
        #expect(data == expected, "\(String(decoding: data, as: UTF8.self))")
        #expect(data.contains(0xE4) && !data.contains(0xC3), "Windows-1252, not UTF-8")
    }

    @Test("A profile survives its file, names missing columns, and a hostile file is refused")
    func fileRoundTripAndRefusals() throws {
        let read = try LedgerExportProfile.read(try Self.profile.encoded())
        #expect(read == Self.profile)
        var withMissing = Self.profile
        withMissing.columns.append(.init(key: "costCode", header: "Konto"))
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        #expect(try withMissing.render(projection).missingKeys == ["costCode"])
        var bad = Self.profile
        bad.delimiter = ","
        bad.decimalSeparator = ","
        #expect(throws: LedgerExportProfile.ProfileError.self) { try LedgerExportProfile.read(try bad.encoded()) }
        #expect(throws: LedgerExportProfile.ProfileError.self) { try LedgerExportProfile.read(Data("{}".utf8)) }
        #expect(Self.profile.fileName(project: "Example Quay/C", date: Date(timeIntervalSince1970: 1_790_000_000)) == "Example Quay-C kalkyl 2026-09-21.csv")
    }

    @Test("A character Windows-1252 cannot hold is refused by name, not replaced")
    func unencodableRefused() throws {
        var profile = Self.profile
        profile.columns[0].header = "Пос"
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        #expect(throws: LedgerExportProfile.ProfileError.notEncodable(character: "П")) { try profile.render(projection) }
    }
}
