import CoreGraphics
import Foundation

/// A cancellable, prioritised queue of single-tile renders (NL-PERF-06, NL-PERF-07).
///
/// The canvas's exact-scale raster is one render per viewport: the right shape for the settled
/// frame, and the wrong one mid-gesture, where every zoom step supersedes the last and a
/// viewport render cannot be interrupted. Level tiles go through this queue instead:
///
/// - **one tile per job**, so what a supersede wastes is one 512-pixel tile, not a viewport;
/// - **nearest first**: jobs carry a priority (distance from the gesture's anchor), so the
///   sheet sharpens outwards from the fingers;
/// - **replaceable**: each display frame hands over the set it wants now; queued jobs outside
///   it are dropped before they start;
/// - **one at a time, off the main thread**: `render` hops to the raster source's actor, and
///   the main actor only awaits it and receives a finished `CGImage`.
@MainActor
final class CanvasTileRenderQueue {

    struct Job: Sendable {
        let key: CanvasTileCache.Key
        let plan: ViewportRasterPlan
        let scale: CGFloat
        /// Lower runs sooner.
        let priority: Double
    }

    /// Renders one plan; `nil` on failure.
    var render: (@MainActor (ViewportRasterPlan) async -> CGImage?)?
    /// Receives each finished tile on the main actor.
    var deliver: (@MainActor (Job, PageRaster) -> Void)?

    private var pending: [Job] = []
    private var running: (key: CanvasTileCache.Key, token: Int, task: Task<Void, Never>)?
    private var nextToken = 0

    /// Started renders, for tests and the diagnostics line.
    private(set) var startedCount = 0

    var pendingCount: Int { pending.count }

    /// Replaces what is queued with `jobs`, nearest first. The running job, if it is wanted
    /// again, is not queued twice.
    func replace(with jobs: [Job]) {
        pending = jobs
            .filter { $0.key != running?.key }
            .sorted { $0.priority < $1.priority }
        pump()
    }

    /// Drops everything queued. The one running tile finishes — a PDFKit draw cannot be
    /// interrupted — and still lands in the cache, where it is useful to the next gesture.
    func cancelQueued() {
        pending.removeAll()
    }

    /// Drops everything and abandons the running tile's result.
    func stop() {
        cancelQueued()
        running?.task.cancel()
        running = nil
    }

    /// Waits until the queue has nothing running and nothing queued. Tests only.
    func settle() async {
        while let task = running?.task {
            await task.value
        }
    }

    private func pump() {
        guard running == nil, !pending.isEmpty, let render else { return }
        let job = pending.removeFirst()
        startedCount += 1
        nextToken &+= 1
        let token = nextToken
        let task = Task { @MainActor [weak self] in
            let signpost = CanvasLog.signposter.beginInterval("TileRender")
            let image = await render(job.plan)
            // Into a surface off the main actor, so the layer shows it without a copy.
            let raster: PageRaster? = if let image {
                await CanvasSurfaceImage.surfaced(
                    PageRaster(image: image, coverage: .region(job.plan.pageRegion), scale: job.scale)
                )
            } else {
                nil
            }
            CanvasLog.signposter.endInterval("TileRender", signpost)
            guard let self, !Task.isCancelled, self.running?.token == token else { return }
            self.running = nil
            if let raster {
                self.deliver?(job, raster)
            }
            self.pump()
        }
        running = (job.key, token, task)
    }
}
