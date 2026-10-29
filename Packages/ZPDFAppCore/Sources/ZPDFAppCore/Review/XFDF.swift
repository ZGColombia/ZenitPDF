import CryptoKit
import Foundation
import ZPDFContracts
import ZPDFPersistence

/// XFDF (ISO 19444-1) export and import of a review (NL-COLLAB-09): the markups, their notes,
/// replies and review states as a small XML file, without resending the drawing.
///
/// One annotation vocabulary: the reader turns XFDF into the same ``ImportedAnnotation`` values
/// the PDF import reads, and ``AnnotationImportPlanner`` does the rest — so the mapping, the stable
/// identities (a second import adds nothing) and the hostile-input caps are shared.
///
/// The drawing is identified by `<f href>` and by a Zenit extension element carrying the drawing's
/// SHA-256; an XFDF that names another drawing's digest is refused with both names. External
/// entities are never resolved.
public enum XFDF {

    /// The XFDF namespace ISO 19444-1 fixes.
    public static let namespace = "http://ns.adobe.com/xfdf/"
    /// Zenit's extension namespace: a private element and attributes other readers ignore.
    ///
    /// The reader matches the `zenit:` prefix, not this URI, so a file written under an earlier
    /// namespace URI still imports.
    public static let zenitNamespace = "https://zenitgroup.com.co/ns/zenit-review/1"
    public static let fileExtension = "xfdf"
    /// An XFDF is markup text; one larger than this is not a review.
    public static let maximumBytes = 64 << 20

    public enum XFDFError: Error, Equatable, Sendable {
        case unreadable(String)
        case tooLarge
        case otherDrawing(fileDrawing: String)
    }

    // MARK: - Writing

