import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The outline shape that stands for a change type.
///
/// Added is a circle, removed is a square, modified is a diamond. The shapes are as different
/// from each other as three simple outlines can be, so the legend survives greyscale printing and
/// every form of colour blindness. Colour is the second cue, never the first.
public struct CompareChangeShape: Shape, Sendable {

    private let kind: CompareChangeKind

    /// Creates the shape for a change type.
    public init(_ kind: CompareChangeKind) {
        self.kind = kind
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        switch kind {
        case .added:
            return Path(ellipseIn: square)
        case .removed:
            return Path(roundedRect: square, cornerRadius: 1.5)
        case .modified:
            var path = Path()
            path.move(to: CGPoint(x: square.midX, y: square.minY))
            path.addLine(to: CGPoint(x: square.maxX, y: square.midY))
            path.addLine(to: CGPoint(x: square.midX, y: square.maxY))
            path.addLine(to: CGPoint(x: square.minX, y: square.midY))
            path.closeSubpath()
            return path
        }
    }
}

/// One legend entry: shape, colour, name, count.
public struct CompareLegendBadge: View {

    private let kind: CompareChangeKind
    private let count: Int?
    private let isOn: Bool

    /// - Parameters:
    ///   - kind: the change type.
    ///   - count: how many of them there are, or `nil` to show no count.
    ///   - isOn: whether this type is currently shown on the canvas.
    public init(kind: CompareChangeKind, count: Int? = nil, isOn: Bool = true) {
        self.kind = kind
        self.count = count
        self.isOn = isOn
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            CompareChangeShape(kind)
                .fill(kind.indicatorColor.swiftUIColor.opacity(isOn ? 0.28 : 0))
                .overlay {
                    CompareChangeShape(kind)
                        .stroke(kind.indicatorColor.swiftUIColor, lineWidth: ZPDFStroke.measurement)
                }
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(kind.displayName)
                .zpdfText(.caption, isOn ? .textPrimary : .textSecondary)
            if let count {
                Text(count.formatted()).zpdfText(.monoNumeric, .textSecondary)
            }
        }
        .padding(.horizontal, ZPDFSpacing.xs)
        .padding(.vertical, 2)
        .opacity(isOn ? 1 : 0.55)
    }
}

/// The whole legend, with each change type toggleable.
public struct CompareLegend: View {

    private let counts: [CompareChangeKind: Int]
    @Binding private var visibleKinds: Set<CompareChangeKind>
    private let canHide: (CompareChangeKind) -> Bool

    /// Creates the legend.
    ///
    /// - Parameters:
    ///   - counts: how many differences of each type exist, shown or hidden.
    ///   - visibleKinds: which types are shown.
    ///   - canHide: whether a shown type may be hidden. The last shown type may not be; its
    ///     button is disabled and says so rather than swallowing the click (finding BH-838).
    public init(
        counts: [CompareChangeKind: Int],
        visibleKinds: Binding<Set<CompareChangeKind>>,
        canHide: @escaping (CompareChangeKind) -> Bool = { _ in true }
    ) {
        self.counts = counts
        self._visibleKinds = visibleKinds
        self.canHide = canHide
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ForEach(CompareChangeKind.allCases) { kind in
                let isOn = visibleKinds.contains(kind)
                let isLastShown = isOn && !canHide(kind)
                Button {
                    if visibleKinds.contains(kind) {
                        guard canHide(kind) else { return }
                        visibleKinds.remove(kind)
                    } else {
                        visibleKinds.insert(kind)
                    }
                } label: {
                    CompareLegendBadge(
                        kind: kind,
                        count: counts[kind] ?? 0,
                        isOn: isOn
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLastShown)
                .accessibilityLabel(Text(kind.displayName))
                .accessibilityValue(Text(accessibilityValue(for: kind)))
                .accessibilityHint(Text(isLastShown ? Self.lastShownExplanation : ""))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                .help(isLastShown ? Self.lastShownExplanation : helpText(for: kind))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Difference types",
            comment: "Accessibility label for the Revision Compare legend"
        )))
    }

    /// Why the last shown type cannot be hidden.
    static let lastShownExplanation = NSLocalizedString(
        "At least one change type stays shown. Show another type before hiding this one.",
        comment: "Help tag and hint for the legend button of the only shown change type"
    )

    private func accessibilityValue(for kind: CompareChangeKind) -> String {
        let count = counts[kind] ?? 0
        let shown = visibleKinds.contains(kind)
            ? NSLocalizedString("shown", comment: "Accessibility value: change type is shown")
            : NSLocalizedString("hidden", comment: "Accessibility value: change type is hidden")
        let format = NSLocalizedString(
            "%1$d, %2$@",
            comment: "Accessibility value for a legend entry: count, visibility"
        )
        return String(format: format, count, shown)
    }

    private func helpText(for kind: CompareChangeKind) -> String {
        switch kind {
        case .added:
            return NSLocalizedString(
                "Drawn on the newer sheet and not on the baseline.",
                comment: "Help tag for the Added change type"
            )
        case .removed:
            return NSLocalizedString(
                "Drawn on the baseline and not on the newer sheet.",
                comment: "Help tag for the Removed change type"
            )
        case .modified:
            return NSLocalizedString(
                "Drawn on both sheets, but not the same.",
                comment: "Help tag for the Modified change type"
            )
        }
    }
}
