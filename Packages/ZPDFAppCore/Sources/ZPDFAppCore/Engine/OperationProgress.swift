import Foundation

/// What a long operation reports while it runs.
///
/// OCR over a 300-page set, a vector extraction, a revision compare and an export all
/// take longer than a frame, and the rule in `QUALITY_BAR` is that none of them may look
/// like a hang. So each one reports through this value and each one is cancellable —
/// there is no long operation in this package that a user cannot stop.
public struct OperationProgress: Hashable, Sendable {

    /// What the operation is.
    public enum Stage: String, Hashable, Sendable, Codable {
        /// Queued, nothing started.
        case pending
        /// Reading the source: opening a PDF, scanning a content stream.
        case reading
        /// The main work: recognising text, comparing rasters, extracting geometry.
        case working
        /// Building the result the caller asked for.
        case finishing
        /// Finished normally.
        case completed
        /// Stopped because the caller cancelled it.
        case cancelled
        /// Stopped because it failed. The reason is in ``OperationProgress/detail``.
        case failed
    }

    /// The stage the operation is in.
    public var stage: Stage
    /// Fraction complete, `0...1`, or `nil` when the total is not knowable yet.
    public var fraction: Double?
    /// Units done, for an operation that counts something — pages, primitives, rows.
    public var completedUnits: Int
    /// Total units, or `nil` while unknown.
    public var totalUnits: Int?
    /// A localized one-line description, for the progress row's accessibility value.
    public var detail: String

    /// Creates a progress report.
    public init(
        stage: Stage = .pending,
        fraction: Double? = nil,
        completedUnits: Int = 0,
        totalUnits: Int? = nil,
        detail: String = ""
    ) {
        self.stage = stage
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.detail = detail
    }

    /// A report for a counted operation, with the fraction derived rather than passed in
    /// separately — a fraction that disagrees with its counts is a bug waiting to be seen.
    public static func counting(
        _ completed: Int,
        of total: Int,
        stage: Stage = .working,
        detail: String = ""
    ) -> OperationProgress {
        OperationProgress(
            stage: stage,
            fraction: total > 0 ? Double(completed) / Double(total) : nil,
            completedUnits: completed,
            totalUnits: total,
            detail: detail
        )
    }

    /// Whether the operation has stopped, for whatever reason.
    public var isTerminal: Bool {
        stage == .completed || stage == .cancelled || stage == .failed
    }

    /// A finished report.
    public static let completed = OperationProgress(stage: .completed, fraction: 1)
    /// A cancelled report.
    public static let cancelled = OperationProgress(stage: .cancelled)
}

/// A handle on a running long operation.
///
/// Holds the `Task` so the UI can cancel it, and the last report so a view appearing
/// mid-operation shows the real state rather than starting at zero.
@MainActor
@Observable
public final class OperationHandle {

    /// A stable identity, so a list of running operations is diffable.
    public let id: UUID
    /// A localized title, for example `"Recognising text"`.
    public let title: String
    /// The most recent report.
    public private(set) var progress: OperationProgress

    private var cancelWork: (@Sendable () -> Void)?

    /// Creates a handle.
    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
        self.progress = OperationProgress(stage: .pending, detail: title)
    }

    /// Records a new report. Ignored once the operation is terminal, so a late report from
    /// a cancelled task cannot resurrect a finished progress row.
    public func report(_ progress: OperationProgress) {
        guard !self.progress.isTerminal else { return }
        self.progress = progress
    }

    /// Attaches the task that does the work, whatever it returns.
    ///
    /// Both callers used to attach a wrapper, `Task { _ = await task.value }`. Awaiting an
    /// unstructured task neither makes it a child nor forwards cancellation, so ``cancel()``
    /// flipped the row to Cancelled while the compare or the search ran to completion and
    /// installed its result under it — QUALITY_BAR's "no long operation a user cannot stop" was
    /// not delivered by this type (BH-100, BH-106, BH-450). The work itself is cancelled now.
    public func attach<Success: Sendable, Failure: Error>(cancelling task: Task<Success, Failure>) {
        cancelWork = { task.cancel() }
    }

    /// Cancels the operation. The task observes `Task.isCancelled` at its own checkpoints;
    /// the handle goes to ``OperationProgress/cancelled`` immediately so the UI is honest
    /// about what the user just asked for.
    public func cancel() {
        cancelWork?()
        guard !progress.isTerminal else { return }
        progress = .cancelled
    }

    /// Whether the operation is still running.
    public var isRunning: Bool { !progress.isTerminal }
}

/// A `Sendable` way for work running off the main actor to report back to a handle.
///
/// A closure rather than a reference to the handle, because the handle is `@MainActor` and
/// the work is not. Hopping per report is deliberate: reports are rare, and the
/// alternative — a lock around mutable UI state — is the thing Swift 6 exists to prevent.
public struct ProgressSink: Sendable {

    private let hop: @Sendable (OperationProgress) -> Void

    /// Creates a sink that forwards to a main-actor handle.
    @MainActor
    public init(handle: OperationHandle) {
        hop = { progress in
            Task { @MainActor in handle.report(progress) }
        }
    }

    /// Creates a sink that discards its reports, for a caller that does not show progress.
    public init() {
        hop = { _ in }
    }

    /// Creates a sink over an arbitrary `Sendable` closure, for tests.
    public init(_ body: @escaping @Sendable (OperationProgress) -> Void) {
        hop = body
    }

    /// Reports progress.
    public func callAsFunction(_ progress: OperationProgress) { hop(progress) }
}
