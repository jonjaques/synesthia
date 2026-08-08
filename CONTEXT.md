# Synesthia

A macOS music visualizer: it takes sound from one of several places, analyzes it, and draws
it. The language below is the language the code, the docs and the UI should all use — where
they currently disagree, this file is what they should be corrected to.

## Language

### Audio intake

**Source**:
A place audio can come from, as the app drives it — start it, stop it, ask whether it is
running, hear about it dying on its own. There are four; exactly one is active at a time.
_Avoid_: engine, capture, feed, input, backend

**Source Kind**:
Which of the four Sources is selected. The one the user picks in the source menu.
_Avoid_: source type, mode

**Selectable**:
The Source Kinds the picker offers. The Demo Track is deliberately not one of them.

**Demo Track**:
The bundled loop the app plays itself. It is a full Source — just not a Selectable one,
because nobody would choose it over their own music. It reaches the user through the welcome
sheet and the Help menu instead, and it is the only Source that needs no Permission at all.
_Avoid_: sample track, built-in track, fallback

**Live**:
Audio is currently flowing into the Analyzer from the active Source. True whether the app is
playing the sound itself (Demo Track, audio file) or listening to sound someone else is
making (system audio, audio input).
_Avoid_: capturing, capture active, recording, running (at app level — see Source)

**Analyzer**:
The single funnel every Source ends in. Runs the FFT and publishes Snapshots. The only object
shared across threads.
_Avoid_: DSP, processor, engine

**Snapshot**:
One frame of analyzed audio, as an immutable value copy. Consumers come and get the latest
one; nothing is ever pushed at them.
_Avoid_: frame, sample, audio data, buffer

**Band**:
One slice of the spectrum in a Snapshot's fine-grained array.

**Component**:
One of the named registers (sub-bass, low-mid, presence, air, …) a Snapshot summarizes.
Coarser than a Band and named, so a Visualizer can ask for "air" rather than a range.

**Envelope**:
A transient feature that decays smoothly between hits — so a high value means "loud-ish",
not "a hit landed this frame". The rising edge of an Envelope is a **Hit**.
_Avoid_: peak, transient (for the value itself)

**Loudness Normalization**:
The slow auto-gain that adapts the Analyzer's dB mapping to how loud the current Source
happens to be, so a quiet microphone and loud mastered music both land in a useful visual
range without retuning Sensitivity.
_Avoid_: AGC, auto-gain, leveling

### Rendering

**Visualizer**:
A live GPU object that draws one frame when asked. Only the selected one exists; switching
tears the old one down.
_Avoid_: effect, scene, mode, renderer

**Descriptor**:
The static value that describes a Visualizer — its identity, its user-facing name and
tagline, its Options, and how to build it. Descriptors exist even when their Visualizer does
not.
_Avoid_: metadata, config, spec

**Registry**:
The list of Descriptors the app offers, in menu order. The extension point for a Visualizer
that isn't built in.

**Option**:
One user-tunable control a Descriptor declares. An on/off Option is not a separate kind of
thing — it is an Option whose value is 0 or 1.
_Avoid_: parameter (that is the shader side — see Slot), setting, knob, control

**Slot**:
Which of the shader's fixed parameter positions an Option's value lands in. The one contract
that is written on both the Swift and the shader side and must agree.
_Avoid_: index, parameter index, p-value

**Tuning**:
A user's values for one Visualizer — palette, sensitivity, speed, and its Options. Nothing is
shared between Visualizers; switching restores that Visualizer's own look.
_Avoid_: settings, preferences, config, preset

**Uniforms**:
The per-frame constants handed to every shader: the clock, the Snapshot's features, the
Tuning, and the state the host derives so no Visualizer has to keep it itself.

**Palette**:
One of the colour schemes. A Palette belongs to a Visualizer's Tuning, not to the app.

**Render Scale**:
The fraction of native resolution the drawable is rendered at. Steps down when the GPU can't
hold the frame budget and back up when it can, rather than dropping frames.

### Media players

**Player**:
An external media app Synesthia can recognize — Music, Spotify. Never the app's own
playback of a file or the Demo Track; those are Sources.
_Avoid_: media player, music app, source. **Never** use for the app's own file playback.

**Track**:
What a Player is playing: title, artist, album, and whether it is playing or paused.

**Now Playing**:
What the badge shows — the Track from the winning Player when there is one, or the Demo
Track's own details. Knowing this costs no Permission.

**Player Control**:
The opt-in layer that adds transport buttons and real cover art by driving a Player
directly. Everything else about Now Playing works without it.
_Avoid_: automation, remote, Apple Events (those are how it works, not what it is)

**Artwork Tile**:
The square at the leading edge of the badge. Real cover art when a Player handed over the
bytes; otherwise a gradient sampled from the current Palette at an offset derived from the
album, with the Player's icon in the corner. The gradient is the designed answer, not a
placeholder.

### Permissions and first run

**Permission**:
One of the macOS privacy grants Synesthia may need. A Source Kind names the Permission it
requires, or none.
_Avoid_: TCC, entitlement, access

**Blocked**:
The active Source cannot run for want of a Permission. Distinct from a transient failure:
Blocked earns the explainer card, a transient failure earns a banner that clears itself.

**Welcome**:
The first-run explainer that describes each Source and what it costs before macOS asks for
anything. Nothing plays until it is answered.
_Avoid_: onboarding, intro, first-run wizard

### Distribution

**App Store build**:
The Mac App Store channel. Shows Now Playing, but has no Player Control and sends no Apple
Events at all.

**Direct build**:
The notarized direct-download channel. Adds Player Control and in-app updates.
