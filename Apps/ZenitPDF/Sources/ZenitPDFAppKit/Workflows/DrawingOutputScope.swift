import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer

/// Which markups go onto paper or into a marked file (NL-PDF-05 scope sheet, NL-PDF-06 print
/// filters): sheets, subjects and review statuses.
///
/// One predicate for both, on purpose — "the same predicate drives print so paper and file cannot
/// disagree". It narrows what `PDFFlattenPolicy` already decided (hidden and non-printable
/// markups never reach it), and it never adds anything back.
///
/// Markup layers (ADR-0032, r2-layers) join ``subjects`` and ``statuses`` as ``layerIDs``: a layer
/// the person unticks here stays off this one print or file, on top of its own printable flag.
struct DrawingOutputScope: Sendable, Equatable {

    /// Markups only on these sheets (page identities); `nil` is every sheet. Other sheets still
    /// print or export — clean.
    var pageIDs: Set<UUID>?
    /// Only markups with one of these subjects (`""` for no subject); `nil` is every subject.
    var subjects: Set<String>?
    /// Only markups in one of these review states; `nil` is every state.
    var statuses: Set<MarkupStatus>?
    /// Only markups on one of these markup layers; `nil` is every layer (ADR-0032).
    var layerIDs: Set<UUID>?

    static let everything = DrawingOutputScope()

    init(pageIDs: Set<UUID>? = nil, subjects: Set<String>? = nil, statuses: Set<MarkupStatus>? = nil, layerIDs: Set<UUID>? = nil) {
        self.pageIDs = pageIDs
        self.subjects = subjects
        self.statuses = statuses
        self.layerIDs = layerIDs
    }

    var isEverything: Bool { pageIDs == nil && subjects == nil && statuses == nil && layerIDs == nil }

    /// What the scope reads off one markup.
    struct Facts: Sendable, Equatable {
        var subject: String
        var status: MarkupStatus
        /// The markup's layer, resolved (a layer the project no longer holds is the default).
        var layerID: UUID = MarkupLayer.defaultID.rawValue
    }

