---
name: Synesthia
description: A darkened listening room — near-black indigo chrome that exists so the app's own light is the only colour in the frame.
colors:
  ink: "#0a0912"
  raised: "#161421"
  line: "#272338"
  line-soft: "#1a1727"
  line-lift: "#34333f"
  paper: "#f4f2f9"
  paper-lift: "#ffffff"
  dim: "#a5a2b4"
  mute: "#878396"
  accent: "#6e4bff"
  wash-cold: "#2e9bff"
  capture-tint: "#7163ff"
  icon-field: "color(display-p3 0.07979 0 0.45094)"
  plate-black: "#000000"
typography:
  display:
    fontFamily: "Familjen Grotesk, Helvetica Neue, Helvetica, sans-serif"
    fontSize: "clamp(2.5rem, 5.2vw, 3.75rem)"
    fontWeight: 600
    lineHeight: 1.04
    letterSpacing: "-0.022em"
  headline:
    fontFamily: "Familjen Grotesk, Helvetica Neue, Helvetica, sans-serif"
    fontSize: "clamp(1.75rem, 3.4vw, 2.375rem)"
    fontWeight: 600
    lineHeight: 1.04
    letterSpacing: "-0.022em"
  title:
    fontFamily: "Familjen Grotesk, Helvetica Neue, Helvetica, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.012em"
  body:
    fontFamily: "IBM Plex Sans, Helvetica Neue, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: "normal"
  label:
    fontFamily: "IBM Plex Mono, ui-monospace, monospace"
    fontSize: "0.6875rem"
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: "0.12em"
  spec:
    fontFamily: "IBM Plex Mono, ui-monospace, monospace"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.5
    fontFeature: "tabular-nums"
rounded:
  xs: "0.3rem"
  sm: "0.4rem"
  md: "0.625rem"
  lg: "0.875rem"
  capsule: "9999px"
  app-badge: "16px"
  app-badge-inner: "10px"
  app-card: "24px"
spacing:
  rail: "clamp(1.25rem, 5vw, 4.5rem)"
  container: "76rem"
  section: "6rem"
  section-wide: "8rem"
  pod-height: "56px"
  pod-inset: "6px"
  pod-gap: "12px"
  chrome-inset-x: "16px"
  chrome-inset-bottom: "20px"
components:
  button-primary:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0.9rem 1.25rem"
  button-primary-hover:
    backgroundColor: "{colors.paper-lift}"
    textColor: "{colors.ink}"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.paper}"
    rounded: "{rounded.md}"
    padding: "0.9rem 1.25rem"
  button-secondary-hover:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.paper}"
  button-compact:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0.5rem 0.875rem"
  surface-card:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.paper}"
    rounded: "{rounded.lg}"
    padding: "1.5rem"
  plate:
    backgroundColor: "{colors.plate-black}"
    rounded: "{rounded.lg}"
  tab:
    backgroundColor: "transparent"
    textColor: "{colors.mute}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "0.4rem 0.7rem"
  tab-selected:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.paper}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "0.4rem 0.7rem"
  kbd:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.dim}"
    typography: "{typography.label}"
    rounded: "{rounded.xs}"
    padding: "0.25rem 0.4rem"
  chrome-pod:
    backgroundColor: "transparent"
    textColor: "{colors.paper-lift}"
    rounded: "{rounded.capsule}"
    padding: "0 14px"
    height: "{spacing.pod-height}"
  now-playing-badge:
    backgroundColor: "transparent"
    textColor: "{colors.paper-lift}"
    rounded: "{rounded.app-badge}"
    padding: "{spacing.pod-inset}"
    height: "{spacing.pod-height}"
  chrome-icon-button:
    backgroundColor: "transparent"
    textColor: "{colors.paper-lift}"
    rounded: "{rounded.capsule}"
    size: "32px"
  permission-card:
    backgroundColor: "transparent"
    textColor: "{colors.paper-lift}"
    rounded: "{rounded.app-card}"
    padding: "28px 32px"
    width: "430px"
---

# Design System: Synesthia

## Overview

**Creative North Star: "The Darkened Listening Room"**

