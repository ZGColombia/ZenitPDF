import CryptoKit
import Foundation

/// A detached CAdES `SignedData` for the PAdES baseline B-B profile (NL-PDF-16, ADR-0028 §2).
///
/// The Security framework's `CMSEncoder` builds `adbe.pkcs7.detached` signatures but cannot add
/// the **signing-certificate-v2** signed attribute (RFC 5035) that the PAdES baseline requires,
/// and always adds signing-time, which PAdES forbids (the signing time is the signature
/// dictionary's `/M`). So this assembles the DER by hand: content-type, message-digest and
/// signing-certificate-v2 as signed attributes, SHA-256 throughout, the signer's certificate
/// included. The one private-key operation is the caller's `sign` closure — the app passes
/// `SecKeyCreateSignature` with the keychain identity's key; a test passes a key it made — so
/// this type holds no key and no keychain access.
public enum CAdESSignedData {

    /// The key family of the signer, which fixes the signature algorithm identifier.
    public enum KeyKind: Sendable, Hashable {
        /// RSA with PKCS #1 v1.5 padding over SHA-256.
        case rsa
        /// ECDSA over SHA-256, the signature DER-encoded (X9.62).
        case ecdsa
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadableCertificate
        public var description: String { "the signing certificate could not be read" }
    }

    /// Builds the `ContentInfo` holding the `SignedData` over `content`.
    ///
    /// - Parameters:
    ///   - certificate: the signer's certificate, DER.
    ///   - chain: further certificates to include (issuers), DER.
    ///   - sign: signs the DER of the signed attributes (a `SET`) with the signer's private key
    ///     and returns the raw signature (PKCS #1 for RSA, X9.62 DER for ECDSA).
    public static func build(
        content: Data,
        certificate: Data,
        chain: [Data] = [],
        keyKind: KeyKind,
        sign: (Data) throws -> Data
    ) throws -> Data {
        guard let (issuer, serial) = issuerAndSerial(of: certificate) else { throw Failure.unreadableCertificate }
        let sha256 = DER.sequence([DER.oid("2.16.840.1.101.3.4.2.1")])  // absent parameters
        let contentDigest = Data(SHA256.hash(data: content))
        let certificateDigest = Data(SHA256.hash(data: certificate))

        let attributes = [
            attribute("1.2.840.113549.1.9.3", DER.oid("1.2.840.113549.1.7.1")),          // content-type: data
            attribute("1.2.840.113549.1.9.4", DER.octetString(contentDigest)),           // message-digest
            // signing-certificate-v2: one ESSCertIDv2 whose hash algorithm is the default
            // SHA-256, so it is omitted (RFC 5035 §3).
            attribute("1.2.840.113549.1.9.16.2.47", DER.sequence([DER.sequence([DER.sequence([DER.octetString(certificateDigest)])])]))
        ]
        let signedSet = DER.set(attributes)                 // what is signed: tag 0x31
        let signature = try sign(signedSet)
        var signedImplicit = signedSet
        signedImplicit[signedImplicit.startIndex] = 0xA0    // stored as [0] IMPLICIT

        let signatureAlgorithm: Data = switch keyKind {
        case .rsa: DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null])
        case .ecdsa: DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
        }
        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([issuer, serial]),
            sha256,
            signedImplicit,
            signatureAlgorithm,
            DER.octetString(signature)
        ])
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([sha256]),
            DER.sequence([DER.oid("1.2.840.113549.1.7.1")]),          // detached: no eContent
            DER.tagged(0xA0, ([certificate] + chain).reduce(Data(), +)),
            DER.set([signerInfo])
        ])
        return DER.sequence([DER.oid("1.2.840.113549.1.7.2"), DER.tagged(0xA0, signedData)])
    }

    static func attribute(_ oid: String, _ value: Data) -> Data {
        DER.sequence([DER.oid(oid), DER.set([value])])
    }

    /// The certificate's issuer `Name` and serial `INTEGER`, each as its complete DER element.
    static func issuerAndSerial(of certificate: Data) -> (Data, Data)? {
        let bytes = [UInt8](certificate)
        guard let certificateElement = DER.element(bytes, at: 0), certificateElement.tag == 0x30,
              let tbs = DER.element(bytes, at: certificateElement.contentStart), tbs.tag == 0x30 else { return nil }
        var cursor = tbs.contentStart
        guard var next = DER.element(bytes, at: cursor) else { return nil }
        if next.tag == 0xA0 {                                   // [0] EXPLICIT version
            cursor = next.end
            guard let after = DER.element(bytes, at: cursor) else { return nil }
            next = after
        }
        guard next.tag == 0x02 else { return nil }              // serialNumber
        let serial = Data(bytes[next.start..<next.end])
        guard let algorithm = DER.element(bytes, at: next.end),  // signature AlgorithmIdentifier
              let issuer = DER.element(bytes, at: algorithm.end), issuer.tag == 0x30 else { return nil }
        return (Data(bytes[issuer.start..<issuer.end]), serial)
    }
}

/// The few DER encodings a CMS signature needs.
enum DER {
    static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        var value = count
        var digits: [UInt8] = []
        while value > 0 { digits.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(digits.count)] + digits)
    }

    static func tagged(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func sequence(_ items: [Data]) -> Data { tagged(0x30, items.reduce(Data(), +)) }
    /// A `SET OF`, its elements sorted by their encodings as DER requires.
    static func set(_ items: [Data]) -> Data {
        tagged(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +))
    }
    static func octetString(_ data: Data) -> Data { tagged(0x04, data) }
    static let null = Data([0x05, 0x00])

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, Data(bytes))
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return tagged(0x06, Data()) }
        var body: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7F)]
            var value = part >> 7
            while value > 0 { chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0); value >>= 7 }
            body += chunk
        }
        return tagged(0x06, Data(body))
    }

    struct Element {
        var tag: UInt8
        var start: Int
        var contentStart: Int
        var end: Int
    }

    /// The element starting at `index`, or `nil` when the bytes do not hold one.
    static func element(_ bytes: [UInt8], at index: Int) -> Element? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        var cursor = index + 1
        var count = Int(bytes[cursor])
        cursor += 1
        if count & 0x80 != 0 {
            let digits = count & 0x7F
            guard digits > 0, digits <= 4, cursor + digits <= bytes.count else { return nil }
            count = 0
            for offset in 0..<digits { count = (count << 8) | Int(bytes[cursor + offset]) }
            cursor += digits
        }
        guard cursor + count <= bytes.count else { return nil }
        return Element(tag: tag, start: index, contentStart: cursor, end: cursor + count)
    }
}
