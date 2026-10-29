import CoreGraphics
import CQPDF
import CryptoKit
import Foundation
import ImageIO

/// Pictures above a target resolution, resampled (NL-PDF-08).
///
/// qpdf finds each picture and the lowest resolution it is painted at on any page (following
/// `q`/`Q`/`cm` through the page content and nested forms); this side decodes it with ImageIO or
/// from its decoded samples, resamples it with Core Graphics, and hands it back: a JPEG picture
/// stays JPEG (re-encoded at ``jpegQuality``), a Flate picture stays lossless samples that the
/// writer compresses with Flate. qpdf in this build has no JPEG codec, and needs none: ImageIO
/// does the decoding and the encoding.
///
/// Only 8-bit grey or RGB pictures without masks or decode arrays are ever offered; JBIG2, CCITT,
/// JPX, image masks, inline images and colour-keyed pictures are left byte for byte. Vector
/// content is never touched, and ``QPDFVectorDigest`` proves it for every copy.
public struct QPDFImageDownsampling: Hashable, Sendable {
    /// Pictures painted above 1.25 × this resolution are resampled to it.
    public var targetDPI: Double
    /// JPEG quality for re-encoded JPEG pictures, 0…1.
    public var jpegQuality: Double

    public init(targetDPI: Double = 150, jpegQuality: Double = 0.8) {
        self.targetDPI = targetDPI
        self.jpegQuality = jpegQuality
    }
}

/// The resampling itself, separate from qpdf so it can be tested on its own. `package`, not
/// `internal`: the release gate builds this package's tests without `@testable`.
package enum QPDFImageResampler {

    package struct Output: Equatable {
        package var data: Data
        package var width: Int
        package var height: Int
        package var isJPEG: Bool
    }

    /// Resamples one offered picture to `targetDPI`, or `nil` to leave it.
    package static func resample(
        width: Int,
        height: Int,
        components: Int,
        isJPEG: Bool,
        effectiveDPI: Double,
        bytes: UnsafeRawBufferPointer,
        settings: QPDFImageDownsampling
    ) -> Output? {
        guard effectiveDPI.isFinite, effectiveDPI > settings.targetDPI, width > 1, height > 1,
              components == 1 || components == 3 else { return nil }
        let factor = settings.targetDPI / effectiveDPI
        let newWidth = max(1, Int((Double(width) * factor).rounded()))
        let newHeight = max(1, Int((Double(height) * factor).rounded()))
        guard newWidth < width, newHeight < height else { return nil }

        let source: CGImage
        if isJPEG {
            guard let data = CFDataCreate(nil, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count),
                  let reader = CGImageSourceCreateWithData(data, nil),
                  let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == width, image.height == height
            else { return nil }
            source = image
        } else {
            // The sample count is computed with overflow reported: /Width and /Height come from
            // the file, and 2147483647² × 3 used to overflow `Int` and trap the repair worker
            // (U-052). A count that does not fit is a picture this side cannot hold: left as it is.
            let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: components)
            let (sampleBytes, overflow) = rowBytes.multipliedReportingOverflow(by: height)
            guard !rowOverflow, !overflow, bytes.count == sampleBytes,
                  let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                      bytesPerRow: width * components,
                      space: components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  )
            else { return nil }
            source = image
        }

        // The drawing space: the picture's own, so resampling converts no colour. A JPEG whose
        // space is neither grey nor RGB (CMYK, Lab) is left alone.
        let gray = components == 1
        let space: CGColorSpace
        if isJPEG, let own = source.colorSpace, own.model == (gray ? .monochrome : .rgb) {
            space = own
        } else if isJPEG {
            return nil
        } else {
            space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        }
        let bytesPerPixel = gray ? 1 : 4
        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8,
            bytesPerRow: newWidth * bytesPerPixel, space: space,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        if isJPEG {
            guard let resampled = context.makeImage() else { return nil }
            let out = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(writer, resampled, [
                kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, settings.jpegQuality))
            ] as CFDictionary)
            guard CGImageDestinationFinalize(writer), out.length > 0 else { return nil }
            return Output(data: out as Data, width: newWidth, height: newHeight, isJPEG: true)
        }
        guard let raw = context.data else { return nil }
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        var samples = Data(count: newWidth * newHeight * components)
        samples.withUnsafeMutableBytes { target in
            let out = target.bindMemory(to: UInt8.self)
            if gray {
                for row in 0..<newHeight {
                    for column in 0..<newWidth { out[row * newWidth + column] = pixels[row * newWidth + column] }
                }
            } else {
                for index in 0..<(newWidth * newHeight) {
                    out[index * 3] = pixels[index * 4]
                    out[index * 3 + 1] = pixels[index * 4 + 1]
                    out[index * 3 + 2] = pixels[index * 4 + 2]
                }
            }
        }
        return Output(data: samples, width: newWidth, height: newHeight, isJPEG: false)
    }
}

