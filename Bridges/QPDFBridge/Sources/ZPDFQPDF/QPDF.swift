import CQPDF
import Foundation

/// PDF repair and structural operations, backed by vendored qpdf.
///
/// Three properties hold for every function here, and the test suite asserts
/// each of them rather than assuming it:
///
/// - **The input is never modified.** Inputs are opened read-only, and the shim
///   refuses before parsing anything if the output path resolves to an input or
///   already exists. `QPDFInputImmutabilityTests` hashes every input before and
///   after every operation.
/// - **Output is atomic.** Work goes to a sibling `.zpdf-partial` file that is
///   renamed into place only on success, so a failure or a cancellation leaves
///   nothing behind.
/// - **Failure is typed.** The C shim catches every C++ exception; there is no
///   trap, no `fatalError`, and no path that returns a partially valid result.
///
/// Cancellation is cooperative and reads `Task.isCancelled`, so calling these
/// from inside a cancelled `Task` fails with ``QPDFError/cancelled``. They are
/// synchronous and blocking: run them off the main actor.
public enum QPDF: Sendable {

    // MARK: - Build facts

    /// The vendored qpdf version, e.g. `12.4.1`.
    public static var vendoredVersion: String {
        String(cString: zpdf_qpdf_version())
    }

    /// The compiled-in crypto provider. Always `native` in this build: the
    /// GnuTLS (LGPL) and OpenSSL providers are not vendored at all.
    public static var cryptoProvider: String {
        String(cString: zpdf_qpdf_crypto_provider())
    }

    /// Whether this build can decode `/DCTDecode` (JPEG) streams. `false`: no
    /// libjpeg is vendored, so DCT streams are copied through unmodified
    /// instead of being re-encoded. See `VENDORED.md`.
    public static var hasDCTSupport: Bool {
        zpdf_qpdf_has_dct_support() != 0
    }

    // MARK: - Inspection

    /// Parse `url` and report what is in it, without writing anything.
    ///
    /// Succeeds on a damaged file that qpdf could recover; the damage is in
    /// ``QPDFInventory/damage``. Fails only when the file cannot be read at
    /// all, needs a password that was not supplied, or is damaged past
    /// recovery.
    public static func inspect(
        _ url: URL,
        password: String? = nil,
        options: QPDFOptions = .default
    ) throws -> QPDFInventory {
        let report = ReportBuffer()
        defer { report.release() }
        var inventory = zpdf_qpdf_inventory()
        var cOptions = try options.validatedCValue()

        let status = withPath(url) { path in
            withOptionalPassword(password) { pw in
                zpdf_qpdf_inspect(
                    path, pw, &cOptions, cancelCallback, nil, &inventory, report.pointer)
            }
        }
        try report.throwIfFailed(status)
        return makeInventory(inventory, report: report.value)
    }

    // MARK: - Whole-document operations

    /// Rebuild `input` into a new file at `output`.
    ///
    /// This is the repair operation: qpdf parses with recovery — reconstructing
    /// the cross-reference table by scanning for objects when the table is
    /// wrong or missing — and then writes a structurally correct document.
    /// Repairing an already-valid file is a no-op in content: the result is a
    /// valid file with the same pages — and, by default, the same encryption and
    /// permissions (BH-407: the default used to write a plaintext, unrestricted copy).
    @discardableResult
    public static func repair(
        input: URL,
        output: URL,
        password: String? = nil,
        writeOptions: QPDFWriteOptions = .preservingEncryption,
        options: QPDFOptions = .default
    ) throws -> QPDFReport {
        try writeCopy(
            input: input,
            output: output,
            password: password,
            writeOptions: writeOptions,
            options: options)
    }

    /// Write a linearized ("fast web view") copy of `input` to `output`.
    @discardableResult
    public static func linearize(
        input: URL,
        output: URL,
        password: String? = nil,
        options: QPDFOptions = .default
    ) throws -> QPDFReport {
        // Keeps the input's encryption, like repair (BH-407).
        var write = QPDFWriteOptions.preservingEncryption
        write.linearize = true
        return try writeCopy(
            input: input, output: output, password: password, writeOptions: write, options: options)
    }

