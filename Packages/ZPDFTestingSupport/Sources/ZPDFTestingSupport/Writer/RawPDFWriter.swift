import Foundation

/// The body of one indirect object.
enum PDFObjectBody {
    /// Any PDF object written verbatim: a dictionary, an array, a number, a name.
    case verbatim(String)
    /// A stream. `/Length` is inserted automatically; `dictionaryEntries` supplies the
    /// rest, e.g. `"/Filter /FlateDecode"`.
    case stream(dictionaryEntries: String, data: Data)
}

/// A deliberate defect to introduce while serialising, so that hostile fixtures are
/// real files rather than descriptions of files.
enum PDFCorruption: Equatable {
    case none
    /// Keep the first `keepFraction` of the serialised bytes and drop the rest.
    case truncate(keepFraction: Double)
    /// Write a cross-reference table whose offsets are all wrong by `delta` bytes.
    case shiftCrossReferenceOffsets(delta: Int)
    /// Skip the body of `objectNumber` while still claiming it in the xref table.
    case omitObjectBody(objectNumber: Int)
}

/// A hand-rolled PDF serialiser.
///
/// CoreGraphics' `CGPDFContext` cannot express most of what this corpus needs — page
/// `/Rotate`, exact form-XObject matrices, a cyclic page tree, a broken xref, an
/// object that is declared and then missing — and, just as importantly, it rewrites
/// coordinates at its own precision, which would break the guarantee that the number
/// in the manifest is byte-for-byte the number in the file. So the well-formed and
/// the malformed fixtures alike are written here, and CoreGraphics is used only where
/// it is genuinely the right tool: producing a correctly encrypted document.
struct RawPDFWriter {
    let kind: FixtureKind
    /// Total number of indirect objects, numbered `1 ... objectCount`.
    let objectCount: Int
    /// Object number of the document catalogue.
    let rootObject: Int
    /// Object number of the `/Info` dictionary, when the document has one.
    var infoObject: Int?
    /// A constant `/ID`, so that repeated generation is byte-identical.
    var idHex: String = "5A454E495450444600000000000000FF"
    var corruption: PDFCorruption = .none
    /// Produces object `n`'s body on demand. Returning `nil` writes nothing for that
    /// object while the xref table still claims it. No fixture does this today:
    /// `.missingObject` dangles a reference to an object number beyond `/Size`, and
    /// every object it declares is written.
    let body: (Int) throws -> PDFObjectBody?

    /// Serialises the whole document into memory.
    func data() throws -> Data {
        let sink = PDFDataSink()
        try serialize(into: sink)
        var out = sink.data
        if case let .truncate(fraction) = corruption {
            // `min`/`max` pass NaN straight through, and `Int(NaN)` traps.
            guard !fraction.isNaN else {
                throw FixtureError.generationFailed(kind: kind, reason: "truncation fraction is NaN")
            }
            let clamped = Swift.min(Swift.max(fraction, 0), 1)
            let keep = Int((Double(out.count) * clamped).rounded(.down))
            out = out.prefix(keep)
        }
        return out
    }

    /// Serialises the document straight to `handle`, holding at most one object in
    /// memory at a time. Truncation is not supported on this path; the fixtures that
    /// need it are small and use `data()`.
    func write(to handle: FileHandle, path: String) throws {
        if case .truncate = corruption {
            throw FixtureError.generationFailed(kind: kind, reason: "truncation requires the buffered path")
        }
        let sink = PDFFileSink(handle: handle, path: path)
        try serialize(into: sink)
    }

    // MARK: - Serialisation

    private func serialize(into sink: PDFByteSink) throws {
        guard objectCount >= 1, objectCount <= RawPDFWriter.maximumObjectCount else {
            throw FixtureError.generationFailed(
                kind: kind,
                reason: "object count \(objectCount) outside 1...\(RawPDFWriter.maximumObjectCount)"
            )
        }

        try sink.write("%PDF-1.7\n", kind: kind)
        // The binary comment tells tools the file is not plain text.
        try sink.write(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))

