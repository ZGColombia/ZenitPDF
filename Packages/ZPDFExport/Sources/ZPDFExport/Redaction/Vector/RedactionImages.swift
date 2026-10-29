import CoreGraphics
import Foundation
import ImageIO

/// Blanks the samples of an image that fall under a box, in the image data itself.
///
/// A picture partly under a box keeps every sample whose centre lies outside the boxes exactly
/// as it was; every sample whose centre lies inside one is overwritten with a constant, and the
/// image is written back losslessly (Flate). Covering an image with a black rectangle would
/// leave the samples in the file for anyone to lift; this removes them.
enum RedactionImages {

    struct Layout {
        var width: Int
        var height: Int
        var bitsPerComponent: Int
        var components: Int
        /// Per component, the raw sample value written into a blanked sample.
        var blank: [UInt32]

        var rowBytes: Int { (width * components * bitsPerComponent + 7) / 8 }
    }

    struct Result {
        var dictionary: [String: PDFObject]
        var data: Data
    }

    /// Which samples are overwritten.
    enum Rule {
        /// Redaction: every sample whose centre lies inside a box.
        case blankCentresIn([CGRect])
        /// A copy cut down to what one placement shows: every sample whose cell lies wholly
        /// outside the visible rectangle (a sample any part of which shows is kept).
        case keepCellsMeeting(CGRect)
    }

    static func blank(_ bytes: inout [UInt8], layout: Layout, placement: CGAffineTransform, rule: Rule) -> Int {
        switch rule {
        case let .blankCentresIn(boxes): return blank(&bytes, layout: layout, placement: placement, boxes: boxes)
        case let .keepCellsMeeting(visible): return blank(&bytes, layout: layout, placement: placement, outside: visible)
        }
    }

