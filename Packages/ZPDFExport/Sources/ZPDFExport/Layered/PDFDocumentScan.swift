import Foundation

/// Everything the layered exporter needs to know about a PDF it is going to append to: which
/// object is the catalog, which objects are the pages, and what each of those objects currently
/// says.
///
/// # Why the objects are found by scanning rather than through the cross-reference table
///
/// The cross-reference table is the part of a PDF that damage reaches first — every repair tool
/// in existence has a "reconstruct the xref" path because plotters, mail gateways and revision
/// control routinely break it. This scan reads the object bodies directly, in file order, and
/// lets a later definition of an object number win, which is exactly what an incremental update
/// means. It therefore reads a file whose table is wrong, and it reads the *current* version of
/// every object in a file that has been updated ten times.
///
/// By default, `startxref` lets the incremental update chain its `/Prev` to the prior section.
/// With `honoringFreeEntries`, cross-reference tables and streams also keep freed objects deleted.
///
/// # What it refuses
///
/// Encryption. An incremental update must encrypt its own strings and streams with the
/// document's key, and this package holds no crypto. Refused with a sentence naming why, per
/// ADR-0013 §2 — never a silent fall back to a flattened file.
struct PDFDocumentScan {

    /// One object as the file currently defines it.
    struct Entry {
        let object: PDFObject
        /// Where the `n g obj` header started. Later wins.
        let offset: Int
        /// The `g` of `n g obj`. Zero for an object inside an object stream, which is the only
        /// generation such an object can have (ISO 32000-1 §7.5.7). An update that supersedes
        /// the object must write it under this generation, or the `n g R` pointing at it no
        /// longer resolves to the new definition.
        var generation: Int = 0
    }

    let bytes: [UInt8]
    private(set) var objects: [Int: Entry] = [:]
    private(set) var trailer: [String: PDFObject] = [:]
    /// The offset the file's last `startxref` names, and whether the section there is a table.
    private(set) var previousStartXref: Int?
    private(set) var previousSectionIsTable = false

    // MARK: - Reading

    /// - Parameter honoringFreeEntries: drop every object a later cross-reference section frees.
    ///   The layered export keeps its historical reading (a later definition wins, free entries
    ///   are not consulted); redaction asks for this, so a deleted object stays deleted.
    init(data: Data, honoringFreeEntries: Bool = false) throws {
        self.bytes = [UInt8](data)
        guard bytes.count >= 8,
              PDFObjectParser(bytes: bytes, index: 0).matches("%PDF-1", at: 0)
                  || PDFObjectParser(bytes: bytes, index: 0).matches("%PDF-2", at: 0)
                  || PDFObjectParser.find(Array("%PDF-".utf8), in: bytes, from: 0) != nil
        else {
            throw ExportError.layeredSourceUnreadable(
                "the drawing does not begin with a PDF header, so there is no object layer to "
                    + "add a layer to."
            )
        }
        scanObjects()
        expandObjectStreams()
        readTrailer()
        readStartXref()
        if honoringFreeEntries { removeFreedObjects() }

        if trailer["Encrypt"] != nil || objects.values.contains(where: {
            $0.object.dictionaryValue?["Type"]?.nameValue == "XRef"
                && $0.object.dictionaryValue?["Encrypt"] != nil
        }) {
            throw ExportError.layeredSourceUnreadable(
                "the drawing is encrypted, and a layer added to it would have to be encrypted "
                    + "with the same key; Zenit PDF has no writer for encrypted documents, so the "
                    + "layered export cannot be produced from this file."
            )
        }
    }

    /// One linear pass: every `n g obj` header, its body, and a jump past whatever it contained.
    ///
    /// Jumping past a parsed object is what keeps a binary stream from being mistaken for
    /// syntax — the three bytes `obj` do occur inside compressed image data, and a scanner that
    /// restarted after every candidate would find them.
    private mutating func scanObjects() {
        var index = 0
        let limit = bytes.count
        var indirectLengthStreams: [Header] = []
        while index < limit {
            guard let headerStart = Self.nextObjectHeader(in: bytes, from: index) else { break }
            var parser = PDFObjectParser(bytes: bytes, index: headerStart.bodyStart)
            guard let object = parser.parseObject() else {
                index = headerStart.bodyStart
                continue
            }
            // Later definitions supersede earlier ones. That is the incremental-update rule and
            // it is also the right answer for a file whose objects were appended by a repair.
            objects[headerStart.number] = Entry(
                object: object,
                offset: headerStart.start,
                generation: headerStart.generation
            )
            if case let .stream(dictionary, _) = object, dictionary["Length"]?.referenceValue != nil {
                indirectLengthStreams.append(headerStart)
            }
            index = max(parser.index, headerStart.bodyStart)
        }
        resolveIndirectLengths(indirectLengthStreams)
    }

