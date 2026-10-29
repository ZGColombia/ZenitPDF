import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell

/// What a calibration that is about to run is *for*.
///
/// Calibration is one flow — two clicks and a typed length — with three destinations: the page
/// default, an existing Scale Region, or a region that does not exist yet. The destination is
/// decided before the first click and read after the last, which is why it is a value on the
/// document rather than a parameter threaded through the canvas.
public enum ScaleCalibrationTarget: Sendable, Equatable {
    /// The document default scale. The ordinary Calibrate command.
    case pageDefault
    /// An existing Scale Region: a new scale is installed and assigned to it.
    case region(UUID)
    /// The draft in the Scale Regions panel: a new scale is installed and offered to the draft,
    /// which still has to be committed before the region exists.
    case draft
}

extension ZenitPDFProjectDocument {

    /// Connects the Scale Regions panel and the Project Zones page to the document.
    ///
    /// Everything that *mutates* leaves through ``DocumentCommandBus``, so each edit is
    /// undoable, lands in the audit trail and survives save → reopen. Everything that *reads*
    /// comes from the document snapshot the same refresh feeds the ledger from, so a panel can
    /// never show a region a ledger row beside it has not heard of.
    ///
    /// The two panels' models refuse out loud when a hook is unset (`.notWired`,
    /// `.rejectedByCore`). This function is what stops that refusal from being the shipping
    /// behaviour.
    func wireProjectStructure(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        wireScaleRegionsPanel(shell: shell, core: core)
        wireProjectZonesPanel(shell: shell, core: core)
        wireBoundaryCapture(shell: shell, core: core)
        wireCrossingPrompt(shell: shell, core: core)
        wireInspectorScaleRegion(shell: shell, core: core)
        wireInspectorLockAndHide(shell: shell, core: core)
        wireInspectorZoneAssignment(shell: shell, core: core)  // nl-ux: UX/InspectorZoneWiring.swift
        // Every refresh, not only the ones these panels caused: a measurement drawn on the
        // canvas changes a region's markup count and a zone's subtotal, and a panel that only
        // hears about its own edits is stale for every other one.
        // This window's panels from this window's core: with a second window on the document
        // (NL-UX-20) each core's refresh brings its own window's panels up to date.
        core.onDidRefresh = { [weak self, weak shell, weak core] _ in
            guard let self, let shell, let core else { return }
            self.refreshProjectStructure(shell: shell, core: core)
        }
        // A Tool Library arming reaches the toolbar, so the chips and the status bar say
        // the same thing the presenter believes. Without the mirror the presenter drew an
        // Area while the toolbar still highlighted Select (LT-37, 2026-08-29).
        // The Inspector's Repeat stepper (LT-7). Through the ordinary command bus, so the
        // edit is undoable and lands in the audit trail like any other cell edit.
        // Answers whether the edit landed, so the stepper lets go of a refused ask (W-039).
        shell.onSetRepeatCount = { [weak self, weak core] markupID, count in
            guard self != nil, let core else { return false }
            do {
                _ = try await core.commands.perform(
                    RepetitionColumn.edit(markupID: MarkupID(markupID), count: count)
                )
                await core.refresh()
                // No explicit changeDone: the bus registers the undo and the document
                // counts it, so ⌘Z returns to clean (BH-375, R-018).
                return true
            } catch {
                // A refused edit is said, not swallowed (CR-156).
                Self.reportRefusedEdit(error, core: core)
                return false
            }
        }
        // Through the shell's library mirror, not the toolbar's own arming methods: those are a
        // person choosing a tool, which puts the preset down (X-018). The mirror names the preset
        // in the toolbar's selection and lights Select when the preset arms no drawing tool.
        core.onLibraryArmedTool = { [weak shell] mode in shell?.libraryArmed(mode) }
        refreshProjectStructure(shell: shell, core: core)
    }