/// The C callback: one box per call of the transform, reached through `image_context`.
final class QPDFImageCallbackBox {
    let settings: QPDFImageDownsampling
    init(settings: QPDFImageDownsampling) { self.settings = settings }
}

let qpdfImageCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<zpdf_qpdf_image>?, UnsafeMutablePointer<zpdf_qpdf_image_replacement>?
) -> Int32 = { context, image, out in
    guard let context, let image, let out, let data = image.pointee.data else { return 0 }
    let box = Unmanaged<QPDFImageCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let offered = image.pointee
    guard let result = QPDFImageResampler.resample(
        width: Int(offered.width),
        height: Int(offered.height),
        components: Int(offered.components),
        isJPEG: offered.encoding == ZPDFQPDF_IMAGE_DCT,
        effectiveDPI: offered.effective_dpi,
        bytes: UnsafeRawBufferPointer(start: data, count: offered.length),
        settings: box.settings
    ), !result.data.isEmpty, let buffer = malloc(result.data.count) else { return 0 }
    result.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: result.data.count)
    out.pointee = zpdf_qpdf_image_replacement(
        width: Int32(result.width),
        height: Int32(result.height),
        encoding: result.isJPEG ? ZPDFQPDF_IMAGE_DCT : ZPDFQPDF_IMAGE_SAMPLES,
        reserved: 0,
        data: buffer.assumingMemoryBound(to: UInt8.self),
        length: result.data.count
    )
    return 1
}

/// A per-page fingerprint of everything that is *not* a picture: page boxes, rotation, and every
/// path-construction and painting operator with its operands, in order, read with Core Graphics —
/// on the page and inside every form XObject it draws, recursively (R-118).
///
/// The before/after gate of Reduce File Size (NL-PDF-08): a copy whose fingerprint differs from
/// its source's on any page is refused. Text and pictures are not in it — a picture is exactly
/// what the operation is allowed to change — and neither are `q`/`Q`/`cm`, which a flatten wraps
/// around the unchanged content.
///
/// # Forms
///
/// A CAD drawing often wraps its whole linework in a form XObject; the page's own stream then
/// holds nothing but `q … cm /Fm0 Do Q`, and a digest of the page stream alone compared nothing.
/// Each form a page draws is digested on its own — its `/Matrix`, its `/BBox` and its operators,
/// a form it draws in turn folded into its digest — and the page carries the multiset of those
/// digests beside the digest of its own stream. Flattening annotations places each appearance as
/// a new form, so a copy that also flattens may add forms (``matches(before:after:allowingAddedForms:)``);
/// every form of the source must still be there, unchanged.
public enum QPDFVectorDigest {

    /// One page's fingerprint: its own stream, and the forms it draws.
    public struct PageDigest: Sendable, Hashable {
        /// The boxes, the rotation and the page stream's path operators.
        public var content: String
        /// Each form drawn from the page stream, by digest, with how often it is drawn.
        public var forms: [String: Int]

        /// Both halves as one string.
        public var combined: String {
            ([content] + forms.keys.sorted().map { "\($0)x\(forms[$0] ?? 0)" }).joined(separator: "|")
        }
    }

