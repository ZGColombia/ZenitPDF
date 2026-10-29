import Foundation
import GRDB

/// A colour stored in one `INTEGER` column as `0xRRGGBBAA`.
///
/// Spec 8.2 gives `color_rgba INTEGER NOT NULL` on `scale_region` and `project_zone`.
/// Eight bits per channel with the alpha in the low byte, so the packed value reads the
/// same way it is written in CSS-style hex and sorts sensibly in a debugger.
///
/// SQLite integers are signed 64-bit, so the packed 32-bit value is widened rather than
/// reinterpreted: a colour never comes back negative, and a value outside `0…0xFFFFFFFF`
/// is a typed rejection instead of a silent truncation.
public struct PackedRGBA: Sendable, Hashable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(packedValue: UInt32) {
        self.red = UInt8(truncatingIfNeeded: packedValue >> 24)
        self.green = UInt8(truncatingIfNeeded: packedValue >> 16)
        self.blue = UInt8(truncatingIfNeeded: packedValue >> 8)
        self.alpha = UInt8(truncatingIfNeeded: packedValue)
    }

    /// Clamps and rounds unit-interval components. `NaN` becomes 0 rather than trapping.
    public init(unitRed: Double, unitGreen: Double, unitBlue: Double, unitAlpha: Double = 1) {
        func channel(_ value: Double) -> UInt8 {
            guard value.isFinite else { return 0 }
            let scaled = (value * 255).rounded()
            return UInt8(max(0, min(255, scaled)))
        }
        self.init(
            red: channel(unitRed),
            green: channel(unitGreen),
            blue: channel(unitBlue),
            alpha: channel(unitAlpha)
        )
    }

    public var packedValue: UInt32 {
        (UInt32(red) << 24) | (UInt32(green) << 16) | (UInt32(blue) << 8) | UInt32(alpha)
    }

    public var unitComponents: (red: Double, green: Double, blue: Double, alpha: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255, Double(alpha) / 255)
    }

    public static let opaqueBlack = PackedRGBA(packedValue: 0x0000_00FF)
}

extension PackedRGBA: CustomStringConvertible {
    public var description: String { String(format: "#%08X", packedValue) }
}

extension PackedRGBA: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { Int64(packedValue).databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> PackedRGBA? {
        // Only INTEGER storage (BH-611). GRDB's `Int64.fromDatabaseValue` also accepts a
        // REAL and rounds it toward zero, which would read a lossy writer's 4278190335.7
        // as a valid colour instead of the typed rejection the header promises.
        guard case let .int64(raw) = dbValue.storage,
              raw >= 0, raw <= Int64(UInt32.max)
        else { return nil }
        return PackedRGBA(packedValue: UInt32(raw))
    }
}
