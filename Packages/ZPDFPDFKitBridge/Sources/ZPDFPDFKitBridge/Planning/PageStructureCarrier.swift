import CoreGraphics
import Foundation
import PDFKit

/// Document structure a page-operation write may or may not carry into its result.
public enum DocumentStructureFeature: String, Sendable, Hashable, Codable, CaseIterable {
    /// `/PageLabels` — the sheet numbers ("A-101").
    case pageLabels
    /// `/Outlines` — bookmarks.
    case outline
    /// `/OCProperties` — the layer definitions. The layered content itself is kept.
    case optionalContent
    /// `/Dests` or the `/Names /Dests` tree — named destinations.
    case namedDestinations
}

/// Carries a source document's structure into the fresh `PDFDocument` a page operation builds.
///
/// Documents bug 5: `applyPageOperations` assembles a new `PDFDocument` from copied
/// pages, and PDFKit gives a new document no page labels, no bookmarks and no layer
/// definitions, while copied GoTo links keep pointing at the *source's* pages. Measured on
/// macOS 26: a PDFKit write drops `/PageLabels` and `/OCProperties` even from a document
/// loaded from a file and merely edited, so there is no PDFKit-only way to keep them.
///
/// What this carries, and how:
/// - **Bookmarks**: rebuilt with PDFKit, each destination re-pointed at the copied page; an
///   entry whose page is not in the result is dropped, a grouping entry is kept while any
///   child survives.
/// - **Internal links**: re-pointed at the copied page; a link whose target page is not in
///   the result is removed rather than left pointing into a document that is not there.
/// - **Page labels**: appended after PDFKit's write as a PDF incremental update to the
///   catalog, one range per page with the page's own label as its prefix, so every page keeps
///   exactly the label it had. Written only when a contributing document declared labels.
///
/// What it cannot carry, and reports as such: layer definitions (`/OCProperties` refers to
/// objects PDFKit renumbers on write) and named destinations.
enum PageStructureCarrier {

    /// A contributing document, pristine, with what the catalog says about it.
    struct Contributor {
        let document: PDFDocument
        let labels: PageLabelTable
        let hasOptionalContent: Bool
        let hasNamedDestinations: Bool
    }

    /// Rebuilds outline and links in `result`, whose page `i` is a copy of
    /// `sources[i]`'s page. Returns the features that could not be carried and the page
    /// labels to append after the write (`nil` when none is needed).
    static func carry(
        into result: PDFDocument,
        sources: [(handle: DocumentHandle, pageIndex: Int)],
        contributors: [DocumentHandle: Contributor],
        primary: DocumentHandle
    ) -> (notCarried: Set<DocumentStructureFeature>, labels: [String]?) {
        // Source page (by document and index) → first result position.
        var position: [PageKey: Int] = [:]
        for (resultIndex, source) in sources.enumerated() {
            let key = PageKey(handle: source.handle, pageIndex: source.pageIndex)
            if position[key] == nil { position[key] = resultIndex }
        }
        // Source `PDFPage` identity → key, for re-pointing destinations.
        var keyOfPage: [ObjectIdentifier: PageKey] = [:]
        for (handle, contributor) in contributors {
            let count = min(contributor.document.pageCount, 100_000)
            for index in 0..<count {
                if let page = contributor.document.page(at: index) {
                    keyOfPage[ObjectIdentifier(page)] = PageKey(handle: handle, pageIndex: index)
                }
            }
        }
        func resultPage(for page: PDFPage?) -> PDFPage? {
            guard let page, let key = keyOfPage[ObjectIdentifier(page)],
                  let index = position[key] else { return nil }
            return result.page(at: index)
        }

        repointLinks(in: result, sources: sources, contributors: contributors, position: position)

        // Outline: the primary's first, then each other contributor's, in the order they
        // first contribute a page.
        var order: [DocumentHandle] = [primary]
        for source in sources where !order.contains(source.handle) { order.append(source.handle) }
        let root = PDFOutline()
        var budget = 20_000
        for handle in order {
            guard let sourceRoot = contributors[handle]?.document.outlineRoot else { continue }
            for index in 0..<sourceRoot.numberOfChildren {
                guard let child = sourceRoot.child(at: index),
                      let rebuilt = rebuild(child, depth: 1, budget: &budget, resultPage: resultPage)
                else { continue }
                root.insertChild(rebuilt, at: root.numberOfChildren)
            }
        }
        if root.numberOfChildren > 0 { result.outlineRoot = root }

        var notCarried: Set<DocumentStructureFeature> = []
        let involved = order.compactMap { contributors[$0] }
        if involved.contains(where: \.hasOptionalContent) { notCarried.insert(.optionalContent) }
        if involved.contains(where: \.hasNamedDestinations) { notCarried.insert(.namedDestinations) }

        var labels: [String]?
        if involved.contains(where: \.labels.isExplicit) {
            labels = sources.map { source in
                contributors[source.handle]?.labels.label(forPageIndex: source.pageIndex)
                    ?? String(source.pageIndex + 1)
            }
        }
        return (notCarried, labels)
    }

