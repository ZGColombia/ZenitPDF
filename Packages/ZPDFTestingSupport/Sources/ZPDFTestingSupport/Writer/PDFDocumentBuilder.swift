import Foundation

/// Assembles a conventional catalogue / page-tree / page document on top of
/// `PDFObjectTable`, so each fixture only has to describe its own content.
final class PDFDocumentBuilder {
    let kind: FixtureKind
    private let table = PDFObjectTable()
    private let catalogNumber: Int
    private let pagesNumber: Int
    private var pageNumbers: [Int] = []
    /// The `/Info` object, added by the first `writer()` call and reused by later ones,
    /// so that serialising the same builder twice yields the same bytes.
    private var infoNumber: Int?

    /// Extra entries spliced into the `/Catalog` dictionary, e.g. `/Names` or
    /// `/OpenAction`.
    var catalogExtraEntries: String = ""

    init(kind: FixtureKind) {
        self.kind = kind
        catalogNumber = table.reserve()
        pagesNumber = table.reserve()
    }

    // MARK: Objects

    @discardableResult
    func addObject(_ text: String) -> Int {
        table.add(text)
    }

    @discardableResult
    func addStream(entries: String = "", data: Data) -> Int {
        table.add(.stream(dictionaryEntries: entries, data: data))
    }

    /// Adds a content stream, compressing it with `/FlateDecode` when asked.
    @discardableResult
    func addContentStream(_ stream: PDFContentStream, compressed: Bool = false) throws -> Int {
        let raw = try stream.data(kind: kind)
        if compressed {
            let deflated = try PDFFlate.zlibStream(raw, kind: kind)
            return addStream(entries: "/Filter /FlateDecode", data: deflated)
        }
        return addStream(data: raw)
    }

    /// Adds one of the base-14 fonts, which need no embedded font programme.
    @discardableResult
    func addBase14Font(baseFont: String) throws -> Int {
        let name = try PDFSyntax.name(baseFont, kind: kind)
        return addObject("<< /Type /Font /Subtype /Type1 /BaseFont \(name) /Encoding /WinAnsiEncoding >>")
    }

    /// Adds a form XObject.
    @discardableResult
    func addFormXObject(
        bbox: FixtureRect,
        matrix: FixtureMatrix,
        resources: String,
        content: PDFContentStream
    ) throws -> Int {
        let data = try content.data(kind: kind)
        let entries = "/Type /XObject /Subtype /Form /FormType 1 "
            + "/BBox \(PDFNumber.array(bbox)) /Matrix [\(PDFNumber.string(matrix))] "
            + "/Resources \(resources)"
        return addStream(entries: entries, data: data)
    }

    /// Claims an object number whose body is set later with ``setObject(_:_:)`` — for page
    /// objects that links and bookmarks must point at before the page is added, and for the
    /// sibling-linked outline items.
    func reserveObject() -> Int { table.reserve() }

    /// Fills an object claimed with ``reserveObject()``.
    func setObject(_ number: Int, _ text: String) { table.set(number, text) }

    // MARK: Pages

    /// Appends a page to the tree and returns its object number.
    ///
    /// `rotation` is written as `/Rotate` whenever it is given, including an explicit
    /// `/Rotate 0`; `nil` leaves the key out so the inherited default applies.
    @discardableResult
    func addPage(
        mediaBox: FixtureRect,
        cropBox: FixtureRect? = nil,
        rotation: Int? = nil,
        resources: String = "<< >>",
        contentObject: Int,
        extraEntries: String = "",
        reservedNumber: Int? = nil
    ) -> Int {
        addPage(
            mediaBox: mediaBox, cropBox: cropBox, rotation: rotation, resources: resources,
            contentObjects: [contentObject], extraEntries: extraEntries, reservedNumber: reservedNumber
        )
    }

    /// Appends a page whose `/Contents` is the given streams, concatenated in order — written
    /// as a single reference when there is one, and as an array otherwise.
    @discardableResult
    func addPage(
        mediaBox: FixtureRect,
        cropBox: FixtureRect? = nil,
        rotation: Int? = nil,
        resources: String = "<< >>",
        contentObjects: [Int],
        extraEntries: String = "",
        reservedNumber: Int? = nil
    ) -> Int {
        let number = reservedNumber ?? table.reserve()
        var entries = "/Type /Page /Parent \(pagesNumber) 0 R "
            + "/MediaBox \(PDFNumber.array(mediaBox))"
        if let cropBox { entries += " /CropBox \(PDFNumber.array(cropBox))" }
        if let rotation { entries += " /Rotate \(rotation)" }
        let contents = contentObjects.count == 1
            ? "\(contentObjects[0]) 0 R"
            : "[" + contentObjects.map { "\($0) 0 R" }.joined(separator: " ") + "]"
        entries += " /Resources \(resources) /Contents \(contents)"
        if !extraEntries.isEmpty { entries += " \(extraEntries)" }
        table.set(number, "<< \(entries) >>")
        pageNumbers.append(number)
        return number
    }

    // MARK: Finishing

    /// Closes the catalogue and page tree and returns a writer ready to serialise.
    ///
    /// Idempotent: a second call rewrites the same catalogue and page tree and reuses
    /// the `/Info` object rather than appending another one.
    func writer(corruption: PDFCorruption = .none) throws -> RawPDFWriter {
        guard !pageNumbers.isEmpty else {
            throw FixtureError.generationFailed(kind: kind, reason: "document has no pages")
        }
        let kids = "[" + pageNumbers.map { "\($0) 0 R" }.joined(separator: " ") + "]"
        table.set(pagesNumber, "<< /Type /Pages /Kids \(kids) /Count \(pageNumbers.count) >>")

        var catalogEntries = "/Type /Catalog /Pages \(pagesNumber) 0 R"
        if !catalogExtraEntries.isEmpty { catalogEntries += " \(catalogExtraEntries)" }
        table.set(catalogNumber, "<< \(catalogEntries) >>")

        let info: Int
        if let infoNumber {
            info = infoNumber
        } else {
            info = table.add(
                "<< /Producer (ZPDFTestingSupport) /Title (\(kind.rawValue)) "
                    + "/CreationDate (D:20260101000000Z) /ModDate (D:20260101000000Z) >>"
            )
            infoNumber = info
        }

        var writer = RawPDFWriter(
            kind: kind,
            objectCount: table.count,
            rootObject: catalogNumber,
            body: table.provider(kind: kind)
        )
        writer.infoObject = info
        writer.corruption = corruption
        return writer
    }

    /// Serialises the document in memory.
    func data(corruption: PDFCorruption = .none) throws -> Data {
        try writer(corruption: corruption).data()
    }
}
