import Foundation
import ZPDFUIPresentation

/// Reads a sheet's number and title off its title block (NL-AUTO-04).
///
/// Most construction sets carry no `/PageLabels`, so the Navigator says "Page 17", set diff
/// matches sheets by position, and nobody can go to "A-104". Naming the sheets is a day-one task
/// on every new set. This reader is the recognition half; the sheet-name data model, its
/// persistence and the Navigator display belong to the document set.
///
/// Two modes, one output:
///
/// - **Template.** The person boxes the sheet number, and optionally the title, on any page.
///   Each box is stored relative to the **nearest corner** of that page's box, because a title
///   block sits in the same corner whatever the sheet size, and is applied to every page of the
///   same paper size. The text inside each box is the reading.
/// - **Automatic.** Near each corner of the sheet (the bottom-right first, where title blocks
///   usually sit), the reader looks for a label it knows in English or Swedish — "Drawing No.",
///   "Sheet", "Ritningsnummer", "Ritn.nr", "Blad", "Title", "Benämning" — and takes the value
///   written after it on the same line, or in the line just below it.
///
/// It reads what is printed and never invents a name: a region with no text is a proposal with
/// no number, and every proposal says where it came from and how sure the reading is. An
/// accepted proposal is the person's decision, not the reader's.
public struct TitleBlockReader: Sendable {

    public init() {}

    // MARK: - Template mode

    /// Reads one page through a template. `nil` when the template does not apply to this page's
    /// paper size — the caller shows the page as "not read", never a name from another layout.
    public func read(
        template: TitleBlockTemplate,
        pageIndex: Int,
        pageBox: PDFRectValue,
        lines: [RecognisedTextLine]
    ) -> SheetNameProposal? {
        guard template.applies(to: pageBox) else { return nil }
        // The box usually holds the cell's own printed label too ("DOKUMENTNUMMER" above
        // "A-00-0-001"), and a generous box reaches the next cell's label ("RITNINGSKATEGORI"
        // under the title). Both are labels, not the name (L-54).
        let number = Self.fieldText(
            in: template.numberRegion.resolved(on: pageBox), lines: lines,
            ownLabels: Self.numberAnchors, otherLabels: Self.titleAnchors + Self.otherFieldLabels
        )
        let title = template.titleRegion.map {
            Self.fieldText(
                in: $0.resolved(on: pageBox), lines: lines,
                ownLabels: Self.titleAnchors, otherLabels: Self.numberAnchors + Self.otherFieldLabels
            )
        }
        let confidence = number.text == nil ? 0 : Swift.min(number.coverage, title?.coverage ?? 1)
        return SheetNameProposal(
            pageIndex: pageIndex,
            number: number.text.map(Self.normaliseNumber),
            title: title?.text,
            source: .template,
            confidence: confidence
        )
    }

    // MARK: - Automatic mode

    /// Labels that introduce a sheet number, lower-cased, without punctuation.
    public static let numberAnchors: [String] = [
        "drawing no", "drawing number", "dwg no", "dwg", "sheet no", "sheet number", "sheet",
        "ritningsnummer", "ritningsnr", "ritn nr", "ritnnr", "ritn", "blad", "bladnummer",
        // L-54: the document-number cell of Swedish and English title blocks.
        "dokumentnummer", "dokumentnr", "dokument nr", "document no", "document number", "doc no"
    ]
    /// Labels that introduce a sheet title.
    public static let titleAnchors: [String] = [
        "drawing title", "sheet title", "title", "benämning", "innehåll", "titel", "ritningstitel",
        // L-54: the title cell of the Swedish standard title block prints "SPECIFIKATION"
        // above the drawing's title ("Takplan Demo").
        "specifikation"
    ]
    /// Labels of the title block's other cells. A cell that starts with one is that field's
    /// label ("SCALE 1:50" under "TITLE"), never the value of a number or a title.
    public static let otherFieldLabels: [String] = [
        "scale", "date", "drawn", "drawn by", "checked", "checked by", "approved", "revision", "rev",
        "project", "client", "job no", "skala", "datum", "ritad av", "granskad", "godkänd", "projekt", "beställare",
        // L-54: further cells a generous box reaches — the drawing category, paper format,
        // status and the commission's own number, in Swedish and English.
        "ritningskategori", "kategori", "drawing category", "category", "format", "paper size", "status",
        "skede", "uppdragsnummer", "uppdragsnr", "uppdrag nr", "projektnummer", "projektnr", "project no",
        "project number", "handläggare", "ansvarig", "konstruktör", "arkitekt", "ändring", "ändr",
        "architect", "engineer", "contractor", "stage",
        // L-54: the remaining cells of the Swedish standard title block (every label printed in
        // the standard block), and their English counterparts that are not
        // also common title words — "floor", "level" and "area" begin real titles.
        "system", "byggnadsverk", "våningsplan", "våningsdel", "delområde", "område", "disciplin",
        "fastighet", "diarienummer", "diarienr", "projektnamn", "adress", "företag", "skapad",
        "telefon", "kontaktperson", "plushöjd", "ändrings",
        "discipline", "address", "company", "created by", "contact", "phone"
    ]
    /// The share of each page dimension, measured from a corner, the automatic mode searches.
    public static let cornerZoneShare = 0.25