    /// Write a decrypted copy of `input` to `output`, using `password` to open
    /// it.
    ///
    /// The output carries no encryption and therefore no permission
    /// restrictions. Fails with ``QPDFError/passwordRequired(_:)`` when the
    /// document is encrypted and `password` is `nil` or empty, and with
    /// ``QPDFError/passwordIncorrect(_:)`` when it is wrong.
    @discardableResult
    public static func decrypt(
        input: URL,
        output: URL,
        password: String?,
        writeOptions: QPDFWriteOptions = .default,
        options: QPDFOptions = .default
    ) throws -> QPDFReport {
        var write = writeOptions
        write.preservesEncryption = false
        return try writeCopy(
            input: input, output: output, password: password, writeOptions: write, options: options)
    }

    // MARK: - Page operations

    /// Write a new document containing only `pageIndices`, in the order given.
    ///
    /// Indices are 0-based. A duplicate index is rejected rather than silently
    /// producing a document with fewer pages than requested.
    @discardableResult
    public static func extractPages(
        input: URL,
        output: URL,
        pageIndices: [Int],
        password: String? = nil,
        writeOptions: QPDFWriteOptions = .default,
        options: QPDFOptions = .default
    ) throws -> QPDFReport {
        guard !pageIndices.isEmpty else {
            throw QPDFError.invalidArgument("at least one page index is required")
        }
        try validateAssembly(writeOptions)
        let indices = try pageIndices.map { index -> Int32 in
            guard let value = Int32(exactly: index) else {
                throw QPDFError.pageRangeInvalid("page index \(index) is out of range")
            }
            return value
        }

        let report = ReportBuffer()
        defer { report.release() }
        var cOptions = try options.validatedCValue()

        let status = withPath(input) { inPath in
            withPath(output) { outPath in
                withOptionalPassword(password) { pw in
                    indices.withUnsafeBufferPointer { buffer in
                        zpdf_qpdf_extract_pages(
                            inPath,
                            pw,
                            outPath,
                            buffer.baseAddress,
                            Int32(buffer.count),
                            writeOptions.flags,
                            &cOptions,
                            cancelCallback,
                            nil,
                            report.pointer)
                    }
                }
            }
        }
        try report.throwIfFailed(status)
        return report.value
    }

    /// Split `input` into consecutive groups of `pagesPerFile` pages.
    ///
    /// Files are written as `<directory>/<basename>-0001.pdf`, `-0002.pdf` and
    /// so on. The input is parsed once. Every output path is checked before any
    /// file is written, so a collision on the last group cannot leave the
    /// earlier groups behind. A failure or a cancellation after some files have
    /// been moved into place removes them again and throws
    /// ``QPDFError/splitIncomplete(underlying:filesWritten:survivingFiles:)``,
    /// which says how far the split got and names anything that could not be
    /// removed. A failure before the first file throws the failure itself.
    ///
    /// - Returns: the files written, in order.
    @discardableResult
    public static func split(
        input: URL,
        outputDirectory: URL,
        basename: String,
        pagesPerFile: Int = 1,
        password: String? = nil,
        writeOptions: QPDFWriteOptions = .default,
        options: QPDFOptions = .default
    ) throws -> [URL] {
        guard pagesPerFile > 0, let perFile = Int32(exactly: pagesPerFile) else {
            throw QPDFError.invalidArgument("pagesPerFile must be positive")
        }
        try validateAssembly(writeOptions)
        guard !basename.isEmpty, !basename.contains("/") else {
            throw QPDFError.invalidArgument("basename must be non-empty and contain no '/'")
        }

        let report = ReportBuffer()
        defer { report.release() }
        var cOptions = try options.validatedCValue()
        var fileCount: Int32 = 0

        let status = withPath(input) { inPath in
            withPath(outputDirectory) { dirPath in
                withOptionalPassword(password) { pw in
                    basename.withCString { base in
                        zpdf_qpdf_split_pages(
                            inPath,
                            pw,
                            dirPath,
                            base,
                            perFile,
                            writeOptions.flags,
                            &cOptions,
                            cancelCallback,
                            nil,
                            &fileCount,
                            report.pointer)
                    }
                }
            }
        }
        guard status == ZPDFQPDF_OK else {
            let underlying = QPDFError.make(status: status, message: report.message)
            // On failure the shim reports how many files it had moved into place — and has
            // removed again. Nothing should survive; anything that does is named here so the
            // caller deals with it now rather than finding it later.
            let filesWritten = Int(max(fileCount, 0))
            guard filesWritten > 0 else { throw underlying }
            let survivingFiles = splitOutputURLs(
                outputDirectory: outputDirectory, basename: basename, count: filesWritten
            ).filter { FileManager.default.fileExists(atPath: $0.path) }
            throw QPDFError.splitIncomplete(
                underlying: underlying, filesWritten: filesWritten, survivingFiles: survivingFiles)
        }
        return try splitOutputURLs(
            outputDirectory: outputDirectory, basename: basename, fileCount: fileCount)
    }

