import CQPDF
import Foundation

/// What a transformed copy of a document should be: flattened, compressed, sanitised,
/// encrypted — any combination (NL-PDF-08, NL-PDF-09).
public struct QPDFTransform: Hashable, Sendable {

    /// Who may print an encrypted copy.
    public enum Printing: Int32, Hashable, Sendable, CaseIterable {
        case none = 0
        case lowResolution = 1
        case full = 2
    }

    /// Password protection and permissions: AES-256 (revision 6).
    public struct Protection: Hashable, Sendable {
        /// Needed to open the file. Empty means anyone may open it and the permissions still bind.
        public var openPassword: String
        /// Needed to change the permissions. Must be non-empty and differ from ``openPassword``.
        public var permissionsPassword: String
        public var printing: Printing
        public var allowsChanges: Bool
        public var allowsCopying: Bool
        public var allowsAnnotating: Bool

        public init(
            openPassword: String = "",
            permissionsPassword: String,
            printing: Printing = .full,
            allowsChanges: Bool = false,
            allowsCopying: Bool = true,
            allowsAnnotating: Bool = true
        ) {
            self.openPassword = openPassword
            self.permissionsPassword = permissionsPassword
            self.printing = printing
            self.allowsChanges = allowsChanges
            self.allowsCopying = allowsCopying
            self.allowsAnnotating = allowsAnnotating
        }
    }

    /// Burn the document's own visible annotations and filled form fields into its pages.
    public var flattensAnnotations: Bool
    /// Object streams, recompressed Flate streams, unreferenced resources removed; without downsampling,
    /// image data is untouched. qpdf has no JPEG decoder; downsampling uses ImageIO to re-encode pictures.
    public var compresses: Bool
    /// Remove JavaScript, embedded files, open and additional actions, and metadata.
    public var sanitizes: Bool
    /// Encrypt the copy.
    public var protection: Protection?
    /// Write a linearized ("fast web view") file.
    public var linearizes: Bool
    /// Resample pictures painted above a target resolution (NL-PDF-08); `nil` leaves every
    /// picture byte for byte.
    public var downsampling: QPDFImageDownsampling?

    public init(
        flattensAnnotations: Bool = false,
        compresses: Bool = false,
        sanitizes: Bool = false,
        protection: Protection? = nil,
        linearizes: Bool = false,
        downsampling: QPDFImageDownsampling? = nil
    ) {
        self.flattensAnnotations = flattensAnnotations
        self.compresses = compresses
        self.sanitizes = sanitizes
        self.protection = protection
        self.linearizes = linearizes
        self.downsampling = downsampling
    }

    var operations: UInt32 {
        var value: UInt32 = 0
        if flattensAnnotations { value |= UInt32(ZPDFQPDF_OP_FLATTEN_ANNOTATIONS) }
        if compresses { value |= UInt32(ZPDFQPDF_OP_COMPRESS) }
        if sanitizes { value |= UInt32(ZPDFQPDF_OP_SANITIZE) }
        if protection != nil { value |= UInt32(ZPDFQPDF_OP_ENCRYPT) }
        if downsampling != nil { value |= UInt32(ZPDFQPDF_OP_DOWNSAMPLE_IMAGES) }
        return value
    }
}

/// What a transform did.
public struct QPDFTransformReport: Hashable, Sendable {
    public let flattenedAnnotationCount: Int
    public let removedJavaScript: Bool
    public let removedEmbeddedFiles: Bool
    public let removedActionCount: Int
    public let removedMetadata: Bool
    /// Pictures resampled to the target resolution.
    public let downsampledImageCount: Int
    /// Pictures painted above the target that were offered for resampling; the difference to
    /// ``downsampledImageCount`` is what ImageIO could not decode or would not shrink.
    public let offeredImageCount: Int
    public let inputByteCount: Int64
    public let outputByteCount: Int64
    public let report: QPDFReport
}

extension QPDF {

