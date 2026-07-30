# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Two design surfaces, one product record (confirmed scope):

- **The app** — native macOS, SwiftUI + Metal. `SDKROOT = macosx`, deployment
  target **macOS 15.0**, built against the macOS 26 SDK. No iOS or Catalyst
  target exists. Native macOS conventions (menu bar commands, Settings scene,
  window/fullscreen behavior, keyboard shortcuts, TCC permission flow) are
  product constraints, not stylistic choices. No shipped Impeccable native
  reference covers macOS; `ios.md`/`android.md` do not apply.
- **The site** — `web/`, an Astro + Tailwind static site on Cloudflare Pages
  (`synesthia.app`), self-contained with its own lockfile and Prettier config.
  Platform `web`. Release artifacts are served from R2 by Pages Functions, so
  shipping a version is an upload, not a site rebuild.

## Users

Three confirmed audiences, in priority order:

1. **Fullscreen focal ambience.** Someone who puts Synesthia on a large display
   and _looks at it_ — a room, a party, a wall. The visual is the point; the
   interface should get out of the way and stay gone. This is the primary case
   and the one the app's auto-hiding chrome already serves.
2. **VJs and performers.** Live use: sets, streams, events. They care about
   control latency, reachable palette/parameter tuning, and not failing in front
   of an audience.
3. **Audio-curious tinkerers.** They value that it is a real 64-band FFT running
   on the GPU, read `docs/`, and may write a visualizer against the plugin
   contract. Fidelity and technical candor land with them; marketing gloss does
   not.

**Not a priority audience:** the background-companion case (app parked in a
small window on a second display while the user works, where glanceable
now-playing outranks spectacle). Now-playing exists and works, but it is a layer
on the visual, not the reason to open the app.

## Product Purpose

Synesthia turns whatever the Mac is playing into light. A Hann-windowed
2048-point FFT (Accelerate/vDSP) runs over live audio and publishes 64
log-spaced bands (30 Hz–16 kHz), a 256-sample waveform, bass/mid/treble/level
scalars, and a beat envelope; those drive pluggable Metal visualizers at the
display's full refresh rate.

Success is that the picture reads as _this_ music rather than generic motion —
bass moves differently from treble, transients hit.

## Positioning

Four claims a neighboring visualizer could not truthfully copy without doing the
same work:

- **Tone-reactive, not level-reactive.** Every visual is driven by the banded
  spectrum, not one amplitude number. Nebula binds particles to individual
  bands; Spectrum Tunnel's angular slices _are_ the spectrum.
- **Now-playing for zero permissions.** Title, artist, album, and player icon
  come from the distributed notifications Music and Spotify already broadcast
  system-wide — public API, no entitlement, no prompt, no library access, no
  MediaRemote. Both distribution channels have it.
- **Nothing gated behind a grant to evaluate it.** A bundled demo loop plays on
  first launch; permissions are opt-in, per source, explained before they're
  requested. This is for review/testing purposes.
- **Real GPU residency.** Compute kernels and device-private ping-pong buffers,
  ~100k simulated particles in Nebula, occlusion pausing, adaptive render scale.

## Operating Context

- **The app runs in front of another app's audio.** The normal state is: user is
  in Spotify, a browser, or a game; Synesthia renders behind or beside it, often
  fullscreen, often unattended for long stretches. It is frequently not the
  focused app.
- **Audio sources** (control bar, left menu): System audio (ScreenCaptureKit —
  needs Screen & System Audio Recording; the only sanctioned route to system
  output on macOS, video leg 2×2 px and discarded), Audio input (mic/line-in/
  interface, device picker), Audio file (local file, looped, reopened next
  launch via a security-scoped bookmark). Plus the bundled demo loop.
- **Permission flow is part of the experience, not an aside.** First-run welcome
  sheet explains each source and its cost; the first `startCapture` after a
  fresh grant can need a second attempt; a Debug build is a separate TCC subject
  from a shipped one.
