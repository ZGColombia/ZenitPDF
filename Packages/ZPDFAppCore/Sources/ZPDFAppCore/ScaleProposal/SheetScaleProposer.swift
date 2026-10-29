import Foundation
import ZPDFUIPresentation

/// The scale proposal for one sheet, read from that sheet's own positioned text (bug
/// `ZenitPDFProjectDocument.swift:1118`).
///
/// The proposal used to be read from page 0's text only, with every line's bounds thrown away:
/// on a real set page 0 is a cover or an index with no scale, so the feature never fired, and the
/// sheets behind it — each at its own scale — never got a proposal. This reads the sheet it is
/// asked about, keeps the bounds, and adds the title-block proximity layer the parser defers to
/// (`ScaleNotationParser`): when two notations are equally good, the one printed in the
/// title-block corner of the sheet is the sheet's scale, and the other is a detail's.
///
/// Still a proposal, still never applied: see ``ScaleProposal``.
public struct SheetScaleProposer: Sendable {

    /// The share of each page dimension, from the bottom-right corner, treated as the title block
    /// when no template says otherwise.
    public static let titleBlockShare = 0.3

    public init() {}

    /// The sheet's proposal, or `nil` when nothing on it reads as a scale.
    ///
    /// - Parameters:
    ///   - titleBlock: where the title block is, when a person has boxed it (NL-AUTO-04); the
    ///     bottom-right corner zone otherwise.
    public func proposal(
        lines: [RecognisedTextLine],
        pageBox: PDFRectValue,
        userUnit: Double = 1,
        titleBlock: PDFRectValue? = nil
    ) -> ScaleProposal? {
        ScaleProposalEngine().proposal(
            forRecognisedLines: lines, pageBox: pageBox, userUnit: userUnit, titleBlock: titleBlock
        )
    }

    /// The sheet's scale candidates in the order ``ScaleProposalEngine/rank(_:pageBoxSizeInPoints:)``
    /// should see them — the one reading of a sheet's text every proposal entry point shares
    /// (L-21).
    ///
    /// A label split from its ratio by the text layer reads as a bare ratio, so split runs are
    /// rejoined on their baseline first (``BaselineLineMerger``) and each value is then read with
    /// the field caption over or beside it (``candidates(in:parser:)``). The engine breaks ties in
    /// reading order, so the title-block candidates go first: they win every tie and lose to a
    /// better-written notation elsewhere.
    static func orderedCandidates(
        in lines: [RecognisedTextLine],
        pageBox: PDFRectValue,
        titleBlock: PDFRectValue? = nil,
        parser: ScaleNotationParser = ScaleNotationParser()
    ) -> [ScaleCandidate] {
        let found = Self.candidates(in: BaselineLineMerger.merge(lines), parser: parser)
        guard !found.isEmpty else { return [] }
        let zone = titleBlock ?? defaultTitleBlockZone(of: pageBox)
        let inTitleBlock = found.filter { isInside($0.boundsInPageSpace, zone) }
        let elsewhere = found.filter { !isInside($0.boundsInPageSpace, zone) }
        return inTitleBlock + elsewhere
    }

    /// The bottom-right corner zone of the page box.
    public static func defaultTitleBlockZone(of pageBox: PDFRectValue) -> PDFRectValue {
        let width = pageBox.size.width * titleBlockShare
        let height = pageBox.size.height * titleBlockShare
        return PDFRectValue(x: pageBox.maxX - width, y: pageBox.minY, width: width, height: height)
    }

    // MARK: - Title-block fields (L-21)

    /// How far below its caption a value may sit, in caption-or-value heights, whichever is
    /// taller. A title block prints the caption small in the cell's top-left corner and the value
    /// under it: a caption a few points tall sits a few points over a value about twice its height.
    static let captionReachBelow = 2.0
    /// How far right of its neighbour a value may sit, in the smaller of the two heights. Past
    /// that the two are in different cells.
    static let neighbourReachRight = 4.0
    /// How far two runs on one row may overlap and still be read left-to-right, in the smaller
    /// height: glyph side bearings and italic overhang, not a second column.
    static let neighbourOverlap = 0.25