    /// Re-reads the document into both panels: regions, their overlaps, zones and their counts.
    ///
    /// Called after every command, because a region's markup count and a zone's subtotal are
    /// facts about the takeoff, not about the panel.
    func refreshProjectStructure(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        shell.refreshScaleRegions()
        shell.refreshProjectZones()
        let regions = core.document.scaleRegions
        let pageID = core.document.currentPageID
        // Only the newest refresh may write the panel: an older one finishing last set the
        // previous page's overlaps and counts on the panel for the new page (BH-916).
        // Counted per window (NL-UX-20): a second window's refresh must not void this one's.
        let window = ObjectIdentifier(shell)
        structureRefreshGenerations[window, default: 0] &+= 1
        let generation = structureRefreshGenerations[window] ?? 0
        Task { @MainActor [weak self] in
            guard let self, self.structureRefreshGenerations[window] == generation else { return }
            guard let pageID else {
                shell.scaleRegions.setOverlaps([])
                shell.scaleRegions.setMarkupCounts([:])
                return
            }
            let counts = await core.session.markupCountsByScaleRegion()
            let pairs = await core.session.overlappingScaleRegions(page: PageID(pageID))
            guard self.structureRefreshGenerations[window] == generation else { return }
            shell.scaleRegions.setMarkupCounts(
                Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
            )
            let byID = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
            shell.scaleRegions.setOverlaps(pairs.compactMap { pair in
                guard let first = byID[pair.0.rawValue], let second = byID[pair.1.rawValue]
                else { return nil }
                // The panel names the lower-priority region first, because that is the one the
                // person is most likely to redraw.
                let ordered = first.priority <= second.priority ? (first, second) : (second, first)
                return ScaleRegionOverlap(
                    first: ordered.0.id,
                    second: ordered.1.id,
                    firstName: ordered.0.name,
                    secondName: ordered.1.name
                )
            })
        }
    }

    // MARK: - Scale Regions

    private func wireScaleRegionsPanel(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        let panel = shell.scaleRegions

        panel.onBeginPolygon = { [weak self, weak shell, weak core] in
            guard let core, let shell else { return }
            shell.toolbar.activateMeasurement(.area)
            core.measurement.beginBoundaryCapture(.scaleRegion)
            core.status.setActiveTool(
                name: NSLocalizedString("Scale Region", comment: "Status bar: drawing a region boundary"),
                note: NSLocalizedString(
                    "Click the corners of the region, then press Return.",
                    comment: "Status bar note while a Scale Region boundary is being drawn"
                )
            )
            // Starting a draw persists nothing; the commit marks the document (CR-155).
        }

        // Same disarm-on-cancel as the zones panel (LT-36's cancel half).
        panel.onCancelPolygonDrawing = { [weak shell, weak core] in
            guard let core, let shell else { return }
            if core.measurement.isCapturingBoundary {
                core.measurement.cancelActiveMeasurement()
            }
            shell.toolbar.selectTool(.select)
            shell.refreshArmedToolStatusForStructure()
        }

        panel.onCreateRegion = { [weak self, weak core] creation in
            guard let self, let core else { return }
            self.enqueueStructureEdit {
                var regions = await core.session.scaleRegionDefinitions
                regions.append(
                    ScaleRegionDefinition(
                        id: ScaleRegionID(creation.id),
                        pageID: PageID(creation.pageID),
                        name: creation.name,
                        boundary: creation.boundary.map { PDFPoint(x: $0.x, y: $0.y) },
                        scaleID: ScaleID(creation.scale.id),
                        priority: creation.priority,
                        locked: creation.locked,
                        isVisible: true,
                        colorRGBA: creation.colorRGBA
                    )
                )
                await self.applyScaleRegions(regions, core: core, panel: panel)
            }
        }

        panel.onRenameRegion = { [weak self, weak core] regionID, name in
            guard let self, let core else { return }
            self.editRegion(regionID, core: core, panel: panel) { $0.name = name }
        }

        panel.onAssignScale = { [weak self, weak core] regionID, scale in
            guard let self, let core else { return }
            self.editRegion(regionID, core: core, panel: panel) { $0.scaleID = ScaleID(scale.id) }
        }

        panel.onSetLocked = { [weak self, weak core] regionID, locked in
            guard let self, let core else { return }
            self.editRegion(regionID, core: core, panel: panel) { $0.locked = locked }
        }

        panel.onSetVisible = { [weak self, weak core] regionID, visible in
            guard let self, let core else { return }
            self.editRegion(regionID, core: core, panel: panel) { $0.isVisible = visible }
        }

        panel.onDeleteRegion = { [weak self, weak core] regionID in
            guard let self, let core else { return }
            self.enqueueStructureEdit {
                var regions = await core.session.scaleRegionDefinitions
                regions.removeAll { $0.id.rawValue == regionID }
                await self.applyScaleRegions(regions, core: core, panel: panel)
            }
        }

        panel.onReorderRegions = { [weak self, weak core] orderedIDs in
            guard let self, let core else { return }
            self.enqueueStructureEdit {
                let existing = await core.session.scaleRegionDefinitions
                // Highest priority first, as the panel publishes them, so the numbers the
                // resolver reads match the order the person just dragged into place.
                let updated = Self.reorderedRegions(existing, orderedIDs: orderedIDs)
                await self.applyScaleRegions(updated, core: core, panel: panel)
            }
        }

        panel.onCalibrateRegion = { [weak self, weak core] regionID in
            guard let self, let core else { return }
            // The current page's scale: a Scale Region is drawn on a sheet, and the sheet has
            // to have a scale of its own before a region can carry a second one beside it.
            guard core.document.currentPageScale != nil else {
                panel.rejectDraft(reason: Self.calibratePageFirstMessage)
                return
            }
            self.pendingScaleCalibration = .region(regionID)
            self.onBeginCalibration?()
        }

        panel.onCalibrateDraft = { [weak self, weak core] _ in
            guard let self, let core else { return }
            guard core.document.currentPageScale != nil else {
                panel.rejectDraft(reason: Self.calibratePageFirstMessage)
                return
            }
            self.pendingScaleCalibration = .draft
            self.onBeginCalibration?()
        }

        panel.onRevealOverlap = { [weak self, weak shell] overlap in
            guard let self, let shell else { return }
            let regions = shell.scaleRegions.regions
            guard let first = regions.first(where: { $0.id == overlap.first }),
                  let second = regions.first(where: { $0.id == overlap.second }),
                  let a = first.boundsInPageSpace,
                  let b = second.boundsInPageSpace
            else { return }
            // The shared area, as a rectangle. It reveals; it never resolves — picking a
            // winner here would be the app choosing a scale, which spec §10.4 forbids.
            let minX = max(a.origin.x, b.origin.x)
            let minY = max(a.origin.y, b.origin.y)
            let maxX = min(a.origin.x + a.size.width, b.origin.x + b.size.width)
            let maxY = min(a.origin.y + a.size.height, b.origin.y + b.size.height)
            guard maxX > minX, maxY > minY else { return }
            self.onRevealPageRect?(
                PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            )
        }

        // A refused delete's Show Measurements: select the markups the region is the scale
        // for and bring them on screen, so the refusal leads somewhere (IM-209's host half).
        panel.onRevealMarkups = { [weak self, weak core] regionID in
            guard let self, let core else { return }
            Task { @MainActor in
                let ids = await Self.markupIDs(measuredBy: regionID, core: core)
                guard !ids.isEmpty else { return }
                core.canvas.select(markupIDs: ids, additive: false)
                self.onZoomToSelection?()
            }
        }

        panel.onResolveCrossing = { [weak self, weak core] crossingID, resolution in
            guard let self, let core else { return }
            Task { @MainActor in
                await core.resolveScaleRegionCrossing(
                    id: crossingID,
                    outcome: Self.outcome(for: resolution)
                )
                await core.refresh()
                self.refreshProjectStructureIfPossible()
                // Using a scale adds the markup through the bus, which counts the change; the
                // `.block` answer creates nothing and must not dirty the document (R-018).
            }
        }
    }

