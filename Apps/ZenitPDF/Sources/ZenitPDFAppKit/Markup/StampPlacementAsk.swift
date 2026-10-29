import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// The single-click stamp's questions (nl-markup).
///
/// `AppCoreEnvironment.placeStamp(_:at:pageID:promptedText:promptedTexts:)` — the stamp door
/// that answers a template's "Checked by", "Note" and other prompted fields — had no caller. A
/// click with a stamp preset armed went through the generic Place path with an empty answer,
/// so every prompted field of a single-click stamp was frozen blank, forever. The batch sheet
/// asked; the click did not.
///
/// A stamp whose template asks nothing is placed at once. One that asks shows one text field
/// per question, through ``ZenitModalPresenter`` so no test can put it on screen, and places the
/// stamp with the answers on OK. Cancel places nothing.
@MainActor
enum StampPlacementAsk {

    /// The stable name of this dialogue, for `ZenitModalPresenter.didRequest(_:)`.
    static let modalIdentifier = "markup.stampPlacementPrompt"

    /// Places `preset` at `point`, asking its template's questions first when it has any.
    ///
    /// - Parameter completion: receives the receipt, or `nil` when the person cancelled.
    static func place(
        _ preset: ToolPresetSummary,
        at point: PDFPointValue,
        pageID: UUID,
        core: AppCoreEnvironment,
        window: NSWindow?,
        completion: @escaping @MainActor (ToolPresetPlaceReceipt?) -> Void
    ) {
        let prompts = preset.stamp?.placementPrompts ?? []
        guard !prompts.isEmpty else {
            Task { @MainActor in
                completion(await core.placeStamp(preset, at: point, pageID: pageID))
            }
            return
        }
        let (alert, fields) = makeAlert(presetName: preset.name, prompts: prompts)
        typeForTesting?(fields)
        // Nobody to answer: nothing is placed. A stamp frozen with blank answers is the
        // defect this file closes, so it is not the silent default.
        ZenitModalPresenter.runAlert(
            alert,
            identifier: modalIdentifier,
            sheetedOn: window,
            answerWithoutAUser: .dismissed
        ) { answer in
            guard answer == .button(0) else {
                completion(nil)
                return
            }
            let texts = answers(from: fields.map(\.stringValue), prompts: prompts)
            Task { @MainActor in
                completion(await core.placeStamp(
                    preset, at: point, pageID: pageID,
                    promptedText: texts.first?.value ?? "",
                    promptedTexts: Dictionary(uniqueKeysWithValues: texts.map { ($0.slot, $0.value) })
                ))
            }
        }
    }

    /// Types into the fields before the alert is answered. Tests only: a test decides the
    /// button through `ZenitModalPresenter.answering` and the words through this.
    static var typeForTesting: (@MainActor ([NSTextField]) -> Void)?

    /// The answers keyed by the prompts' slots, in prompt order, trimmed.
    static func answers(from values: [String], prompts: [StampPlacementPrompt]) -> [(slot: Int, value: String)] {
        zip(prompts, values).map { prompt, value in
            (prompt.slot, value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The alert and its text fields, one per prompt, in the template's draw order.
    static func makeAlert(presetName: String, prompts: [StampPlacementPrompt]) -> (NSAlert, [NSTextField]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString(
                "Place “%@”", comment: "Stamp placement prompt title; the stamp preset's name"
            ),
            presetName
        )
        alert.informativeText = NSLocalizedString(
            "The stamp asks for this text. It is written into the stamp once and never changes afterwards.",
            comment: "Stamp placement prompt detail"
        )
        let width: CGFloat = 280
        let rowHeight: CGFloat = 44
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(prompts.count)))
        var fields: [NSTextField] = []
        for (index, prompt) in prompts.enumerated() {
            let top = stack.frame.height - rowHeight * CGFloat(index + 1)
            let label = NSTextField(labelWithString: prompt.prompt)
            label.frame = NSRect(x: 0, y: top + 24, width: width, height: 16)
            let field = NSTextField(string: "")
            field.frame = NSRect(x: 0, y: top, width: width, height: 22)
            field.placeholderString = prompt.prompt
            field.setAccessibilityLabel(prompt.prompt)
            stack.addSubview(label)
            stack.addSubview(field)
            fields.append(field)
        }
        for (field, next) in zip(fields, fields.dropFirst()) { field.nextKeyView = next }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = fields.first
        alert.addButton(withTitle: NSLocalizedString("Place Stamp", comment: "Stamp placement prompt: place with the typed text"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Stamp placement prompt: place nothing"))
        return (alert, fields)
    }
}