    /// Re-reads every stream whose `/Length` is an indirect reference, now that the object it
    /// names has been scanned (Quartz, among others, writes the length object *after* the
    /// stream). Without this the payload comes from the `endstream` search, which loses a final
    /// CR byte of binary data to the end-of-line trim.
    private mutating func resolveIndirectLengths(_ headers: [Header]) {
        guard !headers.isEmpty else { return }
        let lengths: [Int: Int] = objects.compactMapValues { entry in
            if case let .integer(value) = entry.object { return value }
            return nil
        }
        for header in headers {
            guard let current = objects[header.number], current.offset == header.start else {
                continue
            }
            var parser = PDFObjectParser(
                bytes: bytes,
                index: header.bodyStart,
                lengthResolver: { lengths[$0] }
            )
            guard let object = parser.parseObject(), case .stream = object else { continue }
            objects[header.number] = Entry(
                object: object,
                offset: header.start,
                generation: header.generation
            )
        }
    }

    private struct Header {
        let number: Int
        let generation: Int
        let start: Int
        let bodyStart: Int
    }

    private static func nextObjectHeader(in bytes: [UInt8], from start: Int) -> Header? {
        var position = start
        while let found = PDFObjectParser.find(Array("obj".utf8), in: bytes, from: position) {
            position = found + 3
            // `endobj` also ends in `obj`; the byte before must not be a regular character that
            // belongs to a longer keyword.
            guard found + 3 >= bytes.count || !PDFByte.isRegular(bytes[found + 3]) else { continue }
            var cursor = found - 1
            func skipBack() {
                while cursor >= 0, PDFByte.isWhitespace(bytes[cursor]) { cursor -= 1 }
            }
            skipBack()
            let generationEnd = cursor
            while cursor >= 0, PDFByte.isDigit(bytes[cursor]) { cursor -= 1 }
            guard cursor < generationEnd else { continue }
            let generationStart = cursor + 1
            skipBack()
            let numberEnd = cursor
            while cursor >= 0, PDFByte.isDigit(bytes[cursor]) { cursor -= 1 }
            guard cursor < numberEnd else { continue }
            let numberStart = cursor + 1
            guard cursor < 0 || PDFByte.isWhitespace(bytes[cursor]) || PDFByte.isDelimiter(bytes[cursor])
            else { continue }
            // Bounded like a cross-reference start: every writer allocates new objects from
            // `nextObjectNumber` upwards, so a header at `Int.max` trapped the `+ 1` there
            // (it1r R-108). A number past the bound is not a header this scan can use.
            guard let number = Int(String(decoding: bytes[numberStart...numberEnd], as: UTF8.self)),
                  number > 0, number <= Self.maximumObjectNumber
            else { continue }
            // A generation is at most five digits (ISO 32000-1 §7.3.10); a longer run is not a
            // header this scan can trust, but it is also not worth refusing the object over.
            let generation = Int(
                String(decoding: bytes[generationStart...generationEnd], as: UTF8.self)
            ).flatMap { (0...65_535).contains($0) ? $0 : nil } ?? 0
            return Header(
                number: number,
                generation: generation,
                start: numberStart,
                bodyStart: found + 3
            )
        }
        return nil
    }