    /// Write each group of `pageGroups` (0-based indices, in the order given) as its own new
    /// document, `<directory>/<basename>-0001.pdf`, `-0002.pdf` and so on, in group order.
    ///
    /// The input is parsed once, which is the point: Split into Sheets writes one file per
    /// sheet, and opening the drawing once per sheet cost 76 ms a sheet on a 2 MB, 300-sheet
    /// set — 22.7 s for the set, against 0.26 s parsed once (NL-DOCS-08, it1r). Each file keeps
    /// what ``extractPages(input:output:pageIndices:password:writeOptions:options:)`` keeps.
    /// Collisions, failures and cancellation behave as in ``split(input:outputDirectory:basename:pagesPerFile:password:writeOptions:options:)``.
    ///
    /// - Returns: the files written, one per group, in order.
    @discardableResult
    public static func extractPageGroups(
        input: URL,
        outputDirectory: URL,
        basename: String,
        pageGroups: [[Int]],
        password: String? = nil,
        writeOptions: QPDFWriteOptions = .default,
        options: QPDFOptions = .default
    ) throws -> [URL] {
        guard !pageGroups.isEmpty, pageGroups.allSatisfy({ !$0.isEmpty }),
              let groupCount = Int32(exactly: pageGroups.count) else {
            throw QPDFError.invalidArgument("at least one page group, each of at least one page, is required")
        }
        try validateAssembly(writeOptions)
        guard !basename.isEmpty, !basename.contains("/") else {
            throw QPDFError.invalidArgument("basename must be non-empty and contain no '/'")
        }
        let indices = try pageGroups.flatMap { $0 }.map { index -> Int32 in
            guard let value = Int32(exactly: index) else {
                throw QPDFError.pageRangeInvalid("page index \(index) is out of range")
            }
            return value
        }
        let sizes = try pageGroups.map { group -> Int32 in
            guard let value = Int32(exactly: group.count) else {
                throw QPDFError.invalidArgument("a page group is too large")
            }
            return value
        }

        let report = ReportBuffer()
        defer { report.release() }
        var cOptions = try options.validatedCValue()
        var fileCount: Int32 = 0

        let status = withPath(input) { inPath in
            withPath(outputDirectory) { dirPath in
                withOptionalPassword(password) { pw in
                    basename.withCString { base in
                        indices.withUnsafeBufferPointer { indexBuffer in
                            sizes.withUnsafeBufferPointer { sizeBuffer in
                                zpdf_qpdf_extract_page_groups(
                                    inPath,
                                    pw,
                                    dirPath,
                                    base,
                                    indexBuffer.baseAddress,
                                    sizeBuffer.baseAddress,
                                    groupCount,
                                    writeOptions.flags,
                                    &cOptions,
                                    cancelCallback,
                                    nil,
                                    &fileCount,
                                    report.pointer)
                            }
                        }
                    }
                }
            }
        }
        guard status == ZPDFQPDF_OK else {
            let underlying = QPDFError.make(status: status, message: report.message)
            let filesWritten = Int(max(fileCount, 0))
            guard filesWritten > 0 else { throw underlying }
            let survivingFiles = splitOutputURLs(
                outputDirectory: outputDirectory, basename: basename, count: filesWritten
            ).filter { FileManager.default.fileExists(atPath: $0.path) }
            throw QPDFError.splitIncomplete(
                underlying: underlying, filesWritten: filesWritten, survivingFiles: survivingFiles)
        }
        return try splitOutputURLs(
            outputDirectory: outputDirectory, basename: basename, fileCount: fileCount)
    }

