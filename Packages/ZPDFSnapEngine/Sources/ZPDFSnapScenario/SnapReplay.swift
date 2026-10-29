import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// Drives the engine over a list of events and collects the resolutions.
///
/// Every stability and determinism assertion in the suite runs over this log rather than over
/// engine internals, which is what `QUALITY_BAR` 3.3 step 3 requires: "assertions run over the
/// log, not over screenshots" — and not over private state either.
public enum SnapReplay {

    public struct Run: Sendable {
        public let resolutions: [SnapResolution]
        public let engine: SnapEngine

        /// The winning candidate key of every event, `nil` where nothing won.
        public var winners: [SnapCandidateKey?] {
            resolutions.map { resolution in
                resolution.winner.map {
                    SnapCandidateKey(
                        kind: $0.kind,
                        primitiveID: $0.primitiveID,
                        secondaryPrimitiveID: nil,
                        position: $0.position
                    )
                }
            }
        }

        /// What makes two consecutive winners the same decision.
        ///
        /// A fixed target is its point: the same endpoint re-derived from a different primitive
        /// is not a switch, and the positional key encodes that. A target that follows the
        /// cursor — the nearest point on an edge — has a new position at every event, so its
        /// position cannot identify it; it is the edge it lies on, exactly as the engine's own
        /// hysteresis identity says (BH-218). Keyed on the position, a winner held along one
        /// segment counted a switch per event.
        enum SwitchKey: Hashable {
            case point(SnapCandidateKey.PositionalKey)
            case edge(SnapCandidateKey.Identity)
        }

        static func switchKey(_ resolution: SnapResolution) -> SwitchKey? {
            if let key = resolution.winnerKey {
                return key.followsCursor ? .edge(key.identity) : .point(key.positional)
            }
            return resolution.winner.map {
                .point(
                    SnapCandidateKey(
                        kind: $0.kind,
                        primitiveID: $0.primitiveID,
                        secondaryPrimitiveID: nil,
                        position: $0.position
                    ).positional
                )
            }
        }

        /// The number of times the winner changed identity between consecutive events.
        ///
        /// This is the "switch" that `QUALITY_BAR` S9 counts; see ``SwitchKey`` for what
        /// identity means here.
        public var switchCount: Int { switchIndices.count }

        /// The index of every event at which the winner changed identity.
        ///
        /// Events with no winner are skipped rather than counted: losing the snap in a gap and
        /// reacquiring the same point on the far side is one continuous decision, not two
        /// switches, and counting it as two would let a passing engine fail S9 for the wrong
        /// reason.
        public var switchIndices: [Int] {
            var result: [Int] = []
            var previous: SwitchKey?
            for (offset, resolution) in resolutions.enumerated() {
                guard let current = Self.switchKey(resolution) else { continue }
                if let previous, previous != current { result.append(offset) }
                previous = current
            }
            return result
        }

        public var log: [String] { resolutions.map(\.decision.logLine) }
    }

    public static func run(
        index: SnapIndex,
        events: [SnapPointerEvent],
        settings: SnapSettings = .default,
        weights: SnapScoringWeights = .standard,
        engine: SnapEngine = SnapEngine(),
        beforeEach: ((Int, inout SnapEngine) -> Void)? = nil
    ) throws -> Run {
        var engine = engine
        var resolutions: [SnapResolution] = []
        resolutions.reserveCapacity(events.count)
        for (offset, event) in events.enumerated() {
            beforeEach?(offset, &engine)
            resolutions.append(
                try engine.resolve(
                    SnapQuery(event: event, settings: settings, weights: weights),
                    in: index
                )
            )
        }
        return Run(resolutions: resolutions, engine: engine)
    }

    /// The view point that corresponds to a page point under a layout, through the real
    /// converter — so a test can write its cursor positions in page space.
    public static func viewPoint(
        _ point: PDFPoint, page: PageDescriptor, layout: PageViewLayout
    ) throws -> CGPoint {
        try PageCoordinateConverter(page: page, layout: layout).pageToView(point)
    }

    /// A layout with the page anchored at the view origin.
    public static func layout(zoom: Double, backingScale: Double = 2.0) -> PageViewLayout {
        PageViewLayout(
            anchor: .zero, zoom: zoom, backingScale: backingScale, isViewFlipped: false
        )
    }

    /// Builds events from a list of page-space cursor positions.
    public static func events(
        pagePoints: [PDFPoint],
        page: PageDescriptor,
        zoom: Double,
        backingScale: Double = 2.0,
        modifiers: SnapModifiers = .none,
        anchorPagePoint: PDFPoint? = nil,
        activeLayerID: String? = nil
    ) throws -> [SnapPointerEvent] {
        let layout = layout(zoom: zoom, backingScale: backingScale)
        var result: [SnapPointerEvent] = []
        result.reserveCapacity(pagePoints.count)
        for (offset, point) in pagePoints.enumerated() {
            result.append(
                SnapPointerEvent(
                    viewPoint: try viewPoint(point, page: page, layout: layout),
                    layout: layout,
                    modifiers: modifiers,
                    anchorPagePoint: anchorPagePoint,
                    activeLayerID: activeLayerID,
                    sequence: offset
                )
            )
        }
        return result
    }
}

extension SnapScene {
    /// A point primitive, the simplest possible snap target: one endpoint, no edges, no
    /// derived geometry to confuse a stability test.
    public static func point(
        id: UInt64, _ position: PDFPoint, confidence: Float = 1.0, layerID: String? = nil
    ) -> SnapPrimitive {
        SnapPrimitive(
            id: id,
            bounds: PDFRect(origin: position, size: .zero),
            kind: .point,
            geometry: .point(position),
            sourceObjectID: id,
            confidence: confidence,
            layerID: layerID
        )
    }
}
