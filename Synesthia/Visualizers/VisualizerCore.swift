import Foundation
import Metal
import MetalKit
import Observation
import SwiftUI
import simd

// MARK: - Shared uniforms
// Layout must match `VizUniforms` in Shaders.metal exactly
// (currently 42 floats / 168 bytes). Both sides now assert it: the test
// `VizUniformsTests` pins the Swift layout and a `static_assert` in
// Shaders.metal pins the MSL one, so a one-sided edit fails the build or the
// test suite instead of silently shifting every field into the wrong shader
// variable.

/// The per-frame constants handed to every shader ("uniforms" in graphics
/// jargon: values that are the same for every pixel/vertex of a draw call).
/// Built fresh each frame by `MetalVisualizerView` from the clock, the latest
/// `AudioSnapshot`, and the user's tuning, then copied verbatim into GPU
/// memory — which is why the Swift struct and the MSL struct must stay
/// byte-identical: the GPU just reinterprets these bytes as its own struct.
///
/// Growing this struct is the supported way to give every visualizer a new
/// input. Two rules: **append to the end** (inserting in the middle shifts
/// every later field) and update the byte count in both files plus
/// `VizUniformsTests`. The option block `p0…p15` is the one exception — it is
/// deliberately contiguous so the shaders can declare it as `float p[16]` and
/// index it, which is what lets a *generic* shader host (the data-only plugin
/// idea in docs/roadmap.md) map a plugin's declared options onto slots
/// without knowing their names.
struct VizUniforms {
    /// Drawable size in pixels; shaders use it to correct for aspect ratio.
    var resolution = SIMD2<Float>(0, 0)
    /// Seconds since app launch — the animation clock.
    var time: Float = 0
    /// Seconds since the previous frame (clamped; see MetalVisualizerView).
    var dt: Float = 0
    // Audio features copied from AudioSnapshot (see AudioAnalyzer.swift for
    // what each one means). All roughly 0...1.
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beat: Float = 0
    // User tuning from the options popover.
    var sensitivity: Float = 1
    var speed: Float = 1
    /// Palette index as a float (uniform blocks hold floats; the shader
    /// rounds it back to an int).
    var palette: Float = 0
    // The visualizer's own options, in declaration order — 16 consecutive
    // floats, which is byte-identical to the `float p[16]` the shaders index.
    // Read them through `subscript(parameter:)` rather than by name.
    var p0: Float = 0
    var p1: Float = 0
    var p2: Float = 0
    var p3: Float = 0
    var p4: Float = 0
    var p5: Float = 0
    var p6: Float = 0
    var p7: Float = 0
    var p8: Float = 0
    var p9: Float = 0
    var p10: Float = 0
    var p11: Float = 0
    var p12: Float = 0
    var p13: Float = 0
    var p14: Float = 0
    var p15: Float = 0
    // Finer-grained audio features (named sub-bands and transients).
    var subBass: Float = 0
    var lowMid: Float = 0
    var highMid: Float = 0
    var presence: Float = 0
    var air: Float = 0
    var trebleBeat: Float = 0
    var flux: Float = 0
    var centroid: Float = 0
    // Per-frame state the host derives once so no visualizer has to keep it
    // itself. `beat`/`trebleBeat` are *envelopes* that decay smoothly, so
    // "a new hit landed this frame" is not something a shader can see; these
    // two are the rising edges, 1 on the frame of the hit and 0 otherwise —
    // exactly what a simulation kernel needs to apply an impulse (a GPU
    // kernel has no memory of the previous frame's envelope).
    var beatHit: Float = 0
    var trebleHit: Float = 0
    /// Kicks counted since launch. A free clock for anything that wants to
    /// advance per beat rather than per second (and the seed of the
    /// beat-synced scene changes in docs/roadmap.md).
    var beatCount: Float = 0
    /// Frames rendered since launch, wrapped well inside float precision.
    /// Useful as a per-frame seed for hashes and temporal dithering.
    var frame: Float = 0
    /// 1 when the system Reduce Motion setting is on. The host already damps
    /// the transient features (see `applyReduceMotionIfNeeded`), but some
    /// effects can only be toned down structurally — a particle sim's
    /// turbulence, a strobe — so they get told outright.
    var reduceMotion: Float = 0
    /// Ramps 0 → 1 over the first moments after this visualizer was built,
    /// so a switch can fade in rather than pop. Groundwork for the crossfade
    /// half of beat-synced scene changes.
    var intro: Float = 1