    /// Reads one page by looking for known labels near its corners.
    public func readAutomatically(
        pageIndex: Int,
        pageBox: PDFRectValue,
        lines: [RecognisedTextLine]
    ) -> SheetNameProposal {
        let lines = BaselineLineMerger.merge(lines)
        for corner in [TitleBlockCorner.bottomRight, .bottomLeft, .topRight, .topLeft] {
            let zone = Self.cornerZone(corner, of: pageBox)
            let local = lines.filter { line in
                guard let bounds = line.boundsInPageSpace else { return false }
                return zone.holds(x: bounds.centreX, y: bounds.centreY)
            }
            guard !local.isEmpty else { continue }
            let number = Self.value(after: Self.numberAnchors, excluding: Self.titleAnchors, in: local)
            guard let number else { continue }
            let title = Self.value(after: Self.titleAnchors, excluding: Self.numberAnchors, in: local)
            return SheetNameProposal(
                pageIndex: pageIndex,
                number: Self.normaliseNumber(number),
                title: title,
                source: .keywordAnchor,
                confidence: Self.anchorConfidence
            )
        }
        return SheetNameProposal(pageIndex: pageIndex, number: nil, title: nil, source: .keywordAnchor, confidence: 0)
    }

    /// A keyword reading is a good guess, not a boxed reading: it is shown for review as such.
    public static let anchorConfidence = 0.6
    /// A classified reading — no label found, the text judged by shape or by the on-device
    /// model — is the weakest kind, and is shown as such.
    public static let classifiedConfidence = 0.4

    /// Reads by keyword first; when no label is found near a corner, labels the text in the
    /// bottom-right corner zone with `classifier` (NL-AUTO-22: the on-device model on macOS 26
    /// when it is available, the rules everywhere else) and takes the first sheet-number-shaped
    /// and title-shaped texts. The classifier only ever names a field; the text is the drawing's.
    public func readAutomatically(
        pageIndex: Int,
        pageBox: PDFRectValue,
        lines: [RecognisedTextLine],
        classifier: any TitleBlockFieldClassifying
    ) async -> SheetNameProposal {
        let anchored = readAutomatically(pageIndex: pageIndex, pageBox: pageBox, lines: lines)
        guard anchored.number == nil else { return anchored }
        let zone = Self.cornerZone(.bottomRight, of: pageBox)
        let local = BaselineLineMerger.merge(lines).filter { line in
            guard let bounds = line.boundsInPageSpace else { return false }
            return zone.holds(x: bounds.centreX, y: bounds.centreY)
        }
        guard !local.isEmpty else { return anchored }
        let texts = local.map { Self.collapseWhitespace($0.text) }
        let labels = await classifier.classify(texts)
        let number = zip(texts, labels).first { $0.1 == .sheetNumber }?.0
        let title = zip(texts, labels).first { $0.1 == .sheetTitle }?.0
        guard let number else { return anchored }
        return SheetNameProposal(
            pageIndex: pageIndex,
            number: Self.normaliseNumber(number),
            title: title,
            source: classifier.isModelBacked ? .onDeviceModel : .classified,
            confidence: Self.classifiedConfidence
        )
    }

    // MARK: - Across the set

