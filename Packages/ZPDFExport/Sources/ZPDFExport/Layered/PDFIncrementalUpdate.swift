import CryptoKit
import Foundation

/// Appends objects to a PDF **without rewriting a byte of it**.
///
/// An incremental update is the original file, then the objects that supersede some of its
/// objects, then a cross-reference section that chains back to the old one with `/Prev`. Readers
/// resolve an object number to whichever definition the newest section names, so the pages and
/// the catalog can be changed while the bytes that describe the drawing stay exactly where they
/// were. That is what ADR-0013 promises and it is the only PDF operation that can keep the
/// promise: every "write a copy" path — Core Graphics', qpdf's, PDFKit's — re-encodes the whole
/// document.
///
/// The artefact therefore begins with the source file, byte for byte, and
/// ``LayeredExportOutcome/preservedSourceBytes`` is that length. A test hashes the prefix.
struct PDFIncrementalUpdate {

    /// Object number to its new definition. Numbers that already exist supersede; numbers past
    /// the source's `/Size` are new.
    var objects: [Int: PDFObject] = [:]

    func appended(to source: Data, scan: PDFDocumentScan) throws -> Data {
        guard !objects.isEmpty else { return source }
        guard let root = scan.rootReference else {
            throw ExportError.layeredCatalogUnreachable(
                "the drawing names no document catalog in its trailer, so an update to it has "
                    + "nothing to point at and the markup layer cannot be recorded."
            )
        }
        guard let previous = scan.previousStartXref else {
            throw ExportError.layeredSourceUnreadable(
                "the drawing has no usable startxref, so there is no cross-reference section for "
                    + "an update to chain to; the file would have to be rebuilt, which this "
                    + "export does not do."
            )
        }

        var out = source
        // A source that ends mid-token would otherwise run into the first appended object.
        if let last = out.last, last != 0x0A, last != 0x0D {
            out.append(0x0A)
        }

        let numbers = objects.keys.sorted()
        // Past every number the source uses as well as every number this update writes (X-026):
        // an update that only supersedes — a page whose viewports alone changed — has no new
        // object, and one past the highest superseded number names an object the source already
        // has, which a cross-reference stream numbered that way would replace.
        let xrefNumber = max((numbers.last ?? 0) + 1, scan.nextObjectNumber)
        var offsets: [Int: Int] = [:]
        // A superseding definition keeps the generation the source gave the object: the page
        // tree still says `12 1 R`, and `12 0 obj` would be a different object to a strict
        // reader. New objects are past the source's numbers and get generation 0.
        var generations: [Int: Int] = [:]
        for number in numbers {
            guard let object = objects[number] else { continue }
            let generation = scan.generation(of: number)
            offsets[number] = out.count
            generations[number] = generation
            out.append(contentsOf: Array("\(number) \(generation) obj\n".utf8))
            out.append(object.serialized)
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        // `dropFirst`, not `suffix(from: source.count)`: a count is not an index when the caller
        // hands in a slice whose `startIndex` is not zero.
        let identifier = Self.identifier(of: scan, appending: Data(out.dropFirst(source.count)))
        let xrefOffset = out.count

        if scan.previousSectionIsTable {
            guard let table = Self.table(offsets: offsets, generations: generations) else {
                throw ExportError.layeredSourceUnreadable(
                    "the drawing is larger than a classic cross-reference table can address "
                        + "(9 999 999 999 bytes), or names an object generation past 65535, so an "
                        + "update to it cannot be written."
                )
            }
            out.append(table)
            var trailer: [String: PDFObject] = [
                "Size": .integer(max(xrefNumber, scan.nextObjectNumber)),
                "Root": root,
                "Prev": .integer(previous)
            ]
            if let info = scan.trailer["Info"] { trailer["Info"] = info }
            trailer["ID"] = identifier
            out.append(contentsOf: Array("trailer\n".utf8))
            out.append(PDFObject.dictionary(trailer).serialized)
            out.append(0x0A)
        } else {
            var entries = offsets
            entries[xrefNumber] = xrefOffset
            let offsetWidth = Self.offsetFieldWidth(for: entries)
            var dictionary: [String: PDFObject] = [
                "Type": .name("XRef"),
                "Size": .integer(max(xrefNumber + 1, scan.nextObjectNumber)),
                "Root": root,
                "Prev": .integer(previous),
                "W": .array([.integer(1), .integer(offsetWidth), .integer(2)]),
                "Index": .array(Self.index(of: entries).flatMap {
                    [PDFObject.integer($0.start), PDFObject.integer($0.count)]
                })
            ]
            if let info = scan.trailer["Info"] { dictionary["Info"] = info }
            dictionary["ID"] = identifier
            let stream = PDFObject.stream(
                dictionary: dictionary,
                data: Self.crossReferenceStream(
                    entries: entries,
                    generations: generations,
                    offsetWidth: offsetWidth
                )
            )
            out.append(contentsOf: Array("\(xrefNumber) 0 obj\n".utf8))
            out.append(stream.serialized)
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        out.append(contentsOf: Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    // MARK: - Copying another document's objects in

    /// `value`, read out of `scan` — another document, the markup painter's scratch PDF — with
    /// every object it references copied into this update under a number from `allocate`.
    ///
    /// `memo` maps a scratch object number to its copy. Pass one memo for everything copied out
    /// of one scratch document, so an object the painter shares across its pages (its ICC
    /// colour space, its ExtGState) is copied once, not once per markup (U-051). The annotated
    /// export and the layered export both copy through here; `tooDeep` is the refusal each
    /// words its own way for a resource nested past ``PDFObjectParser/maximumDepth``.
    mutating func copy(
        _ value: PDFObject,
        from scan: PDFDocumentScan,
        memo: inout [Int: Int],
        allocate: () -> Int,
        tooDeep: () -> ExportError,
        depth: Int = 0
    ) throws -> PDFObject {
        guard depth <= PDFObjectParser.maximumDepth else { throw tooDeep() }
        func inner(_ child: PDFObject) throws -> PDFObject {
            try copy(child, from: scan, memo: &memo, allocate: allocate, tooDeep: tooDeep, depth: depth + 1)
        }
        switch value {
        case let .reference(number, _):
            if let existing = memo[number] { return .reference(number: existing, generation: 0) }
            guard let entry = scan.objects[number] else { return .null }
            let assigned = allocate()
            memo[number] = assigned
            objects[assigned] = try inner(entry.object)
            return .reference(number: assigned, generation: 0)
        case let .array(values):
            return .array(try values.map(inner))
        case let .dictionary(entries):
            return .dictionary(try entries.mapValues(inner))
        case let .stream(dictionary, data):
            return .stream(dictionary: try dictionary.mapValues(inner), data: data)
        default:
            return value
        }
    }

    // MARK: - Cross-reference shapes

    private struct Run {
        let start: Int
        let count: Int
    }

    /// Contiguous runs of object numbers, which is what an xref subsection is.
    private static func index(of offsets: [Int: Int]) -> [Run] {
        var runs: [Run] = [Run(start: 0, count: 1)]
        var start: Int?
        var previous: Int?
        for number in offsets.keys.sorted() {
            if let last = previous, number == last + 1 {
                previous = number
                continue
            }
            if let begin = start, let last = previous {
                runs.append(Run(start: begin, count: last - begin + 1))
            }
            start = number
            previous = number
        }
        if let begin = start, let last = previous {
            runs.append(Run(start: begin, count: last - begin + 1))
        }
        return runs
    }

    /// The classic cross-reference section for `offsets`, or `nil` when an offset or generation
    /// does not fit its fixed-width field (T-044: `%010d` wrapped an offset past 2 GiB).
    static func table(offsets: [Int: Int], generations: [Int: Int] = [:]) -> Data? {
        var text = "xref\n"
        for run in index(of: offsets) {
            text += "\(run.start) \(run.count)\n"
            for number in run.start..<(run.start + run.count) {
                if let offset = offsets[number] {
                    guard let entry = PDFFixedWidthField.inUseEntry(offset: offset, generation: generations[number] ?? 0) else { return nil }
                    text += entry
                } else {
                    // Only object 0, the head of the free list.
                    text += "0000000000 65535 f \n"
                }
            }
        }
        return Data(text.utf8)
    }

    /// Bytes per offset in a cross-reference stream row: four, the width every file under 4 GiB
    /// needs, widened for a larger one rather than truncating the high bits away.
    static func offsetFieldWidth(for entries: [Int: Int]) -> Int {
        let largest = UInt64(max(entries.values.max() ?? 0, 0))
        var width = 4
        while width < 8, largest >> UInt64(width * 8) != 0 { width += 1 }
        return width
    }

    static func crossReferenceStream(
        entries: [Int: Int],
        generations: [Int: Int] = [:],
        offsetWidth: Int = 4
    ) -> Data {
        var out = Data()
        for run in index(of: entries) {
            for number in run.start..<(run.start + run.count) {
                guard let offset = entries[number] else {
                    out.append(0)
                    out.append(contentsOf: [UInt8](repeating: 0, count: offsetWidth))
                    out.append(contentsOf: [0xFF, 0xFF])
                    continue
                }
                out.append(1)
                let value = UInt64(max(offset, 0))
                for shift in stride(from: (offsetWidth - 1) * 8, through: 0, by: -8) {
                    out.append(UInt8((value >> UInt64(shift)) & 0xFF))
                }
                let generation = UInt16(clamping: generations[number] ?? 0)
                out.append(UInt8(generation >> 8))
                out.append(UInt8(generation & 0xFF))
            }
        }
        return out
    }

    /// `/ID`: the source's first element kept, the second replaced by a digest of what was
    /// appended. The pair means "same document lineage, different revision", which is exactly
    /// what an added layer is.
    private static func identifier(of scan: PDFDocumentScan, appending added: Data) -> PDFObject {
        let digest = Array(SHA256.hash(data: added).prefix(16))
        let second = PDFObject.hexString(digest)
        guard let existing = scan.trailer["ID"]?.arrayValue, let first = existing.first else {
            return .array([second, second])
        }
        return .array([first, second])
    }
}
