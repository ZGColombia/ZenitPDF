import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The style fields carried between the contract's `MarkupStyle` and the
/// presentation tier: line ends, font family and text alignment.
///
/// `MarkupStyle` has always held all three. The presentation tier never carried them up, so
/// nothing could show them, edit them, or — on the canvas — draw them.
public enum MarkupStyleBridge {

    /// Copies the stored ends, font and alignment onto a summary.
    public static func carry(_ style: MarkupStyle, into summary: inout MarkupSummary) {
        summary.startCap = MarkupLineCap(domain: style.startCap)
        summary.endCap = MarkupLineCap(domain: style.endCap)
        summary.fontName = style.fontName
        summary.textAlignment = MarkupTextAlignment(domain: style.textAlignment)
        // Round 2 (ADR-0029).
        summary.bold = style.textStyle?.bold
        summary.italic = style.textStyle?.italic
        summary.textColorRGBA = style.textStyle?.textColor.map { ColorRGBA(domain: $0) }
        summary.boxBorder = style.textStyle?.boxBorder
        summary.cloudArcSize = style.cloudArcSize
        summary.rotationDegrees = style.rotationDegrees
        summary.multiplyBlend = style.blendMode == .multiply ? true : nil
    }

    /// Copies the record-level round-2 fields (group, link) onto a summary (ADR-0029).
    public static func carry(recordFieldsOf record: MarkupRecord, into summary: inout MarkupSummary) {
        summary.groupID = record.groupID?.rawValue
        summary.linkURL = record.link?.url
        summary.linkPageID = record.link?.pageID?.rawValue
    }
}

extension MarkupLineCap {

    /// The presentation mirror of the contract's `LineCapStyle`.
    public init(domain: ZPDFContracts.LineCapStyle) {
        switch domain {
        case .none: self = .none
        case .openArrow: self = .openArrow
        case .closedArrow: self = .closedArrow
        case .circle: self = .circle
        case .square: self = .square
        case .diamond: self = .diamond
        case .slash: self = .slash
        case .butt: self = .butt
        case .round: self = .round
        }
    }

    /// Back to the domain.
    public var domain: ZPDFContracts.LineCapStyle {
        switch self {
        case .none: return .none
        case .openArrow: return .openArrow
        case .closedArrow: return .closedArrow
        case .circle: return .circle
        case .square: return .square
        case .diamond: return .diamond
        case .slash: return .slash
        case .butt: return .butt
        case .round: return .round
        }
    }
}

extension MarkupTextAlignment {

    /// The presentation mirror of the contract's `TextAlignment`.
    public init(domain: ZPDFContracts.TextAlignment) {
        switch domain {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        case .justified: self = .justified
        }
    }

    /// Back to the domain.
    public var domain: ZPDFContracts.TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        case .justified: return .justified
        }
    }
}