    /// One hex digest per page (forms included), or `nil` when the file cannot be read by Core
    /// Graphics.
    public static func pages(ofFileAt url: URL, password: String? = nil) -> [String]? {
        pageDigests(ofFileAt: url, password: password)?.map(\.combined)
    }

    /// One ``PageDigest`` per page, or `nil` when the file cannot be read by Core Graphics.
    public static func pageDigests(ofFileAt url: URL, password: String? = nil) -> [PageDigest]? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        if document.isEncrypted, !document.isUnlocked {
            guard let password, document.unlockWithPassword(password) else { return nil }
        }
        guard document.numberOfPages > 0 else { return [] }
        var digests: [PageDigest] = []
        let table = Collector.table()
        defer { CGPDFOperatorTableRelease(table) }
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { digests.append(PageDigest(content: "", forms: [:])); continue }
            let collector = Collector(table: table, depth: 0, cache: FormCache())
            let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
            collector.append("box \(media.minX) \(media.minY) \(media.width) \(media.height) \(crop.minX) \(crop.minY) \(crop.width) \(crop.height) rot \(page.rotationAngle)")
            let stream = CGPDFContentStreamCreateWithPage(page)
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(collector).toOpaque())
            _ = CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
            digests.append(PageDigest(content: collector.digest(), forms: collector.forms))
        }
        return digests
    }

    /// Whether `after` keeps every page of `before`: the same page streams and every form of the
    /// source, unchanged; with `allowingAddedForms` (the copy also flattens annotations), forms the
    /// source did not draw may be added.
    public static func matches(before: [PageDigest], after: [PageDigest], allowingAddedForms: Bool) -> Bool {
        guard before.count == after.count else { return false }
        for (old, new) in zip(before, after) {
            guard old.content == new.content else { return false }
            if allowingAddedForms {
                guard old.forms.allSatisfy({ new.forms[$0.key, default: 0] >= $0.value }) else { return false }
            } else {
                guard old.forms == new.forms else { return false }
            }
        }
        return true
    }

    /// Form digests already computed in one page, by stream: a drawing that places one form a
    /// thousand times scans it once.
    final class FormCache {
        var digests: [UnsafeRawPointer: String] = [:]
    }

    final class Collector {
        var hasher = SHA256()
        var count = 0
        /// Forms drawn from this stream (page level only; a form folds its forms into its hash).
        var forms: [String: Int] = [:]
        let table: CGPDFOperatorTableRef
        let depth: Int
        let cache: FormCache

        init(table: CGPDFOperatorTableRef, depth: Int, cache: FormCache) {
            self.table = table
            self.depth = depth
            self.cache = cache
        }

        func append(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0x0A]))
            count += 1
        }

        func digest() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined() + "/\(count)"
        }

        static let operators: [(String, Int)] = [
            ("m", 2), ("l", 2), ("c", 6), ("v", 4), ("y", 4), ("h", 0), ("re", 4),
            ("S", 0), ("s", 0), ("f", 0), ("F", 0), ("f*", 0), ("B", 0), ("B*", 0),
            ("b", 0), ("b*", 0), ("n", 0), ("W", 0), ("W*", 0)
        ]

        static func table() -> CGPDFOperatorTableRef {
            let table = CGPDFOperatorTableCreate()!
            for (name, _) in operators {
                CGPDFOperatorTableSetCallback(table, name, callback(for: name))
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in qpdfDigestForm(scanner, info) }
            return table
        }

        private static func callback(for name: String) -> CGPDFOperatorCallback {
            switch name {
            case "m": return { s, i in qpdfDigestRecord(s, i, "m", 2) }
            case "l": return { s, i in qpdfDigestRecord(s, i, "l", 2) }
            case "c": return { s, i in qpdfDigestRecord(s, i, "c", 6) }
            case "v": return { s, i in qpdfDigestRecord(s, i, "v", 4) }
            case "y": return { s, i in qpdfDigestRecord(s, i, "y", 4) }
            case "h": return { s, i in qpdfDigestRecord(s, i, "h", 0) }
            case "re": return { s, i in qpdfDigestRecord(s, i, "re", 4) }
            case "S": return { s, i in qpdfDigestRecord(s, i, "S", 0) }
            case "s": return { s, i in qpdfDigestRecord(s, i, "s", 0) }
            case "f": return { s, i in qpdfDigestRecord(s, i, "f", 0) }
            case "F": return { s, i in qpdfDigestRecord(s, i, "F", 0) }
            case "f*": return { s, i in qpdfDigestRecord(s, i, "f*", 0) }
            case "B": return { s, i in qpdfDigestRecord(s, i, "B", 0) }
            case "B*": return { s, i in qpdfDigestRecord(s, i, "B*", 0) }
            case "b": return { s, i in qpdfDigestRecord(s, i, "b", 0) }
            case "b*": return { s, i in qpdfDigestRecord(s, i, "b*", 0) }
            case "n": return { s, i in qpdfDigestRecord(s, i, "n", 0) }
            case "W": return { s, i in qpdfDigestRecord(s, i, "W", 0) }
            default: return { s, i in qpdfDigestRecord(s, i, "W*", 0) }
            }
        }

    }
}