- **Two channels with different capabilities.** Mac App Store (`Release`) and
  notarized direct download with Sparkle (`Direct`). Transport control and real
  album artwork exist only in the direct build, opt-in, and only after the user
  clicks "Control Music… / Control Spotify…".
- **The site's job** is download, screenshots, and support — plus `/appcast.xml`,
  `/download`, `/downloads/*` as live release infrastructure.

## Capabilities and Constraints

**Confirmed app capabilities**

- Four visualizers: **Nebula**, **Spectrum Tunnel**, **Aurora**, **Bars**.
- Five palettes (Prism, Ember, Ocean, Violet, Mono); global Sensitivity and
  Speed; per-visualizer options (≤4 each) that persist per visualizer.
- **Normalize Loudness** (Settings, ⌘,, on by default): slow auto-gain so a
  quiet mic and loud mastered music read the same without retuning.
- Universal binary (Apple silicon + Intel). Full-screen edge to edge; chrome
  auto-hides after 3 s of pointer stillness. Renders at display refresh
  including 120 Hz ProMotion; stops rendering entirely when occluded; keeps the
  display awake only while audio is playing.
- Keyboard: `Space` play/pause · `⌘1`–`⌘4` visualizer · `⌘→/←` track · `⌘L`
  listen · `⌘O` open file · `⌃⌘F` fullscreen.
- No accounts, no analytics, no networking, no third-party SDKs in the app.
  Audio is analyzed in memory, never recorded, stored, or transmitted. Stored
  data is local preferences plus one file bookmark. `PrivacyInfo.xcprivacy`
  declares no tracking and no collected data.

**Durable constraints**

- **macOS 15.0 floor.** One binary serves 15 and 26; the only 26-only API is
  Liquid Glass, behind a single `#available` check with a material fallback.
- **App Sandbox** in both targets. The store build carries no Apple Events
  entitlement and no `network.client`; the release script asserts against the
  built archive that no automation entitlement, no `tell application "…"`
  string, and no Sparkle leaked into it.
- **Plugin contract**: a visualizer is a `Visualizer` class + descriptor +
  shader functions, options capped at 16 and delivered to the shader as `p` in
  declaration order. New UI is generated from descriptors, so a visualizer's
  controls are not hand-designed per visualizer.
- **Audio never publishes into SwiftUI.** The render loop pulls snapshots; only
  now-playing and app state are observable. Anything touching the audio thread
  or draw callback must be `nonisolated`.
- The site is a separate project: run its scripts from inside `web/`, not from
  the Makefile.

**Explicitly open product facts**

- **Localization.** All UI strings are SwiftUI literals. String catalogs are
  enabled but unmigrated; new user-facing strings must stay literal
  `Text("…")` keys, never computed strings.
- **App Store listing does not exist yet.** `APP_STORE_AVAILABLE = false`,
  `APP_STORE_URL` is a placeholder ID. The direct download is live.
- Site placeholders: the `@synesthia_app` social handle and the
  `support@`/`privacy@synesthia.app` addresses need real routing.
- **Known content drift to fix before submission:** `docs/app-store-metadata.md`
  describes _three_ visualizers; the app ships four (Bars). `web/src/pages/index.astro`
  and `web/src/components/ShotCarousel.astro` list three as well, and there are no
  Bars screenshots. The same doc's pointer for the price is also wrong: the
  `Offer` advertising `price: '0'` is in `index.astro`'s `softwareApplication`
  node, not in `Base.astro`.

**Commercial model (confirmed)**

Free as the direct download from synesthia.app; **paid, as a one-time purchase,
on the Mac App Store**. The source is MIT and public, so the store price buys
convenience, updates through Apple, and support of the project — not access.
This resolves the "Free, or paid — undecided" note in
`docs/app-store-metadata.md`. It has a live consequence: the site currently
advertises a single free price for the product — `offers.price: '0'` in the
`softwareApplication` JSON-LD in `web/src/pages/index.astro`, the `ctaHeading`
that reads "Free on the Mac App Store." when `APP_STORE_AVAILABLE` flips true,
and the hero's `Free · macOS 15 or later · …` spec line. All three become false
the moment the paid listing exists, and the middle one is wired to the flag that
turns the listing on, so it will publish the wrong claim by itself. Price must be
stated per channel before `APP_STORE_AVAILABLE` is flipped.