    /// Flags every proposal whose number another page also claims. Duplicates are flagged,
    /// never suffixed: which page is really A-104 is the person's call.
    public static func flaggingDuplicates(_ proposals: [SheetNameProposal]) -> [SheetNameProposal] {
        var counts: [String: Int] = [:]
        for proposal in proposals {
            if let number = proposal.number?.lowercased() { counts[number, default: 0] += 1 }
        }
        return proposals.map { proposal in
            var copy = proposal
            copy.isDuplicateNumber = proposal.number.map { (counts[$0.lowercased()] ?? 0) > 1 } ?? false
            return copy
        }
    }

    // MARK: - Reading text in a region

    /// The text of the lines inside `region`, top to bottom then left to right, and how much of
    /// that text lay inside (the smallest share of any contributing line's area).
    static func text(in region: PDFRectValue, lines: [RecognisedTextLine]) -> (text: String?, coverage: Double) {
        let picked = pickedLines(in: region, lines: lines)
        guard !picked.isEmpty else { return (nil, 0) }
        let joined = picked.map(\.text).joined(separator: " ")
        return (collapseWhitespace(joined), picked.map(\.share).min() ?? 0)
    }

    /// One field's reading from its box, with the title block's printed labels left out (L-54).
    ///
    /// A title block is a grid of cells, each with its label printed small at the top and its
    /// value under it ("DOKUMENTNUMMER" above "A-00-0-001"). A box drawn around one field
    /// usually holds that cell's label and often reaches into the cells above and below it.
    /// Read top to bottom:
    ///
    /// - A line that starts with one of the field's **own** labels opens the field's cell.
    ///   Whatever was read before it belonged to the cell above ("RITNINGSKATEGORI" / "Planer"
    ///   over "DOKUMENTNUMMER") and is dropped; only what follows the label on its line is kept.
    /// - The line straight under a bare own label is the value, even when it happens to begin
    ///   with another cell's label word ("SPECIFIKATION" / "System Schematic").
    /// - A line that starts with **another** field's label is that cell's label. Beside a line
    ///   already read (the same row) it is the neighbouring cell's, and is passed over. Above
    ///   anything read it is the cell above's, and is passed over. Below what was read, or below
    ///   the field's own label, the box has reached the cell under the field: the reading ends.
    /// - When the field's own cell holds nothing but its label, the reading is empty — a
    ///   printed label is never the name. The one exception is a layout that prints the label
    ///   under the value: text read before the own label that did not follow another cell's
    ///   label is the value.
    /// - With no own label in the box, and only other labels, a line that carries text after
    ///   its label word is kept whole: a title that happens to begin with a label word
    ///   ("PROJECT OVERVIEW") is still the drawing's text. Bare labels alone read as nothing.
    static func fieldText(
        in region: PDFRectValue,
        lines: [RecognisedTextLine],
        ownLabels: [String],
        otherLabels: [String]
    ) -> (text: String?, coverage: Double) {
        let picked = pickedLines(in: region, lines: lines)
        guard !picked.isEmpty else { return (nil, 0) }
        // Own and other labels in one list, longest first: "sheet no" is not "sheet" followed
        // by "no", and "SHEET TITLE" is the title's label, not the number's "sheet".
        let labels = (ownLabels.map { (label: $0, isOwn: true) } + otherLabels.map { (label: $0, isOwn: false) })
            .sorted { $0.label.count > $1.label.count }
        func classify(_ text: String) -> (isOwn: Bool, rest: String)? {
            for entry in labels {
                if let rest = remainder(of: text, after: entry.label) { return (entry.isOwn, rest) }
            }
            return nil
        }
        func sameRow(_ a: PDFRectValue, _ b: PDFRectValue) -> Bool {
            Swift.abs(a.centreY - b.centreY) <= Swift.min(a.size.height, b.size.height) / 2
        }

        typealias Read = (text: String, share: Double)
        var kept: [Read] = []
        var keptFollowsOtherLabel = false
        var beforeOwnLabel: [Read] = []
        var beforeOwnLabelFollowsOtherLabel = false
        var sawOtherLabel = false
        var sawOwnLabel = false
        var expectingValue = false
        var labelledLines: [Read] = []
        // The bounds of the last line the field took in — its own label or a kept line.
        var lastTaken: PDFRectValue?

        reading: for line in picked {
            guard let label = classify(line.text) else {
                if kept.isEmpty { keptFollowsOtherLabel = sawOtherLabel }
                kept.append((line.text, line.share))
                expectingValue = false
                lastTaken = line.bounds
                continue
            }
            if label.isOwn {
                if !kept.isEmpty {
                    beforeOwnLabel = kept
                    beforeOwnLabelFollowsOtherLabel = keptFollowsOtherLabel
                }
                kept = []
                sawOwnLabel = true
                expectingValue = label.rest.isEmpty
                if !label.rest.isEmpty { kept.append((label.rest, line.share)) }
                lastTaken = line.bounds
                continue
            }
            if expectingValue, !label.rest.isEmpty, let own = lastTaken, !sameRow(own, line.bounds) {
                kept.append((line.text, line.share))
                expectingValue = false
                lastTaken = line.bounds
                continue
            }
            if let last = lastTaken, sameRow(last, line.bounds) { continue }
            if sawOwnLabel || !kept.isEmpty { break reading }
            sawOtherLabel = true
            if !label.rest.isEmpty { labelledLines.append((line.text, line.share)) }
        }

        let reading: [Read]
        if !kept.isEmpty {
            reading = kept
        } else if sawOwnLabel {
            reading = beforeOwnLabelFollowsOtherLabel ? [] : beforeOwnLabel
        } else {
            reading = labelledLines
        }
        guard !reading.isEmpty else { return (nil, 0) }
        return (collapseWhitespace(reading.map(\.text).joined(separator: " ")), reading.map(\.share).min() ?? 0)
    }

