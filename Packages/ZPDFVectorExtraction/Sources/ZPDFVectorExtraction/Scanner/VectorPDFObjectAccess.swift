import CoreGraphics
import Foundation

/// Small, total helpers over the `CGPDFObject` C API.
///
/// Every one of them returns an optional instead of trapping: the input is a PDF, and a
/// PDF may claim anything about itself. Nothing here force-unwraps, and nothing here
/// allocates in proportion to a number read out of the file.
enum PDFObject {

    static func name(_ pointer: UnsafePointer<Int8>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }

    static func dictionary(_ object: CGPDFObjectRef?) -> CGPDFDictionaryRef? {
        guard let object else { return nil }
        var value: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &value) else { return nil }
        return value
    }

    static func stream(_ object: CGPDFObjectRef?) -> CGPDFStreamRef? {
        guard let object else { return nil }
        var value: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &value) else { return nil }
        return value
    }

    static func array(_ object: CGPDFObjectRef?) -> CGPDFArrayRef? {
        guard let object else { return nil }
        var value: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &value) else { return nil }
        return value
    }

    static func nameValue(_ object: CGPDFObjectRef?) -> String? {
        guard let object else { return nil }
        var value: UnsafePointer<Int8>?
        guard CGPDFObjectGetValue(object, .name, &value) else { return nil }
        return name(value)
    }

    static func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Double? {
        var value: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dictionary, key, &value) else { return nil }
        return Double(value)
    }

    static func integer(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, key, &value) else { return nil }
        return value
    }

    static func nameEntry(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dictionary, key, &value) else { return nil }
        return name(value)
    }

    static func dictionaryEntry(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &value) else { return nil }
        return value
    }

    static func arrayEntry(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &value) else { return nil }
        return value
    }

    static func streamEntry(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var value: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, key, &value) else { return nil }
        return value
    }

    /// A `[a b c d e f]` matrix entry, or `nil` when it is absent or not six numbers.
    static func matrix(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGAffineTransform? {
        guard let array = arrayEntry(dictionary, key), CGPDFArrayGetCount(array) == 6 else { return nil }
        var components = [Double](repeating: 0, count: 6)
        for index in 0..<6 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value), value.isFinite else { return nil }
            components[index] = Double(value)
        }
        return CGAffineTransform(
            a: components[0], b: components[1],
            c: components[2], d: components[3],
            tx: components[4], ty: components[5]
        )
    }

    /// An `[llx lly urx ury]` box entry.
    static func box(_ dictionary: CGPDFDictionaryRef, _ key: String) -> VectorBounds? {
        guard let array = arrayEntry(dictionary, key), CGPDFArrayGetCount(array) == 4 else { return nil }
        var components = [Double](repeating: 0, count: 4)
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value), value.isFinite else { return nil }
            components[index] = Double(value)
        }
        return VectorBounds(
            minX: components[0], minY: components[1],
            maxX: components[2], maxY: components[3]
        )
    }

    /// The declared encoded length of a stream, used for progress accounting. The
    /// *encoded* length is read on purpose: decoding a stream to measure it is exactly
    /// the decompression-bomb trap.
    static func encodedLength(of stream: CGPDFStreamRef) -> Int {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return 0 }
        return integer(dictionary, "Length").map { Swift.max(0, $0) } ?? 0
    }

    /// A pointer-identity token for a PDF dictionary, used only for cycle detection and
    /// optional-content membership within a single open document. Never persisted:
    /// pointer values differ between runs, and anything derived from them would break
    /// the determinism rule of `QUALITY_BAR` 3.4 if it escaped.
    static func identity(dictionary: CGPDFDictionaryRef) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(dictionary.rawValue))
    }

    /// The same, for a stream.
    static func identity(stream: CGPDFStreamRef) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(stream.rawValue))
    }
}
