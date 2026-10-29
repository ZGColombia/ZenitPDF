import AppKit
import ZPDFUIWorkflows
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation

/// Round-2 markup state the canvas controller keeps (r2-markup).
struct MarkupRound2CanvasState {
    /// Test seam: whether the next click counts as a ⌘-click. `nil` reads the real modifier.
    var commandClickOverride: Bool?
}

/// Round 2, markup unit: in-place text editing (NL-MARKUP-08), the tool gestures that depend on a
/// variant (NL-MARKUP-10), ⌘-click on a hyperlink markup (NL-MARKUP-17) and the rotation knob
/// for text boxes and shapes (NL-MARKUP-18).
extension PDFCanvasViewController {

    // MARK: - Gestures

    /// The gesture of the armed markup tool, with its variant: a clouded callout is dragged like
    /// a rectangle and then typed into, whatever the plain Cloud tool does.
    func markupGesture(for kind: ZPDFUIPresentation.MarkupKind) -> ZenitToolGesture {
        if kind == .cloud, core.markup.variant == .cloudedCallout {
            return ZenitToolGesture(
                minimumPointCount: 2,
                completingPointCount: 2,
                usesDragGesture: true,
                dragAlsoPlacesClicks: true,
                closesOutline: true,
                needsTextEntry: true
            )
        }
        return ZenitToolMode.markup(kind).gesture
    }

    /// Whether the click being handled was made with ⌘ held.
    var isCommandClick: Bool {
        if let override = markupRound2.commandClickOverride { return override }
        return NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
    }

    // MARK: - Hyperlink markups

    /// Follows a hyperlink markup's destination through ``onFollowLink`` — the same door the
    /// drawing's own links use, so a web address asks before it opens. Returns whether `id` was a
    /// hyperlink with a destination.
    @discardableResult
    func followMarkupLink(_ id: UUID) -> Bool {
        guard let record = sceneRecords.first(where: { $0.id.rawValue == id }),
              record.kind == .hyperlink, let link = record.link, link.isValid else { return false }
        if let pageID = link.pageID {
            // By identity: in a project of several drawings a PDF index names a page only within
            // its own drawing, and `.page(index)` could land on another drawing's sheet.
            guard core.document.pages.contains(where: { $0.id == pageID.rawValue }) else { return true }
            onFollowLink?(.sheet(pageID.rawValue))
        } else if let url = link.url {
            onFollowLink?(.uri(url))
        }
        return true
    }

    // MARK: - Relative rotation (NL-MARKUP-18, R-004)

