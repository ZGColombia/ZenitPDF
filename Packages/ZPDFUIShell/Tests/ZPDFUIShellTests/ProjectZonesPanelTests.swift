import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

@MainActor
private enum ZoneFixture {

    static func zone(
        _ name: String,
        kind: ProjectZoneKind = .room,
        parentID: UUID? = nil,
        markupCount: Int = 0,
        visible: Bool = true,
        color: ColorRGBA = ColorRGBA.Zenit.Dark.cyan,
        id: UUID = UUID()
    ) -> ProjectZoneSummary {
        ProjectZoneSummary(
            id: id,
            name: name,
            kind: kind,
            parentID: parentID,
            colorRGBA: color,
            markupCount: markupCount,
            isVisible: visible
        )
    }

    /// A model with the creation hook wired, which is the state the shipping panel is in.
    static func wiredModel(zones: [ProjectZoneSummary] = []) -> ProjectZonesPanelModel {
        let model = ProjectZonesPanelModel(zones: zones)
        model.onCreateZone = { _ in }
        return model
    }
}

/// The half of Project Zones that did not exist: making one.
@Suite("Project Zones: creating a zone", .shellTierSerialised)
@MainActor
struct ProjectZoneCreationTests {

    @Test("Add Zone opens a draft named, typed and coloured, before anything is drawn")
    func addOpensADraft() {
        let model = ZoneFixture.wiredModel(zones: [ZoneFixture.zone("Ground Floor")])
        model.beginZone()

        let draft = try? #require(model.draft)
        #expect(draft?.name == "Zone 2")
        #expect(draft?.kind == .room)
        #expect(draft?.hasBoundary == false)
        #expect(model.canCommitDraft, "a zone with no boundary is still a zone")
    }

    @Test("A zone is created with its name, type, colour and parent")
    func createdZoneCarriesEverythingChosen() {
        let parent = ZoneFixture.zone("Building A", kind: .buildingSection)
        let model = ZoneFixture.wiredModel(zones: [parent])
        var created: [ProjectZoneCreation] = []
        model.onCreateZone = { created.append($0) }

        model.beginZone()
        model.setDraftName("Apartment 12")
        model.setDraftKind(.apartment)
        model.setDraftColor(paletteID: "green")
        model.setDraftParent(parent.id)
        #expect(model.commitDraft())

        #expect(created.count == 1)
        #expect(created.first?.name == "Apartment 12")
        #expect(created.first?.kind == .apartment)
        #expect(created.first?.parentID == parent.id)
        #expect(created.first?.colorRGBA == ZenitMarkupPalette.color(for: "green"))
        #expect(created.first?.boundary.isEmpty == true)
        #expect(model.draft == nil)
        #expect(model.selection == created.first?.id)
    }

    @Test("A drawn boundary is carried onto the zone with the page it was drawn on")
    func aDrawnBoundaryIsCarried() {
        let model = ZoneFixture.wiredModel()
        var created: [ProjectZoneCreation] = []
        model.onCreateZone = { created.append($0) }
        var armed = 0
        model.onBeginBoundary = { armed += 1 }
        let pageID = UUID()
        let boundary = [
            PDFPointValue(x: 0, y: 0),
            PDFPointValue(x: 80, y: 0),
            PDFPointValue(x: 80, y: 60)
        ]

        model.beginZone()
        #expect(model.beginBoundary())
        #expect(armed == 1)
        #expect(model.isAwaitingBoundary)
        #expect(model.completeBoundary(boundary, pageID: pageID, pageLabel: "A-101"))
        #expect(!model.isAwaitingBoundary)
        #expect(model.draft?.hasBoundary == true)
        #expect(model.commitDraft())

        #expect(created.first?.boundary == boundary)
        #expect(created.first?.pageID == pageID)
    }

    @Test("A blank or duplicated name is refused, with the name in the sentence")
    func namesAreValidated() {
        let model = ZoneFixture.wiredModel(zones: [ZoneFixture.zone("Ground Floor")])
        model.beginZone()

        model.setDraftName("  ")
        #expect(!model.canCommitDraft)
        #expect(!model.commitDraft())
        #expect(model.refusal == .nameEmpty)

        model.setDraftName("Ground Floor")
        #expect(!model.commitDraft())
        #expect(model.refusal == .nameTaken("Ground Floor"))
        #expect(model.refusal?.message.contains("Ground Floor") == true)
    }

    @Test("Two points cannot bound a zone")
    func twoPointBoundaryIsRefused() {
        let model = ZoneFixture.wiredModel()
        model.onBeginBoundary = {}
        model.beginZone()
        model.beginBoundary()
        #expect(!model.completeBoundary(
            [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 5, y: 5)],
            pageID: UUID(),
            pageLabel: "A-101"
        ))
        #expect(model.refusal == .boundaryTooFewPoints(count: 2))
        #expect(model.draft?.hasBoundary == false, "the draft keeps its no-boundary state")
    }

    @Test("An unwired panel refuses out loud instead of pretending to create a zone")
    func unwiredPanelDoesNotPretend() {
        let model = ProjectZonesPanelModel()
        model.beginZone()
        model.setDraftName("Ground Floor")
        #expect(!model.commitDraft())
        #expect(model.refusal == .notWired)
        #expect(model.draft != nil, "the refusal keeps the work")
    }
}

