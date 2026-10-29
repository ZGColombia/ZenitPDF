import AppKit
import ZPDFContracts

/// The print panel's own section for a drawing (NL-PDF-06, NL-PDF-07): scale, markups, and the
/// overlap of tiles for a sheet larger than the paper.
///
/// Every control writes straight into ``DocumentPrintView/options``, and
/// ``keyPathsForValuesAffectingPreview()`` names each one, so the panel's preview redraws as the
/// person changes it. The summary items say the same choices in words for the panel's summary
/// pane.
@MainActor
final class PrintOptionsAccessory: NSViewController, NSPrintPanelAccessorizing {

    private let printView: DocumentPrintView

    /// The scale popup's index into ``DocumentPrintLayout/ScaleMode/allCases``.
    @objc dynamic var scaleModeIndex: Int = DocumentPrintLayout.ScaleMode.allCases.firstIndex(of: .fitToPaper) ?? 2 {
        didSet { apply() }
    }
    @objc dynamic var customPercent: Double = 100 {
        didSet { apply() }
    }
    @objc dynamic var includeMarkups: Bool = true {
        didSet { apply() }
    }
    @objc dynamic var overlapMillimetres: Double = 10 {
        didSet { apply() }
    }
    @objc dynamic var scaleBar: Bool = true {
        didSet { apply() }
    }
    @objc dynamic var header: Bool = false {
        didSet { apply() }
    }
    @objc dynamic var includeSummary: Bool = false {
        didSet { apply() }
    }
    /// Bumped whenever the scope controls change, so the preview redraws.
    @objc dynamic var scopeRevision: Int = 0

    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let percentField = NSTextField(string: "100")
    private let markupsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let overlapField = NSTextField(string: "10")
    let scaleBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let headerCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let summaryCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Sheets, subjects and statuses: the Marked export's scope sheet, on paper (NL-PDF-06).
    private(set) var scopeControls: DrawingScopeControls?