    /// The paths a split into `fileCount` files produces, in order, once the shim's count has
    /// been checked. A negative count is a shim bug and is reported as one; it used to trap
    /// inside `prefix(_:)` instead (CR-143).
    static func splitOutputURLs(
        outputDirectory: URL,
        basename: String,
        fileCount: Int32
    ) throws -> [URL] {
        guard fileCount >= 0 else {
            throw QPDFError.internalFailure(
                "the shim reported \(fileCount) split output files; the count cannot be negative")
        }
        return splitOutputURLs(
            outputDirectory: outputDirectory, basename: basename, count: Int(fileCount))
    }

    private static func splitOutputURLs(
        outputDirectory: URL,
        basename: String,
        count: Int
    ) -> [URL] {
        (0..<count).map { index in
            outputDirectory.appendingPathComponent(
                String(format: "%@-%04d.pdf", basename, index + 1))
        }
    }

    /// One document to merge, with the password needed to open it.
    public struct Source: Hashable, Sendable {
        public let url: URL
        public let password: String?

        public init(_ url: URL, password: String? = nil) {
            self.url = url
            self.password = password
        }
    }

    /// Concatenate `sources` into a new document at `output`, in order.
    @discardableResult
    public static func merge(
        sources: [Source],
        output: URL,
        writeOptions: QPDFWriteOptions = .default,
        options: QPDFOptions = .default
    ) throws -> QPDFReport {
        guard !sources.isEmpty else {
            throw QPDFError.invalidArgument("at least one input is required")
        }
        try validateAssembly(writeOptions)

        let report = ReportBuffer()
        defer { report.release() }
        var cOptions = try options.validatedCValue()

        // Materialise the C string arrays by hand; nesting `withCString` once
        // per source would need recursion and would be far harder to audit.
        let pathBuffers = sources.map { Array($0.url.path.utf8CString) }
        let passwordBuffers = sources.map { source -> [CChar]? in
            source.password.map { Array($0.utf8CString) }
        }
        var pathPointers: [UnsafeMutablePointer<CChar>] = []
        var passwordPointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in pathPointers { pointer.deallocate() }
            for pointer in passwordPointers { pointer?.deallocate() }
        }
        for buffer in pathBuffers {
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: buffer.count)
            pointer.update(from: buffer, count: buffer.count)
            pathPointers.append(pointer)
        }
        for buffer in passwordBuffers {
            guard let buffer else {
                passwordPointers.append(nil)
                continue
            }
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: buffer.count)
            pointer.update(from: buffer, count: buffer.count)
            passwordPointers.append(pointer)
        }

        let inputs: [UnsafePointer<CChar>?] = pathPointers.map { UnsafePointer($0) }
        let passwords: [UnsafePointer<CChar>?] = passwordPointers.map { pointer in
            pointer.map { UnsafePointer($0) }
        }

        let status = withPath(output) { outPath in
            inputs.withUnsafeBufferPointer { inputBuffer in
                passwords.withUnsafeBufferPointer { passwordBuffer in
                    zpdf_qpdf_merge(
                        inputBuffer.baseAddress,
                        passwordBuffer.baseAddress,
                        Int32(inputBuffer.count),
                        outPath,
                        writeOptions.flags,
                        &cOptions,
                        cancelCallback,
                        nil,
                        report.pointer)
                }
            }
        }
        try report.throwIfFailed(status)
        return report.value
    }

    // MARK: - Shared plumbing

    /// Page-assembly operations build a *new* document from copied pages, so there is no
    /// encryption to carry over: `preservesEncryption` used to be accepted and silently
    /// produce a plaintext file (BH-408).
    private static func validateAssembly(_ writeOptions: QPDFWriteOptions) throws {
        try writeOptions.validate()
        if writeOptions.preservesEncryption {
            throw QPDFError.invalidArgument(
                "preservesEncryption cannot be honoured: pages are assembled into a new, unencrypted document")
        }
    }

    @discardableResult
    private static func writeCopy(
        input: URL,
        output: URL,
        password: String?,
        writeOptions: QPDFWriteOptions,
        options: QPDFOptions
    ) throws -> QPDFReport {
        try writeOptions.validate()
        let report = ReportBuffer()
        defer { report.release() }
        var cOptions = try options.validatedCValue()

        let status = withPath(input) { inPath in
            withPath(output) { outPath in
                withOptionalPassword(password) { pw in
                    zpdf_qpdf_write_copy(
                        inPath,
                        pw,
                        outPath,
                        writeOptions.flags,
                        &cOptions,
                        cancelCallback,
                        nil,
                        report.pointer)
                }
            }
        }
        try report.throwIfFailed(status)
        return report.value
    }
}