Synesthia's interface is an unlit room, and the app's own output is the only light source in it. That single idea generates every decision below. The room is never neutral black — every surface is pulled a few degrees toward the indigo of the app icon, so that a screenshot whose own background is pure black reads as a lit object _in_ the room rather than a hole punched through it. The strongest colour anywhere in the chrome is a 14% indigo wash at the top of the landing page. Everything more saturated than that is the product, not the frame.

The room exists across two very different media, and it behaves the same in both. In the app, the chrome is glass floating over a live Metal canvas — three pods along the bottom edge, a status line at the top, and after three seconds of pointer stillness all of it fades out and the room goes dark except for the visual. On the site, the same restraint becomes flat near-black surfaces, hairline indigo rules, and real captures of the app lit by two drop shadows, one of which is deliberately indigo. Nothing on the site simulates the product; the plates _are_ the product.

The voice is precise and unembarrassed by the machinery. Small mono labels carry the machine-readable facts — 64 bands, 30 Hz – 16 kHz, 2048-point FFT — in the same tone the app itself uses, because a listener who cares that the analysis is real is the listener this is for. Warmth comes from the display face (a Swedish grotesque, not another Inter) and from geometry being correct; it never comes from decoration. Three things this system is explicitly not: the neon VJ/EDM aesthetic (no synthwave grids, no glowing gradient chrome — saturation belongs to audio-driven output only), the SaaS landing page (no gradient mesh, no floating 3D mockups, no logo wall, no testimonial cards, no pill buttons), and any simulated product output whatsoever.

**Key Characteristics:**

- Indigo-tinted near-black, never neutral grey — the room has a colour temperature
- Colour budget spent entirely on the product's own output; chrome stays under a 14% ceiling
- Flat by default; light appears only around real captures of the app
- Chrome that can disappear completely, and does
- Display grotesque against a mono spec face — warmth carrying instrument readings
- Every visual of the product is a real capture off the shipping build

## Colors

Nearly achromatic, but never neutral: four surfaces and three inks, all rotated toward the icon's indigo, with exactly one saturated accent that is never allowed to become type.

### Primary

- **Icon Indigo** (`#6e4bff`): The icon's field colour, and the only saturated value in the system. Focus rings (2px, 3px offset), the hero wash's warm lobe at 14%, and the second pass of the plate shadow at 12–20%. It fails contrast as text, so it is never used for type or for an icon that carries meaning alone.
- **Capture Purple** (`#7163ff`): App only. The disc behind an active listen button, matched to macOS's own menu-bar audio-capture pill rather than to `.systemIndigo` (`#5856d6`), which is visibly darker than the chip it sits beside. The one place in the app that overrides a system colour, and the comment in `CaptureButton` explains why.
- **Icon Field Indigo** (`color(display-p3 0.07979 0 0.45094)`): The gradient origin inside `Icon.icon`. Not a UI token — it is the upstream source the two above answer to. Every derived asset (favicons, touch icon, `Mark.astro`) comes out of the Icon Composer export via `npm run assets`; none is redrawn.

### Secondary

- **Cold Lobe Blue** (`#2e9bff`): One job only — the colder second lobe of the hero wash, at 7%, under the headline column. It exists so the wash reads as light with direction rather than as a single flat bloom.

### Neutral

- **Indigo Black** (`#0a0912`): The room. Page background, window background, and the browser theme colour.
- **Raised Indigo** (`#161421`): Every surface that sits above the room — cards, selected tabs, keycaps, secondary-button hover.
- **Indigo Hairline** (`#272338`): The structural rule. Section borders, card and plate edges, keycap borders, and the underline colour beneath prose links.
- **Whisper Rule** (`#1a1727`): The softer divider, for rows _inside_ a surface where the structural hairline would over-articulate the list.
- **Hairline Lift** (`#34333f`): The one hover state of the structural rule — the secondary button's border on hover.
- **Cool Paper** (`#f4f2f9`): Primary text, and the fill of the primary button. Slightly cool, so it belongs to the same light as the room.
- **Paper Lift** (`#ffffff`): Pure white, reserved for two things: the primary button's hover fill, and text sitting on glass in the app (where the canvas behind it is arbitrary and only full white plus a shadow guarantees legibility).
- **Dimmed Paper** (`#a5a2b4`): Secondary prose, list descriptions, nav links at rest.
- **Muted Slate** (`#878396`): Tertiary — mono labels, spec lines, footer text, list markers.
- **Plate Black** (`#000000`): Used _only_ as the backing of a screenshot frame, matching the captures' own background. Never a page or panel surface.