    /// Objects hidden inside `/ObjStm` compressed object streams — where every PDF written since
    /// about 2005 puts its catalog and its page dictionaries.
    private mutating func expandObjectStreams() {
        let streams = objects
            .filter { $0.value.object.dictionaryValue?["Type"]?.nameValue == "ObjStm" }
            .sorted { $0.value.offset < $1.value.offset }
        for (_, entry) in streams {
            guard case let .stream(dictionary, raw) = entry.object,
                  let count = dictionary["N"]?.integerValue,
                  let first = dictionary["First"]?.integerValue,
                  count > 0, count < 100_000, first >= 0,
                  let decoded = PDFStreamCodec.decode(dictionary: dictionary, data: raw)
            else { continue }
            let contents = [UInt8](decoded)
            guard first <= contents.count else { continue }

            var header = PDFObjectParser(bytes: contents, index: 0)
            var pairs: [(number: Int, offset: Int)] = []
            for _ in 0..<count {
                guard let number = header.parseObject()?.integerValue,
                      let offset = header.parseObject()?.integerValue
                else { break }
                pairs.append((number, offset))
            }
            for pair in pairs where pair.number > 0 && pair.number <= Self.maximumObjectNumber {
                // `first` is bounded above, `pair.offset` is whatever the header says: compare
                // against the room that is left rather than adding, so an offset near `Int.max`
                // is skipped instead of overflowing.
                guard pair.offset >= 0, pair.offset < contents.count - first else { continue }
                let start = first + pair.offset
                var parser = PDFObjectParser(bytes: contents, index: start)
                guard let object = parser.parseObject() else { continue }
                // An object stream's members are as current as the stream that carries them; a
                // top-level definition later in the file still wins.
                if let existing = objects[pair.number], existing.offset > entry.offset { continue }
                objects[pair.number] = Entry(object: object, offset: entry.offset)
            }
        }
    }

    /// The trailer as the latest revision has it: every trailer dictionary — a classic
    /// `trailer`, or a cross-reference stream's own dictionary — in file order, each later one
    /// superseding the keys it defines, as each incremental update's trailer does. (A
    /// cross-reference stream's `/Root` used to win wherever it stood, so a classic update
    /// after it was ignored and an earlier revision's page tree came back: finding 12.)
    private mutating func readTrailer() {
        var sections: [(offset: Int, entries: [String: PDFObject])] = []
        var position = 0
        let needle = Array("trailer".utf8)
        while let found = PDFObjectParser.find(needle, in: bytes, from: position) {
            position = found + needle.count
            var parser = PDFObjectParser(bytes: bytes, index: position)
            guard let dictionary = parser.parseObject()?.dictionaryValue else { continue }
            sections.append((found, dictionary))
        }
        // A cross-reference *stream* carries the trailer keys in its own dictionary; a file
        // written since PDF 1.5 usually has no `trailer` keyword at all.
        for (_, entry) in objects where entry.object.dictionaryValue?["Type"]?.nameValue == "XRef" {
            guard let dictionary = entry.object.dictionaryValue else { continue }
            let trailerKeys = dictionary.filter { ["Root", "Info", "ID", "Encrypt", "Size", "Prev"].contains($0.key) }
            sections.append((entry.offset, trailerKeys))
        }
        var merged: [String: PDFObject] = [:]
        for section in sections.sorted(by: { $0.offset < $1.offset }) {
            for (key, value) in section.entries { merged[key] = value }
        }
        trailer = merged
    }

    /// Removes every object whose latest cross-reference entry is a free entry with no
    /// definition of the object after it (ISO 32000-1 §7.5.4, §7.5.8).
    ///
    /// Sections are ordered by where they stand in the file; the cross-reference stream a hybrid
    /// file's trailer names with `/XRefStm` belongs to that trailer's section and is read right
    /// after its table, whose free entries for compressed objects it overrides (§7.5.8.4).
    private mutating func removeFreedObjects() {
        var entries: [(order: Int, number: Int, free: Bool)] = []
        var hybridStreams: Set<Int> = []
        var position = 0
        let needle = Array("xref".utf8)
        while let found = PDFObjectParser.find(needle, in: bytes, from: position) {
            position = found + needle.count
            // `startxref` also ends in `xref`; a table's keyword stands alone.
            guard found == 0 || PDFByte.isWhitespace(bytes[found - 1]),
                  found + 4 < bytes.count, PDFByte.isWhitespace(bytes[found + 4]) else { continue }
            var parser = PDFObjectParser(bytes: bytes, index: found + 4)
            var subsections = 0
            table: while subsections < 100_000 {
                parser.skipWhitespaceAndComments()
                guard parser.index < bytes.count else { break }
                if parser.matches("trailer", at: parser.index) {
                    var trailerParser = PDFObjectParser(bytes: bytes, index: parser.index + 7)
                    if let stm = trailerParser.parseObject()?.dictionaryValue?["XRefStm"]?.integerValue,
                       let stream = objects.values.first(where: { $0.offset == stm }) {
                        hybridStreams.insert(stm)
                        Self.crossReferenceStreamEntries(stream.object, order: found * 2 + 1, into: &entries)
                    }
                    break
                }
                // `start` bounded too: `start + index` below overflowed and trapped for a hostile
                // `xref 9223372036854775806 3` when redaction read the file (R-108).
                guard let start = parser.parseObject()?.integerValue, let count = parser.parseObject()?.integerValue,
                      start >= 0, start <= Self.maximumObjectNumber, count >= 0, count < 10_000_000 else { break }
                subsections += 1
                for index in 0..<count {
                    guard parser.parseObject()?.integerValue != nil, parser.parseObject()?.integerValue != nil else { break table }
                    parser.skipWhitespaceAndComments()
                    guard let keyword = parser.readKeyword(), keyword == "f" || keyword == "n" else { break table }
                    entries.append((found * 2, start + index, keyword == "f"))
                }
            }
        }
        for entry in objects.values where entry.object.dictionaryValue?["Type"]?.nameValue == "XRef" && !hybridStreams.contains(entry.offset) {
            Self.crossReferenceStreamEntries(entry.object, order: entry.offset * 2, into: &entries)
        }
        var latest: [Int: (order: Int, free: Bool)] = [:]
        for (_, entry) in entries.enumerated().sorted(by: { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }) {
            latest[entry.number] = (entry.order, entry.free)
        }
        for (number, state) in latest where state.free && number > 0 {
            // A definition after the section that freed the number is a later revision reusing it.
            guard let current = objects[number], current.offset * 2 < state.order else { continue }
            objects.removeValue(forKey: number)
        }
    }

