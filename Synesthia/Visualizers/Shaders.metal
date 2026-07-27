// All shader code for the built-in visualizers, compiled at build time into
// the app's default Metal library (loaded via device.makeDefaultLibrary()).
//
// A primer for readers new to shaders: a *vertex* function runs once per
// vertex and decides where geometry lands on screen; a *fragment* function
// runs once per covered pixel and decides its color. The visualizers here
// are mostly "full-screen shader" style — a single triangle covers the
// window, and the fragment function computes every pixel's color from
// scratch each frame using only its coordinates, the clock, and the audio
// uniforms (the style popularized by Shadertoy).
//
// External visualizer plugins (a roadmap item) wouldn't compile into this
// library; they can ship MSL source and compile it at load time with
// MTLDevice.makeLibrary(source:), which is how this whole file used to work.

#include <metal_stdlib>
using namespace metal;

// Layout must match VizUniforms in VisualizerCore.swift exactly (28 floats / 112 bytes).
// The CPU fills that Swift struct each frame and copies its raw bytes here;
// see VisualizerCore.swift for what each field means.
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
    float p4;
    float p5;
    float p6;
    float p7;
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

// The standard "fullscreen triangle" trick: one triangle big enough that the
// screen rectangle is entirely inside it (clipped at the edges). Cheaper and
// simpler than two triangles forming a quad, and the vertex positions are
// generated from the vertex index — no vertex buffer needed at all.
// uv comes out as 0...1 across the visible screen.
vertex FSQuadOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    FSQuadOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    return out;
}

// ---------------------------------------------------------------- helpers

// Cosine palette (Íñigo Quílez): a + b*cos(2π(c*t + d)) per channel maps any
// scalar t to a smooth cyclic gradient. Coefficients must stay in sync with
// the CPU mirror in VisualizerCore.swift (Palettes.color).
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

// Samples the 64-band spectrum at a continuous position x in 0...1, linearly
// interpolating between neighboring bands so sweeps look smooth.
static float bandAt(constant float* bands, float x) {
    float f = clamp(x, 0.0, 0.9999) * 63.0;
    int i = int(f);
    return mix(bands[i], bands[min(i + 1, 63)], fract(f));
}

// Samples the 256-point waveform at x in 0...1, averaged with its neighbors
// to soften single-sample spikes.
static float waveAt(constant float* wave, float x) {
    int i = int(clamp(x, 0.0, 0.9999) * 255.0);
    int a = max(i - 1, 0), b = min(i + 1, 255);
    return (wave[a] + wave[i] + wave[b]) / 3.0;
}

// Cheap 2D → pseudo-random hash in 0...1. Not statistically great, but fast
// and stable per input — used to scatter stars/particles deterministically.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise: random values at integer grid points, smoothly interpolated
// between them. Gives soft, organic variation rather than white noise.
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Fractal Brownian motion: several octaves of noise, each at double the
// frequency and half the amplitude of the last. The classic recipe for
// clouds, smoke, and haze.
static float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * vnoise(p);
        p *= 2.03;
        amp *= 0.5;
    }
    return v;
}

// 2D rotation by angle a.
static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Sparse twinkling point field; returns brightness at uv for one layer.
// Space is cut into a grid; ~8% of cells (hash > 0.92) contain a star at a
// hashed offset, each pulsing on its own phase.
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
//
// A raymarched flight through a winding cave. Unlike the other fragment
// shaders (which fake depth with a polar mapping), this one marches an
// actual 3D signed-distance field: the tunnel is a bore of varying radius
// around a centerline that snakes through space, so bends really occlude —
// the far end disappears behind the curve of the wall and you never see the
// end. The camera rides the centerline. Adapted from two Shadertoy
// references: XtdGR7 (the winding SDF tunnel) and the "Hyper Tunnel" from
// the demo "Sailing Beyond" (crevice lighting from the iteration count,
// power-shaped fbm crags, the volumetric steam pass, and the audio-pumped
// exposure). Their texture lookups are replaced with procedural 3D value
// noise, so no assets are needed.
//
// The audio is carved into the geometry itself: each angular lane of the
// wall reads one slice of the 64-band spectrum (bass at the floor, treble
// overhead, mirror-folded so there is no seam) and loud bands physically
// bulge the rock inward; the bass swells the whole bore; spiral ridges
// corkscrew past at a rate set by the Twist slider with depth from the
// low-mids; the waveform rings the bore along its length; every kick throws
// a wall of light up the tunnel toward the camera; the mids, presence and
// onsets pump the steam; and the scene's exposure breathes with the track's
// overall loudness.

// 3D value-noise stack standing in for Shadertoy's RGBA-noise texture.
static float hash31(float3 p) {
    p = fract(p * float3(443.897, 441.423, 437.195));
    p += dot(p, p.yzx + 19.19);
    return fract((p.x + p.y) * p.z);
}

static float vnoise3(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i);
    float n100 = hash31(i + float3(1.0, 0.0, 0.0));
    float n010 = hash31(i + float3(0.0, 1.0, 0.0));
    float n110 = hash31(i + float3(1.0, 1.0, 0.0));
    float n001 = hash31(i + float3(0.0, 0.0, 1.0));
    float n101 = hash31(i + float3(1.0, 0.0, 1.0));
    float n011 = hash31(i + float3(0.0, 1.0, 1.0));
    float n111 = hash31(i + float3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// Balanced three-octave fbm, ~0…0.875 — used for color/steam variation.
static float fbm3(float3 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 3; i++) {
        v += amp * vnoise3(p);
        p *= 2.03;
        amp *= 0.5;
    }
    return v;
}

// Demoscene-style fbm (after "Sailing Beyond"): heavily weighted first
// octave with frequency *tripling* per octave, ~0…0.33. Shaped with a power
// curve at the call site it makes terraced, cliff-like billows rather than
// soft lumps.
static float fbmSharp(float3 p) {
    float r = 0.0, w = 1.0, s = 1.0;
    for (int i = 0; i < 3; i++) {
        w *= 0.25;
        s *= 3.0;
        r += w * vnoise3(p * s);
    }
    return r;
}

// Where the tunnel's centerline sits at distance z: layered incommensurate
// sines, so the path winds forever without repeating. The amplitude is on
// the order of the bore radius — that is what makes curves actually occlude
// instead of just leaning.
static float2 tunnelCenter(float z, float bend) {
    return float2(sin(z * 0.31) + 0.6 * sin(z * 0.17 + 4.0),
                  cos(z * 0.23) + 0.6 * sin(z * 0.13 + 1.0)) * 0.55 * bend;
}

// Mirror-folded angle around the bore (0 = floor, 1 = ceiling): band 0 and
// band 63 never sit next to each other, so the spectrum wall has no seam.
// The +0.25 phase puts the fold's minimum at angle -π/2 (straight down), so
// the bass really is at the floor and the treble overhead as documented —
// +0.75 (the obvious other choice) flips the whole spectrum upside down.
static float tunnelFold(float angle) {
    return 1.0 - fabs(fract(angle / 6.28318 + 0.25) * 2.0 - 1.0);
}

// The signed-distance field: positive inside the air of the tunnel, zero at
// the wall. Everything audible deforms it — see the section comment.
static float tunnelMap(float3 pos, constant VizUniforms& u,
                       constant float* bands, constant float* wave) {
    float2 xy = pos.xy - tunnelCenter(pos.z, u.p2);
    float angle = atan2(xy.y, xy.x);
    float e = clamp(bandAt(bands, tunnelFold(angle)) * u.sensitivity, 0.0, 1.2);
    // spiral ridges spinning past: rate from the Twist slider, depth from
    // the low-mids
    float arms = sin(angle * 3.0 - pos.z * 0.4 + u.time * u.speed * (0.5 + 1.0 * u.p0))
               * (0.05 + 0.25 * clamp(u.lowMid * u.sensitivity, 0.0, 1.0));
    // power-shaped noise carves terraced crags into the rock
    float crags = pow(fbmSharp(pos * 0.55) * 3.3, 1.3);
    // the bore's own slow, irregular breathing: a drifting noise field, so
    // caverns open and close instead of repeating like a sine would
    float cavern = vnoise3(float3(1.7, 2.9, pos.z * 0.06) + float3(0.0, u.time * 0.05, 0.0)) - 0.5;
    float r = 1.1
        + 0.5 * cavern
        + 0.35 * u.bass * u.sensitivity                     // bass blows the tunnel wide
        + u.p4 * (0.42 * crags - 0.30                       // crags (Ripple slider)
                  + 0.06 * waveAt(wave, fract(pos.z * 0.10)))
        + arms
        - 0.30 * e * e;                                     // loud bands bulge the wall inward
    // Floor the bore radius so a worst-case pile-up of carvings can never
    // close the tunnel over the camera (which rides the centerline).
    r = max(r, 0.30);
    return r - length(xy);
}