    /// The lines more than half inside `region`, in reading order, with the share of each
    /// that lay inside.
    static func pickedLines(in region: PDFRectValue, lines: [RecognisedTextLine]) -> [(bounds: PDFRectValue, text: String, share: Double)] {
        var picked: [(bounds: PDFRectValue, text: String, share: Double)] = []
        for line in lines {
            guard let bounds = line.boundsInPageSpace else { continue }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let share = overlapShare(of: bounds, in: region)
            // More than half the line inside the box: the person meant it.
            guard share > 0.5 else { continue }
            picked.append((bounds, text, share))
        }
        picked.sort {
            // PDF space: larger y is higher on the sheet.
            if Swift.abs($0.bounds.centreY - $1.bounds.centreY) > Swift.min($0.bounds.size.height, $1.bounds.size.height) / 2 {
                return $0.bounds.centreY > $1.bounds.centreY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        return picked
    }

    static func overlapShare(of bounds: PDFRectValue, in region: PDFRectValue) -> Double {
        let area = bounds.size.width * bounds.size.height
        guard area > 0 else { return region.holds(x: bounds.centreX, y: bounds.centreY) ? 1 : 0 }
        let width = Swift.max(0, Swift.min(bounds.maxX, region.maxX) - Swift.max(bounds.minX, region.minX))
        let height = Swift.max(0, Swift.min(bounds.maxY, region.maxY) - Swift.max(bounds.minY, region.minY))
        return (width * height) / area
    }

    /// The value written after one of `anchors`: on the same line after the label ("Ritn.nr:
    /// A-101"), else the nearest line below the label that overlaps it horizontally, else the
    /// nearest line to its right on the same baseline.
    static func value(after anchors: [String], excluding others: [String] = [], in lines: [RecognisedTextLine]) -> String? {
        let keyed = lines.compactMap { line -> (line: RecognisedTextLine, bounds: PDFRectValue)? in
            guard let bounds = line.boundsInPageSpace else { return nil }
            // "Sheet title: Floor Plan" starts with "sheet" but is the other field's label.
            // A line that matches one of this field's own labels stays, however it starts.
            guard remainder(of: line.text, afterAny: anchors) != nil
                || remainder(of: line.text, afterAny: others) == nil else { return nil }
            return (line, bounds)
        }
        // Longest anchors first, so "drawing title" is not read as "title" and "sheet no" not as "sheet".
        for anchor in anchors.sorted(by: { $0.count > $1.count }) {
            for (line, bounds) in keyed {
                guard let sameLine = remainder(of: line.text, after: anchor) else { continue }
                if !sameLine.isEmpty { return sameLine }
                let below = keyed
                    .filter { $0.bounds.maxY <= bounds.minY + 0.5 && bounds.minY - $0.bounds.maxY <= bounds.size.height * 3 }
                    .filter { $0.bounds.maxX >= bounds.minX && $0.bounds.minX <= bounds.maxX + bounds.size.width }
                    .filter { remainder(of: $0.line.text, afterAny: anchors + others + otherFieldLabels) == nil }
                    .min { (bounds.minY - $0.bounds.maxY) < (bounds.minY - $1.bounds.maxY) }
                if let below {
                    let text = collapseWhitespace(below.line.text)
                    if !text.isEmpty { return text }
                }
                let right = keyed
                    .filter { $0.bounds.minX >= bounds.maxX - 0.5 && Swift.abs($0.bounds.centreY - bounds.centreY) <= bounds.size.height / 2 }
                    .filter { remainder(of: $0.line.text, afterAny: otherFieldLabels) == nil }
                    .min { $0.bounds.minX < $1.bounds.minX }
                if let right {
                    let text = collapseWhitespace(right.line.text)
                    if !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    /// When `text` starts with `anchor` (compared lower-cased, blind to `.` and `:`), the rest of
    /// the line after the label and its separator; `nil` when it does not start with the label.
    /// "Ritn.nr: A-101", "RITN NR A-101" and "Ritn.nr:A-101" all give "A-101"; "Sheets 4" does
    /// not match "sheet".
    static func remainder(of text: String, after anchor: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let wanted = anchor.split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return nil }
        var wordIndex = 0
        var matched = 0
        var leftover: String?
        while matched < wanted.count, wordIndex < words.count {
            // One written word may hold several label words: "Ritn.nr:" is "ritn", "nr".
            var pieces = words[wordIndex].lowercased()
                .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "." || $0 == ":" })
                .map(String.init)
            let original = words[wordIndex]
            wordIndex += 1
            var consumedPieces = 0
            while !pieces.isEmpty, matched < wanted.count {
                let piece = pieces.removeFirst()
                guard piece == wanted[matched] else { return nil }
                matched += 1
                consumedPieces += 1
            }
            if matched == wanted.count, !pieces.isEmpty {
                // The value follows inside the same written word, after a separator.
                guard let cut = original.lastIndex(where: { $0 == ":" || $0 == "." }) else { return nil }
                leftover = String(original[original.index(after: cut)...])
            }
            _ = consumedPieces
        }
        guard matched == wanted.count else { return nil }
        var rest = words[wordIndex...].joined(separator: " ")
        if let leftover { rest = leftover + (rest.isEmpty ? "" : " " + rest) }
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".:#-\u{2013}\u{2014} \t"))
        return collapseWhitespace(trimmed)
    }

    static func remainder(of text: String, afterAny anchors: [String]) -> String? {
        for anchor in anchors {
            if let rest = remainder(of: text, after: anchor) { return rest }
        }
        return nil
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A sheet number as it should be shown: trimmed, inner whitespace collapsed, and a space
    /// either side of a hyphen removed ("A - 101" is "A-101").
    static func normaliseNumber(_ text: String) -> String {
        collapseWhitespace(text).replacingOccurrences(of: " - ", with: "-")
    }

    static func cornerZone(_ corner: TitleBlockCorner, of box: PDFRectValue) -> PDFRectValue {
        let width = box.size.width * cornerZoneShare
        let height = box.size.height * cornerZoneShare
        switch corner {
        case .bottomLeft: return PDFRectValue(x: box.minX, y: box.minY, width: width, height: height)
        case .bottomRight: return PDFRectValue(x: box.maxX - width, y: box.minY, width: width, height: height)
        case .topLeft: return PDFRectValue(x: box.minX, y: box.maxY - height, width: width, height: height)
        case .topRight: return PDFRectValue(x: box.maxX - width, y: box.maxY - height, width: width, height: height)
        }
    }
}

/// A corner of the page box.
public enum TitleBlockCorner: String, Sendable, Hashable, Codable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight
}

/// A rectangle stored relative to one corner of the page box, so it lands on the same place of
/// the title block on every sheet of that size.
public struct TitleBlockAnchoredRegion: Sendable, Hashable, Codable {
    public let corner: TitleBlockCorner
    /// Distance from the corner to the nearest rectangle edge, inward, in page points.
    public let insetX: Double
    public let insetY: Double
    public let width: Double
    public let height: Double

