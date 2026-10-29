import CQPDF
import Foundation

// MARK: - Errors

/// Every way a qpdf operation can fail. There is no untyped path: the C shim
/// catches every C++ exception and returns a status code, and every status code
/// maps to exactly one case here.
public enum QPDFError: Error, Equatable, Sendable {
    /// A path was empty, a count was not positive, or two flags contradicted.
    case invalidArgument(String)
    /// The requested output already exists, or resolves to one of the inputs.
    /// Every operation writes a new file; nothing is ever overwritten.
    case outputConflict(String)
    /// The input is missing, unreadable, or not a regular file.
    case cannotRead(String)
    /// The document is encrypted and no password was supplied.
    case passwordRequired(String)
    /// The document is encrypted and the supplied password was rejected.
    case passwordIncorrect(String)
    /// The document is damaged past the point qpdf can recover it.
    case damaged(String)
    /// The output could not be written or moved into place.
    case writeFailed(String)
    /// qpdf parsed the file but cannot do what was asked of it.
    case unsupported(String)
    /// The enclosing `Task` was cancelled. No output was written.
    case cancelled
    /// The input exceeded one of `QPDFOptions`' bounds.
    case limitExceeded(String)
    /// Allocation failed inside qpdf or inside the shim.
    case outOfMemory
    /// An unexpected C++ exception. A bug in qpdf or in the shim, reported
    /// rather than thrown.
    case internalFailure(String)
    /// A page index was out of range, or the same page was requested twice.
    case pageRangeInvalid(String)
    /// The C shim returned a status this Swift version does not know about.
    case unknownStatus(Int32, String)
    /// A split failed or was cancelled after `filesWritten` output files had already been
    /// moved into place. Every one of them was removed again, so normally nothing survives;
    /// `survivingFiles` names any that could not be removed. `underlying` is the failure
    /// itself — ``cancelled``, ``writeFailed(_:)``, ``damaged(_:)`` and so on. Thrown only by
    /// ``QPDF/split(input:outputDirectory:basename:pagesPerFile:password:writeOptions:options:)``
    /// and only once at least one file had been written; a split that fails before its first
    /// file throws the underlying error directly, exactly as every other operation does.
    indirect case splitIncomplete(underlying: QPDFError, filesWritten: Int, survivingFiles: [URL])

    static func make(status: Int32, message: String) -> QPDFError {
        switch status {
        case ZPDFQPDF_ERR_ARGUMENT: return .invalidArgument(message)
        case ZPDFQPDF_ERR_OUTPUT_CONFLICT: return .outputConflict(message)
        case ZPDFQPDF_ERR_CANNOT_READ: return .cannotRead(message)
        case ZPDFQPDF_ERR_PASSWORD_REQUIRED: return .passwordRequired(message)
        case ZPDFQPDF_ERR_PASSWORD_INCORRECT: return .passwordIncorrect(message)
        case ZPDFQPDF_ERR_DAMAGED: return .damaged(message)
        case ZPDFQPDF_ERR_WRITE: return .writeFailed(message)
        case ZPDFQPDF_ERR_UNSUPPORTED: return .unsupported(message)
        case ZPDFQPDF_ERR_CANCELLED: return .cancelled
        case ZPDFQPDF_ERR_LIMIT: return .limitExceeded(message)
        case ZPDFQPDF_ERR_OUT_OF_MEMORY: return .outOfMemory
        case ZPDFQPDF_ERR_INTERNAL: return .internalFailure(message)
        case ZPDFQPDF_ERR_PAGE_RANGE: return .pageRangeInvalid(message)
        default: return .unknownStatus(status, message)
        }
    }
}

// MARK: - Options

/// Bounds applied to untrusted input.
///
/// Every field has a defensive default. The parser limits are handed to qpdf's
/// process-global limit registry for the duration of one call, which is why the
/// C shim serialises all work on one mutex.
public struct QPDFOptions: Hashable, Sendable {
    /// Refuse inputs larger than this. Checked with `stat` before opening. Must be
    /// positive: every operation refuses a zero or negative bound with
    /// ``QPDFError/invalidArgument(_:)`` rather than quietly using the default (BH-411).
    public var maximumInputBytes: Int64
    /// Refuse documents with more pages than this. Must be positive, like every bound here.
    public var maximumPageCount: Int32
    /// Let qpdf reconstruct a broken cross-reference table. Turning this off
    /// makes `repair` useless, so it exists only for tests that want to observe
    /// the raw failure.
    public var attemptsRecovery: Bool
    /// Stop collecting warnings past this many: the report keeps counting in
    /// ``QPDFReport/warningCount`` and sets ``QPDFReport/warningsTruncated``. It never aborts
    /// the parse — qpdf's own abort limit stays at no less than the default 10 000
    /// (BH-410: lowering this used to make repair fail as `.damaged` on the 51st warning).
    public var maximumWarnings: UInt32
    /// qpdf parser error budget before it gives up on the document.
    public var maximumParserErrors: UInt32
    /// Nesting depth limit for arrays and dictionaries.
    public var maximumParserNesting: UInt32
    /// Element-count limit for one array or dictionary.
    public var maximumContainerSize: UInt32
    /// Filter-chain length limit for one stream.
    public var maximumStreamFilters: UInt32
    /// Byte ceiling for one inflate, and for the PNG, TIFF and run-length
    /// predictors. This is the decompression-bomb bound.
    public var maximumDecodedStreamBytes: UInt32
    /// Ignore cross-reference streams and reconstruct instead.
    public var ignoresCrossReferenceStreams: Bool

