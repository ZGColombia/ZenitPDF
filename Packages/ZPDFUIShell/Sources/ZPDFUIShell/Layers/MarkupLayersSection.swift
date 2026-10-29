import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Navigator ▸ Layers page's markup-layer section (ADR-0032, unit r2-layers): the project's
/// layers with a visibility eye, a lock, rename in place, drag to reorder and a count, the active
/// layer marked, and New Layer in the header.
///
/// Every request goes through ``MarkupLayerPanelModel``; nothing here writes a layer.
struct MarkupLayersSection: View {

    let environment: ProjectShellEnvironment

    var body: some View {
        let model = environment.markupLayers
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ZPDFSpacing.s) {
                Text(NSLocalizedString("Markup layers", comment: "Layers page section: layers of the takeoff markups"))
                    .zpdfText(.sectionHeader, .textSecondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if model.ledgerFilterLayerIDs != nil {
                    Button(NSLocalizedString("Show All in Ledger", comment: "Layers page: lift the ledger's layer filter")) {
                        model.clearLedgerFilter()
                    }
                    .buttonStyle(.link)
                    .zpdfFont(.caption)
                    .help(NSLocalizedString("The Quantity Ledger shows only some layers. Show every layer's rows again.", comment: "Help for Show All in Ledger"))
                }
                ZPDFToolbarButton(
                    glyph: .symbol(.add),
                    title: NSLocalizedString("New Layer…", comment: "Layers page: add a markup layer"),
                    action: { model.newLayer() }
                )
            }
            .padding(.horizontal, ZPDFSpacing.l)
            .padding(.top, ZPDFSpacing.l)
            .padding(.bottom, ZPDFSpacing.xs)

            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                MarkupLayerRowView(environment: environment, row: row, index: index)
                    .padding(.horizontal, ZPDFSpacing.l)
                ZPDFHairlineDivider(leadingInset: ZPDFSpacing.l, trailingInset: ZPDFSpacing.l)
            }
            if !model.rows.isEmpty {
                MarkupLayerEndDropZone(model: model)
                    .padding(.horizontal, ZPDFSpacing.l)
            }
        }
    }
}

/// The strip under the last layer row: a layer dropped here goes to the bottom (V-047). Every
/// row takes a drop *above* itself, so without it the bottom place could be reached only through
/// Move Down. Mirrors the Navigator's page end strip (U-044); accessibility-hidden, because Move
/// Down already reaches the same place.
struct MarkupLayerEndDropZone: View {

    let model: MarkupLayerPanelModel
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .frame(height: ZPDFSpacing.Control.minimumHitTarget / 2)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(ZPDFColor.color(NavigatorStyle.stateLine))
                    .frame(height: 2)
                    .opacity(isTargeted ? 1 : 0)
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { payloads, _ in
                model.drop(payloads, at: model.rows.count)
            } isTargeted: { isTargeted = $0 }
            .accessibilityHidden(true)
    }
}

/// One markup layer row.
struct MarkupLayerRowView: View {

