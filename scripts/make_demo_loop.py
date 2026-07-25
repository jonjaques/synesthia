#!/usr/bin/env python3
"""Synthesize `Synesthia/Resources/DemoLoop.m4a` — the royalty-free clip behind
the app's zero-permission "See a demo" path.

The track is generated rather than licensed on purpose: bundling third-party
audio in an App Store submission means proving the rights to it, and this
sidesteps that entirely. It is also tuned for the job — the arrangement
deliberately keeps energy in every band the analyzer reports (sub-bass kick,
mid pad, treble arp/hats), so all three visualizers have something to react to.

Deterministic: same output every run, so the bundled file is reproducible.

    python3 scripts/make_demo_loop.py

Requires only the standard library plus `afconvert` (ships with macOS).
"""
import array
import math
import os
import random
import subprocess
import struct
import tempfile
import wave

SAMPLE_RATE = 44100
BPM = 120.0
BEAT = 60.0 / BPM          # 0.5 s
BAR = BEAT * 4             # 2.0 s
BARS = 16
DURATION = BAR * BARS      # 32 s
N = int(DURATION * SAMPLE_RATE)

rng = random.Random(20260725)

# Master buffer, mono; stereo width is added at the very end.
master = [0.0] * N


def add(buf, start, gain=1.0):
    """Mix `buf` into the master at sample offset `start`, wrapping past the
    end back to the beginning so the result is a seamless loop."""
    for i, v in enumerate(buf):
        master[(start + i) % N] += v * gain


def env_exp(n, rate):
    return [math.exp(-rate * i / SAMPLE_RATE) for i in range(n)]


def kick(dur=0.36):
    """Sine with a fast downward pitch sweep — the classic synthesized kick."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    phase = 0.0
    for i in range(n):
        t = i / SAMPLE_RATE
        freq = 45.0 + 115.0 * math.exp(-t * 38.0)
        phase += 2.0 * math.pi * freq / SAMPLE_RATE
        amp = math.exp(-t * 6.5)
        out[i] = math.sin(phase) * amp
    return out


def snare(dur=0.30):
    """Noise body (high-passed) plus a short tonal thwack."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    prev_x = prev_y = 0.0
    phase = 0.0
    for i in range(n):
        t = i / SAMPLE_RATE
        x = rng.uniform(-1.0, 1.0)
        # One-pole high-pass, so the noise reads as a snare rather than a rumble.
        y = 0.85 * (prev_y + x - prev_x)
        prev_x, prev_y = x, y
        phase += 2.0 * math.pi * 190.0 / SAMPLE_RATE
        out[i] = y * math.exp(-t * 17.0) * 0.8 + math.sin(phase) * math.exp(-t * 24.0) * 0.35
    return out


def hat(dur=0.07, decay=75.0):
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    prev_x = prev_y = 0.0
    for i in range(n):
        t = i / SAMPLE_RATE
        x = rng.uniform(-1.0, 1.0)
        # Two high-pass stages: brighter still, so it lands in the "air" band.
        y = 0.96 * (prev_y + x - prev_x)
        prev_x, prev_y = x, y
        out[i] = y * math.exp(-t * decay)
    return out


def bass(freq, dur):
    """Odd-harmonic stack with a decaying brightness — a plucky synth bass."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    harmonics = [(1, 1.0), (2, 0.5), (3, 0.33), (4, 0.18), (5, 0.10)]
    for i in range(n):
        t = i / SAMPLE_RATE
        # Attack ramp avoids a click; the exponential tail keeps notes distinct.
        amp = min(1.0, t / 0.006) * (0.25 + 0.75 * math.exp(-t * 4.0))
        # Higher harmonics fade faster, imitating a lowpass sweeping down.
        bright = math.exp(-t * 7.0)
        s = 0.0
        for h, hamp in harmonics:
            if freq * h > SAMPLE_RATE / 2.5:
                break
            s += math.sin(2.0 * math.pi * freq * h * t) * hamp * (1.0 if h == 1 else bright)
        out[i] = math.tanh(s * 0.6) * amp
    return out


def pad(freqs, dur):
    """Slow-attack detuned stack — the sustained mid-band bed."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    voices = []
    for f in freqs:
        for detune in (-0.004, 0.0, 0.005):
            voices.append(f * (1.0 + detune))
    attack = 0.5
    release = 0.6
    for i in range(n):
        t = i / SAMPLE_RATE
        a = min(1.0, t / attack)
        r = min(1.0, (dur - t) / release)
        amp = a * max(0.0, r)
        s = 0.0
        for f in voices:
            # Three harmonics is enough body without turning to mush.
            s += (math.sin(2.0 * math.pi * f * t)
                  + 0.35 * math.sin(2.0 * math.pi * f * 2 * t)
                  + 0.16 * math.sin(2.0 * math.pi * f * 3 * t))
        out[i] = s / len(voices) * amp
    return out