### Named Rules

**The Colour Belongs to the Product Rule.** No chrome surface, border, glow, or wash may exceed 14% of a saturated hue. If a screen needs more colour, the answer is a real capture of the app, not a more colourful interface.

**The Accent Is Not Ink Rule.** Icon Indigo (`#6e4bff`) is a ring, a wash, and a shadow pass. It is never text, never an icon that carries meaning alone, and never a fill behind text.

**The Never-Neutral Rule.** Every grey in this system is rotated toward the icon's indigo. A literal neutral (`#808080`, `#111`, Tailwind's `zinc`) is the failure mode this palette exists to avoid — it makes the room read as an absence rather than a place.

**The Palette Coefficients Are Canonical Rule.** The app's five palettes (Prism, Ember, Ocean, Violet, Mono) are cosine palettes — `a + b·cos(2π(c·t + d))` per channel — defined once in `Palettes.color` and mirrored in `Shaders.metal`. Those coefficients are the only source of truth. The five 5-stop swatch strips on the landing page are hand-authored and **do not currently match them** (the app's Prism runs red → magenta → blue → green → yellow; the site's runs blue → green → yellow → orange → red; the app's Mono is symmetric white → dark → white, the site's is a monotone ramp). This is known drift: regenerate those strips by sampling the coefficients, and never treat the site's hexes as the palette.

## Typography

**Display Font:** Familjen Grotesk (with Helvetica Neue, Helvetica, sans-serif)
**Body Font:** IBM Plex Sans (with Helvetica Neue, sans-serif)
**Label/Mono Font:** IBM Plex Mono (with ui-monospace, monospace)

**Character:** A Swedish grotesque doing the talking and an IBM mono doing the measuring. The display face is warmer and less corporate than the Inter/Archivo default but sober at 600, so it carries a product page without competing with the product; Plex Mono gives the numbers the look of readings off equipment, which is what they are.

In the app there is no custom typography at all: every label uses a SwiftUI semantic text style (`.headline`, `.callout`, `.subheadline`, `.caption`, `.title3`, `.largeTitle`, and `.caption.monospacedDigit()` for slider values). That is a deliberate native-first choice — it inherits San Francisco, Dynamic-Type-adjacent behaviour, and the user's own accessibility text settings for free.

### Hierarchy

- **Display** (600, `clamp(2.5rem, 5.2vw, 3.75rem)`, 1.04, −0.022em, balanced wrap): One per page. The page's single claim — "Music you can see."
- **Headline** (600, `clamp(1.75rem, 3.4vw, 2.375rem)`, 1.04, −0.022em): Section headings. Always preceded by a mono eyebrow, never by a larger label.
- **Title** (600, 1.0625rem, 1.3, −0.012em): The workhorse — visualizer names, pipeline stages, source names, FAQ questions. Small enough to sit in a three-up grid, still the display face so the family reads through.
- **Body** (400, 1rem, 1.6): Prose in Dimmed Paper. Measure is capped explicitly at the point of use — `42ch` for hero and section leads, `46ch` for the legal standfirst, `max-w-3xl` for long prose.
- **Label** (500, 0.6875rem, 0.12em, uppercase, Muted Slate): The eyebrow above every section heading, carousel tabs, keycaps, and the "Last updated" line. Tracking is what makes it legible at this size.
- **Spec** (400, 0.75rem, tabular numerals, Muted Slate): Machine-readable facts on their own line — `Free · macOS 15 or later · Apple silicon or Intel · 4.4 MB`, `64 bands · 30 Hz – 16 kHz`, per-visualizer option names. Tabular figures so version and size strings don't shift between pages.

### Named Rules

**The Mono Carries the Numbers Rule.** Any value a user could check — a version, a frequency, a file size, a band count, a shortcut — is set in Plex Mono with tabular numerals. Prose describes; mono measures.

