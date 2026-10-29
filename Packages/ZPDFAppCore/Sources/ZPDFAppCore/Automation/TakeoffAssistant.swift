import Foundation
import Observation
import ZPDFContracts
import ZPDFPersistence
import ZPDFSnapEngine
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// The Takeoff Assistant (NL-AUTO-16): "Prepare this set" walks the sheets and runs the detectors
/// that already exist — sheet names from the title block (NL-AUTO-04), the sheet's scale
/// (NL-AUTO-19), the rooms (NL-AUTO-08), the person's library symbols (NL-AUTO-13) — and files
/// what they find as **proposals** in an inbox
/// kept in the project (schema v17 `automation_proposal`). Nothing is committed: each proposal is
/// accepted or rejected by a person, and an accepted one goes through the ordinary command bus.
/// Nothing uses the network; every detector reads the drawing on this Mac.
public struct AssistantProposal: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case sheetName
        case scale
        case room
        /// Every hit of one library symbol on the sheet, accepted as one count.
        case symbols
    }

    public enum State: String, Codable, Hashable, Sendable {
        case open
        case accepted
        case rejected
    }

    public let id: UUID
    public let pageID: UUID
    public let pageIndex: Int
    public let kind: Kind
    public var state: State
    /// `0…1`, the detector's own confidence.
    public let confidence: Double

    // sheetName
    public var sheetNumber: String?
    public var sheetTitle: String?
    // scale
    public var scaleDisplay: String?
    /// The proposal's exact metres per PDF point, as a decimal string.
    public var metresPerPoint: String?
    public var scaleEvidence: String?
    /// The ratio's two sides, as decimal strings, for the preset scale an acceptance sets.
    public var ratioNumerator: String?
    public var ratioDenominator: String?
    // room
    public var roomRing: [PDFPoint]?
    public var roomName: String?
    // symbols
    public var symbolDesignation: String?
    public var symbolPositions: [PDFPoint]?

    public init(id: UUID = UUID(), pageID: UUID, pageIndex: Int, kind: Kind, state: State = .open, confidence: Double,
                sheetNumber: String? = nil, sheetTitle: String? = nil, scaleDisplay: String? = nil, metresPerPoint: String? = nil,
                scaleEvidence: String? = nil, ratioNumerator: String? = nil, ratioDenominator: String? = nil,
                roomRing: [PDFPoint]? = nil, roomName: String? = nil,
                symbolDesignation: String? = nil, symbolPositions: [PDFPoint]? = nil) {
        self.id = id
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.kind = kind
        self.state = state
        self.confidence = confidence
        self.sheetNumber = sheetNumber
        self.sheetTitle = sheetTitle
        self.scaleDisplay = scaleDisplay
        self.metresPerPoint = metresPerPoint
        self.scaleEvidence = scaleEvidence
        self.ratioNumerator = ratioNumerator
        self.ratioDenominator = ratioDenominator
        self.roomRing = roomRing
        self.roomName = roomName
        self.symbolDesignation = symbolDesignation
        self.symbolPositions = symbolPositions
    }

    /// What makes two proposals the same suggestion, so a rerun does not offer again what a
    /// person already accepted or rejected: the kind and its content, not its identity.
    public var sameness: String {
        switch kind {
        case .sheetName: return "name|\(sheetNumber ?? "")|\(sheetTitle ?? "")"
        case .scale: return "scale|\(metresPerPoint ?? "")"
        case .room:
            // A ring by its bounds rounded to a point, so two detections of one room agree.
            let ring = roomRing ?? []
            let xs = ring.map(\.x), ys = ring.map(\.y)
            return "room|\(Int((xs.min() ?? 0).rounded()))|\(Int((ys.min() ?? 0).rounded()))|\(Int((xs.max() ?? 0).rounded()))|\(Int((ys.max() ?? 0).rounded()))"
        case .symbols:
            let positions = (symbolPositions ?? []).map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.sorted()
            return "symbols|\(symbolDesignation ?? "")|\(positions.joined(separator: ";"))"
        }
    }

    /// One line for the inbox.
    public var summary: String {
        switch kind {
        case .sheetName:
            let number = sheetNumber ?? ""
            return sheetTitle.map { String(format: NSLocalizedString("Name the sheet %1$@ “%2$@”", comment: "Assistant proposal: sheet name; number, title"), number, $0) }
                ?? String(format: NSLocalizedString("Name the sheet %@", comment: "Assistant proposal: sheet number only"), number)
        case .scale:
            return String(format: NSLocalizedString("Scale %1$@, read from “%2$@”", comment: "Assistant proposal: scale; ratio, evidence text"), scaleDisplay ?? "", scaleEvidence ?? "")
        case .room:
            return roomName.map { String(format: NSLocalizedString("Room “%@”", comment: "Assistant proposal: named room"), $0) }
                ?? NSLocalizedString("Room (no name printed inside)", comment: "Assistant proposal: unnamed room")
        case .symbols:
            return String(format: NSLocalizedString("Count %1$lld × “%2$@” (library symbol)", comment: "Assistant proposal: library symbol hits; count, designation"),
                          Int64(symbolPositions?.count ?? 0), symbolDesignation ?? "")
        }
    }
}