    init(printView: DocumentPrintView) {
        self.printView = printView
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString("Drawing", comment: "Print panel accessory title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func title(for mode: DocumentPrintLayout.ScaleMode) -> String {
        switch mode {
        case .actualSize: NSLocalizedString("Actual size", comment: "Print scale: 100 %")
        case .halfSize: NSLocalizedString("Half size", comment: "Print scale: 50 %")
        case .fitToPaper: NSLocalizedString("Fit to paper", comment: "Print scale: shrink to fit")
        case .custom: NSLocalizedString("Custom", comment: "Print scale: a typed percentage")
        }
    }

    var scaleMode: DocumentPrintLayout.ScaleMode {
        let modes = DocumentPrintLayout.ScaleMode.allCases
        return modes.indices.contains(scaleModeIndex) ? modes[scaleModeIndex] : .fitToPaper
    }

    override func loadView() {
        scalePopup.addItems(withTitles: DocumentPrintLayout.ScaleMode.allCases.map(Self.title(for:)))
        scalePopup.selectItem(at: scaleModeIndex)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged(_:))
        scalePopup.setAccessibilityLabel(NSLocalizedString("Print scale", comment: "Accessibility label: print scale popup"))

        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.minimum = 1
        number.maximum = 400
        number.maximumFractionDigits = 1
        percentField.formatter = number
        percentField.target = self
        percentField.action = #selector(percentChanged(_:))
        percentField.setAccessibilityLabel(NSLocalizedString("Custom print scale, percent", comment: "Accessibility label: custom print percentage"))

        markupsCheckbox.title = NSLocalizedString("Print markups", comment: "Print panel checkbox: include the markups")
        markupsCheckbox.state = includeMarkups ? .on : .off
        markupsCheckbox.target = self
        markupsCheckbox.action = #selector(markupsChanged(_:))
        markupsCheckbox.setAccessibilityLabel(markupsCheckbox.title)

        let millimetres = NumberFormatter()
        millimetres.numberStyle = .decimal
        millimetres.minimum = 0
        millimetres.maximum = 50
        millimetres.maximumFractionDigits = 1
        overlapField.formatter = millimetres
        overlapField.target = self
        overlapField.action = #selector(overlapChanged(_:))
        overlapField.setAccessibilityLabel(NSLocalizedString("Tile overlap, millimetres", comment: "Accessibility label: tile overlap field"))

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let percentRow = NSStackView(views: [percentField, NSTextField(labelWithString: "%")])
        percentRow.spacing = 4
        let overlapRow = NSStackView(views: [overlapField, NSTextField(labelWithString: NSLocalizedString("mm", comment: "Millimetre unit"))])
        overlapRow.spacing = 4
        let note = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "Each sheet states the scale it printed at. A sheet larger than the paper at the chosen scale is printed across several pages.",
            comment: "Print panel explanation of scale notes and tiling"
        ))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        // A wrapping label reports its height for a width it is told; without one the fitting
        // size below would measure it as a single line.
        note.preferredMaxLayoutWidth = Self.noteWidth

        for (box, title, value, action) in [
            (scaleBarCheckbox, NSLocalizedString("Scale bar on sheets printed at a scale", comment: "Print panel checkbox"), scaleBar, #selector(scaleBarChanged(_:))),
            (headerCheckbox, NSLocalizedString("Header with takeoff, sheet and date", comment: "Print panel checkbox"), header, #selector(headerChanged(_:))),
            (summaryCheckbox, NSLocalizedString("Append the quantity summary", comment: "Print panel checkbox"), includeSummary, #selector(summaryChanged(_:)))
        ] {
            box.title = title
            box.state = value ? .on : .off
            box.target = self
            box.action = action
            box.setAccessibilityLabel(title)
        }
        summaryCheckbox.isEnabled = printView.summary != nil

        var rows: [[NSView]] = [
            [label(NSLocalizedString("Scale:", comment: "Print panel label")), scalePopup],
            [label(NSLocalizedString("Custom scale:", comment: "Print panel label")), percentRow],
            [NSGridCell.emptyContentView, markupsCheckbox]
        ]
        if !printView.scopeRecords.isEmpty {
            let controls = DrawingScopeControls.make(records: printView.scopeRecords, currentPageID: printView.currentPageID, layers: printView.scopeLayers)
            controls.onChange = { [weak self] in self?.scopeChanged() }
            scopeControls = controls
            rows.append([label(NSLocalizedString("Print:", comment: "Print panel label: which markups")), controls])
        }
        rows += [
            [NSGridCell.emptyContentView, scaleBarCheckbox],
            [NSGridCell.emptyContentView, headerCheckbox],
            [NSGridCell.emptyContentView, summaryCheckbox],
            [label(NSLocalizedString("Tile overlap:", comment: "Print panel label")), overlapRow],
            [NSGridCell.emptyContentView, note]
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        percentField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        overlapField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        note.widthAnchor.constraint(lessThanOrEqualToConstant: Self.noteWidth).isActive = true

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        // L-45: the print panel lays an accessory out in the frame its view arrives with. This
        // one arrived as `NSView()` — zero by zero — so the panel gave the Drawing section no
        // room: its rows were drawn on top of one another and over "Media & Quality" below. The
        // view now arrives at the size its contents need.
        container.frame = NSRect(origin: .zero, size: Self.fittedSize(of: container))
        preferredContentSize = container.frame.size
        view = container
        syncControls()
    }

    /// The widest the explanatory note is allowed to be.
    static let noteWidth: CGFloat = 320

    /// The size `container` needs to show every control without overlap: its Auto Layout
    /// fitting size, laid out first so the grid has measured every row.
    static func fittedSize(of container: NSView) -> NSSize {
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        return NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
    }

    private func syncControls() {
        percentField.isEnabled = scaleMode == .custom
        percentField.doubleValue = customPercent
        overlapField.doubleValue = overlapMillimetres
    }

    @objc private func scaleChanged(_ sender: NSPopUpButton) { scaleModeIndex = sender.indexOfSelectedItem }
    @objc private func percentChanged(_ sender: NSTextField) { customPercent = sender.doubleValue }
    @objc private func markupsChanged(_ sender: NSButton) { includeMarkups = sender.state == .on }
    @objc private func overlapChanged(_ sender: NSTextField) { overlapMillimetres = sender.doubleValue }
    @objc private func scaleBarChanged(_ sender: NSButton) { scaleBar = sender.state == .on }
    @objc private func headerChanged(_ sender: NSButton) { header = sender.state == .on }
    @objc private func summaryChanged(_ sender: NSButton) { includeSummary = sender.state == .on }

    /// The scope controls changed: the view prints the new selection of markups.
    func scopeChanged() {
        printView.scope = scopeControls?.scope ?? .everything
        scopeRevision += 1
    }

    /// Writes the choices into the print view, which lays its pages out again.
    private func apply() {
        printView.options = DocumentPrintLayout.Options(
            scaleMode: scaleMode,
            customPercent: customPercent,
            includeMarkups: includeMarkups,
            tileOverlap: max(0, overlapMillimetres) / 25.4 * 72,
            scaleBar: scaleBar,
            header: header,
            includeSummary: includeSummary
        )
        if isViewLoaded { syncControls() }
    }

    // MARK: - NSPrintPanelAccessorizing

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let scale: String = scaleMode == .custom
            ? String(format: NSLocalizedString("%@ %%", comment: "A print percentage"), DocumentPrintLayout.ratioText(customPercent))
            : Self.title(for: scaleMode)
        var items: [[NSPrintPanel.AccessorySummaryKey: String]] = [
            [.itemName: NSLocalizedString("Scale", comment: "Print summary item"), .itemDescription: scale],
            [
                .itemName: NSLocalizedString("Markups", comment: "Print summary item"),
                .itemDescription: includeMarkups
                    ? NSLocalizedString("Printed", comment: "Print summary: markups included")
                    : NSLocalizedString("Not printed", comment: "Print summary: markups left off")
            ]
        ]
        let layerNames = Dictionary(printView.scopeLayers.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
        if includeMarkups, let sentence = printView.scope.summary(pageLabel: { _ in nil }, layerName: { layerNames[$0] }) {
            items.append([.itemName: NSLocalizedString("Which markups", comment: "Print summary item"), .itemDescription: sentence])
        }
        return items
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["scaleModeIndex", "customPercent", "includeMarkups", "overlapMillimetres", "scaleBar", "header", "includeSummary", "scopeRevision"]
    }
}