    /// The facts of every record; `layers` resolves each record's layer (empty: as stored).
    static func facts(from records: [MarkupRecord], layers: [MarkupLayer] = []) -> [UUID: Facts] {
        let set = layers.isEmpty ? nil : MarkupLayerSet(layers)
        return Dictionary(records.map { record in
            let layer = set?.resolvedLayerID(of: record) ?? record.effectiveLayerID
            return (record.id.rawValue, Facts(subject: record.subject, status: record.status, layerID: layer.rawValue))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The one predicate.
    func includes(_ facts: Facts, pageID: UUID) -> Bool {
        if let pageIDs, !pageIDs.contains(pageID) { return false }
        if let subjects, !subjects.contains(facts.subject) { return false }
        if let statuses, !statuses.contains(facts.status) { return false }
        if let layerIDs, !layerIDs.contains(facts.layerID) { return false }
        return true
    }

    /// `pages` with every markup outside the scope removed. A renderable the facts do not name is
    /// not a markup this scope can judge and stays only when nothing is filtered.
    func apply(to pages: [FlattenPage], facts: [UUID: Facts]) -> [FlattenPage] {
        guard !isEverything else { return pages }
        return pages.map { page in
            var filtered = page
            let pageID = page.page.id.rawValue
            filtered.markups = page.markups.filter { markup in
                guard let fact = facts[markup.id.rawValue] else { return false }
                return includes(fact, pageID: pageID)
            }
            return filtered
        }
    }

    /// How many markups the scope keeps out of those on `pages`.
    func count(on pages: [FlattenPage], facts: [UUID: Facts]) -> (kept: Int, total: Int) {
        let all = Set(pages.flatMap { $0.markups.map(\.id.rawValue) })
        let kept = Set(apply(to: pages, facts: facts).flatMap { $0.markups.map(\.id.rawValue) })
        return (kept.count, all.count)
    }

    /// A sentence for the export report and the print summary, or `nil` for everything.
    func summary(pageLabel: (UUID) -> String?, layerName: (UUID) -> String? = { _ in nil }) -> String? {
        guard !isEverything else { return nil }
        var parts: [String] = []
        if let pageIDs {
            let labels = pageIDs.compactMap(pageLabel).sorted()
            parts.append(String(format: NSLocalizedString("on sheet %@", comment: "Output scope: markups only on these sheets; sheet labels"),
                                labels.joined(separator: ", ")))
        }
        if let subjects {
            let names = subjects.map { $0.isEmpty ? Self.noSubjectTitle : $0 }.sorted()
            parts.append(String(format: NSLocalizedString("with subject %@", comment: "Output scope: markups only with these subjects"),
                                names.joined(separator: ", ")))
        }
        if let statuses {
            let names = MarkupStatus.allCases.filter(statuses.contains).map(Self.title(for:))
            parts.append(String(format: NSLocalizedString("with status %@", comment: "Output scope: markups only in these states"),
                                names.joined(separator: ", ")))
        }
        if let layerIDs {
            let names = layerIDs.compactMap(layerName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            parts.append(String(format: NSLocalizedString("on layer %@", comment: "Output scope: markups only on these markup layers"),
                                names.joined(separator: ", ")))
        }
        return String(format: NSLocalizedString("Only markups %@ are included.", comment: "Output scope sentence; the conditions"),
                      parts.joined(separator: "; "))
    }

    static let noSubjectTitle = NSLocalizedString("No subject", comment: "Output scope: markups without a subject")

    static func title(for status: MarkupStatus) -> String {
        switch status {
        case .none: NSLocalizedString("No status", comment: "Markup review status")
        case .open: NSLocalizedString("Open", comment: "Markup review status")
        case .inProgress: NSLocalizedString("In progress", comment: "Markup review status")
        case .resolved: NSLocalizedString("Resolved", comment: "Markup review status")
        case .accepted: NSLocalizedString("Accepted", comment: "Markup review status")
        case .rejected: NSLocalizedString("Rejected", comment: "Markup review status")
        case .cancelled: NSLocalizedString("Cancelled", comment: "Markup review status")
        case .completed: NSLocalizedString("Completed", comment: "Markup review status")
        }
    }
}

/// The scope controls, shared by the Marked export's save panel and the print panel: which
/// sheets carry markups, and which subjects and statuses. Every box starts ticked, so a person
/// who never touches it gets everything, as before.
@MainActor
final class DrawingScopeControls: NSView {

    let sheetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var subjectBoxes: [(value: String, box: NSButton)] = []
    private(set) var statusBoxes: [(value: MarkupStatus, box: NSButton)] = []
    /// One box per markup layer (ADR-0032), when the project has more than one.
    private(set) var layerBoxes: [(value: UUID, box: NSButton)] = []
    private let currentPageID: UUID?
    /// Told whenever a control changes, so a print preview can redraw.
    var onChange: (() -> Void)?

    /// - Parameters:
    ///   - subjects: the subjects the takeoff uses (`""` for none), in the order to list them.
    ///   - statuses: the review states the takeoff uses.
    ///   - currentPageID: the sheet on screen, for "This sheet only"; `nil` hides that choice.
    ///   - layers: the project's markup layers, top first; boxes appear when there are two or more.
    init(subjects: [String], statuses: [MarkupStatus], currentPageID: UUID?, layers: [(id: UUID, name: String)] = []) {
        self.currentPageID = currentPageID
        super.init(frame: .zero)
        sheetPopup.addItem(withTitle: NSLocalizedString("All sheets", comment: "Output scope: markups on every sheet"))
        if currentPageID != nil {
            sheetPopup.addItem(withTitle: NSLocalizedString("This sheet only", comment: "Output scope: markups only on the sheet on screen"))
        }
        sheetPopup.setAccessibilityLabel(NSLocalizedString("Markups on", comment: "Accessibility label: output scope sheet choice"))
        sheetPopup.target = self
        sheetPopup.action = #selector(changed)
        for subject in subjects {
            let box = NSButton(checkboxWithTitle: subject.isEmpty ? DrawingOutputScope.noSubjectTitle : subject, target: self, action: #selector(changed))
            box.state = .on
            box.setAccessibilityLabel(String(format: NSLocalizedString("Include subject %@", comment: "Accessibility label: output scope subject box"), box.title))
            subjectBoxes.append((subject, box))
        }
        for status in statuses {
            let box = NSButton(checkboxWithTitle: DrawingOutputScope.title(for: status), target: self, action: #selector(changed))
            box.state = .on
            box.setAccessibilityLabel(String(format: NSLocalizedString("Include status %@", comment: "Accessibility label: output scope status box"), box.title))
            statusBoxes.append((status, box))
        }
        if layers.count > 1 {
            for layer in layers {
                let box = NSButton(checkboxWithTitle: layer.name, target: self, action: #selector(changed))
                box.state = .on
                box.setAccessibilityLabel(String(format: NSLocalizedString("Include layer %@", comment: "Accessibility label: output scope markup layer box"), layer.name))
                layerBoxes.append((layer.id, box))
            }
        }

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            return field
        }
        func column(_ boxes: [NSButton]) -> NSView {
            let stack = NSStackView(views: boxes)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            guard boxes.count > 6 else { return stack }
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.documentView = stack
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: 200).isActive = true
            return scroll
        }
        let sheetRow = NSStackView(views: [label(NSLocalizedString("Markups on:", comment: "Output scope label")), sheetPopup])
        var rows: [NSView] = [sheetRow]
        if !subjectBoxes.isEmpty {
            rows.append(label(NSLocalizedString("Subjects:", comment: "Output scope label")))
            rows.append(column(subjectBoxes.map(\.box)))
        }
        if statusBoxes.count > 1 {
            rows.append(label(NSLocalizedString("Statuses:", comment: "Output scope label")))
            rows.append(column(statusBoxes.map(\.box)))
        }
        if !layerBoxes.isEmpty {
            rows.append(label(NSLocalizedString("Layers:", comment: "Output scope label: markup layers")))
            rows.append(column(layerBoxes.map(\.box)))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func changed() { onChange?() }

    /// What is ticked. A list with every box ticked is "every", not a list, so a subject added
    /// later is not silently left out.
    var scope: DrawingOutputScope {
        var scope = DrawingOutputScope()
        if sheetPopup.indexOfSelectedItem == 1, let currentPageID { scope.pageIDs = [currentPageID] }
        let subjects = subjectBoxes.filter { $0.box.state == .on }.map(\.value)
        if subjects.count < subjectBoxes.count { scope.subjects = Set(subjects) }
        let statuses = statusBoxes.filter { $0.box.state == .on }.map(\.value)
        if statuses.count < statusBoxes.count { scope.statuses = Set(statuses) }
        let layers = layerBoxes.filter { $0.box.state == .on }.map(\.value)
        if layers.count < layerBoxes.count { scope.layerIDs = Set(layers) }
        return scope
    }

    /// The controls for a takeoff: its subjects and statuses, and the sheet on screen.
    static func make(records: [MarkupRecord], currentPageID: UUID?, layers: [MarkupLayer] = []) -> DrawingScopeControls {
        var subjects: [String] = []
        var seen = Set<String>()
        for record in records where seen.insert(record.subject).inserted { subjects.append(record.subject) }
        subjects.sort { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let used = Set(records.map(\.status))
        return DrawingScopeControls(
            subjects: subjects,
            statuses: MarkupStatus.allCases.filter(used.contains),
            currentPageID: currentPageID,
            layers: layers.map { (id: $0.id.rawValue, name: $0.name) }
        )
    }
}

extension DrawingOutputScope {

    /// Narrows `job` to `scope` and returns the sentence the export report carries, or `nil`
    /// when nothing was filtered.
    @MainActor
    static func narrow(_ job: inout FlattenedDrawingExport.Job, scope: DrawingOutputScope, document: ZenitPDFProjectDocument) async -> String? {
        guard !scope.isEverything, let core = document.core else { return nil }
        let layers = core.snapshot.markupLayers
        let facts = facts(from: await core.session.orderedMarkups, layers: layers)
        job.pages = scope.apply(to: job.pages, facts: facts)
        let labels = Dictionary((document.drawing?.pages ?? []).map { ($0.id.rawValue, $0.label.isEmpty ? String($0.index + 1) : $0.label) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(layers.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
        return scope.summary(pageLabel: { labels[$0] }, layerName: { names[$0] })
    }
}

extension ProjectWindowController {

    /// The scope controls for the document's takeoff, with the sheet on screen offered.
    func drawingScopeControls(for document: ZenitPDFProjectDocument) async -> DrawingScopeControls? {
        guard let core = document.core else { return nil }
        let records = await core.session.orderedMarkups
        return DrawingScopeControls.make(records: records, currentPageID: core.document.currentPageID, layers: core.snapshot.markupLayers)
    }
}
