import Foundation
import ZPDFUIPresentation

/// Rejoins words a text layer split apart on one baseline.
///
/// PDFKit's line segmentation sometimes returns "Skala" and "1:100", or "PLAN" and "1", as two
/// lines when they were drawn as one — measured on the synthetic title blocks the automation
/// benchmark writes (NL-AUTO-25). A scale notation without its label word reads as a plain ratio
/// and loses to a detail's scale; a title loses its number. Two lines are one when their
/// vertical centres agree to within half the smaller height and the gap between them is under
/// one and a half heights; nothing else is merged.
public enum BaselineLineMerger {

    public static func merge(_ lines: [RecognisedTextLine]) -> [RecognisedTextLine] {
        let positioned = lines.compactMap { line -> (text: String, box: PDFRectValue)? in
            guard let box = line.boundsInPageSpace else { return nil }
            return (line.text, box)
        }
        let unpositioned = lines.filter { $0.boundsInPageSpace == nil }
        // Top to bottom, then left to right.
        let ordered = positioned.sorted {
            let a = $0.box.minY + $0.box.size.height / 2
            let b = $1.box.minY + $1.box.size.height / 2
            if Swift.abs(a - b) > Swift.min($0.box.size.height, $1.box.size.height) / 2 { return a > b }
            return $0.box.minX < $1.box.minX
        }
        var merged: [(text: String, box: PDFRectValue)] = []
        for line in ordered {
            if let last = merged.last, joins(last.box, line.box) {
                let box = union(last.box, line.box)
                merged[merged.count - 1] = (last.text + " " + line.text, box)
            } else {
                merged.append(line)
            }
        }
        return merged.map { RecognisedTextLine(text: $0.text, boundsInPageSpace: $0.box) } + unpositioned
    }

    static func joins(_ left: PDFRectValue, _ right: PDFRectValue) -> Bool {
        let height = Swift.min(left.size.height, right.size.height)
        guard height > 0 else { return false }
        let leftCentre = left.minY + left.size.height / 2
        let rightCentre = right.minY + right.size.height / 2
        guard Swift.abs(leftCentre - rightCentre) <= height / 2 else { return false }
        let gap = right.minX - left.maxX
        return gap >= -height / 2 && gap <= height * 1.5
    }

    static func union(_ a: PDFRectValue, _ b: PDFRectValue) -> PDFRectValue {
        let minX = Swift.min(a.minX, b.minX), minY = Swift.min(a.minY, b.minY)
        let maxX = Swift.max(a.maxX, b.maxX), maxY = Swift.max(a.maxY, b.maxY)
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
