import Foundation
import Observation
import ZPDFUIPresentation

/// A markup layer row's drag payload: a private text form, so a layer row only takes a dragged
/// layer row, and text from another application or a Navigator page card is refused (V-047).
public enum MarkupLayerDrag {
    public static let prefix = "zenit-layer:"

    public static func payload(for id: UUID) -> String { prefix + id.uuidString }

    public static func layerID(in payload: String) -> UUID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}

/// One markup layer as the Navigator and the Inspector show it (ADR-0032).
public struct MarkupLayerRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let isVisible: Bool
    public let isLocked: Bool
    public let isPrintable: Bool
    /// How many markups the layer holds across the project.
    public let markupCount: Int
    /// The project's default layer: renamed, hidden and locked like any other, never deleted.
    public let isDefault: Bool

    public init(
        id: UUID, name: String, isVisible: Bool = true, isLocked: Bool = false,
        isPrintable: Bool = true, markupCount: Int = 0, isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isPrintable = isPrintable
        self.markupCount = markupCount
        self.isDefault = isDefault
    }
}

/// The project's markup layers, for the Navigator's Layers page and the Inspector's Layer row
/// (ADR-0032, unit r2-layers).
///
/// The shell renders the rows the application applies and reports every request through a
/// callback; it never changes a layer itself, because the truth — and its undo — lives in the
/// session. A row therefore flips only when the application applies the new state, so a switch
/// always shows what is in force.
@MainActor
@Observable
public final class MarkupLayerPanelModel {

    /// The layers, top first.
    public private(set) var rows: [MarkupLayerRow] = []
    /// The layer new markups go to.
    public private(set) var activeLayerID: UUID?
    /// The layers the ledger is narrowed to, or `nil` when it is not filtered by layer.
    public private(set) var ledgerFilterLayerIDs: Set<UUID>?
    /// Whether the application has installed project layers. Until it has, the Navigator keeps
    /// the older name-derived markup-layer list (a surface without a project, a test).
    public private(set) var isInstalled = false

    public init() {}

    /// Installs the rows, the active layer and the ledger filter the application reports.
    public func apply(rows: [MarkupLayerRow], activeLayerID: UUID?, ledgerFilterLayerIDs: Set<UUID>? = nil) {
        if self.rows != rows { self.rows = rows }
        if self.activeLayerID != activeLayerID { self.activeLayerID = activeLayerID }
        if self.ledgerFilterLayerIDs != ledgerFilterLayerIDs { self.ledgerFilterLayerIDs = ledgerFilterLayerIDs }
        if !isInstalled { isInstalled = true }
    }

    /// One row by identity.
    public func row(_ id: UUID) -> MarkupLayerRow? { rows.first { $0.id == id } }

    // MARK: Requests (the application answers them)

    /// Raised to create a layer; the application asks for a name, adds it at the top and makes it
    /// active. `markupIDs` are moved onto it in the same step when the request came from a
    /// selection (the Inspector's and the context menu's "New Layer…").
    @ObservationIgnored public var onNewLayer: (@MainActor (_ markupIDs: Set<UUID>) -> Void)?
    @ObservationIgnored public var onRename: (@MainActor (_ layerID: UUID, _ name: String) -> Void)?
    @ObservationIgnored public var onMove: (@MainActor (_ layerID: UUID, _ index: Int) -> Void)?
    @ObservationIgnored public var onSetVisible: (@MainActor (_ layerID: UUID, _ visible: Bool) -> Void)?
    @ObservationIgnored public var onSetLocked: (@MainActor (_ layerID: UUID, _ locked: Bool) -> Void)?
    @ObservationIgnored public var onSetPrintable: (@MainActor (_ layerID: UUID, _ printable: Bool) -> Void)?
    /// Raised to delete a layer; the application asks where its markups go.
    @ObservationIgnored public var onDelete: (@MainActor (_ layerID: UUID) -> Void)?
    @ObservationIgnored public var onSetActive: (@MainActor (_ layerID: UUID) -> Void)?
    /// Raised to move markups onto a layer.
    @ObservationIgnored public var onAssign: (@MainActor (_ markupIDs: Set<UUID>, _ layerID: UUID) -> Void)?
    /// Raised to narrow the ledger to these layers, or to lift the layer filter with `nil`.
    @ObservationIgnored public var onFilterLedger: (@MainActor (_ layerIDs: Set<UUID>?) -> Void)?

