import Foundation
import Testing

@testable import Synesthia

/// Tests for the CPU→GPU contract, which is the one place in the visualizer
/// stack with a *correct answer* rather than a judgement call about how things
/// look.
///
/// `VizUniforms` exists twice — once in Swift, once in MSL — and the GPU
/// reinterprets the Swift struct's raw bytes as its own. A mismatch doesn't
/// crash: every field after the edit silently lands in the wrong shader
/// variable, which looks like a visualizer that has gone subtly wrong for no
/// reason. Nothing caught that before. Now the MSL side has a
/// `static_assert(sizeof(VizUniforms) == 168)` and this file pins the Swift
/// side to the same layout, so a one-sided edit fails the build or fails here.
@MainActor
struct VizUniformsTests {

    // MARK: - Layout

    @Test func structIs42Floats() {
        // The number quoted in VisualizerCore.swift, Shaders.metal, and
        // docs/rendering.md. `stride` is what gets copied to the GPU.
        #expect(MemoryLayout<VizUniforms>.size == 168)
        #expect(MemoryLayout<VizUniforms>.stride == 168)
        #expect(MemoryLayout<VizUniforms>.stride % MemoryLayout<Float>.stride == 0)
        #expect(MemoryLayout<VizUniforms>.stride / MemoryLayout<Float>.stride == 42)
    }

    /// Every field, in order, at the offset the MSL struct puts it. Spelled out
    /// rather than computed: the point is to fail loudly when a field is
    /// inserted rather than appended.
    @Test func fieldOffsetsMatchTheShaderStruct() {
        let expected: [(String, PartialKeyPath<VizUniforms>, Int)] = [
            ("resolution", \VizUniforms.resolution, 0),
            ("time", \VizUniforms.time, 8),
            ("dt", \VizUniforms.dt, 12),
            ("bass", \VizUniforms.bass, 16),
            ("mid", \VizUniforms.mid, 20),
            ("treble", \VizUniforms.treble, 24),
            ("level", \VizUniforms.level, 28),
            ("beat", \VizUniforms.beat, 32),
            ("sensitivity", \VizUniforms.sensitivity, 36),
            ("speed", \VizUniforms.speed, 40),
            ("palette", \VizUniforms.palette, 44),
            ("p0", \VizUniforms.p0, 48),
            ("subBass", \VizUniforms.subBass, 112),
            ("lowMid", \VizUniforms.lowMid, 116),
            ("highMid", \VizUniforms.highMid, 120),
            ("presence", \VizUniforms.presence, 124),
            ("air", \VizUniforms.air, 128),
            ("trebleBeat", \VizUniforms.trebleBeat, 132),
            ("flux", \VizUniforms.flux, 136),
            ("centroid", \VizUniforms.centroid, 140),
            ("beatHit", \VizUniforms.beatHit, 144),
            ("trebleHit", \VizUniforms.trebleHit, 148),
            ("beatCount", \VizUniforms.beatCount, 152),
            ("frame", \VizUniforms.frame, 156),
            ("reduceMotion", \VizUniforms.reduceMotion, 160),
            ("intro", \VizUniforms.intro, 164),
        ]
        for (name, keyPath, offset) in expected {
            #expect(MemoryLayout<VizUniforms>.offset(of: keyPath) == offset, "\(name) moved")
        }
    }

    /// The option block has to be contiguous, because MSL declares it as
    /// `float p[16]` and indexes it. Sixteen separate Swift properties are only
    /// byte-identical to that array as long as nothing pads between them.
    @Test func optionSlotsAreContiguous() {
        let slots: [WritableKeyPath<VizUniforms, Float>] = [
            \.p0, \.p1, \.p2, \.p3, \.p4, \.p5, \.p6, \.p7,
            \.p8, \.p9, \.p10, \.p11, \.p12, \.p13, \.p14, \.p15,
        ]
        #expect(slots.count == VizUniforms.parameterCount)
        for (index, slot) in slots.enumerated() {
            #expect(MemoryLayout<VizUniforms>.offset(of: slot) == 48 + index * 4)
        }
    }

    // MARK: - Parameter mapping

    @Test func parametersMapInDeclarationOrder() {
        var uniforms = VizUniforms()
        for index in 0..<VizUniforms.parameterCount {
            uniforms.setParameter(index, to: Float(index) + 0.5)
        }
        for index in 0..<VizUniforms.parameterCount {
            #expect(uniforms[parameter: index] == Float(index) + 0.5)
        }
        // The first eight are the ones existing shaders and BarsVisualizer
        // read by name; spot-check that the mapping is the identity it looks
        // like and not off by one.
        #expect(uniforms.p0 == 0.5)
        #expect(uniforms.p7 == 7.5)
        #expect(uniforms.p15 == 15.5)
    }