    public static let `default` = QPDFOptions()

    public init(
        maximumInputBytes: Int64 = 1 << 30,
        maximumPageCount: Int32 = 20000,
        attemptsRecovery: Bool = true,
        maximumWarnings: UInt32 = 10000,
        maximumParserErrors: UInt32 = 1000,
        maximumParserNesting: UInt32 = 200,
        maximumContainerSize: UInt32 = 5_000_000,
        maximumStreamFilters: UInt32 = 8,
        maximumDecodedStreamBytes: UInt32 = 512 * 1024 * 1024,
        ignoresCrossReferenceStreams: Bool = false
    ) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumPageCount = maximumPageCount
        self.attemptsRecovery = attemptsRecovery
        self.maximumWarnings = maximumWarnings
        self.maximumParserErrors = maximumParserErrors
        self.maximumParserNesting = maximumParserNesting
        self.maximumContainerSize = maximumContainerSize
        self.maximumStreamFilters = maximumStreamFilters
        self.maximumDecodedStreamBytes = maximumDecodedStreamBytes
        self.ignoresCrossReferenceStreams = ignoresCrossReferenceStreams
    }

    /// ``cValue`` after checking every bound. The C layer reads `<= 0` as "use the
    /// default", so a caller who computed 0 (or meant "refuse everything") silently got
    /// 20 000 pages / 1 GiB (BH-411). Refused here instead.
    func validatedCValue() throws -> zpdf_qpdf_options {
        guard maximumInputBytes > 0 else {
            throw QPDFError.invalidArgument("maximumInputBytes must be positive, not \(maximumInputBytes)")
        }
        guard maximumPageCount > 0 else {
            throw QPDFError.invalidArgument("maximumPageCount must be positive, not \(maximumPageCount)")
        }
        let unsigned: [(String, UInt32)] = [
            ("maximumWarnings", maximumWarnings),
            ("maximumParserErrors", maximumParserErrors),
            ("maximumParserNesting", maximumParserNesting),
            ("maximumContainerSize", maximumContainerSize),
            ("maximumStreamFilters", maximumStreamFilters),
            ("maximumDecodedStreamBytes", maximumDecodedStreamBytes),
        ]
        for (name, value) in unsigned where value == 0 {
            throw QPDFError.invalidArgument("\(name) must be positive, not 0")
        }
        return cValue
    }

    var cValue: zpdf_qpdf_options {
        zpdf_qpdf_options(
            max_input_bytes: maximumInputBytes,
            max_pages: maximumPageCount,
            attempt_recovery: attemptsRecovery ? 0 : -1,
            doc_max_warnings: maximumWarnings,
            parser_max_errors: maximumParserErrors,
            parser_max_nesting: maximumParserNesting,
            parser_max_container_size: maximumContainerSize,
            max_stream_filters: maximumStreamFilters,
            flate_max_memory: maximumDecodedStreamBytes,
            png_max_memory: maximumDecodedStreamBytes,
            tiff_max_memory: maximumDecodedStreamBytes,
            run_length_max_memory: maximumDecodedStreamBytes,
            ignore_xref_streams: ignoresCrossReferenceStreams ? 1 : 0
        )
    }
}

/// How the new file is written. The input is never touched whatever these say.
public struct QPDFWriteOptions: Hashable, Sendable {
    /// Produce a linearized ("fast web view") file.
    public var linearize: Bool
    /// Carry the input's encryption over to the output.
    public var preservesEncryption: Bool
    /// Derive `/ID` from the content instead of the clock, so two runs over the
    /// same input produce byte-identical output.
    public var deterministicID: Bool
    /// Write uncompressed, human-readable QDF output.
    public var qdf: Bool
    /// Write no object streams, so every object is directly visible.
    public var disablesObjectStreams: Bool

    public static let `default` = QPDFWriteOptions()

    /// ``default`` with the input's encryption carried over — what ``QPDF/repair(input:output:password:writeOptions:options:)``
    /// and ``QPDF/linearize(input:output:password:options:)`` use, so a structural rewrite
    /// never silently removes a password or `/P` restrictions (BH-407).
    public static let preservingEncryption = QPDFWriteOptions(preservesEncryption: true)

