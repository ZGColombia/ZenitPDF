import CoreGraphics
import Foundation

/// A little-endian binary writer with varint integers.
///
/// Hand-rolled rather than `JSONEncoder` because the result is stored per page inside
/// the project package: a 250 000-primitive page is roughly 20 MB here and roughly ten
/// times that as JSON.
struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    init(reservingCapacity capacity: Int = 0) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    mutating func write(byte: UInt8) { bytes.append(byte) }

    mutating func write(bool: Bool) { bytes.append(bool ? 1 : 0) }

    /// LEB128 unsigned varint: one byte for values under 128, which is most of them.
    mutating func write(varint value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
    }

    mutating func write(varint value: Int) {
        write(varint: UInt64(Swift.max(0, value)))
    }

    mutating func write(fixed value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func write(fixed value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func write(double value: Double) { write(fixed: value.bitPattern) }

    mutating func write(float value: Float) { write(fixed: value.bitPattern) }

    mutating func write(point: CGPoint) {
        write(double: point.x)
        write(double: point.y)
    }

    mutating func write(bounds: VectorBounds) {
        write(double: bounds.minX)
        write(double: bounds.minY)
        write(double: bounds.maxX)
        write(double: bounds.maxY)
    }

    mutating func write(string: String) {
        let utf8 = Array(string.utf8)
        write(varint: UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func write(optionalString: String?) {
        guard let optionalString else { return write(bool: false) }
        write(bool: true)
        write(string: optionalString)
    }
}

/// The reader half. Every read is bounds-checked and every failure is typed: the input
/// may be a truncated or corrupted cache file inside a project package a user copied
/// off a failing disk.
struct BinaryReader {
    private let bytes: [UInt8]
    /// One past the last readable byte: the reader can be bounded to a prefix of
    /// `bytes` — the payload before the checksum trailer — without copying it (IM-158).
    private let end: Int
    private var offset: Int

    init(_ data: Data) {
        let bytes = [UInt8](data)
        self.bytes = bytes
        self.end = bytes.count
        self.offset = 0
    }

    /// A reader over `bytes[start..<end]`, sharing the array's storage.
    init(bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        self.end = Swift.min(Swift.max(end ?? bytes.count, 0), bytes.count)
        self.offset = Swift.min(Swift.max(start, 0), self.end)
    }

    var remaining: Int { end - offset }
    var position: Int { offset }

    private func fail(_ reason: String) -> VectorExtractionError {
        .cacheDecodingFailed(reason: "\(reason) at byte \(offset)")
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < end else { throw fail("unexpected end of data") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBool() throws -> Bool {
        let byte = try readByte()
        guard byte <= 1 else { throw fail("invalid boolean \(byte)") }
        return byte == 1
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readByte()
            guard shift < 64 else { throw fail("varint is too long") }
            // The tenth group sits at shift 63, where only its lowest bit fits. Swift's
            // smart shift silently discarded the other six, so a value that does not fit
            // in 64 bits decoded as a truncated one and returned normally instead of
            // throwing the typed error every other malformed field gets (BH-859).
            guard shift < 63 || byte & 0x7E == 0 else { throw fail("varint overflows 64 bits") }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    /// A varint read as a signed `Int`, refusing anything that does not fit.
    ///
    /// The narrowing `Int(someUInt64)` traps, and a trap is not a refusal: no `catch`
    /// sees it, the crash-recovery machinery never runs, and the process dies. Every
    /// scalar in this format that ends up in an `Int` therefore goes through here, so a
    /// hostile ten-byte varint carrying `UInt64.max` becomes a typed decoding error like
    /// every other malformed field. (S17 security review: the same bytes reach this
    /// decoder from `GeometryService.xpc`'s reply, which is exactly the input the XPC
    /// boundary exists to distrust.)
    mutating func readBoundedInt(limit: Int = Int.max) throws -> Int {
        let value = try readVarint()
        guard value <= UInt64(limit) else {
            throw fail("value \(value) exceeds the decoding limit \(limit)")
        }
        return Int(value)
    }

    mutating func readCount(limit: Int) throws -> Int {
        let value = try readVarint()
        guard value <= UInt64(limit) else {
            throw fail("count \(value) exceeds the decoding limit \(limit)")
        }
        // A count must not exceed the bytes that could possibly encode it: one element
        // is at least one byte, so a claimed count larger than what is left is a lie.
        guard value <= UInt64(remaining) + 1 else {
            throw fail("count \(value) exceeds the remaining \(remaining) bytes")
        }
        return Int(value)
    }

    mutating func readFixedUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw fail("unexpected end of data") }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    mutating func readFixedUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw fail("unexpected end of data") }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        offset += 4
        return value
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readFixedUInt64())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readFixedUInt32())
    }

    mutating func readPoint() throws -> CGPoint {
        let x = try readDouble()
        let y = try readDouble()
        return CGPoint(x: x, y: y)
    }

    mutating func readBounds() throws -> VectorBounds {
        let minX = try readDouble()
        let minY = try readDouble()
        let maxX = try readDouble()
        let maxY = try readDouble()
        return VectorBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    mutating func readString(limit: Int = 1 << 20) throws -> String {
        let count = try readCount(limit: limit)
        guard remaining >= count else { throw fail("string runs past the end of data") }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        guard let value = String(bytes: slice, encoding: .utf8) else {
            throw fail("string is not valid UTF-8")
        }
        return value
    }

    mutating func readOptionalString(limit: Int = 1 << 20) throws -> String? {
        guard try readBool() else { return nil }
        return try readString(limit: limit)
    }

    mutating func expect(magic: [UInt8]) throws {
        guard remaining >= magic.count else { throw fail("data is too short to be an extraction") }
        for expected in magic {
            let actual = try readByte()
            guard actual == expected else { throw fail("wrong magic number") }
        }
    }
}
