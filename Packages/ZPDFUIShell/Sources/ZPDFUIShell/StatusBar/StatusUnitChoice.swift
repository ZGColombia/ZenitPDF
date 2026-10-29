import Foundation
import ZPDFUIPresentation

/// One row of the status strip's Unit menu (NL-UX-19).
public enum StatusUnitChoice: Hashable, Sendable {
    /// Metres, square metres, cubic metres.
    case metric
    /// Feet, square feet, cubic yards.
    case imperial
    /// Only the length unit changes.
    case length(LengthUnit)
    /// Lengths in decimal feet, `12.50 ft`, never feet-and-inches marks (NL-MEASURE-10).
    case decimalFeet
    /// Lengths in decimal inches, `150.00 in` (NL-MEASURE-10).
    case decimalInches
    /// A separator in the menu.
    case divider

    /// The rows in menu order.
    public static let menuChoices: [StatusUnitChoice] = [
        .metric, .imperial, .divider,
        .length(.millimetre), .length(.centimetre), .length(.metre),
        .length(.inch), .length(.foot), .length(.yard),
        .decimalFeet, .decimalInches
    ]

    /// The row's title.
    public var title: String {
        switch self {
        case .metric:
            return NSLocalizedString("Metric (m, m², m³)", comment: "Status strip unit menu: metric preset")
        case .imperial:
            return NSLocalizedString("Imperial (ft, ft², yd³)", comment: "Status strip unit menu: imperial preset")
        case .length(let unit):
            return String(
                format: NSLocalizedString("Lengths in %@", comment: "Status strip unit menu: length unit; the placeholder is the unit symbol"),
                unit.rawValue
            )
        case .decimalFeet:
            return NSLocalizedString("Decimal Feet (12.50 ft)", comment: "Status strip unit menu: lengths in decimal feet, never feet and inches")
        case .decimalInches:
            return NSLocalizedString("Decimal Inches (150.00 in)", comment: "Status strip unit menu: lengths in decimal inches")
        case .divider:
            return ""
        }
    }
}