    /// Turns each markup by `delta` from its OWN angle, as one undo step (R-004). The three
    /// relative items used to send one absolute angle — the selection's common angle plus the
    /// delta, or 0 + delta when the angles differed — so text boxes at 0° and 30° both ended at
    /// 90° after Rotate 90° Left. A bulk edit carries one value for every markup, so the turn is
    /// built per markup and goes through the bus as one batch.
    func rotateMarkups(_ ids: [UUID], by delta: Double) async {
        let core = self.core
        var batch: [DocumentCommand] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = await core.session.markup(MarkupID(id)) else { continue }
            if record.locked {
                ZenitPDFProjectDocument.reportRefusedEdit(MarkupClipboardRefusal(message: NSLocalizedString(
                    "Nothing was rotated: a selected markup is locked. Unlock it and try again.",
                    comment: "Rotate refusal: part of the selection is locked"
                )), core: core)
                return
            }
            guard MarkupStyleFit.holdsRotation(record) else { continue }
            var style = record.style
            style.rotationDegrees = Self.foldedRotation((record.style.rotationDegrees ?? 0) + delta)
            if style != record.style { batch.append(.changeStyle(id: record.id, style: style)) }
        }
        guard !batch.isEmpty else { return }
        do {
            try await core.commands.performBatch(batch, actionName: NSLocalizedString("Rotate", comment: "Undo action name: markups rotated"))
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
        }
    }

    /// An angle folded into [0°, 360°); 0° is stored as no rotation, as the bulk edit stores it.
    nonisolated static func foldedRotation(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let folded = wrapped < 0 ? wrapped + 360 : wrapped
        return Swift.abs(folded) < 1e-9 || Swift.abs(folded - 360) < 1e-9 ? nil : folded
    }

    // MARK: - In-place text editing (NL-MARKUP-08)

    /// Opens the editor over the words of the markup under `point`, when it draws words or is a
    /// note. Returns whether an editor opened.
    func beginInPlaceTextEdit(at point: PDFPointValue) -> Bool {
        guard activeTextEntry == nil, let hit = hitTest(point) else { return false }
        return beginInPlaceTextEdit(markupID: hit)
    }

    /// Opens the editor over the words of one named markup: the context menu's Edit Text, which
    /// knows the markup it was opened on. It used to re-hit-test the centre of the markup's
    /// bounds, which on a callout (whose bounds take in the leader tip) was usually empty paper —
    /// a silent no-op — or another markup, whose words then opened instead (R-003).
    func beginInPlaceTextEdit(markupID: UUID) -> Bool {
        guard activeTextEntry == nil,
              let record = sceneRecords.first(where: { $0.id.rawValue == markupID }), !record.locked,
              let entry = Self.inPlaceEntry(for: record) else { return false }
        core.canvas.select(markupIDs: [markupID], additive: false)
        activeTextEntry = entry.entry
        installTextEditor()
        textEditor?.string = entry.text
        refresh()
        return true
    }

    /// What the editor edits for a record: its box, its words, and whether they are its drawn
    /// text or its note. `nil` for a markup with no words to edit.
    static func inPlaceEntry(for record: MarkupRecord) -> (entry: TextEntry, text: String)? {
        guard let points = record.geometry?.points else { return nil }
        let kind = Shown.Markup(domain: record.kind)
        switch record.kind {
        case .text where points.count >= 2:
            let box = ZenitMarkupGeometry.boundingRect(PDFPointValue(domain: points[0]), PDFPointValue(domain: points[1]))
            return (TextEntry(kind: kind, box: box, target: nil, editing: record.id.rawValue), MarkupVisibleText.text(of: record))
        case .callout where points.count >= 3, .cloud where points.count >= 3:
            let box = ZenitMarkupGeometry.boundingRect(PDFPointValue(domain: points[1]), PDFPointValue(domain: points[2]))
            return (
                TextEntry(kind: kind, box: box, target: PDFPointValue(domain: points[0]), editing: record.id.rawValue),
                MarkupVisibleText.text(of: record)
            )
        case .note where points.count >= 2:
            let icon = ZenitMarkupGeometry.boundingRect(PDFPointValue(domain: points[0]), PDFPointValue(domain: points[1]))
            let side = AppMarkupToolPresenter.noteSide
            let box = PDFRectValue(x: icon.minX, y: icon.minY - side * 3, width: side * 8, height: side * 3)
            return (TextEntry(kind: kind, box: box, target: nil, editing: record.id.rawValue), record.comment)
        default:
            return nil
        }
    }

    /// Closes the in-place editor, committing the words as one undo step when they changed: the
    /// drawn text through `.editText`, a note's words through `.editComment`. Emptying a text box
    /// leaves it as it was rather than deleting it — Delete is the verb for that.
    func finishInPlaceTextEdit(commit: Bool) {
        guard let entry = activeTextEntry, let id = entry.editing else { return }
        let typed = (textEditor?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        endTextEditor()
        activeTextEntry = nil
        guard commit, let record = sceneRecords.first(where: { $0.id.rawValue == id }) else {
            refresh()
            return
        }
        let command: DocumentCommand?
        if record.kind == .note {
            command = typed == record.comment ? nil : .editComment(id: record.id, comment: typed)
        } else {
            command = typed.isEmpty || typed == MarkupVisibleText.text(of: record) ? nil : .editText(id: record.id, text: typed)
        }
        guard let command else {
            refresh()
            return
        }
        Task { @MainActor [core] in
            do {
                _ = try await core.commands.perform(command)
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
            self.refresh()
        }
    }

    // MARK: - Rotation (NL-MARKUP-18)

    /// Where a turnable record's knob is: above its box's top edge on the centre line, turned
    /// with the record, `gap` page points out. The box is the scene's own
    /// (`CanvasSceneBuilder.rotationBox(of:)`), so the knob a press grabs is the knob the canvas
    /// drew (U-006, iteration 4).
    static func rotationKnob(of record: MarkupRecord, gap: Double) -> PDFPointValue? {
        guard let box = CanvasSceneBuilder.rotationBox(of: record) else { return nil }
        let centre = PDFPointValue(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2)
        let rest = PDFPointValue(x: centre.x, y: box.maxY + gap)
        return CanvasSceneBuilder.turn(rest, about: centre, degrees: record.style.effectiveRotationDegrees)
    }

    /// The rotation a record would take with its knob dragged to `point` (Shift: 15° steps).
    func markupRotation(of record: MarkupRecord, draggedTo point: PDFPointValue) -> Double? {
        guard let box = CanvasSceneBuilder.rotationBox(of: record) else { return nil }
        let centre = PDFPointValue(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2)
        let placement = CanvasStampPlacement(
            anchor: centre, widthPoints: max(box.size.width, 1), heightPoints: max(box.size.height, 1),
            rotationDegrees: record.style.effectiveRotationDegrees
        )
        let raw = placement.rotation(draggingHandleTo: point)
        return isShiftHeld ? CanvasStampPlacement.snapped(raw, increment: Self.stampRotationSnapDegrees) : raw
    }

    /// The selected text box, shape or image whose rotation knob is under `point`.
    ///
    /// A locked markup's knob is grabbed too, as a locked stamp's knob and a locked markup's
    /// vertices are: the release goes through the bulk edit, which refuses with its "locked"
    /// note. Skipping it here left a knob drawn that no press could take, and the press fell
    /// through to a marquee whose release cleared the selection (U-003, iteration 4).
    func markupRotationHandle(at point: PDFPointValue) -> UUID? {
        let tolerance = core.canvas.viewport.pageDistance(forViewPoints: Self.stampRotationHandleToleranceScreenPoints)
        let gap = core.canvas.viewport.pageDistance(forViewPoints: Double(CanvasPageView.stampRotationHandleGapViewPoints))
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1 else { return nil }
        for record in sceneRecords.reversed() where selected.contains(record.id.rawValue) {
            guard let knob = Self.rotationKnob(of: record, gap: gap) else { continue }
            if knob.distance(to: point) <= tolerance { return record.id.rawValue }
        }
        return nil
    }

    /// Writes the turned record's rotation as one `.changeStyle`, one undo step.
    func commitMarkupRotation(markupID: UUID, to point: PDFPointValue) {
        guard let record = sceneRecords.first(where: { $0.id.rawValue == markupID }),
              let rotation = markupRotation(of: record, draggedTo: point),
              abs(record.style.effectiveRotationDegrees - rotation) > 1e-9
        else {
            refresh()
            return
        }
        // Through the bulk edit, so the step is named "Rotate" like the Inspector's.
        var edit = MarkupStyleEdit()
        edit.rotationDegrees = rotation
        Task { @MainActor [core] in
            let receipt = await core.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [record.id.rawValue], style: edit))
            if let failure = receipt.failureDescription { core.status.setActiveToolNote(failure) }
            self.refresh()
        }
    }

    // MARK: - Drag and drop (NL-UX-15)

    /// Installs the Tool Library drop: a preset row dropped on the sheet places one of it at the
    /// drop point — a count mark, a stamp (asking its questions), a shape — through the same door
    /// a Place click uses.
    func enablePresetDrops() {
        scrollViewForTesting.onDropPreset = { [weak self] presetID, windowPoint in
            guard let self, let transform = self.pageViewForTesting.transform else { return false }
            let point = transform.pagePoint(from: self.pageViewForTesting.convert(windowPoint, from: nil))
            return self.dropPreset(presetID, at: point)
        }
    }

    /// Places the preset with `presetID` at `point`. Returns whether the library has it.
    @discardableResult
    func dropPreset(_ presetID: UUID, at point: PDFPointValue) -> Bool {
        guard let preset = core.toolLibrary.presets.first(where: { $0.id == presetID }) else { return false }
        handlePresetPlaceClick(preset, at: point)
        return true
    }
}