    /// Write a transformed copy of `input` to `output`. The input is never modified, and the
    /// output is written atomically, as for every operation here.
    ///
    /// Operations apply in the order flatten, sanitise, compress, encrypt. An encrypted input
    /// opened with `password` and transformed without ``QPDFTransform/protection`` is written
    /// decrypted — the person unlocked it and asked for a changed copy.
    @discardableResult
    public static func transform(
        input: URL,
        output: URL,
        password: String? = nil,
        transform: QPDFTransform,
        options: QPDFOptions = .default
    ) throws -> QPDFTransformReport {
        guard transform.operations != 0 else {
            throw QPDFError.invalidArgument("no operation was requested")
        }
        if let downsampling = transform.downsampling {
            guard downsampling.targetDPI.isFinite, (36...2400).contains(downsampling.targetDPI) else {
                throw QPDFError.invalidArgument("the picture resolution must be between 36 and 2400 dpi")
            }
        }
        if let protection = transform.protection {
            guard !protection.permissionsPassword.isEmpty else {
                throw QPDFError.invalidArgument("encryption needs a permissions password")
            }
            guard protection.permissionsPassword != protection.openPassword else {
                throw QPDFError.invalidArgument("the permissions password must differ from the open password")
            }
        }
        let inputSize = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        let buffer = UnsafeMutablePointer<zpdf_qpdf_report>.allocate(capacity: 1)
        buffer.initialize(to: zpdf_qpdf_report())
        defer {
            buffer.deinitialize(count: 1)
            buffer.deallocate()
        }
        var cOptions = try options.validatedCValue()
        var result = zpdf_qpdf_transform_result()
        let flags: UInt32 = transform.linearizes ? UInt32(ZPDFQPDF_WRITE_LINEARIZE) : 0
        let protection = transform.protection
        let imageBox = transform.downsampling.map { QPDFImageCallbackBox(settings: $0) }
        let imageContext = imageBox.map { Unmanaged.passUnretained($0).toOpaque() }
        let before = transform.downsampling == nil ? nil : QPDFVectorDigest.pageDigests(ofFileAt: input, password: password)
        let status: Int32 = input.path.withCString { inPath in
            output.path.withCString { outPath in
                (protection?.openPassword ?? "").withCString { user in
                    (protection?.permissionsPassword ?? "").withCString { owner in
                        var spec = zpdf_qpdf_transform(
                            operations: transform.operations,
                            allow_print: protection?.printing.rawValue ?? ZPDFQPDF_PRINT_FULL,
                            allow_modify: protection?.allowsChanges == true ? 1 : 0,
                            allow_extract: protection?.allowsCopying == true ? 1 : 0,
                            allow_annotate: protection?.allowsAnnotating == true ? 1 : 0,
                            user_password: user,
                            owner_password: owner,
                            image_target_dpi: transform.downsampling?.targetDPI ?? 0,
                            image_callback: transform.downsampling == nil ? nil : qpdfImageCallback,
                            image_context: imageContext
                        )
                        let call: (UnsafePointer<CChar>?) -> Int32 = { pw in
                            zpdf_qpdf_transform_copy(
                                inPath, pw, outPath, &spec, flags, &cOptions,
                                transformCancelCallback, nil, &result, buffer)
                        }
                        guard let password else { return call(nil) }
                        return password.withCString { call($0) }
                    }
                }
            }
        }
        let report = QPDFReport(
            message: String(cString: zpdf_qpdf_report_message(buffer)),
            warnings: String(cString: zpdf_qpdf_report_warnings(buffer))
                .split(separator: "\n").map(String.init),
            warningCount: Int(buffer.pointee.warning_count),
            warningsTruncated: buffer.pointee.warnings_truncated != 0
        )
        withExtendedLifetime(imageBox) {}
        if status != ZPDFQPDF_OK {
            throw QPDFError.make(status: status, message: report.message)
        }
        // The before/after gate: resampling pictures may change nothing else on any page.
        if transform.downsampling != nil {
            // Flattening annotations places each appearance as a new form: forms may be added
            // then, never changed or lost.
            let after = QPDFVectorDigest.pageDigests(ofFileAt: output, password: protection?.openPassword ?? password)
            guard let before, let after,
                  QPDFVectorDigest.matches(before: before, after: after, allowingAddedForms: transform.flattensAnnotations) else {
                try? FileManager.default.removeItem(at: output)
                throw QPDFError.invalidArgument(
                    "the copy's linework did not match the original's page for page, so it was not kept"
                )
            }
        }
        let outputSize = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        return QPDFTransformReport(
            flattenedAnnotationCount: Int(result.flattened_annotation_count),
            removedJavaScript: result.removed_javascript != 0,
            removedEmbeddedFiles: result.removed_embedded_files != 0,
            removedActionCount: Int(result.removed_actions),
            removedMetadata: result.removed_metadata != 0,
            downsampledImageCount: Int(result.downsampled_images),
            offeredImageCount: Int(result.offered_images),
            inputByteCount: inputSize,
            outputByteCount: outputSize,
            report: report
        )
    }
}

private let transformCancelCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
    Task.isCancelled ? 1 : 0
}