    /// The option slots in descriptor order. They are stored properties
    /// rather than a Swift array because the layout has to match MSL's
    /// `float p[16]` byte for byte, and this table is how the host fills them
    /// without a sixteen-case switch.
    private static let parameterKeyPaths: [WritableKeyPath<VizUniforms, Float>] = [
        \.p0, \.p1, \.p2, \.p3, \.p4, \.p5, \.p6, \.p7,
        \.p8, \.p9, \.p10, \.p11, \.p12, \.p13, \.p14, \.p15,
    ]

    /// How many options a visualizer may declare — one number, derived from
    /// the struct itself, that the host, the docs, and the tests all use.
    static var parameterCount: Int { parameterKeyPaths.count }

    subscript(parameter index: Int) -> Float {
        get { self[keyPath: Self.parameterKeyPaths[index]] }
        set { self[keyPath: Self.parameterKeyPaths[index]] = newValue }
    }

    /// Bounds-checked `subscript(parameter:)`: a descriptor that declares more
    /// options than there are slots quietly loses the extras rather than
    /// trapping in a release build.
    mutating func setParameter(_ index: Int, to value: Float) {
        guard Self.parameterKeyPaths.indices.contains(index) else { return }
        self[parameter: index] = value
    }
}

// MARK: - Plugin model
//
// Synesthia visualizers are plugins. To add one:
//   1. Create a class conforming to `Visualizer` with a static `descriptor`.
//   2. Add its shader functions to Shaders.metal (compiled into the app's
//      default library at build time).
//   3. Append the descriptor to `VisualizerRegistry.builtIn`, or call
//      `VisualizerRegistry.register(_:)` at startup (e.g. from a loaded bundle).
// Options declared in the descriptor automatically appear in the Options UI
// and arrive in `VizUniforms.p0...p15` in declaration order.

/// One user-tunable control: `range` bounds it, `defaultValue` is where reset
/// puts it. A visualizer may declare at most `VizUniforms.parameterCount` of
/// them (they map onto the shader's `p` array in declaration order).
///
/// A toggle is not a separate kind of thing — it is an option whose value is
/// 0 or 1, drawn as a switch instead of a slider. Storing it as a `Double`
/// like every other option means persistence, reset, and the parameter mapping
/// need no special case; the shader tests it with `> 0.5`.
struct VisualizerOption: Identifiable {
    /// How the options popover draws the control.
    enum Kind {
        case slider
        case toggle
    }

    let id: String
    let name: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let kind: Kind

    init(
        id: String, name: String, range: ClosedRange<Double>, defaultValue: Double,
        kind: Kind = .slider
    ) {
        self.id = id
        self.name = name
        self.range = range
        self.defaultValue = defaultValue
        self.kind = kind
    }

    /// An on/off option, stored as 0 or 1.
    static func toggle(id: String, name: String, defaultOn: Bool) -> VisualizerOption {
        VisualizerOption(
            id: id, name: name, range: 0...1, defaultValue: defaultOn ? 1 : 0, kind: .toggle)
    }
}

/// Static description of a visualizer: identity, UI strings, options, and a
/// factory closure. Descriptors are cheap values that exist even when their
/// visualizer isn't instantiated; the class itself (pipelines, buffers) is
/// only built via `make` when the user actually selects it.
struct VisualizerDescriptor: Identifiable {
    let id: String
    let name: String
    let tagline: String
    let options: [VisualizerOption]
    /// Builds the visualizer: (GPU device, compiled shader library, pixel
    /// format of the view it will draw into) → instance.
    let make: (MTLDevice, MTLLibrary, MTLPixelFormat) throws -> any Visualizer

    /// Written out rather than synthesized so the option cap is checked at
    /// the one place descriptors are built. The host silently drops options
    /// past the last slot (see `VizUniforms.setParameter`), which is the right
    /// behavior for a plugin loaded at runtime but a bug worth catching in a
    /// built-in.
    init(
        id: String, name: String, tagline: String, options: [VisualizerOption],
        make: @escaping (MTLDevice, MTLLibrary, MTLPixelFormat) throws -> any Visualizer
    ) {
        assert(
            options.count <= VizUniforms.parameterCount,
            "\(id) declares \(options.count) options; only \(VizUniforms.parameterCount) reach the shader")
        self.id = id
        self.name = name
        self.tagline = tagline
        self.options = options
        self.make = make
    }
}

/// The whole runtime contract: once per frame, encode your drawing into the
/// given command buffer. `uniforms` is prepared by the host; `snapshot`
/// additionally offers the full 64-band array and waveform for visualizers
/// that want more than the scalar features.
protocol Visualizer: AnyObject {
    func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot)
}