    /// The largest object number a cross-reference section, an object header or an object
    /// stream is read for — far beyond any real file (the format's own implementation limit is
    /// 8,388,607), and far enough from `Int.max` that adding a subsection's count to it, or the
    /// objects a writer appends, cannot overflow.
    static let maximumObjectNumber = 1 << 40

    private static func crossReferenceStreamEntries(_ object: PDFObject, order: Int, into entries: inout [(order: Int, number: Int, free: Bool)]) {
        guard case let .stream(dictionary, raw) = object, let decoded = PDFStreamCodec.decode(dictionary: dictionary, data: raw) else { return }
        let widths = dictionary["W"]?.arrayValue?.compactMap(\.integerValue) ?? []
        guard widths.count == 3, widths.allSatisfy({ (0...8).contains($0) }) else { return }
        let rowLength = widths.reduce(0, +)
        guard rowLength > 0 else { return }
        let size = dictionary["Size"]?.integerValue ?? 0
        let index = dictionary["Index"]?.arrayValue?.compactMap(\.integerValue) ?? [0, size]
        let data = [UInt8](decoded)
        var row = 0
        for pair in stride(from: 0, to: index.count - 1, by: 2) {
            let first = index[pair], count = index[pair + 1]
            guard first >= 0, first <= maximumObjectNumber, count >= 0, count < 10_000_000 else { return }
            for offset in 0..<count {
                let base = row * rowLength
                guard base + rowLength <= data.count else { return }
                var type = 1
                if widths[0] > 0 {
                    type = 0
                    for byte in data[base..<(base + widths[0])] { type = type << 8 | Int(byte) }
                }
                entries.append((order, first + offset, type == 0))
                row += 1
            }
        }
    }

    private mutating func readStartXref() {
        guard let found = PDFObjectParser.findLast(Array("startxref".utf8), in: bytes) else {
            return
        }
        var parser = PDFObjectParser(bytes: bytes, index: found + 9)
        guard let offset = parser.parseObject()?.integerValue, offset >= 0, offset < bytes.count
        else { return }
        previousStartXref = offset
        var probe = PDFObjectParser(bytes: bytes, index: offset)
        probe.skipWhitespaceAndComments()
        previousSectionIsTable = probe.matches("xref", at: probe.index)
    }

    // MARK: - Resolution

    func object(_ value: PDFObject?) -> PDFObject? {
        guard let value else { return nil }
        var current = value
        var hops = 0
        while case let .reference(number, _) = current {
            guard hops < 32, let entry = objects[number] else { return nil }
            current = entry.object
            hops += 1
        }
        return current
    }

    /// The generation the file currently defines object `number` under, zero when unknown.
    func generation(of number: Int) -> Int {
        objects[number]?.generation ?? 0
    }

    func dictionary(_ value: PDFObject?) -> [String: PDFObject]? {
        object(value)?.dictionaryValue
    }

    /// One past the highest object number in use; at most `maximumObjectNumber + 1`, since no
    /// object past the bound is ever read, so the writers' `allocator += 1` cannot overflow.
    var nextObjectNumber: Int {
        let highest = min(objects.keys.max() ?? 0, Self.maximumObjectNumber)
        // Clamped before subtracting: `/Size -9223372036854775808` must not underflow.
        let declared = min(max(trailer["Size"]?.integerValue ?? 0, 0), Self.maximumObjectNumber) - 1
        return max(highest, declared, 0) + 1
    }

