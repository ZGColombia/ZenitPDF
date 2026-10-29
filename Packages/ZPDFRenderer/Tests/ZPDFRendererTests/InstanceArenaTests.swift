import Foundation
import Metal
import Testing
import ZPDFContracts
import ZPDFRenderer

/// The persistent GPU buffer and its slot allocator — the mechanism the incremental-update
/// requirement rests on.
@Suite("Instance arena", .serialized)
struct InstanceArenaTests {

    private func device() throws -> any MTLDevice {
        try #require(MTLCreateSystemDefaultDevice(), "this machine has no Metal device")
    }

    private func id(_ value: Int) -> MarkupID {
        MarkupID(UUID(uuidString: String(format: "D0D0D0D0-0000-0000-0000-%012d", value)) ?? UUID())
    }

    private func segments(_ count: Int, seed: Float) -> [SegmentInstance] {
        (0..<count).map { index in
            SegmentInstance(p0x: seed + Float(index), p0y: seed, p1x: seed + 1, p1y: seed, width: 1)
        }
    }

    @Test("Struct strides match the byte layout the shaders declare")
    func layoutStrides() {
        #expect(MetalInstanceLayout.segmentStride == 48)
        #expect(MetalInstanceLayout.triangleVertexStride == 16)
        #expect(MetalInstanceLayout.symbolStride == 48)
        #expect(MetalInstanceLayout.glyphStride == 48)
        #expect(MetalInstanceLayout.uniformStride == 64)
        // Swift does not raise a struct's alignment for a homogeneous tuple, so the Swift-side
        // alignment is 4. What matters is that every instance *offset* in the buffer is a
        // multiple of 16, which the shading language requires for a `float4` member, and that
        // follows from the strides above being multiples of 16.
        #expect(MetalInstanceLayout.segmentStride % 16 == 0)
        #expect(MetalInstanceLayout.symbolStride % 16 == 0)
        #expect(MetalInstanceLayout.glyphStride % 16 == 0)
        #expect(MetalInstanceLayout.uniformStride % 16 == 0)
        // Field offsets, spelled out against the Metal struct declarations.
        #expect(MemoryLayout<SegmentInstance>.offset(of: \.dashRuns) == 0)
        #expect(MemoryLayout<SegmentInstance>.offset(of: \.p0x) == 16)
        #expect(MemoryLayout<SegmentInstance>.offset(of: \.width) == 32)
        #expect(MemoryLayout<SegmentInstance>.offset(of: \.color) == 40)
        #expect(MemoryLayout<SegmentInstance>.offset(of: \.flags) == 44)
        #expect(MemoryLayout<SymbolInstance>.offset(of: \.centerX) == 16)
        #expect(MemoryLayout<SymbolInstance>.offset(of: \.color) == 32)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.anchorX) == 16)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.widthPixels) == 32)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.color) == 40)
        #expect(MemoryLayout<TriangleVertex>.offset(of: \.color) == 8)
    }