    private struct PageKey: Hashable {
        let handle: DocumentHandle
        let pageIndex: Int
    }

    /// Re-points every copied GoTo link. The *source* page's annotations are read, not the
    /// copy's: a copied link's destination resolves lazily against the document it now belongs
    /// to and comes back with no page (measured), while the source's resolves. Copy and source
    /// list their annotations in the same order.
    private static func repointLinks(
        in result: PDFDocument,
        sources: [(handle: DocumentHandle, pageIndex: Int)],
        contributors: [DocumentHandle: Contributor],
        position: [PageKey: Int]
    ) {
        for (resultIndex, source) in sources.enumerated() {
            guard let contributor = contributors[source.handle],
                  let sourcePage = contributor.document.page(at: source.pageIndex),
                  let copiedPage = result.page(at: resultIndex) else { continue }
            let originals = sourcePage.annotations
            let copies = copiedPage.annotations
            guard originals.count == copies.count else { continue }
            for (original, copy) in zip(originals, copies) where original.type == "Link" {
                let destination = original.destination
                    ?? (original.action as? PDFActionGoTo)?.destination
                guard let destination else { continue } // URI, launch, JavaScript: untouched
                let targetIndex = destination.page.map { contributor.document.index(for: $0) }
                if let targetIndex,
                   let resultTarget = position[PageKey(handle: source.handle, pageIndex: targetIndex)],
                   let target = result.page(at: resultTarget) {
                    let moved = PDFDestination(page: target, at: destination.point)
                    moved.zoom = destination.zoom
                    copy.action = PDFActionGoTo(destination: moved)
                } else {
                    // Its sheet was not carried over: a link into nothing is worse than none.
                    copiedPage.removeAnnotation(copy)
                }
            }
        }
    }

    private static func rebuild(
        _ source: PDFOutline,
        depth: Int,
        budget: inout Int,
        resultPage: (PDFPage?) -> PDFPage?
    ) -> PDFOutline? {
        guard depth <= 32, budget > 0 else { return nil }
        budget -= 1
        let node = PDFOutline()
        node.label = source.label
        node.isOpen = source.isOpen
        var keep = false
        let destination = source.destination ?? (source.action as? PDFActionGoTo)?.destination
        if let destination {
            if let target = resultPage(destination.page) {
                node.destination = PDFDestination(page: target, at: destination.point)
                keep = true
            }
        } else if let action = source.action as? PDFActionURL, let url = action.url {
            node.action = PDFActionURL(url: url)
            keep = true
        }
        for index in 0..<source.numberOfChildren {
            guard let child = source.child(at: index),
                  let rebuilt = rebuild(child, depth: depth + 1, budget: &budget, resultPage: resultPage)
            else { continue }
            node.insertChild(rebuilt, at: node.numberOfChildren)
            keep = true
        }
        return keep ? node : nil
    }

    // MARK: - Page labels by incremental update