    var rootReference: PDFObject? {
        if let root = trailer["Root"], root.referenceValue != nil { return root }
        // No usable trailer: fall back to the last object that calls itself a catalog.
        let catalogs = objects
            .filter { $0.value.object.dictionaryValue?["Type"]?.nameValue == "Catalog" }
            .sorted { $0.value.offset < $1.value.offset }
        guard let last = catalogs.last else { return nil }
        return .reference(number: last.key, generation: last.value.generation)
    }

    // MARK: - The page tree

    /// The page objects in document order, with the attributes a page inherits from its
    /// ancestors already resolved (`/Resources`, `/MediaBox`, `/CropBox`, `/Rotate`).
    struct PageEntry {
        let number: Int
        let dictionary: [String: PDFObject]
        /// `/Resources` as written on the page, or inherited, or `nil` when neither exists.
        let inheritedResources: PDFObject?
        /// `/CropBox`, or `/MediaBox`, page-first then inherited. The four numbers, unresolved.
        let inheritedVisibleBox: PDFObject?
        /// `/Rotate`, page-first then inherited.
        let inheritedRotation: PDFObject?
        /// `/MediaBox` alone, page-first then inherited.
        var inheritedMediaBox: PDFObject?
        /// `/CropBox` alone, page-first then inherited. A reader intersects it with the media
        /// box (ISO 32000-1 §14.11.2), so the visible sheet is the intersection of the two.
        var inheritedCropBox: PDFObject?
    }

    func pages() throws -> [PageEntry] {
        guard let root = rootReference, let catalog = dictionary(root) else {
            throw ExportError.layeredCatalogUnreachable(
                "the drawing has no readable document catalog, so there is nowhere to record the "
                    + "optional-content group that makes the markups a layer."
            )
        }
        guard let pagesReference = catalog["Pages"], dictionary(pagesReference) != nil else {
            throw ExportError.layeredCatalogUnreachable(
                "the drawing's catalog has no readable page tree, so the markup layer cannot be "
                    + "attached to a page."
            )
        }
        var collected: [PageEntry] = []
        var visited: Set<Int> = []
        collect(
            node: pagesReference,
            inherited: Inherited(),
            depth: 0,
            visited: &visited,
            into: &collected
        )
        guard !collected.isEmpty else {
            throw ExportError.layeredCatalogUnreachable(
                "the drawing's page tree lists no pages that can be read, so there is no page to "
                    + "add the markup layer to."
            )
        }
        return collected
    }

    /// The four attributes ISO 32000-1 §7.7.3.4 lets a page inherit from a `/Pages` node.
    private struct Inherited {
        var resources: PDFObject?
        var mediaBox: PDFObject?
        var cropBox: PDFObject?
        var rotation: PDFObject?
    }

    private func collect(
        node: PDFObject,
        inherited: Inherited,
        depth: Int,
        visited: inout Set<Int>,
        into collected: inout [PageEntry]
    ) {
        guard depth <= PDFObjectParser.maximumDepth else { return }
        if let number = node.referenceValue?.number {
            guard !visited.contains(number) else { return }
            visited.insert(number)
        }
        guard let entries = dictionary(node) else { return }
        var carried = inherited
        carried.resources = entries["Resources"] ?? carried.resources
        carried.mediaBox = entries["MediaBox"] ?? carried.mediaBox
        carried.cropBox = entries["CropBox"] ?? carried.cropBox
        carried.rotation = entries["Rotate"] ?? carried.rotation
        let type = entries["Type"]?.nameValue

        if type == "Page" || (type == nil && entries["Kids"] == nil && entries["Contents"] != nil) {
            guard let number = node.referenceValue?.number else { return }
            collected.append(
                PageEntry(
                    number: number,
                    dictionary: entries,
                    inheritedResources: carried.resources,
                    inheritedVisibleBox: carried.cropBox ?? carried.mediaBox,
                    inheritedRotation: carried.rotation,
                    inheritedMediaBox: carried.mediaBox,
                    inheritedCropBox: carried.cropBox
                )
            )
            return
        }
        guard let kids = object(entries["Kids"])?.arrayValue else { return }
        for kid in kids {
            collect(
                node: kid,
                inherited: carried,
                depth: depth + 1,
                visited: &visited,
                into: &collected
            )
        }
    }
}
