import CoreGraphics
import CryptoKit
import Foundation

/// The complete takeoff, carried inside the PDF as an **associated file** (NL-PDF-03,
/// ADR-0023).
///
/// # What is written
///
/// An embedded-file stream holding the measurement overlay, a file specification that names it
/// with `/AFRelationship /Supplement`, and a superseding catalog whose `/AF` array and
/// `/Names /EmbeddedFiles` tree list it. The file specification also carries
/// ``StandardAnnotationWriter/takeoffKey``: the length and SHA-256 of the drawing the takeoff was
/// measured on. Because every Zenit write is an incremental update, that drawing is the file's
/// own prefix, byte for byte, and ``EmbeddedTakeoffReader`` proves it by hashing the prefix.
///
/// # Supersession
///
/// A second save replaces the entry — the name-tree slot and the `/AF` reference of any file
/// specification carrying the takeoff key — and never adds a second copy. Other embedded files
/// and associated files stay exactly as they were.
public struct EmbeddedTakeoff: Sendable, Hashable {
    /// The name in the embedded-files tree.
    public var fileName: String
    /// The bytes: a measurement overlay document.
    public var payload: Data
    public var mimeType: String
    /// Length of the drawing the takeoff was measured on — the file's prefix.
    public var sourceByteCount: Int
    /// SHA-256 of that drawing, lowercase hex.
    public var sourceSHA256: String

    public init(
        fileName: String = EmbeddedTakeoff.defaultFileName,
        payload: Data,
        mimeType: String = "application/json",
        sourceByteCount: Int,
        sourceSHA256: String
    ) {
        self.fileName = fileName
        self.payload = payload
        self.mimeType = mimeType
        self.sourceByteCount = sourceByteCount
        self.sourceSHA256 = sourceSHA256
    }

    public static let defaultFileName = "zenit-takeoff.zpdfoverlay"
}

extension StandardAnnotationWriter {

    /// The second-class key on the takeoff's file specification.
    public static let takeoffKey = "ZPDFTakeoff"

    /// Adds `takeoff` to the update: embedded file, file specification, and a superseding catalog.
    ///
    /// - Returns: `false` with the reason when the catalog's embedded-files tree is one this
    ///   writer does not rebuild (an intermediate-node tree); the annotations are still written.
    static func embed(
        _ takeoff: EmbeddedTakeoff,
        scan: PDFDocumentScan,
        allocate: () -> Int,
        update: inout PDFIncrementalUpdate
    ) throws -> (embedded: Bool, note: String?) {
        try embed([takeoff], scan: scan, allocate: allocate, update: &update)
    }

    /// Adds every file in `takeoffs` (the takeoff first, then its companions) in one catalog
    /// update. Each file specification carries ``takeoffKey``, so a later save supersedes all of
    /// them together.
    static func embed(
        _ takeoffs: [EmbeddedTakeoff],
        scan: PDFDocumentScan,
        allocate: () -> Int,
        update: inout PDFIncrementalUpdate
    ) throws -> (embedded: Bool, note: String?) {
        guard let root = scan.rootReference, let catalogNumber = root.referenceValue?.number,
              var catalog = scan.dictionary(root)
        else {
            throw ExportError.annotationExportRefused(
                "the drawing has no readable document catalog, so the takeoff cannot be attached to it."
            )
        }
        // An update to an object already superseded by this update must edit that version.
        if case let .dictionary(pending)? = update.objects[catalogNumber] { catalog = pending }

        var names: [String: PDFObject] = scan.dictionary(catalog["Names"]) ?? [:]
        var tree: [String: PDFObject] = scan.dictionary(names["EmbeddedFiles"]) ?? [:]
        if tree["Kids"] != nil {
            return (false, "the drawing's attachment list is a multi-level tree this writer does not rebuild, "
                + "so the takeoff was not embedded; the annotations were.")
        }

        var specs: [(name: [UInt8], reference: PDFObject)] = []
        for takeoff in takeoffs {
            specs.append((Array(takeoff.fileName.utf8), try embedOne(takeoff, allocate: allocate, update: &update)))
        }
        let ourNames = Set(specs.map(\.name))

        // The name tree: a flat /Names array, sorted by name, with this entry replaced.
        var pairs: [(key: [UInt8], value: PDFObject)] = []
        let existing = scan.object(tree["Names"])?.arrayValue ?? []
        var index = 0
        while index + 1 < existing.count {
            let key: [UInt8]
            switch scan.object(existing[index]) {
            case let .string(raw)?: key = raw
            case let .hexString(raw)?: key = raw
            default: key = []
            }
            let value = existing[index + 1]
            let isOurs = ourNames.contains(key)
                || scan.dictionary(value)?[takeoffKey] != nil
            if !isOurs { pairs.append((key, value)) }
            index += 2
        }
        pairs.append(contentsOf: specs.map { (key: $0.name, value: $0.reference) })
        pairs.sort { $0.key.lexicographicallyPrecedes($1.key) }
        tree = ["Names": .array(pairs.flatMap { [PDFObject.string($0.key), $0.value] })]
        names["EmbeddedFiles"] = .dictionary(tree)
        catalog["Names"] = .dictionary(names)

        // /AF: every associated file that is not an earlier takeoff, then this one.
        let associated = (scan.object(catalog["AF"])?.arrayValue ?? []).filter {
            scan.dictionary($0)?[takeoffKey] == nil
        }
        catalog["AF"] = .array(associated + specs.map(\.reference))
        update.objects[catalogNumber] = .dictionary(catalog)
        return (true, nil)
    }

