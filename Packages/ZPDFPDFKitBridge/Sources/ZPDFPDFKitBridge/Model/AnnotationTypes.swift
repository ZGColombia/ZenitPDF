import CoreGraphics
import Foundation

/// The annotation subtypes this bridge understands as data.
///
/// Anything else round-trips as ``other(_:)`` carrying the raw `/Subtype` name, so an
/// unrecognised annotation is never silently lost when a document is read.
public enum AnnotationKind: Sendable, Hashable, Codable {
    case text
    case link
    case freeText
    case line
    case square
    case circle
    case polygon
    case polyLine
    case highlight
    case underline
    case squiggly
    case strikeOut
    case stamp
    case ink
    case popup
    case fileAttachment
    case widget
    case redact
    case other(String)

    /// The PDF `/Subtype` name.
    public var pdfSubtype: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .freeText: return "FreeText"
        case .line: return "Line"
        case .square: return "Square"
        case .circle: return "Circle"
        case .polygon: return "Polygon"
        case .polyLine: return "PolyLine"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .squiggly: return "Squiggly"
        case .strikeOut: return "StrikeOut"
        case .stamp: return "Stamp"
        case .ink: return "Ink"
        case .popup: return "Popup"
        case .fileAttachment: return "FileAttachment"
        case .widget: return "Widget"
        case .redact: return "Redact"
        case let .other(name): return name
        }
    }

    public init(pdfSubtype: String) {
        switch pdfSubtype {
        case "Text": self = .text
        case "Link": self = .link
        case "FreeText": self = .freeText
        case "Line": self = .line
        case "Square": self = .square
        case "Circle": self = .circle
        case "Polygon": self = .polygon
        case "PolyLine": self = .polyLine
        case "Highlight": self = .highlight
        case "Underline": self = .underline
        case "Squiggly": self = .squiggly
        case "StrikeOut": self = .strikeOut
        case "Stamp": self = .stamp
        case "Ink": self = .ink
        case "Popup": self = .popup
        case "FileAttachment": self = .fileAttachment
        case "Widget": self = .widget
        case "Redact": self = .redact
        default: self = .other(pdfSubtype)
        }
    }
}

/// A colour as four components in the sRGB space, 0…1.
///
/// Not `NSColor`: nothing in this package imports AppKit.
public struct AnnotationColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clampedToUnitInterval
        self.green = green.clampedToUnitInterval
        self.blue = blue.clampedToUnitInterval
        self.alpha = alpha.clampedToUnitInterval
    }
}

extension Double {
    var clampedToUnitInterval: Double {
        guard isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, self))
    }
}

/// What an annotation's action *is*, recorded and never performed.
///
/// A `Link` annotation with a `/Launch` action is a file on the estimator's disk that a
/// PDF wants to run. Zenit PDF shows the user what it is; it does not do it (spec 7.4).
public enum AnnotationActionSummary: Sendable, Hashable, Codable {
    case goToPage(pageIndex: Int?)
    case goToNamedDestination(String)
    case uri(String)
    case launch(fileName: String?)
    case remoteGoTo(fileName: String?)
    case javaScript
    case named(String)
    case other(String)
}

/// A PDF annotation as a neutral value.
///
/// This is deliberately not a mirror of `PDFAnnotation`: it carries what Zenit PDF needs
/// to display, round-trip and audit an annotation, in types that survive being sent to
/// another actor and written to a ledger.
public struct NeutralAnnotation: Sendable, Hashable, Codable {
    public var pageIndex: Int
    public var kind: AnnotationKind
    /// The annotation rectangle in page space.
    public var bounds: CGRect
    public var contents: String?
    public var subject: String?
    public var author: String?
    public var color: AnnotationColor?
    public var interiorColor: AnnotationColor?
    public var borderWidth: Double?
    /// Polygon and polyline vertices, or a line's two endpoints, in page space.
    public var points: [CGPoint]
    /// Ink strokes, one array of points per stroke, in page space.
    ///
    /// Read back from `/InkList`, and written through PDFKit's Bézier-path API on macOS (the
    /// only shape PDFKit accepts ink in; handing it `/InkList` numbers crashes its appearance
    /// generator). The first annotated export promised an `Ink` fallback that this refusal made
    /// impossible (nl-pdf bug 3).
    public var inkPaths: [[CGPoint]]
    /// Text-markup quadrilaterals, four points each, in page space.
    public var quadPoints: [CGPoint]
    /// The action, described but never executed.
    public var action: AnnotationActionSummary?
    /// `/M`, the modification date, when the annotation declares one.
    public var modificationDate: Date?
    /// `/CreationDate`, when the annotation declares one.
    public var creationDate: Date?
    /// `/NM`, the annotation's own name, when it has one.
    ///
    /// PDFKit discards `/NM` when it writes a file (measured on macOS 26), so the writer also
    /// stores it under ``ZenitAnnotationOwnership/nameKey``, which PDFKit keeps, and the reader
    /// falls back to that key.
    public var name: String?
    /// Whether Zenit wrote this annotation. Written as ``ZenitAnnotationOwnership/ownerKey``;
    /// ``AnnotationWriteMode/supersedeZenitOwned`` replaces such annotations instead of stacking
    /// a second set on a re-export (nl-pdf bug 5).
    public var isZenitOwned: Bool
    /// For a link to a page of this drawing: the page-space left and top it lands on, each
    /// `nil` when the destination leaves that axis to the reader (NL-DOCS-09). Not coded.
    public var destinationLeft: Double? = nil
    public var destinationTop: Double? = nil