/// What the assistant reads of one sheet.
public struct AssistantPageInput: Sendable {
    public let pageID: UUID
    public let pageIndex: Int
    public let pageBox: PDFRectValue
    public let userUnit: Double
    public let lines: [RecognisedTextLine]
    /// The sheet's vector primitives, or `nil` when they could not be read (then no rooms).
    public let primitives: [VectorPrimitive]?
    public let metresPerPoint: Double?
    /// Whether the sheet already has a name / a scale: then that detector is not run.
    public let isNamed: Bool
    public let hasScale: Bool

    public init(pageID: UUID, pageIndex: Int, pageBox: PDFRectValue, userUnit: Double = 1, lines: [RecognisedTextLine],
                primitives: [VectorPrimitive]?, metresPerPoint: Double?, isNamed: Bool, hasScale: Bool) {
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.pageBox = pageBox
        self.userUnit = userUnit
        self.lines = lines
        self.primitives = primitives
        self.metresPerPoint = metresPerPoint
        self.isNamed = isNamed
        self.hasScale = hasScale
    }
}

public enum TakeoffAssistant {

    /// The most rooms filed for one sheet; a denser sheet says so instead of flooding the inbox.
    public static let maximumRoomsPerSheet = 200

    /// Every proposal the detectors make for one sheet. Pure over its input.
    public static func proposals(for page: AssistantPageInput, roomOptions: RoomDetector.Options, filter: TraceFilter = .none,
                                 library: [SymbolLibraryEntry] = []) -> [AssistantProposal] {
        var found: [AssistantProposal] = []
        if !page.isNamed {
            let name = TitleBlockReader().readAutomatically(pageIndex: page.pageIndex, pageBox: page.pageBox, lines: page.lines)
            if let number = name.number, !number.isEmpty {
                found.append(AssistantProposal(pageID: page.pageID, pageIndex: page.pageIndex, kind: .sheetName,
                                               confidence: name.confidence, sheetNumber: number, sheetTitle: name.title))
            }
        }
        if !page.hasScale, let scale = SheetScaleProposer().proposal(lines: page.lines, pageBox: page.pageBox, userUnit: page.userUnit) {
            found.append(AssistantProposal(pageID: page.pageID, pageIndex: page.pageIndex, kind: .scale,
                                           confidence: scale.notationConfidence, scaleDisplay: scale.displayString,
                                           metresPerPoint: NSDecimalNumber(decimal: scale.metresPerPointExact).stringValue,
                                           scaleEvidence: scale.evidence.sourceText,
                                           ratioNumerator: "\(scale.ratio.numerator)", ratioDenominator: "\(scale.ratio.denominator)"))
        }
        if let primitives = page.primitives,
           case let .rooms(rooms, _) = RoomDetector.detect(RegionTracer.prepare(primitives: primitives, filter: filter), options: roomOptions) {
            for room in rooms.prefix(maximumRoomsPerSheet) {
                let name = RoomLabelPairing.label(for: room.region.ring, lines: page.lines).name
                found.append(AssistantProposal(pageID: page.pageID, pageIndex: page.pageIndex, kind: .room,
                                               confidence: room.closures.isEmpty ? 0.8 : 0.6,
                                               roomRing: room.region.ring, roomName: name))
            }
        }
        if let primitives = page.primitives {
            found += symbolProposals(pageID: page.pageID, pageIndex: page.pageIndex, primitives: primitives, library: library)
        }
        return found
    }

    /// The most library symbols searched per sheet, as Find Library Symbols searches.
    public static let maximumLibrarySymbols = 50

