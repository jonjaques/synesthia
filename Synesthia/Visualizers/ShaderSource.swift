import Foundation

/// Metal shading-language source for all built-in visualizers, compiled at
/// runtime with `MTLDevice.makeLibrary(source:)`. Runtime compilation keeps
/// the build independent of the offline Metal toolchain and lets future
/// plugins ship their own shader source the same way.
enum ShaderSource {
    static let library = #"""
#include <metal_stdlib>
using namespace metal;

// Layout must match VizUniforms in VisualizerCore.swift exactly (24 floats / 96 bytes).
struct VizUniforms {
    float2 resolution;
    float time;
    float dt;
    float bass;
    float mid;
    float treble;
    float level;
    float beat;
    float sensitivity;
    float speed;
    float palette;
    float p0;
    float p1;
    float p2;
    float p3;
    float subBass;
    float lowMid;
    float highMid;
    float presence;
    float air;
    float trebleBeat;
    float flux;
    float centroid;
};

struct FSQuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSQuadOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    FSQuadOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    return out;
}

// ---------------------------------------------------------------- helpers

static float3 cosPalette(float t, float which) {
    float3 a, b, c, d;
    int p = int(which + 0.5);
    if (p == 1)      { a = float3(0.55, 0.25, 0.12); b = float3(0.45, 0.35, 0.20); c = float3(1.0); d = float3(0.00, 0.12, 0.25); } // Ember
    else if (p == 2) { a = float3(0.10, 0.35, 0.45); b = float3(0.25, 0.35, 0.45); c = float3(1.0); d = float3(0.00, 0.10, 0.20); } // Ocean
    else if (p == 3) { a = float3(0.40, 0.20, 0.50); b = float3(0.50, 0.30, 0.50); c = float3(1.0); d = float3(0.80, 0.90, 0.30); } // Violet
    else if (p == 4) { a = float3(0.60);             b = float3(0.40);             c = float3(1.0); d = float3(0.0);              } // Mono
    else             { a = float3(0.50);             b = float3(0.50);             c = float3(1.0); d = float3(0.00, 0.33, 0.67); } // Prism
    return a + b * cos(6.28318 * (c * t + d));
}

static float bandAt(constant float* bands, float x) {
    float f = clamp(x, 0.0, 0.9999) * 63.0;
    int i = int(f);
    return mix(bands[i], bands[min(i + 1, 63)], fract(f));
}

static float waveAt(constant float* wave, float x) {
    int i = int(clamp(x, 0.0, 0.9999) * 255.0);
    int a = max(i - 1, 0), b = min(i + 1, 255);
    return (wave[a] + wave[i] + wave[b]) / 3.0;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * vnoise(p);
        p *= 2.03;
        amp *= 0.5;
    }
    return v;
}

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Sparse twinkling point field; returns brightness at uv for one layer.
static float starLayer(float2 uv, float scale, float t, float twinkleSpeed) {
    float2 g = uv * scale;
    float2 id = floor(g);
    float h = hash21(id);
    if (h < 0.92) { return 0.0; }
    float2 f = fract(g) - 0.5;
    float2 offs = float2(hash21(id + 7.1), hash21(id + 3.7)) - 0.5;
    float d = length(f - offs * 0.6);
    float tw = 0.55 + 0.45 * sin(t * twinkleSpeed * (0.5 + h) + h * 40.0);
    return smoothstep(0.10, 0.0, d) * tw * (h - 0.92) * 12.5;
}

// ---------------------------------------------------------------- Spectrum Tunnel

