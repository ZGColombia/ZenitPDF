import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// How much a review finding matters.
public enum ToolSetImportFindingSeverity: String, Hashable, Sendable, CaseIterable, Comparable {

    /// Worth knowing, changes nothing.
    case notice
    /// Something in the file was adjusted or left out.
    case warning
    /// The set cannot be imported as it stands.
    case blocking

    /// Orders severities from least to most serious.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.notice, .warning, .blocking]
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
        return l < r
    }

    /// The design-system severity used to draw the finding, so it is never colour alone.
    public var displaySeverity: ZPDFSeverity {
        switch self {
        case .notice: return .info
        case .warning: return .warning
        case .blocking: return .danger
        }
    }

    /// A localized name spoken ahead of the message.
    public var displayName: String {
        switch self {
        case .notice:
            return NSLocalizedString("Note", comment: "Tool set import finding severity")
        case .warning:
            return NSLocalizedString("Adjusted", comment: "Tool set import finding severity")
        case .blocking:
            return NSLocalizedString("Blocked", comment: "Tool set import finding severity")
        }
    }
}

/// What the import-safety review found.
public enum ToolSetImportFindingCode: String, Hashable, Sendable, CaseIterable {

    /// The file was written by a newer or older schema than this build reads.
    case unsupportedSchemaVersion
    /// The file describes no tools at all.
    case emptySet
    /// The file describes more tools than one set is allowed to hold.
    case tooManyPresets
    /// A field this build does not know about was present and was left alone.
    case unknownField
    /// A tool was missing something it cannot do without.
    case missingRequiredField
    /// A tool named a markup family this build does not have.
    case unknownMarkupType
    /// A tool named a measurement tool this build does not have.
    case unknownMeasurementTool
    /// A tool named a display unit this build does not have.
    case unknownDisplayUnit
    /// A colour was not written as `#RRGGBB`.
    case invalidColor
    /// Text was longer than a name or a default is allowed to be, and was shortened.
    case overlongText
    /// A tool carried more custom defaults than are allowed, and the extras were dropped.
    case tooManyDefaults
    /// A symbol name was not a plain symbol name, and a neutral symbol was used instead.
    case suspiciousSymbolName
    /// Text in the file looks like markup or a script. It is stored and shown as plain text.
    case markupLikeText
    /// Text in the file points somewhere outside it. Zenit does not follow it.
    case externalReference
    /// An embedded image was bigger than the limit and was left out.
    case embeddedImageTooLarge
    /// An embedded image claimed more pixels than the limit and was left out.
    case embeddedImageTooManyPixels
    /// An embedded image was in a format Zenit does not read, and was left out.
    case unsupportedImageFormat
    /// The file carried more embedded images than the limit; the extras were left out.
    case tooManyEmbeddedImages
    /// Two tools claimed the same identity. The second was given a fresh one.
    case duplicateIdentifier
    /// A measurement parameter was not a number Zenit will store, and was left out.
    case valueOutOfRange
    /// A stamp was exported with a picture that is not in the file; the tool arrives without
    /// it. Finding BH-319.
    case artworkNotIncluded
    /// Part of a stamp's template was not something Zenit will store, and was left out.
    case invalidStamp
    /// A tool's assembly (its `zenit.assembly` default, NL-QTY-07) was not an assignment Zenit
    /// can read, or was larger than the limit, and was left out whole — never shortened.
    case invalidAssembly

    /// How serious this kind of finding is.
    public var severity: ToolSetImportFindingSeverity {
        switch self {
        case .unsupportedSchemaVersion, .emptySet, .tooManyPresets:
            return .blocking
        case .unknownField, .duplicateIdentifier, .unknownDisplayUnit:
            return .notice
        case .missingRequiredField, .unknownMarkupType, .unknownMeasurementTool, .invalidColor,
             .overlongText, .tooManyDefaults, .suspiciousSymbolName, .markupLikeText,
             .externalReference, .embeddedImageTooLarge, .embeddedImageTooManyPixels,
             .unsupportedImageFormat, .tooManyEmbeddedImages, .valueOutOfRange,
             .artworkNotIncluded, .invalidStamp, .invalidAssembly:
            return .warning
        }
    }
}

