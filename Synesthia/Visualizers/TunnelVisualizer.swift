/// A raymarched flight through a winding cave whose geometry *is* the music:
/// the shader sphere-traces a real 3D distance field, so the tunnel's bends
/// genuinely occlude — the far end disappears behind the curve of the wall
/// and you never see the end (the old Mac tunnel-screensaver move, done with
/// actual depth). Each angular lane of the wall reads one spectrum band
/// (bass at the floor, treble overhead, mirror-folded so there is no seam)
/// and loud bands bulge the rock inward; bass swells the bore, spiral ridges
/// corkscrew past with the low-mids, the waveform rings the tube, and every
/// kick throws a wall of light up the tunnel at the camera. Crevice glow
/// from the march's iteration count lights the rock, volumetric steam fills
/// the bore with the mids and vocals, and the exposure of the whole scene
/// breathes with the track's loudness (tricks borrowed from the demoscene
/// "Sailing Beyond" hyper-tunnel).
///
/// All of it lives in `tunnelFragment` in Shaders.metal. This is a descriptor
/// over `FullscreenShaderVisualizer`, which owns the encode.
enum TunnelVisualizer {
    static let descriptor = VisualizerDescriptor(
        id: "tunnel",
        name: "Spectrum Tunnel",
        tagline: "Fly through a winding cave the music carves as you go",
        options: [
            VisualizerOption(id: "twist", name: "Twist", range: 0.0...3.0, defaultValue: 1.0),
            VisualizerOption(id: "glow", name: "Glow", range: 0.3...2.5, defaultValue: 1.0),
            VisualizerOption(id: "bend", name: "Bend", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "pulse", name: "Pulse", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "ripple", name: "Ripple", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "fog", name: "Fog", range: 0.0...2.0, defaultValue: 1.0),
        ],
        make: {
            try FullscreenShaderVisualizer(
                fragment: "tunnelFragment", device: $0, library: $1, pixelFormat: $2)
        })
}
