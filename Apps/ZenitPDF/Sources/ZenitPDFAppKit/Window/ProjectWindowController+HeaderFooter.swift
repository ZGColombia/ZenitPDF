import AppKit
import Foundation
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Tools ▸ Batch Header, Footer or Sheet Number… (NL-PDF-20): the scoped batch sheet, with a
/// text template in place of a stamp preset.
extension ProjectWindowController {

    /// The template with an optional start value: `{n=101}` numbers from 101. Pure.
    static func headerFooterTemplate(_ typed: String) -> (template: String, numberStart: Int) {
        guard let range = typed.range(of: #"\{n=(-?\d{1,9})\}"#, options: .regularExpression) else {
            return (typed, 1)
        }
        let token = typed[range]
        let digits = token.dropFirst(3).dropLast()
        return (typed.replacingCharacters(in: range, with: "{n}"), Int(digits) ?? 1)
    }

    /// The batch model for a header or footer, wired to the engine without opening anything.
    func makeHeaderFooterModel(for document: ZenitPDFProjectDocument) -> (model: BatchApplyModel, runState: BatchRunState)? {
        guard let core = document.core, !core.snapshot.pages.isEmpty else { return nil }
        let model = BatchApplyModel()
        model.placementPrompt = NSLocalizedString(
            "Text for each sheet. {page}, {n}, {date}, {project} and {document} are filled in; {n=101} numbers from 101.",
            comment: "Batch header/footer prompt explaining the template fields"
        )
        // Nothing is placed without the text, and the preview says so (L-60).
        model.requiresPromptedText = true
        model.rangeThrough = core.snapshot.pages.count
        // The Navigator's selection, live pages only — the same rule the stamp batch uses.
        model.navigatorSelection = selectedNavigatorPageIDs(in: document)
        model.onPlan = { [weak core] values in
            let parsed = Self.headerFooterTemplate(values.promptedText)
            guard let core, let producer = core.headerFooterBatchProducer(
                template: parsed.template, numberStart: parsed.numberStart
            ) else { return nil }
            return core.planBatchApply(producer, request: BatchApplyRequest(
                scope: values.scope,
                anchor: values.anchor,
                skipPagesAlreadyCarrying: values.skipPagesAlreadyCarrying,
                searchMatchedPageIDs: values.searchMatchedPageIDs
            ))
        }
        wireSearchScope(on: model, document: document)
        let runState = BatchRunState()
        model.onRun = { [weak core, weak model] plan, promptedText in
            let parsed = Self.headerFooterTemplate(promptedText)
            guard let core, let producer = core.headerFooterBatchProducer(
                template: parsed.template, numberStart: parsed.numberStart
            ) else { return BatchApplyReceipt() }
            let task = Task { @MainActor in
                await core.runBatchApply(
                    producer,
                    plan: plan,
                    progress: ProgressSink { progress in
                        Task { @MainActor in model?.report(fraction: progress.fraction, detail: progress.detail) }
                    }
                )
            }
            runState.task = task
            return await task.value
        }
        model.onCancel = { runState.task?.cancel() }
        return (model, runState)
    }

    /// Tools ▸ Batch Header, Footer or Sheet Number….
    @discardableResult
    func presentHeaderFooterBatch(for document: ZenitPDFProjectDocument) -> BatchApplyModel? {
        guard let window else { return nil }
        let kind = WorkflowPanelKind.batchApply
        guard modeRegistry.exitRoute(for: kind.id) == nil else { return nil }
        guard let wired = makeHeaderFooterModel(for: document) else { return nil }
        let sheetWindow = WorkflowSheet.presentBatchApply(
            in: window,
            model: wired.model,
            title: NSLocalizedString("Header, Footer or Sheet Number", comment: "Batch header/footer sheet title"),
            onEnd: { [weak self] in
                wired.runState.task?.cancel()
                self?.modeRegistry.unregister(id: kind.id)
            }
        )
        modeRegistry.register(kind.makeRegistration(onClose: { [weak window, weak sheetWindow] in
            guard let window, let sheetWindow else { return }
            window.endSheet(sheetWindow)
        }))
        return wired.model
    }
}