/// Naming, colour, nesting, visibility and deletion on zones that exist.
@Suite("Project Zones: editing a zone", .shellTierSerialised)
@MainActor
struct ProjectZoneEditingTests {

    @Test("Renaming, recolouring and retyping all reach the app tier")
    func editsReachTheAppTier() {
        let zone = ZoneFixture.zone("Ground Floor")
        let model = ZoneFixture.wiredModel(zones: [zone])
        var renamed: [(UUID, String)] = []
        var recoloured: [(UUID, ColorRGBA)] = []
        var retyped: [(UUID, ProjectZoneKind)] = []
        var visibility: [(UUID, Bool)] = []
        model.onRenameZone = { renamed.append(($0, $1)) }
        model.onSetZoneColor = { recoloured.append(($0, $1)) }
        model.onSetZoneKind = { retyped.append(($0, $1)) }
        model.onSetZoneVisible = { visibility.append(($0, $1)) }

        #expect(model.rename(zoneID: zone.id, to: "  Basement  "))
        #expect(renamed.first?.1 == "Basement", "the name is trimmed before it is stored")
        #expect(model.setColor(paletteID: "amber", zoneID: zone.id))
        #expect(recoloured.first?.1 == ZenitMarkupPalette.color(for: "amber"))
        #expect(model.setKind(.floor, zoneID: zone.id))
        #expect(retyped.first?.1 == .floor)
        #expect(model.setVisible(false, zoneID: zone.id))
        #expect(visibility.first?.1 == false)
    }

    @Test("A zone cannot be nested inside itself or inside its own descendant")
    func nestingCannotCycle() {
        let parent = ZoneFixture.zone("Building A")
        let child = ZoneFixture.zone("Floor 1", parentID: parent.id)
        let grandchild = ZoneFixture.zone("Room 3", parentID: child.id)
        let model = ZoneFixture.wiredModel(zones: [parent, child, grandchild])
        var reparented = 0
        model.onSetZoneParent = { _, _ in reparented += 1 }

        #expect(!model.setParent(parent.id, zoneID: parent.id))
        #expect(model.refusal == .circularParent(name: "Building A"))
        #expect(!model.setParent(grandchild.id, zoneID: parent.id))
        #expect(model.refusal == .circularParent(name: "Room 3"))
        #expect(reparented == 0)

        #expect(model.setParent(parent.id, zoneID: grandchild.id), "a legal move still works")
        #expect(reparented == 1)
    }

    @Test("Deleting a zone that still holds markups is refused, with the count")
    func deletingANonEmptyZoneIsRefused() {
        let zone = ZoneFixture.zone("Ground Floor", markupCount: 41)
        let model = ZoneFixture.wiredModel(zones: [zone])
        var deleted = 0
        model.onDeleteZone = { _ in deleted += 1 }

        #expect(!model.delete(zoneID: zone.id))
        #expect(model.refusal == .zoneNotEmpty(name: "Ground Floor", markupCount: 41))
        #expect(model.refusal?.message.contains("41") == true)
        #expect(deleted == 0)
    }

    @Test("Deleting an empty zone works and drops the selection with it")
    func deletingAnEmptyZoneWorks() {
        let zone = ZoneFixture.zone("Ground Floor")
        let model = ZoneFixture.wiredModel(zones: [zone])
        var deleted: [UUID] = []
        model.onDeleteZone = { deleted.append($0) }
        model.selection = zone.id

        #expect(model.delete(zoneID: zone.id))
        #expect(deleted == [zone.id])
        #expect(model.selection == nil)
    }

    @Test("An action on a zone that is gone refuses instead of touching the wrong one")
    func staleIdentitiesRefuse() {
        let model = ZoneFixture.wiredModel(zones: [ZoneFixture.zone("Only")])
        #expect(!model.rename(zoneID: UUID(), to: "Anything"))
        #expect(model.refusal == .unknownZone)
    }

    @Test("Children are reported per parent, so the list can be drawn as a tree")
    func nestingIsReadable() {
        let parent = ZoneFixture.zone("Building A")
        let child = ZoneFixture.zone("Floor 1", parentID: parent.id)
        let model = ZoneFixture.wiredModel(zones: [parent, child])
        #expect(model.children(of: nil).map(\.name) == ["Building A"])
        #expect(model.children(of: parent.id).map(\.name) == ["Floor 1"])
    }
}

/// The reason zones exist: they are a grouping key in the Quantity Ledger.
@Suite("Project Zones as a ledger grouping key", .shellTierSerialised)
@MainActor
struct ProjectZoneGroupingTests {