fragment float4 tunnelFragment(FSQuadOut in [[stage_in]],
                               constant VizUniforms& u [[buffer(0)]],
                               constant float* bands [[buffer(1)]],
                               constant float* wave [[buffer(2)]]) {
    float glow = u.p1;
    float pulse = u.p3;
    float fogAmt = u.p5;

    // Square-space pixel coordinates (y half-height = 1).
    float2 suv = in.uv * 2.0 - 1.0;
    suv.x *= u.resolution.x / max(u.resolution.y, 1.0);

    // The camera rides the centerline, aimed at the centerline further on
    // (that look-ahead is what keeps the mouth centered while the far end
    // swings). The kick surges it forward; a slow continuous roll keeps the
    // flight alive.
    float camZ = u.time * u.speed * 2.2 + 0.4 * u.beat;
    float3 ro = float3(tunnelCenter(camZ, u.p2), camZ);
    float3 ta = float3(tunnelCenter(camZ + 2.0, u.p2), camZ + 2.0);
    float rollA = u.time * 0.1 + 0.6 * sin(u.time * 0.3);
    float3 fw = normalize(ta - ro);
    float3 right = normalize(cross(fw, float3(sin(rollA), cos(rollA), 0.0)));
    float3 up = cross(right, fw);
    float3 rd = normalize(suv.x * right + suv.y * up + 1.4 * fw);

    // Sphere-trace to the wall, counting steps: grazing rays rack up
    // iterations, and that count *is* the lighting — crevices, crags and
    // silhouettes glow with no normal computation at all (the demoscene
    // trick).
    float t = 0.0;
    float3 p = ro;
    float steps = 0.0;
    for (int i = 0; i < 60; i++) {
        float d = tunnelMap(p, u, bands, wave);
        if (d < 0.0025 || t > 26.0) break;
        t += max(d * 0.8, 0.004);
        p = ro + rd * t;
        steps += 1.0;
    }

    // Recover the wall's slice of the spectrum.
    float2 xy = p.xy - tunnelCenter(p.z, u.p2);
    float fold = tunnelFold(atan2(xy.y, xy.x));
    float e = clamp(bandAt(bands, fold) * u.sensitivity, 0.0, 1.5);

    float crevice = min(0.85, steps / 42.0) + 0.06;

    // Mineral coloring: the same noise family that carved the rock steers
    // the hue on top of the bass→treble floor-to-ceiling gradient, so
    // colored strata run through the walls.
    float3 wallColor = cosPalette(0.06 + fold * 0.45 + 1.1 * fbm3(p * 0.35)
                                  + u.centroid * 0.30, u.palette);
    float3 col = wallColor * (0.35 + 3.0 * e * e) * crevice * glow;

    // ribs streaming past with the high-mids
    float segF = fract(p.z * 0.9);
    float rib = smoothstep(0.10, 0.0, min(segF, 1.0 - segF));
    col += cosPalette(0.5 + fold * 0.3, u.palette) * rib * crevice
         * (0.08 + 1.0 * clamp(u.highMid * u.sensitivity, 0.0, 1.2)) * glow;

    // glitter veins answering hi-hats and air: soft pow-shaped noise spots
    // tinted by the palette, twinkling as they stream past (hard hash cells
    // here read as flat gray confetti — never again)
    float sp = vnoise3(p * 13.0 + float3(0.0, 0.0, u.time * 0.6));
    float glit = pow(max(sp - 0.72, 0.0) * 3.5, 3.0);
    col += cosPalette(0.85 + fold * 0.3 + u.centroid * 0.2, u.palette) * glit
         * (0.5 + 0.5 * sin(u.time * 12.0 + p.z * 3.0))
         * (1.4 * u.trebleBeat + 0.8 * u.air * u.sensitivity) * 2.0;

    // every kick throws a wall of light up the tunnel toward the camera
    // (beat 1 → 0 maps far → here) — the Pulse slider scales it
    float lightZ = camZ + 1.5 + u.beat * 10.0;
    float pulseGlow = exp(-fabs(p.z - lightZ) * 0.6) * u.beat * pulse;
    col += cosPalette(0.1 + u.centroid * 0.3, u.palette) * pulseGlow * (1.5 + 1.0 * u.bass);

    // distance dissolves into palette haze pulsing with the low end (Fog
    // slider) — the far end of the cave is never a picture, just glow
    float atten = 1.0 / (1.0 + t * t * 0.010 * fogAmt);
    float3 fogColor = cosPalette(0.6 + u.centroid * 0.25 + u.time * 0.01, u.palette)
                    * (0.06 + 0.45 * u.bass * u.sensitivity + 0.20 * u.flux);
    col = col * atten + fogColor * (1.0 - atten);

    // volumetric steam (after "Sailing Beyond"): march back from the wall
    // toward the camera stacking noise, cube it, and let the mids, the
    // presence band (vocals) and onsets pump its brightness
    float f = 0.0;
    float distC = t;
    for (int i = 0; i < 16; i++) {
        float3 sp = ro + rd * distC;
        f += vnoise3(sp * 0.9 + float3(0.0, 0.0, -u.time * 0.30)) * 0.045;
        distC -= max(t * 0.06, 0.25);
        if (distC < 0.4) break;
    }
    float3 steamColor = cosPalette(0.55 + u.centroid * 0.3 + u.time * 0.008, u.palette);
    col += steamColor * pow(fabs(f * 1.5), 3.0)
         * (0.35 + 1.6 * clamp(u.mid * u.sensitivity, 0.0, 1.0)
            + 1.0 * clamp(u.presence * u.sensitivity, 0.0, 1.2) + 0.8 * u.flux);

    // the whole scene breathes with the track's loudness (the demoscene
    // audio-exposure trick, driven by our smoothed RMS level)
    col *= (0.50 + 0.85 * u.level * u.sensitivity) * (1.0 + 0.20 * u.flux) * 1.6;

    // vignette, then vibrance: push saturation while still HDR, Reinhard
    // tone map (c/(1+c)) so the additive pile-up rolls smoothly into 0...1
    // instead of clipping at white, and finish with a gentle S-curve — the
    // deepened shadows and richer primaries keep the cave from going muddy
    col *= smoothstep(4.5, 0.8, dot(suv, suv));
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = max(mix(float3(luma), col, 1.5), 0.0);
    col = col / (1.0 + col);
    col = col * col * (3.0 - 2.0 * col);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- Aurora
//
// A night-sky scene built in layers, back to front: gradient sky, a star
// field that flashes with the percussion, haze, ground fog, and up to eight
// aurora ribbons — one per instrument group, sub-bass at the bottom of the
// sky through air at the top, each with its own motion personality and each
// shaded along its length by the fine spectrum inside its own range.

// One layer of the aurora's star field: a jittered grid where ~10% of cells
// hold a star, each with its own size, tint, twinkle phase, and flash
// gates. The air band sets the ambient twinkle level; every hi-hat lights a
// different constellation and every kick a different (larger) one, so the
// sky visibly plays the drum kit.
static float3 auroraStarLayer(float2 sp, float scale, constant VizUniforms& u) {
    float2 g = sp * scale;
    float2 id = floor(g);
    float h1 = hash21(id);
    if (h1 < 0.90) { return float3(0.0); }
    float2 offs = float2(hash21(id + 7.1), hash21(id + 3.7)) - 0.5;
    float2 f = fract(g) - 0.5 - offs * 0.7;
    float d = length(f);
    float h2 = hash21(id + 11.3);
    float h3 = hash21(id + 17.9);
    float h4 = hash21(id + 23.7);
    float core = exp(-d * d * (150.0 - 90.0 * h2));
    // 4-point diffraction cross on the brightest few
    float sparkle = (exp(-fabs(f.x) * 42.0) * exp(-fabs(f.y) * 8.0)
                   + exp(-fabs(f.y) * 42.0) * exp(-fabs(f.x) * 8.0))
                  * max(h1 - 0.975, 0.0) * 40.0;
    float twinkle = 0.45 + 0.55 * sin(u.time * (2.0 + 4.0 * h3) + h3 * 40.0);
    // two independent, periodically reshuffled gates: each hi-hat lights a
    // different constellation, each kick a different (larger) one
    float gateHat = step(0.55, fract(h4 + floor(u.time * 1.5) * 0.618));
    float gateKick = step(0.45, fract(h4 * 3.7 + floor(u.time * 2.0) * 0.618));
    float amp = (0.30 + 0.70 * twinkle) * (0.30 + 0.70 * clamp(u.air * u.sensitivity, 0.0, 1.0))
              + gateHat * u.trebleBeat * 1.3
              + gateKick * u.beat * 1.2;
    float3 tint = mix(float3(1.0), cosPalette(h2, u.palette), 0.35);
    return tint * (core + sparkle) * amp * (h1 - 0.90) * 10.0;
}

fragment float4 auroraFragment(FSQuadOut in [[stage_in]],
                               constant VizUniforms& u [[buffer(0)]],
                               constant float* bands [[buffer(1)]],
                               constant float* wave [[buffer(2)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 suv = float2(uv.x * aspect, uv.y);
    float starsAmt = u.p2;

    // Night-sky gradient, tinted faintly by the palette and the spectral
    // centroid so the sky's mood follows the music's brightness.
    float3 col = mix(float3(0.008, 0.010, 0.026), float3(0.016, 0.026, 0.050), uv.y);
    col += cosPalette(0.62 + u.centroid * 0.3, u.palette) * 0.012;

    // the star field (see auroraStarLayer): three depths of sky
    float3 stars = auroraStarLayer(suv, 40.0, u)
                 + auroraStarLayer(suv + 5.3, 75.0, u) * 0.6
                 + auroraStarLayer(suv + 9.1, 140.0, u) * 0.35;
    col += stars * starsAmt * smoothstep(0.16, 0.50, uv.y);

    // drifting haze that brightens with the low end, tinted by brightness
    float haze = fbm(uv * 3.0 + float2(u.time * 0.05 * u.speed, 0.0));
    col += cosPalette(0.6 + u.centroid * 0.3 + u.time * 0.01, u.palette) * haze
         * (0.03 + 0.10 * u.bass * u.sensitivity);

    // ground fog breathing with the sub-bass
    float fog = fbm(float2(uv.x * 4.0 + u.time * 0.08 * u.speed, uv.y * 9.0));
    col += cosPalette(0.05, u.palette) * fog * smoothstep(0.30, 0.0, uv.y)
         * (0.04 + 0.30 * u.subBass * u.sensitivity);

    int layers = clamp(int(u.p0 + 0.5), 2, 8);
    float height = u.p1;

    // One ribbon per instrument group, low to high: sub-bass at the bottom
    // of the sky through air at the top. Each has its own motion
    // personality — lows are fat and slow and jump on the kick, mids carry
    // the waveform (melody and vocals) and answer onsets, highs are thin
    // and fast and shiver on hi-hats — and each is shaded along its length
    // by the fine spectrum *inside* its own frequency range, so every
    // ribbon is a small equalizer for its register.
    float comps[8] = {u.subBass, u.bass, u.lowMid, u.mid,
                      u.highMid, u.presence, u.treble, u.air};
    for (int i = 0; i < 8; i++) {
        if (i >= layers) break;
        float fi = float(i) / float(max(layers - 1, 1));
        int cIdx = int(fi * 7.0 + 0.5);
        float reg = float(cIdx) / 7.0;
        float compE = clamp(comps[cIdx] * u.sensitivity, 0.0, 1.3);
        // the fine spectrum inside this register, spread across the screen
        float localE = clamp(bandAt(bands, (float(cIdx) + clamp(uv.x, 0.0, 1.0)) / 8.0)
                           * u.sensitivity, 0.0, 1.3);
        // transient personality: lows jump on the kick, mids on onsets,
        // highs shiver on hi-hat transients
        float transient = u.beat * (1.0 - smoothstep(0.15, 0.45, reg))
                        + u.flux * exp(-pow((reg - 0.5) * 3.5, 2.0))
                        + u.trebleBeat * smoothstep(0.55, 0.85, reg);
        // mids carry the waveform; lows and highs mostly ignore it
        float wWeight = exp(-pow((reg - 0.5) * 2.4, 2.0));
        float w = waveAt(wave, fract(uv.x + fi * 0.13));
        // low ribbons undulate slowly and widely, high ribbons shiver fast
        float sway = (0.065 * (1.0 - reg) + 0.018)
                   * sin(uv.x * (4.0 + reg * 14.0)
                         + u.time * u.speed * (0.4 + 1.6 * reg) * (0.6 + fi * 0.8));
        float ripple = 0.014 * reg
                     * sin(uv.x * (30.0 + 60.0 * reg) + u.time * u.speed * (2.0 + 3.0 * reg))
                     * clamp(u.highMid * u.sensitivity, 0.0, 1.2);
        float yC = 0.5
                 + (fi - 0.5) * 0.58
                 + w * height * wWeight * (0.5 + 0.8 * compE)
                 + sway + ripple
                 + 0.04 * transient * (1.0 - 0.5 * reg);
        // thickness: fat lows, thin highs, detailed by the local spectrum,
        // puffed by this register's transients
        float thickness = (0.004 + 0.030 * compE) * (1.6 - 1.1 * reg)
                        * (0.6 + 0.9 * localE) * (1.0 + 0.5 * transient);
        // t/(|dy|+t) is a soft glow profile: 1 on the center line, falling
        // off hyperbolically; the pow sharpens its core.
        float glowR = thickness / (fabs(uv.y - yC) + thickness);
        glowR = pow(glowR, 1.6);
        // vertical curtain rays driven by the presence band
        float rays = 0.85 + 0.30 * sin(uv.x * (90.0 + fi * 20.0) + u.time * u.speed * (1.5 + fi))
                   * clamp(u.presence * u.sensitivity * 1.5, 0.0, 1.0);
        col += cosPalette(fi * 0.85 + u.centroid * 0.2 + u.time * 0.015, u.palette)
             * glowR * rays * (0.10 + 0.85 * compE + 0.30 * localE) * (1.0 + 0.45 * transient);
    }

    // beat lift + onset shimmer
    col *= 1.0 + 0.18 * u.beat + 0.10 * u.flux;

    // vibrance, Reinhard tone mapping, and a gentle S-curve — the same
    // finishing chain as the tunnel, so the ribbons saturate instead of
    // washing out
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = max(mix(float3(luma), col, 1.35), 0.0);
    col = col / (1.0 + col);
    col = col * col * (3.0 - 2.0 * col);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- Nebula
//
// Nebula is the one hybrid visualizer: this fragment shader paints the smoky
// background, then a CPU-simulated particle cloud (NebulaVisualizer.swift)
// is drawn on top with the point-sprite pipeline below, using additive
// blending so overlapping particles glow brighter.

// The nebula's three bodies: 0 = bass core, 1 = mid disc, 2 = treble halo.
// Each drifts on its own slow orbit — the heavy core lurches on kicks, the
// disc and halo counter-orbit around it, swinging wider as their register
// gets louder. The Orbit speed slider (p3) scales how fast they travel,
// Spread (p4) how far they roam — 0 collapses them back into one centered
// cloud. Mirrored on the CPU in NebulaVisualizer.orbCenter (keep the two in
// sync): the simulation places the particles here and this shader paints
// each body's background halo at the same spot.
static float3 nebulaOrbCenter(int body, constant VizUniforms& u) {
    float t = u.time * u.speed * u.p3;
    float spread = u.p4;
    if (body == 0) {
        float3 c = float3(0.20 * sin(t * 0.42), 0.10 * sin(t * 0.31 + 1.7), 0.16 * cos(t * 0.36));
        float3 lurch = float3(sin(t * 0.5), 0.3 * cos(t * 0.37), cos(t * 0.5));
        return (c + normalize(lurch) * (0.10 * u.beat)) * spread;
    }
    if (body == 1) {
        float a = t * 0.23;
        float radius = (0.45 + 0.30 * u.mid) * spread;
        return float3(cos(a), 0.22 * sin(a * 1.3), sin(a)) * radius;
    }
    float a = -t * 0.35 + 2.1;
    float radius = (0.70 + 0.45 * u.treble) * spread;
    return float3(radius * cos(a), 0.30 * sin(t * 0.55) * spread, radius * sin(a));
}

// The shared nebula camera: yaw/pitch orbit, centroid lean, kick dolly,
// perspective divide, slow roll. Returns square-space coordinates (y
// half-height 1, x before aspect correction) in xy and the perspective
// factor in z. Both the particle pass and the background pass project
// through this, so the background's halos sit exactly behind the 3D bodies.
static float3 nebulaProject(float3 world, constant VizUniforms& u) {
    float t = u.time * u.speed;
    // A non-uniform orbit around the whole cluster: the yaw speeds up and
    // slows down instead of turning at a constant rate, the pitch swings
    // from below the disc to high above it (leaned further by the spectral
    // centroid — bright music looks down, dark music up), and the distance
    // breathes in and out, so every pass frames the bodies differently.
    float yaw = t * 0.14 + 0.55 * sin(t * 0.047);
    float pitch = 0.55 * sin(t * 0.043) + 0.18 * (u.centroid - 0.5);
    float cy = cos(yaw), sy = sin(yaw);
    float cp = cos(pitch), sp = sin(pitch);
    float3x3 rotY = float3x3(float3(cy, 0.0, -sy), float3(0.0, 1.0, 0.0), float3(sy, 0.0, cy));
    float3x3 rotX = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, cp, sp), float3(0.0, -sp, cp));
    float3 pos = rotX * (rotY * world);
    // Push the scene in front of the camera, then perspective-divide:
    // farther things land closer to center and draw smaller. The kick
    // envelope pulls the camera in, punching the whole frame on the beat.
    pos.z += 3.4 + 0.7 * sin(t * 0.037) - 0.35 * u.beat;
    float persp = 1.0 / max(pos.z, 0.25);
    float2 clip = pos.xy * persp * 1.6;
    // slow two-frequency roll so the scene never feels locked upright
    clip = rot2(clip, 0.09 * sin(t * 0.05) + 0.04 * sin(t * 0.013));
    return float3(clip, persp);
}

fragment float4 nebulaBackgroundFragment(FSQuadOut in [[stage_in]],
                                         constant VizUniforms& u [[buffer(0)]],
                                         constant float* bands [[buffer(1)]],
                                         constant float* wave [[buffer(2)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    uv.x *= u.resolution.x / max(u.resolution.y, 1.0);
    float r = length(uv);

    // near-black base that slowly cycles hue instead of sitting on a fixed
    // navy, so even quiet passages drift through color
    float3 col = float3(0.004) + cosPalette(u.time * 0.006 + 0.5 * u.centroid, u.palette) * 0.014;

    // deep-space stars, twinkling harder as the air band opens up
    float stars = starLayer(uv, 40.0, u.time, 2.0) + starLayer(uv + 11.3, 80.0, u.time, 4.0) * 0.5;
    col += stars * (0.20 + 0.80 * clamp(u.air * u.sensitivity, 0.0, 1.0));

    // slow smoky nebula, breathing with the bass and lifting on any onset
    // (two fbm fields multiplied and drifting in different directions gives
    // the billowing look)
    float smoke = fbm(uv * 1.6 + float2(u.time * 0.03 * u.speed, -u.time * 0.02 * u.speed));
    smoke *= fbm(uv * 3.1 - float2(0.0, u.time * 0.04 * u.speed));
    col += cosPalette(0.15 + u.centroid * 0.3 + u.time * 0.008, u.palette) * smoke
         * (0.05 + 0.22 * u.bass * u.sensitivity + 0.08 * u.flux);

    // counter-drifting wisp layer riding the low-mids
    float wisp = fbm(rot2(uv, 0.7) * 2.2 + float2(-u.time * 0.025 * u.speed, u.time * 0.018 * u.speed));
    col += cosPalette(0.45 + u.centroid * 0.2, u.palette) * wisp * wisp
         * (0.03 + 0.18 * u.lowMid * u.sensitivity);

    // one colored halo behind each body, projected through the shared camera
    // so it tracks its orb across the screen: the bass halo strobes with the
    // kick, the mid halo breathes with onsets, the treble halo flickers with
    // hi-hats. The envelopes decay smoothly, so each strobe pulses and fades
    // rather than flashing hard, and each halo's hue drifts on its own.
    float2 orbC[3];
    for (int i = 0; i < 3; i++) {
        orbC[i] = nebulaProject(nebulaOrbCenter(i, u), u).xy;
    }
    float3 lobeGain = float3(0.30 * u.bass * u.sensitivity + 0.35 * u.beat,
                             0.25 * u.mid * u.sensitivity + 0.20 * u.flux,
                             0.20 * u.treble * u.sensitivity + 0.30 * u.trebleBeat);
    for (int i = 0; i < 3; i++) {
        float2 d = uv - orbC[i];
        float lobe = exp(-dot(d, d) * (i == 0 ? 2.2 : 3.0));
        // the Halos slider (p5) fades the washes from off to double strength
        col += cosPalette(0.08 + 0.38 * float(i) + u.time * 0.012 + u.centroid * 0.25, u.palette)
             * lobe * (0.035 + lobeGain[i]) * 0.45 * u.p5;
    }

    // soft core glow pulsing on the beat and flaring with onsets, riding
    // along with the bass orb
    float rb = length(uv - orbC[0]);
    col += cosPalette(0.5, u.palette)
         * (0.05 + 0.30 * u.beat + 0.15 * u.flux + 0.18 * u.bass * u.sensitivity)
         * smoothstep(0.9, 0.0, rb) * 0.35;

    // kick shockwave: the beat envelope decays 1 → 0, so (1 - beat) is a
    // ring radius that expands outward from the core after every kick and
    // fades as it goes — a stateless shockwave, echoing the one the CPU
    // simulation drives through the particles, erupting from the bass orb.
    float shockR = (1.0 - u.beat) * 1.5;
    float shock = exp(-pow((rb - shockR) * 8.0, 2.0)) * u.beat * u.beat;
    // the Impact slider (p6) scales the ring along with the particle wave
    col += cosPalette(0.12 + u.centroid * 0.25, u.palette) * shock * 0.45 * u.p6;

    // oscilloscope halo: the live waveform wrapped in a ring around the
    // cloud, mirrored left/right so the wrap point has no seam; overall
    // loudness fades it in.
    float theta = atan2(uv.y, uv.x) / 6.28318 + 0.5;
    float w = waveAt(wave, 1.0 - fabs(theta * 2.0 - 1.0));
    float scopeR = 0.85 + 0.30 * w * u.sensitivity;
    float scope = smoothstep(0.030, 0.0, fabs(r - scopeR));
    col += cosPalette(0.35 + u.centroid * 0.4, u.palette) * scope * (0.04 + 0.35 * u.level);

    col *= smoothstep(2.0, 0.5, r);
    return float4(col, 1.0);
}

// Mirrors NebulaVisualizer.GPUParticle in Swift; the CPU simulation writes
// this layout into a shared MTLBuffer each frame.
struct Particle {
    float4 posSize;   // xyz = position, w = point size hint
    float4 color;     // rgb, a = intensity
};

struct ParticleOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

// Projects one particle from its 3D simulation position to the screen via
// the shared nebula camera (see nebulaProject above).
vertex ParticleOut particleVertex(uint vid [[vertex_id]],
                                  constant Particle* particles [[buffer(0)]],
                                  constant VizUniforms& u [[buffer(1)]]) {
    Particle p = particles[vid];
    float3 proj = nebulaProject(p.posSize.xyz, u);
    float2 clip = proj.xy;
    clip.x *= u.resolution.y / max(u.resolution.x, 1.0);

    ParticleOut out;
    out.position = float4(clip, 0.0, 1.0);
    // point_size makes the GPU rasterize this vertex as a screen-aligned
    // square of that many pixels (a "point sprite").
    out.pointSize = clamp(p.posSize.w * proj.z * u.resolution.y * 0.012, 1.0, 90.0);
    out.color = p.color;
    return out;
}

// Shades each particle's square: point_coord is 0...1 across the sprite, and
// a Gaussian falloff from its center turns the square into a soft glowing
// dot. Rendered with additive blending, so overlaps brighten like real light.
fragment float4 particleFragment(ParticleOut in [[stage_in]],
                                 float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float a = exp(-d * d * 4.5) * smoothstep(1.0, 0.65, d);
    float3 col = in.color.rgb * a * in.color.a;
    return float4(col, a * in.color.a);
}

// Final pass for the nebula: the background and the additive particles are
// rendered into a float16 HDR texture, and this maps it to the display —
// exposure lift and vibrance while still HDR, Reinhard tone mapping, then a
// gentle S-curve. Additive particle pile-ups roll into bloom-like highlights
// instead of clipping hard at white.
fragment float4 nebulaTonemapFragment(FSQuadOut in [[stage_in]],
                                      texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    // texture rows run top-down while uv runs bottom-up, hence the flip
    float3 col = src.sample(s, float2(in.uv.x, 1.0 - in.uv.y)).rgb;
    col *= 1.35;
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = max(mix(float3(luma), col, 1.4), 0.0);
    col = col / (1.0 + col);
    col = col * col * (3.0 - 2.0 * col);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- Bars
//
// A mixing console seen from the producer's chair, drawn entirely with
// signed-distance fields in one fullscreen pass. The meter bridge stands
// vertically at the back (LED spectrum wall, two analog VU meters, a
// phosphor scope) and the desk surface recedes in perspective in front of
// it (one channel strip per slice of the spectrum: moving fader, EQ knob
// with an LED collar, channel lamp).
//
// Two conventions make the rest of this section readable:
//
//  * **Everything is measured in screen-height units.** `uv` is 0…1 on both
//    axes, so a y distance is already in height units and an x distance
//    becomes one by multiplying by the aspect ratio. Sizes written here are
//    therefore literally "fraction of the window's height", and one pixel is
//    `aa` — which is all the anti-aliasing any of these edges needs.
//  * **No audio is read directly.** Every value comes from `st`, the state
//    buffer that BarsVisualizer's CPU simulation fills each frame (column
//    ballistics, peak-hold caps, fader positions, needle angles). Meters are
//    defined by their time constants, and time constants need memory between
//    frames, which a fragment shader does not have.
//
// Layout of `st`, in floats — must match `BarsVisualizer.Slot` exactly.
constant int kBarsHeights = 0;    // 64 column heights, 0…1
constant int kBarsPeaks = 64;     // 64 peak-hold caps, 0…1
constant int kBarsFaders = 128;   // 16 fader positions, 0…1
constant int kBarsKnobs = 144;    // 16 knob values, 0…1
constant int kBarsVU = 160;       // 2 needle positions (program, peak)
constant int kBarsLamp = 162;     // console lamp brightness

// Distance to the edge of a box: negative inside, positive outside.
static float sdBox(float2 p, float2 b) {
    float2 d = fabs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Same, with rounded corners of radius r (shrink the box, then inflate the
// field — the standard SDF rounding trick).
static float sdRoundBox(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    return sdBox(p, b - r) - r;
}

// Distance to the line segment ab.
static float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    return length(pa - ba * h);
}

// Coverage of an SDF shape: 1 inside, 0 outside, `aa` of soft edge. Every
// edge in this section goes through here, which is why nothing crawls.
static float aaFill(float d, float aa) {
    return smoothstep(aa, -aa, d);
}

// Linearly interpolated waveform sample. `waveAt` snaps to whole samples,
// which is invisible in a ribbon but turns the scope's thin trace into a
// staircase of disconnected dots.
static float waveLerp(constant float* wave, float x) {
    float f = clamp(x, 0.0, 0.9999) * 255.0;
    int i = int(f);
    return mix(wave[i], wave[min(i + 1, 255)], fract(f));
}

// Brushed-aluminium panel: anisotropic grain (fine across, stretched along),
// plus a broad specular sweep standing in for a lamp somewhere in the room.
static float3 barsPanel(float2 uv, float room, constant VizUniforms& u) {
    float brush = 0.65 * vnoise(float2(uv.x * 6.0, uv.y * 520.0))
                + 0.35 * vnoise(float2(uv.x * 17.0, uv.y * 1900.0));
    float3 col = float3(0.052, 0.055, 0.064) * (0.55 + 0.9 * brush);
    float lx = 0.5 + 0.42 * sin(u.time * 0.05 * u.speed);
    col += float3(0.030, 0.032, 0.040) * exp(-pow((uv.x - lx) * 1.6, 2.0))
         * (0.35 + 0.65 * uv.y) * room;
    return col;
}

// One panel screw: dark recessed head, top-lit bevel, driver slot, glint.
static float3 barsScrew(float2 d, float aa, float room) {
    if (dot(d, d) > 0.00022) { return float3(0.0); }
    float r = length(d);
    float head = aaFill(r - 0.0080, aa);
    float ring = aaFill(r - 0.0098, aa) - head;
    float3 col = float3(0.030, 0.031, 0.035) * head;
    col += float3(0.10, 0.105, 0.115) * ring * (0.30 + 1.0 * smoothstep(-0.008, 0.008, d.y));
    col = mix(col, float3(0.018) * head, aaFill(sdBox(rot2(d, 0.7), float2(0.0062, 0.0010)), aa) * head);
    col += float3(0.30, 0.31, 0.34) * ring * exp(-pow((d.y - d.x - 0.006) * 260.0, 2.0)) * room;
    return col;
}

// One pixel of the LED ladder.
//   wx, wy  position on the wall: 0…1 across the columns, 0…1 up the ladder
//           (the reflection passes a mirrored wy, hence no upper clamp here)
//   ww, wh  the ladder's size in screen-height units, so a lens keeps its
//           shape whatever the window aspect is
static float3 barsWall(float wx, float wy, float ww, float wh,
                       int cols, int segs, float glow, float peakAmt,
                       constant float* st, constant VizUniforms& u, float aa) {
    float3 col = float3(0.0);
    if (wx < 0.0 || wx > 1.0 || wy < 0.0 || wy > 1.0) { return col; }

    float cf = wx * float(cols);
    int ci = clamp(int(cf), 0, cols - 1);
    float h = st[kBarsHeights + ci];
    float pk = st[kBarsPeaks + ci];
    float colFrac = (float(ci) + 0.5) / float(cols);

    float cw = ww / float(cols);
    float qx = (fract(cf) - 0.5) * cw;
    float halfW = cw * 0.38;
    float yh = wy * wh;      // height above the base, in screen-height units

    // Two ways to draw a column. Segmented is the LED ladder; "0 segments"
    // is one continuous bar, and it needs its own path rather than a ladder
    // of very fine segments — once a segment is thinner than the pixel that
    // anti-aliases it, the boundaries come back as banding.
    float2 q, b;      // this pixel's position within the drawn shape
    float unlitD;     // the dark lens/tube that is visible even when off
    float lit, sc, capT;
    if (segs >= 2) {
        float ch = wh / float(segs);
        float sf = wy * float(segs);
        float si = floor(sf);
        lit = clamp(h * float(segs) - si, 0.0, 1.0);
        sc = (si + 0.5) / float(segs);
        q = float2(qx, (fract(sf) - 0.5) * ch);
        b = float2(halfW, ch * 0.35);
        unlitD = sdRoundBox(q, b, 0.34 * min(b.x, b.y));
        capT = max(0.55 / float(segs), 0.006);
    } else {
        lit = 1.0;                    // coverage comes from the bar's own edge
        sc = wy;
        b = float2(halfW, max(h * wh * 0.5, 1e-5));
        q = float2(qx, yh - h * wh * 0.5);
        unlitD = sdRoundBox(float2(qx, yh - wh * 0.5), float2(halfW, wh * 0.5), halfW * 0.35);
        capT = 0.006;
    }
    float d = sdRoundBox(q, b, 0.34 * min(b.x, b.y));
    float face = aaFill(d, aa);

    // The hue ladder climbs the bar rather than running across the wall: a
    // meter is read vertically, and 0.66 → 1.0 of the cosine palette happens
    // to be exactly the green → amber → red of hardware in the default
    // palette, while every other palette gets its own cool-to-hot run. The
    // top of the scale is pushed red in *all* of them — the "over" cue is
    // universal enough on real gear to be worth breaking palette purity for.
    float3 hue = cosPalette(0.56 + 0.46 * sc + 0.05 * colFrac + 0.06 * u.centroid, u.palette);
    float3 c = mix(hue, float3(1.0, 0.13, 0.04), smoothstep(0.76, 1.0, sc) * 0.7);
    // Saturate and ramp: a lit LED is driven hard enough to wash toward white
    // through the exposure curve, so the ladder needs more colour than the
    // palette's raw value to survive the trip.
    c = max(mix(float3(dot(c, float3(0.299, 0.587, 0.114))), c, 1.4), 0.0);
    c *= 0.85 + 0.30 * sc;

    // unlit lens: dark smoked plastic that still shows the whole ladder
    float tube = aaFill(unlitD, aa);
    col += mix(c, float3(0.5), 0.65) * tube * 0.030;
    col += c * face * (0.35 + 1.6 * lit) * lit;           // the lit face
    col += c * exp(-max(d, 0.0) * (34.0 / max(glow, 0.25))) * lit * 0.55 * glow;
    // moulded highlight across the top of a lit lens
    col += mix(float3(1.0), c, 0.45) * face * lit * 0.20
         * smoothstep(-b.y, b.y, q.y) * smoothstep(b.x, 0.25 * b.x, fabs(q.x));

    // Peak-hold cap: one LED hanging at the loudest recent value, its core
    // driven white. `wy` and `pk` are both normalised, so `capT` is too — a
    // little over half a segment, which snaps it to the lens grid.
    // (`tube`, not `face`: the cap floats above the bar top, where the lit
    // face has no coverage at all in continuous mode.)
    float cap = smoothstep(capT, capT * 0.3, fabs(wy - pk)) * step(0.02, pk)
              * clamp(peakAmt, 0.0, 1.0);
    col += mix(c, float3(1.0), 0.30) * cap
         * (tube * 0.95 + exp(-max(unlitD, 0.0) * 50.0) * (1.0 - tube) * 0.5 * glow);
    return col;
}

// One lamp-lit analog VU meter, centred on `p` with ext-extents `ext`.
// `value` 0…1 sweeps the needle across the arc; `lamp` pulses the backlight.
static float3 barsVU(float3 col, float2 p, float2 ext, float value,
                     float lamp, float glow, float aa, constant VizUniforms& u) {
    if (fabs(p.x) > ext.x + 0.05 || fabs(p.y) > ext.y + 0.05) { return col; }

    float bezelD = sdRoundBox(p, ext, min(ext.x, ext.y) * 0.22);
    float faceD = sdRoundBox(p, ext - 0.011, min(ext.x, ext.y) * 0.14);
    float bezel = aaFill(bezelD, aa);
    float faceM = aaFill(faceD, aa);
    float up = smoothstep(-ext.y, ext.y, p.y);

    // machined frame with a top-lit bevel
    col = mix(col, float3(0.075, 0.078, 0.088) * (0.5 + 1.0 * up), bezel);
    col += float3(0.10, 0.105, 0.115) * smoothstep(0.0022, 0.0, fabs(bezelD)) * (0.25 + 0.9 * up);

    // The face is cream card lit by a warm lamp behind the glass. The lamp
    // takes a little of the palette so the meter belongs to the scene, but
    // half-desaturated first — at full strength the palette can land on a
    // saturated hue and the meter stops reading as a lamp-lit card at all.
    float3 tint = cosPalette(0.10 + 0.30 * u.centroid, u.palette);
    tint = mix(float3(dot(tint, float3(0.299, 0.587, 0.114))), tint, 0.5);
    float3 lampCol = mix(float3(1.0, 0.84, 0.60), tint, 0.30);
    float3 face = float3(1.05, 1.00, 0.86) * (0.55 + 0.80 * smoothstep(-ext.y * 1.5, ext.y, p.y));
    face *= mix(float3(1.0), lampCol, 0.60) * (0.80 + 0.50 * lamp);
    col = mix(col, face, faceM);

    // Scale arc, struck from a pivot below the face like the real movement.
    float2 pivot = float2(0.0, -ext.y * 1.30);
    float2 rp = p - pivot;
    float rr = length(rp);
    float ang = atan2(rp.x, rp.y);
    float R = ext.y * 1.95;
    float aMax = 0.52;
    float inArc = step(fabs(ang), aMax) * faceM;
    col = mix(col, float3(0.10, 0.09, 0.08),
              smoothstep(0.0030, 0.0, fabs(rr - R)) * inArc * 0.95);
    // the red zone above 0 VU
    col = mix(col, float3(0.80, 0.10, 0.07),
              step(0.16, ang) * inArc * smoothstep(0.0042, 0.0, fabs(rr - R * 1.015)));
    // graduations, every other one long
    float tf = (ang + aMax) / (2.0 * aMax) * 10.0;
    float ti = round(tf);
    float tickLen = mix(0.055, 0.105, step(fract(ti * 0.5), 0.25)) * R;
    float tick = smoothstep(0.0016, 0.0, fabs(tf - ti) * (2.0 * aMax / 10.0) * rr)
               * step(rr, R) * step(R - tickLen, rr) * inArc;
    col = mix(col, float3(0.08, 0.075, 0.07), tick);
    // the bold 0 VU mark where the red zone begins
    col = mix(col, float3(0.06, 0.055, 0.05),
              smoothstep(0.0030, 0.0, fabs(ang - 0.16) * rr)
              * step(R * 0.83, rr) * step(rr, R) * inArc);

    // The needle, with its shadow cast on the card just below it.
    float na = mix(-aMax * 0.97, aMax * 0.97, clamp(value, 0.0, 1.0));
    float2 dir = float2(sin(na), cos(na));
    float w = 0.0022 - 0.0012 * clamp(dot(rp, dir) / R, 0.0, 1.0);
    col = mix(col, col * 0.62,
              aaFill(sdSegment(rp - float2(0.0018, -0.0018), dir * R * 0.20, dir * R) - w, aa * 2.0)
              * faceM * 0.55);
    col = mix(col, float3(0.06, 0.05, 0.045),
              aaFill(sdSegment(rp, dir * R * 0.20, dir * R * 1.005) - w, aa) * faceM);
    col = mix(col, float3(0.13, 0.12, 0.11), aaFill(rr - ext.y * 0.09, aa) * faceM);

    // glass: one diagonal reflection band, then a soft edge vignette
    col += float3(0.85, 0.90, 1.0) * faceM
         * exp(-pow((p.x * 0.7 + p.y * 1.5 - ext.y * 0.35) * 6.0, 2.0)) * 0.07;
    col *= 1.0 - 0.22 * faceM * smoothstep(0.45, 1.0, length(p / ext));
    // the lamp spilling out onto the panel around the bezel
    col += lampCol * exp(-max(bezelD, 0.0) * 26.0) * (0.03 + 0.05 * lamp) * glow;
    return col;
}

// The phosphor scope between the meters: the live waveform on a curved CRT.
static float3 barsScope(float3 col, float2 p, float2 ext, float glow, float aa,
                        constant float* wave, constant VizUniforms& u) {
    if (fabs(p.x) > ext.x + 0.04 || fabs(p.y) > ext.y + 0.04) { return col; }

    float bezelD = sdRoundBox(p, ext, 0.012);
    float faceD = sdRoundBox(p, ext - 0.009, 0.010);
    float bezel = aaFill(bezelD, aa);
    float faceM = aaFill(faceD, aa);
    col = mix(col, float3(0.060, 0.063, 0.072) * (0.5 + 1.0 * smoothstep(-ext.y, ext.y, p.y)), bezel);
    col += float3(0.09) * smoothstep(0.0022, 0.0, fabs(bezelD));

    // Barrel distortion, so the tube reads as glass rather than a flat rect.
    float2 q = p / (ext - 0.009);
    q *= 1.0 + 0.055 * dot(q, q);
    if (max(fabs(q.x), fabs(q.y)) > 1.0) { return col; }
    float3 screen = float3(0.012, 0.020, 0.017) * (1.0 - 0.45 * dot(q, q));

    // graticule
    float2 g = q * float2(6.0, 3.0);
    float2 gd = fabs(g - round(g)) / float2(6.0, 3.0);
    screen += float3(0.06, 0.10, 0.08) * smoothstep(0.006, 0.0, min(gd.x, gd.y));

    // The trace: nearest distance to a few samples either side, so steep
    // slopes stay a connected line instead of breaking into dots.
    float gain = 0.72 * clamp(u.sensitivity, 0.2, 2.0);
    float tx = q.x * 0.5 + 0.5;
    float best = 1e3;
    for (int k = -3; k <= 3; k++) {
        float xs = tx + float(k) * 0.0055;
        float ys = waveLerp(wave, xs) * gain;
        best = min(best, length(float2((xs - tx) * 2.0, q.y - ys)));
    }
    float3 phosphor = mix(cosPalette(0.42 + 0.25 * u.centroid, u.palette),
                          float3(0.55, 1.0, 0.70), 0.45);
    screen += phosphor * (pow(0.035 / (best + 0.035), 2.6) * 1.5 + 0.13 / (best * 6.0 + 0.13) * glow);

    // scanlines and a slow bright band rolling up the tube
    screen *= 0.85 + 0.15 * sin(q.y * 190.0);
    screen *= 1.0 + 0.10 * exp(-pow((q.y - fract(u.time * 0.11 * u.speed) * 2.4 + 1.2) * 3.0, 2.0));
    col = mix(col, screen, faceM);
    col += float3(0.8, 0.9, 1.0) * faceM
         * exp(-pow((q.x * 0.6 + q.y * 1.1 - 0.55) * 2.6, 2.0)) * 0.030;
    return col;
}

// The desk surface, in its own world coordinates: X across (-0.5…0.5 spans
// the desk), Z into the screen (0 at the front edge, 0.45 at the meter
// bridge). `aaX`/`aaZ` are one pixel measured in those units — they grow
// toward the back, which is exactly the blur the foreshortening needs.
static float3 barsDesk(float3 col, float X, float Z, float aaX, float aaZ,
                       int chans, int cols, float glow, float room,
                       constant float* st, constant VizUniforms& u) {
    float aa = max(aaX, aaZ);
    float edge = sdBox(float2(X, Z - 0.225), float2(0.5, 0.225));
    if (edge > 0.012) {
        // Off the desk: studio floor, lit by nothing but what the meter wall
        // throws down onto it, with the desk's shadow pooling along its edge.
        float3 floorCol = col * 0.5
                        + float3(0.017, 0.018, 0.022) * (0.5 + 0.9 * vnoise(float2(X * 16.0, Z * 44.0)));
        floorCol += cosPalette(0.60 + 0.16 * u.centroid, u.palette)
                  * exp(-(0.45 - Z) * 5.0) * 0.055 * glow;
        return floorCol * mix(1.0, 0.30, smoothstep(0.20, 0.0, edge));
    }

    float3 surface = float3(0.070, 0.073, 0.084);
    surface *= 0.82 + 0.36 * vnoise(float2(X * 70.0, Z * 300.0));
    surface += float3(0.030, 0.031, 0.038) * smoothstep(0.10, 0.45, Z) * room;
    surface *= 1.0 - 0.50 * smoothstep(0.39, 0.45, Z);          // bridge shadow
    // the armrest trim along the front edge, catching the room light
    surface = mix(float3(0.115, 0.105, 0.092), surface, smoothstep(0.014, 0.034, Z));
    col = mix(col, surface, aaFill(edge, aa));
    col += float3(0.12) * smoothstep(0.0018, 0.0, fabs(edge)) * room;

    float sw = 1.0 / float(chans);
    float sf = (X + 0.5) / sw;
    int ci = clamp(int(sf), 0, chans - 1);
    float lx = (fract(sf) - 0.5) * sw;
    float fader = st[kBarsFaders + ci];
    float knob = st[kBarsKnobs + ci];
    float3 accent = cosPalette(0.12 + 0.52 * ((float(ci) + 0.5) / float(chans))
                               + 0.16 * u.centroid, u.palette);

    // engraved separator between strips
    float bnd = fabs(fabs(lx) - sw * 0.5);
    col *= 1.0 - 0.55 * smoothstep(0.0040, 0.0, bnd);
    col += float3(0.05, 0.052, 0.060) * smoothstep(0.0018, 0.0, fabs(bnd - 0.0042)) * room;

    // Fader slot, its printed travel scale, and the moving cap.
    float slotW = min(sw * 0.11, 0.013);
    float2 fq = float2(lx, Z - 0.175);
    float slotD = sdRoundBox(fq, float2(slotW, 0.115), slotW);
    col = mix(col, float3(0.008, 0.008, 0.010), aaFill(slotD, aa));
    col += float3(0.06) * smoothstep(0.0014, 0.0, fabs(slotD)) * room;
    float tickZ = fabs(fract((Z - 0.062) / 0.0440) - 0.5) * 0.0440;
    col += float3(0.10, 0.102, 0.11)
         * smoothstep(0.0016, 0.0, tickZ)
         * smoothstep(0.0040, 0.0, fabs(fabs(lx) - slotW - 0.008))
         * step(0.055, Z) * step(Z, 0.292) * room;

    float capZ = 0.070 + clamp(fader, 0.0, 1.0) * 0.205;
    float2 cq = float2(lx, Z - capZ);
    float capW = min(sw * 0.34, 0.040);
    float capD = sdRoundBox(cq, float2(capW, 0.0165), 0.006);
    float capM = aaFill(capD, aa);
    col *= 1.0 - 0.6 * aaFill(sdRoundBox(cq + float2(0.0, 0.008), float2(capW, 0.020), 0.008),
                              aa * 2.5) * (1.0 - capM);
    // The cap is a moulded plastic block: bright on the face turned toward
    // the viewer, falling into shadow along its far edge.
    float3 capCol = float3(0.26, 0.265, 0.285) * (0.35 + 1.05 * smoothstep(0.020, -0.014, cq.y));
    capCol *= 0.86 + 0.28 * vnoise(float2(lx * 420.0, 0.0));    // moulded ribs
    col = mix(col, capCol, capM);
    col += float3(0.16) * smoothstep(0.0022, 0.0, fabs(capD))
         * smoothstep(-0.004, 0.012, cq.y) * room;              // lit top edge
    float capLine = aaFill(sdRoundBox(cq, float2(capW * 0.86, 0.0022), 0.0018), aa);
    col += accent * capLine * (0.25 + 1.7 * fader) * glow;
    // spill onto the desk *around* the cap — inside is moulded plastic, and
    // exp(-max(d,0)) is 1 everywhere inside a shape, which would flood it
    col += accent * exp(-max(capD, 0.0) * 110.0) * (1.0 - capM) * (0.06 + 0.45 * fader) * glow;

    // EQ knob: dished cap, pointer, and an LED collar that fills as it turns.
    float kr = min(sw * 0.30, 0.028);
    float2 kq = float2(lx, Z - 0.378);
    float kd = length(kq) - kr;
    float km = aaFill(kd, aa);
    float3 knobCol = float3(0.155, 0.160, 0.178) * (0.45 + 1.00 * smoothstep(-kr, kr, kq.y));
    knobCol *= 1.0 - 0.30 * smoothstep(kr * 0.45, kr, length(kq));
    col = mix(col, knobCol, km);
    col += float3(0.11) * smoothstep(0.0016, 0.0, fabs(kd)) * room;
    float ka = mix(-2.35, 2.35, clamp(knob, 0.0, 1.0));
    float2 kdir = float2(sin(ka), cos(ka));
    col = mix(col, float3(0.85, 0.87, 0.92),
              aaFill(sdSegment(kq, kdir * kr * 0.20, kdir * kr * 0.82) - kr * 0.10, aa) * km);
    float collar = smoothstep(0.0030 + aa, 0.0, fabs(length(kq) - kr * 1.22))
                 * step(fabs(atan2(kq.x, kq.y)), 2.35)
                 * step(atan2(kq.x, kq.y), ka);
    col += accent * collar * (0.20 + 1.3 * knob) * glow;

    // channel lamp, between the knob and the head of the fader slot
    float2 bq = float2(lx, Z - 0.315);
    float bd = sdRoundBox(bq, float2(min(sw * 0.26, 0.028), 0.0085), 0.004);
    float bm = aaFill(bd, aa);
    col = mix(col, float3(0.055, 0.057, 0.064), bm);
    col += accent * (bm + exp(-max(bd, 0.0) * 130.0) * 0.4)
         * (0.05 + 1.1 * smoothstep(0.10, 0.75, fader)) * glow;

    // The meter wall spills its colour down onto the back of the desk.
    int wc = clamp(int((X + 0.5) * float(cols)), 0, cols - 1);
    float3 spill = cosPalette(0.05 + 0.48 * ((float(wc) + 0.5) / float(cols))
                              + 0.12 + 0.16 * u.centroid, u.palette);
    col += spill * st[kBarsHeights + wc] * exp(-(0.45 - Z) * 7.0) * 0.30 * glow;
    return col;
}

// (No `bands` at buffer(1): the columns arrive pre-aggregated and shaped in
// `st`. The waveform stays at buffer(2) so that index means the same thing
// here as in every other visualizer.)
fragment float4 barsFragment(FSQuadOut in [[stage_in]],
                             constant VizUniforms& u [[buffer(0)]],
                             constant float* wave [[buffer(2)]],
                             constant float* st [[buffer(3)]]) {
    float2 uv = in.uv;
    float A = u.resolution.x / max(u.resolution.y, 1.0);
    float aa = 1.4 / max(u.resolution.y, 1.0);

    int cols = clamp(int(u.p0 + 0.5), 8, 64);
    int segs = int(u.p1 + 0.5);
    float peakAmt = u.p2;
    float glow = u.p3;
    float deskAmt = clamp(u.p4, 0.0, 1.0);
    int chans = clamp(int(u.p5 + 0.5), 4, 16);
    float meters = clamp(u.p6, 0.0, 2.0);
    float room = clamp(u.p7, 0.0, 2.0);
    float lamp = st[kBarsLamp];

    // Vertical layout, bottom to top: desk, gloss shelf (which catches the
    // wall's reflection), LED ladder, meter bay. The two sliders that hide a
    // section give its space back to the ladder rather than leaving a hole.
    float bayH = 0.165 * min(meters, 1.0);
    float bayHi = 0.986;
    float bayLo = bayHi - bayH;
    bool hasDesk = deskAmt > 0.03;
    float horizon = 0.015 + 0.50 * deskAmt;
    float panelLo = hasDesk ? horizon : 0.010;
    float shelfHi = panelLo + 0.050;
    float wallLo = shelfHi;
    float wallHi = bayLo - (bayH > 0.001 ? 0.014 : 0.0);
    float ladderHi = wallHi - 0.026;   // the strip above holds the over-lamps

    // the room the console sits in
    float3 col = float3(0.008, 0.008, 0.011);
    col += cosPalette(0.55 + 0.25 * u.centroid, u.palette) * 0.012 * (0.35 + 0.65 * uv.y) * room;

    if (hasDesk && uv.y < horizon) {
        // Floor projection: a fixed world width appears `dy` wide on screen,
        // so world x is (screen x)/dy and world depth is 1/dy. `e` stops the
        // far edge at a finite distance — it is what sets how hard the desk
        // converges (here, the back edge is 46% of the near edge's width).
        float conv = 0.46;
        float e = conv * horizon / (1.0 - conv);
        float dyB = horizon + e;
        float dy = horizon - uv.y + e;
        float X = (uv.x - 0.5) * dyB / dy;
        float Z = 0.45 * (1.0 / dy - 1.0 / dyB) / (1.0 / e - 1.0 / dyB);
        // One pixel in world units, differentiated analytically (fwidth would
        // be undefined in the quads that straddle the horizon).
        float aaX = 1.4 * (dyB / dy) / max(u.resolution.x, 1.0);
        float aaZ = 1.4 * 0.45 / (dy * dy * (1.0 / e - 1.0 / dyB)) / max(u.resolution.y, 1.0);
        col = barsDesk(col, X, Z, aaX, aaZ, chans, cols, glow, room, st, u);
    } else {
        // ---- the meter bridge ----
        float2 pc = float2((uv.x - 0.5) * A, uv.y - (panelLo + bayHi) * 0.5);
        float2 ph = float2(0.492 * A, (bayHi - panelLo) * 0.5);
        float panelD = sdRoundBox(pc, ph, 0.014);
        float panel = aaFill(panelD, aa);
        col = mix(col, barsPanel(uv, room, u), panel);
        col += float3(0.075, 0.078, 0.088) * smoothstep(0.0030, 0.0, fabs(panelD))
             * (0.30 + 0.70 * smoothstep(panelLo, bayHi, uv.y));

        // The ladder sits in a smoked recess; the bevel is dark along the top
        // inside edge and bright along the bottom, which is what reads as
        // "cut into the panel" rather than "printed on it".
        float2 wc = float2((uv.x - 0.5) * A, uv.y - (wallLo + wallHi) * 0.5);
        float2 wh2 = float2(0.470 * A, (wallHi - wallLo) * 0.5);
        float windowD = sdRoundBox(wc, wh2, 0.008);
        float window = aaFill(windowD, aa);
        col = mix(col, float3(0.014, 0.015, 0.019), window);
        col += mix(float3(0.075), float3(0.012), smoothstep(-0.5, 0.5, wc.y / max(wh2.y, 1e-4)))
             * smoothstep(0.0035, 0.0, fabs(windowD)) * window;

        float ladderX0 = 0.045, ladderX1 = 0.955;
        float wx = (uv.x - ladderX0) / (ladderX1 - ladderX0);
        float ww = (ladderX1 - ladderX0) * A;
        // The ladder stops just short of the recess floor. That sliver of
        // sill is what separates the bars from their reflection below —
        // without it the two run together into one continuous bar.
        float ladderLo = wallLo + 0.011;
        float wh = ladderHi - ladderLo;

        // printed dB scale: engraved rules behind the columns, matching ticks
        // in the margins outside the recess
        float scaleY = (uv.y - ladderLo) / max(wh, 1e-4);
        float rule = smoothstep(0.0016, 0.0, fabs(fract(scaleY * 5.0 + 0.5) - 0.5) / 5.0);
        float overLine = smoothstep(0.0022, 0.0, fabs(scaleY - 0.86));
        if (scaleY > 0.0 && scaleY < 1.0) {
            float gapMask = 1.0 - step(fabs(fract(wx * float(cols)) - 0.5) * 2.0, 0.80);
            col += float3(0.055, 0.058, 0.066) * rule * gapMask * step(0.0, wx) * step(wx, 1.0);
            col += float3(0.25, 0.05, 0.03) * overLine * gapMask * step(0.0, wx) * step(wx, 1.0);
            float margin = step(uv.x, ladderX0 - 0.004) + step(ladderX1 + 0.004, uv.x);
            col += float3(0.12, 0.125, 0.14) * (rule + overLine) * margin * (1.0 - window) * room;
        }

        col += barsWall(wx, scaleY, ww, wh, cols, segs, glow, peakAmt, st, u, aa);

        // Over-lamps: one tiny red LED per column, latched by the peak cap.
        if (uv.y > ladderHi + 0.004 && uv.y < wallHi - 0.004 && wx > 0.0 && wx < 1.0) {
            float lampX = fract(wx * float(cols)) - 0.5;
            int lc = clamp(int(wx * float(cols)), 0, cols - 1);
            float over = smoothstep(0.94, 1.0, st[kBarsPeaks + lc]);
            float2 lq = float2(lampX * ww / float(cols), uv.y - (ladderHi + wallHi) * 0.5);
            float ld = length(lq) - min(0.0055, ww / float(cols) * 0.22);
            float lm = aaFill(ld, aa);
            col += float3(0.30, 0.03, 0.02) * lm * 0.25;
            col += float3(1.0, 0.12, 0.06) * over
                 * (lm * 1.6 + exp(-max(ld, 0.0) * 90.0) * 0.8 * glow);
        }

        // Gloss shelf: the ladder reflected in the polished sill below it.
        if (uv.y < shelfHi && uv.y > panelLo) {
            float below = shelfHi - uv.y;
            col *= 0.30;
            col += barsWall(wx, (below + 0.011) / max(wh, 1e-4), ww, wh, cols, segs,
                            glow, 0.0, st, u, aa * 3.0)
                 * 0.26 * exp(-below * 30.0);
            col += float3(0.05) * smoothstep(0.0022, 0.0, fabs(uv.y - shelfHi));
        }

        // ---- the meter bay ----
        if (bayH > 0.001 && uv.y > bayLo - 0.02) {
            float cy = (bayLo + bayHi) * 0.5;
            float vuHy = bayH * 0.44;
            float vuHx = vuHy * 1.45;
            float vuHxUV = vuHx / A;
            float cxL = 0.028 + vuHxUV;
            float cxR = 0.972 - vuHxUV;
            float gain = min(meters, 1.6);
            col = barsVU(col, float2((uv.x - cxL) * A, uv.y - cy), float2(vuHx, vuHy),
                         st[kBarsVU], lamp, glow * gain, aa, u);
            col = barsVU(col, float2((uv.x - cxR) * A, uv.y - cy), float2(vuHx, vuHy),
                         st[kBarsVU + 1], lamp, glow * gain, aa, u);
            // The scope keeps a tube-like aspect instead of stretching to
            // fill; whatever is left over stays panel.
            float freeHx = max((cxR - cxL) * 0.5 * A - vuHx - 0.045, 0.02);
            float scopeHx = min(freeHx, vuHy * 4.6);
            col = barsScope(col, float2((uv.x - 0.5) * A, uv.y - cy),
                            float2(scopeHx, vuHy * 0.94), glow * gain, aa, wave, u);

            // Between scope and meters, a cluster of eight indicator LEDs —
            // one per named band, sub-bass on the left through air on the
            // right, mirrored on both sides of the bay.
            float comps[8] = {u.subBass, u.bass, u.lowMid, u.mid,
                              u.highMid, u.presence, u.treble, u.air};
            float clusterX = (scopeHx + freeHx) * 0.5;
            for (int i = 0; i < 8; i++) {
                float2 lp = float2(fabs((uv.x - 0.5) * A) - clusterX,
                                   uv.y - cy - (float(i / 4) - 0.5) * 0.026);
                lp.x -= (float(i % 4) - 1.5) * 0.020;
                float ld = length(lp) - 0.0042;
                float lm = aaFill(ld, aa);
                float e = clamp(comps[i] * u.sensitivity * 1.6, 0.0, 1.0);
                float3 lc = cosPalette(0.66 + 0.30 * float(i) / 7.0, u.palette);
                col += lc * (lm * (0.05 + 1.5 * e)
                             + exp(-max(ld, 0.0) * 220.0) * e * 0.5 * glow) * gain;
                col += float3(0.05) * smoothstep(0.0016, 0.0, fabs(ld + 0.0016)) * room;
            }
        }

        // fixings, on the metal only
        float pin = 1.0 - window;
        float sy0 = panelLo + 0.020, sy1 = bayHi - 0.020;
        col += barsScrew(float2((uv.x - 0.016) * A, uv.y - sy0), aa, room) * pin;
        col += barsScrew(float2((uv.x - 0.984) * A, uv.y - sy0), aa, room) * pin;
        col += barsScrew(float2((uv.x - 0.016) * A, uv.y - sy1), aa, room) * pin;
        col += barsScrew(float2((uv.x - 0.984) * A, uv.y - sy1), aa, room) * pin;
    }

    // Room light: the lamp over the desk lifts with the kick, and the whole
    // frame falls off toward the corners.
    col *= 1.0 + 0.14 * lamp * room;
    col *= 1.0 - 0.40 * room
         * smoothstep(0.55, 1.45, length(float2((uv.x - 0.5) * 1.9, (uv.y - 0.5) * 1.25)));
    // Film grain, reshuffled 12×/second rather than every frame: at display
    // rate this reads as static rather than grain, and it is the one thing
    // here that would flicker on a 120 Hz panel.
    col += (hash21(uv * 640.0 + floor(u.time * 12.0)) - 0.5) * 0.009 * room;

    // Vibrance, then an exposure curve rather than the Reinhard + S-curve the
    // other visualizers finish with: this frame is lit *hardware*, not an
    // additive glow, and the S-curve's midtone crush would swallow the panel
    // detail. 1 - exp(-x) leaves the dark end nearly untouched and rolls the
    // LED pile-ups smoothly into white.
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = max(mix(float3(luma), col, 1.22), 0.0);
    col = 1.0 - exp(-col * 1.18);
    return float4(col, 1.0);
}
