import Foundation
import Metal
import ZPDFContracts

/// A persistent GPU buffer of fixed-stride instances, sliced into per-markup slots.
///
/// # The whole point
///
/// A page holds 100 000 markups. Dragging one of them must cost one slot write, not 100 000. So
/// the arena remembers, per markup, where its instances live and what revision produced them:
///
/// - **Unchanged** `(id, revision)` — nothing is written. Not the instances, not the slot header,
///   nothing. The bytes in the buffer are already right.
/// - **Changed, same instance count or fewer** — the instances are overwritten in place. The
///   slot does not move, no other slot is touched, and the dirty range is exactly those bytes.
/// - **Changed, more instances than the slot holds** — the old slot is freed onto the free list
///   and a new one is allocated, preferentially from a free block of a suitable size, otherwise
///   at the high-water mark.
/// - **Removed** — the slot's instances are stamped with the dead flag, which the vertex stage
///   turns into off-screen geometry, and the slot goes on the free list. Nothing is compacted at
///   that moment, because compaction is the expensive thing and a deletion is not a reason to pay
///   for it.
///
/// Compaction runs only when dead space exceeds live space, and it is the one operation that
/// rewrites the buffer wholesale. Amortised over the allocations that caused it, it is O(1) per
/// instance.
///
/// # Dirty ranges
///
/// Every write records its byte extent. On a unified-memory device the buffer is `.storageShared`
/// and nothing has to be flushed, but the extent is still tracked and reported, because it is the
/// number the incremental benchmark asserts against and because a discrete GPU needs
/// `didModifyRange` over exactly that extent.
public final class InstanceArena<Element> {

    /// One markup's instances.
    public struct Slot {
        var offset: Int
        var capacity: Int
        var count: Int
        var revision: UInt64
    }

    private let device: any MTLDevice
    private let stride: Int
    private let dead: Element
    private let label: String
    /// Largest buffer the arena will grow to, in bytes. `2³¹` in production; a test lowers it to
    /// reach the allocation-failure path without allocating gigabytes.
    private let maximumByteCount: Int

    /// Upserts that could not get room for a grown slot. The markup keeps its previous
    /// instances rather than vanishing; see ``upsert(_:revision:elements:)`` (BH-629).
    public private(set) var allocationFailureCount = 0

    public private(set) var buffer: (any MTLBuffer)?
    private var capacityInElements = 0
    /// One past the highest element index ever allocated. Draw calls cover `0..<highWaterMark`.
    public private(set) var highWaterMark = 0
    private var slots: [MarkupID: Slot] = [:]
    /// Free blocks as `(offset, capacity)`, largest last.
    private var freeBlocks: [(offset: Int, capacity: Int)] = []
    private var deadElements = 0

    /// Instance payload bytes written during the current frame. Bookkeeping writes — stamping a
    /// freed slot dead, zeroing a freshly grown tail — are deliberately excluded: they are the
    /// cost of allocation, not of an update, and folding them in would make the incremental
    /// benchmark's ratio a measurement of the allocator instead of of the update path.
    public private(set) var frameUploadedBytes = 0
    /// Slots rewritten during the current frame.
    public private(set) var frameDirtySlots = 0
    private var frameDirtyLow = Int.max
    private var frameDirtyHigh = 0
    private var seenThisFrame: Set<MarkupID> = []
    private var sweepsThisFrame = true

    public init(device: any MTLDevice, dead: Element, label: String, maximumByteCount: Int = 1 << 31) {
        self.device = device
        self.stride = MemoryLayout<Element>.stride
        self.dead = dead
        self.label = label
        self.maximumByteCount = Swift.max(0, maximumByteCount)
    }

    public var residentByteCount: Int { capacityInElements * stride }
    /// The dirty byte range of the current frame, or `nil` when nothing was written.
    public var frameDirtyRange: Range<Int>? {
        frameDirtyLow <= frameDirtyHigh ? frameDirtyLow..<frameDirtyHigh : nil
    }

    // MARK: - Frame lifecycle

    /// Starts a frame that will visit every markup, so ``endFrame()`` can free the ones it did
    /// not see.
    public func beginFrame() {
        resetFrameCounters()
        sweepsThisFrame = true
        seenThisFrame.removeAll(keepingCapacity: true)
    }