/// One thing the review noticed, in language a person can act on.
public struct ToolSetImportFinding: Hashable, Sendable, Identifiable {

    /// Deterministic identity, so the same file always produces the same list.
    public let id: String
    /// What was found.
    public var code: ToolSetImportFindingCode
    /// How serious it is.
    public var severity: ToolSetImportFindingSeverity
    /// The tool it concerns, or `nil` when it concerns the whole file.
    public var presetName: String?
    /// What happened and what Zenit did about it.
    public var message: String

    /// Creates a finding.
    public init(
        id: String,
        code: ToolSetImportFindingCode,
        severity: ToolSetImportFindingSeverity? = nil,
        presetName: String? = nil,
        message: String
    ) {
        self.id = id
        self.code = code
        self.severity = severity ?? code.severity
        self.presetName = presetName
        self.message = message
    }

    /// A localized VoiceOver label: severity, tool, message.
    public var accessibilityLabel: String {
        if let presetName {
            let format = NSLocalizedString(
                "%1$@, %2$@: %3$@",
                comment: "VoiceOver label for an import finding: severity, tool name, message"
            )
            return String(format: format, severity.displayName, presetName, message)
        }
        let format = NSLocalizedString(
            "%1$@: %2$@",
            comment: "VoiceOver label for an import finding: severity, message"
        )
        return String(format: format, severity.displayName, message)
    }
}

/// What one embedded image in the file claims to be.
///
/// The review reports the claim. The bytes are not decoded until the person accepts the import.
public struct ToolSetEmbeddedImageReview: Hashable, Sendable, Identifiable {

    /// Deterministic identity.
    public let id: String
    /// The tool that carries the image.
    public var presetName: String
    /// The name written in the file.
    public var fileName: String
    /// The format written in the file.
    public var declaredFormat: String
    /// How many bytes the base64 text would decode to.
    public var declaredByteCount: Int
    /// Declared pixel width.
    public var pixelWidth: Int
    /// Declared pixel height.
    public var pixelHeight: Int
    /// Whether Zenit will keep it if the import goes ahead.
    public var isAccepted: Bool
    /// The identity of the preset that carries it, as the validator assigned it, so the
    /// picture can be attached to that preset once the person has said yes (BH-320).
    public var presetID: UUID?
    /// The picture as base64 text, exactly as the file wrote it. Never decoded during the
    /// review; decoded only by ``ToolLibraryEditingModel/attachImportedPictures(_:)`` after
    /// the import is confirmed.
    public var base64Data: String

    /// Creates an embedded image review row.
    public init(
        id: String,
        presetName: String,
        fileName: String,
        declaredFormat: String,
        declaredByteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        isAccepted: Bool,
        presetID: UUID? = nil,
        base64Data: String = ""
    ) {
        self.id = id
        self.presetName = presetName
        self.fileName = fileName
        self.declaredFormat = declaredFormat
        self.declaredByteCount = declaredByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isAccepted = isAccepted
        self.presetID = presetID
        self.base64Data = base64Data
    }

    /// A localized one-line description: format, pixels, size.
    public var detailLine: String {
        let format = NSLocalizedString(
            // `%ld`, not `%d`: the pixel counts are Swift `Int`, read from an untrusted file, and
            // `%d` consumes a C int — a declared 4294967297 printed as 1. Finding BH-852.
            "%1$@ · %2$ld × %3$ld px · %4$@",
            comment: "Embedded image detail: format, width, height, byte size"
        )
        return String(
            format: format,
            declaredFormat.uppercased(),
            pixelWidth,
            pixelHeight,
            ByteCountFormatter.string(fromByteCount: Int64(declaredByteCount), countStyle: .file)
        )
    }
}

/// Everything a person needs to see before deciding to trust an imported tool set.
///
/// The review is produced *without* adding anything to the Tool Library. It is the whole point
/// of the import-safety sheet: a file is described, in full, before it is believed.
public struct ToolSetImportReview: Hashable, Sendable, Identifiable {

