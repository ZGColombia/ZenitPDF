import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// One markup as VoiceOver meets it on the canvas (NL-PLAT-20): its label says what it is and
/// what it measures, and pressing it selects it — the same selection a click makes.
final class CanvasMarkupAccessibilityElement: NSAccessibilityElement {
    let markupID: UUID
    private let onPress: ((UUID) -> Void)?

    init(markupID: UUID, onPress: ((UUID) -> Void)?) {
        self.markupID = markupID
        self.onPress = onPress
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress(markupID)
        return true
    }
}

enum CanvasAccessibilityText {

    /// "Slab, A, 21.40 m², sheet A-101": subject, label, main quantity and sheet, each only when
    /// there is one. The kind stands in for a markup with no subject.
    ///
    /// The quantity is `MeasurementFieldSummary.displayTextWithUnit`, the one value-and-unit rule
    /// the Inspector, the pills and the captions read, so a feet-and-inches length is spoken
    /// `12'-6"` alone (X-023). This label used to join text and symbol itself and said `12'-6" ft`.
    static func label(for summary: MarkupSummary) -> String {
        var parts: [String] = []
        parts.append(summary.subject.isEmpty ? summary.kind.displayName : summary.subject)
        if !summary.label.isEmpty { parts.append(summary.label) }
        if let field = summary.primaryField {
            parts.append(field.displayTextWithUnit)
        }
        if !summary.pageLabel.isEmpty {
            parts.append(String(format: NSLocalizedString("sheet %@", comment: "VoiceOver: the sheet a markup is on; the sheet label"), summary.pageLabel))
        }
        return parts.joined(separator: ", ")
    }
}

extension PDFCanvasViewController {

    /// Gives the canvas's markups their spoken labels from the takeoff and their press action.
    func installMarkupAccessibility() {
        pageView.markupAccessibilityTexts = { [weak self] in
            guard let self else { return [:] }
            return Dictionary(self.core.snapshot.markups.map { ($0.id, CanvasAccessibilityText.label(for: $0)) }, uniquingKeysWith: { first, _ in first })
        }
        pageView.onMarkupAccessibilityPress = { [weak self] id in
            guard let self else { return }
            self.core.canvas.select(markupIDs: [id], additive: false)
            self.refresh()
        }
    }
}