enum VisualizerRegistry {
    private(set) static var all: [VisualizerDescriptor] = [
        NebulaVisualizer.descriptor,
        TunnelVisualizer.descriptor,
        AuroraVisualizer.descriptor,
        BarsVisualizer.descriptor,
    ]

    /// Plugin entry point: external code can add visualizers at runtime.
    static func register(_ descriptor: VisualizerDescriptor) {
        guard !all.contains(where: { $0.id == descriptor.id }) else { return }
        all.append(descriptor)
    }

    static func descriptor(id: String) -> VisualizerDescriptor? {
        all.first { $0.id == id }
    }
}

// MARK: - Palettes

/// The five color schemes. Each is a *cosine palette* (Íñigo Quílez's
/// technique): color(t) = a + b·cos(2π(c·t + d)) per RGB channel, which turns
/// a single scalar t into a smooth, endlessly cyclable gradient from just
/// four coefficient vectors — no texture or lookup table needed.
enum Palettes {
    static let names = ["Prism", "Ember", "Ocean", "Violet", "Mono"]

    /// CPU mirror of `cosPalette` in Shaders.metal, for CPU-colored
    /// particles and the palette swatches in the options UI. Keep the
    /// coefficients in sync with the shader.
    static func color(_ t: Float, palette: Int) -> SIMD3<Float> {
        let a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, d: SIMD3<Float>
        switch palette {
        case 1:
            a = [0.55, 0.25, 0.12]; b = [0.45, 0.35, 0.20]; c = [1, 1, 1]; d = [0.00, 0.12, 0.25]
        case 2:
            a = [0.10, 0.35, 0.45]; b = [0.25, 0.35, 0.45]; c = [1, 1, 1]; d = [0.00, 0.10, 0.20]
        case 3:
            a = [0.40, 0.20, 0.50]; b = [0.50, 0.30, 0.50]; c = [1, 1, 1]; d = [0.80, 0.90, 0.30]
        case 4:
            a = [0.60, 0.60, 0.60]; b = [0.40, 0.40, 0.40]; c = [1, 1, 1]; d = [0, 0, 0]
        default:
            a = [0.50, 0.50, 0.50]; b = [0.50, 0.50, 0.50]; c = [1, 1, 1]; d = [0.00, 0.33, 0.67]
        }
        let angle = 6.28318 * (c * t + d)
        return a + b * SIMD3<Float>(cos(angle.x), cos(angle.y), cos(angle.z))
    }
}

// MARK: - Settings

/// Everything the user can tune about one visualizer. Nothing here is shared
/// with any other visualizer — switching visualizers restores its own look.
struct VisualizerTuning: Codable, Equatable {
    var sensitivity: Double = 1.0
    var speed: Double = 1.0
    var paletteIndex: Int = 0
    /// Descriptor option values keyed by option id; missing means "default".
    var options: [String: Double] = [:]

    func value(for option: VisualizerOption) -> Double {
        options[option.id] ?? option.defaultValue
    }

    static func defaults(for descriptor: VisualizerDescriptor) -> VisualizerTuning {
        var tuning = VisualizerTuning()
        for option in descriptor.options {
            tuning.options[option.id] = option.defaultValue
        }
        return tuning
    }

    /// Fills in unset options so a stored tuning can be compared to `defaults`.
    func normalized(for descriptor: VisualizerDescriptor) -> VisualizerTuning {
        var tuning = self
        tuning.options = descriptor.options.reduce(into: [:]) { $0[$1.id] = value(for: $1) }
        return tuning
    }
}

/// Persisted per-visualizer tuning, keyed by visualizer id. Stored as JSON in
/// `UserDefaults` and saved on every mutation (the payload is tiny).
@Observable
final class VisualizerSettings {
    private var tunings: [String: VisualizerTuning] {
        didSet { save() }
    }