**The One Weight Rule.** The display face ships exactly one weight (600), because exactly one weight is ever asked for. Adding 500 or 700 to a rule means adding a font download to every visit; three weights were once preloaded for nothing. Check `astro.config.mjs` before you set a display weight.

**The App Never Names a Size Rule.** No `Font.system(size:)` for text in the app. Semantic styles only, so the user's text-size and accessibility settings reach the UI. (Icon glyphs are the sole exception — `ChromeIconButtonStyle` sizes symbols explicitly, because those are drawn shapes, not type.)

## Layout

**The site** is a single 76rem column with one gutter token. `.rail` — `padding-inline: clamp(1.25rem, 5vw, 4.5rem)`, `max-width: 76rem`, auto margins — is applied to the header, every section, and the footer, so nothing can drift a few pixels out of alignment. Vertical rhythm is one value with one step up: `pb-24` (6rem) between sections, `pb-32` (8rem) from `md` up. Sections alternate between two structures only: a `max-w-[42rem]` intro block followed by a grid, or a 12-column split (`md:col-span-5` intro / `md:col-span-6 md:col-start-7` content) that leaves a real gutter down the middle rather than a token gap. Grids collapse in one step — three-up to one-up, four-up to two-up to one-up — at `sm`/`md`/`lg`; there is no dense mobile variant because there is nothing to compress.

**The app** lays out on width thresholds measured from its own content, not device classes. `ChromeLayout` picks `wide` at ≥940pt (badge leading, transport optically centred, visualizer trailing — one row), `medium` at ≥680pt (badge on its own row above the other two), and `compact` below that (each pod on its own centred row), with a hard `minWindowSize` of 460×380 because that is where the transport pod begins to clip. The bottom band sits 16pt from the side edges and 20pt from the bottom, with 12pt between pods. Everything in that band is exactly 56pt tall.

### Named Rules

**The One Rail Rule.** Every full-width band on the site uses `.rail`. A section that sets its own horizontal padding is a bug, not a variant.

**The One Height Rule.** Every pod in the app's bottom chrome is exactly 56pt (`chromePodHeight`), set by the tallest content (the badge's two lines beside artwork). Pods sizing themselves to their contents is what made the band read as three unrelated objects; do not let a new pod opt out.

**The Measure Rule.** Prose is capped in characters (`42ch`, `46ch`, `18ch` for the closing heading), never in pixels, and never left to the container.

## Elevation & Depth

Flat, with light in exactly two places. Surfaces are separated by a hairline and a one-step tonal lift (Raised Indigo on Indigo Black), not by shadow: `.surface` carries `1px solid` Indigo Hairline and no blur, no gradient, no shadow at all. The one thing that does get shadow is a real capture of the app — and it gets two passes, one black for depth and one indigo, because a screenshot whose own background is `#000` needs coloured light to separate from a near-black page. That indigo pass is the system's single decorative flourish, and it is pointed at the product.

The app's chrome is the exception that proves the rule: it floats over a live canvas, so it has to be a material rather than a tone. On macOS 26 that is real Liquid Glass (`.glassEffect`, `.interactive()` on the two pods containing controls); on macOS 15 it degrades to `.ultraThinMaterial` plus a 14%-white hairline and a soft drop shadow — same job, separating chrome from arbitrary moving colour. Route every new chrome background through the `chromeGlass` modifier; nothing else in the app is allowed to call `glassEffect` directly.

### Shadow Vocabulary

- **Plate** (`box-shadow: 0 18px 44px rgba(0,0,0,0.5), 0 4px 30px color-mix(in oklab, var(--color-accent) 12%, transparent)`): Framed, opaque captures (the fullscreen shots), which also get a clipping radius and a hairline.
- **Shot** (`filter: drop-shadow(0 24px 60px rgba(0,0,0,0.7)) drop-shadow(0 6px 44px color-mix(in oklab, var(--color-accent) 20%, transparent))`): Windowed captures, which carry their own rounded corners and traffic lights in the alpha channel. A `filter` rather than a `box-shadow` precisely so the shadow follows the alpha instead of a rectangle — this is why they are never given a frame.
- **Glass fallback** (`shadow(color: .black.opacity(0.35), radius: 10, y: 3)`): App only, macOS 15 path, under a pod.
- **Glyph shadow** (`shadow(color: .black.opacity(0.35), radius: 3, y: 1)`): App only, applied by `chromeForeground()` _inside_ the glass so it lands on the glyphs and not on the capsule. Invisible against dark material; the entire point is the frame where a bright canvas pushes the glass light and white-on-glass has no guaranteed contrast.