    /// Appends `/PageLabels` to the catalog of the classic-xref PDF at `url`, one range per
    /// page with `labels[i]` as its prefix. Returns `false`, leaving the file untouched, when
    /// the file is not in the shape PDFKit writes (a classic cross-reference table and a
    /// trailer naming the catalog) — the caller then reports the labels as not carried.
    static func appendPageLabels(_ labels: [String], toFileAt url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard let appended = pageLabelUpdate(labels, appendedTo: data) else { return false }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        return true
    }

    /// The bytes of an incremental update that adds `/PageLabels` to `pdf`'s catalog, or
    /// `nil` when `pdf` is not a classic-xref file this can update safely. Pure, so it is
    /// tested on bytes.
    static func pageLabelUpdate(_ labels: [String], appendedTo pdf: Data) -> Data? {
        // One Character per byte: Latin-1 maps each byte to one scalar, and the only grapheme
        // that would join two of them, CR LF, is split by standing CR in for U+2028 (still a
        // newline to the parser). Offsets into `text` are then byte offsets.
        guard !labels.isEmpty, let latin = String(data: pdf, encoding: .isoLatin1) else { return nil }
        let text = latin.replacingOccurrences(of: "\r", with: "\u{2028}")
        // The last `startxref` names the last cross-reference section.
        guard let startRange = text.range(of: "startxref", options: .backwards) else { return nil }
        let afterStart = text[startRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previousXref = Int(afterStart.prefix { $0.isNumber }),
              previousXref > 0, previousXref < pdf.count else { return nil }
        let xrefIndex = text.index(text.startIndex, offsetBy: previousXref)
        guard text[xrefIndex...].hasPrefix("xref") else { return nil } // an xref stream: refuse
        guard let trailerRange = text.range(of: "trailer", range: xrefIndex..<text.endIndex),
              let trailer = balancedDictionary(in: text, from: trailerRange.upperBound)
        else { return nil }
        guard let root = reference(named: "Root", in: trailer),
              let size = integer(named: "Size", in: trailer) else { return nil }
        // Locate the catalog through the classic table.
        guard let catalogOffset = xrefOffset(of: root.object, in: text, xrefStart: xrefIndex, byteCount: pdf.count),
              catalogOffset < pdf.count else { return nil }
        let catalogStart = text.index(text.startIndex, offsetBy: catalogOffset)
        guard text[catalogStart...].hasPrefix("\(root.object) \(root.generation) obj"),
              let objRange = text.range(of: "obj", range: catalogStart..<text.endIndex),
              let catalog = balancedDictionary(in: text, from: objRange.upperBound),
              catalog.contains("/Catalog"), !catalog.contains("/PageLabels")
        else { return nil }

        let numbers = labels.enumerated().map { "\($0.offset) << /P \(pdfString($0.element)) >>" }
        let entry = "/PageLabels << /Nums [\(numbers.joined(separator: " "))] >>"
        let body = String(catalog.dropLast(2)) + " " + entry + " >>"

        var update = "\n"
        let objectOffset = pdf.count + update.utf8.count
        update += "\(root.object) \(root.generation) obj\n\(body)\nendobj\n"
        let xrefOffsetNew = pdf.count + update.utf8.count
        update += "xref\n\(root.object) 1\n"
        // `%ld`, not `%d`: `%d` reads 32 bits and wrapped an offset past 2 GiB (T-044).
        guard objectOffset <= 9_999_999_999, (0...65_535).contains(root.generation) else { return nil }
        update += String(format: "%010ld %05ld n \n", objectOffset, root.generation)
        var newTrailer = "/Size \(size) /Root \(root.object) \(root.generation) R /Prev \(previousXref)"
        if let info = reference(named: "Info", in: trailer) {
            newTrailer += " /Info \(info.object) \(info.generation) R"
        }
        if let id = arrayText(named: "ID", in: trailer) { newTrailer += " /ID \(id)" }
        update += "trailer\n<< \(newTrailer) >>\nstartxref\n\(xrefOffsetNew)\n%%EOF\n"
        return update.data(using: .isoLatin1)
    }

    /// A PDF text string: literal for printable ASCII (escaped), UTF-16BE hex otherwise.
    static func pdfString(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            var escaped = ""
            for character in value {
                switch character {
                case "\\": escaped += "\\\\"
                case "(": escaped += "\\("
                case ")": escaped += "\\)"
                default: escaped.append(character)
                }
            }
            return "(\(escaped))"
        }
        var hex = "<FEFF"
        for unit in value.utf16 { hex += String(format: "%04X", unit) }
        return hex + ">"
    }