    private static let storageKey = "VisualizerTunings"
    private static let legacyKey = "VisualizerSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([String: VisualizerTuning].self, from: data)
        {
            tunings = decoded
        } else {
            tunings = Self.migratedLegacyTunings()
        }
    }

    func tuning(for visualizer: String) -> VisualizerTuning {
        tunings[visualizer] ?? VisualizerTuning()
    }

    func update(_ visualizer: String, _ change: (inout VisualizerTuning) -> Void) {
        var tuning = tuning(for: visualizer)
        change(&tuning)
        tunings[visualizer] = tuning
    }

    /// Two-way binding into one field of a visualizer's tuning, so SwiftUI
    /// sliders/pickers can edit the stored value directly.
    func binding<V>(
        _ visualizer: String,
        _ keyPath: WritableKeyPath<VisualizerTuning, V>
    ) -> Binding<V> {
        Binding(
            get: { self.tuning(for: visualizer)[keyPath: keyPath] },
            set: { value in self.update(visualizer) { $0[keyPath: keyPath] = value } })
    }

    func binding(_ visualizer: String, option: VisualizerOption) -> Binding<Double> {
        Binding(
            get: { self.tuning(for: visualizer).value(for: option) },
            set: { value in self.update(visualizer) { $0.options[option.id] = value } })
    }

    /// The same binding as a `Bool`, for options drawn as a switch.
    func binding(_ visualizer: String, toggle option: VisualizerOption) -> Binding<Bool> {
        Binding(
            get: { self.tuning(for: visualizer).value(for: option) > 0.5 },
            set: { value in self.update(visualizer) { $0.options[option.id] = value ? 1 : 0 } })
    }

    func reset(_ descriptor: VisualizerDescriptor) {
        tunings[descriptor.id] = .defaults(for: descriptor)
    }

    func isDefault(_ descriptor: VisualizerDescriptor) -> Bool {
        tuning(for: descriptor.id).normalized(for: descriptor) == .defaults(for: descriptor)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tunings) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Carries the old global sensitivity/speed/palette onto every visualizer so
    /// an upgrade doesn't silently reset the user's look.
    private static func migratedLegacyTunings() -> [String: VisualizerTuning] {
        guard let stored = UserDefaults.standard.dictionary(forKey: legacyKey) else { return [:] }
        let legacyOptions = stored["options"] as? [String: Double] ?? [:]
        var result: [String: VisualizerTuning] = [:]
        for descriptor in VisualizerRegistry.all {
            var tuning = VisualizerTuning(
                sensitivity: stored["sensitivity"] as? Double ?? 1.0,
                speed: stored["speed"] as? Double ?? 1.0,
                paletteIndex: stored["paletteIndex"] as? Int ?? 0)
            for option in descriptor.options {
                // Legacy option keys were already namespaced by visualizer.
                if let value = legacyOptions["\(descriptor.id).\(option.id)"] {
                    tuning.options[option.id] = value
                }
            }
            result[descriptor.id] = tuning
        }
        return result
    }
}

// MARK: - Pipeline helpers

/// What a visualizer's `init` can fail with. Every case names the thing that
/// was missing, because these surface as a silent fall-through in the host
/// (`try? descriptor.make(...)`) and the message in the log is all there is
/// to go on.
enum VisualizerError: LocalizedError {
    /// No such function in the shader library — almost always a typo in a
    /// function name, or a `.metal` file that didn't make it into the target.
    case missingFunction(String)
    /// The GPU refused an allocation (a buffer or texture).
    case allocationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFunction(let name):
            return "Shader function “\(name)” is not in the Metal library"
        case .allocationFailed(let what):
            return "Could not allocate \(what)"
        }
    }
}

/// Builds a Metal render pipeline state: the pre-validated, GPU-compiled
/// combination of one vertex function + one fragment function + output
/// format. Creating these is expensive, so visualizers build theirs once in
/// `init` and reuse them every frame.
///
/// With `additiveBlending`, each drawn fragment is *added* to what's already
/// in the framebuffer instead of replacing it — overlapping translucent
/// things accumulate brightness the way overlapping lights do. That's the
/// standard look for glowing particles.
func makeRenderPipeline(
    device: MTLDevice,
    library: MTLLibrary,
    vertex: String,
    fragment: String,
    pixelFormat: MTLPixelFormat,
    additiveBlending: Bool = false
) throws -> MTLRenderPipelineState {
    guard let vertexFunction = library.makeFunction(name: vertex) else {
        throw VisualizerError.missingFunction(vertex)
    }
    guard let fragmentFunction = library.makeFunction(name: fragment) else {
        throw VisualizerError.missingFunction(fragment)
    }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = pixelFormat
    if additiveBlending {
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
    }
    return try device.makeRenderPipelineState(descriptor: descriptor)
}

/// Builds a Metal *compute* pipeline state: one kernel function, compiled and
/// validated up front exactly like a render pipeline.
///
/// A compute pass has no triangles and no pixels — it just runs a function
/// over a grid of threads, which is what makes it the right tool for
/// simulation: 100k particles are 100k independent threads reading and writing
/// GPU memory, with no drawing involved. See `GPUParticleSystem` for the
/// dispatch and buffer plumbing built on top of this.
func makeComputePipeline(
    device: MTLDevice,
    library: MTLLibrary,
    function: String
) throws -> MTLComputePipelineState {
    guard let kernel = library.makeFunction(name: function) else {
        throw VisualizerError.missingFunction(function)
    }
    return try device.makeComputePipelineState(function: kernel)
}
