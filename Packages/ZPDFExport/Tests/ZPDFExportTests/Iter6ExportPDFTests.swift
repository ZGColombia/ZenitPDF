import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

/// Iteration 6: W-055 (the embedded-takeoff reader is bounded on open) and
/// W-058 (the layered and flattened writers use the shared same-item rule). Each test says what
/// the code before the fix did.
@Suite("Iteration 6 — PDF export", .sharedHeap, .serialized)
struct Iter6ExportPDFTests {

    // MARK: - W-055

    /// A one-page drawing whose catalog `/AF` lists one Zenit file specification per entry, in
    /// order. Each payload is Flate-encoded into its own embedded-file stream, or, with
    /// `sharingOneStream`, every entry names the first entry's stream. `streamKeys` adds
    /// dictionary text to the stream of the entry it names.
    static func drawing(
        carrying entries: [(name: String, payload: Data)],
        sharingOneStream: Bool = false,
        streamKeys: [String: String] = [:]
    ) -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            var specs: [Int] = []
            var shared: Int?
            for entry in entries {
                let stream: Int
                if sharingOneStream, let shared {
                    stream = shared
                } else {
                    let encoded = PDFStreamCodec.flateEncode(entry.payload) ?? entry.payload
                    let extra = streamKeys[entry.name].map { " " + $0 } ?? ""
                    stream = pdf.addStream("/Type /EmbeddedFile /Filter /FlateDecode" + extra, encoded)
                    shared = stream
                }
                specs.append(pdf.add(
                    "<< /Type /Filespec /F (\(entry.name)) /UF (\(entry.name)) /EF << /F \(stream) 0 R >>"
                        + " /AFRelationship /Supplement"
                        + " /\(StandardAnnotationWriter.takeoffKey) << /Version 1 /SourceLength 8 /SourceSHA256 (00) >> >>"
                ))
            }
            let associated = specs.map { "\($0) 0 R" }.joined(separator: " ")
            return ([HardeningPage("0 0 10 10 re f", resources: nil)], "/AF [\(associated)]")
        }
    }

    static func payload(_ byte: UInt8, count: Int) -> Data { Data(repeating: byte, count: count) }

    @Test("W-055: at most eight Zenit entries are read, however many the drawing's /AF lists")
    func readIsCappedAtEightEntries() throws {
        let entries = (0..<20).map { (name: "file-\($0).json", payload: Self.payload(UInt8(65 + $0), count: 100)) }
        let drawing = Self.drawing(carrying: entries)
        #expect(EmbeddedTakeoffReader.mayCarryTakeoff(drawing) == true)
        // Old: every one of the 20 entries was decoded and kept — no limit on the count.
        let found = EmbeddedTakeoffReader.entries(in: drawing)
        #expect(EmbeddedTakeoffReader.maximumEntries == 8)
        #expect(found.map(\.takeoff.fileName) == (0..<8).map { "file-\($0).json" })
        #expect(found.allSatisfy { $0.takeoff.payload.count == 100 })
        // An entry past the eighth is not looked at, by name or otherwise.
        #expect(EmbeddedTakeoffReader.read(drawing, named: "file-12.json") == nil)
        #expect(EmbeddedTakeoffReader.read(drawing, named: "file-7.json")?.takeoff.payload == Self.payload(72, count: 100))
    }

    @Test("W-055: the payloads one read holds share one decoded-byte budget")
    func payloadsShareOneBudget() {
        // Three distinct 1 000-byte payloads against a 2 500-byte budget: the first two decode
        // (1 000 + 1 000 = 2 000), the third would need 1 000 of the 500 left and is refused.
        // Old: every stream had its own 256 MB ceiling, so N entries could hold N × 256 MB.
        let drawing = Self.drawing(carrying: [
            ("a.json", Self.payload(65, count: 1_000)),
            ("b.json", Self.payload(66, count: 1_000)),
            ("c.json", Self.payload(67, count: 1_000)),
        ])
        let found = EmbeddedTakeoffReader.entries(in: drawing, named: nil, stoppingAtFirst: false, decodedByteBudget: 2_500)
        #expect(found.map(\.takeoff.fileName) == ["a.json", "b.json"])
        #expect(found.reduce(0) { $0 + $1.takeoff.payload.count } == 2_000)
        // The shipping budget reads all three.
        #expect(EmbeddedTakeoffReader.entries(in: drawing).count == 3)
    }

    @Test("W-055: a read by name decodes only the entry it returns")
    func readByNameDecodesOnlyThatEntry() {
        // The overlay first, then the session archive, 1 000 bytes each, against a 1 500-byte
        // budget. Decoding everything first (old: `read(_:named:)` decoded every entry, then picked one)
        // spends 1 000 on the overlay and cannot fit the archive in the 500 left; decoding by
        // name spends the budget on the archive alone.
        let drawing = Self.drawing(carrying: [
            (EmbeddedTakeoff.defaultFileName, Self.payload(79, count: 1_000)),
            ("zenit-session.json", Self.payload(83, count: 1_000)),
        ])
        let everything = EmbeddedTakeoffReader.entries(in: drawing, named: nil, stoppingAtFirst: false, decodedByteBudget: 1_500)
        #expect(everything.map(\.takeoff.fileName) == [EmbeddedTakeoff.defaultFileName])
        let archive = EmbeddedTakeoffReader.entries(
            in: drawing, named: "zenit-session.json", stoppingAtFirst: true, decodedByteBudget: 1_500
        )
        #expect(archive.map(\.takeoff.fileName) == ["zenit-session.json"])
        #expect(archive.first?.takeoff.payload == Self.payload(83, count: 1_000))
        // `read(_:)` stops at the first entry that decodes.
        let first = EmbeddedTakeoffReader.entries(in: drawing, named: nil, stoppingAtFirst: true, decodedByteBudget: 1_500)
        #expect(first.map(\.takeoff.fileName) == [EmbeddedTakeoff.defaultFileName])
        #expect(EmbeddedTakeoffReader.read(drawing)?.takeoff.fileName == EmbeddedTakeoff.defaultFileName)
    }

    @Test("W-055: one stream named by several entries is decoded once, and charged once")
    func oneStreamIsDecodedOnce() {
        // Five entries name one 1 000-byte stream; the budget is 1 500. Decoded once, it is
        // charged 1 000 once and all five entries read. Old: the same stream was inflated five
        // times, once per entry — a decompression bomb pointed at by N entries cost N inflations.
        let drawing = Self.drawing(
            carrying: (0..<5).map { (name: "copy-\($0).json", payload: Self.payload(90, count: 1_000)) },
            sharingOneStream: true
        )
        let found = EmbeddedTakeoffReader.entries(in: drawing, named: nil, stoppingAtFirst: false, decodedByteBudget: 1_500)
        #expect(found.count == 5)
        #expect(found.allSatisfy { $0.takeoff.payload == Self.payload(90, count: 1_000) })
    }

    @Test("W-055: a stream that inflates past what is left of the budget is refused while inflating; a later small entry still reads")
    func bombIsRefusedAndTheRestRead() {
        // 4 000 000 bytes of one letter compress to a few kilobytes. Against a 1 000 000-byte
        // budget it is refused at the limit; the 200-byte archive after it decodes.
        let drawing = Self.drawing(carrying: [
            ("bomb.json", Self.payload(66, count: 4_000_000)),
            ("zenit-session.json", Self.payload(83, count: 200)),
        ])
        #expect(drawing.count < 100_000)
        let found = EmbeddedTakeoffReader.entries(in: drawing, named: nil, stoppingAtFirst: false, decodedByteBudget: 1_000_000)
        #expect(found.map(\.takeoff.fileName) == ["zenit-session.json"])
        #expect(found.first?.takeoff.payload.count == 200)
    }

    /// The widest row the PNG predictor accepts: 2^20 − 1 columns of 32 16-bit colours.
    static let widestRowParameters = "/DecodeParms << /Predictor 12 /Columns 1048575 /Colors 32 /BitsPerComponent 16 >>"

    @Test("W-055: a PNG predictor that pads a 2-byte stream to a 64 MB row is held to what is left of the budget")
    func predictorPaddingIsHeldToTheBudget() {
        // The stream inflates to 2 bytes — a tag and one byte of data — which fits a 1 500-byte
        // budget, but undoing the predictor pads that one row to 67 108 800 bytes. Old: the
        // predictor was checked only against the fixed 256 MB ceiling, so the entry came back
        // holding 64 MB and the read held up to 256 MB + 64 MB, past the shared budget.
        let drawing = Self.drawing(
            carrying: [("wide.json", Data([0, 7])), ("zenit-session.json", Self.payload(83, count: 200))],
            streamKeys: ["wide.json": Self.widestRowParameters]
        )
        let found = EmbeddedTakeoffReader.entries(in: drawing, decodedByteBudget: 1_500)
        #expect(found.map(\.takeoff.fileName) == ["zenit-session.json"], "the padded entry is refused, the archive after it still reads")
        #expect(found.first?.takeoff.payload.count == 200)
        // Nothing the reader returns holds more than its budget.
        #expect(found.reduce(0) { $0 + $1.takeoff.payload.count } <= 1_500)
    }

    @Test("W-055: the predictor's output size is known before it is allocated, and checked against the caller's limit")
    func predictorChecksItsLimitUpFront() throws {
        // The case above, at the codec: 2 bytes in, one 67 108 800-byte row out.
        #expect(PDFStreamCodec.undoPNGPredictor(Data([0, 7]), columns: 1_048_575, colors: 32, bitsPerComponent: 16, limit: 1_500) == nil)
        // A row that fits the limit is still padded out to its width.
        #expect(PDFStreamCodec.undoPNGPredictor(Data([0, 7]), columns: 1_000, colors: 1, bitsPerComponent: 8, limit: 1_000) == Data([7]) + Data(count: 999))
        #expect(PDFStreamCodec.undoPNGPredictor(Data([0, 7]), columns: 1_000, colors: 1, bitsPerComponent: 8, limit: 999) == nil)
        let dictionary: [String: PDFObject] = [
            "Filter": .name("FlateDecode"),
            "DecodeParms": .dictionary(["Predictor": .integer(12), "Columns": .integer(1_048_575), "Colors": .integer(32), "BitsPerComponent": .integer(16)]),
        ]
        let encoded = try #require(PDFStreamCodec.flateEncode(Data([0, 7])))
        #expect(PDFStreamCodec.decode(dictionary: dictionary, data: encoded, limit: 1_500) == nil)
        #expect(throws: RedactionUnsupported.self) { try RedactionStreamFilters.decode(dictionary: dictionary, data: encoded, limit: 1_500) }

        // Hand-derived sizes, 4-byte rows (stride 5) with the Up filter (tag 2): two whole rows
        // are 8 bytes; a 7-byte stream is one whole row and a short one padded to 4 (8 bytes);
        // a trailing lone tag byte adds no row (6 bytes in, 4 out).
        let twoRows = Data([2, 1, 2, 3, 4, 2, 1, 1, 1, 1])
        #expect(PDFStreamCodec.undoPNGPredictor(twoRows, columns: 4, colors: 1, bitsPerComponent: 8, limit: 8) == Data([1, 2, 3, 4, 2, 3, 4, 5]))
        #expect(PDFStreamCodec.undoPNGPredictor(twoRows, columns: 4, colors: 1, bitsPerComponent: 8, limit: 7) == nil)
        let shortLast = Data([0, 1, 2, 3, 4, 0, 9])
        #expect(PDFStreamCodec.undoPNGPredictor(shortLast, columns: 4, colors: 1, bitsPerComponent: 8, limit: 8) == Data([1, 2, 3, 4, 9, 0, 0, 0]))
        #expect(PDFStreamCodec.undoPNGPredictor(shortLast, columns: 4, colors: 1, bitsPerComponent: 8, limit: 7) == nil)
        let loneTag = Data([0, 1, 2, 3, 4, 0])
        #expect(PDFStreamCodec.undoPNGPredictor(loneTag, columns: 4, colors: 1, bitsPerComponent: 8, limit: 4) == Data([1, 2, 3, 4]))
        #expect(PDFStreamCodec.undoPNGPredictor(Data(), columns: 1_048_575, colors: 32, bitsPerComponent: 16, limit: 0) == Data())
    }

    // MARK: - W-058

    @Test("W-058: the layered and flattened writers refuse a hard link to the drawing, by the shared same-item rule")
    func writersRefuseAHardLinkToTheDrawing() throws {
        let drawing = try LayeredMarkupExportTests.write(LayeredSourceFixtures.plain(), named: "Plan.pdf")
        defer { try? FileManager.default.removeItem(at: drawing.deletingLastPathComponent()) }
        let hardLink = drawing.deletingLastPathComponent().appendingPathComponent("Plan (hard link).pdf")
        try FileManager.default.linkItem(at: drawing, to: hardLink)
        let original = try Data(contentsOf: drawing)
        let refusal = PDFFlattenError.fileWriteFailed(path: hardLink.path, reason: "the destination is the drawing being exported")

        // Old: each writer compared resolved paths only. "Plan (hard link).pdf" is not
        // "Plan.pdf", so nothing was refused and the export replaced the hard link's name.
        #expect(throws: refusal) {
            _ = try LayeredMarkupExporter().write(source: drawing, pages: [LayeredMarkupExportTests.job()], to: hardLink)
        }
        #expect(throws: refusal) {
            try FlattenedPDFWriter().write(
                shape: .flattened,
                pages: [FlattenPage(page: FlattenedPDFWriterTests.page(), sourcePageIndex: 0, markups: [])],
                content: nil,
                to: hardLink,
                protecting: [drawing]
            )
        }
        #expect(try Data(contentsOf: drawing) == original)
        #expect(try Data(contentsOf: hardLink) == original, "nothing is written under the hard link's name")

        // A destination that is a different file is still written.
        let elsewhere = drawing.deletingLastPathComponent().appendingPathComponent("Plan — Marked.pdf")
        _ = try LayeredMarkupExporter().write(source: drawing, pages: [LayeredMarkupExportTests.job()], to: elsewhere)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}