    /// The `<< … >>` starting at the first `<<` at or after `start`, strings and nesting aware.
    private static func balancedDictionary(in text: String, from start: String.Index) -> String? {
        guard let open = text.range(of: "<<", range: start..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        var inString = 0
        var scanned = 0
        while index < text.endIndex, scanned < 1_000_000 {
            scanned += 1
            let character = text[index]
            let next = text.index(after: index)
            if inString > 0 {
                if character == "\\" { index = next < text.endIndex ? text.index(after: next) : next; continue }
                if character == "(" { inString += 1 }
                if character == ")" { inString -= 1 }
                index = next
                continue
            }
            if character == "(" { inString = 1; index = next; continue }
            if character == "<", next < text.endIndex, text[next] == "<" {
                depth += 1; index = text.index(after: next); continue
            }
            if character == ">", next < text.endIndex, text[next] == ">" {
                depth -= 1
                let end = text.index(after: next)
                if depth == 0 { return String(text[open.lowerBound..<end]) }
                index = end
                continue
            }
            index = next
        }
        return nil
    }

    private static func reference(named name: String, in dictionary: String) -> (object: Int, generation: Int)? {
        guard let range = dictionary.range(
            of: "/\(name)\\s+(\\d+)\\s+(\\d+)\\s+R", options: .regularExpression
        ) else { return nil }
        let parts = dictionary[range].split(whereSeparator: \.isWhitespace)
        guard parts.count >= 3, let object = Int(parts[1]), let generation = Int(parts[2]) else { return nil }
        return (object, generation)
    }

    private static func integer(named name: String, in dictionary: String) -> Int? {
        guard let range = dictionary.range(of: "/\(name)\\s+(\\d+)", options: .regularExpression) else { return nil }
        return Int(dictionary[range].split(whereSeparator: \.isWhitespace).last ?? "")
    }

    private static func arrayText(named name: String, in dictionary: String) -> String? {
        guard let range = dictionary.range(of: "/\(name)\\s*\\[[^\\]]*\\]", options: .regularExpression) else {
            return nil
        }
        let text = dictionary[range]
        guard let open = text.firstIndex(of: "[") else { return nil }
        return String(text[open...])
    }

    /// The byte offset of `object` in the classic cross-reference sections starting at
    /// `xrefStart` and following `/Prev` (bounded).
    private static func xrefOffset(
        of object: Int, in text: String, xrefStart: String.Index, byteCount: Int
    ) -> Int? {
        var sectionStart: String.Index? = xrefStart
        var hops = 0
        while let start = sectionStart, hops < 64 {
            hops += 1
            guard text[start...].hasPrefix("xref") else { return nil }
            var lines = text[text.index(start, offsetBy: 4)...].split(
                omittingEmptySubsequences: true, whereSeparator: \.isNewline
            ).makeIterator()
            while let header = lines.next() {
                let fields = header.split(whereSeparator: \.isWhitespace)
                if fields.first == "trailer" { break }
                guard fields.count == 2, let first = Int(fields[0]), let count = Int(fields[1]),
                      count >= 0, count < 10_000_000 else { return nil }
                for number in first..<(first + count) {
                    guard let line = lines.next() else { return nil }
                    if number == object {
                        let entry = line.split(whereSeparator: \.isWhitespace)
                        guard entry.count >= 3, entry[2] == "n", let offset = Int(entry[0]) else { return nil }
                        return offset
                    }
                }
            }
            guard let trailerRange = text.range(of: "trailer", range: start..<text.endIndex),
                  let trailer = balancedDictionary(in: text, from: trailerRange.upperBound),
                  let previous = integer(named: "Prev", in: trailer),
                  previous > 0, previous < byteCount else { return nil }
            sectionStart = text.index(text.startIndex, offsetBy: previous)
        }
        return nil
    }
}
