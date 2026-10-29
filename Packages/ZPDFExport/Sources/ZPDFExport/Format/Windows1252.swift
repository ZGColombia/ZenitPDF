import Foundation

/// Windows-1252 — the PDF standard fonts' WinAnsiEncoding and the spreadsheet code page — as one
/// table for every writer that needs it (R-113).
///
/// The visible signature seal, the searchable OCR layer and the export profiles each carried their
/// own encoder, and they disagreed: the seal knew only the Latin-1 half and seven punctuation marks,
/// so a signer named Šolić or a reason with "…" or "™" printed `?` in the seal while the OCR layer
/// and the profiles encoded the same characters correctly.
enum Windows1252 {

    /// Unicode → the byte for the characters that 0x80–0x9F hold (the rest of that block is
    /// unassigned).
    static let extras: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
        0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
        0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
        0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    /// The byte for `scalar`, or `nil` when the code page lacks it.
    static func byte(for scalar: Unicode.Scalar) -> UInt8? {
        if scalar.value < 0x80 || (0xA0...0xFF).contains(scalar.value) { return UInt8(scalar.value) }
        return extras[scalar.value]
    }

    /// The bytes for one character (composed first, so "é" written as e + combining acute is the
    /// single byte 0xE9), or `nil` when any part of it is missing from the code page.
    static func bytes(for character: Character) -> [UInt8]? {
        var out: [UInt8] = []
        for scalar in String(character).precomposedStringWithCanonicalMapping.unicodeScalars {
            guard let byte = byte(for: scalar) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// `text` as the body of a PDF literal string in WinAnsiEncoding: `(`, `)` and `\` escaped,
    /// bytes outside printable ASCII written in octal, and a character the code page lacks written
    /// as one `?`. `controlsAsSpace` writes control characters as spaces (a seal line).
    static func pdfLiteral(_ text: String, controlsAsSpace: Bool = false) -> String {
        var out = ""
        for character in text {
            for byte in bytes(for: character) ?? [UInt8(ascii: "?")] {
                switch byte {
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                    out += "\\" + String(UnicodeScalar(byte))
                case 0x20...0x7E:
                    out += String(UnicodeScalar(byte))
                case 0x00..<0x20 where controlsAsSpace:
                    out += " "
                default:
                    out += String(format: "\\%03o", byte)
                }
            }
        }
        return out
    }
}