/// `Do` of a form XObject into the digest of the collector behind `info`: the form's `/Matrix`,
/// `/BBox` and operators, scanned with a collector of its own (a picture is not recorded).
private func qpdfDigestForm(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let collector = Unmanaged<QPDFVectorDigest.Collector>.fromOpaque(info).takeUnretainedValue()
    var namePointer: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
    let content = CGPDFScannerGetContentStream(scanner)
    guard let object = CGPDFContentStreamGetResource(content, "XObject", namePointer) else { return }
    var stream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
    var subtype: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
    let identity = unsafeBitCast(stream, to: UnsafeRawPointer.self)
    let digest: String
    if let cached = collector.cache.digests[identity] {
        digest = cached
    } else if collector.depth >= 12 {
        digest = "deep"
    } else {
        let inner = QPDFVectorDigest.Collector(table: collector.table, depth: collector.depth + 1, cache: collector.cache)
        for key in ["Matrix", "BBox"] {
            var array: CGPDFArrayRef?
            var values: [CGPDFReal] = []
            if CGPDFDictionaryGetArray(dictionary, key, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var value: CGPDFReal = 0
                    _ = CGPDFArrayGetNumber(array, index, &value)
                    values.append(value)
                }
            }
            inner.append(key + values.map { String(format: " %.6f", $0) }.joined())
        }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let formContent = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        let formScanner = CGPDFScannerCreate(formContent, collector.table, Unmanaged.passUnretained(inner).toOpaque())
        _ = CGPDFScannerScan(formScanner)
        CGPDFScannerRelease(formScanner)
        CGPDFContentStreamRelease(formContent)
        // Nested forms fold into their parent's hash, in order.
        for (nested, count) in inner.forms.sorted(by: { $0.key < $1.key }) { inner.append("form \(nested) x\(count)") }
        digest = inner.digest()
        collector.cache.digests[identity] = digest
    }
    collector.forms[digest, default: 0] += 1
}

/// One path operator into the digest of the collector behind `info`. File-level so the scanner's
/// C callbacks can be formed without capturing anything.
private func qpdfDigestRecord(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?, _ name: String, _ arity: Int) {
    guard let info else { return }
    let collector = Unmanaged<QPDFVectorDigest.Collector>.fromOpaque(info).takeUnretainedValue()
    var values = [CGPDFReal](repeating: 0, count: arity)
    for index in stride(from: arity - 1, through: 0, by: -1) {
        var value: CGPDFReal = 0
        _ = CGPDFScannerPopNumber(scanner, &value)
        values[index] = value
    }
    // Six decimals: a rewrite may re-serialise numbers, never move them.
    collector.append(name + values.map { String(format: " %.6f", $0) }.joined())
}