    /// Anchors `rect` to the corner of `pageBox` it lies nearest.
    public init(rect: PDFRectValue, on pageBox: PDFRectValue) {
        let nearRight = rect.centreX > pageBox.centreX
        let nearTop = rect.centreY > pageBox.centreY
        corner = nearTop ? (nearRight ? .topRight : .topLeft) : (nearRight ? .bottomRight : .bottomLeft)
        insetX = nearRight ? pageBox.maxX - rect.maxX : rect.minX - pageBox.minX
        insetY = nearTop ? pageBox.maxY - rect.maxY : rect.minY - pageBox.minY
        width = rect.size.width
        height = rect.size.height
    }

    /// The rectangle on another page box.
    public func resolved(on pageBox: PDFRectValue) -> PDFRectValue {
        let x: Double
        let y: Double
        switch corner {
        case .bottomLeft, .topLeft: x = pageBox.minX + insetX
        case .bottomRight, .topRight: x = pageBox.maxX - insetX - width
        }
        switch corner {
        case .bottomLeft, .bottomRight: y = pageBox.minY + insetY
        case .topLeft, .topRight: y = pageBox.maxY - insetY - height
        }
        return PDFRectValue(x: x, y: y, width: width, height: height)
    }
}

/// Where the number and title sit on one layout of title block, and which paper it belongs to.
public struct TitleBlockTemplate: Sendable, Hashable, Codable {
    public let numberRegion: TitleBlockAnchoredRegion
    public let titleRegion: TitleBlockAnchoredRegion?
    /// The page box size the template was drawn on.
    public let paperWidth: Double
    public let paperHeight: Double
    /// How far another page's box may differ and still be "the same paper", per edge.
    public static let paperTolerance = 6.0