    /// One proposal per library symbol that is on the sheet: every confirmed hit, held to the
    /// symbol's own style as well as its shape (NL-AUTO-13). Confidence is how far under the
    /// matcher's residual threshold the hits sit on average — the matcher's own measure, not an
    /// invented one.
    public static func symbolProposals(pageID: UUID, pageIndex: Int, primitives: [VectorPrimitive],
                                       library: [SymbolLibraryEntry]) -> [AssistantProposal] {
        var options = SymbolMatchOptions.standard
        options.styleGate = [.strokeColor, .strokeWidth]
        return library.prefix(maximumLibrarySymbols).compactMap { entry -> AssistantProposal? in
            guard let report = try? SymbolMatcher().matches(exemplar: entry.exemplar, in: primitives, options: options),
                  !report.confirmed.isEmpty else { return nil }
            let meanResidual = report.confirmed.map(\.residual).reduce(0, +) / Double(report.confirmed.count)
            let confidence = report.residualThreshold > 0 ? max(0, min(1, 1 - meanResidual / report.residualThreshold)) : 0.5
            return AssistantProposal(pageID: pageID, pageIndex: pageIndex, kind: .symbols, confidence: confidence,
                                     symbolDesignation: entry.designation,
                                     symbolPositions: report.confirmed.map { PDFPoint(x: Double($0.position.x), y: Double($0.position.y)) })
        }
    }
}

/// The inbox, per project: every proposal with its state, kept in the project database and read
/// back on open.
@MainActor
@Observable
public final class AutomationInbox {

    public private(set) var proposals: [AssistantProposal] = []

    @ObservationIgnored private var package: ProjectPackage?
    @ObservationIgnored private var projectID = ""

    public init() {}

    public var openProposals: [AssistantProposal] { proposals.filter { $0.state == .open } }

    /// Reads the inbox from a project; an unsaved Quick PDF keeps it in memory until it is saved.
    public func attach(package: ProjectPackage?) async {
        self.package = package
        guard let package else { return }
        projectID = await package.manifest.projectId
        let project = projectID
        let rows = (try? await package.read { db in try AutomationProposalStore.proposals(project: project, in: db) }) ?? []
        proposals = rows.compactMap { row in try? JSONDecoder().decode(AssistantProposal.self, from: Data(row.payloadJson.utf8)) }
            .map { var proposal = $0; proposal.state = AssistantProposal.State(rawValue: rows.first { $0.id == proposal.id.uuidString }?.state ?? "open") ?? .open; return proposal }
        if !pendingUnsaved.isEmpty {
            let pending = pendingUnsaved
            pendingUnsaved = [:]
            for (pageID, list) in pending { await file(list, forPage: pageID) }
        }
    }

    @ObservationIgnored private var pendingUnsaved: [UUID: [AssistantProposal]] = [:]

    /// Files a fresh run's proposals for one sheet: the sheet's open proposals are replaced, and a
    /// proposal the person already decided is not offered again.
    @discardableResult
    public func file(_ fresh: [AssistantProposal], forPage pageID: UUID) async -> [AssistantProposal] {
        let decided = Set(proposals.filter { $0.pageID == pageID && $0.state != .open }.map(\.sameness))
        let kept = fresh.filter { !decided.contains($0.sameness) }
        proposals.removeAll { $0.pageID == pageID && $0.state == .open }
        proposals.append(contentsOf: kept)
        guard let package else {
            pendingUnsaved[pageID] = kept
            return kept
        }
        let project = projectID
        let stamp = PersistenceTimestamp.string(from: Date())
        let rows = kept.compactMap { proposal -> AutomationProposalRecord? in
            guard let json = try? JSONEncoder().encode(proposal) else { return nil }
            return AutomationProposalRecord(id: proposal.id.uuidString, projectId: project, pageId: pageID.uuidString,
                                            kind: proposal.kind.rawValue, payloadJson: String(decoding: json, as: UTF8.self),
                                            createdAt: stamp)
        }
        _ = try? await package.write { db in
            try AutomationProposalStore.removeOpen(project: project, page: pageID.uuidString, in: db)
            try AutomationProposalStore.insert(rows, in: db)
        }
        return kept
    }

    /// Records a decision. The action it stands for is the caller's, through the command bus.
    public func decide(_ id: UUID, _ state: AssistantProposal.State) async {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].state = state
        guard let package else { return }
        let stamp = PersistenceTimestamp.string(from: Date())
        let recordState: AutomationProposalRecord.State = state == .accepted ? .accepted : (state == .rejected ? .rejected : .open)
        _ = try? await package.write { db in
            try AutomationProposalStore.setState(id: id.uuidString, state: recordState, decidedAt: stamp, in: db)
        }
    }
}
