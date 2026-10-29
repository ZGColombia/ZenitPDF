import Foundation
import ZPDFContracts

/// Page label and 0-based index, as the ledger shows them (spec 15.2).
public struct LedgerPageInfo: Hashable, Sendable {
    public var label: String
    public var index: Int

    public init(label: String, index: Int) {
        self.label = label
        self.index = index
    }
}

/// The names behind the ids a `MarkupRecord` carries.
///
/// A markup stores a `ZoneID`, not the word "Basement". Resolving the name is a project-level
/// lookup, so the store takes the whole table up front rather than calling back into a database
/// per cell — a callback per cell is how a 100 000-row scroll becomes a 100 000-query scroll.
public struct LedgerNameCatalog: Hashable, Sendable {
    public var pages: [PageID: LedgerPageInfo]
    public var zones: [ZoneID: String]
    public var layers: [LayerID: String]
    public var scaleRegions: [ScaleRegionID: String]
    public var scales: [ScaleID: String]

    public init(
        pages: [PageID: LedgerPageInfo] = [:],
        zones: [ZoneID: String] = [:],
        layers: [LayerID: String] = [:],
        scaleRegions: [ScaleRegionID: String] = [:],
        scales: [ScaleID: String] = [:]
    ) {
        self.pages = pages
        self.zones = zones
        self.layers = layers
        self.scaleRegions = scaleRegions
        self.scales = scales
    }

    public static let empty = LedgerNameCatalog()
}