    @Test("The ledger's grouping menu offers Project Zone")
    func theGroupingLevelExists() {
        let option = LedgerPaneModel.groupingOptions.first { $0.column == .projectZone }
        #expect(option != nil)
        #expect(option?.title == "Project Zone")
    }

    @Test("Group by Zone asks the ledger for exactly that column")
    func groupingRequestIsRaised() {
        let model = ZoneFixture.wiredModel(zones: [ZoneFixture.zone("Ground Floor")])
        var requested: [LedgerColumnID] = []
        model.onGroupLedger = { requested.append($0) }
        #expect(model.groupLedgerByZone())
        #expect(requested == [.projectZone])
    }

    @Test("The panel says when grouping by zone would put everything in one group")
    func emptyGroupingIsStated() {
        let empty = ZoneFixture.wiredModel(zones: [ZoneFixture.zone("Ground Floor")])
        #expect(empty.ledgerGroupingWouldBeEmpty)
        #expect(empty.filedMarkupCount == 0)

        let filled = ZoneFixture.wiredModel(zones: [
            ZoneFixture.zone("Ground Floor", markupCount: 12),
            ZoneFixture.zone("Basement", markupCount: 5)
        ])
        #expect(!filled.ledgerGroupingWouldBeEmpty)
        #expect(filled.filedMarkupCount == 17)
    }

    @Test("Filing the canvas selection into a zone needs a selection, and says so")
    func filingASelectionNeedsASelection() {
        let zone = ZoneFixture.zone("Ground Floor")
        let model = ZoneFixture.wiredModel(zones: [zone])
        var filed: [UUID] = []
        model.onAssignSelection = { filed.append($0) }

        #expect(!model.assignSelection(to: zone.id))
        #expect(model.refusal == .nothingSelected)
        #expect(filed.isEmpty)

        model.setSelectedMarkupCount(3)
        #expect(model.assignSelection(to: zone.id))
        #expect(filed == [zone.id])
    }

    @Test("A regrouping request survives being asked for the same grouping twice")
    func repeatedRequestsAreBothDelivered() {
        let channel = LedgerGroupingRequest()
        channel.request([.projectZone])
        let firstToken = channel.token
        #expect(channel.take() == [.projectZone])
        #expect(channel.pending == nil)

        channel.request([.projectZone])
        #expect(channel.token > firstToken, "the token moves, so the second ask is delivered")
        #expect(channel.take() == [.projectZone])
    }
}

/// The Project Zones page is reachable, and it can be left.
@Suite("Project Zones: reachability and no dead ends", .shellTierSerialised)
@MainActor
struct ProjectZoneReachabilityTests {

    @Test("Show Project Zones is a real command with a chord and no conflict")
    func theCommandExists() {
        let table = ZPDFCommandTable.standard
        let command = table.command(.projectZones)
        #expect(command != nil)
        #expect(command?.group == .panels)
        #expect(command?.binding?.displayString == "\u{2325}\u{2318}4")
        #expect(table.conflicts().isEmpty)
        #expect(table.undeclaredShadows().isEmpty)
    }

    @Test("Performing it opens the Navigator on the zones page")
    func theCommandOpensThePage() {
        let environment = ProjectShellEnvironment.mock()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "test.zones")
        )
        _ = layout.view
        layout.panelState.navigatorSection = .pages

        environment.perform(.projectZones)
        #expect(layout.panelState.navigatorSection == .zones)
    }

    @Test("The environment's zone panel mirrors the document presenter")
    func thePanelReadsTheDocument() {
        let environment = ProjectShellEnvironment.mock()
        environment.refreshProjectZones()
        #expect(environment.projectZones.zones.count == environment.document.zones.count)
        let panelIDs: Set<UUID> = Set(environment.projectZones.zones.map(\.id))
        let documentIDs: Set<UUID> = Set(environment.document.zones.map(\.id))
        #expect(panelIDs == documentIDs)
    }

    @Test("Every refusal the zone panel can raise carries a sentence")
    func everyRefusalSpeaks() {
        let refusals: [ProjectZoneRefusal] = [
            .nameEmpty,
            .nameTaken("Ground Floor"),
            .unknownZone,
            .circularParent(name: "Building A"),
            .boundaryTooFewPoints(count: 2),
            .zoneNotEmpty(name: "Ground Floor", markupCount: 3),
            .nothingSelected,
            .notWired
        ]
        for refusal in refusals {
            #expect(!refusal.message.isEmpty, "\(refusal) must say something")
        }
    }

    @Test("Cancelling leaves nothing armed and no draft behind")
    func cancelIsAWayOut() {
        let model = ZoneFixture.wiredModel()
        model.onBeginBoundary = {}
        model.beginZone()
        model.beginBoundary()
        model.cancelZoneCreation()
        #expect(model.draft == nil)
        #expect(!model.isAwaitingBoundary)
        #expect(model.refusal == nil)
    }
}
