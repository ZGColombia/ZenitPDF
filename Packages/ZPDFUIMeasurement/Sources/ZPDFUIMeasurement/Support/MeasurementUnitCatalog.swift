import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Turns the presentation layer's unit enums into design-system picker options.
///
/// The design system deliberately knows nothing about units, and the presentation layer
/// deliberately knows nothing about pickers. This is the seam between them.
public enum MeasurementUnitCatalog {

    /// Every length unit, in the order the picker shows them.
    public static let lengthOptions: [ZPDFUnitOption] = LengthUnit.allCases.map(option(for:))

    /// Every area unit.
    public static let areaOptions: [ZPDFUnitOption] = AreaUnit.allCases.map(option(for:))

    /// Every volume unit.
    public static let volumeOptions: [ZPDFUnitOption] = VolumeUnit.allCases.map(option(for:))

    /// A picker option for one length unit.
    public static func option(for unit: LengthUnit) -> ZPDFUnitOption {
        ZPDFUnitOption(id: unit.rawValue, name: unit.displayName, abbreviation: unit.symbol)
    }

    /// A picker option for one area unit.
    public static func option(for unit: AreaUnit) -> ZPDFUnitOption {
        ZPDFUnitOption(id: unit.rawValue, name: unit.displayName, abbreviation: unit.symbol)
    }

    /// A picker option for one volume unit.
    public static func option(for unit: VolumeUnit) -> ZPDFUnitOption {
        ZPDFUnitOption(id: unit.rawValue, name: unit.displayName, abbreviation: unit.symbol)
    }

    /// Resolves a picker identifier back to a length unit, or `nil` when the identifier is not
    /// a unit Zenit can measure in. Calibration treats that `nil` as a blocking error rather
    /// than silently falling back to metres.
    public static func lengthUnit(forIdentifier identifier: String) -> LengthUnit? {
        LengthUnit(rawValue: identifier)
    }

    /// One PDF page point expressed in metres: 1 pt = 1/72 in, 1 in = 0.0254 m.
    public static let metresPerPagePoint: Double = 0.0254 / 72.0
}