    /// Overwrites every sample whose cell, placed on the sheet, does not meet `visible`.
    static func blank(_ bytes: inout [UInt8], layout: Layout, placement: CGAffineTransform, outside visible: CGRect) -> Int {
        let w = Double(layout.width), h = Double(layout.height)
        var count = 0
        // Samples outside the visible rectangle's bounds in sample space cannot meet it; only
        // those inside need the exact test.
        var firstColumn = 0, lastColumn = -1, firstRow = 0, lastRow = -1
        if !visible.isNull, visible.width > 0, visible.height > 0,
           abs(placement.a * placement.d - placement.b * placement.c) > 1e-12 {
            let inverse = placement.inverted()
            let corners = [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.minY),
                           CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)].map { $0.applying(inverse) }
            let (minU, maxU, minV, maxV) = unitBounds(corners)
            firstColumn = max(0, Int((minU * w).rounded(.down)) - 1)
            lastColumn = min(layout.width - 1, Int((maxU * w).rounded(.up)) + 1)
            firstRow = max(0, Int(((1 - maxV) * h).rounded(.down)) - 1)
            lastRow = min(layout.height - 1, Int(((1 - minV) * h).rounded(.up)) + 1)
        }
        for row in 0..<layout.height {
            for column in 0..<layout.width {
                var meets = false
                if row >= firstRow, row <= lastRow, column >= firstColumn, column <= lastColumn {
                    let cell = [CGPoint(x: Double(column) / w, y: 1 - Double(row + 1) / h), CGPoint(x: Double(column + 1) / w, y: 1 - Double(row + 1) / h),
                                CGPoint(x: Double(column + 1) / w, y: 1 - Double(row) / h), CGPoint(x: Double(column) / w, y: 1 - Double(row) / h)]
                        .map { $0.applying(placement) }
                    meets = RedactionContentRewriter.quad(cell, intersects: visible)
                }
                if !meets, write(&bytes, layout: layout, row: row, column: column) { count += 1 }
            }
        }
        return count
    }

    /// The component count and blank value of a colour space, resolved through the resources.
    static func layout(
        dictionary: [String: PDFObject],
        colorSpaces: [String: PDFObject]?,
        resolve: (PDFObject?) -> PDFObject?
    ) throws -> Layout {
        guard let width = resolve(dictionary["Width"])?.integerValue, let height = resolve(dictionary["Height"])?.integerValue,
              width > 0, height > 0, width <= 30_000, height <= 30_000 else {
            throw RedactionUnsupported("an image has no usable size")
        }
        if resolve(dictionary["ImageMask"]) == .boolean(true) {
            let decode = resolve(dictionary["Decode"])?.arrayValue?.compactMap { resolve($0)?.doubleValue }
            // Sample 0 paints under the default decode; the blank sample paints nothing.
            let paintsOnZero = decode.map { $0.count == 2 && $0[0] < $0[1] } ?? true
            return Layout(width: width, height: height, bitsPerComponent: 1, components: 1, blank: [paintsOnZero ? 1 : 0])
        }
        let bits = resolve(dictionary["BitsPerComponent"])?.integerValue ?? 8
        guard [1, 2, 4, 8, 16].contains(bits) else { throw RedactionUnsupported("an image has \(bits) bits per component") }
        let maximum = UInt32((1 << bits) - 1)
        let (components, kind) = try colorSpace(resolve(dictionary["ColorSpace"]), colorSpaces: colorSpaces, resolve: resolve, depth: 0)
        let blank: [UInt32]
        switch kind {
        case .cmyk: blank = [0, 0, 0, maximum]
        case .tint: blank = Array(repeating: maximum, count: components)
        case .zero: blank = Array(repeating: 0, count: components)
        }
        return Layout(width: width, height: height, bitsPerComponent: bits, components: components, blank: blank)
    }

    private enum BlankKind { case zero, cmyk, tint }

    private static func colorSpace(
        _ value: PDFObject?,
        colorSpaces: [String: PDFObject]?,
        resolve: (PDFObject?) -> PDFObject?,
        depth: Int
    ) throws -> (Int, BlankKind) {
        guard depth < 8 else { throw RedactionUnsupported("an image colour space nests too deeply") }
        switch value {
        case .name("DeviceGray")?, .name("CalGray")?, .name("G")?: return (1, .zero)
        case .name("DeviceRGB")?, .name("CalRGB")?, .name("RGB")?: return (3, .zero)
        case .name("DeviceCMYK")?, .name("CMYK")?: return (4, .cmyk)
        case let .name(name)?:
            guard let named = resolve(colorSpaces?[name]) else { throw RedactionUnsupported("an image names the colour space \(name), which the sheet does not define") }
            return try colorSpace(named, colorSpaces: colorSpaces, resolve: resolve, depth: depth + 1)
        case let .array(items)?:
            guard let family = resolve(items.first)?.nameValue else { break }
            switch family {
            case "CalGray": return (1, .zero)
            case "CalRGB", "Lab": return (3, .zero)
            case "Indexed", "I": return (1, .zero)
            case "ICCBased":
                let n = resolve(items.count > 1 ? items[1] : nil)?.dictionaryValue?["N"].flatMap { resolve($0)?.integerValue } ?? 0
                guard [1, 3, 4].contains(n) else { throw RedactionUnsupported("an ICC colour space has \(n) components") }
                return (n, n == 4 ? .cmyk : .zero)
            case "Separation": return (1, .tint)
            case "DeviceN":
                let names = resolve(items.count > 1 ? items[1] : nil)?.arrayValue ?? []
                guard !names.isEmpty, names.count <= 32 else { break }
                return (names.count, .tint)
            default:
                if items.count == 1 { return try colorSpace(items[0], colorSpaces: colorSpaces, resolve: resolve, depth: depth + 1) }
            }
        default:
            break
        }
        throw RedactionUnsupported("an image's colour space cannot be read")
    }

    /// The decoded samples, from any supported filter chain including DCT (8-bit gray or RGB).
    static func samples(dictionary: [String: PDFObject], data: Data, layout: inout Layout) throws -> [UInt8] {
        let decoded = try RedactionStreamFilters.decode(dictionary: dictionary, data: data, allowDCT: true)
        var bytes: [UInt8]
        if decoded.remainingFilter == "DCTDecode" {
            bytes = try jpegSamples(decoded.data, layout: &layout)
        } else {
            bytes = [UInt8](decoded.data)
        }
        let expected = layout.rowBytes * layout.height
        guard bytes.count >= expected else { throw RedactionUnsupported("an image's data is shorter than its size says") }
        if bytes.count > expected { bytes.removeSubrange(expected...) }
        return bytes
    }

    private static func jpegSamples(_ data: Data, layout: inout Layout) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == layout.width, image.height == layout.height, image.bitsPerComponent == 8,
              let provider = image.dataProvider, let raw = provider.data as Data?
        else { throw RedactionUnsupported("a JPEG image cannot be decoded") }
        let model = image.colorSpace?.model
        let components = model == .monochrome ? 1 : (model == .rgb ? 3 : 0)
        guard components > 0, components == layout.components else {
            throw RedactionUnsupported("a JPEG image is not 8-bit gray or RGB")
        }
        let pixelBytes = image.bitsPerPixel / 8
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
        let offset = alphaFirst && pixelBytes > components ? pixelBytes - components : 0
        let bytes = [UInt8](raw)
        var out = [UInt8](repeating: 0, count: layout.width * layout.height * components)
        for row in 0..<layout.height {
            for column in 0..<layout.width {
                let source = row * image.bytesPerRow + column * pixelBytes + offset
                let target = (row * layout.width + column) * components
                guard source + components <= bytes.count else { throw RedactionUnsupported("a JPEG image decodes short") }
                for component in 0..<components { out[target + component] = bytes[source + component] }
            }
        }
        layout.bitsPerComponent = 8
        return out
    }

    /// Overwrites every sample whose centre, placed on the sheet by `placement` (the unit square
    /// to page space), lies inside a box. Returns how many samples were blanked.
    static func blank(_ bytes: inout [UInt8], layout: Layout, placement: CGAffineTransform, boxes: [CGRect]) -> Int {
        let inverse = placement.inverted()
        var count = 0
        for box in boxes {
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)].map { $0.applying(inverse) }
            let (minU, maxU, minV, maxV) = unitBounds(corners)
            let w = Double(layout.width), h = Double(layout.height)
            let firstColumn = max(0, Int((minU * w).rounded(.down)) - 1), lastColumn = min(layout.width - 1, Int((maxU * w).rounded(.up)) + 1)
            let firstRow = max(0, Int(((1 - maxV) * h).rounded(.down)) - 1), lastRow = min(layout.height - 1, Int(((1 - minV) * h).rounded(.up)) + 1)
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    let unit = CGPoint(x: (Double(column) + 0.5) / w, y: 1 - (Double(row) + 0.5) / h)
                    let page = unit.applying(placement)
                    guard page.x > box.minX, page.x < box.maxX, page.y > box.minY, page.y < box.maxY else { continue }
                    if write(&bytes, layout: layout, row: row, column: column) { count += 1 }
                }
            }
        }
        return count
    }

    /// The unit-square bounds of `corners`, clamped to [-1, 2].
    ///
    /// They only choose which samples get the exact test, and the image is the unit square, so
    /// clamping never drops a sample. It keeps `bound × size` inside `Int`: a placement such as
    /// `1000 0 0 1e-14 x y cm` passes the determinant guard, and its inverse scales v by 1e14,
    /// which made `Int(Double)` trap (S-065). A non-finite corner scans the whole image.
    static func unitBounds(_ corners: [CGPoint]) -> (minU: Double, maxU: Double, minV: Double, maxV: Double) {
        let us = corners.map { Double($0.x) }, vs = corners.map { Double($0.y) }
        guard !us.isEmpty, (us + vs).allSatisfy(\.isFinite) else { return (-1, 2, -1, 2) }
        func clamp(_ value: Double) -> Double { min(2, max(-1, value)) }
        return (clamp(us.min() ?? 0), clamp(us.max() ?? 0), clamp(vs.min() ?? 0), clamp(vs.max() ?? 0))
    }

    /// Writes the blank value into one sample; `true` when a value changed.
    private static func write(_ bytes: inout [UInt8], layout: Layout, row: Int, column: Int) -> Bool {
        var changed = false
        let base = row * layout.rowBytes
        for component in 0..<layout.components {
            let value = layout.blank[component]
            let sampleIndex = column * layout.components + component
            switch layout.bitsPerComponent {
            case 8:
                let index = base + sampleIndex
                if bytes[index] != UInt8(value) { bytes[index] = UInt8(value); changed = true }
            case 16:
                let index = base + sampleIndex * 2
                let high = UInt8(value >> 8), low = UInt8(value & 0xFF)
                if bytes[index] != high || bytes[index + 1] != low { bytes[index] = high; bytes[index + 1] = low; changed = true }
            default:
                let bits = layout.bitsPerComponent
                let bitOffset = sampleIndex * bits
                let index = base + bitOffset / 8
                let shift = 8 - bits - bitOffset % 8
                let mask = UInt8(((1 << bits) - 1) << shift)
                let updated = (bytes[index] & ~mask) | (UInt8(value << UInt32(shift)) & mask)
                if updated != bytes[index] { bytes[index] = updated; changed = true }
            }
        }
        return changed
    }

    /// Reads one sample's components back (for the verifier).
    static func sample(_ bytes: [UInt8], layout: Layout, row: Int, column: Int) -> [UInt32] {
        let base = row * layout.rowBytes
        return (0..<layout.components).map { component in
            let sampleIndex = column * layout.components + component
            switch layout.bitsPerComponent {
            case 8: return UInt32(bytes[base + sampleIndex])
            case 16: return UInt32(bytes[base + sampleIndex * 2]) << 8 | UInt32(bytes[base + sampleIndex * 2 + 1])
            default:
                let bits = layout.bitsPerComponent
                let bitOffset = sampleIndex * bits
                let shift = 8 - bits - bitOffset % 8
                return UInt32((bytes[base + bitOffset / 8] >> UInt8(shift)) & UInt8((1 << bits) - 1))
            }
        }
    }

    /// An image XObject with its samples under the boxes blanked, written back with Flate.
    static func redactXObject(
        dictionary: [String: PDFObject],
        data: Data,
        placement: CGAffineTransform,
        rule: Rule,
        colorSpaces: [String: PDFObject]?,
        resolve: (PDFObject?) -> PDFObject?
    ) throws -> Result {
        var layout = try layout(dictionary: dictionary, colorSpaces: colorSpaces, resolve: resolve)
        var bytes = try samples(dictionary: dictionary, data: data, layout: &layout)
        _ = blank(&bytes, layout: layout, placement: placement, rule: rule)
        var out = dictionary
        // An associated file (/AF) can hold the original samples (finding 10); the writer drops
        // it everywhere, and it is not carried onto the blanked copy either.
        for key in ["Filter", "DecodeParms", "Length", "Alternates", "OPI", "Metadata", "SMaskInData", "Name", "StructParent", "ID", "AF"] {
            out.removeValue(forKey: key)
        }
        if out["ImageMask"] != .boolean(true) { out["BitsPerComponent"] = .integer(layout.bitsPerComponent) }
        var encoded = Data(bytes)
        if let flate = PDFStreamCodec.flateEncode(encoded) {
            encoded = flate
            out["Filter"] = .name("FlateDecode")
        }
        return Result(dictionary: out, data: encoded)
    }

    /// An inline image with its samples under the boxes blanked, re-emitted uncompressed in
    /// ASCIIHex so no binary byte can end the image early.
    static func redactInline(
        _ image: RedactionInlineImage,
        placement: CGAffineTransform,
        rule: Rule,
        colorSpaces: [String: PDFObject]?,
        resolve: (PDFObject?) -> PDFObject?
    ) throws -> RedactionInlineImage {
        let full = RedactionInlineImageKeys.expanded(image.dictionary)
        var layout = try layout(dictionary: full, colorSpaces: colorSpaces, resolve: resolve)
        var bytes = try samples(dictionary: full, data: image.data, layout: &layout)
        _ = blank(&bytes, layout: layout, placement: placement, rule: rule)
        var dictionary: [String: PDFObject] = [
            "W": .integer(layout.width), "H": .integer(layout.height), "F": .name("AHx")
        ]
        if full["ImageMask"] == .boolean(true) {
            dictionary["IM"] = .boolean(true)
        } else {
            dictionary["BPC"] = .integer(layout.bitsPerComponent)
            if let space = image.dictionary["CS"] ?? image.dictionary["ColorSpace"] { dictionary["CS"] = space }
        }
        if let decode = image.dictionary["D"] ?? image.dictionary["Decode"] { dictionary["D"] = decode }
        if let interpolate = image.dictionary["I"] ?? image.dictionary["Interpolate"] { dictionary["I"] = interpolate }
        return RedactionInlineImage(dictionary: dictionary, data: RedactionStreamFilters.asciiHexEncode(Data(bytes)))
    }
}