    public init(numberRect: PDFRectValue, titleRect: PDFRectValue?, pageBox: PDFRectValue) {
        numberRegion = TitleBlockAnchoredRegion(rect: numberRect, on: pageBox)
        titleRegion = titleRect.map { TitleBlockAnchoredRegion(rect: $0, on: pageBox) }
        paperWidth = pageBox.size.width
        paperHeight = pageBox.size.height
    }

    /// Whether this template belongs on a page of `pageBox`'s size.
    public func applies(to pageBox: PDFRectValue) -> Bool {
        Swift.abs(pageBox.size.width - paperWidth) <= Self.paperTolerance
            && Swift.abs(pageBox.size.height - paperHeight) <= Self.paperTolerance
    }
}

/// One page's proposed name. A proposal until a person accepts it.
public struct SheetNameProposal: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// Read inside the boxes the person drew.
        case template
        /// Read after a known label near a corner.
        case keywordAnchor
        /// No label found; the text judged a sheet number by its shape.
        case classified
        /// No label found; the text labelled by the on-device language model (NL-AUTO-22).
        case onDeviceModel
        /// Read inside the person's box by on-device text recognition — the sheet has no text
        /// layer there (NL-AUTO-03).
        case templateOCR
    }

    public var id: Int { pageIndex }
    public let pageIndex: Int
    public var number: String?
    public var title: String?
    public let source: Source
    /// `0…1`: for a template reading, the smallest share of any read line that lay inside its
    /// box; for a keyword reading, ``TitleBlockReader/anchorConfidence``; `0` when nothing was read.
    public let confidence: Double
    /// Another page claims the same number.
    public var isDuplicateNumber: Bool = false

    public init(pageIndex: Int, number: String?, title: String?, source: Source, confidence: Double) {
        self.pageIndex = pageIndex
        self.number = number
        self.title = title
        self.source = source
        self.confidence = confidence
    }

    /// Whether anything was read at all.
    public var isEmpty: Bool { (number ?? "").isEmpty && (title ?? "").isEmpty }
}

extension PDFRectValue {
    /// Centre x, for the title-block reader.
    fileprivate var centreX: Double { origin.x + size.width / 2 }
    /// Centre y, for the title-block reader.
    fileprivate var centreY: Double { origin.y + size.height / 2 }
    /// Whether the point lies inside or on the edge.
    fileprivate func holds(x: Double, y: Double) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}