    /// One embedded-file stream and its file specification; returns the specification.
    private static func embedOne(
        _ takeoff: EmbeddedTakeoff,
        allocate: () -> Int,
        update: inout PDFIncrementalUpdate
    ) throws -> PDFObject {
        let payload = takeoff.payload
        var streamDictionary: [String: PDFObject] = [
            "Type": .name("EmbeddedFile"),
            "Subtype": .name(takeoff.mimeType),
            "Params": .dictionary([
                "Size": .integer(payload.count),
                "CheckSum": .hexString(Array(Insecure.MD5.hash(data: payload)))
            ])
        ]
        var bytes = payload
        if let deflated = PDFStreamCodec.flateEncode(payload), deflated.count < payload.count {
            bytes = deflated
            streamDictionary["Filter"] = .name("FlateDecode")
        }
        let streamNumber = allocate()
        update.objects[streamNumber] = .stream(dictionary: streamDictionary, data: bytes)
        let stream = PDFObject.reference(number: streamNumber, generation: 0)

        let specNumber = allocate()
        let spec = PDFObject.reference(number: specNumber, generation: 0)
        update.objects[specNumber] = .dictionary([
            "Type": .name("Filespec"),
            "F": OptionalContentCatalog.textString(takeoff.fileName),
            "UF": OptionalContentCatalog.textString(takeoff.fileName),
            "Desc": OptionalContentCatalog.textString("Zenit PDF takeoff"),
            "EF": .dictionary(["F": stream, "UF": stream]),
            "AFRelationship": .name("Supplement"),
            takeoffKey: .dictionary([
                "Version": .integer(1),
                "SourceLength": .integer(takeoff.sourceByteCount),
                "SourceSHA256": .string(Array(takeoff.sourceSHA256.lowercased().utf8))
            ])
        ])

        return spec
    }
}

/// Finds and verifies a takeoff embedded by ``StandardAnnotationWriter``.
public enum EmbeddedTakeoffReader {

    /// What was found.
    public struct Found: Sendable, Hashable {
        public var takeoff: EmbeddedTakeoff
        /// Whether the file's first ``EmbeddedTakeoff/sourceByteCount`` bytes hash to
        /// ``EmbeddedTakeoff/sourceSHA256`` — the drawing under the takeoff is the one it was
        /// measured on, untouched.
        public var prefixVerified: Bool
    }

    /// The most Zenit entries one read considers, in `/AF` order. A save writes two — the
    /// overlay and the session archive — so eight leaves room and bounds the work an untrusted
    /// drawing can ask for on open (W-055).
    static let maximumEntries = 8
    /// The most decoded bytes one read holds across every entry it decodes: one stream's own
    /// ceiling, shared, so a drawing with many `/AF` entries cannot multiply it (W-055).
    static let maximumDecodedBytes = PDFStreamCodec.maximumDecodedBytes

    /// The takeoff in `data`, or `nil` when the file carries none (or cannot be scanned). Only
    /// the entry returned is decoded and hashed.
    public static func read(_ data: Data) -> Found? {
        entries(in: data, named: nil, stoppingAtFirst: true, decodedByteBudget: maximumDecodedBytes).first
    }

    /// The Zenit file named `fileName` among those embedded, or `nil`. Entries are told apart by
    /// name before anything is decoded, so only the one asked for is inflated and its prefix
    /// hashed (W-055: every entry used to be decoded and kept to answer for one).
    public static func read(_ data: Data, named fileName: String) -> Found? {
        entries(in: data, named: fileName, stoppingAtFirst: true, decodedByteBudget: maximumDecodedBytes).first
    }