        var offsets = [Int](repeating: 0, count: objectCount + 1)
        var omitted = Set<Int>()
        if case let .omitObjectBody(number) = corruption { omitted.insert(number) }

        for number in 1...objectCount {
            offsets[number] = sink.offset
            if omitted.contains(number) { continue }
            guard let objectBody = try body(number) else { continue }
            try write(object: number, body: objectBody, into: sink)
        }

        let xrefOffset = sink.offset
        try writeCrossReferenceTable(offsets: offsets, into: sink)
        try writeTrailer(startxref: xrefOffset, into: sink)
    }

    private func write(object number: Int, body: PDFObjectBody, into sink: PDFByteSink) throws {
        try sink.write("\(number) 0 obj\n", kind: kind)
        switch body {
        case let .verbatim(text):
            try sink.write(text, kind: kind)
            try sink.write("\n", kind: kind)
        case let .stream(entries, data):
            let trimmed = entries.trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = trimmed.isEmpty ? "" : " \(trimmed)"
            try sink.write("<< /Length \(data.count)\(separator) >>\nstream\n", kind: kind)
            try sink.write(data)
            try sink.write("\nendstream\n", kind: kind)
        }
        try sink.write("endobj\n", kind: kind)
    }

    private func writeCrossReferenceTable(offsets: [Int], into sink: PDFByteSink) throws {
        var delta = 0
        if case let .shiftCrossReferenceOffsets(value) = corruption { delta = value }

        try sink.write("xref\n0 \(objectCount + 1)\n", kind: kind)
        try sink.write("0000000000 65535 f \n", kind: kind)
        for number in 1...objectCount {
            // Every entry is exactly 20 bytes, as the spec requires.
            let field = RawPDFWriter.crossReferenceOffsetField(offsets[number] + delta)
            try sink.write("\(field) 00000 n \n", kind: kind)
        }
    }

    private func writeTrailer(startxref: Int, into sink: PDFByteSink) throws {
        var entries = "/Size \(objectCount + 1) /Root \(rootObject) 0 R"
        if let infoObject { entries += " /Info \(infoObject) 0 R" }
        entries += " /ID [<\(idHex)> <\(idHex)>]"
        try sink.write("trailer\n<< \(entries) >>\nstartxref\n\(startxref)\n%%EOF\n", kind: kind)
    }

    /// The 10-digit offset field of one xref row, clamped to `0 ... 9_999_999_999`.
    ///
    /// `%ld`, not `%d`: Swift passes `Int` as 64 bits, and `%d` reads only the low 32,
    /// so an offset above `Int32.max` would print as an 11-character negative number
    /// and misalign every following 20-byte row.
    static func crossReferenceOffsetField(_ offset: Int) -> String {
        let clamped = Swift.min(Swift.max(0, offset), 9_999_999_999)
        return String(format: "%010ld", clamped)
    }

    /// A generator that asks for more objects than this has a bug; refusing keeps a
    /// runaway loop from writing an unbounded file.
    static let maximumObjectCount = 8_192
}

// MARK: - String escaping

enum PDFSyntax {

    /// Escapes `value` for a PDF literal string `( ... )`.
    ///
    /// Only characters representable in WinAnsi are allowed through; the fixture
    /// strings are deliberately ASCII so that a consumer's text extraction can compare
    /// against the manifest without an encoding round trip in the way.
    static func literalString(_ value: String, kind: FixtureKind) throws -> String {
        var out = "("
        for scalar in value.unicodeScalars {
            guard scalar.value < 128 else {
                throw FixtureError.encodingFailed(
                    kind: kind,
                    reason: "fixture strings must be ASCII, found U+\(String(scalar.value, radix: 16, uppercase: true))"
                )
            }
            switch scalar {
            case "(": out += "\\("
            case ")": out += "\\)"
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + ")"
    }

    /// Renders a PDF name, rejecting anything that would need escaping.
    static func name(_ value: String, kind: FixtureKind) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw FixtureError.encodingFailed(kind: kind, reason: "invalid PDF name \"\(value)\"")
        }
        return "/\(value)"
    }
}