## Brand Commitments

- **Name and wordmark are reserved.** The MIT grant covers the source only; the
  Synesthia name, wordmark, and app icon (`Synesthia/Icon.icon`, `assets/Icon
Exports/`) are excluded. Forks must ship under their own name and mark.
- **The icon is the only mark.** Every favicon and touch icon on the site is
  derived from the Icon Composer export by `npm run assets`; there is no
  hand-drawn version and none should be made.
- Established copy, unchanged unless the user changes it: site title **"Music
  you can see"**, tagline **"Music visualizer for macOS"**, App Store subtitle
  **"See what your Mac is playing"**.
- **Voice: precise and technically candid, no hype.** Consistent across README,
  `docs/`, the App Store drafts, and the site — it explains the mechanism, names
  what a feature costs the user, and states absences plainly ("it is the honest
  state before either exists"). Superlatives and vague benefit language are off
  voice.
- **Prior binding direction for the site:** restrained, near-business-card
  composure — the real screenshots and the Icon Composer mark carry it; no
  simulated effects standing in for the app's output. Recorded as given, not
  expanded.
- The site is dark-only today (`color-scheme: dark`, theme color `#0A0912`).

## Evidence on Hand

Real, usable:

- **Screenshots of the actual shipping UI**, captured by driving it:
  `web/src/assets/screenshots/{nebula,tunnel,aurora}-{windowed,fullscreen}.png`,
  regenerated by `make screenshots`. **No Bars screenshots exist yet.**
- **The bundled demo loop** (`Synesthia/Resources/DemoLoop.m4a`, generated
  deterministically by `make demo-track`) — a demonstrable, permission-free
  first-run experience.
- **Public source** at github.com/jonjaques/synesthia (MIT), issues as the
  support channel, and developer docs in `docs/` (architecture, audio pipeline,
  rendering, visualizers, macOS integration, distribution).
- **Verifiable release facts** in `web/src/consts.ts`: version, `macOS 15 or
later`, `Apple silicon or Intel`, DMG size. Read them from there; they are
  maintained with the release.
- `PrivacyInfo.xcprivacy` and the App Privacy answers back every privacy claim.

**Absent — must not be fabricated:** no testimonials, no press, no reviews, no
user or download counts, no awards, no benchmark numbers beyond what the code
demonstrably does, no customer logos. There is no App Store rating because there
is no listing. Performance claims are limited to what is implemented (64 bands,
2048-point FFT, ~100k particles, display-rate rendering).

## Product Principles

1. **The picture is the product; the interface is scaffolding.** Anything
   persistent that isn't the visual has to earn its pixels, and should be able
   to disappear.
2. **Never make a user pay a permission to find out if it's any good.** Working
   before granting is a feature, and the order — demonstrate, then explain, then
   ask — is fixed.
3. **Say what it costs.** Every permission, channel difference, and absent
   feature is named plainly at the moment it matters. Candor is the brand.
4. **Reactive means banded.** New visuals must be driven by spectrum, waveform,
   or transients — not by one loudness number dressed up as motion.
5. **Native, and quiet about it.** Real macOS behavior — menus, Settings,
   fullscreen, shortcuts, Reduce Motion, VoiceOver, ProMotion — over invented
   chrome.

## Accessibility & Inclusion

- **Reduce Motion is honored** and treated as a correctness requirement, not a
  nicety: it damps beat-driven flashing and smooths brightness. Any new visual
  with transient-driven luminance changes must respect it.
- **VoiceOver labels throughout** the control bar and options.
- **Every core action has a keyboard path** (source, transport, visualizer,
  fullscreen, options).
- **Photosensitivity is a live risk** for this product category: rapid
  full-canvas luminance swings on a large display are the failure mode to design
  against, and Reduce Motion is the sanctioned escape hatch.
