import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// The `/OCProperties` layer catalogue: tree parsing, default visibility, lock state,
/// `/Order` nesting, radio groups, duplicate names, broken references, and the
/// effective-visibility rule the persistence overrides feed.
@Suite("Layer tree")
struct LayerTreeTests {

    // MARK: - Parsing the three-layer fixture

    @Test("The three-layer fixture parses to the catalogue its manifest declares")
    func parsesThreeLayerFixture() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }

        let tree = try #require(try await provider.layerTree(of: opened.handle))
        #expect(tree.layers.count == 4)
        #expect(tree.layers.map(\.name) == ["Walls", "Doors", "Grid", "Walls"])
        #expect(tree.layers.map(\.id) == [
            .ocg(atIndex: 0), .ocg(atIndex: 1), .ocg(atIndex: 2), .ocg(atIndex: 3)
        ])
        #expect(tree.layers.map(\.isVisibleByDefault) == [true, true, false, true])
        #expect(tree.layers.map(\.isLockedByDefault) == [false, false, true, false])
        #expect(!tree.scanWasTruncated)
    }

    @Test("Duplicate layer names are preserved, never merged")
    func duplicateNamesAreDistinctLayers() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }

        let tree = try #require(try await provider.layerTree(of: opened.handle))
        let walls = tree.layers.filter { $0.name == "Walls" }
        #expect(walls.count == 2)
        #expect(Set(walls.map(\.id)).count == 2, "same name, distinct identities")
    }

    @Test("/Order nesting puts Doors under Walls and every layer stays reachable")
    func orderNesting() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }

        let tree = try #require(try await provider.layerTree(of: opened.handle))
        #expect(tree.outline.count == 3, "Walls (with child), Grid, duplicate Walls")
        let wallsNode = try #require(tree.outline.first)
        #expect(wallsNode.layerID == .ocg(atIndex: 0))
        #expect(wallsNode.children.map(\.layerID) == [.ocg(atIndex: 1)])
        #expect(tree.outline[1].layerID == .ocg(atIndex: 2))
        #expect(tree.outline[2].layerID == .ocg(atIndex: 3))

        // Every layer id appears somewhere in the outline.
        var reachable: Set<PDFLayerID> = []
        func walk(_ nodes: [PDFLayerNode]) {
            for node in nodes {
                if let id = node.layerID { reachable.insert(id) }
                walk(node.children)
            }
        }
        walk(tree.outline)
        #expect(reachable == Set(tree.layers.map(\.id)))
    }

    @Test("/RBGroups reports the Doors-Grid radio group")
    func radioGroups() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }

        let tree = try #require(try await provider.layerTree(of: opened.handle))
        #expect(tree.radioGroups == [[.ocg(atIndex: 1), .ocg(atIndex: 2)]])
    }

    @Test("/Usage hints are reported: Grid declares view and print both off")
    func usageHints() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }

        let tree = try #require(try await provider.layerTree(of: opened.handle))
        let grid = try #require(tree.layer(.ocg(atIndex: 2)))
        #expect(grid.usage.view == false)
        #expect(grid.usage.print == false)
        #expect(grid.usage.export == nil)
        let walls = try #require(tree.layer(.ocg(atIndex: 0)))
        #expect(walls.usage.isEmpty)
    }

    @Test("Page bindings join marked-content property names back to layer identity")
    func pageBindings() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }

        let tree = try #require(try await provider.layerTree(of: opened.handle))
        let binding = try #require(tree.pageBindings.first { $0.pageIndex == 0 })
        #expect(binding.propertyNamesByLayer[.ocg(atIndex: 0)] == ["L0"])
        #expect(binding.propertyNamesByLayer[.ocg(atIndex: 1)] == ["L1"])
        #expect(binding.propertyNamesByLayer[.ocg(atIndex: 2)] == ["L2"])
        #expect(binding.propertyNamesByLayer[.ocg(atIndex: 3)] == ["L3"])
    }

    // MARK: - No layers, broken layers

    @Test("A document without /OCProperties has no layer tree, and that is not an error")
    func missingOCPropertiesIsNil() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        defer { Task { await provider.close(opened.handle) } }
        let tree = try await provider.layerTree(of: opened.handle)
        #expect(tree == nil)
    }

    @Test("A broken /OCGs reference is a typed error, not a trap and not a phantom layer")
    func brokenReferenceIsTypedError() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.brokenLayerReference))
        defer { Task { await provider.close(opened.handle) } }
        await #expect {
            _ = try await provider.layerTree(of: opened.handle)
        } throws: { error in
            guard let bridgeError = error as? PDFBridgeError,
                  case .layerCatalogUnreadable = bridgeError else { return false }
            return true
        }
    }

    // MARK: - Effective visibility

    @Test("Effective visibility is the document default overridden by project settings")
    func effectiveVisibility() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }
        let tree = try #require(try await provider.layerTree(of: opened.handle))

        // No overrides: the document defaults.
        let defaults = tree.effectiveVisibility(overrides: [:])
        #expect(defaults == [
            .ocg(atIndex: 0): true, .ocg(atIndex: 1): true,
            .ocg(atIndex: 2): false, .ocg(atIndex: 3): true
        ])
        #expect(tree.effectiveVisibilityMatchesDocumentDefault(overrides: [:]))

        // Project hides Walls and shows the default-hidden Grid.
        let overrides = ["ocg:0": false, "ocg:2": true]
        let effective = tree.effectiveVisibility(overrides: overrides)
        #expect(effective == [
            .ocg(atIndex: 0): false, .ocg(atIndex: 1): true,
            .ocg(atIndex: 2): true, .ocg(atIndex: 3): true
        ])
        #expect(!tree.effectiveVisibilityMatchesDocumentDefault(overrides: overrides))

        // An override that only restates the default still matches the default.
        #expect(tree.effectiveVisibilityMatchesDocumentDefault(overrides: ["ocg:1": true]))

        // A stale override from an older revision is ignored, not an error.
        let stale = tree.effectiveVisibility(overrides: ["ocg:99": false])
        #expect(stale == defaults)
        // The lock state is the document's own — there are no project lock overrides (V-097,
        // W-057): the third layer, Grid, is locked and nothing else.
        #expect(tree.layers.filter(\.isLockedByDefault).map(\.id) == [.ocg(atIndex: 2)])
    }

    @Test("Hidden marked-content names feed the snap filter, per page")
    func hiddenMarkedContentNames() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeLayers))
        defer { Task { await provider.close(opened.handle) } }
        let tree = try #require(try await provider.layerTree(of: opened.handle))

        let defaults = tree.effectiveVisibility(overrides: [:])
        #expect(tree.hiddenMarkedContentNames(onPageIndex: 0, effectiveVisibility: defaults) == ["L2"])

        let effective = tree.effectiveVisibility(overrides: ["ocg:0": false, "ocg:2": true])
        #expect(
            tree.hiddenMarkedContentNames(onPageIndex: 0, effectiveVisibility: effective) == ["L0"]
        )
        #expect(tree.hiddenMarkedContentNames(onPageIndex: 7, effectiveVisibility: defaults).isEmpty)
    }

    // MARK: - A heavy A1 drawing without layers

    /// The Synthetic Roof Plan (`ZPDFTestingSupport`) is a vector sheet like a CAD export
    /// written without layers: the file contains **no** optional-content structures at all —
    /// no `/OCProperties`, no `/Properties` resources, no `BDC` in the byte stream — but
    /// 16 341 vector primitives, text and two masked raster images. A heavy page is still not a
    /// layered one, and this test pins that the bridge invents no layer tree for it, so the app
    /// tier's layer panel correctly shows none. (Its layered variant is
    /// `synthetic-roof-plan-layered`, with two groups.)
    @Test("A heavy A1 drawing without optional content declares no layers")
    func roofPlanHasNoLayerCatalogue() async throws {
        let url = try ZPDFFixtures.shared(.syntheticRoofPlan).url
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "expected the synthetic roof plan at \(url.path)"
        )
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        defer { Task { await provider.close(opened.handle) } }
        #expect(opened.descriptor.pageCount == 1)
        let tree = try await provider.layerTree(of: opened.handle)
        #expect(tree == nil, "the roof plan has no /OCProperties; a non-nil tree is an invention")
    }
}
