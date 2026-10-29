import CoreGraphics
import Foundation
#if canImport(Security) && os(macOS)
import Security
#endif

/// The digital signatures in a drawing, verified offline (NL-PDF-15).
///
/// For every signature field with a value: who signed (the certificate's subject), when (the
/// signing time the signature carries, or the field's `/M`), whether the signed byte ranges still
/// hash to what was signed, and whether anything was appended after them. Verification is the
/// Security framework's CMS decoder over the `/ByteRange` bytes, and certificate trust is
/// evaluated against the system's roots **with network fetching switched off** — no revocation
/// lookup, no timestamp server, nothing leaves the machine.
///
/// Nothing here writes, repairs or re-signs. It reads, and it reports.
public enum SignatureInspector {

    /// What one signature says about the file.
    public enum Integrity: String, Sendable, Hashable {
        /// The signed bytes are exactly what was signed, and the signature covers the whole file.
        case intact
        /// The signed bytes are intact; later revisions were appended after them (an annotation
        /// save, a second signature). The signed revision itself was not changed.
        case intactWithLaterRevisions
        /// The signed bytes no longer match the signature: the file was modified after signing.
        case modified
        /// The signature could not be decoded or checked.
        case unverifiable
    }

    public struct Signature: Sendable, Hashable {
        /// The field's name (`/T`).
        public let fieldName: String?
        /// The signer's certificate subject, or the dictionary's `/Name` when there is no
        /// readable certificate.
        public let signer: String?
        public let signingTime: Date?
        /// `/SubFilter`, e.g. `adbe.pkcs7.detached` or `ETSI.CAdES.detached`.
        public let subFilter: String?
        public let integrity: Integrity
        /// Whether the signer's certificate chains to a root this Mac trusts. `false` for a
        /// self-signed or organisation-internal certificate, which can still be `intact`.
        public let certificateTrusted: Bool
        /// Whether the byte ranges run to the end of the file.
        public let coversWholeFile: Bool
    }