    /// The file the review is about.
    public var fileName: String
    /// The set's name, as the file gives it.
    public var setName: String
    /// Who the file says exported it, as untrusted text.
    public var declaredAuthor: String?
    /// When the file says it was exported.
    public var declaredExportDate: Date?
    /// The schema version the file declares.
    public var schemaVersion: Int
    /// How big the file is on disk.
    public var byteCount: Int
    /// How many tools the file claims to hold, before anything was dropped.
    public var declaredPresetCount: Int
    /// The tools Zenit would actually add, already sanitized.
    public var presets: [ToolPresetSummary]
    /// How many tools of each markup family the set holds.
    public var markupKindCounts: [MarkupKind: Int]
    /// How many tools of each measurement tool the set holds.
    public var measurementKindCounts: [MeasurementKind: Int]
    /// The symbol names the set asks for, deduplicated and sorted.
    public var countSymbolNames: [String]
    /// The custom Quantity Ledger columns the set writes defaults into, sorted.
    public var customDefaultKeys: [String]
    /// The images the set carries.
    public var embeddedImages: [ToolSetEmbeddedImageReview]
    /// Everything the review noticed, most serious first.
    public var findings: [ToolSetImportFinding]
    /// Arriving tools whose identity is already in the library, as *fresh identity → identity
    /// in the library*. The validator re-mints a colliding identity; this remembers which tool
    /// it collided with, so the import can offer to update that tool instead (IM-233).
    public var libraryMatches: [UUID: UUID]

    /// Creates a review.
    public init(
        fileName: String,
        setName: String,
        declaredAuthor: String? = nil,
        declaredExportDate: Date? = nil,
        schemaVersion: Int,
        byteCount: Int,
        declaredPresetCount: Int,
        presets: [ToolPresetSummary],
        markupKindCounts: [MarkupKind: Int],
        measurementKindCounts: [MeasurementKind: Int],
        countSymbolNames: [String],
        customDefaultKeys: [String],
        embeddedImages: [ToolSetEmbeddedImageReview],
        findings: [ToolSetImportFinding],
        libraryMatches: [UUID: UUID] = [:]
    ) {
        self.fileName = fileName
        self.setName = setName
        self.declaredAuthor = declaredAuthor
        self.declaredExportDate = declaredExportDate
        self.schemaVersion = schemaVersion
        self.byteCount = byteCount
        self.declaredPresetCount = declaredPresetCount
        self.presets = presets
        self.markupKindCounts = markupKindCounts
        self.measurementKindCounts = measurementKindCounts
        self.countSymbolNames = countSymbolNames
        self.customDefaultKeys = customDefaultKeys
        self.embeddedImages = embeddedImages
        self.findings = findings
        self.libraryMatches = libraryMatches
    }

    /// The findings that stop the import.
    public var blockingFindings: [ToolSetImportFinding] {
        findings.filter { $0.severity == .blocking }
    }

    /// Identity of the review, derived from what it describes so it stays stable across
    /// redraws and so two reviews of the same file compare equal.
    public var id: String { "\(fileName)#\(byteCount)#\(declaredPresetCount)" }

    /// Whether the Import button may be enabled.
    public var isSafeToImport: Bool {
        blockingFindings.isEmpty && !presets.isEmpty
    }

    /// How many tools the file described that Zenit will not add.
    public var droppedPresetCount: Int {
        max(0, declaredPresetCount - presets.count)
    }

    /// A localized one-line summary of what would be added.
    public var summaryLine: String {
        let format = NSLocalizedString(
            "%1$@, %2$@, %3$@",
            comment: "Tool set import summary: '5 tools', '2 categories', '1 image'"
        )
        let categories = Set(presets.map(\.category)).count
        let acceptedImages = embeddedImages.filter(\.isAccepted).count
        return String(
            format: format,
            WorkflowPlurals.tools(presets.count),
            WorkflowPlurals.categories(categories),
            WorkflowPlurals.images(acceptedImages)
        )
    }

    /// The statement the sheet always shows, whatever the file contains.
    public static let dataOnlyStatement = NSLocalizedString(
        "A tool set is a description of tools, not a program. Zenit reads it as plain text and pictures, runs nothing from it, and follows no address inside it.",
        comment: "Standing statement on the tool set import review sheet"
    )
}