    /// Starts a frame that will visit only the markups that changed.
    ///
    /// No slot can be freed in such a frame, because the arena is not being told about the ones
    /// that stayed. That is the point: at a hundred thousand markups, inserting every id into a
    /// seen-set once per frame costs more than the frame budget, and a drag changes one of them.
    /// The preparer only offers this path when it has established that nothing was added,
    /// removed or reordered.
    public func beginTargetedFrame() {
        resetFrameCounters()
        sweepsThisFrame = false
    }

    private func resetFrameCounters() {
        frameUploadedBytes = 0
        frameDirtySlots = 0
        frameDirtyLow = Int.max
        frameDirtyHigh = 0
    }

    /// Writes `elements` for `id`, or does nothing when `(id, revision)` is already resident.
    ///
    /// - Returns: `true` when bytes were written.
    @discardableResult
    public func upsert(_ id: MarkupID, revision: UInt64, elements: [Element]) -> Bool {
        if sweepsThisFrame { seenThisFrame.insert(id) }
        if let slot = slots[id], slot.revision == revision, slot.count == elements.count {
            return false
        }
        guard !elements.isEmpty else {
            release(id)
            if sweepsThisFrame { seenThisFrame.insert(id) }
            return false
        }
        if var slot = slots[id], slot.capacity >= elements.count {
            // In place. Instances beyond the new count are stamped dead so a shrinking markup
            // does not leave a tail of stale geometry behind it.
            write(elements, at: slot.offset)
            if slot.count > elements.count {
                let tail = [Element](repeating: dead, count: slot.count - elements.count)
                write(tail, at: slot.offset + elements.count, counted: false)
            }
            slot.count = elements.count
            slot.revision = revision
            slots[id] = slot
            frameDirtySlots += 1
            return true
        }
        // Room first, release second. Releasing first stamped the old instances dead, and when
        // the allocation then failed — memory pressure, or the 2³¹-byte cap — a markup that was
        // on screen last frame silently vanished (BH-629). Now a failed grow keeps the previous
        // instances drawing, is logged and counted, and returns `false`; the slot keeps its old
        // revision, so the next upsert of this markup retries.
        guard let offset = allocate(elements.count) else {
            allocationFailureCount += 1
            RendererLog.logger.error(
                "\(self.label, privacy: .public): no room for \(elements.count) instances; keeping the previous ones"
            )
            return false
        }
        release(id)
        write(elements, at: offset)
        slots[id] = Slot(offset: offset, capacity: elements.count, count: elements.count, revision: revision)
        frameDirtySlots += 1
        return true
    }

    /// Frees every slot the frame did not touch, then compacts when dead space has taken over.
    ///
    /// A targeted frame skips the sweep and the compaction — it has not been told about the slots
    /// it did not visit, so it must not conclude that they are gone.
    public func endFrame() {
        if sweepsThisFrame {
            var removed: [MarkupID] = []
            for (id, _) in slots where !seenThisFrame.contains(id) {
                removed.append(id)
            }
            for id in removed { release(id) }
            if deadElements > 0, deadElements > highWaterMark / 2 {
                compact()
            }
        }
        // `.managed` storage exists only on macOS discrete GPUs; iOS is unified-memory and
        // `.storageModeShared` throughout, so there is nothing to flush there.
        #if os(macOS)
        if let range = frameDirtyRange, let buffer, buffer.storageMode == .managed {
            buffer.didModifyRange(range)
        }
        #endif
    }

    /// Where `id`'s live instances sit in the buffer, or `nil` when it has no slot. The offset
    /// is in elements. Valid until the next upsert, release or compaction touching the arena.
    public func slotSpan(of id: MarkupID) -> (offset: Int, count: Int)? {
        guard let slot = slots[id] else { return nil }
        return (slot.offset, slot.count)
    }

    /// Frees `id`'s slot, stamping its instances dead.
    public func release(_ id: MarkupID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        let stamp = [Element](repeating: dead, count: slot.capacity)
        write(stamp, at: slot.offset, counted: false)
        freeBlocks.append((slot.offset, slot.capacity))
        deadElements += slot.capacity
        // Freeing a slot is not counted as a dirty slot. The counter answers "how many markups had
        // their instances rewritten", which is what the incremental benchmark and the hover test
        // are about; stamping a freed slot dead is bookkeeping, and counting it would make a
        // markup that merely moved between atlas buckets look like two rewrites.
    }