    /// The markups a Scale Region is the scale for.
    static func markupIDs(measuredBy regionID: UUID, core: AppCoreEnvironment) async -> Set<UUID> {
        Set(await core.session.orderedMarkups
            .filter { $0.scaleRegionID?.rawValue == regionID }
            .map(\.id.rawValue))
    }

    /// Runs a read-modify-write of the region or zone set after every earlier one has landed.
    ///
    /// Each edit reads the whole set, changes one field and writes the whole set back. Two in
    /// one turn — a rename committed by focus loss and the Lock click that caused it — both
    /// read the old set and the second write reverted the first, silently (BH-384).
    func enqueueStructureEdit(_ body: @escaping @MainActor () async -> Void) {
        let previous = structureEditTail
        structureEditTail = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// Waits for every queued structure edit. Test seam.
    func settleStructureEdits() async {
        while let tail = structureEditTail {
            await tail.value
            if structureEditTail == tail { break }
        }
    }

    /// The zone set after deleting one zone: its children move up to **its** parent, so a
    /// Building > Floor 2 > Apt 201 chain keeps Apt 201 under Building (BH-385).
    static func deletingZone(_ zoneID: UUID, from zones: [ProjectZoneDefinition]) -> [ProjectZoneDefinition] {
        let grandparent = zones.first { $0.id.rawValue == zoneID }?.parentID
        var remaining = zones.filter { $0.id.rawValue != zoneID }
        for index in remaining.indices where remaining[index].parentID?.rawValue == zoneID {
            remaining[index].parentID = grandparent
        }
        return remaining
    }

    /// The region set after a drag reorder: priorities follow the new order, **except a locked
    /// region's**, which keeps its exact priority as the panel promises (CR-178). The wiring
    /// used to rewrite every id, so the next refresh undid the lock's guarantee (BH-917).
    static func reorderedRegions(_ existing: [ScaleRegionDefinition], orderedIDs: [UUID]) -> [ScaleRegionDefinition] {
        let top = orderedIDs.count
        return existing.map { region in
            var copy = region
            if !region.locked, let index = orderedIDs.firstIndex(of: region.id.rawValue) {
                copy.priority = top - index
            }
            return copy
        }
    }

    /// The sort order a new zone takes: one past the largest in use.
    static func nextZoneSortOrder(_ zones: [ProjectZoneDefinition]) -> Int {
        (zones.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Applies one whole-set region edit through the command bus, then re-reads the panels.
    private func applyScaleRegions(
        _ regions: [ScaleRegionDefinition],
        core: AppCoreEnvironment,
        panel: ScaleRegionsPanelModel
    ) async {
        do {
            try await core.commands.perform(.setScaleRegions(regions))
            await core.refresh()
            refreshProjectStructureIfPossible()
        } catch {
            panel.rejectDraft(reason: Self.scaleRegionRefusal(error))
        }
    }

    /// The sentence the Scale Regions panel shows for a refused region edit.
    ///
    /// A scale calibrated on another sheet has its own sentence, naming what to do in this panel
    /// (T-056: it read "scale <UUID> belongs to another page and cannot be used on page <UUID>").
    /// Every other refusal is the core's plain sentence (``UserFacingRefusal``) — never the error's
    /// `description`, which read "measurement failed: …" with an identifier in it (L-102).
    static func scaleRegionRefusal(_ error: any Error) -> String {
        if case DocumentCommandError.scaleBelongsToAnotherPage = error {
            return NSLocalizedString(
                "That scale was calibrated on another sheet. Pick one of this sheet's scales, or calibrate the region on the drawing.",
                comment: "Scale Regions panel refusal: the chosen scale belongs to another sheet"
            )
        }
        return UserFacingRefusal.sentence(for: error)
    }

    /// Edits one region in place and applies the whole set.
    private func editRegion(
        _ regionID: UUID,
        core: AppCoreEnvironment,
        panel: ScaleRegionsPanelModel,
        _ edit: @escaping @Sendable (inout ScaleRegionDefinition) -> Void
    ) {
        enqueueStructureEdit {
            var regions = await core.session.scaleRegionDefinitions
            guard let index = regions.firstIndex(where: { $0.id.rawValue == regionID }) else { return }
            edit(&regions[index])
            await self.applyScaleRegions(regions, core: core, panel: panel)
        }
    }

    // MARK: - Project Zones

    private func wireProjectZonesPanel(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        let panel = shell.projectZones

        panel.onBeginBoundary = { [weak shell, weak core] in
            guard let core, let shell else { return }
            shell.toolbar.activateMeasurement(.area)
            core.measurement.beginBoundaryCapture(.projectZone)
            core.status.setActiveTool(
                name: NSLocalizedString("Project Zone", comment: "Status bar: drawing a zone boundary"),
                note: NSLocalizedString(
                    "Click the corners of the zone, then press Return.",
                    comment: "Status bar note while a Project Zone boundary is being drawn"
                )
            )
        }

        // The panel's own Cancel must disarm the canvas too: banner gone with the tool
        // still armed and the status bar still instructing was LT-35's third break.
        panel.onCancelBoundaryDrawing = { [weak shell, weak core] in
            guard let core, let shell else { return }
            if core.measurement.isCapturingBoundary {
                core.measurement.cancelActiveMeasurement()
            }
            shell.toolbar.selectTool(.select)
            shell.refreshArmedToolStatusForStructure()
        }

        panel.onCreateZone = { [weak self, weak core] creation in
            guard let self, let core else { return }
            self.enqueueStructureEdit {
                var zones = await core.session.projectZoneDefinitions
                let zone = ProjectZoneDefinition(
                    id: ZoneID(creation.id),
                    name: creation.name,
                    kind: creation.kind,
                    parentID: creation.parentID.map(ZoneID.init),
                    pageID: creation.pageID.map(PageID.init),
                    boundary: creation.boundary.map { PDFPoint(x: $0.x, y: $0.y) },
                    // After the largest order in use, not at the count: after a deletion the
                    // count collides with a surviving zone's order (BH-918).
                    sortOrder: Self.nextZoneSortOrder(zones),
                    isVisible: true,
                    colorRGBA: creation.colorRGBA
                )
                zones.append(zone)
                // L-92: the markups already inside the boundary are filed with the zone.
                let enclosed = ProjectZoneFiling.markupsEnclosed(
                    by: zone, among: await core.session.orderedMarkups, zones: zones
                )
                await self.applyZoneCreation(zones, zone: zone, filing: enclosed, core: core)
            }
        }

        panel.onRenameZone = { [weak self, weak core] zoneID, name in
            guard let self, let core else { return }
            self.editZone(zoneID, core: core) { $0.name = name }
        }
        panel.onSetZoneKind = { [weak self, weak core] zoneID, kind in
            guard let self, let core else { return }
            self.editZone(zoneID, core: core) { $0.kind = kind }
        }
        panel.onSetZoneColor = { [weak self, weak core] zoneID, color in
            guard let self, let core else { return }
            self.editZone(zoneID, core: core) { $0.colorRGBA = color }
        }
        panel.onSetZoneParent = { [weak self, weak core] zoneID, parentID in
            guard let self, let core else { return }
            self.editZone(zoneID, core: core) { $0.parentID = parentID.map(ZoneID.init) }
        }
        panel.onSetZoneVisible = { [weak self, weak core] zoneID, visible in
            guard let self, let core else { return }
            self.editZone(zoneID, core: core) { $0.isVisible = visible }
        }

        panel.onDeleteZone = { [weak self, weak core] zoneID in
            guard let self, let core else { return }
            self.enqueueStructureEdit {
                let zones = Self.deletingZone(zoneID, from: await core.session.projectZoneDefinitions)
                await self.applyProjectZones(zones, core: core)
            }
        }

        panel.onAssignSelection = { [weak self, weak core] zoneID in
            guard let self, let core else { return }
            let selected = core.canvas.selectedMarkupIDs
            guard !selected.isEmpty else { return }
            Task { @MainActor in
                do {
                    try await core.commands.perform(
                        .setMarkupZone(
                            ids: selected.sorted { $0.uuidString < $1.uuidString }.map(MarkupID.init),
                            zoneID: ZoneID(zoneID)
                        )
                    )
                    await core.refresh()
                    self.refreshProjectStructureIfPossible()
                } catch {
                    Self.reportStructureFailure(error, core: core)
                }
            }
        }
    }

    /// Creates a zone and files the markups its boundary encloses, in one step: one ⌘Z takes
    /// back both (L-92). A zone drawn round markups already on the sheet used to file none of
    /// them — it showed 0, and Group by Zone said nothing was filed yet.
    private func applyZoneCreation(
        _ zones: [ProjectZoneDefinition],
        zone: ProjectZoneDefinition,
        filing enclosed: [MarkupID],
        core: AppCoreEnvironment
    ) async {
        guard !enclosed.isEmpty else {
            await applyProjectZones(zones, core: core)
            return
        }
        do {
            try await core.commands.performBatch(
                [.setProjectZones(zones), .setMarkupZone(ids: enclosed, zoneID: zone.id)],
                actionName: NSLocalizedString("Edit Project Zones", comment: "Undo action name for a Project Zone change")
            )
            await core.refresh()
            refreshProjectStructureIfPossible()
            core.status.setActiveToolNote(Self.zoneFilingNote(zoneName: zone.name, count: enclosed.count))
        } catch {
            Self.reportStructureFailure(error, core: core)
        }
    }

    /// The status line after a new zone filed the markups inside it.
    static func zoneFilingNote(zoneName: String, count: Int) -> String {
        String(
            format: NSLocalizedString(
                "Zone “%1$@” created; %2$d markup(s) inside its boundary were filed into it.",
                comment: "Status note after creating a Project Zone filed the markups already inside its boundary; zone name and count"
            ),
            zoneName, count
        )
    }

    private func applyProjectZones(_ zones: [ProjectZoneDefinition], core: AppCoreEnvironment) async {
        do {
            try await core.commands.perform(.setProjectZones(zones))
            await core.refresh()
            refreshProjectStructureIfPossible()
        } catch {
            Self.reportStructureFailure(error, core: core)
        }
    }

    private func editZone(
        _ zoneID: UUID,
        core: AppCoreEnvironment,
        _ edit: @escaping @Sendable (inout ProjectZoneDefinition) -> Void
    ) {
        enqueueStructureEdit {
            var zones = await core.session.projectZoneDefinitions
            guard let index = zones.firstIndex(where: { $0.id.rawValue == zoneID }) else { return }
            edit(&zones[index])
            await self.applyProjectZones(zones, core: core)
        }
    }

    // MARK: - The boundary the canvas draws

    private func wireBoundaryCapture(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        core.measurement.onCommitBoundary = { [weak shell, weak core] purpose, points, pageID in
            guard let shell, let core else { return }
            let label = core.document.pages.first { $0.id == pageID.rawValue }?.label ?? ""
            switch purpose {
            case .scaleRegion:
                shell.scaleRegions.completePolygon(points, pageID: pageID.rawValue, pageLabel: label)
            case .projectZone:
                shell.projectZones.completeBoundary(points, pageID: pageID.rawValue, pageLabel: label)
            }
            shell.toolbar.selectTool(.select)
            shell.refreshArmedToolStatusForStructure()
        }
        core.measurement.onCancelBoundary = { [weak shell] purpose in
            guard let shell else { return }
            switch purpose {
            case .scaleRegion: shell.scaleRegions.cancelRegionCreation()
            // A tool switch or a canvas Escape stops the drawing and keeps the named draft
            // (BH-304, host half); Cancel in the panel is what
            // discards it.
            case .projectZone: shell.projectZones.stopBoundaryDrawing()
            }
            shell.toolbar.selectTool(.select)
            shell.refreshArmedToolStatusForStructure()
        }
    }

    // MARK: - The crossing prompt

    private func wireCrossingPrompt(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        core.onScaleRegionCrossing = { [weak self, weak shell, weak core] pending in
            guard let self, let shell, let core else { return }
            let summaries = core.document.scaleRegions
            let regions = pending.regionIDs.compactMap { id in
                summaries.first { $0.id == id.rawValue }
            }
            let pageLabel = core.document.pages
                .first { $0.id == pending.record.pageID.rawValue }?.label ?? ""
            shell.scaleRegions.present(
                crossing: ScaleRegionCrossing(
                    id: pending.id,
                    // The subject a fresh measurement carries is its tool's own name, so the
                    // headline reads "This Area crosses…"
                    // without a second tool-name table to keep in step with the palette.
                    measurementName: pending.record.subject.isEmpty
                        ? NSLocalizedString("measurement", comment: "Generic measurement name")
                        : pending.record.subject,
                    pageLabel: pageLabel,
                    regions: regions,
                    canSplitAtBoundary: pending.canSplitAtBoundary,
                    // The page default is offered only when part of the geometry is really
                    // outside every region. Offering it otherwise would invite a scale that
                    // applies to none of the drawing the measurement covers.
                    // The scale of the page the measurement is *on*, not of whatever page is
                    // current. The two are normally the same and the one time they are not is
                    // exactly when offering the wrong one would put a ratio from another sheet
                    // behind a measurement.
                    pageDefaultScale: pending.touchesPageDefault
                        ? core.snapshot.scale(onPage: pending.record.pageID.rawValue)
                        : nil
                )
            )
            // The question has to be visible to be answered, so the panel opens itself.
            self.presentScaleRegionsPanel()
        }
    }

    // MARK: - The Inspector's Scale Region row

    private func wireInspectorScaleRegion(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        // The Scale Region row in the Inspector's Measurement section. The control
        // has rendered since the Inspector was written and did nothing, because there was no
        // command behind it; there is one now, and it carries the region's scale with it.
        shell.inspectorEditing.onAssignScaleRegion = { [weak self, weak core] markupIDs, regionID in
            guard let self, let core, !markupIDs.isEmpty else { return }
            Task { @MainActor in
                do {
                    try await core.commands.perform(
                        .setMarkupScaleRegion(
                            ids: markupIDs.sorted { $0.uuidString < $1.uuidString }.map(MarkupID.init),
                            regionID: regionID.map(ScaleRegionID.init),
                            scaleID: nil
                        )
                    )
                    await core.refresh()
                    self.refreshProjectStructureIfPossible()
                } catch {
                    Self.reportStructureFailure(error, core: core)
                }
            }
        }
    }

    // MARK: - The Inspector header's Lock and Hide

    private func wireInspectorLockAndHide(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        // The same code Edit ▸ Lock and Edit ▸ Hide run (IM-023, R-041): one undo step each.
        // The command bus dirties the document when a command lands, so nothing marks it here.
        shell.inspectorEditing.onSetLocked = { [weak core] markupIDs, locked in
            guard let core, !markupIDs.isEmpty else { return }
            Task { @MainActor in await Self.performLockHide(ids: markupIDs, lock: locked, hide: nil, core: core) }
        }
        shell.inspectorEditing.onSetHidden = { [weak core] markupIDs, hidden in
            guard let core, !markupIDs.isEmpty else { return }
            Task { @MainActor in await Self.performLockHide(ids: markupIDs, lock: nil, hide: hidden, core: core) }
        }
    }

    /// Locks or unlocks, and hides or shows, `ids` through the bus — one undo step each — and
    /// says a refusal. A hidden markup leaves the selection: Delete would act on something
    /// unseen. The one implementation behind Edit ▸ Lock / Hide and the Inspector header's
    /// switches, which each carried a copy (R-041).
    static func performLockHide(ids: Set<UUID>, lock: Bool?, hide: Bool?, core: AppCoreEnvironment) async {
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }.map(MarkupID.init)
        guard !ordered.isEmpty else { return }
        do {
            if let lock {
                _ = try await core.commands.perform(.setLocked(ids: ordered, locked: lock))
            }
            if let hide {
                // L-77: a locked markup refuses the hide, and the refusal went to the warnings
                // tray only — Hide Selection looked like it did nothing. The unlocked markups are
                // hidden, and the status line says which were not and how to change that.
                let locked = lock == nil ? lockedMarkups(among: ids, notAlready: hide, core: core) : []
                let changeable = ordered.filter { !locked.contains($0.rawValue) }
                if !changeable.isEmpty {
                    _ = try await core.commands.perform(.setHidden(ids: changeable, hidden: hide))
                    if hide { core.canvas.select(markupIDs: Set(locked), additive: false) }
                }
                if !locked.isEmpty {
                    core.status.setActiveToolNote(lockedHideNote(count: locked.count, hide: hide))
                }
            }
        } catch {
            reportRefusedEdit(error, core: core)
        }
    }

    /// The markups among `ids` that are locked and whose hidden flag would change (L-77).
    static func lockedMarkups(among ids: Set<UUID>, notAlready hidden: Bool, core: AppCoreEnvironment) -> Set<UUID> {
        Set(core.snapshot.markups.filter { ids.contains($0.id) && $0.locked && $0.hidden != hidden }.map(\.id))
    }

    /// What Hide Selection (or Show) says about the locked markups it left alone (L-77).
    static func lockedHideNote(count: Int, hide: Bool) -> String {
        if hide {
            return LocalizedPlural.string(
                "%lld locked markups were not hidden. Unlock them first (Edit ▸ Unlock Selection).",
                count: count,
                one: NSLocalizedString(
                    "%lld locked markup was not hidden. Unlock it first (Edit ▸ Unlock Selection).",
                    comment: "Status note: Hide Selection reached a locked markup; the number"
                ),
                other: NSLocalizedString(
                    "%lld locked markups were not hidden. Unlock them first (Edit ▸ Unlock Selection).",
                    comment: "Status note: Hide Selection reached several locked markups; the number"
                )
            )
        }
        return LocalizedPlural.string(
            "%lld locked markups were not shown. Unlock them first (Edit ▸ Unlock Selection).",
            count: count,
            one: NSLocalizedString(
                "%lld locked markup was not shown. Unlock it first (Edit ▸ Unlock Selection).",
                comment: "Status note: showing reached a locked hidden markup; the number"
            ),
            other: NSLocalizedString(
                "%lld locked markups were not shown. Unlock them first (Edit ▸ Unlock Selection).",
                comment: "Status note: showing reached several locked hidden markups; the number"
            )
        )
    }

    /// The `/UserUnit` of a page of this drawing; 1 when unknown.
    func pageUserUnit(for pageID: UUID?) -> Double {
        guard let pageID, let page = drawing?.pages.first(where: { $0.id.rawValue == pageID }) else { return 1 }
        return page.userUnit
    }

    // MARK: - Calibration destinations

    /// Finishes a calibration that was started for a Scale Region rather than for the page.
    ///
    /// - Returns: `true` when the calibration was consumed here, so the ordinary page-default
    ///   path must not also run.
    @discardableResult
    public func completeScaleRegionCalibration(
        scale: ScaleTransform,
        shell: ProjectShellEnvironment
    ) async -> Bool {
        guard let core, let target = pendingScaleCalibration, target != .pageDefault else {
            return false
        }
        pendingScaleCalibration = nil
        // The page's /UserUnit reaches the ratio shown for the region (the BH-092
        // remainder).
        let summary = ScaleSummary(
            domain: scale, name: nil, userUnit: pageUserUnit(for: core.document.currentPageID)
        )
        switch target {
        case .pageDefault:
            return false
        case .draft:
            shell.scaleRegions.assignDraftScale(summary)
        case let .region(regionID):
            var regions = await core.session.scaleRegionDefinitions
            guard let index = regions.firstIndex(where: { $0.id.rawValue == regionID }) else {
                // The region went while its calibration was being entered: say so, rather
                // than let the person believe it was calibrated (BH-919).
                core.status.setActiveToolNote(Self.calibratedRegionGoneMessage)
                return true
            }
            regions[index].scaleID = scale.id
            await applyScaleRegions(regions, core: core, panel: shell.scaleRegions)
        }
        await core.refresh()
        refreshProjectStructureIfPossible()
        return true
    }

    static let calibratedRegionGoneMessage = NSLocalizedString(
        "That Scale Region was deleted while it was being calibrated, so the new scale was not assigned to any region.",
        comment: "Status note when a region calibration finishes after the region was deleted"
    )

    /// Puts a refused structure edit in front of the person, in words.
    ///
    /// The tray, not a modal: these edits happen while someone is looking at the drawing, and
    /// a sheet over the canvas mid-takeoff is its own defect. One fixed identity, so a second
    /// refusal replaces the first rather than stacking.
    static func reportStructureFailure(_ error: any Error, core: AppCoreEnvironment) {
        core.document.post(
            AppWarning(
                id: structureFailureWarningID,
                severity: .danger,
                title: NSLocalizedString(
                    "That change to the project structure was not made.",
                    comment: "Warning headline when a Scale Region or Project Zone edit is refused"
                ),
                message: String(
                    format: NSLocalizedString(
                        "Nothing was changed. %@",
                        comment: "Warning detail; the placeholder is the reason, as a sentence"
                    ),
                    // L-102: the reason in words, never the core's raw description.
                    UserFacingRefusal.sentence(for: error)
                ),
                source: NSLocalizedString("Project structure", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// A refused canvas or inspector edit — a delete, a move, a vertex drag, a Repeat count —
    /// said in words. `try?` on the command bus used to swallow these: a refused delete still
    /// cleared the selection, a refused move snapped back with no word (CR-156).
    static func reportRefusedEdit(_ error: any Error, core: AppCoreEnvironment) {
        core.document.post(
            AppWarning(
                id: structureFailureWarningID,
                severity: .danger,
                title: NSLocalizedString(
                    "That edit was not made.",
                    comment: "Warning headline when a canvas or inspector edit is refused by the core"
                ),
                message: String(
                    format: NSLocalizedString(
                        "Nothing was changed. %@",
                        comment: "Warning detail; the placeholder is the reason, as a sentence"
                    ),
                    // L-102: the reason in words, never the core's raw description.
                    UserFacingRefusal.sentence(for: error)
                ),
                source: NSLocalizedString("Editing", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    private static let structureFailureWarningID =
        UUID(uuidString: "3F5B9C10-7A44-4C1B-9E63-9C1A5D2F7B44")!

    /// Re-reads both panels when the document is fully built. A no-op before that.
    func refreshProjectStructureIfPossible() {
        guard let shell, let core else { return }
        refreshProjectStructure(shell: shell, core: core)
    }

    private static var calibratePageFirstMessage: String {
        NSLocalizedString(
            "Calibrate the sheet first. A Scale Region overrides the page scale, so there has to be one to override.",
            comment: "Refusal when a Scale Region calibration is asked for before the page has any scale"
        )
    }

    /// The core outcome for one of the panel's three choices.
    static func outcome(for resolution: ScaleRegionCrossingResolution) -> ScaleRegionCrossingOutcome {
        switch resolution {
        case .splitAtBoundary: .splitAtBoundary
        case let .useScale(regionID): .useScale(regionID: regionID.map(ScaleRegionID.init))
        case .block: .block
        }
    }
}

extension ProjectShellEnvironment {

    /// Puts the status bar back on whatever tool the toolbar is holding.
    ///
    /// `refreshArmedToolStatus` is internal to the shell package; boundary capture borrows the
    /// status line while it runs and has to hand it back, so this is the one public way to say
    /// "the borrowed line is finished with".
    func refreshArmedToolStatusForStructure() {
        let mode = toolbar.activeSelection.mode
        status.setActiveTool(name: mode.displayName, note: mode.limitationNote)
    }
}
