import Foundation
import SwiftUI
import Metal
import MetalKit
import simd
import Observation

// MARK: - Shared uniforms
// Layout must match `VizUniforms` in Shaders.metal exactly
// (currently 24 floats / 96 bytes).

/// The per-frame constants handed to every shader ("uniforms" in graphics
/// jargon: values that are the same for every pixel/vertex of a draw call).
/// Built fresh each frame by `MetalVisualizerView` from the clock, the latest
/// `AudioSnapshot`, and the user's tuning, then copied verbatim into GPU
/// memory — which is why the Swift struct and the MSL struct must stay
/// byte-identical: the GPU just reinterprets these bytes as its own struct.
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
    /// The visualizer's own option sliders, in declaration order.
    var p0: Float = 0
    var p1: Float = 0
    var p2: Float = 0
    var p3: Float = 0
    // Finer-grained audio features (named sub-bands and transients).
    var subBass: Float = 0
    var lowMid: Float = 0
    var highMid: Float = 0
    var presence: Float = 0
    var air: Float = 0
    var trebleBeat: Float = 0
    var flux: Float = 0
    var centroid: Float = 0

    mutating func setParameter(_ index: Int, to value: Float) {
        switch index {
        case 0: p0 = value
        case 1: p1 = value
        case 2: p2 = value
        default: p3 = value
        }
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
// and arrive in `VizUniforms.p0...p3` in declaration order.

/// One user-tunable slider: `range` bounds it, `defaultValue` is where reset
/// puts it. A visualizer may declare at most four (they map onto p0...p3).
struct VisualizerOption: Identifiable {
    let id: String
    let name: String
    let range: ClosedRange<Double>
    let defaultValue: Double
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
}

/// The whole runtime contract: once per frame, encode your drawing into the
/// given command buffer. `uniforms` is prepared by the host; `snapshot`
/// additionally offers the full 64-band array and waveform for visualizers
/// that want more than the scalar features.
protocol Visualizer: AnyObject {
    func draw(in view: MTKView,
              commandBuffer: MTLCommandBuffer,
              uniforms: VizUniforms,
              snapshot: AudioSnapshot)
}

enum VisualizerRegistry {
    private(set) static var all: [VisualizerDescriptor] = [
        NebulaVisualizer.descriptor,
        TunnelVisualizer.descriptor,
        AuroraVisualizer.descriptor,
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
           let decoded = try? JSONDecoder().decode([String: VisualizerTuning].self, from: data) {
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
    func binding<V>(_ visualizer: String,
                    _ keyPath: WritableKeyPath<VisualizerTuning, V>) -> Binding<V> {
        Binding(get: { self.tuning(for: visualizer)[keyPath: keyPath] },
                set: { value in self.update(visualizer) { $0[keyPath: keyPath] = value } })
    }

    func binding(_ visualizer: String, option: VisualizerOption) -> Binding<Double> {
        Binding(get: { self.tuning(for: visualizer).value(for: option) },
                set: { value in self.update(visualizer) { $0.options[option.id] = value } })
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

// MARK: - Pipeline helper

/// Builds a Metal render pipeline state: the pre-validated, GPU-compiled
/// combination of one vertex function + one fragment function + output
/// format. Creating these is expensive, so visualizers build theirs once in
/// `init` and reuse them every frame.
///
/// With `additiveBlending`, each drawn fragment is *added* to what's already
/// in the framebuffer instead of replacing it — overlapping translucent
/// things accumulate brightness the way overlapping lights do. That's the
/// standard look for glowing particles.
func makeRenderPipeline(device: MTLDevice,
                        library: MTLLibrary,
                        vertex: String,
                        fragment: String,
                        pixelFormat: MTLPixelFormat,
                        additiveBlending: Bool = false) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: vertex)
    descriptor.fragmentFunction = library.makeFunction(name: fragment)
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
