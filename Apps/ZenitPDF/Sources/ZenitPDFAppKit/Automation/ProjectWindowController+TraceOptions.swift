import AppKit
import Foundation
import ZPDFSnapEngine

/// NL-AUTO-11: the person decides what auto-trace leaves out. The tracer never judges what a wall
/// is; these choices are the person's, and every trace states them in the status bar.
extension ProjectWindowController {

    /// The thin-line threshold the options offer, in page points.
    static let traceThinLineThreshold = 0.25

    /// How the options are asked for. Injectable for tests; the default is a sheet with three
    /// checkboxes through ``ZenitModalPresenter``.
    static var autoTraceOptionsPrompt: (@MainActor (NSWindow?, TraceFilter) async -> TraceFilter?) = { window, current in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Auto-Trace Options", comment: "Auto-trace options sheet title"
            )
            alert.informativeText = NSLocalizedString(
                "Choose what ⌥-click tracing leaves out. Hidden layers are always left out. Whatever is chosen here is named in the status bar every time a room is traced.",
                comment: "Auto-trace options sheet body"
            )
            func box(_ title: String, _ on: Bool, _ y: CGFloat) -> NSButton {
                let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
                button.state = on ? .on : .off
                button.frame = NSRect(x: 0, y: y, width: 320, height: 20)
                return button
            }
            let dashed = box(NSLocalizedString("Ignore dashed lines", comment: "Auto-trace option"), current.excludesDashed, 48)
            let fills = box(NSLocalizedString("Ignore fills and hatch", comment: "Auto-trace option"), current.excludesFillOnly, 24)
            let thin = box(
                String(format: NSLocalizedString("Ignore lines thinner than %.2f pt", comment: "Auto-trace option; the width"),
                       ProjectWindowController.traceThinLineThreshold),
                current.minimumStrokeWidth > 0, 0
            )
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 70))
            [dashed, fills, thin].forEach(container.addSubview)
            alert.accessoryView = container
            alert.addButton(withTitle: NSLocalizedString("Apply", comment: "Auto-trace options confirm"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Designation prompt cancel"))
            ZenitModalPresenter.runAlert(alert, identifier: "automation.traceOptions", sheetedOn: window) { answer in
                guard answer.buttonIndex == 0 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: TraceFilter(
                    excludesDashed: dashed.state == .on,
                    excludesFillOnly: fills.state == .on,
                    minimumStrokeWidth: thin.state == .on ? ProjectWindowController.traceThinLineThreshold : 0
                ))
            }
        }
    }

    func showAutoTraceOptions(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let choice = await Self.autoTraceOptionsPrompt(self.window, document.automation.traceChoices) else { return }
            document.automation.traceChoices = choice
            document.core?.status.setActiveToolNote(
                AutoTraceWording.filterNote(choice)
                    ?? NSLocalizedString(
                        "Auto-trace follows every visible line.",
                        comment: "Status note after clearing every auto-trace option"
                    )
            )
        }
    }
}
