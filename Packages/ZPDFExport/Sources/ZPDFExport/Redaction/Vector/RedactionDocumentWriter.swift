import Foundation

/// Writes a redacted copy as a **fresh file**: one revision, one cross-reference table, every
/// object renumbered, and only the objects the new catalog reaches (ADR-0033 §5).
///
/// An incremental update would keep the original bytes — the secret included — as an earlier
/// revision any tool can roll back to. So nothing is appended to anything: the writer walks the
/// new object graph from the catalog, copies what it reaches, and leaves everything else behind,
/// old content streams, replaced annotations and unreferenced objects alike.
///
/// On the way it drops, everywhere: XMP metadata, private application data (`/PieceInfo`),
/// thumbnails, additional-actions triggers, associated files (`/AF`) and embedded files (`/EF`,
/// `/RF`, any stream typed `/EmbeddedFile`), PostScript (a form's `/PS` alternate, PostScript
/// XObjects), and every JavaScript, Launch, ImportData, Rendition, SubmitForm and embedded-go-to
/// action. A reference to an object on the removed list is dropped with the key or array slot
/// that held it. (Associated and embedded files used to survive whenever the optional `/Type`
/// was left out: findings 10 and 17.)
struct RedactionDocumentWriter {

    /// Foreign documents (the raster pages of sheets that fell back) are addressed as
    /// `index << 32 | number`; index 0 is the source.
    static func foreignNumber(_ index: Int, _ number: Int) -> Int { index << 32 | number }

    let source: PDFDocumentScan
    var foreign: [PDFDocumentScan] = []
    var pool: RedactionObjectPool
    /// Encoded numbers never written, and every reference to them dropped.
    var removed: Set<Int> = []
    /// Source page object number → the new page's reference.
    var pageMap: [Int: PDFObject] = [:]
    /// Source object number → the synthetic object written in its place wherever it is named: a
    /// form field whose value was cleaned, a font reduced to the glyphs still shown.
    var replacements: [Int: Int] = [:]
    /// Every source object (encoded number) the last `write` copied, for the check that nothing
    /// cut under a box travels in its original form.
    private(set) var writtenSources: Set<Int> = []
    var droppedKeys: Set<String> = ["Metadata", "PieceInfo", "Thumb", "AA", "AF", "EF", "RF", "EmbeddedFiles"]
    static let droppedActions: Set<String> = ["JavaScript", "Launch", "ImportData", "Rendition", "SubmitForm", "GoToE"]

    init(source: PDFDocumentScan, pool: RedactionObjectPool) {
        self.source = source
        self.pool = pool
    }

    private func object(_ encoded: Int) -> (PDFObject, Int)? {
        if encoded >= RedactionObjectPool.syntheticBase {
            return pool.objects[encoded].map { ($0, -1) }
        }
        let index = encoded >> 32, number = encoded & 0xFFFF_FFFF
        if index == 0 { return source.objects[number].map { ($0.object, 0) } }
        guard index - 1 < foreign.count else { return nil }
        return foreign[index - 1].objects[number].map { ($0.object, index) }
    }

    /// Resolves a reference as written in an object from `origin` (−1: synthetic, already encoded).
    func resolve(_ object: PDFObject?, origin: Int = 0) -> PDFObject? {
        guard let object else { return nil }
        guard case let .reference(number, _) = object else { return object }
        let encoded = origin > 0 ? Self.foreignNumber(origin, number) : number
        guard let (found, foundOrigin) = self.object(encoded) else { return nil }
        if case .reference = found { return nil }
        return foundOrigin > 0 ? rebase(found, origin: foundOrigin) : found
    }

    /// A foreign object with its references encoded, so it can sit in a synthetic object.
    func rebase(_ object: PDFObject, origin: Int) -> PDFObject {
        switch object {
        case let .reference(number, generation): .reference(number: Self.foreignNumber(origin, number), generation: generation)
        case let .array(values): .array(values.map { rebase($0, origin: origin) })
        case let .dictionary(entries): .dictionary(entries.mapValues { rebase($0, origin: origin) })
        case let .stream(dictionary, data): .stream(dictionary: dictionary.mapValues { rebase($0, origin: origin) }, data: data)
        default: object
        }
    }

    // MARK: - Writing