    @Test("Colour packing is RGBA8 in the order the shader unpacks")
    func colorPacking() {
        let packed = packColor(RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 0.25))
        #expect(packed & 0xFF == 255)
        #expect((packed >> 8) & 0xFF == 0)
        #expect((packed >> 16) & 0xFF == 128)
        #expect((packed >> 24) & 0xFF == 64)
        // Out-of-range and non-finite components clamp rather than wrapping.
        let hostile = packColor(RGBAColor(red: 5, green: -2, blue: .nan, alpha: 1))
        #expect(hostile & 0xFF == 255)
        #expect((hostile >> 8) & 0xFF == 0)
        #expect((hostile >> 16) & 0xFF == 0)
    }

    @Test("An unchanged revision writes no bytes at all")
    func unchangedWritesNothing() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(10, seed: 1))
        arena.endFrame()
        #expect(arena.frameUploadedBytes > 0)

        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(10, seed: 1))
        arena.endFrame()
        #expect(arena.frameUploadedBytes == 0)
        #expect(arena.frameDirtySlots == 0)
        #expect(arena.frameDirtyRange == nil)
    }

    @Test("A changed markup rewrites its own slot and nothing else")
    func changedRewritesOneSlot() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        for index in 0..<1_000 {
            arena.upsert(id(index), revision: 1, elements: segments(4, seed: Float(index)))
        }
        arena.endFrame()
        let fullBuild = arena.frameUploadedBytes
        #expect(fullBuild == 1_000 * 4 * MetalInstanceLayout.segmentStride)

        arena.beginFrame()
        for index in 0..<1_000 {
            let revision: UInt64 = index == 500 ? 2 : 1
            arena.upsert(id(index), revision: revision, elements: segments(4, seed: Float(index)))
        }
        arena.endFrame()
        #expect(arena.frameDirtySlots == 1)
        #expect(arena.frameUploadedBytes == 4 * MetalInstanceLayout.segmentStride)
        let range = try #require(arena.frameDirtyRange)
        #expect(range.count == 4 * MetalInstanceLayout.segmentStride)
        // The dirty region is one slot, not the whole buffer.
        #expect(range.count * 1_000 == fullBuild)
    }

    @Test("A slot that shrinks stamps its tail dead instead of leaving stale geometry")
    func shrinkingSlot() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(8, seed: 1))
        arena.endFrame()
        arena.beginFrame()
        arena.upsert(id(1), revision: 2, elements: segments(3, seed: 2))
        arena.endFrame()
        let buffer = try #require(arena.buffer)
        let base = buffer.contents().assumingMemoryBound(to: SegmentInstance.self)
        for index in 3..<8 {
            #expect(base[index].flags & MetalInstanceLayout.deadFlag != 0)
        }
        for index in 0..<3 {
            #expect(base[index].flags & MetalInstanceLayout.deadFlag == 0)
        }
    }

    @Test("A removed markup is stamped dead and its space is reused by the next allocation")
    func removalAndReuse() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        for index in 0..<10 {
            arena.upsert(id(index), revision: 1, elements: segments(5, seed: Float(index)))
        }
        arena.endFrame()
        let mark = arena.highWaterMark
        #expect(mark == 50)

        // Frame two drops one markup. Removal is detected at endFrame, so the block is only on
        // the free list once this frame is over — which is the design, and the test says so
        // rather than pretending an allocation in the same frame could have reused it.
        arena.beginFrame()
        for index in 0..<10 where index != 4 {
            arena.upsert(id(index), revision: 1, elements: segments(5, seed: Float(index)))
        }
        arena.endFrame()

        // Frame three adds a new markup of the same size; it lands in the freed block.
        arena.beginFrame()
        for index in 0..<10 where index != 4 {
            arena.upsert(id(index), revision: 1, elements: segments(5, seed: Float(index)))
        }
        arena.upsert(id(99), revision: 1, elements: segments(5, seed: 99))
        arena.endFrame()
        #expect(arena.highWaterMark == mark)
        #expect(arena.frameUploadedBytes == 5 * MetalInstanceLayout.segmentStride)
    }

    @Test("Compaction runs only when dead space is the majority, and preserves live slots")
    func compaction() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        for index in 0..<100 {
            arena.upsert(id(index), revision: 1, elements: segments(10, seed: Float(index)))
        }
        arena.endFrame()
        #expect(arena.highWaterMark == 1_000)

        // Drop ninety of the hundred: dead space is now 90 %, so the next endFrame compacts.
        arena.beginFrame()
        for index in 0..<10 {
            arena.upsert(id(index), revision: 1, elements: segments(10, seed: Float(index)))
        }
        arena.endFrame()
        #expect(arena.highWaterMark == 100)

        // The survivors are still correct and still identified.
        arena.beginFrame()
        for index in 0..<10 {
            arena.upsert(id(index), revision: 1, elements: segments(10, seed: Float(index)))
        }
        arena.endFrame()
        #expect(arena.frameUploadedBytes == 0)
    }

    @Test("Growth preserves existing contents and stamps the new tail dead")
    func growthPreservesContents() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(2_000, seed: 7))
        arena.endFrame()
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(2_000, seed: 7))
        arena.upsert(id(2), revision: 1, elements: segments(2_000, seed: 9))
        arena.endFrame()
        let buffer = try #require(arena.buffer)
        let base = buffer.contents().assumingMemoryBound(to: SegmentInstance.self)
        #expect(base[0].p0x == 7)
        #expect(base[2_000].p0x == 9)
        #expect(arena.frameUploadedBytes == 2_000 * MetalInstanceLayout.segmentStride)
    }

    @Test("An empty element list releases the slot rather than allocating a zero-length one")
    func emptyElements() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(4, seed: 1))
        arena.endFrame()
        arena.beginFrame()
        arena.upsert(id(1), revision: 2, elements: [])
        arena.endFrame()
        let buffer = try #require(arena.buffer)
        let base = buffer.contents().assumingMemoryBound(to: SegmentInstance.self)
        for index in 0..<4 {
            #expect(base[index].flags & MetalInstanceLayout.deadFlag != 0)
        }
    }

    @Test("Dispose releases everything and leaves the arena usable again")
    func disposeIsSafe() throws {
        let arena = InstanceArena<SegmentInstance>(device: try device(), dead: .dead, label: "t")
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(4, seed: 1))
        arena.endFrame()
        arena.dispose()
        #expect(arena.buffer == nil)
        #expect(arena.residentByteCount == 0)
        arena.beginFrame()
        arena.upsert(id(1), revision: 1, elements: segments(4, seed: 1))
        arena.endFrame()
        #expect(arena.highWaterMark == 4)
    }
}
