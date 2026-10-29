import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFGeometry
import ZPDFUIPresentation

/// Typed length and angle while drawing (NL-MEASURE-18).
///
/// With a segment tool drawing — at least one point placed — typing `4,2` and Return places the
/// next vertex 4.2 (display unit) along the pointer's direction; `4,2<90` places it at 90° in the
/// drawing's own axes; `12'6"` works in feet and inches. The live pill echoes what is typed.
/// Delete removes the last character, Escape drops the entry, and Return with nothing typed still
/// finishes the shape. A digit or a decimal separator starts an entry (".5" is half a unit, as the
/// shared number grammar reads it); the other characters only continue one, so a single-key
/// shortcut is never taken away when nothing is being typed.
extension PDFCanvasViewController {

    /// The pill text while an entry is typed: "4,2 m ⏎", or "4,2 m < 90° ⏎".
    var typedEntryEcho: String? {
        guard !typedEntry.isEmpty else { return nil }
        let unit = core.snapshot.units.length.symbol
        let parts = typedEntry.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let length = parts[0].trimmingCharacters(in: .whitespaces)
        let shownLength = length.isEmpty || length.contains("'") || length.contains("\"") ? length : "\(length) \(unit)"
        let angle = parts.count == 2 ? " < \(parts[1].trimmingCharacters(in: .whitespaces))°" : ""
        return shownLength + angle + " \u{23CE}"
    }

    /// Whether a segment tool is mid-drawing, so typed characters belong to it.
    var acceptsTypedEntry: Bool {
        guard let kind = core.measurement.activeKind, !kind.isPointPlacement, !isCalibrating,
              core.markup.activeKind == nil else { return false }
        return !core.measurement.placedPoints.isEmpty
    }

    /// Claims the key when it belongs to a typed entry. Returns whether it did.
    func handleTypedEntry(_ key: CanvasKey) -> Bool {
        switch key {
        case .typed(let character):
            guard acceptsTypedEntry else { return false }
            // W-005: a leading separator starts the entry too. It used to fall through (a beep),
            // so ".5" became "5" and placed a segment ten times too long.
            guard !typedEntry.isEmpty || Self.startsTypedEntry(character) else { return false }
            typedEntry.append(character)
            refresh()
            return true
        case .removeLastVertex:
            guard !typedEntry.isEmpty else { return false }
            typedEntry.removeLast()
            refresh()
            return true
        case .escape:
            guard !typedEntry.isEmpty else { return false }
            typedEntry = ""
            refresh()
            return true
        case .finish, .commandFinish:
            // A Return that arrives while a typed vertex is still being placed finishes the
            // shape after that vertex, not before it (R-013).
            if typedEntryCommitInFlight {
                finishAfterTypedEntry = true
                return true
            }
            guard !typedEntry.isEmpty else { return false }
            commitTypedEntry()
            return true
        default:
            // Any other key leaves the entry as it is.
            return false
        }
    }

    /// Drops an entry once its shape stops taking one (X-004): the shape was finished by a
    /// double-click or a secondary click, cancelled, or lost to a tool switch or a page turn.
    /// Nothing else cleared it, so a stale "4" went on claiming every tool key, ate Delete and
    /// Escape, echoed in the next shape's pill and was placed by that shape's Return. A Return
    /// waiting on a typed vertex in flight has no shape left to finish either. Run from
    /// ``refreshLiveFeedback()``, which every change of the placed points, the tool or the page
    /// reaches.
    func dropStaleTypedEntry() {
        guard !typedEntry.isEmpty || finishAfterTypedEntry, !acceptsTypedEntry else { return }
        typedEntry = ""
        finishAfterTypedEntry = false
    }

    /// A point the pointer places supersedes a half-typed length (X-004): the entry was typed
    /// from the vertex before it, and a Return after the click placed a segment of the stale
    /// length from the new one.
    func dropTypedEntryForPointerPoint() {
        typedEntry = ""
    }

    /// The characters that may open an entry: a digit, or a decimal separator.
    static func startsTypedEntry(_ character: Character) -> Bool {
        character.isNumber || character == "." || character == ","
    }