fragment float4 tunnelFragment(FSQuadOut in [[stage_in]],
                               constant VizUniforms& u [[buffer(0)]],
                               constant float* bands [[buffer(1)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    uv.x *= u.resolution.x / max(u.resolution.y, 1.0);

    // sub-bass sways the camera; the kick nudges everything forward
    float wobble = (0.08 * u.subBass + 0.05 * u.bass) * u.sensitivity;
    uv += wobble * float2(sin(u.time * 0.7), cos(u.time * 0.9));

    float r = length(uv);
    float angle = atan2(uv.y, uv.x);
    float depth = 0.35 / max(r, 1e-3) + u.time * u.speed * 1.2 + 0.30 * u.beat;

    float twist = u.p0;
    float glow = u.p1;
    float ang01 = fract(angle / 6.28318 + 0.5 + twist * 0.05 * depth);

    float e  = clamp(bandAt(bands, ang01) * u.sensitivity, 0.0, 1.5);
    float eN = clamp(bandAt(bands, fract(ang01 + 0.03 * sin(depth * 0.7))) * u.sensitivity, 0.0, 1.5);

    // primary rings, sharpened by the band energy at this angle
    float rings = pow(abs(sin(depth * 3.14159)), 8.0 + 26.0 * (1.0 - min(e, 1.0)));
    float3 col = cosPalette(ang01 + depth * 0.05 + u.centroid * 0.25, u.palette)
               * (rings * (0.30 + 2.4 * e) + e * e * 0.55 * glow);

    // fine interleaved rings answering the high-mids
    float rings2 = pow(abs(sin(depth * 6.28318 + 1.5708)), 24.0);
    col += cosPalette(ang01 + 0.4, u.palette) * rings2
         * clamp(u.highMid * u.sensitivity, 0.0, 1.2) * 0.8 * glow;

    // radial light spokes riding the presence band
    float spokes = pow(abs(sin(angle * 18.0 + depth * 0.6)), 10.0);
    col += cosPalette(ang01 + 0.15, u.palette) * spokes * (0.10 + 0.90 * eN)
         * clamp(u.presence * u.sensitivity, 0.0, 1.2) * 0.9;

    // dust motes streaming past, lit by the treble
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float layerDepth = depth * (0.5 + fi * 0.23) + fi * 17.0;
        float2 cell = float2(floor(ang01 * 64.0 + fi * 13.0), floor(layerDepth));
        float h = hash21(cell);
        if (h > 0.94) {
            float2 f = float2(fract(ang01 * 64.0 + fi * 13.0), fract(layerDepth)) - 0.5;
            float d = length(f * float2(1.0, 0.35));
            float tw = 0.6 + 0.4 * sin(u.time * 14.0 + h * 50.0);
            col += cosPalette(h + u.centroid * 0.3, u.palette) * smoothstep(0.35, 0.0, d)
                 * (0.20 + 1.3 * u.treble * u.sensitivity) * tw
                 * smoothstep(1.5, 0.4, r) * 0.55;
        }
    }

    // beat flash washing outward from the center
    col += cosPalette(depth * 0.08, u.palette) * u.beat * 0.4 * smoothstep(0.9, 0.0, r);
    // hi-hat glints at the tunnel mouth
    col += float3(0.90, 0.95, 1.0) * u.trebleBeat * 0.25 * smoothstep(0.55, 0.10, r);
    // warm core
    col += float3(1.0, 0.95, 0.85) * u.bass * u.sensitivity * 0.4 * glow * smoothstep(0.45, 0.0, r);

    // onsets lift the whole scene a touch
    col *= 1.0 + 0.22 * u.flux;

    col *= smoothstep(1.7, 0.35, r);
    col = col / (1.0 + col);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- Aurora

fragment float4 auroraFragment(FSQuadOut in [[stage_in]],
                               constant VizUniforms& u [[buffer(0)]],
                               constant float* bands [[buffer(1)]],
                               constant float* wave [[buffer(2)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float3 col = mix(float3(0.010, 0.012, 0.030), float3(0.020, 0.030, 0.055), uv.y);

    // twinkling stars in the upper sky, brightened by the air band
    float2 suv = float2(uv.x * aspect, uv.y);
    float stars = starLayer(suv, 60.0, u.time, 3.0)
                + starLayer(suv + 3.7, 110.0, u.time, 5.0) * 0.6;
    col += stars * (0.30 + 0.70 * clamp(u.air * u.sensitivity, 0.0, 1.0))
         * smoothstep(0.35, 0.75, uv.y);

    // drifting haze that brightens with the low end, tinted by brightness
    float haze = fbm(uv * 3.0 + float2(u.time * 0.05 * u.speed, 0.0));
    col += cosPalette(0.6 + u.centroid * 0.3 + u.time * 0.01, u.palette) * haze
         * (0.03 + 0.10 * u.bass * u.sensitivity);

    // ground fog breathing with the sub-bass
    float fog = fbm(float2(uv.x * 4.0 + u.time * 0.08 * u.speed, uv.y * 9.0));
    col += cosPalette(0.05, u.palette) * fog * smoothstep(0.30, 0.0, uv.y)
         * (0.04 + 0.30 * u.subBass * u.sensitivity);

    int layers = clamp(int(u.p0 + 0.5), 2, 10);
    float height = u.p1;

    for (int i = 0; i < 10; i++) {
        if (i >= layers) break;
        float fi = float(i) / float(max(layers - 1, 1));
        float bandE = clamp(bandAt(bands, 0.06 + fi * 0.88) * u.sensitivity, 0.0, 1.3);
        float w = waveAt(wave, fract(uv.x + fi * 0.13));
        // fine ripple from the high-mids
        float ripple = 0.012 * sin(uv.x * 42.0 + u.time * u.speed * 3.0 + fi * 9.0)
                     * clamp(u.highMid * u.sensitivity, 0.0, 1.2);
        float yC = 0.5
                 + (fi - 0.5) * 0.55
                 + w * height * (0.35 + 0.65 * bandE)
                 + ripple
                 + 0.045 * sin(uv.x * (5.0 + fi * 4.0) + u.time * u.speed * (0.6 + fi * 0.8));
        // thickness pulses along the ribbon with local spectral detail
        float local = bandAt(bands, fract(uv.x * 0.35 + fi * 0.2));
        float thickness = (0.005 + 0.040 * bandE) * (0.7 + 0.8 * local);
        float glow = thickness / (fabs(uv.y - yC) + thickness);
        glow = pow(glow, 1.6);
        // vertical curtain rays driven by the presence band
        float rays = 0.85 + 0.30 * sin(uv.x * (90.0 + fi * 20.0) + u.time * u.speed * (1.5 + fi))
                   * clamp(u.presence * u.sensitivity * 1.5, 0.0, 1.0);
        col += cosPalette(fi * 0.85 + u.centroid * 0.2 + u.time * 0.015, u.palette)
             * glow * rays * (0.12 + 0.95 * bandE);
    }

    // treble sparkles that twinkle in place instead of strobing
    float2 g = floor(uv * u.resolution * 0.35);
    float h = hash21(g);
    float sparkle = step(0.9975, h) * (0.5 + 0.5 * sin(u.time * 20.0 + h * 80.0));
    col += sparkle * (u.treble + u.trebleBeat * 0.7) * u.sensitivity * 0.9;

    // beat lift + onset shimmer
    col *= 1.0 + 0.18 * u.beat + 0.10 * u.flux;

    col = col / (1.0 + col);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- Nebula

fragment float4 nebulaBackgroundFragment(FSQuadOut in [[stage_in]],
                                         constant VizUniforms& u [[buffer(0)]],
                                         constant float* bands [[buffer(1)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    uv.x *= u.resolution.x / max(u.resolution.y, 1.0);
    float r = length(uv);

    float3 col = float3(0.008, 0.008, 0.012);

    // deep-space stars, twinkling harder as the air band opens up
    float stars = starLayer(uv, 40.0, u.time, 2.0) + starLayer(uv + 11.3, 80.0, u.time, 4.0) * 0.5;
    col += stars * (0.20 + 0.80 * clamp(u.air * u.sensitivity, 0.0, 1.0));

    // slow smoky nebula, breathing with the bass
    float smoke = fbm(uv * 1.6 + float2(u.time * 0.03 * u.speed, -u.time * 0.02 * u.speed));
    smoke *= fbm(uv * 3.1 - float2(0.0, u.time * 0.04 * u.speed));
    col += cosPalette(0.15 + u.centroid * 0.3 + u.time * 0.008, u.palette) * smoke
         * (0.05 + 0.22 * u.bass * u.sensitivity);

    // counter-drifting wisp layer riding the low-mids
    float wisp = fbm(rot2(uv, 0.7) * 2.2 + float2(-u.time * 0.025 * u.speed, u.time * 0.018 * u.speed));
    col += cosPalette(0.45 + u.centroid * 0.2, u.palette) * wisp * wisp
         * (0.03 + 0.18 * u.lowMid * u.sensitivity);

    // soft core glow pulsing on the beat and flaring with onsets
    col += cosPalette(0.5, u.palette)
         * (0.05 + 0.30 * u.beat + 0.15 * u.flux + 0.18 * u.bass * u.sensitivity)
         * smoothstep(0.9, 0.0, r) * 0.35;

    col *= smoothstep(2.0, 0.5, r);
    return float4(col, 1.0);
}

struct Particle {
    float4 posSize;   // xyz = position, w = point size hint
    float4 color;     // rgb, a = intensity
};

struct ParticleOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex ParticleOut particleVertex(uint vid [[vertex_id]],
                                  constant Particle* particles [[buffer(0)]],
                                  constant VizUniforms& u [[buffer(1)]]) {
    Particle p = particles[vid];

    float yaw = u.time * 0.12 * u.speed;
    float pitch = 0.30 * sin(u.time * 0.06 * u.speed);
    float cy = cos(yaw), sy = sin(yaw);
    float cp = cos(pitch), sp = sin(pitch);
    float3x3 rotY = float3x3(float3(cy, 0.0, -sy), float3(0.0, 1.0, 0.0), float3(sy, 0.0, cy));
    float3x3 rotX = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, cp, sp), float3(0.0, -sp, cp));

    float3 pos = rotX * (rotY * p.posSize.xyz);
    pos.z += 3.4;

    float persp = 1.0 / max(pos.z, 0.25);
    float2 clip = pos.xy * persp * 1.6;
    clip.x *= u.resolution.y / max(u.resolution.x, 1.0);

    ParticleOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.pointSize = clamp(p.posSize.w * persp * u.resolution.y * 0.012, 1.0, 90.0);
    out.color = p.color;
    return out;
}

fragment float4 particleFragment(ParticleOut in [[stage_in]],
                                 float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float a = exp(-d * d * 4.5) * smoothstep(1.0, 0.65, d);
    float3 col = in.color.rgb * a * in.color.a;
    return float4(col, a * in.color.a);
}
"""#
}
