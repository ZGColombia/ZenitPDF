import CoreGraphics
import Foundation
import Observation
import Testing
@testable import ZPDFUIShell

/// The shell half of tasks the app tier completes: real Navigator thumbnails
/// (placeholder-then-fill, cached), the Navigator drop policy, the document-layer list
/// model, and the two zoom commands (zoom to selection and marquee zoom).
@Suite("Navigator and zoom shell", .shellTierSerialised)
@MainActor
struct NavigatorAndZoomShellTests {

    private static func makeImage(width: Int = 8, height: Int = 8) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    // MARK: - Thumbnails

    @Test("The loader fills from its provider once, then serves the cache")
    func loaderFillsOnceAndCaches() async throws {
        let loader = NavigatorThumbnailLoader()
        let pageID = UUID()
        var calls: [Int] = []
        loader.provider = { pageIndex, maximumPixelSize in
            calls.append(pageIndex)
            #expect(maximumPixelSize == NavigatorThumbnailLoader.maximumPixelSize)
            return Self.makeImage()
        }

        #expect(loader.image(for: pageID) == nil, "placeholder first: nothing is loaded yet")
        await loader.request(pageID: pageID, pageIndex: 3)
        #expect(loader.image(for: pageID) != nil, "the render fills the placeholder")
        #expect(calls == [3])

        // A second request for a cached page never re-renders.
        await loader.request(pageID: pageID, pageIndex: 3)
        #expect(calls == [3])
    }

    @Test("The cache is LRU-bounded and re-requests after eviction")
    func loaderEvictsLeastRecentlyUsed() async throws {
        let loader = NavigatorThumbnailLoader(capacity: 2)
        loader.provider = { _, _ in Self.makeImage() }
        let first = UUID(), second = UUID(), third = UUID()
        await loader.request(pageID: first, pageIndex: 0)
        await loader.request(pageID: second, pageIndex: 1)
        // Touch `first` so `second` is the least recently used.
        _ = loader.image(for: first)
        await loader.request(pageID: third, pageIndex: 2)
        #expect(loader.cachedCount == 2)
        #expect(loader.image(for: first) != nil)
        #expect(loader.image(for: second) == nil, "the least recently used image is evicted")
        #expect(loader.image(for: third) != nil)
    }

