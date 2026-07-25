import Foundation
import Metal
import MetalKit
import simd
import Observation

// MARK: - Shared uniforms
// Layout must match `VizUniforms` in ShaderSource.swift exactly
// (currently 24 floats / 96 bytes).

struct VizUniforms {
    var resolution = SIMD2<Float>(0, 0)
    var time: Float = 0
    var dt: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beat: Float = 0
    var sensitivity: Float = 1
    var speed: Float = 1
    var palette: Float = 0
    var p0: Float = 0
    var p1: Float = 0
    var p2: Float = 0
    var p3: Float = 0
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
//   2. Put its shaders in any .metal file in the target (they all compile
//      into the default library).
//   3. Append the descriptor to `VisualizerRegistry.builtIn`, or call
//      `VisualizerRegistry.register(_:)` at startup (e.g. from a loaded bundle).
// Options declared in the descriptor automatically appear in the Options UI
// and arrive in `VizUniforms.p0...p3` in declaration order.

struct VisualizerOption: Identifiable {
    let id: String
    let name: String
    let range: ClosedRange<Double>
    let defaultValue: Double
}

struct VisualizerDescriptor: Identifiable {
    let id: String
    let name: String
    let tagline: String
    let options: [VisualizerOption]
    let make: (MTLDevice, MTLLibrary, MTLPixelFormat) throws -> any Visualizer
}

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

enum Palettes {
    static let names = ["Prism", "Ember", "Ocean", "Violet", "Mono"]

    /// CPU mirror of the cosine palette in Shaders.metal, for CPU-colored particles.
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

/// Persisted user tuning: global sensitivity/speed/palette plus per-visualizer
/// option values keyed by "visualizerID.optionID".
@Observable
final class VisualizerSettings {
    var sensitivity: Double {
        didSet { save() }
    }
    var speed: Double {
        didSet { save() }
    }
    var paletteIndex: Int {
        didSet { save() }
    }
    private var optionValues: [String: Double] {
        didSet { save() }
    }

    private static let defaultsKey = "VisualizerSettings"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        sensitivity = stored["sensitivity"] as? Double ?? 1.0
        speed = stored["speed"] as? Double ?? 1.0
        paletteIndex = stored["paletteIndex"] as? Int ?? 0
        optionValues = stored["options"] as? [String: Double] ?? [:]
    }

    func value(visualizer: String, option: VisualizerOption) -> Double {
        optionValues["\(visualizer).\(option.id)"] ?? option.defaultValue
    }

    func setValue(_ value: Double, visualizer: String, option: VisualizerOption) {
        optionValues["\(visualizer).\(option.id)"] = value
    }

    private func save() {
        UserDefaults.standard.set([
            "sensitivity": sensitivity,
            "speed": speed,
            "paletteIndex": paletteIndex,
            "options": optionValues,
        ] as [String: Any], forKey: Self.defaultsKey)
    }
}

// MARK: - Pipeline helper

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