    /// A document for the given markups and threads. `pageIndex` maps a page to its 0-based index.
    public static func document(
        records: [ZPDFContracts.MarkupRecord],
        replies: [ReviewEntryRecord],
        pageIndex: [PageID: Int],
        drawingName: String,
        drawingDigest: String?
    ) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<xfdf xmlns="\#(namespace)" xmlns:zenit="\#(zenitNamespace)" xml:space="preserve">"# + "\n"
        xml += #"  <f href="\#(escape(drawingName))"/>"# + "\n"
        if let drawingDigest {
            xml += #"  <zenit:drawing sha256="\#(escape(drawingDigest))"/>"# + "\n"
        }
        xml += "  <annots>\n"
        let repliesByMarkup = Dictionary(grouping: replies.filter { $0.kind == ReviewEntryRecord.Kind.reply.rawValue && !$0.retracted }, by: \.markupId)
        for record in records {
            guard let page = pageIndex[record.pageID], let element = element(for: record, page: page) else { continue }
            xml += element
            let name = record.id.rawValue.uuidString
            let rect = rectText(bounds(of: record))
            if let state = standardState(record.status) {
                xml += "    <text page=\"\(page)\" rect=\"\(rect)\" name=\"\(name)-review\" inreplyto=\"\(name)\""
                xml += " title=\"\(escape(record.author))\" state=\"\(state)\" statemodel=\"Review\""
                xml += " date=\"\(pdfDate(record.modifiedAt))\" flags=\"hidden,norotate,nozoom\"/>\n"
            }
            for reply in repliesByMarkup[name] ?? [] {
                let created = PersistenceTimestamp.date(from: reply.createdAt) ?? record.modifiedAt
                xml += "    <text page=\"\(page)\" rect=\"\(rect)\" name=\"\(escape(reply.id))\" inreplyto=\"\(name)\" replyType=\"reply\""
                xml += " title=\"\(escape(reply.authorName))\" date=\"\(pdfDate(created))\" creationdate=\"\(pdfDate(created))\" flags=\"hidden,norotate,nozoom\">"
                xml += "<contents>\(escape(reply.body))</contents></text>\n"
            }
        }
        xml += "  </annots>\n</xfdf>\n"
        return Data(xml.utf8)
    }

    static func element(for record: ZPDFContracts.MarkupRecord, page: Int) -> String? {
        guard let geometry = record.geometry else { return nil }
        let points = geometry.points
        let ring = geometry.polygons.first?.outer.points ?? []
        var tag: String
        var extra = ""
        var body = ""
        var contents = record.comment
        switch record.kind {
        case .rectangle:
            tag = "square"
        case .ellipse:
            tag = "circle"
        case .polygon, .cloud, .revisionCloud:
            guard ring.count >= 3 else { return nil }
            tag = "polygon"
            body = "<vertices>\(vertexText(ring))</vertices>"
            if record.kind != .polygon { extra = #" intent="PolygonCloud" style="cloudy" intensity="1""# }
        case .polyline:
            guard points.count >= 2 else { return nil }
            tag = "polyline"
            body = "<vertices>\(vertexText(points))</vertices>"
        case .line, .arrow:
            guard points.count >= 2 else { return nil }
            tag = "line"
            extra = " start=\"\(pointText(points[0]))\" end=\"\(pointText(points[1]))\" head=\"None\" tail=\"\(record.kind == .arrow ? "OpenArrow" : "None")\""
        case .text:
            tag = "freetext"
            contents = MarkupVisibleText.text(of: record)
        case .callout:
            guard points.count >= 3 else { return nil }
            tag = "freetext"
            contents = MarkupVisibleText.text(of: record)
            extra = " intent=\"FreeTextCallout\" callout=\"\(pointText(points[0])),\(pointText(points[1]))\""
        case .note:
            tag = "text"
        case .measurement:
            if !ring.isEmpty, ring.count >= 3 {
                tag = "polygon"
                body = "<vertices>\(vertexText(ring))</vertices>"
                extra = #" intent="PolygonDimension""#
            } else if points.count >= 2 {
                tag = "polyline"
                body = "<vertices>\(vertexText(points))</vertices>"
                extra = #" intent="PolyLineDimension""#
            } else {
                return nil
            }
        default:
            return nil
        }
        let colour = record.style.color
        var line = "    <\(tag) page=\"\(page)\" rect=\"\(rectText(bounds(of: record)))\" name=\"\(record.id.rawValue.uuidString)\""
        line += " title=\"\(escape(record.author))\" subject=\"\(escape(record.subject))\""
        line += " date=\"\(pdfDate(record.modifiedAt))\" creationdate=\"\(pdfDate(record.createdAt))\""
        line += " color=\"\(hex(colour))\" width=\"\(number(record.style.lineWidth))\" opacity=\"\(number(record.style.opacity))\""
        if let fill = record.style.fill { line += " interior-color=\"\(hex(fill))\"" }
        line += " zenit:status=\"\(record.status.rawValue)\"\(extra)>"
        if !contents.isEmpty { line += "<contents>\(escape(contents))</contents>" }
        line += body
        line += "</\(tag)>\n"
        return line
    }

    static func standardState(_ status: ZPDFContracts.MarkupStatus) -> String? {
        switch status {
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .cancelled: return "Cancelled"
        case .completed: return "Completed"
        default: return nil
        }
    }

    static func bounds(of record: ZPDFContracts.MarkupRecord) -> PDFRect {
        guard let geometry = record.geometry else { return PDFRect(x: 0, y: 0, width: 0, height: 0) }
        let all = geometry.points + geometry.polygons.flatMap { $0.outer.points }
        guard let first = all.first else { return PDFRect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in all.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return PDFRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func rectText(_ rect: PDFRect) -> String {
        "\(number(rect.origin.x)),\(number(rect.origin.y)),\(number(rect.origin.x + rect.size.width)),\(number(rect.origin.y + rect.size.height))"
    }

    static func pointText(_ point: PDFPoint) -> String { "\(number(point.x)),\(number(point.y))" }

    static func vertexText(_ points: [PDFPoint]) -> String { points.map(pointText).joined(separator: ";") }

    /// Shortest decimal that reads back to the same double, never scientific.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    static func hex(_ colour: RGBAColor) -> String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + byte(colour.red) + byte(colour.green) + byte(colour.blue)
    }

    /// The calendar a PDF date is read and written in: Gregorian, GMT.
    ///
    /// One shared value, and the fourteen digits handled by hand (V-041). Import and export each
    /// built and configured a `DateFormatter` for every date — two per annotation, two per
    /// reply — and even a shared formatter costs tens of microseconds a parse.
    static let pdfDateCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()

    /// The fields of a PDF date, in the order its fourteen digits spell them.
    static let pdfDateFields: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]

    /// `D:yyyyMMddHHmmssZ` in GMT, exactly as the en_US_POSIX formatter wrote it.
    static func pdfDate(_ date: Date) -> String {
        let parts = pdfDateCalendar.dateComponents(pdfDateFields, from: date)
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
        }
        return "D:" + padded(parts.year, 4) + padded(parts.month, 2) + padded(parts.day, 2)
            + padded(parts.hour, 2) + padded(parts.minute, 2) + padded(parts.second, 2) + "Z"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default:
                // XML 1.0 forbids most control characters; drop them rather than write a file
                // no parser will read.
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Reading

    /// What an XFDF file holds, as import annotations, and the drawing it names.
    public struct Reading: Sendable {
        public var annotations: [ImportedAnnotation]
        public var drawingName: String?
        public var drawingDigest: String?
        /// SHA-256 of the file itself — the key a second import of it is recognised by.
        public var digest: String
        /// Annotations not kept because the file's geometry budget ran out before them (U-032).
        public var annotationsOverBudget = 0
    }

    public static func read(_ data: Data) throws -> Reading {
        guard data.count <= maximumBytes else { throw XFDFError.tooLarge }
        let delegate = XFDFParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw XFDFError.unreadable(delegate.failure ?? parser.parserError?.localizedDescription ?? "")
        }
        // Replies name their parent by `name`; resolve to the parent's position.
        var annotations = delegate.annotations
        let indexByName = Dictionary(annotations.compactMap { annotation in annotation.name.map { ($0, annotation.index) } },
                                     uniquingKeysWith: { first, _ in first })
        for (offset, parent) in delegate.inReplyTo {
            annotations[offset].inReplyToIndex = indexByName[parent] ?? Int.min
        }
        let digest = data.withUnsafeBytes { buffer in
            SHA256Hex.hash(buffer)
        }
        var reading = Reading(annotations: annotations, drawingName: delegate.drawingName, drawingDigest: delegate.drawingDigest, digest: digest)
        reading.annotationsOverBudget = delegate.annotationsOverBudget
        return reading
    }

    /// Refuses an XFDF that names another drawing by digest.
    public static func check(_ reading: Reading, drawingDigest: String?) throws {
        if let named = reading.drawingDigest, let drawingDigest, named.lowercased() != drawingDigest.lowercased() {
            throw XFDFError.otherDrawing(fileDrawing: reading.drawingName ?? named)
        }
    }
}