    /// CR-101 — the cache is flushed by a change of SUBJECT, not by an assignment.
    ///
    /// This test used to assert the opposite: that any reassignment of `provider` flushed. That
    /// rule is what made one markup edit re-rasterise every open drawing's thumbnail, because
    /// the application re-installs an equivalent closure on every tab sync — amplified by
    /// `providerRevision`, which then re-ran every visible row's task. A closure is not a
    /// document. Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A re-installed provider for the same subject keeps the cache" recorded an issue
    ///   at NavigatorAndZoomShellTests.swift:98:9: Expectation failed:
    ///   (loader.image(for: pageID) → nil) != nil
    /// ✘ Test "A re-installed provider for the same subject keeps the cache" recorded an issue
    ///   at NavigatorAndZoomShellTests.swift:99:9: Expectation failed: (loader.cachedCount → 0) == 1
    /// ✘ Test "A re-installed provider for the same subject keeps the cache" recorded an issue
    ///   at NavigatorAndZoomShellTests.swift:100:9: Expectation failed:
    ///   (loader.providerRevision → 6) == (revision → 1)
    /// ✘ Test "The identified provider follows the same rule as the page-index one" recorded an
    ///   issue at NavigatorAndZoomShellTests.swift:159:9: Expectation failed:
    ///   (loader.cachedCount → 0) == 1
    /// ```
    @Test("A re-installed provider for the same subject keeps the cache")
    func loaderKeepsTheCacheAcrossAnEquivalentReinstall() async throws {
        let loader = NavigatorThumbnailLoader()
        loader.provider = { _, _ in Self.makeImage() }
        let pageID = UUID()
        await loader.request(pageID: pageID, pageIndex: 0)
        #expect(loader.image(for: pageID) != nil)
        let revision = loader.providerRevision

        // The tab sync, once per sync, for as long as the window is open.
        for _ in 0..<5 { loader.provider = { _, _ in Self.makeImage() } }

        #expect(loader.image(for: pageID) != nil, "five tab syncs threw the raster away")
        #expect(loader.cachedCount == 1)
        #expect(
            loader.providerRevision == revision,
            "every bump re-runs every visible row's `.task`; a tab sync must not bump"
        )
    }

    @Test("A declared change of subject invalidates the cache, and a stale fill is discarded")
    func loaderInvalidatesWhenTheSubjectChanges() async throws {
        let loader = NavigatorThumbnailLoader()
        let first = UUID(), second = UUID()
        loader.setProvider({ _, _ in Self.makeImage() }, identity: first)
        let pageID = UUID()
        await loader.request(pageID: pageID, pageIndex: 0)
        #expect(loader.image(for: pageID) != nil)

        // Same subject, re-declared: nothing is thrown away.
        loader.setProvider({ _, _ in Self.makeImage() }, identity: first)
        #expect(loader.cachedCount == 1)

        // A different subject means a different document: everything cached is gone.
        loader.setProvider({ _, _ in nil }, identity: second)
        #expect(loader.image(for: pageID) == nil)
        #expect(loader.cachedCount == 0)
        #expect(loader.providerIdentity == AnyHashable(second))

        // A provider that fails leaves the placeholder, never a crash or a stale image.
        await loader.request(pageID: pageID, pageIndex: 0)
        #expect(loader.image(for: pageID) == nil)
    }

    @Test("Gaining or losing a provider still invalidates, with no identity declared")
    func loaderInvalidatesWhenTheProviderAppearsOrGoesAway() async throws {
        let loader = NavigatorThumbnailLoader()
        #expect(loader.providerRevision == 0)

        // LT-1: rows that rendered against no provider need their tasks re-run.
        loader.provider = { _, _ in Self.makeImage() }
        #expect(loader.providerRevision == 1)

        let pageID = UUID()
        await loader.request(pageID: pageID, pageIndex: 0)
        #expect(loader.cachedCount == 1)

        loader.provider = nil
        #expect(loader.cachedCount == 0, "images nothing can refresh are not kept")
        #expect(loader.providerRevision == 2)
    }

    @Test("The identified provider follows the same rule as the page-index one")
    func identifiedProviderInvalidatesOnlyOnASubjectChange() async throws {
        let loader = NavigatorThumbnailLoader()
        let a = UUID(), b = UUID()
        let openDrawings: Set<UUID> = [a, b]
        loader.setIdentifiedProvider({ _, _ in Self.makeImage() }, identity: openDrawings)
        await loader.request(id: a)
        #expect(loader.cachedCount == 1)

        // The same set of open drawings, re-declared on every tab sync.
        loader.setIdentifiedProvider({ _, _ in Self.makeImage() }, identity: openDrawings)
        #expect(loader.cachedCount == 1)

        // A drawing closed: the set changed, so the cache goes.
        loader.setIdentifiedProvider({ _, _ in Self.makeImage() }, identity: Set([a]))
        #expect(loader.cachedCount == 0)
    }

    /// Whether a semaphore has already been signalled, without waiting for anything.
    ///
    /// Split out because `DispatchSemaphore.wait(timeout:)` is unavailable from an asynchronous
    /// context — correctly, since blocking a cooperative thread is how you deadlock a test suite.
    /// A zero timeout inside a synchronous function cannot block, and this is the only shape that
    /// reads a `@Sendable` closure's effect under the Swift 6 language mode without an
    /// `@unchecked Sendable` box, which this repository does not allow.
    private static func hasFired(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    /// The thumbnail render loop, as an assertion rather than as a nine-minute hang.
    ///
    /// `NavigatorPageThumbnail.sheet` reads the cache from inside a SwiftUI `body`. If that read
    /// reports a change to the observation the same body registered, the body is invalidated by
    /// its own evaluation and SwiftUI re-runs it for ever — which is what put the Navigator at
    /// 99.4 % CPU as soon as one real thumbnail had landed. This reproduces the shape of that
    /// dependency with `withObservationTracking`: read, then read again, and require silence.
    @Test("A cache read must not report a change to the view that performed it")
    func imageLookupDoesNotInvalidateItsOwnReader() async throws {
        let loader = NavigatorThumbnailLoader()
        loader.provider = { _, _ in Self.makeImage() }
        let first = UUID(), second = UUID()
        await loader.request(pageID: first, pageIndex: 0)
        await loader.request(pageID: second, pageIndex: 1)
        #expect(loader.cachedCount == 2, "the loop needs a filled cache before it can start")

        // A semaphore rather than a captured `var`: `onChange` is `@Sendable`, so under the Swift 6
        // language mode it may not mutate captured local state. `DispatchSemaphore` is `Sendable`,
        // the signal is synchronous with the mutation, and a zero timeout turns "did it fire?"
        // into a value without waiting for anything.
        let reportedChange = DispatchSemaphore(value: 0)
        withObservationTracking {
            _ = loader.image(for: first)
            _ = loader.image(for: second)
        } onChange: {
            reportedChange.signal()
        }

        // The next body evaluation. Before the fix this touched the observed LRU array and woke
        // the tracker that the previous evaluation had installed.
        _ = loader.image(for: first)
        _ = loader.image(for: second)
        #expect(
            Self.hasFired(reportedChange) == false,
            "a cache read invalidated its own reader — a render loop"
        )

        // The array is still maintained, so silence was not bought by deleting the bookkeeping:
        // a third page still fills and is still counted. `loaderEvictsLeastRecentlyUsed` above
        // owns the eviction claim, at capacity 2, and it still passes.
        let third = UUID()
        await loader.request(pageID: third, pageIndex: 2)
        #expect(loader.cachedCount == 3)
    }

    // MARK: - Navigator drops

    // NL-PLAT-04/05 widened the policy: drawing images and DXF/DWG are admitted too (a DWG then
    // gets the sentence naming the way forward). `.txt` stays refused.
    @Test("The drop policy admits the openable types, order preserved")
    func dropPolicyFilters() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.dwg"),
            URL(fileURLWithPath: "/tmp/c.ZPDFPROJ"),
            URL(fileURLWithPath: "/tmp/d.PDF"),
            URL(fileURLWithPath: "/tmp/e.txt")
        ]
        let accepted = NavigatorDropPolicy.acceptedURLs(urls)
        #expect(accepted.map(\.lastPathComponent) == ["a.pdf", "b.dwg", "c.ZPDFPROJ", "d.PDF"])
        #expect(NavigatorDropPolicy.acceptedURLs([URL(fileURLWithPath: "/tmp/e.txt")]).isEmpty)
    }

    @Test("A navigator drop reaches the environment hook with its insertion index")
    func dropHookReceivesInsertionIndex() {
        let environment = ProjectShellEnvironment.mock()
        var received: (urls: [URL], index: Int)?
        environment.onNavigatorDropFiles = { urls, index in
            received = (urls, index)
            return true
        }
        let urls = [URL(fileURLWithPath: "/tmp/plan.pdf")]
        #expect(environment.onNavigatorDropFiles?(urls, 2) == true)
        #expect(received?.urls == urls)
        #expect(received?.index == 2)
    }

    // MARK: - Document layers (gap 10)

    @Test("The layer list renders applied rows and reports toggles without flipping itself")
    func layerListModelRoundTrip() {
        let model = NavigatorLayerListModel()
        #expect(model.rows.isEmpty)
        var toggles: [(String, Bool)] = []
        model.onSetVisible = { id, visible in toggles.append((id, visible)) }

        model.apply(rows: [
            NavigatorLayerRow(id: "ocg:0", name: "Walls", isVisible: true),
            NavigatorLayerRow(id: "ocg:2", name: "Grid", isVisible: false, isLocked: true)
        ])
        #expect(!model.rows.isEmpty)
        #expect(model.rows.map(\.name) == ["Walls", "Grid"])

        // The toggle is a report, not a mutation: the row flips only when the app tier
        // applies the new effective state, so the checkbox never lies about what is in force.
        model.setVisible(false, layerID: "ocg:0")
        #expect(toggles.count == 1)
        #expect(toggles.first?.0 == "ocg:0")
        #expect(toggles.first?.1 == false)
        #expect(model.rows.first?.isVisible == true)

        model.apply(rows: [
            NavigatorLayerRow(id: "ocg:0", name: "Walls", isVisible: false),
            NavigatorLayerRow(id: "ocg:2", name: "Grid", isVisible: false, isLocked: true)
        ])
        #expect(model.rows.first?.isVisible == false)
    }

    // MARK: - Zoom commands

    @Test("Zoom to Selection is declared on the plan's chord and forwarded to the app tier")
    func zoomToSelectionCommand() {
        let table = ZPDFCommandTable.standard
        let command = table.command(.zoomToSelection)
        #expect(command != nil)
        #expect(command?.binding?.displayString == "\u{2318}*")
        #expect(command?.group == .view)
        #expect(table.conflicts().isEmpty)

        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        environment.perform(.zoomToSelection)
        #expect(forwarded == [.zoomToSelection], "the canvas owns the scroll geometry")
    }

    @Test("The Zoom tool exists, is armable, and sits in the toolbar's selectable set")
    func zoomToolIsFirstClass() {
        let environment = ProjectShellEnvironment.mock()
        environment.perform(.zoomTool)
        #expect(environment.toolbar.activeTool == .zoom)
        #expect(!environment.toolbar.showsMeasurementControls)
        #expect(ZenitToolbarBuilder.allowedItemIdentifiers.contains(.zenitZoom))
        #expect(ZenitToolbarBuilder.defaultItemIdentifiers.contains(.zenitZoom))
        #expect(ZenitToolbarBuilder.selectableItemIdentifiers.contains(.zenitZoom))
        #expect(
            ZenitToolbarBuilder.selectionIdentifier(for: .zoom, lastUsedMeasurement: .length)
                == .zenitZoom
        )
        // Arming zoom must disarm a measurement in progress, like every non-measure tool.
        environment.toolbar.activateMeasurement(.length)
        environment.perform(.zoomTool)
        #expect(environment.toolbar.activeTool == .zoom)
    }
}