    public func removeAll() {
        slots.removeAll()
        freeBlocks.removeAll()
        deadElements = 0
        highWaterMark = 0
    }

    public func dispose() {
        removeAll()
        buffer = nil
        capacityInElements = 0
    }

    // MARK: - Allocation

    private func allocate(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        // Best fit among free blocks that are not wastefully large.
        var bestIndex: Int?
        for (index, block) in freeBlocks.enumerated() where block.capacity >= count {
            if bestIndex == nil || block.capacity < freeBlocks[bestIndex!].capacity {
                bestIndex = index
            }
        }
        if let bestIndex {
            let block = freeBlocks.remove(at: bestIndex)
            deadElements -= block.capacity
            if block.capacity > count {
                // Split, and the remainder goes straight back on the list as dead space.
                freeBlocks.append((block.offset + count, block.capacity - count))
                deadElements += block.capacity - count
            }
            return block.offset
        }
        guard reserve(highWaterMark + count) else { return nil }
        let offset = highWaterMark
        highWaterMark += count
        return offset
    }

    private func reserve(_ elements: Int) -> Bool {
        guard elements > capacityInElements else { return true }
        var target = Swift.max(capacityInElements * 2, 1024)
        while target < elements { target *= 2 }
        let byteCount = target * stride
        guard byteCount > 0, byteCount <= maximumByteCount else { return false }
        guard let replacement = device.makeBuffer(length: byteCount, options: .storageModeShared)
        else { return false }
        replacement.label = label
        if let existing = buffer, capacityInElements > 0 {
            memcpy(replacement.contents(), existing.contents(), capacityInElements * stride)
        }
        // The tail beyond the copied region is zeroed by Metal, and a zeroed instance has no dead
        // flag, so it is stamped here rather than left to draw a degenerate quad at the origin.
        let tailStart = capacityInElements
        buffer = replacement
        capacityInElements = target
        if target > tailStart {
            write([Element](repeating: dead, count: target - tailStart), at: tailStart, counted: false)
        }
        return true
    }

    private func write(_ elements: [Element], at offset: Int, counted: Bool = true) {
        guard let buffer, !elements.isEmpty, offset >= 0,
              offset + elements.count <= capacityInElements
        else { return }
        let byteOffset = offset * stride
        let byteCount = elements.count * stride
        elements.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            memcpy(buffer.contents().advanced(by: byteOffset), base, byteCount)
        }
        if counted { frameUploadedBytes += byteCount }
        frameDirtyLow = Swift.min(frameDirtyLow, byteOffset)
        frameDirtyHigh = Swift.max(frameDirtyHigh, byteOffset + byteCount)
    }

    /// Rewrites every live slot into a contiguous prefix. Only ever called when dead space is the
    /// majority of the buffer.
    private func compact() {
        guard buffer != nil else { return }
        let ordered = slots.sorted { $0.value.offset < $1.value.offset }
        var moved: [MarkupID: Slot] = [:]
        var cursor = 0
        var scratch: [Element] = []
        for (id, slot) in ordered {
            guard slot.count > 0 else { continue }
            if slot.offset != cursor {
                scratch = read(offset: slot.offset, count: slot.count)
                write(scratch, at: cursor, counted: false)
            }
            moved[id] = Slot(offset: cursor, capacity: slot.count, count: slot.count, revision: slot.revision)
            cursor += slot.count
        }
        if highWaterMark > cursor {
            write([Element](repeating: dead, count: highWaterMark - cursor), at: cursor, counted: false)
        }
        slots = moved
        freeBlocks.removeAll()
        deadElements = 0
        highWaterMark = cursor
    }

    private func read(offset: Int, count: Int) -> [Element] {
        guard let buffer, count > 0, offset >= 0, offset + count <= capacityInElements else {
            return []
        }
        let base = buffer.contents().advanced(by: offset * stride)
        return Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: Element.self),
            count: count
        ))
    }
}
