import Foundation

/// A DXF drawing converted to a PDF sheet inside the geometry service (NL-PLAT-05, round 2).
///
/// The `.dxf` arrives as an inherited read-only descriptor, exactly as a PDF does for extraction;
/// the service reads it, parses it with `ZPDFDXF`'s bounded reader and draws the sheet. What comes
/// back is the sheet — the PDF bytes Zenit wrote, and the facts about the file the app shows — never
/// the parsed entities, so the application never parses the untrusted file itself.
public struct DXFWireRequest: Sendable, Codable, Hashable {
    public var requestID: UUID
    /// The sheet's title, written into the PDF (the file name without its extension).
    public var title: String
    /// Original file name, carried for error messages only.
    public var fileName: String
    /// Test hook, as ``GeometryWireRequest/debugDelayMilliseconds``.
    public var debugDelayMilliseconds: Int

    public init(requestID: UUID = UUID(), title: String, fileName: String, debugDelayMilliseconds: Int = 0) {
        self.requestID = requestID
        self.title = title
        self.fileName = fileName
        self.debugDelayMilliseconds = debugDelayMilliseconds
    }
}

/// The sheet the service drew, as it crosses the boundary.
public struct DXFWireSheet: Sendable, Codable, Hashable {
    /// The PDF: one page, one optional-content layer per DXF layer.
    public var pdf: Data
    /// The sheet is drawn at 1 : `scaleDenominator`.
    public var scaleDenominator: Int
    /// `true` when the file stated a real unit, so the scale is a fact about the file.
    public var scaleIsFromFile: Bool
    /// `$INSUNITS` as the file wrote it (0 unitless … 16 hectometres).
    public var unitRawValue: Int
    public var pageWidthPoints: Double
    public var pageHeightPoints: Double
    public var layers: [String]
    /// Entity kinds the reader met and does not draw, with counts.
    public var skipped: [String: Int]

    public init(pdf: Data, scaleDenominator: Int, scaleIsFromFile: Bool, unitRawValue: Int, pageWidthPoints: Double,
                pageHeightPoints: Double, layers: [String], skipped: [String: Int]) {
        self.pdf = pdf
        self.scaleDenominator = scaleDenominator
        self.scaleIsFromFile = scaleIsFromFile
        self.unitRawValue = unitRawValue
        self.pageWidthPoints = pageWidthPoints
        self.pageHeightPoints = pageHeightPoints
        self.layers = layers
        self.skipped = skipped
    }
}

/// The sheet's bytes on the wire: a binary property list, which carries the PDF as raw bytes
/// rather than inflating it by a third as JSON's base64 would. The reader refuses a reply that
/// could not have come from the writer — a PDF that is not one, a scale off the standard list's
/// range, an unknown unit, a page of no size — before the app acts on it.
public enum DXFWireCodec {

    /// Largest sheet the app accepts back, in bytes.
    public static let maximumPDFBytes = 512 * 1024 * 1024

    public static func encode(_ sheet: DXFWireSheet) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(sheet)
    }

    public static func decode(_ data: Data) throws -> DXFWireSheet {
        let sheet = try PropertyListDecoder().decode(DXFWireSheet.self, from: data)
        guard sheet.pdf.count <= maximumPDFBytes, sheet.pdf.starts(with: Data("%PDF-".utf8)) else {
            throw DXFWireError.malformed("the sheet is not a PDF")
        }
        guard (1...100_000).contains(sheet.scaleDenominator) else { throw DXFWireError.malformed("scale 1:\(sheet.scaleDenominator)") }
        guard (0...16).contains(sheet.unitRawValue) else { throw DXFWireError.malformed("unit \(sheet.unitRawValue)") }
        guard sheet.pageWidthPoints.isFinite, sheet.pageHeightPoints.isFinite,
              sheet.pageWidthPoints > 0, sheet.pageHeightPoints > 0 else { throw DXFWireError.malformed("page size") }
        guard sheet.skipped.values.allSatisfy({ $0 >= 0 }) else { throw DXFWireError.malformed("skipped counts") }
        return sheet
    }
}

public enum DXFWireError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case let .malformed(detail): return "The drawing service sent back a sheet that does not read: \(detail)."
        }
    }
}
