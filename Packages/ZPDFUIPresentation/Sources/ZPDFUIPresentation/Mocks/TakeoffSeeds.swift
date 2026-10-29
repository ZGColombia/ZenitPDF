// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

/// Parses an exact decimal from text.
///
/// Sample values must not travel through `Double`: a float literal would turn `24.60`
/// into a value that fails the exact-equality assertions in the consistency tests.
internal func dec(_ text: String) -> Decimal { Decimal(string: text) ?? .zero }

/// One hand-authored line of the sample construction takeoff.
///
/// Quantities are stored in SI base units — metres, square metres, cubic metres or a
/// plain count — exactly as the measurement engine will produce them.
internal struct TakeoffSeed: Sendable {

    /// Takeoff subject, the primary grouping key.
    let subject: String
    /// Instance label.
    let label: String
    /// Measurement tool that produced the line.
    let kind: MeasurementKind
    /// Zero-based sheet index.
    let pageIndex: Int
    /// Index into the sample's Project Zone list.
    let zoneIndex: Int
    /// Primary quantity in the SI base unit for ``kind``'s dimension.
    let value: Decimal
    /// Outline length in metres for area takeoffs, otherwise `nil`.
    let perimetre: Decimal?
    /// Pour depth in metres for volume takeoffs, otherwise `nil`.
    let depth: Decimal?
    /// Price per SI base unit, in the project currency.
    let unitCost: Decimal
    /// Dimensionless waste allowance, for example `0.05` for five per cent.
    let wasteFactor: Decimal
    /// Material choice value.
    let material: String
    /// Trade choice value.
    let trade: String
    /// Scale Region that governed the measurement, or `nil` for the page default.
    let scaleRegionName: String?

    init(
        _ subject: String,
        _ label: String,
        _ kind: MeasurementKind,
        page: Int,
        zone: Int,
        value: Decimal,
        perimetre: Decimal? = nil,
        depth: Decimal? = nil,
        unitCost: Decimal,
        waste: Decimal,
        material: String,
        trade: String,
        scaleRegionName: String? = nil
    ) {
        self.subject = subject
        self.label = label
        self.kind = kind
        self.pageIndex = page
        self.zoneIndex = zone
        self.value = value
        self.perimetre = perimetre
        self.depth = depth
        self.unitCost = unitCost
        self.wasteFactor = waste
        self.material = material
        self.trade = trade
        self.scaleRegionName = scaleRegionName
    }
}

/// The forty-line sample takeoff.
///
/// Composition: seven plan lengths, four perimeters, thirteen areas, eleven counts and
/// five volumes, spread over three sheets and four Project Zones.
internal enum TakeoffSeedList {

