import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// A deterministic list of pointer samples (`QUALITY_BAR` 3.3 step 1).
///
/// Paths are generated, never captured from a human, so they are byte-reproducible. A sample is
/// `(view point, zoom, modifiers)`; there is no timestamp, because the engine may not depend on
/// one and a fixture that carries one invites a future version to start.
public struct SnapPointerPath: Sendable, Hashable {

    public struct Sample: Sendable, Hashable {
        public var viewPoint: CGPoint
        public var zoom: Double
        public var backingScale: Double
        public var modifiers: SnapModifiers

        public init(
            viewPoint: CGPoint,
            zoom: Double,
            backingScale: Double = 2.0,
            modifiers: SnapModifiers = .none
        ) {
            self.viewPoint = viewPoint
            self.zoom = zoom
            self.backingScale = backingScale
            self.modifiers = modifiers
        }
    }

    public var name: String
    public var samples: [Sample]

    public init(name: String, samples: [Sample]) {
        self.name = name
        self.samples = samples
    }

    /// Turns the path into engine events for a given page layout anchor.
    public func events(
        anchor: CGPoint = .zero,
        isViewFlipped: Bool = false,
        anchorPagePoint: PDFPoint? = nil,
        activeLayerID: String? = nil
    ) throws -> [SnapPointerEvent] {
        var result: [SnapPointerEvent] = []
        result.reserveCapacity(samples.count)
        for (offset, sample) in samples.enumerated() {
            let layout = PageViewLayout(
                anchor: anchor,
                zoom: sample.zoom,
                backingScale: sample.backingScale,
                isViewFlipped: isViewFlipped
            )
            try layout.validate()
            result.append(
                SnapPointerEvent(
                    viewPoint: sample.viewPoint,
                    layout: layout,
                    modifiers: sample.modifiers,
                    anchorPagePoint: anchorPagePoint,
                    activeLayerID: activeLayerID,
                    sequence: offset
                )
            )
        }
        return result
    }

    // MARK: - Path families of QUALITY_BAR 3.3

    /// A straight traverse in view space from `from` to `to`, inclusive of both ends.
    public static func traverse(
        name: String,
        from: CGPoint,
        to: CGPoint,
        steps: Int,
        zoom: Double,
        backingScale: Double = 2.0
    ) -> SnapPointerPath {
        var samples: [Sample] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...Swift.max(1, steps) {
            let t = Double(i) / Double(Swift.max(1, steps))
            samples.append(
                Sample(
                    viewPoint: CGPoint(
                        x: from.x + (to.x - from.x) * t,
                        y: from.y + (to.y - from.y) * t
                    ),
                    zoom: zoom,
                    backingScale: backingScale
                )
            )
        }
        return SnapPointerPath(name: name, samples: samples)
    }

    /// Dither about `centre` along `direction`, with a fixed amplitude in view points.
    ///
    /// The waveform is a deterministic pseudo-random sequence from a 64-bit LCG seeded by the
    /// path name, so it is jagged like a real hand tremor but identical on every machine. It is
    /// not `SystemRandomNumberGenerator`, which is seeded per process.
    public static func dither(
        name: String,
        centre: CGPoint,
        direction: CGVector,
        amplitudeViewPoints: Double,
        sampleCount: Int,
        zoom: Double,
        backingScale: Double = 2.0
    ) -> SnapPointerPath {
        let length = (direction.dx * direction.dx + direction.dy * direction.dy).squareRoot()
        let ux = length > 0 ? direction.dx / length : 1
        let uy = length > 0 ? direction.dy / length : 0

        var state = SnapDeterministicRandom(seed: name)
        // Clamped like `traverse` and `approach` clamp their step counts: a negative count from
        // a caller's arithmetic is an empty path, not a range trap that kills the test process
        // (BH-669).
        let count = Swift.max(0, sampleCount)
        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            // Uniform on [-amplitude, +amplitude], endpoints included at the extremes of the
            // generator, so a +/-3.9 dither really does reach 3.9.
            let offset = (state.nextUnitDouble() * 2 - 1) * amplitudeViewPoints
            samples.append(
                Sample(
                    viewPoint: CGPoint(x: centre.x + ux * offset, y: centre.y + uy * offset),
                    zoom: zoom,
                    backingScale: backingScale
                )
            )
        }
        return SnapPointerPath(name: name, samples: samples)
    }

    /// A slow spiral approach into a cluster, used for the eight-primitive cluster path.
    public static func approach(
        name: String,
        target: CGPoint,
        startDistance: Double,
        steps: Int,
        zoom: Double,
        backingScale: Double = 2.0
    ) -> SnapPointerPath {
        var samples: [Sample] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...Swift.max(1, steps) {
            let t = Double(i) / Double(Swift.max(1, steps))
            let distance = startDistance * (1 - t)
            let angle = Double.pi / 4
            samples.append(
                Sample(
                    viewPoint: CGPoint(
                        x: target.x + CGFloat(distance * Foundation.cos(angle)),
                        y: target.y + CGFloat(distance * Foundation.sin(angle))
                    ),
                    zoom: zoom,
                    backingScale: backingScale
                )
            )
        }
        return SnapPointerPath(name: name, samples: samples)
    }
}

/// A small, explicit, seedable generator.
///
/// `SystemRandomNumberGenerator` is seeded from the OS and `Hasher` is seeded per process;
/// neither can appear anywhere near a fixture that 20 separate processes must agree on.
/// This is `splitmix64`, chosen because its state transition is one line and its output is
/// well distributed enough for jitter.
public struct SnapDeterministicRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    /// Seeds from a string with FNV-1a, so a path's waveform is a function of its name.
    public init(seed name: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        self.init(seed: hash)
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in `[0, 1]`, inclusive of both ends at the extremes of the generator.
    public mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) / Double((1 as UInt64) << 53)
    }

    public mutating func nextInt(below limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        return Int(next() % UInt64(limit))
    }
}
