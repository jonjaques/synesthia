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

| What                        | Where                                                                        | Current value                             |
| --------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------- |
| Mac App Store listing       | `APP_STORE_URL` in `src/consts.ts`                                           | `https://apps.apple.com/app/id0000000000` |
| Google Analytics 4 ID       | `PUBLIC_GA_ID` env var, or `GA_MEASUREMENT_ID` in `src/consts.ts`            | `G-XXXXXXXXXX`                            |
| Production domain           | `site` in `astro.config.mjs`, and the `Sitemap:` line in `public/robots.txt` | `https://synesthia.app`                   |
| Twitter/X handle            | `SITE.social` in `src/consts.ts`                                             | `@synesthia_app`                          |
| Version, size, requirements | `RELEASE` in `src/consts.ts`                                                 | 1.0 / 4.2 MB / macOS 15                   |

The analytics snippet is only emitted once the measurement ID differs from the
placeholder, so dev and preview builds write no cookie and load no script. Set
it per environment:

```sh
PUBLIC_GA_ID=G-ABC1234567 npm run build
```

`site` feeds canonical URLs, Open Graph tags and the generated sitemap, so it
has to be right before deploying.

## How the page works

It is a business card, not a manual: hero, visualizers, sources, pipeline, and a
download. Every image is a real capture produced by `make screenshots` in the
repo root, which drives the shipping build — there is no re-creation of the app
anywhere on the page. (There used to be: a canvas re-implementation of the
visualizers and a microphone demo. Both are gone.)

`src/scripts/boot.ts` is the whole of the page's JavaScript and does two things:

- **Reveal** — one `IntersectionObserver` fades `[data-reveal]` sections in once.
- **Carousel** — `src/components/ShotCarousel.astro` crossfades the three
  windowed captures in the hero. It autoplays only while it is on screen, the
  tab is in front, the pointer is elsewhere, and the visitor hasn't clicked a
  tab themselves; `prefers-reduced-motion` disables autoplay entirely.

Both degrade to nothing: without JS every section is visible, the first slide
stays put, and the carousel tabs are hidden rather than dead.

## Assets

`public/img/*`, the favicons and `og.png` are generated from the app icon in
`../assets/`. If the icon changes, regenerate them:

```sh
npm run assets
```

The OG card is composited with sharp: the bare comet artwork screen-blended over
an indigo gradient, with the wordmark set in the system grotesque.

## Design tokens

Colors and type live in `src/styles/global.css` under `@theme`. The screenshots
are the only saturated thing on the page, so the chrome stays nearly achromatic
— but not neutral grey: every surface is pulled a few degrees toward the icon's
indigo (`--color-accent`), and `body::before` lays a soft wash of it over the
top of the document. That tint is what the plates read against; their own
backgrounds are pure black, so a page that isn't pure black makes each one a
distinct object instead of a hole. Nothing exceeds 14% saturation.

Type is Familjen Grotesk for display, IBM Plex Sans for body, IBM Plex Mono for
specs and labels, self-hosted and preloaded through Astro's fonts API.