    public func newLayer(moving markupIDs: Set<UUID> = []) { onNewLayer?(markupIDs) }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, row(id)?.name != trimmed else { return }
        onRename?(id, trimmed)
    }

    public func move(_ id: UUID, to index: Int) {
        guard let from = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(rows.count - 1, index))
        guard target != from else { return }
        onMove?(id, target)
    }

    /// The final place of a layer dropped at `index`, or `nil` when the drop changes nothing
    /// (on its own row, just under itself, or the last row on the end strip).
    ///
    /// A dragged layer dropped on the row at `index` lands just above that row, where the drop
    /// line is drawn (U-045); `index == rows.count` is the strip under the last row, which lands
    /// the layer at the bottom (V-047). `onMove` takes the layer's final place and removes the
    /// layer before it inserts it again, so a downward drop is one place short of the row: in
    /// [A, B, C, D], dropping A on C drew the line between B and C and handed over index 2,
    /// which gives [B, C, A, D]. Below its own place the layer now lands at `index - 1`.
    func dropTarget(for id: UUID, droppedOn index: Int) -> Int? {
        guard let from = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let wanted = from < index ? index - 1 : index
        let target = max(0, min(rows.count - 1, wanted))
        return target == from ? nil : target
    }

    /// A drag's text payloads dropped at `index` — a row, or the end strip at `rows.count`.
    /// Only a layer row's own payload (``MarkupLayerDrag``) moves anything; text from another
    /// application, a Navigator page card or anything else is refused. Answers whether a layer
    /// moved, so the drop is never reported as a success that did nothing (V-047).
    @discardableResult
    public func drop(_ payloads: [String], at index: Int) -> Bool {
        guard let id = payloads.lazy.compactMap(MarkupLayerDrag.layerID(in:)).first,
              let target = dropTarget(for: id, droppedOn: index) else { return false }
        onMove?(id, target)
        return true
    }

    public func setVisible(_ visible: Bool, layer id: UUID) {
        guard row(id)?.isVisible != visible else { return }
        onSetVisible?(id, visible)
    }

    public func setLocked(_ locked: Bool, layer id: UUID) {
        guard row(id)?.isLocked != locked else { return }
        onSetLocked?(id, locked)
    }

    public func setPrintable(_ printable: Bool, layer id: UUID) {
        guard row(id)?.isPrintable != printable else { return }
        onSetPrintable?(id, printable)
    }

    public func delete(_ id: UUID) {
        guard let row = row(id), !row.isDefault else { return }
        onDelete?(id)
    }

    public func setActive(_ id: UUID) {
        guard activeLayerID != id, row(id) != nil else { return }
        onSetActive?(id)
    }

    // MARK: Moving markups onto a layer (V-046)

    /// Why markups cannot be moved onto a layer. The one rule the Navigator's "Move Selected
    /// Markups Here" and the Inspector's Layer popup both ask, so the same action gets the same
    /// answer on both surfaces. They used to disagree: the Inspector filed a selection onto a
    /// locked layer but refused a markup with its own lock; the Navigator refused a locked layer
    /// but moved a markup with its own lock.
    public enum AssignRefusal: Equatable, Sendable {
        /// Nothing is selected.
        case nothingSelected
        /// The project's layers are not installed, or the target is not one of them.
        case unknownLayer
        /// The target layer is locked: nothing may be added to it (its markups could then not
        /// be moved back off it, since a locked layer's markups cannot change).
        case targetLocked
        /// A selected markup sits on a locked layer.
        case markupOnLockedLayer
        /// A selected markup has its own lock.
        case markupLocked
    }

    /// Why `markups` cannot move onto the layer `layerID` — `nil` for a new layer, which is
    /// never locked — or `nil` when they can.
    public func assignRefusal(_ markups: [MarkupSummary], to layerID: UUID?) -> AssignRefusal? {
        guard isInstalled || markups.isEmpty else { return .unknownLayer }
        var targetIsLocked: Bool?
        if let layerID, !markups.isEmpty {
            guard let target = row(layerID) else { return .unknownLayer }
            targetIsLocked = target.isLocked
        }
        return Self.assignRefusal(markups, targetIsLocked: targetIsLocked)
    }

    /// The rule itself, for a surface that knows the target's lock but holds no panel model —
    /// the canvas's Move to Layer menu. `targetIsLocked` is `nil` for a new layer.
    public static func assignRefusal(_ markups: [MarkupSummary], targetIsLocked: Bool?) -> AssignRefusal? {
        guard !markups.isEmpty else { return .nothingSelected }
        if targetIsLocked == true { return .targetLocked }
        if markups.contains(where: { $0.layerLocked == true }) { return .markupOnLockedLayer }
        // `locked` includes the layer's share; the case above has already named that one.
        if markups.contains(where: \.locked) { return .markupLocked }
        return nil
    }

    /// Whether `markups` can move onto `layerID` (`nil`: a new layer).
    public func canAssign(_ markups: [MarkupSummary], to layerID: UUID?) -> Bool {
        assignRefusal(markups, to: layerID) == nil
    }

    /// Moves `markups` onto a layer when the rule allows it; nothing otherwise.
    public func assign(_ markups: [MarkupSummary], to layerID: UUID) {
        guard canAssign(markups, to: layerID) else { return }
        onAssign?(Set(markups.map(\.id)), layerID)
    }

    /// Creates a layer and moves `markups` onto it, when their locks allow it.
    public func newLayer(moving markups: [MarkupSummary]) {
        guard canAssign(markups, to: nil) else { return }
        onNewLayer?(Set(markups.map(\.id)))
    }

    /// A refusal in words, for a disabled item's help.
    public static func reason(_ refusal: AssignRefusal) -> String {
        switch refusal {
        case .nothingSelected:
            return NSLocalizedString("Select markups to move them onto a layer.", comment: "Why moving markups onto a layer is off: nothing selected")
        case .unknownLayer:
            return NSLocalizedString("This layer is not available.", comment: "Why moving markups onto a layer is off: the layer is unknown")
        case .targetLocked:
            return NSLocalizedString("This layer is locked. Unlock it to move markups onto it.", comment: "Why moving markups onto a layer is off: the layer is locked")
        case .markupOnLockedLayer:
            // The Inspector says the same thing through `InspectorPanel.lockedLayerReason` (W-052).
            return NSLocalizedString(
                "The selection is on a locked layer. Unlock the layer in the Navigator first.",
                comment: "Inspector Layer popup help when a selected markup's layer is locked"
            )
        case .markupLocked:
            return NSLocalizedString("The selection includes a locked markup. Unlock it first.", comment: "Why moving markups onto a layer is off: a selected markup is locked")
        }
    }

    /// Narrows the ledger to one layer, or lifts the filter when it is already that layer alone.
    public func toggleLedgerFilter(_ id: UUID) {
        onFilterLedger?(ledgerFilterLayerIDs == [id] ? nil : [id])
    }

    public func clearLedgerFilter() { onFilterLedger?(nil) }

    // MARK: Words

    /// The row's spoken name: qualified, because a drawing layer can have the same name (CR-113).
    public static func spokenName(_ row: MarkupLayerRow) -> String {
        String(format: NSLocalizedString("%@, markup layer", comment: "Accessibility label for a markup layer row: layer name"), row.name)
    }

    /// The row's spoken state.
    public static func spokenState(_ row: MarkupLayerRow, isActive: Bool) -> String {
        var parts = [row.isVisible
            ? NSLocalizedString("Visible", comment: "Layer visibility state")
            : NSLocalizedString("Hidden", comment: "Layer visibility state")]
        if row.isLocked { parts.append(NSLocalizedString("Locked", comment: "Markup layer state")) }
        if !row.isPrintable { parts.append(NSLocalizedString("Not printed", comment: "Markup layer state")) }
        if isActive { parts.append(NSLocalizedString("Active", comment: "Markup layer state: new markups go here")) }
        parts.append(String(format: NSLocalizedString("%d markups", comment: "Markup layer state: markup count"), row.markupCount))
        return parts.joined(separator: ", ")
    }
}
