import Foundation

/// One drawing revision available to Revision Compare and Revision Overlay.
public struct RevisionSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the revision.
    public let id: UUID
    /// Document the revision refers to.
    public var documentID: UUID
    /// User-visible name, for example `"Ground Floor Plan"`.
    public var name: String
    /// Revision designation printed on the sheet, for example `"Rev C"`.
    public var revisionLabel: String
    /// Issue date printed on the sheet, or `nil` when the sheet carries none.
    public var issuedDate: Date?
    /// Who issued the revision.
    public var author: String
    /// Number of pages in the revision.
    public var pageCount: Int
    /// Whether this revision is the comparison baseline.
    public var isBaseline: Bool
    /// Unique overlay colour assigned to this revision.
    public var colorRGBA: ColorRGBA
    /// Source file name, shown as a subtitle.
    public var fileName: String

    /// Creates a revision summary.
    public init(
        id: UUID,
        documentID: UUID,
        name: String,
        revisionLabel: String,
        issuedDate: Date? = nil,
        author: String,
        pageCount: Int,
        isBaseline: Bool = false,
        colorRGBA: ColorRGBA,
        fileName: String
    ) {
        self.id = id
        self.documentID = documentID
        self.name = name
        self.revisionLabel = revisionLabel
        self.issuedDate = issuedDate
        self.author = author
        self.pageCount = pageCount
        self.isBaseline = isBaseline
        self.colorRGBA = colorRGBA
        self.fileName = fileName
    }

    /// A localized VoiceOver label: name, revision label and role.
    public var accessibilityLabel: String {
        let format = isBaseline
            ? NSLocalizedString("%1$@, %2$@, baseline", comment: "VoiceOver label for the baseline revision: name, revision label")
            : NSLocalizedString("%1$@, %2$@", comment: "VoiceOver label for a revision: name, revision label")
        return String(format: format, name, revisionLabel)
    }
}

/// What kind of change a compare region represents.
public enum CompareChangeKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Present in the comparison revision but not in the baseline.
    case added
    /// Present in the baseline but not in the comparison revision.
    case removed
    /// Present in both but drawn differently.
    case modified

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name shown as text next to the region badge.
    public var displayName: String {
        switch self {
        case .added: return NSLocalizedString("Added", comment: "Revision Compare change type")
        case .removed: return NSLocalizedString("Removed", comment: "Revision Compare change type")
        case .modified: return NSLocalizedString("Modified", comment: "Revision Compare change type")
        }
    }

    /// SF Symbol name so the change type is legible without colour.
    public var symbolName: String {
        switch self {
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .modified: return "arrow.triangle.2.circlepath.circle"
        }
    }

    /// Redundant colour cue from the palette, dark appearance.
    public var indicatorColor: ColorRGBA {
        switch self {
        case .added: return ColorRGBA.Zenit.Dark.green
        case .removed: return ColorRGBA.Zenit.Dark.danger
        case .modified: return ColorRGBA.Zenit.Dark.warning
        }
    }
}

/// One detected difference between two aligned revisions.
///
/// A difference is a *candidate* until the user accepts it. Zenit never states that a
/// difference constitutes a change order.
public struct CompareDiffSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the candidate.
    public let id: UUID
    /// What kind of change it is.
    public var changeKind: CompareChangeKind
    /// Page in the baseline revision, or `nil` when the region only exists in the comparison.
    public var baselinePageID: PageDescriptor.ID?
    /// Page in the comparison revision, or `nil` when the region only exists in the baseline.
    public var comparisonPageID: PageDescriptor.ID?
    /// Page label the region is reported under.
    public var pageLabel: String
    /// Region bounds in the baseline's page space, when it exists there.
    public var baselineBounds: PDFRectValue?
    /// Region bounds in the comparison's page space, when it exists there.
    public var comparisonBounds: PDFRectValue?
    /// Area of the changed region in square PDF points, used to rank candidates.
    public var areaInSquarePoints: Double
    /// Detector confidence, `0...1`.
    public var confidence: Double
    /// Whether the user accepted the candidate.
    public var isAccepted: Bool
    /// The Zenit markup created when the candidate was accepted, or `nil`.
    public var promotedMarkupID: UUID?

    /// Creates a compare difference summary.
    public init(
        id: UUID,
        changeKind: CompareChangeKind,
        baselinePageID: PageDescriptor.ID? = nil,
        comparisonPageID: PageDescriptor.ID? = nil,
        pageLabel: String,
        baselineBounds: PDFRectValue? = nil,
        comparisonBounds: PDFRectValue? = nil,
        areaInSquarePoints: Double,
        confidence: Double,
        isAccepted: Bool = false,
        promotedMarkupID: UUID? = nil
    ) {
        self.id = id
        self.changeKind = changeKind
        self.baselinePageID = baselinePageID
        self.comparisonPageID = comparisonPageID
        self.pageLabel = pageLabel
        self.baselineBounds = baselineBounds
        self.comparisonBounds = comparisonBounds
        self.areaInSquarePoints = areaInSquarePoints
        self.confidence = min(1, max(0, confidence))
        self.isAccepted = isAccepted
        self.promotedMarkupID = promotedMarkupID
    }

    /// A localized VoiceOver label: change type, page and review state.
    public var accessibilityLabel: String {
        let base = String(
            format: NSLocalizedString(
                "%1$@ region on page %2$@",
                comment: "VoiceOver label for a compare difference: change type, page label"
            ),
            changeKind.displayName,
            pageLabel
        )
        guard isAccepted else { return base }
        return base + ", " + NSLocalizedString("accepted", comment: "VoiceOver suffix for an accepted compare difference")
    }
}

