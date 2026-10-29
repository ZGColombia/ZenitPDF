import Foundation

/// Version stamps for the frozen contracts.
///
/// Each number is bumped only through an accepted ADR. Persisted records carry the version they
/// were written with, so a migration can tell exactly which grammar produced a value.
public enum ContractVersion: Sendable {
    /// Version of the whole vocabulary in this package.
    ///
    /// 2: ADR-0014 gave ``QuantityDimension`` a `ratio` tag, so a slope ratio or a waste factor
    /// is no longer the same dimension as a count and can never sum into a count total. The
    /// tag is encoded only when set, so every version-1 payload decodes unchanged — as a count,
    /// which is what its bytes always said; the consumer that knows a stored dimensionless
    /// value is a ratio (``MeasurementResult/init(from:)`` by field, a ledger by column)
    /// re-tags it on load.
    public static let architecture = 2
    /// Version of the measurement field set and result shape.
    ///
    /// 2: ADR-0004 made slope a vector. `MeasurementParameters` carries a
    /// ``SlopeSpecification`` (magnitude, fall-line azimuth, mode) and a
    /// ``VolumeDepthReference``; ``MeasurementField`` gained `truePerimeter` and `planWallArea`.
    ///
    /// 3: ADR-0007 gave every measured value a derivation. ``MeasurementResult`` carries an
    /// optional ``MeasurementProvenance`` (geometry digest, scale id + version + source,
    /// calibration evidence, slope, parameters, formula and engine version, computed-at). A
    /// version-2 result decodes unchanged with a `nil` provenance.
    ///
    /// 4: ADR-0014 made `slopeRatio` and `slopePercent` ratio-dimensioned fields, and
    /// ``MeasurementResult`` re-tags a stored dimensionless value to its field's dimension on
    /// decode. ADR-0015 changed ``MeasurementError/cutoutOutsideParent(cutoutIndex:)`` to name
    /// the cutout rather than a markup the engine never sees, and added
    /// ``MeasurementError/negativeNetArea(_:)``. A version-3 result decodes unchanged.
    ///
    /// 5: ADR-0035. ``MeasurementError`` gained
    /// `coordinateOutOfRange` (the 1e7-point bound of ``MeasurementGeometry``),
    /// ``MeasurementParameterKey`` gained `openingAreas`, and ``MeasurementParameters`` gained the
    /// optional `displayOverride`, encoded only when present. Additive: a version-4 record
    /// decodes unchanged, with no display override.
    public static let measurement = 5
    /// Version of the scale transform storage format.
    ///
    /// 2: a scale belongs to a **page**. ``ScaleTransform`` carries an optional ``PageID``, and
    /// the resolution order for a measurement is *Scale Region containing the geometry, else the
    /// page's own scale, else nothing* — where nothing means the measurement is refused, never
    /// computed against a sibling page's calibration. ``MeasurementProvenance`` records
    /// `scalePageID` alongside `scaleID` so a derivation can name the sheet the scale was
    /// calibrated on. Additive and optional: a version-1 value decodes unchanged with a `nil`
    /// page, and every existing call site of the initialiser and the three factories is
    /// unaffected because the parameter is defaulted. Projects written before this version
    /// record the page on the row (`scale_definition.page_id`, `NOT NULL` since schema v1) and
    /// are migrated by schema v9 rather than reinterpreted at open time.
    public static let scale = 2
    /// Version of the snap primitive/candidate model.
    public static let snap = 1
    /// Version of the markup record model.
    ///
    /// 2: ADR-0010 gave a markup an optional ``StampInstance`` — the template a stamp was
    /// placed from and the dynamic-field values that were resolved at placement and frozen.
    /// Additive and optional: a version-1 record decodes unchanged with a
    /// `nil` stamp, and every existing call site of ``MarkupRecord/init`` is unaffected
    /// because the parameter is defaulted.
    ///
    /// 3: ADR-0011 gave a markup an optional ``MarkupSymbol`` — a *reference* to artwork in
    /// the project's content-addressed store, so a count mark's glyph is a property of the
    /// mark and survives the deletion or editing of the preset that made it (spec 12.13).
    /// Additive and optional on the same terms as version 2.
    ///
    /// 4: ADR-0012 made every row state its claim. ``MarkupRecord`` carries a
    /// ``QuantityProvenance`` (`measured` / `derived` / `read`) and, for the two new cases,
    /// a mandatory ``QuantityDerivation`` (source markup, formula or OCR text verbatim,
    /// inputs by name, origin identifier). Additive: the initializer parameters are
    /// defaulted, and a version-3 record — no `provenance` key at all — decodes as
    /// `.measured` with a `nil` derivation. No migration pass.
    ///
    /// 5: ADR-0029 added optional `MarkupStyle.textStyle`, `cloudArcSize`,
    /// `rotationDegrees` and `blendMode`, and optional `MarkupRecord.groupID` and `link`.
    /// Additive: a version-4 record decodes unchanged with every new field `nil`.
    ///
    /// 6: ADR-0032 added ``MarkupLayer`` — a project's ordered list of markup
    /// layers with visible, locked and printable flags — and gave the long-reserved
    /// ``MarkupRecord/layerID`` its meaning: the layer the markup belongs to, `nil` being the
    /// project's default layer. No field changed shape, so a version-5 record decodes unchanged
    /// and belongs to the default layer.
    public static let markup = 6
    /// Version of the ledger column/row model.
    public static let ledger = 1
    /// Version of the formula grammar.
    public static let formula = 1