def arp(freq, dur=0.22):
    """Bright short pluck — carries the treble/presence content."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    for i in range(n):
        t = i / SAMPLE_RATE
        amp = min(1.0, t / 0.003) * math.exp(-t * 13.0)
        s = (math.sin(2.0 * math.pi * freq * t)
             + 0.5 * math.sin(2.0 * math.pi * freq * 2 * t) * math.exp(-t * 18.0)
             + 0.28 * math.sin(2.0 * math.pi * freq * 3 * t) * math.exp(-t * 24.0)
             + 0.14 * math.sin(2.0 * math.pi * freq * 5 * t) * math.exp(-t * 30.0))
        out[i] = s * amp * 0.5
    return out


# --- Arrangement -----------------------------------------------------------
# Am - F - C - G, two bars each, so the four-chord cycle runs twice over 16 bars.
PROGRESSION = [
    (110.00, [220.00, 261.63, 329.63]),   # Am
    (87.31, [174.61, 220.00, 261.63]),    # F
    (130.81, [261.63, 329.63, 392.00]),   # C
    (98.00, [196.00, 246.94, 293.66]),    # G
]


def sample_at(beat_index):
    return int(beat_index * BEAT * SAMPLE_RATE)


def build():
    kick_hit = kick()
    snare_hit = snare()

    for bar in range(BARS):
        root, chord = PROGRESSION[(bar // 2) % len(PROGRESSION)]
        b0 = bar * 4  # beat index at the start of this bar

        # Pad: one sustained chord per bar.
        add(pad(chord, BAR), sample_at(b0), 0.16)

        # Kick on 1 and 3, with a pickup on the "and" of 4 every other bar.
        add(kick_hit, sample_at(b0 + 0), 0.95)
        add(kick_hit, sample_at(b0 + 2), 0.95)
        if bar % 2 == 1:
            add(kick_hit, sample_at(b0 + 3.5), 0.55)

        # Snare on 2 and 4.
        add(snare_hit, sample_at(b0 + 1), 0.5)
        add(snare_hit, sample_at(b0 + 3), 0.5)

        # Hats on 8ths, accented on the beat, with 16th flourishes at bar ends.
        for eighth in range(8):
            pos = b0 + eighth * 0.5
            accent = 0.30 if eighth % 2 == 0 else 0.16
            add(hat(), sample_at(pos), accent)
        if bar % 4 == 3:
            for sixteenth in range(4):
                add(hat(dur=0.05, decay=95.0), sample_at(b0 + 3 + sixteenth * 0.25), 0.14)

        # Bass: root on 1, octave-ish movement through the bar.
        add(bass(root, BEAT * 1.5), sample_at(b0 + 0), 0.5)
        add(bass(root, BEAT * 0.5), sample_at(b0 + 1.5), 0.35)
        add(bass(root * 1.5, BEAT * 0.5), sample_at(b0 + 2.5), 0.30)
        add(bass(root, BEAT), sample_at(b0 + 3), 0.40)

        # Arp enters in the second half of each 8-bar phrase, so the loop has
        # somewhere to go instead of being flat for 32 seconds.
        if bar % 8 >= 4:
            pattern = [0, 1, 2, 1, 2, 0, 1, 2]
            for sixteenth, degree in enumerate(pattern):
                note = chord[degree] * 2.0
                add(arp(note), sample_at(b0 + sixteenth * 0.5), 0.22)


def normalize_and_write(path):
    peak = max(abs(v) for v in master)
    # Drive into the soft-clipper rather than hard-normalizing: hard-normalizing
    # would let one stray transient set the level for the whole track and leave
    # the result too quiet to move the analyzer at default sensitivity. tanh
    # keeps the peaks bounded while lifting the body of the mix.
    scale = 1.35 / peak if peak > 0 else 1.0
    frames = array.array("h")
    for i, v in enumerate(master):
        s = math.tanh(v * scale * 1.1)
        # Cheap Haas-style width: the right channel lags a few samples.
        r = math.tanh(master[(i - 220) % N] * scale * 1.1)
        frames.append(int(max(-1.0, min(1.0, s)) * 32000))
        frames.append(int(max(-1.0, min(1.0, r)) * 32000))
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(frames.tobytes())


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(here, "Synesthia", "Resources")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "DemoLoop.m4a")

    print(f"synthesizing {DURATION:.0f}s at {BPM:.0f} BPM…")
    build()
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    normalize_and_write(wav_path)
    print(f"wav: {os.path.getsize(wav_path) / 1e6:.1f} MB → encoding AAC…")
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", wav_path, out],
        check=True,
    )
    os.unlink(wav_path)
    print(f"wrote {out} ({os.path.getsize(out) / 1e3:.0f} KB)")


if __name__ == "__main__":
    main()