// MARK: - C boundary helpers

/// Cooperative cancellation. `Task.isCancelled` is readable from synchronous
/// code running inside a task, so no shared mutable state crosses the boundary
/// and nothing here needs `@unchecked Sendable`. Outside a task it is `false`.
private let cancelCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
    Task.isCancelled ? 1 : 0
}

/// The report struct is ~9 KB of fixed-size buffers. It is heap-allocated so it
/// never lands on the stack and so the C side can write into it directly.
private final class ReportBuffer {
    let pointer: UnsafeMutablePointer<zpdf_qpdf_report>

    init() {
        pointer = UnsafeMutablePointer<zpdf_qpdf_report>.allocate(capacity: 1)
        pointer.initialize(to: zpdf_qpdf_report())
    }

    func release() {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    var message: String {
        String(cString: zpdf_qpdf_report_message(pointer))
    }

    var warningLines: [String] {
        let joined = String(cString: zpdf_qpdf_report_warnings(pointer))
        return joined.isEmpty ? [] : joined.components(separatedBy: "\n")
    }

    var value: QPDFReport {
        QPDFReport(
            message: message,
            warnings: warningLines,
            warningCount: Int(pointer.pointee.warning_count),
            warningsTruncated: pointer.pointee.warnings_truncated != 0)
    }

    func throwIfFailed(_ status: Int32) throws {
        guard status != ZPDFQPDF_OK else { return }
        throw QPDFError.make(status: status, message: message)
    }
}

private func withPath<T>(_ url: URL, _ body: (UnsafePointer<CChar>) -> T) -> T {
    url.path.withCString(body)
}

private func withOptionalPassword<T>(
    _ password: String?,
    _ body: (UnsafePointer<CChar>?) -> T
) -> T {
    guard let password else { return body(nil) }
    return password.withCString { body($0) }
}

private func makeInventory(
    _ raw: zpdf_qpdf_inventory,
    report: QPDFReport
) -> QPDFInventory {
    let encryption: QPDFEncryption? = raw.is_encrypted != 0
        ? QPDFEncryption(
            revision: raw.encryption_revision,
            permissions: raw.encryption_permissions,
            keyBits: raw.encryption_key_bits,
            userPasswordMatched: raw.user_password_matched != 0,
            ownerPasswordMatched: raw.owner_password_matched != 0,
            allowsAccessibility: raw.allow_accessibility != 0,
            allowsExtractAll: raw.allow_extract_all != 0,
            allowsPrintLowResolution: raw.allow_print_low_res != 0,
            allowsPrintHighResolution: raw.allow_print_high_res != 0,
            allowsModifyAssembly: raw.allow_modify_assembly != 0,
            allowsModifyForm: raw.allow_modify_form != 0,
            allowsModifyAnnotation: raw.allow_modify_annotation != 0,
            allowsModifyOther: raw.allow_modify_other != 0,
            allowsModifyAll: raw.allow_modify_all != 0)
        : nil

    return QPDFInventory(
        fileSize: raw.file_size,
        objectCount: raw.object_count,
        streamCount: raw.stream_count,
        pageCount: raw.page_count,
        pdfVersion: "\(raw.pdf_version_major).\(raw.pdf_version_minor)",
        extensionLevel: raw.extension_level,
        isLinearized: raw.is_linearized != 0,
        linearizationIsValid: raw.linearization_is_valid != 0,
        encryption: encryption,
        damage: QPDFDamage(
            crossReferenceWasReconstructed: raw.xref_was_reconstructed != 0,
            damageWarningCount: Int(raw.damage_warning_count),
            pageWarningCount: Int(raw.page_warning_count),
            undecodableStreamCount: Int(raw.undecodable_stream_count),
            unfilterableStreamCount: Int(raw.unfilterable_stream_count)),
        report: report)
}