enum SHA256Hex {
    static func hash(_ buffer: UnsafeRawBufferPointer) -> String {
        SHA256.hash(data: buffer).map { String(format: "%02x", $0) }.joined()
    }
}

/// Collects XFDF annotation elements. Every attribute is read as text and parsed defensively.
///
/// `<vertices>` and `<gesture>` are read as numbers, not as characters (U-034): up to
/// `maximumVertices` points each, a number ending only at a separator or at the element's end,
/// so an `XMLParser` chunk boundary never leaves half a number behind. They used to share the
/// 64 000-character cap of `<contents>`, which cut Zenit's own export of a shape past about
/// 1 700 full-precision vertices and could keep a truncated last number. The whole file shares
/// one geometry budget, and one Ink annotation's gestures `maximumVertices` points (U-032).
final class XFDFParserDelegate: NSObject, XMLParserDelegate {

    var annotations: [ImportedAnnotation] = []
    var inReplyTo: [(Int, String)] = []
    var drawingName: String?
    var drawingDigest: String?
    var failure: String?
    /// Annotations left out because the geometry budget ran out before them (U-032).
    var annotationsOverBudget = 0
    private var budget = AnnotationImportPlanner.maximumTotalPoints
    /// The numbers of the `<vertices>` or `<gesture>` being read, bad ones not-a-number (U-033).
    private var coordinates: [Double] = []
    private var coordinateLimit = 0
    private var token = ""
    private var tokenTooLong = false