    /// The formula version stamped into every ``MeasurementResult`` produced under this contract.
    ///
    /// 2: ADR-0004. Lengths and perimeters on a sloped plane use the per-segment rule
    /// `sqrt(|d|^2 + (s * (d . u))^2)` instead of the scalar `sqrt(1 + s^2)`, so a result stored
    /// at version 1 is detectably from the old, over-measuring model.
    ///
    /// 3: ADR-0015, the 2026-08-31 code review. The perimeter under `outerPlusCutoutEdges` is
    /// the boundary of the net region (CR-21: overlapping or overhanging cutouts no longer
    /// double-count an edge); the angle tool uses `atan2(|cross|, dot)` (CR-26); a per-segment
    /// rise/drop reports the gross vertical travel with the net sign (CR-32); true areas,
    /// volumes and wall areas are normalised to the numeric policy's significance (CR-23);
    /// a pitch's rise and run are no longer stored as metres (CR-22). A result stored at
    /// version 2 may differ from a recalculation in every one of those fields.
    ///
    /// 4: ADR-0019. The informational tools stop writing fields a
    /// summed ledger column reads: Angle no longer writes `planLength` (its two rays), Radius,
    /// Diameter and Three-Point Circle no longer write `perimeter`, `planArea` or `netArea`
    /// (the disc), and Slope no longer writes `planLength` or `trueLength` (its drawn run). A
    /// result stored at version 3 for one of those tools carries values a recalculation drops.
    ///
    /// 5: ADR-0035. A self-crossing cutout removes the area it
    /// covers instead of its lobes' signed difference (R-166); net and cutout areas come from an
    /// origin-shifted shoelace (R-167); a perpendicular thickness on a flat markup is a volume
    /// instead of a refusal (R-168); arc edges of an area with cutouts count at `r·θ` under
    /// `outerPlusCutoutEdges` (R-181); the ellipse and circle tolerances are tested in page space
    /// (R-183); the angle maps deltas (R-184). A result stored at version 4 may differ from a
    /// recalculation in those fields.
    ///
    /// 6: ADR-0035 §8. A crossing outer ring with an arc edge
    /// stores its normalised region instead of the drawn ring's cancelling lobes (S-105); an arc
    /// edge under a separate X/Y scale is measured (by quadrature) instead of refused (S-106);
    /// the ellipse minor semi-axis is `|det| / major`, so thin ellipses keep their area (S-107);
    /// the net area of an area with several cutouts is measured against the drawn rings, not
    /// their lattice copies (S-108); a per-segment rise follows the pieces in drawn order when a
    /// chain has an arc edge (S-110). A result stored at version 5 may differ from a
    /// recalculation in those fields.
    ///
    /// 7: ADR-0037. A cutout that meets an arc edge, or an arc
    /// cutout that meets another cutout or the outer ring, is subtracted on the arcs instead of
    /// as the chords of a 1e-3 pt flattening, and the boundary under `outerPlusCutoutEdges` is
    /// measured on them too (C-08); the ellipse circumference is the quadrature of the elliptic
    /// integral instead of Ramanujan's approximation (T-074); a round ellipse's semi-axes and
    /// circle test no longer cancel, so Radius and Diameter do not depend on where it is drawn
    /// (T-073); Arc Length measures under a separate X/Y scale instead of refusing (T-075). A
    /// result stored at version 6 may differ from a recalculation in those fields.
    ///
    /// 8: ADR-0041. An arc's true length on a sloped plane is
    /// integrated on the curve instead of scaled by a 1° flattening's ratio — `trueLength`,
    /// `truePerimeter` and a Wall Area's sloped base on arcs, about 6e-6 relative on a 45° arc at
    /// a slope of 1 (X-043); an Ellipse Cutout flush with its parent's edge is subtracted whole
    /// instead of short by the sliver its ring stuck out by (X-044). A result stored at version 7
    /// may differ from a recalculation in those fields.
    public static let measurementFormulaVersion = 8
}