    /// The page's scale candidates, each value read with the text a title block lays out before
    /// it (L-21).
    ///
    /// On a real A1 roof plan the text layer handed over "SKALA" and "1:50" as two lines, caption
    /// over value, and "KV" and "1:10 …" as two runs of the area field. Read line by line both
    /// ratios were bare, they tied, reading order put the area field first, and the proposal
    /// offered 1:10 — a property designation — while the SKALA field said 1:50. The Synthetic
    /// Roof Plan test fixture reproduces that layout. Here each line that carries a notation is
    /// read after:
    ///
    /// - **its caption**: the nearest line above it that is only a scale label
    ///   (``ScaleNotationParser/isScaleLabel(_:)``), overlapping it horizontally, within
    ///   ``captionReachBelow`` heights, with no other line centred between the two. One caption
    ///   labels one value, the nearest;
    /// - **its left neighbour**: the nearest run on the same row that ends where it begins,
    ///   within ``neighbourReachRight`` heights.
    ///
    /// The parser then applies its own position rules to the joined text
    /// (``ScaleNotationParser/candidates(inLine:after:boundsInPageSpace:)``), so "SKALA" over
    /// "1:50" labels it and "KV" before "1:10" makes it a designation. Rows are judged by overlap
    /// and the in-between test by centres because a real text layer reports some runs with boxes
    /// far taller than their glyphs (a 13 pt value has arrived over 80 pt tall).
    static func candidates(
        in lines: [RecognisedTextLine],
        parser: ScaleNotationParser = ScaleNotationParser()
    ) -> [ScaleCandidate] {
        let boxes: [PDFRectValue?] = lines.map { line in
            guard let box = line.boundsInPageSpace, box.size.width >= 0, box.size.height > 0,
                  box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite
            else { return nil }
            return box
        }
        let values = lines.indices.filter { !parser.candidates(inLine: lines[$0].text).isEmpty }
        guard !values.isEmpty else { return [] }
        let captions = caption(for: values, lines: lines, boxes: boxes)

        return values.flatMap { index -> [ScaleCandidate] in
            let line = lines[index]
            let left = leftNeighbour(of: index, boxes: boxes)
            let context = [captions[index], left == captions[index] ? nil : left]
                .compactMap { $0.map { lines[$0].text } }
                .joined(separator: " ")
            return parser.candidates(inLine: line.text, after: context, boundsInPageSpace: line.boundsInPageSpace)
        }
    }

    /// Each value's caption line, nearest pair first, one caption per value and one value per
    /// caption.
    static func caption(
        for values: [Int],
        lines: [RecognisedTextLine],
        boxes: [PDFRectValue?]
    ) -> [Int: Int] {
        let labels = lines.indices.filter { boxes[$0] != nil && ScaleNotationParser.isScaleLabel(lines[$0].text) }
        var pairs: [(gap: Double, label: Int, value: Int)] = []
        for value in values {
            guard let v = boxes[value] else { continue }
            for label in labels where label != value {
                guard let l = boxes[label] else { continue }
                let gap = l.minY - v.maxY
                let tolerance = neighbourOverlap * Swift.min(l.size.height, v.size.height)
                guard gap >= -tolerance,
                      gap <= captionReachBelow * Swift.max(l.size.height, v.size.height) else { continue }
                let left = Swift.max(l.minX, v.minX), right = Swift.min(l.maxX, v.maxX)
                guard right > left else { continue }
                let between = boxes.indices.contains { other in
                    guard other != label, other != value, let o = boxes[other] else { return false }
                    let centre = o.center
                    return centre.x >= left && centre.x <= right && centre.y > v.maxY && centre.y < l.minY
                }
                if !between { pairs.append((gap, label, value)) }
            }
        }
        pairs.sort { ($0.gap, $0.value, $0.label) < ($1.gap, $1.value, $1.label) }
        var result: [Int: Int] = [:]
        var usedLabels: Set<Int> = []
        for pair in pairs where result[pair.value] == nil && !usedLabels.contains(pair.label) {
            result[pair.value] = pair.label
            usedLabels.insert(pair.label)
        }
        return result
    }

    /// The run immediately left of a line on the same row, or `nil`.
    static func leftNeighbour(of index: Int, boxes: [PDFRectValue?]) -> Int? {
        guard let v = boxes[index] else { return nil }
        var best: (distance: Double, index: Int)?
        for other in boxes.indices where other != index {
            guard let m = boxes[other] else { continue }
            let height = Swift.min(m.size.height, v.size.height)
            let overlapY = Swift.min(m.maxY, v.maxY) - Swift.max(m.minY, v.minY)
            guard overlapY >= height / 2, m.maxX <= v.minX + neighbourOverlap * height else { continue }
            let gap = v.minX - m.maxX
            guard gap <= neighbourReachRight * height else { continue }
            let distance = Swift.abs(gap)
            if best.map({ distance < $0.distance }) ?? true { best = (distance, other) }
        }
        return best?.index
    }

    static func isInside(_ bounds: PDFRectValue?, _ zone: PDFRectValue) -> Bool {
        guard let bounds else { return false }
        let x = bounds.minX + bounds.size.width / 2
        let y = bounds.minY + bounds.size.height / 2
        return x >= zone.minX && x <= zone.maxX && y >= zone.minY && y <= zone.maxY
    }
}