    let environment: ProjectShellEnvironment
    let row: MarkupLayerRow
    let index: Int

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isDropTarget = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let model = environment.markupLayers
        let isActive = model.activeLayerID == row.id
        HStack(spacing: ZPDFSpacing.s) {
            ZPDFToolbarButton(
                glyph: .symbol(row.isVisible ? .visible : .hidden),
                title: row.isVisible
                    ? NSLocalizedString("Hide Layer", comment: "Markup layer row action")
                    : NSLocalizedString("Show Layer", comment: "Markup layer row action"),
                isSelected: !row.isVisible,
                action: { model.setVisible(!row.isVisible, layer: row.id) }
            )
            // The active layer: a filled marker and the word, so the state is never colour alone.
            ZPDFGlyphView(.symbol(isActive ? .success : .layers), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(isActive ? ZPDFColor.accent : ZPDFColor.textSecondary)
                .accessibilityHidden(true)
            if isRenaming {
                TextField(
                    NSLocalizedString("Layer name", comment: "Placeholder of a markup layer's rename field"),
                    text: $draftName
                )
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { isRenaming = false }
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString("New name for %@", comment: "Accessibility label of a markup layer's rename field"),
                    row.name
                )))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .zpdfText(.body, row.isVisible ? .textPrimary : .textSecondary)
                        .lineLimit(1)
                    if isActive || !row.isPrintable {
                        Text(Self.subtitle(isActive: isActive, printable: row.isPrintable))
                            .zpdfText(.caption, .textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: ZPDFSpacing.xs)
            Text(row.markupCount.formatted())
                .zpdfText(.monoNumeric.withSize(11), .textSecondary)
                .accessibilityHidden(true)
            ZPDFToolbarButton(
                glyph: .symbol(row.isLocked ? .lock : .unlock),
                title: row.isLocked
                    ? NSLocalizedString("Unlock Layer", comment: "Markup layer row action")
                    : NSLocalizedString("Lock Layer", comment: "Markup layer row action"),
                isSelected: row.isLocked,
                action: { model.setLocked(!row.isLocked, layer: row.id) }
            )
        }
        .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
        .background(ZPDFColor.color(NavigatorStyle.accent).opacity(isActive ? NavigatorStyle.selectionTint : 0))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ZPDFColor.color(NavigatorStyle.stateLine))
                .frame(height: 2)
                .opacity(isDropTarget ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { model.setActive(row.id) }
        // V-047: a private payload, and a drop that answers whether a layer moved. The row took
        // any text and returned `true` before reading it, so a stray text drop drew the line and
        // reported a success that did nothing.
        .onDrag { NSItemProvider(object: MarkupLayerDrag.payload(for: row.id) as NSString) }
        .dropDestination(for: String.self) { payloads, _ in
            // Lands where the line at the top of this row is drawn (U-045).
            model.drop(payloads, at: index)
        } isTargeted: { isDropTarget = $0 }
        .contextMenu { menu(model: model, isActive: isActive) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(MarkupLayerPanelModel.spokenName(row)))
        .accessibilityValue(Text(MarkupLayerPanelModel.spokenState(row, isActive: isActive)))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityAction(named: Text(NSLocalizedString("Make Active", comment: "Markup layer row action"))) {
            model.setActive(row.id)
        }
        .accessibilityAction(named: Text(NSLocalizedString("Rename", comment: "Markup layer row action"))) {
            beginRename()
        }
    }

    @ViewBuilder
    private func menu(model: MarkupLayerPanelModel, isActive: Bool) -> some View {
        Button(NSLocalizedString("Make Active", comment: "Markup layer row menu: new markups go here")) {
            model.setActive(row.id)
        }
        .disabled(isActive)
        Button(NSLocalizedString("Rename…", comment: "Markup layer row menu")) { beginRename() }
        Divider()
        Button(row.isVisible
               ? NSLocalizedString("Hide Layer", comment: "Markup layer row menu")
               : NSLocalizedString("Show Layer", comment: "Markup layer row menu")) {
            model.setVisible(!row.isVisible, layer: row.id)
        }
        Button(row.isLocked
               ? NSLocalizedString("Unlock Layer", comment: "Markup layer row menu")
               : NSLocalizedString("Lock Layer", comment: "Markup layer row menu")) {
            model.setLocked(!row.isLocked, layer: row.id)
        }
        Toggle(NSLocalizedString("Print and Export", comment: "Markup layer row menu: whether the layer reaches paper"), isOn: Binding(
            get: { row.isPrintable },
            set: { model.setPrintable($0, layer: row.id) }
        ))
        Divider()
        // V-046: the layer model's one rule, the one the Inspector's Layer popup asks — a locked
        // target and a locked markup are both refused, and the help says which.
        let selection = environment.canvas.resolvedSelectedMarkups
        let refusal = model.assignRefusal(selection, to: row.id)
        Button(NSLocalizedString("Move Selected Markups Here", comment: "Markup layer row menu")) {
            model.assign(selection, to: row.id)
        }
        .disabled(refusal != nil)
        .help(refusal.map(MarkupLayerPanelModel.reason) ?? "")
        Button(model.ledgerFilterLayerIDs == [row.id]
               ? NSLocalizedString("Show All Layers in Ledger", comment: "Markup layer row menu: lift the ledger filter")
               : NSLocalizedString("Show Only This Layer in Ledger", comment: "Markup layer row menu: filter the ledger by layer")) {
            model.toggleLedgerFilter(row.id)
        }
        Divider()
        Button(NSLocalizedString("Move Up", comment: "Markup layer row menu")) { model.move(row.id, to: index - 1) }
            .disabled(index == 0)
        Button(NSLocalizedString("Move Down", comment: "Markup layer row menu")) { model.move(row.id, to: index + 1) }
            .disabled(index >= model.rows.count - 1)
        Divider()
        Button(NSLocalizedString("Delete Layer…", comment: "Markup layer row menu"), role: .destructive) {
            model.delete(row.id)
        }
        .disabled(row.isDefault)
        .help(row.isDefault ? NSLocalizedString("The default layer cannot be deleted.", comment: "Help: why Delete Layer is off") : "")
    }

    private func beginRename() {
        draftName = row.name
        isRenaming = true
        nameFocused = true
    }

    private func commitRename() {
        isRenaming = false
        environment.markupLayers.rename(row.id, to: draftName)
    }

    /// The small line under the name: "Active" and "Not printed", in words.
    static func subtitle(isActive: Bool, printable: Bool) -> String {
        var parts: [String] = []
        if isActive { parts.append(NSLocalizedString("New markups go here", comment: "Markup layer row: the active layer")) }
        if !printable { parts.append(NSLocalizedString("Not printed", comment: "Markup layer row: kept off paper")) }
        return parts.joined(separator: " · ")
    }
}
