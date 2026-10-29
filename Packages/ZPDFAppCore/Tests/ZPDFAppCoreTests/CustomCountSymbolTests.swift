import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Your own count symbols: named, artwork-backed, persisted like tool presets —
/// and frozen into the mark at placement, so editing the symbol never rewrites a count.
///
/// | Rule | Test |
/// |---|---|
/// | A custom symbol round-trips through its preset shape | ``aCustomSymbolRoundTripsThroughItsPreset()`` |
/// | It persists like tool presets and survives save and reopen | ``aCustomSymbolSurvivesSaveAndReopen()`` |
/// | A placed mark keeps the digest it was placed with, whatever happens to the preset | ``aPlacedMarkIsFrozenAtPlacement()`` |
/// | Vector artwork stays the pipeline's vector path — never rasterised | ``vectorArtworkKeepsItsVectorPath()`` |
@Suite("Custom count symbols")
struct CustomCountSymbolTests {

    private static let drainDigest = String(repeating: "a", count: 64)
    private static let valveDigest = String(repeating: "b", count: 64)

    private static func makeDrainSymbol() -> CustomCountSymbol {
        CustomCountSymbol(
            id: UUID(uuidString: "7B00A002-0000-4000-8000-000000000001")!,
            name: "Floor Drain",
            artwork: StampArtworkDescriptor(
                kind: .vector,
                digest: drainDigest,
                byteCount: 2_048,
                sourceName: "drain-symbol.pdf",
                sourcePageIndex: 0
            ),
            colorRGBA: ColorRGBA(red: 0.25, green: 0.5, blue: 1),
            defaultSubject: "Drains"
        )
    }

    // MARK: - The preset shape

    @Test("A custom symbol round-trips through the preset the library stores")
    func aCustomSymbolRoundTripsThroughItsPreset() throws {
        let symbol = Self.makeDrainSymbol()
        let preset = symbol.asPreset(sortIndex: 3)

        #expect(preset.panel == .countSymbols)
        #expect(preset.measurementKind == .count)
        #expect(preset.stamp?.artwork?.digest == Self.drainDigest)
        #expect(preset.stamp?.widthPoints == CountSymbolCatalogue.defaultSizePoints)

        let restored = try #require(CustomCountSymbol(preset: preset))
        #expect(restored == symbol)

        // A preset that is not a custom symbol is not misread as one.
        let glyphCount = try #require(
            DefaultToolSet.presets.first { $0.measurementKind == .count }
        )
        #expect(CustomCountSymbol(preset: glyphCount) == nil,
                "a glyph-faced count preset has no imported artwork")
    }

    @Test("A custom symbol persists like tool presets and survives save and reopen")
    func aCustomSymbolSurvivesSaveAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-count-symbol-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let symbol = Self.makeDrainSymbol()
        // The symbol lives in the library beside ordinary presets, through the same store.
        let library = DefaultToolSet.presets + [symbol.asPreset(sortIndex: 6)]
        let store = ToolPresetContainerStore(directory: directory)
        try await store.write(library)

        // A fresh store over the same directory, as the next launch would read it.
        let reopened = ToolPresetContainerStore(directory: directory)
        let read = try #require(try await reopened.read())
        let restored = CustomCountSymbol.symbols(in: read)
        #expect(restored == [symbol])
        #expect(restored.first?.artwork.digest == Self.drainDigest)
    }

    // MARK: - Frozen at placement

    /// The invariant that editing a symbol never changes a placed mark, driven through the
    /// shipping placement path and the live session:
    /// place a count with the symbol, then re-point the preset at different artwork, and the
    /// placed record still names the digest it was placed with. The preset moved; the mark
    /// did not.
    @Test("A placed mark keeps the digest it was placed with, whatever happens to the preset")
    @MainActor
    func aPlacedMarkIsFrozenAtPlacement() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)

        let symbol = Self.makeDrainSymbol()
        let receipt = await environment.placePreset(
            symbol.asPreset(),
            at: PDFPointValue(x: 300, y: 400),
            pageID: page.id.rawValue
        )
        let markupID = try #require(receipt.markupID, "nothing was placed")

        // Edit the preset to different artwork — the digest changes on the preset…
        var edited = symbol
        edited.artwork = StampArtworkDescriptor(
            kind: .vector,
            digest: Self.valveDigest,
            byteCount: 4_096,
            sourceName: "valve-symbol.pdf",
            sourcePageIndex: 0
        )
        environment.toolLibrary.setPresets([edited.asPreset()])
        let editedResolved = try #require(CountSymbolCatalogue.symbol(for: edited.asPreset()))
        #expect(editedResolved.artworkDigest == Self.valveDigest,
                "the edited preset resolves to the new artwork for the *next* placement")

        // …and the placed record still names the artwork it was placed with.
        let record = try #require(await environment.session.markup(MarkupID(markupID)))
        let placedSymbol = try #require(record.symbol)
        #expect(placedSymbol.artworkDigest == Self.drainDigest,
                "a symbol is resolved at placement and frozen into the markup")
        #expect(placedSymbol.sourceName == "drain-symbol.pdf")
    }

    // MARK: - Vector stays vector

    @Test("Vector artwork keeps the pipeline's vector path and is never rasterised")
    func vectorArtworkKeepsItsVectorPath() throws {
        let symbol = Self.makeDrainSymbol()
        let placed = try #require(symbol.markupSymbol)

        // The mark the placement freezes carries the vector kind — the renderer's structural
        // claim (ADR-0011 §2.4): geometry is multiplied, never resampled.
        #expect(placed.kind == .vector)
        #expect(placed.staysSharpWhenMagnified)
        #expect(placed.artworkDigest == Self.drainDigest)
        #expect(symbol.staysSharpWhenMagnified)

        // A raster source is accepted and says so — the same honesty the stamp editor keeps.
        var rasterSymbol = symbol
        rasterSymbol.artwork = StampArtworkDescriptor(
            kind: .raster,
            digest: Self.valveDigest,
            byteCount: 8_192,
            sourceName: "valve-photo.png",
            pixelWidth: 96,
            pixelHeight: 96
        )
        let rasterPlaced = try #require(rasterSymbol.markupSymbol)
        #expect(rasterPlaced.kind == .raster)
        #expect(!rasterPlaced.staysSharpWhenMagnified)
        #expect(!rasterSymbol.staysSharpWhenMagnified)
    }
}
