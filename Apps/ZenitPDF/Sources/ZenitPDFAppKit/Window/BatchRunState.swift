import Foundation
import ZPDFUIPresentation

/// A box for the running batch's task, so the sheet's Cancel and the window's exit route can
/// both reach the same task without either capturing the other.
///
/// A class rather than a captured `var` because the closures that need it are created before
/// the task exists: `onRun` fills it in, `onCancel` and `onEnd` read it. Main-actor isolated,
/// like everything else on this path.
@MainActor
final class BatchRunState {

    /// The batch in flight, or `nil` when none is.
    var task: Task<BatchApplyReceipt, Never>?

    /// Creates an empty state.
    init() {}
}
