import AppKit
import ZPDFDesignSystem
import ZPDFUIPresentation

/// A reusable cell for the Quantity Ledger table.
///
/// One cell class serves every column. Numeric columns get trailing alignment and
/// monospaced, tabular digits so a column of quantities reads as a column; text columns
/// get leading alignment. The colour swatch is always paired with text, never used alone
/// to carry meaning.
@MainActor
public final class LedgerCellView: NSTableCellView {

    /// Reuse identifier for the standard cell.
    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("zenit.ledger.cell")

    private let label = NSTextField(labelWithString: "")
    private let swatch = NSView()
    private var swatchWidthConstraint: NSLayoutConstraint?
    private var labelLeadingConstraint: NSLayoutConstraint?
    private var swatchLeadingConstraint: NSLayoutConstraint?
    /// How far the cell's content is stepped in: a child row — a cutout, or a row an assembly
    /// derived — sits one step under its source (NL-QTY-07).
    private(set) var indent: CGFloat = 0

    /// The indent of a child row's leading cell.
    public static let childIndent: CGFloat = ZPDFSpacing.l
    /// The swatch's fill, kept so the layer colours can be re-resolved when the appearance
    /// changes. A `CGColor` is a snapshot of one appearance; the dynamic `NSColor` is not.
    private var swatchColor: NSColor?

    /// Creates the cell.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // The ledger builds its table in code; there is no nib to decode.
        return nil
    }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false

        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = ZPDFRadius.hairline
        swatch.layer?.borderWidth = ZPDFStroke.hairline
        swatch.setAccessibilityElement(false)
        addSubview(swatch)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        addSubview(label)
        textField = label

        let swatchWidth = swatch.widthAnchor.constraint(equalToConstant: 0)
        let labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ZPDFSpacing.s)
        swatchWidthConstraint = swatchWidth
        labelLeadingConstraint = labelLeading
        let swatchLeading = swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ZPDFSpacing.s)
        swatchLeadingConstraint = swatchLeading

        NSLayoutConstraint.activate([
            swatchLeading,
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.heightAnchor.constraint(equalToConstant: 10),
            swatchWidth,
            labelLeading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ZPDFSpacing.s),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Fills the cell from a row.
    ///
    /// - Parameters:
    ///   - text: The already-formatted cell text.
    ///   - column: The column being drawn, which decides alignment and digit style.
    ///   - swatchColor: A colour cue drawn beside the text, or `nil` for no swatch.
    ///   - isDimmed: Whether the row failed the filter and is shown at reduced emphasis.
    ///   - accessibilityLabel: What VoiceOver reads for this cell.
    ///   - helpTag: Why the cell shows an error word — the formula engine's diagnostic (T-057) —
    ///     shown as the help tag and given to VoiceOver as help; `nil` for an ordinary cell.
    public func configure(
        text: String,
        column: LedgerColumn,
        swatchColor: NSColor?,
        isDimmed: Bool,
        accessibilityLabel: String,
        indent: CGFloat = 0,
        helpTag: String? = nil
    ) {
        self.indent = indent
        label.stringValue = text
        label.alignment = Self.nsAlignment(column.alignment)
        label.font = Self.font(for: column)
        label.textColor = isDimmed
            ? ZPDFColor.nsColor(.textSecondary)
            : ZPDFColor.nsColor(.textPrimary)
        label.setAccessibilityLabel(accessibilityLabel)
        applyHelpTag(helpTag)

        applySwatch(swatchColor)
    }

    /// Sets or clears the help tag. A reused cell must never keep another row's diagnostic.
    private func applyHelpTag(_ helpTag: String?) {
        label.toolTip = helpTag
        label.setAccessibilityHelp(helpTag)
    }

    /// Fills the cell as a group heading or a subtotal cell.
    public func configureAsGroup(
        text: String,
        column: LedgerColumn?,
        isHeading: Bool,
        swatchColor: NSColor?,
        accessibilityLabel: String
    ) {
        indent = 0
        label.stringValue = text
        label.alignment = isHeading ? .left : Self.nsAlignment(column?.alignment ?? .trailing)
        label.font = isHeading
            ? ZPDFTypography.nsFont(.sectionHeader)
            : ZPDFTypography.nsFont(.monoNumericStrong)
        label.textColor = ZPDFColor.nsColor(.textPrimary)
        label.setAccessibilityLabel(accessibilityLabel)
        applyHelpTag(nil)

        applySwatch(swatchColor)
    }

    private func applySwatch(_ color: NSColor?) {
        swatchColor = color
        swatchLeadingConstraint?.constant = ZPDFSpacing.s + indent
        if color != nil {
            swatch.isHidden = false
            swatchWidthConstraint?.constant = 10
            labelLeadingConstraint?.constant = ZPDFSpacing.s + indent + 10 + ZPDFSpacing.xs
        } else {
            swatch.isHidden = true
            swatchWidthConstraint?.constant = 0
            labelLeadingConstraint?.constant = ZPDFSpacing.s + indent
        }
        resolveSwatchColors()
    }

    /// Resolves the swatch's layer colours against this cell's own appearance.
    ///
    /// `cgColor` pins whichever variant of a dynamic colour is current when it is read, and
    /// a layer never re-resolves it; the border used to keep its light-mode grey after a
    /// switch to dark until the row scrolled away and was reconfigured (BH-737).
    private func resolveSwatchColors() {
        guard let swatchColor else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            swatch.layer?.backgroundColor = swatchColor.cgColor
            swatch.layer?.borderColor = ZPDFColor.nsColor(.border).cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveSwatchColors()
    }

    /// The swatch border as drawn, for the appearance test. Never used by shipping code.
    var swatchBorderColorForTesting: CGColor? { swatch.layer?.borderColor }

    /// AppKit alignment for a ledger alignment token.
    public static func nsAlignment(_ alignment: LedgerColumnAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    /// The font a column's cells use: tabular digits for anything numeric.
    public static func font(for column: LedgerColumn) -> NSFont {
        LedgerColumnLayout.usesMonospacedDigits(column)
            ? ZPDFTypography.nsFont(.monoNumeric)
            : ZPDFTypography.nsFont(.body)
    }
}