### Named Rules

**The Light Comes From the Work Rule.** Shadows exist to lift the product's own output off the page. A card, a panel, a button, or a nav bar that wants a shadow gets a hairline and a tonal step instead.

**The Glass Is One Modifier Rule.** All chrome material in the app goes through `chromeGlass(in:interactive:)`. It owns the macOS 26 / 15 split; a direct `glassEffect` call compiles fine on both and silently breaks the fallback, which nothing catches.

## Shapes

Rounded rectangles at four sizes, and capsules only where something floats. The site's radius scale is deliberately modest — keycaps at 0.3rem, tabs and swatch strips at 0.4rem, buttons at 0.625rem, cards and plates at 0.875rem — because this is the marketing surface of a Mac app and its controls should look like they came from the same place as the app's. Nothing on the site is a pill; a pill button reads as web-native and breaks the association the whole page is built on.

In the app, the two control pods and the icon buttons _are_ capsules and circles, and that is not a contradiction: they are floating objects over a moving canvas, where a capsule reads as a physical lozenge of glass, while a rounded rectangle reads as a mis-sized window. Rectangular app surfaces keep the larger radii — 16pt for the now-playing badge, 18pt for the status banner, 24pt for the permission card.

Borders are hairlines: 1px Indigo Hairline on the site, `.white.opacity(0.14)` on glass, `0.5pt` white at 16% around artwork, and a 1px soft-white capsule (18% white) instead of a `Divider()` inside pods — the system separator colour reads as a hard dark scratch over glass.

### Named Rules

**The Concentric Rule.** A shape nested inside a rounded shape takes the outer radius minus the inset, so the curves stay parallel. The now-playing badge is the reference implementation: 16pt outer, 6pt inset, 10pt artwork. Never nest a radius by eye.

**The Rounded Rect, Not Pill Rule.** Site controls are rounded rectangles (0.625rem). Capsules and circles are reserved for chrome that floats over the canvas in the app.

## Components

**Character: tactile and confident.** Controls should have presence at rest — a legible surface, a real edge, an unmistakable affordance — and should reward a press. This is the system's target, and the site's filled primary button already meets it.

**Where the implementation lags — read this before "matching the existing style".** Parts of the current build are markedly more reticent than the doctrine above, and reproducing them is not the same as being consistent:

- `ChromeIconButtonStyle` renders non-prominent glyphs at 78% white with a fully transparent backing disc at rest (`0` opacity, 10% on hover, 18% pressed). Its scale-on-press (0.92) is the tactile part; the resting invisibility is not.
- `.btn-secondary` is a ghost — transparent fill, hairline border — beside a fully filled primary.
- `.tab` at rest is Muted Slate on nothing, with a transparent border reserved for the selected state.
- `PodDivider` and the pod menus rely on 18–72% white overlays rather than any surface of their own.

Closing that gap is future work with a real constraint: these controls sit on glass over arbitrary moving colour, so "more presence" must come from the pod's own material and geometry, not from raising opacity until the glyph glows. Any change here is verified against a bright canvas frame, not a dark one.

### Buttons

- **Shape:** Gently rounded rectangle (0.625rem), inline-flex, 0.5rem gap between icon and label, `line-height: 1`, never wrapping.
- **Primary:** Cool Paper fill, Indigo Black text, `0.9rem 1.25rem` padding. The filled button is the download; there is one per band and it always names the channel ("Download on the Mac App Store", "Download for macOS") except in the header, where a bare "Download" is unambiguous because only one is shown.
- **Hover / Focus:** Fill lifts to Paper Lift; secondary's border lifts to Hairline Lift with a Raised Indigo fill. Both transition `background-color`, `border-color`, `color` at 0.18s ease. Focus is the global ring — 2px Icon Indigo, 3px offset, 3px radius — never removed, never restyled per component.
- **Secondary:** Transparent fill, Indigo Hairline border, Cool Paper text, same padding and radius. Used for "See it running" and the second download channel. Only ever one filled button in a pair; emphasis is assigned by order, not by taste.
- **Icons:** Inline SVG at `1.125rem` (`1rem` compact), `fill-current`, `aria-hidden`. Never an icon font, never an `<img>`.