    public init(
        pageIndex: Int,
        kind: AnnotationKind,
        bounds: CGRect,
        contents: String? = nil,
        subject: String? = nil,
        author: String? = nil,
        color: AnnotationColor? = nil,
        interiorColor: AnnotationColor? = nil,
        borderWidth: Double? = nil,
        points: [CGPoint] = [],
        inkPaths: [[CGPoint]] = [],
        quadPoints: [CGPoint] = [],
        action: AnnotationActionSummary? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        name: String? = nil,
        isZenitOwned: Bool = false
    ) {
        self.pageIndex = pageIndex
        self.kind = kind
        self.bounds = bounds
        self.contents = contents
        self.subject = subject
        self.author = author
        self.color = color
        self.interiorColor = interiorColor
        self.borderWidth = borderWidth
        self.points = points
        self.inkPaths = inkPaths
        self.quadPoints = quadPoints
        self.action = action
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.name = name
        self.isZenitOwned = isZenitOwned
    }

    private enum CodingKeys: String, CodingKey {
        case pageIndex, kind, bounds, contents, subject, author, color, interiorColor, borderWidth
        case points, inkPaths, quadPoints, action, modificationDate, creationDate, name, isZenitOwned
    }

    /// Decodes a value written before ``isZenitOwned`` existed as not owned.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        kind = try c.decode(AnnotationKind.self, forKey: .kind)
        bounds = try c.decode(CGRect.self, forKey: .bounds)
        contents = try c.decodeIfPresent(String.self, forKey: .contents)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        color = try c.decodeIfPresent(AnnotationColor.self, forKey: .color)
        interiorColor = try c.decodeIfPresent(AnnotationColor.self, forKey: .interiorColor)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth)
        points = try c.decode([CGPoint].self, forKey: .points)
        inkPaths = try c.decode([[CGPoint]].self, forKey: .inkPaths)
        quadPoints = try c.decode([CGPoint].self, forKey: .quadPoints)
        action = try c.decodeIfPresent(AnnotationActionSummary.self, forKey: .action)
        modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        isZenitOwned = try c.decodeIfPresent(Bool.self, forKey: .isZenitOwned) ?? false
    }
}

/// The keys that mark an annotation as Zenit's own, shared by the PDFKit writer here and the
/// incremental annotation writer in `ZPDFExport`, so either one recognises the other's marks.
public enum ZenitAnnotationOwnership {
    /// A second-class key (ISO 32000-1 §7.12.2) readers ignore. Present means Zenit wrote it.
    public static let ownerKey = "ZPDFMarkup"
    /// The annotation's name, kept where PDFKit does not strip it.
    public static let nameKey = "ZPDFName"
    /// `/Subj` of every annotation the first annotated export wrote, before either key existed.
    public static let legacySubject = "Zenit"

    /// Whether an annotation stands for one of `markupNames` — the markups an output paints, or
    /// hides on purpose — and so is left out of that output (L-23): its `/NM` (or the
    /// ``nameKey`` copy PDFKit keeps) names one of them, or it is one of the first export's
    /// unnamed `/Subj (Zenit)` annotations, which name no markup at all.
    ///
    /// The ownership key alone is **not** enough. A drawing a colleague saved markups into carries
    /// their annotations with the key, and while those markups are not in this project the
    /// canvas draws them (only a restore hides them), so every output draws them too.
    ///
    /// - Parameter markupNames: canonical names, as ``canonicalName(_:)`` spells them.
    public static func supersedes(name: String?, subject: String?, markupNames: Set<String>) -> Bool {
        if let name, !name.isEmpty { return markupNames.contains(canonicalName(name)) }
        return subject == legacySubject
    }

    /// A markup name as `UUID.uuidString` spells it (upper case), so a `/NM` another tool
    /// rewrote in lower case still matches; any other text is returned as it is.
    public static func canonicalName(_ name: String) -> String {
        UUID(uuidString: name)?.uuidString ?? name
    }
}

/// What to do with the annotations already in the document being copied.
public enum AnnotationWriteMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Keep every existing annotation and add the new ones.
    case append
    /// Drop every existing annotation on the pages being written to, then add the new
    /// ones. Pages not named by any request keep their annotations.
    case replaceOnTouchedPages
    /// Drop every existing annotation in the whole document, then add the new ones.
    case replaceAll
    /// Keep everybody else's annotations; drop the ones Zenit wrote before — marked with
    /// ``ZenitAnnotationOwnership/ownerKey``, named like one being written, or carrying the first
    /// export's legacy subject and no name — then add the new ones. A re-export replaces its own
    /// set instead of stacking a second one on top.
    case supersedeZenitOwned
}

/// A batch of annotations to write into a copy of a document.
public struct AnnotationWriteRequest: Sendable, Hashable {
    public var annotations: [NeutralAnnotation]
    public var mode: AnnotationWriteMode

    public init(annotations: [NeutralAnnotation], mode: AnnotationWriteMode = .append) {
        self.annotations = annotations
        self.mode = mode
    }
}
