import Foundation
import ZPDFContracts

/// Which style fields a markup can actually hold — drawn, not merely stored.
///
/// A bulk edit reaches a mixed selection, and Paste Style reaches whatever is selected. Writing
/// a fill onto an arrow, a font onto a polyline or the Cloud line style onto a line stores a
/// value nothing draws, costs an undo step that changes nothing visible, and is exactly the
/// "Cloud does nothing on a rectangle" defect in another costume. These rules decide, per
/// markup, which fields of an edit it takes; the rest are skipped for that markup.
public enum MarkupStyleFit {

    /// Whether the kind is an open stroke whose two ends can carry decorations — a line, an
    /// arrow, a polyline, a freehand stroke, or a callout's leader.
    public static func holdsLineEnds(_ kind: MarkupKind) -> Bool {
        switch kind {
        // A cloud's ends are a clouded callout's leader (ADR-0029 §2.4).
        case .line, .arrow, .polyline, .freehand, .callout, .cloud: true
        default: false
        }
    }

    /// Whether the kind draws words, so a font family and an alignment mean something.
    public static func holdsText(_ kind: MarkupKind) -> Bool {
        // A cloud draws words when it is a clouded callout (ADR-0029 §2.4).
        kind == .text || kind == .callout || kind == .cloud
    }

    /// Whether the kind turns by `MarkupStyle.rotationDegrees` (ADR-0029): the record's own rule
    /// (`MarkupRecord.turnsWithStyleRotation`), the one the canvas draws the turn and its knob
    /// by, rather than a second copy of its kind list (U-006, iteration 4).
    public static func holdsRotation(_ record: MarkupRecord) -> Bool {
        record.turnsWithStyleRotation
    }

    /// Whether the kind draws the Cloud line style as scallops.
    public static func holdsCloudStyle(_ kind: MarkupKind) -> Bool {
        switch kind {
        case .rectangle, .ellipse, .polygon, .cloud, .revisionCloud: true
        default: false
        }
    }

    /// Whether the markup has an interior a fill is drawn in.
    public static func holdsFill(_ record: MarkupRecord) -> Bool {
        switch record.kind {
        // A Text box takes a fill since ADR-0029 (NL-MARKUP-08).
        case .line, .arrow, .polyline, .freehand, .highlight, .underline, .strikeout, .hyperlink:
            return false
        case .measurement, .count:
            guard let geometry = record.geometry else { return false }
            return !geometry.polygons.isEmpty || !geometry.circles.isEmpty
        default:
            return true
        }
    }

    /// The fill a markup keeps when its stroke colour changes from `old` to `new` (L-87).
    ///
    /// A closed area is drawn with a fill that is its stroke's tint — the same red, green and
    /// blue at a lower alpha (`AppMeasurementToolPresenter.measurementFill(for:)`, the 20 % the
    /// tools store). Colour ▸ Green used to change only the stroke, so the pill and the ledger
    /// swatch turned green while the shape stayed blue on the canvas. A fill that tints the old
    /// colour now follows the new one at its own alpha; a fill picked separately (another hue,
    /// through Fill or the Inspector) is the person's choice and stays; no stored fill stays
    /// none, which the canvas already derives from the stroke.
    public static func fill(_ fill: RGBAColor?, followingColourFrom old: RGBAColor, to new: RGBAColor) -> RGBAColor? {
        guard let fill, tints(fill, old) else { return fill }
        return RGBAColor(red: new.red, green: new.green, blue: new.blue, alpha: fill.alpha)
    }

    /// Whether `fill` is `stroke`'s tint: the same red, green and blue, within the 8-bit step a
    /// colour picked in a panel and stored as `Double` can drift by.
    static func tints(_ fill: RGBAColor, _ stroke: RGBAColor) -> Bool {
        let step = 0.5 / 255
        return abs(fill.red - stroke.red) <= step
            && abs(fill.green - stroke.green) <= step
            && abs(fill.blue - stroke.blue) <= step
    }
}