### App chrome buttons

- **Shape:** 32×32pt circular hit target, semibold SF Symbol at 15pt; the prominent variant (transport play/pause, listen) is a filled disc at `size + 6`.
- **States:** Hover disc at 10% white, press at 18%, scale 0.92 on press, 0.12s/0.1s ease-out. Prominent variants stay at full white and take no backing disc.
- **Distinctive:** The listen button is the only coloured control in the app — white glyph on a Capture Purple disc with a 6pt glow at 70% when active, matching macOS's own capture chip. It stays lit while its neighbours sit back, because capture is the primary action.

### Cards / Containers

- **Corner Style:** 0.875rem (`.surface`, `.plate`); 24pt for the app's permission card.
- **Background:** Raised Indigo for cards; Plate Black behind captures only.
- **Shadow Strategy:** None on cards — hairline plus tonal step. Captures use the Plate or Shot vocabulary above.
- **Border:** 1px Indigo Hairline. On glass, `.white.opacity(0.14)`.
- **Internal Padding:** 1.5rem (`p-6`) for panels; `px-6 py-16 sm:py-20` for the centred closing block; 18pt for app popover sections; 44pt horizontal for the welcome sheet.

### Rows and lists

- **Style:** Bordered rows, not cards. `border-b` in Whisper Rule with `first:pt-0 last:border-0 last:pb-0`, so a list has internal rules and no outer box.
- **Two-column rows** use a `minmax(0, 9rem) minmax(0, 1fr)` grid with baseline alignment from `sm` up, collapsing to stacked below. Term left, description right, both in DOM reading order — the keyboard-shortcut list uses `flex-row-reverse` to put keycaps on the right _without_ putting the description first for a screen reader.

### Navigation

- **Site header:** Sticky, `h-14`, `bg-ink/70` with `backdrop-blur-xl` and a bottom hairline — the one place on the site that blurs, because content scrolls under it. Mark at 26px plus the wordmark in the display face at 0.95rem/600. Section links are `text-sm` Dimmed Paper → Cool Paper on hover; they hide below `md`, and the compact download button hides below `sm`, leaving mark and wordmark. Current page is marked with `aria-current="page"` and Cool Paper.
- **App:** No navigation. There is no title bar text, no sidebar, no tab bar — sources and visualizers are menus inside the bottom pods, and the traffic lights float directly on the canvas (`ChromelessWindow`).
- **Skip link:** First focusable element on every page, visually hidden until focused, then a Cool Paper block at top-left.

### The Plate (signature component)

The frame around a real capture, and the site's most load-bearing decision. Two variants by capture type: **framed** (`.plate`) for opaque fullscreen shots — 0.875rem radius, `overflow: hidden`, hairline, Plate Black backing, Plate shadow; and **unframed** (`.shot-shadow`) for windowed shots, which already carry macOS's rounded corners and traffic lights in their alpha and therefore get a `drop-shadow` filter that follows their real silhouette instead of a box. Every image inside one is an `astro:assets` `<Picture>` emitting AVIF with a WebP fallback, with real `widths`/`sizes`, an alt text that describes what the visualizer actually looks like, and `loading="eager"` only on the first.

### The Carousel (signature component)

Three windowed captures of the same window crossfading in a fixed `4/3` stage at 0.7s `ease-out-quart`, on a 4600ms interval. It is built to degrade: the first slide carries `data-active` from the server and the controls are `display: none` until `.js` is present, so with JavaScript off the hero is simply a screenshot. Tabs are the `.tab` component in a real `role="tablist"`, and the play/pause control carries the word "Pause"/"Play" beside its glyph — not because the icon is unclear, but because WCAG 2.2.2 requires a discoverable mechanism to stop motion that runs longer than five seconds, and hover/focus pausing is available to neither touch nor screen-reader users.