    /// A descriptor with too many options loses the extras instead of trapping
    /// — the right behavior for a plugin loaded at runtime.
    @Test func extraParametersAreDropped() {
        var uniforms = VizUniforms()
        uniforms.setParameter(VizUniforms.parameterCount, to: 99)
        uniforms.setParameter(-1, to: 99)
        for index in 0..<VizUniforms.parameterCount {
            #expect(uniforms[parameter: index] == 0)
        }
    }

    @Test func defaultsAreNeutral() {
        let uniforms = VizUniforms()
        // Multipliers default to 1 so a visualizer drawn with a default-built
        // uniform block isn't invisible…
        #expect(uniforms.sensitivity == 1)
        #expect(uniforms.speed == 1)
        // …including the entrance ramp, which only starts at 0 when the host
        // is actually animating a switch.
        #expect(uniforms.intro == 1)
        #expect(uniforms.reduceMotion == 0)
    }

    // MARK: - The registry

    @Test func everyVisualizerFitsTheContract() {
        var seen = Set<String>()
        for descriptor in VisualizerRegistry.all {
            #expect(
                descriptor.options.count <= VizUniforms.parameterCount,
                "\(descriptor.id) declares more options than there are slots")
            #expect(seen.insert(descriptor.id).inserted, "duplicate id \(descriptor.id)")
            #expect(!descriptor.name.isEmpty)
            #expect(!descriptor.tagline.isEmpty)
            for option in descriptor.options {
                #expect(
                    option.range.contains(option.defaultValue),
                    "\(descriptor.id).\(option.id) defaults outside its own range")
            }
        }
    }

    @Test func registerIgnoresDuplicateIDs() {
        let before = VisualizerRegistry.all.count
        VisualizerRegistry.register(NebulaVisualizer.descriptor)
        #expect(VisualizerRegistry.all.count == before)
    }

    // MARK: - The option-slot contract

    @Test func everyOptionSlotIsUniqueAndInRange() {
        for descriptor in VisualizerRegistry.all {
            let slots = descriptor.options.map(\.slot)
            #expect(Set(slots).count == slots.count, "\(descriptor.id) reuses a slot")
            #expect(
                slots.allSatisfy { (0..<VizUniforms.parameterCount).contains($0) },
                "\(descriptor.id) declares a slot outside the block: \(slots)")
        }
    }

    /// Pins the Swift side against the `constant int k…` tables in
    /// Shaders.metal. If a descriptor is reordered or a shader constant is
    /// renumbered, exactly one of the two moves and this fails — which is the
    /// whole point of the plan that added `VisualizerOption.slot`.
    ///
    /// **The table below is hand-transcribed from Shaders.metal on purpose**
    /// (`kTunnel…` :193–198, `kAurora…` :417–419, `kNebula…` :578–587,
    /// `kBarsOpt…` :1228–1235). Do not "simplify" it into
    /// `descriptor.options.enumerated()` — that would restate the Swift side
    /// against itself and assert nothing at all.
    @Test func optionSlotsMatchTheShaderConstants() {
        let expected: [String: [String: Int]] = [
            "aurora": ["layers": 0, "height": 1, "stars": 2],
            "tunnel": ["twist": 0, "glow": 1, "bend": 2, "pulse": 3, "ripple": 4, "fog": 5],
            "nebula": [
                "density": 0, "glow": 1, "trails": 2, "turbulence": 3, "swirl": 4,
                "orbits": 5, "spread": 6, "halos": 7, "impact": 8, "form": 9,
            ],
            "bars": [
                "columns": 0, "segments": 1, "peaks": 2, "glow": 3,
                "deskPanel": 4, "desk": 5, "channels": 6, "meters": 7,
            ],
        ]
        for (id, table) in expected {
            guard let descriptor = VisualizerRegistry.descriptor(id: id) else {
                Issue.record("\(id) is no longer registered")
                continue
            }
            for option in descriptor.options {
                #expect(option.slot == table[option.id], "\(id).\(option.id) moved slot")
            }
            #expect(descriptor.options.count == table.count, "\(id) gained or lost an option")
        }
    }

    /// The other struct that exists twice. Nebula's particle state is declared
    /// in MSL (`NebulaParticle`, with its own `static_assert`) and mirrored in
    /// Swift only so the buffer stride comes from a layout; this pins the two
    /// to the same 96 bytes.
    @Test func nebulaParticleStateIs96Bytes() {
        #expect(NebulaVisualizer.particleStride == 96)
    }
}
