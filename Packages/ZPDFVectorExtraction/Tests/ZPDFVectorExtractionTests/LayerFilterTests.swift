import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Layer identity on primitives, the default-hidden rule, the opt-in that keeps
/// hidden geometry, and the query-time snap filter.
@Suite("Layer visibility filtering")
struct LayerFilterTests {

    /// The three-layer fixture's marked-content property names, from its manifest
    /// notes: L0 Walls (visible), L1 Doors (visible), L2 Grid (hidden by default),
    /// L3 duplicate Walls (visible). One line is unlayered.
    static let wallsName = "L0"
    static let doorsName = "L1"
    static let gridName = "L2"
    static let duplicateName = "L3"

    @Test("Primitives carry their layer identity, and default-hidden geometry is not extracted")
    func defaultExtractionOmitsHiddenLayer() async throws {
        let (extraction, _, directory) = try await ExtractionTestSupport.extract(.threeLayers)
        defer { ExtractionTestSupport.remove(directory) }

        #expect(extraction.layerIDs == [Self.wallsName, Self.doorsName, Self.duplicateName].sorted())
        #expect(
            !extraction.primitives.contains { $0.layerID == Self.gridName },
            "the Grid layer is OFF in the document default; its line must not be a snap target"
        )
        #expect(
            extraction.primitives.contains { $0.layerID == nil },
            "the unlayered line is extracted with no layer identity"
        )
        #expect(extraction.primitives.contains { $0.layerID == Self.wallsName })
        #expect(extraction.primitives.contains { $0.layerID == Self.doorsName })
        #expect(extraction.primitives.contains { $0.layerID == Self.duplicateName })
    }

    @Test("includesHiddenOptionalContent keeps the hidden layer's geometry, layer-tagged")
    func optInKeepsHiddenGeometry() async throws {
        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let (extraction, _, directory) = try await ExtractionTestSupport.extract(
            .threeLayers, options: options
        )
        defer { ExtractionTestSupport.remove(directory) }

        #expect(extraction.layerIDs == [
            Self.wallsName, Self.doorsName, Self.gridName, Self.duplicateName
        ].sorted())
        let gridPrimitives = extraction.primitives.filter { $0.layerID == Self.gridName }
        #expect(!gridPrimitives.isEmpty)
        // The Grid line runs from (100, 300) to (400, 300).
        let line = try #require(gridPrimitives.first { $0.kind == .lineSegment })
        guard case let .line(segment) = line.geometry else {
            Issue.record("expected a line geometry")
            return
        }
        #expect(abs(segment.start.y - 300) <= 1e-9 && abs(segment.end.y - 300) <= 1e-9)
    }

    @Test("The option is part of the cache fingerprint")
    func optionChangesFingerprint() {
        var withHidden = VectorExtractionOptions.standard
        withHidden.includesHiddenOptionalContent = true
        #expect(withHidden.fingerprint != VectorExtractionOptions.standard.fingerprint)
    }

    @Test("The snap filter excludes hidden-layer primitives at query time")
    func filterExcludesHiddenLayers() async throws {
        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let (extraction, _, directory) = try await ExtractionTestSupport.extract(
            .threeLayers, options: options
        )
        defer { ExtractionTestSupport.remove(directory) }

        // Document defaults: Grid hidden.
        let defaults = extraction.primitives(excludingLayerIDs: [Self.gridName])
        #expect(!defaults.contains { $0.layerID == Self.gridName })
        #expect(defaults.contains { $0.layerID == Self.wallsName })
        #expect(defaults.contains { $0.layerID == nil })

        // Project override: Walls off, Grid on.
        let overridden = extraction.primitives(excludingLayerIDs: [Self.wallsName])
        #expect(!overridden.contains { $0.layerID == Self.wallsName })
        #expect(overridden.contains { $0.layerID == Self.gridName })
        #expect(
            overridden.contains { $0.layerID == Self.duplicateName },
            "hiding one 'Walls' layer must not hide the other same-named layer: identity is the property name"
        )

        // The filtered list preserves the original deterministic order.
        let identifiers = overridden.map(\.id)
        #expect(identifiers == identifiers.sorted())
    }

    @Test("The filter can exclude unlayered content, and an empty filter is a no-op")
    func unlayeredContentAndNoOp() async throws {
        let (extraction, _, directory) = try await ExtractionTestSupport.extract(.threeLayers)
        defer { ExtractionTestSupport.remove(directory) }

        let layeredOnly = extraction.primitives(
            visibleUnder: VectorLayerVisibilityFilter(
                hiddenLayerIDs: [], includesUnlayeredContent: false
            )
        )
        #expect(!layeredOnly.isEmpty)
        #expect(layeredOnly.allSatisfy { $0.layerID != nil })

        let unfiltered = extraction.primitives(visibleUnder: .everythingVisible)
        #expect(unfiltered == extraction.primitives)
    }
}
