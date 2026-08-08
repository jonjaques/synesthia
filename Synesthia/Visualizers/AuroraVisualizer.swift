/// A night sky where every element is an instrument. Up to eight aurora
/// ribbons, one per register — sub-bass at the bottom of the sky through air
/// at the top — each with its own motion personality (lows fat and slow,
/// jumping on the kick; mids carrying the waveform and answering onsets;
/// highs thin and fast, shivering on hi-hats) and each shaded along its
/// length by the fine spectrum inside its own range. Above them a
/// three-depth star field twinkles with the air band, and every hi-hat and
/// kick lights a different constellation.
///
/// All of the imagery is in `auroraFragment` in Shaders.metal; there is no
/// Swift side left. This is a descriptor over `FullscreenShaderVisualizer`,
/// which owns the encode — the uniforms, the 64-band array, and the 256-point
/// waveform that shapes the ribbons.
enum AuroraVisualizer {
    static let descriptor = VisualizerDescriptor(
        id: "aurora",
        name: "Aurora",
        tagline: "One ribbon per instrument, under a sky that flashes with the drums",
        options: [
            VisualizerOption(id: "layers", name: "Ribbons", range: 2...8, defaultValue: 8),
            VisualizerOption(id: "height", name: "Wave height", range: 0.05...0.6, defaultValue: 0.28),
            VisualizerOption(id: "stars", name: "Stars", range: 0.0...2.0, defaultValue: 1.0),
        ],
        make: {
            try FullscreenShaderVisualizer(
                fragment: "auroraFragment", device: $0, library: $1, pixelFormat: $2)
        })
}