    /// Every signature in the file at `url`. Empty for an unsigned file or one Core Graphics
    /// will not open.
    public static func signatures(ofFileAt url: URL) -> [Signature] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return signatures(in: data)
    }

    public static func signatures(in data: Data) -> [Signature] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog
        else { return [] }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return [] }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return [] }
        var out: [Signature] = []
        var budget = 10_000
        collect(fields, inheritedType: nil, depth: 0, budget: &budget, data: data, into: &out)
        return out
    }

    private static func collect(
        _ fields: CGPDFArrayRef,
        inheritedType: String?,
        depth: Int,
        budget: inout Int,
        data: Data,
        into out: inout [Signature]
    ) {
        guard depth < 32 else { return }
        for index in 0..<CGPDFArrayGetCount(fields) {
            guard budget > 0 else { return }
            budget -= 1
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field else { continue }
            var type = inheritedType
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(field, "FT", &name), let name { type = String(cString: name) }
            var value: CGPDFDictionaryRef?
            if type == "Sig", CGPDFDictionaryGetDictionary(field, "V", &value), let value {
                out.append(signature(value, fieldName: string(field, "T"), data: data))
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids {
                collect(kids, inheritedType: type, depth: depth + 1, budget: &budget, data: data, into: &out)
            }
        }
    }

    private static func signature(_ dictionary: CGPDFDictionaryRef, fieldName: String?, data: Data) -> Signature {
        var subFilterName: UnsafePointer<CChar>?
        let subFilter = CGPDFDictionaryGetName(dictionary, "SubFilter", &subFilterName)
            ? subFilterName.map { String(cString: $0) } : nil
        let declaredTime = string(dictionary, "M").flatMap(AnnotationMapping.pdfDate(from:))
        let declaredName = string(dictionary, "Name")

        func failed() -> Signature {
            Signature(fieldName: fieldName, signer: declaredName, signingTime: declaredTime, subFilter: subFilter,
                      integrity: .unverifiable, certificateTrusted: false, coversWholeFile: false)
        }

        // /ByteRange [0 length1 start2 length2]: exactly two ranges, the first from the start of
        // the file, the second after it, and between them only this signature's own `<hex>`
        // /Contents — the gap is the one unsigned stretch of the signed revision, and anything
        // else hidden there would read as "signed, intact" (R-110).
        var rangeArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "ByteRange", &rangeArray), let rangeArray,
              CGPDFArrayGetCount(rangeArray) == 4
        else { return failed() }
        var ranges: [(Int, Int)] = []
        for pair in stride(from: 0, to: 4, by: 2) {
            var start: CGPDFInteger = 0, length: CGPDFInteger = 0
            // Bounded without adding: a hostile start or length near Int.max overflowed
            // `start + length` and trapped, on every open of the file (R-100).
            guard CGPDFArrayGetInteger(rangeArray, pair, &start), CGPDFArrayGetInteger(rangeArray, pair + 1, &length),
                  start >= 0, length >= 0, start <= data.count, length <= data.count - start
            else { return failed() }
            ranges.append((start, length))
        }
        guard Self.gapIsOnlyContents(ranges, in: data) else { return failed() }
        var covered = Data()
        for (start, length) in ranges {
            covered.append(data[data.startIndex + start ..< data.startIndex + start + length])
        }
        let end = ranges.map { $0.0 + $0.1 }.max() ?? 0
        let coversWholeFile = end == data.count

        var contents: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, "Contents", &contents), let contents,
              let bytes = CGPDFStringGetBytePtr(contents)
        else { return failed() }
        let blob = Data(bytes: bytes, count: CGPDFStringGetLength(contents))

        #if canImport(Security) && os(macOS)
        guard let result = verify(cms: trimmedDER(blob), content: covered) else { return failed() }
        let integrity: Integrity = !result.valid ? .modified : (coversWholeFile ? .intact : .intactWithLaterRevisions)
        return Signature(
            fieldName: fieldName,
            signer: result.signer ?? declaredName,
            signingTime: result.signingTime ?? declaredTime,
            subFilter: subFilter,
            integrity: integrity,
            certificateTrusted: result.trusted,
            coversWholeFile: coversWholeFile
        )
        #else
        return failed()
        #endif
    }

    /// Whether two byte ranges are laid out as a signature's are: the first starting at byte 0,
    /// the second starting after the first ends, and the gap between them exactly one hex string
    /// — `<`, hex digits or white space, `>`. Both ranges are already bounded by the file.
    static func gapIsOnlyContents(_ ranges: [(Int, Int)], in data: Data) -> Bool {
        guard ranges.count == 2, ranges[0].0 == 0 else { return false }
        let gapStart = ranges[0].0 + ranges[0].1, gapEnd = ranges[1].0
        guard gapEnd - gapStart >= 2 else { return false }
        let base = data.startIndex
        guard data[base + gapStart] == UInt8(ascii: "<"), data[base + gapEnd - 1] == UInt8(ascii: ">") else { return false }
        for index in (gapStart + 1)..<(gapEnd - 1) {
            switch data[base + index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"), UInt8(ascii: "A")...UInt8(ascii: "F"),
                 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x00:
                continue
            default:
                return false
            }
        }
        return true
    }

    /// The DER object inside a `/Contents` placeholder: the placeholder is zero-padded to a fixed
    /// size, and the decoder wants exactly the encoded length the DER header states.
    static func trimmedDER(_ blob: Data) -> Data {
        let bytes = [UInt8](blob)
        guard bytes.count >= 2, bytes[0] == 0x30 else { return blob }
        var length = 0
        var header = 2
        if bytes[1] & 0x80 == 0 {
            length = Int(bytes[1])
        } else {
            let count = Int(bytes[1] & 0x7F)
            guard count > 0, count <= 4, bytes.count >= 2 + count else { return blob }
            for index in 0..<count { length = length << 8 | Int(bytes[2 + index]) }
            header = 2 + count
        }
        let total = header + length
        return total <= bytes.count ? Data(bytes[0..<total]) : blob
    }

    #if canImport(Security) && os(macOS)
    private struct Verification {
        var valid: Bool
        var signer: String?
        var signingTime: Date?
        var trusted: Bool
    }

    private static func verify(cms: Data, content: Data) -> Verification? {
        var decoderOut: CMSDecoder?
        guard CMSDecoderCreate(&decoderOut) == errSecSuccess, let decoder = decoderOut else { return nil }
        let updated = cms.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess,
              CMSDecoderSetDetachedContent(decoder, content as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else { return nil }
        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess, signerCount > 0 else { return nil }

        var status = CMSSignerStatus.unsigned
        var trustOut: SecTrust?
        var certificateStatus: OSStatus = 0
        let policy = SecPolicyCreateBasicX509()
        guard CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, &trustOut, &certificateStatus) == errSecSuccess
        else { return nil }

        var trusted = false
        if let trust = trustOut {
            // Local-first: no OCSP, no CRL, no AIA fetch. A certificate the Mac cannot judge
            // offline is reported as not trusted, never looked up.
            SecTrustSetNetworkFetchAllowed(trust, false)
            trusted = SecTrustEvaluateWithError(trust, nil)
        }
        var certificate: SecCertificate?
        var signer: String?
        if CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess, let certificate {
            signer = SecCertificateCopySubjectSummary(certificate) as String?
        }
        var time: CFAbsoluteTime = 0
        let signingTime = CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess
            ? Date(timeIntervalSinceReferenceDate: time) : nil
        return Verification(valid: status == .valid, signer: signer, signingTime: signingTime, trusted: trusted)
    }
    #endif

    private static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }
}