/// How two revisions are blended in Revision Overlay.
public enum RevisionOverlayBlendMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Straight alpha compositing.
    case normal
    /// Multiply, which keeps dark linework from both revisions.
    case multiply
    /// Screen, which keeps light areas.
    case screen
    /// Difference, which makes changes stand out.
    case difference

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the blend picker.
    public var displayName: String {
        switch self {
        case .normal: return NSLocalizedString("Normal", comment: "Revision Overlay blend mode")
        case .multiply: return NSLocalizedString("Multiply", comment: "Revision Overlay blend mode")
        case .screen: return NSLocalizedString("Screen", comment: "Revision Overlay blend mode")
        case .difference: return NSLocalizedString("Difference", comment: "Revision Overlay blend mode")
        }
    }
}

/// How the two revisions were brought into register.
public enum RevisionAlignmentState: Codable, Hashable, Sendable {

    /// No alignment has been applied yet.
    case notAligned
    /// Two-point manual alignment: translation, rotation and uniform scale.
    case manualTwoPoint(residualPixels: Double)
    /// Three-point manual alignment: affine or homography.
    case manualThreePoint(residualPixels: Double)
    /// Feature-based automatic alignment.
    case automatic(inlierRatio: Double, medianReprojectionErrorPixels: Double)
    /// Aligned by matching the two pages' boxes (size and origin), with the residual left
    /// after that fit (BH-107).
    case pageBox(residualPixels: Double)
    /// Alignment was attempted and rejected; manual alignment is offered instead.
    case failed(reason: String)

    /// Whether measurements and compare results may be trusted at all.
    public var isAligned: Bool {
        switch self {
        case .notAligned, .failed: return false
        case .manualTwoPoint, .manualThreePoint, .automatic, .pageBox: return true
        }
    }

    /// A localized status line for the compare toolbar.
    public var displayName: String {
        switch self {
        case .notAligned:
            return NSLocalizedString("Not aligned", comment: "Revision alignment state")
        case .manualTwoPoint(let residual):
            let format = NSLocalizedString("Aligned on two points, residual %.2f px", comment: "Revision alignment state with residual error")
            return String(format: format, residual)
        case .manualThreePoint(let residual):
            let format = NSLocalizedString("Aligned on three points, residual %.2f px", comment: "Revision alignment state with residual error")
            return String(format: format, residual)
        case .automatic(let ratio, let error):
            let format = NSLocalizedString("Aligned automatically, %.0f%% inliers, %.2f mean difference", comment: "Revision alignment state with inlier ratio and the mean gray-level difference after alignment (0–255)")
            return String(format: format, ratio * 100, error)
        case .pageBox(let residual):
            let format = NSLocalizedString("Aligned by page size, residual %.2f px", comment: "Revision alignment state: aligned by matching page boxes, with residual error")
            return String(format: format, residual)
        case .failed(let reason):
            let format = NSLocalizedString("Automatic alignment failed: %@", comment: "Revision alignment failure with reason")
            return String(format: format, reason)
        }
    }
}
