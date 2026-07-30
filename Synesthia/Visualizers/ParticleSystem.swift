import Metal
import MetalKit

/// A GPU-resident particle simulation: the particles live in device-private
/// memory the CPU never touches, one compute kernel seeds them and another
/// advances every one of them in parallel each frame.
///
/// This is the plumbing half of a compute visualizer, deliberately empty of
/// physics — it owns the buffers, the ping-pong, the dispatch sizing, and the
/// binding convention; the visualizer owns the state layout and the two
/// kernels. Nebula is the first client (see `NebulaVisualizer` and the
/// `nebulaSeed`/`nebulaStep` kernels in Shaders.metal); a flocking or fluid
/// visualizer would supply a different layout and different kernels and reuse
/// everything here.
///
/// ### Why the CPU stops touching particles
///
/// The previous Nebula ran its simulation as a serial Swift loop on the render
/// thread, writing into `.storageModeShared` buffers. That caps out around
/// 4–8k particles: every particle costs main-thread time inside the frame, and
/// the buffers have to be triple-buffered with a semaphore so the CPU can't
/// overwrite a frame the GPU is still reading. A kernel has neither problem —
/// 100k+ particles are 100k independent threads, the buffers can be
/// `.storageModePrivate` (fastest GPU memory, no CPU visibility at all), and
/// the render thread does nothing but encode a dispatch.
///
/// ### Ping-pong
///
/// The step kernel reads one buffer and writes the other, then the two swap.
/// Nebula's particles only read their own slot, so it could update in place —
/// but read-only-in/write-only-out is the shape a neighbor-reading kernel
/// (flocking, SPH, any sim where particle A looks at particle B) requires, and
/// it costs one extra buffer. Both buffers are seeded over the full capacity
/// on the first step, so every slot holds valid state even before the density
/// control reaches it.
final class GPUParticleSystem {
    /// Buffer indices the simulation kernels bind. Fixed by convention so the
    /// kernels of different visualizers read the same way, and so this class
    /// can bind the shared four without knowing anything about the caller.
    enum Binding {
        /// Previous frame's state — read-only in the step kernel.
        static let stateIn = 0
        /// This frame's state — written by both kernels.
        static let stateOut = 1
        static let uniforms = 2
        /// The 64-band spectrum.
        static let bands = 3
        /// The 256-point waveform.
        static let waveform = 4
        /// First index a visualizer may bind its own per-frame constants to.
        static let custom = 5
    }

    /// Vertex-stage indices for the sprite draw (see `encodeSprites`).
    enum VertexBinding {
        static let state = 0
        static let uniforms = 1
        /// First index a visualizer may use for its own vertex-stage data.
        static let custom = 2
    }

    /// How many particles the buffers hold. The count actually simulated is
    /// per-frame (a density control), never more than this.
    let capacity: Int

    private let seedPipeline: MTLComputePipelineState
    private let stepPipeline: MTLComputePipelineState
    /// `buffers[0]` is always the most recently simulated state; `buffers[1]`
    /// is the one being written this frame. `step` swaps them.
    private var buffers: [MTLBuffer]
    private var needsSeed = true

    /// - Parameters:
    ///   - capacity: particle count the buffers are sized for.
    ///   - stateStride: bytes of simulation state per particle. Pass
    ///     `MemoryLayout<YourMirrorStruct>.stride` rather than a literal, so
    ///     the number tracks the layout.
    ///   - seedFunction: kernel that fills a fresh particle at `stateOut`.
    ///     Runs once, over the whole capacity, into both buffers.
    ///   - stepFunction: kernel that advances one particle from `stateIn` to
    ///     `stateOut`.
    init(
        device: MTLDevice,
        library: MTLLibrary,
        capacity: Int,
        stateStride: Int,
        seedFunction: String,
        stepFunction: String
    ) throws {
        self.capacity = capacity
        seedPipeline = try makeComputePipeline(device: device, library: library, function: seedFunction)
        stepPipeline = try makeComputePipeline(device: device, library: library, function: stepFunction)

        var allocated = [MTLBuffer]()
        for _ in 0..<2 {
            guard
                let buffer = device.makeBuffer(
                    length: capacity * stateStride, options: .storageModePrivate)
            else {
                throw VisualizerError.allocationFailed(
                    "\(capacity) particles (\(capacity * stateStride / 1_048_576) MB)")
            }
            allocated.append(buffer)
        }
        buffers = allocated
    }