    private static let annotationTags: Set<String> = [
        "square", "circle", "polygon", "polyline", "line", "freetext", "text", "ink",
        "highlight", "underline", "strikeout", "stamp", "caret", "squiggly", "fileattachment", "sound"
    ]
    private var current: ImportedAnnotation?
    private var currentReply: String?
    private var textBuffer = ""
    private var inContents = false
    private var inVertices = false
    private var inGesture = false
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        depth += 1
        guard depth < 64 else { failure = "nesting too deep"; parser.abortParsing(); return }
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        switch local {
        case "f":
            drawingName = attributes["href"]
        case "drawing" where elementName.hasPrefix("zenit:"):
            drawingDigest = attributes["sha256"]
        case "contents":
            inContents = true
            textBuffer = ""
        case "vertices":
            inVertices = true
            startCoordinates(limit: AnnotationImportPlanner.maximumVertices * 2)
        case "gesture":
            inGesture = true
            let drawn = current?.inkPaths.reduce(0) { $0 + $1.count } ?? 0
            startCoordinates(limit: max(0, AnnotationImportPlanner.maximumVertices - drawn) * 2)
        default:
            guard Self.annotationTags.contains(local), current == nil else { return }
            guard annotations.count <= AnnotationImportPlanner.maximumAnnotations else { return }
            current = annotation(tag: local, attributes: attributes, index: annotations.count)
            currentReply = attributes["inreplyto"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inVertices || inGesture {
            readCoordinates(string)
            return
        }
        guard inContents else { return }
        guard textBuffer.count < AnnotationImportPlanner.maximumTextLength * 4 else { return }
        textBuffer += string
    }

    private func startCoordinates(limit: Int) {
        coordinates = []
        coordinateLimit = annotationsOverBudget > 0 ? 0 : limit
        token = ""
        tokenTooLong = false
    }

    private func readCoordinates(_ string: String) {
        guard coordinates.count < coordinateLimit else { return }
        for character in string {
            if character == "," || character == ";" || character.isWhitespace {
                endToken()
                if coordinates.count >= coordinateLimit { return }
            } else if token.utf8.count < 64 {
                token.append(character)
            } else {
                tokenTooLong = true
            }
        }
    }

    /// Ends the number being read: kept in place, not-a-number when it is not a finite number.
    private func endToken() {
        guard !token.isEmpty || tokenTooLong else { return }
        if coordinates.count < coordinateLimit {
            let value = tokenTooLong ? nil : Double(token)
            coordinates.append(value.flatMap { $0.isFinite ? $0 : nil } ?? .nan)
        }
        token = ""
        tokenTooLong = false
    }

    private func finishCoordinates() -> [PDFPoint] {
        endToken()
        defer { coordinates = [] }
        return Self.pairs(coordinates)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        switch local {
        case "contents":
            inContents = false
            current?.contents = String(textBuffer.prefix(AnnotationImportPlanner.maximumTextLength))
        case "vertices":
            inVertices = false
            current?.points = finishCoordinates()
        case "gesture":
            inGesture = false
            let stroke = finishCoordinates()
            if !stroke.isEmpty { current?.inkPaths.append(stroke) }
        default:
            guard Self.annotationTags.contains(local), let finished = current else { return }
            // Once the budget is spent every later annotation is counted, not kept (U-032).
            let cost = finished.points.count + finished.quadPoints.count + finished.inkPaths.reduce(0) { $0 + $1.count }
            guard annotationsOverBudget == 0, cost <= budget else {
                annotationsOverBudget += 1
                current = nil
                currentReply = nil
                return
            }
            budget -= cost
            if let parent = currentReply { inReplyTo.append((annotations.count, parent)) }
            var stored = finished
            if currentReply != nil { stored.inReplyToIndex = Int.min } // resolved after parsing
            annotations.append(stored)
            current = nil
            currentReply = nil
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failure = parseError.localizedDescription
    }

    private func annotation(tag: String, attributes: [String: String], index: Int) -> ImportedAnnotation {
        let subtype: String = [
            "square": "Square", "circle": "Circle", "polygon": "Polygon", "polyline": "PolyLine", "line": "Line",
            "freetext": "FreeText", "text": "Text", "ink": "Ink", "highlight": "Highlight", "underline": "Underline",
            "strikeout": "StrikeOut", "stamp": "Stamp"
        ][tag] ?? tag.capitalized
        let rectValues = Self.numbers(attributes["rect"] ?? "")
        let rect = rectValues.count == 4 && rectValues.allSatisfy(\.isFinite)
            ? PDFRect(corner: PDFPoint(x: rectValues[0], y: rectValues[1]), opposite: PDFPoint(x: rectValues[2], y: rectValues[3]))
            : PDFRect(x: 0, y: 0, width: 0, height: 0)
        var points: [PDFPoint] = []
        if tag == "line" {
            points = Self.points(attributes["start"] ?? "") + Self.points(attributes["end"] ?? "")
        } else if tag == "freetext" {
            points = Self.points((attributes["callout"] ?? "").replacingOccurrences(of: ";", with: ","))
        }
        var endings: [String] = []
        if tag == "line" { endings = [attributes["head"] ?? "None", attributes["tail"] ?? "None"] }
        let style = attributes["style"]?.lowercased()
        return ImportedAnnotation(
            index: index,
            pageIndex: Int(attributes["page"] ?? "") ?? -1,
            subtype: subtype,
            name: attributes["name"],
            author: attributes["title"],
            subject: attributes["subject"],
            creationDate: Self.date(attributes["creationdate"]),
            modificationDate: Self.date(attributes["date"]),
            color: Self.colour(attributes["color"]),
            interiorColor: Self.colour(attributes["interior-color"]),
            lineWidth: attributes["width"].flatMap(Double.init),
            rect: rect,
            points: points,
            lineEndings: endings,
            cloudy: style == "cloudy",
            intent: attributes["intent"],
            stateModel: attributes["statemodel"],
            state: attributes["state"],
            zenitOwned: attributes["zenit:status"] != nil,
            zenitStatus: attributes["zenit:status"]
        )
    }

    /// Every number of an attribute, in place: one that does not read as a finite number is kept
    /// as not-a-number, so the numbers after it stay paired as the file wrote them (U-033).
    static func numbers(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .prefix(AnnotationImportPlanner.maximumVertices * 2)
            .map { token in Double(token).flatMap { $0.isFinite ? $0 : nil } ?? .nan }
    }

    static func points(_ text: String) -> [PDFPoint] {
        pairs(numbers(text))
    }

    /// Pairs in place; a pair with a bad number costs that point only.
    static func pairs(_ values: [Double]) -> [PDFPoint] {
        ReviewAnnotationReader.pairs(values)
    }

    static func colour(_ text: String?) -> RGBAColor? {
        guard var hex = text?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return RGBAColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The moment `D:yyyyMMddHHmmss…` names, in GMT, or `nil` when the fourteen characters after
    /// `D:` are not all digits or name no real moment (a 13th month, 30 February, hour 24) — the
    /// strict formatter's answers, without a formatter (V-041).
    static func date(_ text: String?) -> Date? {
        guard let text, text.hasPrefix("D:") else { return nil }
        let digits = Array(text.utf8.dropFirst(2).prefix(14))
        guard digits.count == 14, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        func field(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + Int($1 - 0x30) } }
        let wanted = DateComponents(
            era: 1, year: field(0..<4), month: field(4..<6), day: field(6..<8),
            hour: field(8..<10), minute: field(10..<12), second: field(12..<14)
        )
        // The calendar rolls an impossible field over (30 February becomes 2 March); the text
        // named no such moment, so a date that does not read back field for field is refused.
        guard let date = XFDF.pdfDateCalendar.date(from: wanted) else { return nil }
        let read = XFDF.pdfDateCalendar.dateComponents(XFDF.pdfDateFields, from: date)
        guard read.era == 1, read.year == wanted.year, read.month == wanted.month, read.day == wanted.day,
              read.hour == wanted.hour, read.minute == wanted.minute, read.second == wanted.second
        else { return nil }
        return date
    }
}

extension AppCoreEnvironment {

    /// The document's review as XFDF: every markup XFDF can express, its note, its standard
    /// review state, and its replies (NL-COLLAB-09).
    ///
    /// In draw order (ADR-0036 §2.2): a reader stacks annotations in the order they are written,
    /// so the markup order put a lower layer's markups over an upper layer's in every viewer
    /// that imported the file (K-09). Every markup is written, hidden layers included — a review
    /// item is exchanged whether or not its layer is shown — so this is the draw order, not the
    /// effective (layer-flag-folded) list the paper exports take.
    ///
    /// One drawing's file: an XFDF names one PDF, so only the document's own drawing's sheets are
    /// written. Writing every drawing's markups under their page indices put a second drawing's
    /// page-0 marks on this drawing's page 0 in every reader (S-030).
    public func exportXFDF(drawingName: String, drawingDigest: String?) async -> Data {
        let records = await session.drawOrderedMarkups
        let drawing = DocumentID(snapshot.documentID)
        var pageIndex: [PageID: Int] = [:]
        for page in await session.pageDescriptors where page.documentID == drawing { pageIndex[page.id] = page.index }
        return XFDF.document(
            records: records, replies: review.entries, pageIndex: pageIndex,
            drawingName: drawingName, drawingDigest: drawingDigest
        )
    }

    /// Plans importing an XFDF onto this document, through the same planner as a marked-up PDF.
    public func planXFDFImport(_ reading: XFDF.Reading) async -> AnnotationImportPlan {
        await planReviewImport(ReviewAnnotationReader.Reading(
            annotations: reading.annotations,
            pageCount: await reviewDrawingPageCount(),
            pageSizes: [],
            digest: reading.digest,
            annotationsOverBudget: reading.annotationsOverBudget
        ))
    }
}