### The Artwork Tile (signature component)

The square at the leading edge of the app's now-playing badge, and the system's one piece of generative colour. With real cover art it shows it; without — always in the App Store build, always for Spotify — it draws a two-stop gradient sampled from the _current visualizer's_ palette at an offset derived from the album name via FNV-1a (not `String.hashValue`, which is per-process seeded and would recolour the same album every launch), plus a top-leading highlight at 22% white and the reporting player's icon in the corner over a blurred black scrim. It is a designed answer, not a placeholder: the tile belongs to the same picture as the canvas, is stable per album, and the player icon answers the question real artwork would have.

### Inputs / Fields

- The app's options popover (340pt wide) is the only place with real controls: uppercase caption section headers in secondary, native `Slider`s with a mono two-decimal readout, native `.switch` toggles, and a per-row revert affordance that appears only once a value differs from its default by more than 0.005.
- The palette picker is five 26pt-tall gradient swatches at 6pt radius, each sampling six stops of its cosine palette; selection is a 2px white border against 1px at 15% white, plus an `.isSelected` accessibility trait.
- **The site has no inputs at all** — no forms, no search, no newsletter. Adding one means designing a field style that does not exist yet; derive it from the keycap and card treatment (Raised Indigo fill, Indigo Hairline border, 0.625rem radius, global focus ring) rather than importing one.

## Do's and Don'ts

### Do:

- **Do** put every full-width band inside `.rail`, and cap prose in `ch`.
- **Do** spend the colour budget on the product. If a section feels flat, the fix is a real capture, not a gradient.
- **Do** run new app chrome backgrounds through `chromeGlass(in:interactive:)`, and apply `chromeForeground()` inside it so the glyph shadow lands on the glyphs.
- **Do** keep every pod in the app's bottom band at exactly 56pt (`chromePodHeight`).
- **Do** derive a nested radius as outer minus inset (badge: 16 − 6 = 10).
- **Do** set machine-readable values in Plex Mono with tabular numerals.
- **Do** give every animated thing a stop: the carousel has a labelled toggle, and `prefers-reduced-motion` flattens transitions to 0.001ms and disables the reveal. The app honours Reduce Motion by damping beat-driven flashing and smoothing brightness — a new visual with transient-driven luminance must too.
- **Do** keep the app's chrome pinned when VoiceOver is running (`NSWorkspace.isVoiceOverEnabled`) — auto-hide on pointer idle is hostile to anyone who never moves a pointer.
- **Do** ship real alt text that describes what the visualizer looks like, not "screenshot of the app".
- **Do** check `astro.config.mjs` before using a font weight; the display face ships one.
- **Do** regenerate the site's palette strips from the cosine coefficients when you next touch them, and close the tactile-vs-reticent gap named in Components — verified against a bright canvas frame.

### Don't:

- **Don't** use a neutral grey anywhere. Every surface is tinted toward the icon's indigo.
- **Don't** set Icon Indigo as a text or icon colour; it fails contrast. Rings, washes, and shadow passes only.
- **Don't** exceed 14% saturation in chrome, or let anything on a page be brighter than the captures.
- **Don't** add a shadow to a card, panel, button, or nav bar. Hairline plus one tonal step.
- **Don't** use pills on the site, or rounded rectangles for the app's floating pods.
- **Don't** call `glassEffect` directly, or use any macOS 26 API without an `#available` guard — the deployment target is 15.0.
- **Don't** simulate, illustrate, mock up, or re-create the app's output. Captures come from `make screenshots` off the shipping build, or they don't ship.
- **Don't** hardcode a text size in the app; semantic styles only (icon glyph sizes excepted).
- **Don't** use `Divider()` inside a glass pod — the system separator reads as a dark scratch. Use the soft-white capsule rule.
- **Don't** reach for the SaaS landing-page kit: gradient mesh, floating 3D device mockups, logo walls, testimonial cards, animated counters. None of it is in this world.
- **Don't** import the visualizer's own look into the interface. No synthwave grids, no neon glow chrome, no rainbow gradients on type.
- **Don't** make a control's only affordance a hover state; the chrome fades out entirely, so every function needs a keyboard path.
