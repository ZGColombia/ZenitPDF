import Foundation

/// What a stamp's artwork *is*, and therefore whether it stays sharp when magnified.
///
/// This is a product-visible fact rather than an implementation detail. Vector artwork stays
/// vector so a stamp is sharp at 400 % — the same principle as the zoom engine — and that is
/// why the preset editor marks a scanned-image stamp as such. An estimator who imports a
/// photographed approval seal is entitled to know, at import time, that it will blur — not to
/// discover it on a plot.
public enum StampArtworkKind: String, Codable, Hashable, Sendable, CaseIterable {

    /// Artwork imported from a PDF page and kept as geometry. Resolution independent.
    case vector

    /// Artwork imported from an image. It has a fixed pixel count and resamples when the
    /// canvas is magnified past that count, exactly as any raster does.
    case raster

    /// No artwork at all: the stamp is its fields and its style.
    case none

    /// Whether magnifying the canvas keeps this artwork's edges crisp.
    ///
    /// The single question the editor's warning is derived from, so the warning and the
    /// renderer cannot disagree about which stamps blur.
    public var staysSharpWhenMagnified: Bool { self != .raster }
}

/// The dynamic content a stamp can carry.
///
/// Seven kinds, and only these seven. They are *dynamic* only in the sense
/// that the template does not spell out their text; the placed markup does, because every
/// one of them is resolved at placement time and frozen — see ``StampInstance``.
public enum StampFieldKind: String, Codable, Hashable, Sendable, CaseIterable {

    /// The date the stamp was placed.
    case date
    /// The local author name at placement time.
    case author
    /// The label of the page the stamp landed on, for example `"A-101"`.
    case pageLabel
    /// The display name of the document.
    case documentName
    /// The document's active revision name.
    case revision
    /// The project's name.
    case projectName
    /// Text the person is prompted for as the stamp is placed.
    case freeText

    /// Whether placing the stamp has to ask the person for this field's text.
    public var isPrompted: Bool { self == .freeText }
}

/// One field of a stamp, as it was resolved at the instant the stamp was placed.
///
/// The text is stored, not the recipe. That is the whole point of the freezing rule: a stamp
/// that says 2026-08-24 must still say that next year.
public struct StampFieldValue: Codable, Hashable, Sendable {

    /// Which dynamic field this was before it was resolved.
    public var kind: StampFieldKind

    /// Distinguishes two fields of the same kind on one template — two free-text lines,
    /// a date in the corner and a date in the body. Zero for a template with one of each.
    public var slot: Int

    /// The text that was resolved when the stamp was placed, and never resolved again.
    public var resolvedText: String

    /// Creates a resolved field value.
    public init(kind: StampFieldKind, slot: Int = 0, resolvedText: String) {
        self.kind = kind
        self.slot = slot
        self.resolvedText = resolvedText
    }

    /// A stable key for the field, for the audit trail and for equality across templates.
    public var key: String { slot == 0 ? kind.rawValue : "\(kind.rawValue).\(slot)" }
}

/// A stamp as it lives on a placed markup: which template made it, and what its dynamic
/// fields said at the moment it was placed.
///
/// # Why the artwork is a digest and not bytes
///
/// A batch stamp puts the same artwork on 312 pages. Copying the artwork into 312 markups
/// would multiply an imported PDF page by 312 for no gain, so the instance names the
/// artwork by ``artworkDigest`` and the bytes are stored once. The digest is also what
/// makes the record self-describing: a project reopened without its tool library still
/// knows exactly which artwork the stamp was made from, and can say so, rather than
/// silently drawing something else.
///
/// # Why the template identity travels with the resolved values
///
/// The audit trail records both the template and the resolved values. Both are here, on the
/// record, so the trail is derived from the markup rather than from
/// a preset that may since have been edited or deleted. ``templateRevision`` is the
/// template's own version at placement time, which is what lets "this stamp does not match
/// the preset any more" be answered without guessing.
public struct StampInstance: Codable, Hashable, Sendable {

    /// The tool preset the stamp was placed from.
    public var templateID: UUID
    /// The preset's name at placement time, kept verbatim so a renamed preset does not
    /// rewrite history.
    public var templateName: String
    /// The preset's revision counter at placement time.
    public var templateRevision: Int

    /// SHA-256 of the artwork bytes, or `nil` when the template carries no artwork.
    public var artworkDigest: String?
    /// Whether that artwork stays sharp when magnified.
    public var artworkKind: StampArtworkKind

    /// Width of the stamp box in PDF points, before rotation.
    public var widthPoints: Double
    /// Height of the stamp box in PDF points, before rotation.
    public var heightPoints: Double
    /// Rotation of the stamp about its anchor, in degrees counter-clockwise.
    public var rotationDegrees: Double

    /// Every dynamic field, resolved and frozen, in template order.
    public var fields: [StampFieldValue]

    /// When the fields were resolved. Not the markup's `createdAt`: a stamp placed by a
    /// batch resolves once for the whole batch, and this records that instant.
    public var resolvedAt: Date

    /// Creates a placed stamp.
    public init(
        templateID: UUID,
        templateName: String,
        templateRevision: Int = 1,
        artworkDigest: String? = nil,
        artworkKind: StampArtworkKind = .none,
        widthPoints: Double,
        heightPoints: Double,
        rotationDegrees: Double = 0,
        fields: [StampFieldValue] = [],
        resolvedAt: Date
    ) {
        self.templateID = templateID
        self.templateName = templateName
        self.templateRevision = templateRevision
        self.artworkDigest = artworkDigest
        self.artworkKind = artworkKind
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.rotationDegrees = rotationDegrees
        self.fields = fields
        self.resolvedAt = resolvedAt
    }

    /// The resolved text of one field kind, or `nil` when the stamp carries none.
    public func text(for kind: StampFieldKind, slot: Int = 0) -> String? {
        fields.first { $0.kind == kind && $0.slot == slot }?.resolvedText
    }

    /// The resolved values as a key-sorted dictionary, which is the shape the audit trail
    /// records them in.
    public var resolvedValues: [String: String] {
        var values: [String: String] = [:]
        for field in fields { values[field.key] = field.resolvedText }
        return values
    }
}