    /// The buffer holding the most recently simulated state — what the render
    /// pass should read.
    var state: MTLBuffer { buffers[0] }

    /// Encodes one simulation step into `commandBuffer` and returns the buffer
    /// the new state landed in.
    ///
    /// Call this before opening the render encoder for the frame: Metal allows
    /// one encoder at a time, and ending the compute pass first lets its
    /// automatic hazard tracking insert the barrier that makes the vertex
    /// stage wait for the simulation.
    ///
    /// - Parameters:
    ///   - count: how many particles to simulate this frame, clamped to
    ///     `capacity`. Slots beyond it keep their previous state.
    ///   - custom: hook to bind anything else the kernels need, at
    ///     `Binding.custom` and up.
    @discardableResult
    func step(
        in commandBuffer: MTLCommandBuffer,
        count: Int,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot,
        custom: ((MTLComputeCommandEncoder) -> Void)? = nil
    ) -> MTLBuffer? {
        let active = min(max(count, 0), capacity)
        guard active > 0, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Particle simulation"

        if needsSeed {
            // Seed both halves of the ping-pong over the whole capacity, so
            // raising the density control later activates slots that already
            // hold a plausible particle rather than uninitialized memory.
            encoder.setComputePipelineState(seedPipeline)
            bindShared(uniforms: uniforms, snapshot: snapshot, to: encoder)
            for buffer in buffers {
                encoder.setBuffer(buffer, offset: 0, index: Binding.stateOut)
                dispatch(seedPipeline, threads: capacity, on: encoder)
            }
            needsSeed = false
        }

        encoder.setComputePipelineState(stepPipeline)
        encoder.setBuffer(buffers[0], offset: 0, index: Binding.stateIn)
        encoder.setBuffer(buffers[1], offset: 0, index: Binding.stateOut)
        bindShared(uniforms: uniforms, snapshot: snapshot, to: encoder)
        custom?(encoder)
        dispatch(stepPipeline, threads: active, on: encoder)
        encoder.endEncoding()

        buffers.swapAt(0, 1)
        return buffers[0]
    }

    /// The standard particle draw: one instanced quad per particle, four
    /// vertices each, reading the state buffer directly.
    ///
    /// Quads rather than Metal point sprites, which is what Nebula used to
    /// draw. A point sprite is always an axis-aligned square capped at a
    /// device-dependent size (90 px here, and that ceiling was reachable),
    /// while a quad the vertex shader positions itself can be scaled and
    /// *oriented* — which is what lets a particle stretch along its own
    /// velocity into a motion-blur streak.
    ///
    /// The caller sets the pipeline and binds `VizUniforms` at
    /// `VertexBinding.uniforms` first.
    func encodeSprites(into encoder: MTLRenderCommandEncoder, count: Int) {
        let active = min(max(count, 0), capacity)
        guard active > 0 else { return }
        encoder.setVertexBuffer(state, offset: 0, index: VertexBinding.state)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: active)
    }

    private func bindShared(
        uniforms: VizUniforms,
        snapshot: AudioSnapshot,
        to encoder: MTLComputeCommandEncoder
    ) {
        withUnsafeBytes(of: uniforms) {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: Binding.uniforms)
        }
        snapshot.bands.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: Binding.bands)
        }
        snapshot.waveform.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: Binding.waveform)
        }
    }

    /// One thread per particle. `dispatchThreads` (rather than
    /// `dispatchThreadgroups`) lets Metal size the ragged last threadgroup
    /// itself, so the kernel needs no bounds check and never runs on a
    /// particle that doesn't exist.
    private func dispatch(
        _ pipeline: MTLComputePipelineState,
        threads: Int,
        on encoder: MTLComputeCommandEncoder
    ) {
        // A multiple of the GPU's SIMD width, capped so a threadgroup's worth
        // of registers stays comfortable; 256 is the usual sweet spot.
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: threads, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: max(width, 1), height: 1, depth: 1))
    }
}
