import ZPDFCompare

extension RevisionOverlayModel {
    /// A test stack: one distinctly coloured, fully opaque, visible layer per label, ids from 0.
    ///
    /// The engine used to carry a palette of its own for this (`standard(labels:)` over an HSV
    /// helper). Nothing shipped used it — the app builds the model from the interface's layers
    /// — so it was deleted (W-083) and the tests build their stacks here.
    static func testStack(labels: [String], blendMode: OverlayBlendMode = .multiply) -> RevisionOverlayModel {
        let palette = [
            OverlayColor(red: 0.18, green: 0.47, blue: 0.82),
            OverlayColor(red: 0.82, green: 0.30, blue: 0.18),
            OverlayColor(red: 0.20, green: 0.65, blue: 0.30),
            OverlayColor(red: 0.60, green: 0.25, blue: 0.75),
        ]
        return RevisionOverlayModel(layers: labels.enumerated().map { index, label in
            OverlayLayer(id: index, label: label, color: palette[index % palette.count], blendMode: blendMode)
        })
    }
}
