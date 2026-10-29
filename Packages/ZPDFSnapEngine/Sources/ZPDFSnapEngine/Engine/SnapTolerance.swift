import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry

/// The screen-pixel to page-point conversion of `SNAP_CONTRACT` 13.6, resolved exactly as
/// `QUALITY_BAR` 3.2 requires.
///
/// > The snap radius is defined in AppKit view points, i.e. device-independent points, not
/// > backing-store pixels.
///
/// so
///
/// ```
/// tolerancePageUnits = radiusViewPoints / zoom
/// ```
///
/// and `backingScaleFactor` **does not appear in the formula**. A 10-point radius is the same
/// physical target on a 1x and a 2x display; making it depend on the backing scale would halve
/// the snap target on every Retina Mac, which is every Mac the product ships to.
///
/// The struct is computed **per event**, never cached: zoom can change between two mouse moves,
/// and a tolerance that survives a zoom change is a defect, not an optimisation.
public struct SnapTolerance: Sendable, Hashable {

    /// The clamped radius in view points.
    public let radiusViewPoints: Double

    /// The hysteresis band width in view points (`SNAP_CONTRACT` 13.6, default 4).
    public let hysteresisViewPoints: Double

    public let zoom: Double

    /// Carried for the feedback payload and for the loupe. Not used in any tolerance formula.
    public let backingScale: Double

    /// `radiusViewPoints / zoom`.
    public let radiusPagePoints: Double

    /// `hysteresisViewPoints / zoom`.
    public let hysteresisPagePoints: Double

    /// `(radiusViewPoints + hysteresisViewPoints) / zoom` — the radius a held candidate is
    /// searched for, per `SNAP_CONTRACT` 13.9.
    public let heldRadiusPagePoints: Double

    public init(settings: SnapSettings, layout: PageViewLayout) throws {
        try Self.validate(settings)
        do {
            try layout.validate()
        } catch let error as GeometryError {
            throw SnapEngineError.coordinateConversionFailed(String(describing: error))
        }

        let radius = settings.clampedRadiusPixels(settings.defaultPixels)
        guard radius.isFinite, settings.hysteresisPixels.isFinite else {
            throw SnapEngineError.nonFiniteInput(field: "snapRadius")
        }

        self.radiusViewPoints = radius
        self.hysteresisViewPoints = Swift.max(0, settings.hysteresisPixels)
        self.zoom = layout.zoom
        self.backingScale = layout.backingScale
        self.radiusPagePoints = radius / layout.zoom
        self.hysteresisPagePoints = self.hysteresisViewPoints / layout.zoom
        self.heldRadiusPagePoints = (radius + self.hysteresisViewPoints) / layout.zoom
    }

    /// A page-point distance expressed back in view points. Exact inverse of the conversion
    /// above, so `pageDistance(viewDistance(d)) == d` to the last bit at every zoom.
    public func viewPoints(fromPagePoints distance: Double) -> Double {
        distance * zoom
    }

    public func pagePoints(fromViewPoints distance: Double) -> Double {
        distance / zoom
    }

    static func validate(_ settings: SnapSettings) throws {
        do {
            try settings.validate()
        } catch {
            throw SnapEngineError.invalidSettings(String(describing: error))
        }
    }
}