    /// Refuses combinations qpdf would reject late (as `.damaged`) or silently not honour
    /// (BH-409): deterministic IDs cannot be generated for an encrypted output, QDF output
    /// forces encryption off, and linearization discards QDF.
    func validate() throws {
        if deterministicID && preservesEncryption {
            throw QPDFError.invalidArgument(
                "deterministicID cannot be combined with preservesEncryption; qpdf cannot derive a deterministic /ID for an encrypted file")
        }
        if qdf && preservesEncryption {
            throw QPDFError.invalidArgument("qdf output cannot preserve encryption")
        }
        if qdf && linearize {
            throw QPDFError.invalidArgument("qdf and linearize are contradictory; linearization discards qdf")
        }
    }

    public init(
        linearize: Bool = false,
        preservesEncryption: Bool = false,
        deterministicID: Bool = false,
        qdf: Bool = false,
        disablesObjectStreams: Bool = false
    ) {
        self.linearize = linearize
        self.preservesEncryption = preservesEncryption
        self.deterministicID = deterministicID
        self.qdf = qdf
        self.disablesObjectStreams = disablesObjectStreams
    }

    var flags: UInt32 {
        var value: UInt32 = 0
        if linearize { value |= UInt32(ZPDFQPDF_WRITE_LINEARIZE) }
        if preservesEncryption { value |= UInt32(ZPDFQPDF_WRITE_PRESERVE_ENCRYPTION) }
        if deterministicID { value |= UInt32(ZPDFQPDF_WRITE_DETERMINISTIC_ID) }
        if qdf { value |= UInt32(ZPDFQPDF_WRITE_QDF) }
        if disablesObjectStreams { value |= UInt32(ZPDFQPDF_WRITE_OBJECT_STREAMS_OFF) }
        return value
    }
}

// MARK: - Report

/// What qpdf said while doing the work. A successful operation can still carry
/// warnings; on a damaged file it almost always does.
public struct QPDFReport: Hashable, Sendable {
    /// Free text from the shim about the operation as a whole. Usually empty.
    public let message: String
    /// The warnings that fit in the shim's fixed-size buffer.
    public let warnings: [String]
    /// The true number of warnings, which can exceed `warnings.count`.
    public let warningCount: Int
    /// `true` when warnings were dropped because the buffer filled.
    public let warningsTruncated: Bool
}

// MARK: - Inventory

/// The encryption state of a document.
public struct QPDFEncryption: Hashable, Sendable {
    /// Standard-security handler revision (`/R`).
    public let revision: Int32
    /// The raw permission bits (`/P`).
    public let permissions: Int32
    /// Length of the actual file key, in bits: 40, 128 or 256.
    public let keyBits: Int32
    /// The supplied password matched the user password.
    public let userPasswordMatched: Bool
    /// The supplied password matched the owner password.
    public let ownerPasswordMatched: Bool

    public let allowsAccessibility: Bool
    public let allowsExtractAll: Bool
    public let allowsPrintLowResolution: Bool
    public let allowsPrintHighResolution: Bool
    public let allowsModifyAssembly: Bool
    public let allowsModifyForm: Bool
    public let allowsModifyAnnotation: Bool
    public let allowsModifyOther: Bool
    public let allowsModifyAll: Bool
}

/// What is structurally wrong with a document.
public struct QPDFDamage: Hashable, Sendable {
    /// qpdf could not trust the cross-reference table and rebuilt it by
    /// scanning the file. This is the single strongest signal that a document
    /// needs repair.
    public let crossReferenceWasReconstructed: Bool
    /// Warnings qpdf classified as structural damage.
    public let damageWarningCount: Int
    /// Warnings about the page tree specifically.
    public let pageWarningCount: Int
    /// Streams whose declared filters failed to decode.
    public let undecodableStreamCount: Int
    /// Streams this build has no decoder for. Not damage: they are copied
    /// through byte for byte. `/DCTDecode` lands here, because this build has
    /// no libjpeg — see `VENDORED.md`.
    public let unfilterableStreamCount: Int

    /// `true` when anything suggests the file should be repaired before use.
    public var needsRepair: Bool {
        crossReferenceWasReconstructed || damageWarningCount > 0 || undecodableStreamCount > 0
    }
}

/// The structural inventory of one document.
public struct QPDFInventory: Hashable, Sendable {
    public let fileSize: Int64
    /// qpdf's approximate count of indirect objects.
    public let objectCount: Int64
    public let streamCount: Int64
    public let pageCount: Int64
    public let pdfVersion: String
    public let extensionLevel: Int32
    public let isLinearized: Bool
    /// Only meaningful when `isLinearized`.
    public let linearizationIsValid: Bool
    /// `nil` when the document is not encrypted.
    public let encryption: QPDFEncryption?
    public let damage: QPDFDamage
    public let report: QPDFReport

    public var isEncrypted: Bool { encryption != nil }
}