    /// Parses the entry and places the vertex, or says why not and keeps the text to correct.
    func commitTypedEntry() {
        let text = typedEntry
        guard acceptsTypedEntry, let anchor = typedSegmentAnchor, let pageID = core.document.currentPageID else {
            typedEntry = ""
            refresh()
            return
        }
        let unit = ZPDFContracts.LengthUnit(shown: core.snapshot.units.length)
        guard let entry = Self.parseTypedSegment(text, unit: unit) else {
            core.status.setActiveToolNote(Self.typedEntryRefusal)
            return
        }
        // R-013: the entry is consumed now, before the session answers. It was cleared only
        // after the scale lookup, so a second Return in that window placed the same vertex twice
        // (a zero-length segment, or the first vertex of a new two-point Length).
        typedEntry = ""
        typedEntryCommitInFlight = true
        refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endTypedEntryCommit() }
            let scale: ScaleTransform
            switch await self.typedEntryScale(page: PageID(pageID), at: PDFPoint(shown: anchor.anchor)) {
            case .scale(let resolved):
                scale = resolved
            case .noScale:
                self.restoreTypedEntry(text, note: Self.typedEntryRefusal)
                return
            case .ambiguous:
                self.restoreTypedEntry(text, note: NSLocalizedString(
                    "The last point is on the boundary of two Scale Regions, so a typed length has no single scale. Click the next point instead.",
                    comment: "Status note: a typed length starts where two Scale Regions meet"
                ))
                return
            }
            guard let point = TypedSegment.point(
                from: PDFPoint(shown: anchor.anchor),
                toward: anchor.pointer.map { PDFPoint(shown: $0) },
                entry: entry,
                scale: scale
            ) else {
                self.restoreTypedEntry(text, note: NSLocalizedString(
                    "Move the pointer the way the segment should go, or type an angle after <.",
                    comment: "Status note: a typed length has no direction yet"
                ))
                return
            }
            // The shape the entry was typed for is still being drawn from the same vertex: an
            // Escape or a tool change during the hop drops the vertex rather than starting a
            // new shape with it.
            guard self.acceptsTypedEntry, self.typedSegmentAnchor?.anchor == anchor.anchor else { return }
            self.placeTypedMeasurementPoint(PDFPointValue(x: point.x, y: point.y))
        }
    }

    /// Which scale a typed length is converted with.
    enum TypedEntryScale: Equatable {
        case scale(ScaleTransform)
        /// Neither the page nor a Scale Region under the anchor has a scale.
        case noScale
        /// The anchor lies where two Scale Regions meet or overlap.
        case ambiguous
    }

    /// The scale the commit will measure the segment with (R-002). The commit funnel gives a
    /// record that lies inside a Scale Region that region's scale (`scaleRegionDecision`), so a
    /// typed length converted at the page scale placed a vertex 4.2 m away at 1:100 inside a
    /// 1:50 region and the ledger said 2.1 m; on a sheet calibrated only by a region the entry
    /// was refused. The segment starts at the anchor, so the anchor decides.
    func typedEntryScale(page: PageID, at anchor: PDFPoint) async -> TypedEntryScale {
        let session = core.session
        // An unreadable region set leaves the page default in force, as the commit does.
        if let resolver = try? await session.scaleRegionResolver(page: page) {
            switch resolver.resolve(point: anchor) {
            case .region(let id):
                guard let region = await session.scaleRegion(id),
                      let scale = await session.scaleTransform(region.scaleID) else { return .noScale }
                return .scale(scale)
            case .ambiguous:
                return .ambiguous
            case .pageDefault:
                break
            }
        }
        guard let scale = await session.scale(onPage: page) else { return .noScale }
        return .scale(scale)
    }

    /// Gives a refused entry back to correct — unless the person has started another one — and
    /// says why.
    private func restoreTypedEntry(_ text: String, note: String) {
        if typedEntry.isEmpty, acceptsTypedEntry { typedEntry = text }
        finishAfterTypedEntry = false
        core.status.setActiveToolNote(note)
        refresh()
    }

    /// The placement is done (or refused); a Return that waited for it now finishes the shape.
    private func endTypedEntryCommit() {
        typedEntryCommitInFlight = false
        guard finishAfterTypedEntry else { return }
        finishAfterTypedEntry = false
        _ = handle(key: .finish)
    }

    /// The entry grammar with the app's shared number and feet-and-inches readers.
    static func parseTypedSegment(_ text: String, unit: ZPDFContracts.LengthUnit) -> TypedSegment.Entry? {
        TypedSegment.parse(
            text,
            unit: unit,
            number: { ZPDFDecimalParser.decimal($0) ?? CalibrationPrompt.mixedNumber($0) },
            feetAndInches: { CalibrationPrompt.feetAndInches($0) }
        )
    }

    static var typedEntryRefusal: String {
        NSLocalizedString(
            "Type a length such as 4.2, or a length and an angle such as 4.2<90, then press Return.",
            comment: "Status note: a typed segment could not be read"
        )
    }
}