    /// Builds the seed list.
    ///
    /// - Parameter footingRegionName: Name of the Scale Region the strip-footing lines
    ///   were measured inside, so that the sample exercises a non-default scale.
    static func all(footingRegionName: String) -> [TakeoffSeed] {
        [
            // MARK: Sheet A-101, Ground Floor — Zone A
            TakeoffSeed("Interior Partition", "Wall Type A", .polylength,
                        page: 0, zone: 0, value: dec("24.60"),
                        unitCost: dec("780"), waste: dec("0.05"),
                        material: "Gypsum", trade: "Carpentry"),
            TakeoffSeed("Interior Partition", "Wall Type A — Corridor", .polylength,
                        page: 0, zone: 0, value: dec("18.20"),
                        unitCost: dec("780"), waste: dec("0.05"),
                        material: "Gypsum", trade: "Carpentry"),
            TakeoffSeed("Exterior Wall", "North Elevation", .length,
                        page: 0, zone: 0, value: dec("12.40"),
                        unitCost: dec("1650"), waste: dec("0.03"),
                        material: "Concrete", trade: "Concrete"),
            TakeoffSeed("Exterior Wall", "East Elevation", .length,
                        page: 0, zone: 0, value: dec("8.75"),
                        unitCost: dec("1650"), waste: dec("0.03"),
                        material: "Concrete", trade: "Concrete"),
            TakeoffSeed("Skirting Board", "Office 101", .perimeter,
                        page: 0, zone: 0, value: dec("21.30"),
                        unitCost: dec("145"), waste: dec("0.08"),
                        material: "Timber", trade: "Carpentry"),
            TakeoffSeed("Skirting Board", "Office 102", .perimeter,
                        page: 0, zone: 0, value: dec("19.80"),
                        unitCost: dec("145"), waste: dec("0.08"),
                        material: "Timber", trade: "Carpentry"),
            TakeoffSeed("Floor Screed", "Office 101", .area,
                        page: 0, zone: 0, value: dec("27.45"), perimetre: dec("21.30"),
                        unitCost: dec("320"), waste: dec("0.04"),
                        material: "Screed", trade: "Flooring"),
            TakeoffSeed("Floor Screed", "Office 102", .area,
                        page: 0, zone: 0, value: dec("24.10"), perimetre: dec("19.80"),
                        unitCost: dec("320"), waste: dec("0.04"),
                        material: "Screed", trade: "Flooring"),
            TakeoffSeed("Suspended Ceiling", "Office 101", .rectangleArea,
                        page: 0, zone: 0, value: dec("27.45"), perimetre: dec("21.30"),
                        unitCost: dec("540"), waste: dec("0.06"),
                        material: "Mineral Fibre", trade: "Ceilings"),
            TakeoffSeed("Power Outlet", "Type G", .count,
                        page: 0, zone: 0, value: dec("18"),
                        unitCost: dec("420"), waste: dec("0"),
                        material: "Electrical", trade: "Electrical"),
            TakeoffSeed("Ceiling Luminaire", "LED 1200", .count,
                        page: 0, zone: 0, value: dec("12"),
                        unitCost: dec("1250"), waste: dec("0"),
                        material: "Electrical", trade: "Electrical"),

            // MARK: Sheet A-101, Ground Floor — Zone B
            TakeoffSeed("Interior Partition", "Wall Type C", .polylength,
                        page: 0, zone: 1, value: dec("15.40"),
                        unitCost: dec("820"), waste: dec("0.05"),
                        material: "Gypsum", trade: "Carpentry"),
            TakeoffSeed("Skirting Board", "Corridor", .perimeter,
                        page: 0, zone: 1, value: dec("34.60"),
                        unitCost: dec("145"), waste: dec("0.08"),
                        material: "Timber", trade: "Carpentry"),
            TakeoffSeed("Floor Screed", "Corridor", .area,
                        page: 0, zone: 1, value: dec("33.60"), perimetre: dec("34.60"),
                        unitCost: dec("320"), waste: dec("0.04"),
                        material: "Screed", trade: "Flooring"),
            TakeoffSeed("Ceramic Tile", "WC 103", .area,
                        page: 0, zone: 1, value: dec("8.65"), perimetre: dec("12.20"),
                        unitCost: dec("890"), waste: dec("0.10"),
                        material: "Ceramic", trade: "Flooring"),
            TakeoffSeed("Suspended Ceiling", "Corridor", .rectangleArea,
                        page: 0, zone: 1, value: dec("33.60"), perimetre: dec("34.60"),
                        unitCost: dec("540"), waste: dec("0.06"),
                        material: "Mineral Fibre", trade: "Ceilings"),
            TakeoffSeed("Smoke Detector", "Ceiling Mounted", .count,
                        page: 0, zone: 1, value: dec("6"),
                        unitCost: dec("890"), waste: dec("0"),
                        material: "Electrical", trade: "Electrical"),
            TakeoffSeed("Door Single", "D-01", .count,
                        page: 0, zone: 1, value: dec("7"),
                        unitCost: dec("6400"), waste: dec("0"),
                        material: "Timber", trade: "Carpentry"),
            TakeoffSeed("Window", "W-02", .count,
                        page: 0, zone: 1, value: dec("5"),
                        unitCost: dec("8900"), waste: dec("0"),
                        material: "Glass", trade: "Glazing"),

            // MARK: Sheet A-102, Second Floor — Open Office
            TakeoffSeed("Interior Partition", "Wall Type B", .polylength,
                        page: 1, zone: 2, value: dec("31.85"),
                        unitCost: dec("795"), waste: dec("0.05"),
                        material: "Gypsum", trade: "Carpentry"),
            TakeoffSeed("Glazed Partition", "Meeting Room 201", .length,
                        page: 1, zone: 2, value: dec("9.60"),
                        unitCost: dec("3400"), waste: dec("0.02"),
                        material: "Glass", trade: "Glazing"),
            TakeoffSeed("Skirting Board", "Open Office", .perimeter,
                        page: 1, zone: 2, value: dec("42.15"),
                        unitCost: dec("145"), waste: dec("0.08"),
                        material: "Timber", trade: "Carpentry"),
            TakeoffSeed("Carpet Tile", "Open Office", .area,
                        page: 1, zone: 2, value: dec("96.30"), perimetre: dec("42.15"),
                        unitCost: dec("410"), waste: dec("0.07"),
                        material: "Carpet", trade: "Flooring"),
            TakeoffSeed("Carpet Tile", "Meeting Room 201", .area,
                        page: 1, zone: 2, value: dec("28.75"), perimetre: dec("21.60"),
                        unitCost: dec("410"), waste: dec("0.07"),
                        material: "Carpet", trade: "Flooring"),
            TakeoffSeed("Suspended Ceiling", "Open Office", .rectangleArea,
                        page: 1, zone: 2, value: dec("96.30"), perimetre: dec("42.15"),
                        unitCost: dec("540"), waste: dec("0.06"),
                        material: "Mineral Fibre", trade: "Ceilings"),
            TakeoffSeed("Ceramic Tile", "WC 202", .area,
                        page: 1, zone: 2, value: dec("7.90"), perimetre: dec("11.40"),
                        unitCost: dec("890"), waste: dec("0.10"),
                        material: "Ceramic", trade: "Flooring"),
            TakeoffSeed("Roof Light Well", "South Pitch", .trueSlopedArea,
                        page: 1, zone: 2, value: dec("18.65"), perimetre: dec("17.90"),
                        unitCost: dec("1450"), waste: dec("0.05"),
                        material: "Steel", trade: "Mechanical"),
            TakeoffSeed("Power Outlet", "Type G", .count,
                        page: 1, zone: 2, value: dec("26"),
                        unitCost: dec("420"), waste: dec("0"),
                        material: "Electrical", trade: "Electrical"),
            TakeoffSeed("Data Outlet", "RJ45", .count,
                        page: 1, zone: 2, value: dec("22"),
                        unitCost: dec("560"), waste: dec("0"),
                        material: "Electrical", trade: "Electrical"),
            TakeoffSeed("Ceiling Luminaire", "LED 1200", .count,
                        page: 1, zone: 2, value: dec("24"),
                        unitCost: dec("1250"), waste: dec("0"),
                        material: "Electrical", trade: "Electrical"),
            TakeoffSeed("Sprinkler Head", "Pendant", .count,
                        page: 1, zone: 2, value: dec("14"),
                        unitCost: dec("720"), waste: dec("0"),
                        material: "Steel", trade: "Mechanical"),
            TakeoffSeed("Door Single", "D-01", .count,
                        page: 1, zone: 2, value: dec("9"),
                        unitCost: dec("6400"), waste: dec("0"),
                        material: "Timber", trade: "Carpentry"),

            // MARK: Sheet S-201, Foundation — Grid A to D
            TakeoffSeed("Slab on Grade", "Pour A", .volume,
                        page: 2, zone: 3, value: dec("42.30"), depth: dec("0.30"),
                        unitCost: dec("2450"), waste: dec("0.03"),
                        material: "Concrete", trade: "Concrete"),
            TakeoffSeed("Slab on Grade", "Pour B", .volume,
                        page: 2, zone: 3, value: dec("28.65"), depth: dec("0.30"),
                        unitCost: dec("2450"), waste: dec("0.03"),
                        material: "Concrete", trade: "Concrete"),
            TakeoffSeed("Strip Footing", "Grid A", .volume,
                        page: 2, zone: 3, value: dec("6.72"), depth: dec("0.60"),
                        unitCost: dec("3100"), waste: dec("0.04"),
                        material: "Concrete", trade: "Concrete",
                        scaleRegionName: footingRegionName),
            TakeoffSeed("Strip Footing", "Grid B", .volume,
                        page: 2, zone: 3, value: dec("5.94"), depth: dec("0.60"),
                        unitCost: dec("3100"), waste: dec("0.04"),
                        material: "Concrete", trade: "Concrete",
                        scaleRegionName: footingRegionName),
            TakeoffSeed("Column Pad", "P1", .volume,
                        page: 2, zone: 3, value: dec("1.35"), depth: dec("0.45"),
                        unitCost: dec("3450"), waste: dec("0.04"),
                        material: "Concrete", trade: "Concrete"),
            TakeoffSeed("Formwork", "Perimeter Edge", .area,
                        page: 2, zone: 3, value: dec("18.40"), perimetre: dec("61.20"),
                        unitCost: dec("620"), waste: dec("0.09"),
                        material: "Timber", trade: "Concrete"),
            TakeoffSeed("Rebar Mesh", "Slab A", .area,
                        page: 2, zone: 3, value: dec("141.00"), perimetre: dec("48.60"),
                        unitCost: dec("185"), waste: dec("0.05"),
                        material: "Steel", trade: "Reinforcement"),
            TakeoffSeed("Pile Cap", "PC-1", .count,
                        page: 2, zone: 3, value: dec("8"),
                        unitCost: dec("12500"), waste: dec("0"),
                        material: "Concrete", trade: "Concrete")
        ]
    }
}
#endif