    mutating func write(catalog: PDFObject, info: [String: PDFObject]) throws -> Data {
        var numbers: [Int: Int] = [:]
        var queue: [(encoded: Int, origin: Int)] = []
        var bodies: [Int: PDFObject] = [:]
        var nextNumber = 1

        func assign(_ encoded: Int) -> Int {
            if let existing = numbers[encoded] { return existing }
            let number = nextNumber
            nextNumber += 1
            numbers[encoded] = number
            queue.append((encoded, 0))
            return number
        }

        func transform(_ object: PDFObject, origin: Int, depth: Int) -> PDFObject? {
            guard depth < 256 else { return nil }
            switch object {
            case let .reference(number, _):
                var encoded = origin > 0 ? Self.foreignNumber(origin, number) : number
                // A source page, named from the source or from a new object, is the new page.
                if origin <= 0, number < 1 << 32, let page = pageMap[number], case let .reference(pageNumber, _) = page {
                    encoded = pageNumber
                } else if origin <= 0, number < 1 << 32, let replacement = replacements[number] {
                    encoded = replacement
                }
                guard !removed.contains(encoded), self.object(encoded) != nil else { return nil }
                return .reference(number: assign(encoded), generation: 0)
            case let .array(values):
                return .array(values.compactMap { transform($0, origin: origin, depth: depth + 1) })
            case let .dictionary(entries):
                return transformDictionary(entries, origin: origin, depth: depth).map { .dictionary($0) }
            case let .stream(dictionary, data):
                guard let entries = transformDictionary(dictionary, origin: origin, depth: depth) else { return nil }
                return .stream(dictionary: entries, data: data)
            default:
                return object
            }
        }

        func transformDictionary(_ entries: [String: PDFObject], origin: Int, depth: Int) -> [String: PDFObject]? {
            if let action = entries["S"]?.nameValue, Self.droppedActions.contains(action) { return nil }
            if entries["JS"] != nil { return nil }
            if entries["Type"]?.nameValue == "EmbeddedFile" || entries["Subtype"]?.nameValue == "PS" { return nil }
            // A form's PostScript alternate (finding 13) is not drawn by any reader and can hold
            // a copy of the linework.
            let postScriptAlternate = entries["Subtype"]?.nameValue == "Form" || entries["Subtype2"]?.nameValue == "PS"
            var out: [String: PDFObject] = [:]
            for (key, value) in entries where !droppedKeys.contains(key) {
                if postScriptAlternate, key == "PS" || key == "Subtype2" { continue }
                if let transformed = transform(value, origin: origin, depth: depth + 1) { out[key] = transformed }
            }
            return out
        }

        let catalogNumber = nextNumber
        nextNumber += 1
        let infoNumber = nextNumber
        nextNumber += 1
        bodies[catalogNumber] = transform(catalog, origin: -1, depth: 0) ?? .dictionary([:])
        bodies[infoNumber] = .dictionary(info)
        var cursor = 0
        while cursor < queue.count {
            let (encoded, _) = queue[cursor]
            cursor += 1
            guard let number = numbers[encoded], let (found, origin) = object(encoded) else { continue }
            bodies[number] = transform(found, origin: origin, depth: 0) ?? .null
        }

        writtenSources = Set(numbers.keys.filter { $0 < RedactionObjectPool.syntheticBase })
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = Array(repeating: 0, count: nextNumber)
        for number in 1..<nextNumber {
            guard let body = bodies[number] else { continue }
            offsets[number] = out.count
            out.append(contentsOf: Array("\(number) 0 obj\n".utf8))
            out.append(body.serialized)
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(contentsOf: Array("xref\n0 \(nextNumber)\n".utf8))
        out.append(contentsOf: Array("0000000000 65535 f \n".utf8))
        for number in 1..<nextNumber {
            if bodies[number] == nil {
                out.append(contentsOf: Array("0000000000 65535 f \n".utf8))
            } else {
                // From the Int itself: `%010d` wrapped an offset past 2 GiB (T-044).
                guard let entry = PDFFixedWidthField.inUseEntry(offset: offsets[number], generation: 0) else {
                    throw RedactionRefusal.checkFailed("the copy is larger than a cross-reference table can address")
                }
                out.append(contentsOf: Array(entry.utf8))
            }
        }
        let identifier = PDFObject.hexString((0..<16).map { _ in UInt8.random(in: 0...255) })
        let trailer: PDFObject = .dictionary([
            "Size": .integer(nextNumber),
            "Root": .reference(number: catalogNumber, generation: 0),
            "Info": .reference(number: infoNumber, generation: 0),
            "ID": .array([identifier, identifier])
        ])
        out.append(contentsOf: Array("trailer\n".utf8))
        out.append(trailer.serialized)
        out.append(contentsOf: Array("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }
}
