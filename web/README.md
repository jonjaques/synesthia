# Synesthia — landing page

Single-page marketing site for the Synesthia macOS visualizer. Astro 7 (static
output) + Tailwind v4, no client framework.

```sh
npm install
npm run dev      # http://localhost:4321
npm run build    # -> dist/
npm run preview
```

## Before launch

Everything pending lives in `src/consts.ts` and `astro.config.mjs`:

| What | Where | Current value |
|---|---|---|
| Mac App Store listing | `APP_STORE_URL` in `src/consts.ts` | `https://apps.apple.com/app/id0000000000` |
| Google Analytics 4 ID | `PUBLIC_GA_ID` env var, or `GA_MEASUREMENT_ID` in `src/consts.ts` | `G-XXXXXXXXXX` |
| Production domain | `site` in `astro.config.mjs`, and the `Sitemap:` line in `public/robots.txt` | `https://synesthia.app` |
| Twitter/X handle | `SITE.social` in `src/consts.ts` | `@synesthia_app` |
| Version, size, requirements | `RELEASE` in `src/consts.ts` | 1.0 / 4.2 MB / macOS 26.5 |

The analytics snippet is only emitted once the measurement ID differs from the
placeholder, so dev and preview builds write no cookie and load no script. Set
it per environment:

```sh
PUBLIC_GA_ID=G-ABC1234567 npm run build
```

`site` feeds canonical URLs, Open Graph tags and the generated sitemap, so it
has to be right before deploying.

## How the page works

The hero is a live visualizer, not a video. `src/scripts/signal.ts` produces the
same shape of data the app itself analyses — 64 log-spaced bands from 30 Hz to
16 kHz, a 256-sample waveform, bass/mid/treble/level, and a beat envelope — and
every canvas on the page reads from it through one shared `requestAnimationFrame`
loop.

Two producers feed that signal:

- **Synthetic** (default) — a plausible piece of music at 104 BPM. No permission
  prompt, so the page is alive on arrival.
- **Microphone** — the *Use your mic* button opens an `AnalyserNode` and the page
  visualizes the room. Nothing is recorded or transmitted. The two producers
  crossfade, so toggling is never a jump cut.

`src/scripts/visuals.ts` holds the renderers: the hero comet (the app icon,
animated), the 64-bar analyser strip, and miniatures of the three shipping
visualizers. `src/scripts/boot.ts` wires them up and keeps offscreen canvases
from drawing.

Under `prefers-reduced-motion` the clock never starts — each canvas renders one
composed still frame instead. Turning the mic on is an explicit choice, so it
starts the loop even then.

## Assets

`public/img/*`, the favicons and `og.png` are generated from the app icon in
`../assets/`. If the icon changes, regenerate them:

```sh
npm run assets
```

The OG card is composited with sharp: the bare comet artwork screen-blended over
an indigo gradient, with the wordmark set in the system grotesque.

## Design tokens

Colors and type live in `src/styles/global.css` under `@theme`. Every color is
sampled from the app icon: an indigo field (`--color-void`, `--color-field`) and
the comet's dispersion (`--color-spec-blue` through `--color-spec-red`). Type is
Archivo for display, IBM Plex Sans for body, IBM Plex Mono for specs and labels,
self-hosted and preloaded through Astro's fonts API.
