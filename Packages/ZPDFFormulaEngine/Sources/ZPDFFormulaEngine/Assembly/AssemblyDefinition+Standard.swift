import Foundation
import ZPDFContracts

extension AssemblyDefinition {

    /// The worked example: a timber stud wall.
    ///
    /// Measure one wall and this recipe produces four quantities from it — the wall's area, the
    /// studs at the declared spacing, the plates, and the plasterboard for both faces. It is the
    /// shape every other recipe is a variation on, and it is what the tests are written against.
    ///
    /// | Line | Formula | Produces |
    /// |---|---|---|
    /// | Wall area | `Length * Height` | area (m^2) |
    /// | Studs | `FLOOR(Length / Spacing) + 1` | dimensionless count |
    /// | Plates | `Length * 2` | length (m) |
    /// | Plasterboard both sides | `Length * Height * 2` | area (m^2) |
    ///
    /// # On the stud count
    ///
    /// `FLOOR` is part of the engine's function set, so the count is a whole number by
    /// construction rather than by rounding afterwards. `Length / Spacing` is metres over metres,
    /// which the dimensional algebra resolves to dimensionless, and adding the literal `1` keeps it
    /// that way — the closing stud at the far end, the one an estimator forgets.
    ///
    /// This is the naive spacing count and nothing more: it does not add studs for openings,
    /// corners, junctions or double studs at a joint. Those belong in a recipe of the estimator's
    /// own, which is the whole reason recipes are data rather than code.
    ///
    /// # Its id is fixed
    ///
    /// `5a504446-4153-4d42-0000-000000000001`. It is written out byte by byte rather than parsed
    /// so that there is no optional to unwrap and no way for it to differ between builds. A seeded
    /// example that changed identity would orphan every measurement pointing at it.
    public static let timberStudWall = AssemblyDefinition(
        id: UUID(
            uuid: (
                0x5A, 0x50, 0x44, 0x46, 0x41, 0x53, 0x4D, 0x42,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
            )
        ),
        name: "Timber stud wall",
        note: "Area, studs at spacing, plates and plasterboard from one measured wall.",
        inputs: [
            AssemblyInput(
                name: "Length",
                dimension: .length,
                note: "The wall's length as measured on the drawing."
            ),
            AssemblyInput(
                name: "Height",
                dimension: .length,
                note: "Floor to underside of the head plate."
            ),
            AssemblyInput(
                name: "Spacing",
                dimension: .length,
                note: "Stud spacing, centre to centre. Not measured — the estimator supplies it."
            )
        ],
        lines: [
            AssemblyLine(
                name: "Wall area",
                source: "Length * Height",
                outputDimension: .area,
                note: "One face."
            ),
            AssemblyLine(
                name: "Studs",
                source: "FLOOR(Length / Spacing) + 1",
                outputDimension: .count,
                note: "Studs at spacing, plus the closing stud at the far end."
            ),
            AssemblyLine(
                name: "Plates",
                source: "Length * 2",
                outputDimension: .length,
                note: "Sole plate and head plate."
            ),
            AssemblyLine(
                name: "Plasterboard both sides",
                source: "Length * Height * 2",
                outputDimension: .area,
                note: "Both faces, before any deduction for openings."
            )
        ]
    )
}
