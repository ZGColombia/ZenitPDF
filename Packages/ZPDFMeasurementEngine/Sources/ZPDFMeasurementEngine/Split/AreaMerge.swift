import Foundation
import ZPDFClipper2
import ZPDFContracts

/// The union of measured areas (NL-MEASURE-06's merge), the mirror of ``PolygonSplitter``.
///
/// Each area's **net** region (outer ring minus holes) is unioned through Clipper2 and the rings
/// are reassembled into polygons in the splitter's deterministic order. Areas that touch or
/// overlap come back as one polygon; areas that are apart come back as several, and the caller
/// refuses the merge rather than store one markup that is secretly two shapes.
public enum AreaMerge {

    public static func union(
        _ polygons: [PolygonGeometry],
        options: MeasurementEngineOptions = .default
    ) throws(MeasurementEngineError) -> [PolygonGeometry] {
        guard !polygons.isEmpty else { return [] }
        var paths: ClipperPaths = []
        for polygon in polygons {
            paths.append(contentsOf: try CoverageRegions.netRegion(of: polygon, options: options))
        }
        let merged = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.union(paths, [], fillRule: .nonZero, scale: options.clipperScale)
        }
        return try CoverageRegions.polygons(from: merged, options: options)
    }
}