    /// The Zenit files carried as associated files, in `/AF` order (the takeoff first): the
    /// reader both entry points share, with the decoded-byte budget named so a test can reach it
    /// without a 256 MB payload. With the defaults it answers every entry it may consider.
    ///
    /// A read by name runs on every open of a drawing, and almost no drawing carries one: the
    /// catalog's `/AF` is read lazily through Core Graphics first, and the file is scanned in full
    /// only when it names a Zenit file. Scanning first copied and parsed the whole drawing — every
    /// object, every object stream — on every open, to find nothing (R-109).
    ///
    /// Bounds, all W-055 (an untrusted drawing is read on open, off the main actor but in this
    /// process): only the first ``maximumEntries`` `/AF` entries carrying the Zenit key are
    /// considered; names and markers are read before any stream is decoded, so `named` and
    /// `stoppingAtFirst` decode only what they return; one stream named by several entries is
    /// decoded once; every decode — the PNG predictor's row padding included — is limited by
    /// what is left of `decodedByteBudget`, so the payloads held together never pass it; and a
    /// prefix is hashed only for an entry returned, once per distinct length.
    static func entries(
        in data: Data,
        named fileName: String? = nil,
        stoppingAtFirst: Bool = false,
        decodedByteBudget: Int = maximumDecodedBytes
    ) -> [Found] {
        if mayCarryTakeoff(data) == false { return [] }
        guard let scan = try? PDFDocumentScan(data: data),
              let catalog = scan.dictionary(scan.rootReference)
        else { return [] }
        var found: [Found] = []
        var remaining = decodedByteBudget
        // One decode per stream, one hash per distinct source length: the takeoff and the
        // session archive of one save name the same prefix.
        var decoded: [Int: Data] = [:]
        var digests: [Int: String] = [:]
        var considered = 0
        for candidate in scan.object(catalog["AF"])?.arrayValue ?? [] {
            guard considered < maximumEntries else { break }
            guard let spec = scan.dictionary(candidate),
                  let marker = scan.dictionary(spec[StandardAnnotationWriter.takeoffKey])
            else { continue }
            considered += 1
            guard let length = scan.object(marker["SourceLength"])?.integerValue,
                  let digest = StandardAnnotationWriter.text(scan.object(marker["SourceSHA256"])),
                  let files = scan.dictionary(spec["EF"])
            else { continue }
            let name = StandardAnnotationWriter.text(scan.object(spec["UF"] ?? spec["F"]))
                ?? EmbeddedTakeoff.defaultFileName
            if let fileName, name != fileName { continue }
            let streamReference = files["F"] ?? files["UF"]
            guard case let .stream(dictionary, raw)? = scan.object(streamReference) else { continue }
            let payload: Data
            if let number = streamReference?.referenceValue?.number, let earlier = decoded[number] {
                payload = earlier
            } else {
                guard let fresh = PDFStreamCodec.decode(dictionary: dictionary, data: raw, limit: remaining) else { continue }
                remaining -= fresh.count
                if let number = streamReference?.referenceValue?.number { decoded[number] = fresh }
                payload = fresh
            }
            let mime = scan.object(dictionary["Subtype"])?.nameValue ?? "application/json"
            var verified = false
            if length > 0, length <= data.count {
                let actual = digests[length] ?? SHA256.hash(data: data.prefix(length)).map { String(format: "%02x", $0) }.joined()
                digests[length] = actual
                verified = actual == digest.lowercased()
            }
            found.append(Found(
                takeoff: EmbeddedTakeoff(
                    fileName: name,
                    payload: payload,
                    mimeType: mime,
                    sourceByteCount: length,
                    sourceSHA256: digest.lowercased()
                ),
                prefixVerified: verified
            ))
            if stoppingAtFirst { break }
        }
        return found
    }

    /// Whether the latest catalog's `/AF` names a file carrying the Zenit takeoff key, read
    /// through Core Graphics, which parses only the cross-reference table and the objects asked
    /// for. `nil` when Core Graphics cannot open the file or it is locked — the full scan decides
    /// then, as before.
    static func mayCarryTakeoff(_ data: Data) -> Bool? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked, let catalog = document.catalog
        else { return nil }
        var files: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(catalog, "AF", &files), let files else { return false }
        for index in 0..<CGPDFArrayGetCount(files) {
            var spec: CGPDFDictionaryRef?
            var marker: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(files, index, &spec), let spec,
               CGPDFDictionaryGetDictionary(spec, StandardAnnotationWriter.takeoffKey, &marker) {
                return true
            }
        }
        return false
    }
}
