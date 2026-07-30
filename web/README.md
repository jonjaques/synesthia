# Synesthia — landing page

Single-page marketing site for the Synesthia macOS visualizer. Astro 7 (static
output) + Tailwind v4, no client framework.

```sh
npm install
npm run dev      # http://localhost:4321
npm run build    # -> dist/
npm run preview
```

## Still placeholder

Everything pending lives in `src/consts.ts`:

| What                  | Where                                | Current value                             | Consequence while it stands                                                                                                                          |
| --------------------- | ------------------------------------ | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mac App Store listing | `APP_STORE_URL`                      | `https://apps.apple.com/app/id0000000000` | Nothing — `APP_STORE_AVAILABLE` is `false`, so no button points at it                                                                                |
| Twitter/X handle      | `SITE.social`                        | `@synesthia_app`                          | `twitter:site` / `twitter:creator` are **omitted**, on purpose: attributing the card to a handle that doesn't exist is worse than not attributing it |
| Support mail routing  | `CONTACT.support`, `CONTACT.privacy` | `@synesthia.app` addresses                | A dead support address is an App Review risk                                                                                                         |

Settled, but worth knowing where they live: `site` in `astro.config.mjs` (feeds
canonical URLs, Open Graph, the JSON-LD graph and the sitemap), the `Sitemap:`
line in `public/robots.txt`, and `RELEASE` in `src/consts.ts` (version, size and
requirements shown next to the download).

## Analytics

Google Analytics 4, measurement ID in `GA_MEASUREMENT_ID` (`src/consts.ts`),
overridable per environment with `PUBLIC_GA_ID`. To build with none of it —
no script, no cookie, no listeners — give it anything that isn't a real ID:

```sh
PUBLIC_GA_ID=off npm run build
```

Two files:

- **`src/components/Analytics.astro`** bootstraps the tag, and is where the
  opt-out lives. It checks Do Not Track and Global Privacy Control _before_
  injecting the script, so an opted-out visitor causes no request at all, and
  sets `<html data-analytics="on">` only if it really loaded.
- **`src/scripts/analytics.ts`** is the behavioural half, loaded by the layout on
  every page (including the legal ones — outbound and `mailto:` clicks happen
  there too). It reads that flag and attaches nothing without it.

Beyond the automatic `page_view`, these custom events are sent:

| Event               | Parameters                                            | Answers                                    |
| ------------------- | ----------------------------------------------------- | ------------------------------------------ |
| `download_click`    | `channel`, `placement`, `release_version`, `link_url` | Did anyone download, and from which button |
| `outbound_click`    | `link_url`, `link_domain`, `link_text`, `placement`   | Where the page sends people                |
| `contact_click`     | `address`, `placement`                                | Whether the support address gets used      |
| `nav_click`         | `target`, `placement`                                 | Which section people go looking for        |
| `section_view`      | `section`                                             | Which sections actually got seen           |
| `scroll_depth`      | `percent` (25/50/75/90)                               | How far down the pitch gets read           |
| `select_visualizer` | `visualizer`, `method`                                | Which hero shot people choose              |
| `carousel_toggle`   | `state`                                               | Whether the autoplay annoys people         |
| `web_vitals`        | `metric_name`, `metric_value`, `metric_rating`        | LCP / CLS / INP from real visitors         |

`download_click` covers both channels rather than using GA4's automatic
`file_download`, which fires for neither: the App Store button is outbound and
`/download` is an extensionless redirect. `web_vitals` sends CLS multiplied by
1000 so it stays a useful integer — divide it back when reading.

`placement` comes from `data-placement`, which `DownloadOptions` threads through
to each button (`header`, `hero`, `cta`); every other link falls back to which
landmark it sits in.

The privacy page enumerates all of this, and promises the DNT behaviour. If you
add an event, add it there too.

## Headers

`public/_headers` is Cloudflare Pages' header config, copied into `dist/` by the
build. It sets a CSP whose real job is the host allowlist (`unsafe-inline` is
unavoidable for scripts on a static host — the JSON-LD and the analytics
bootstrap are both inline), the usual `nosniff` / `Referrer-Policy` /
`Permissions-Policy` set, and `immutable` caching for `/_astro/*`, which Pages
otherwise revalidates on every visit.

Check it after changing anything that loads from a third-party host, since a
blocked request is silent in production. Locally:

```sh
npm run build && npm run pages-dev   # then look at the response headers
```

## How the page works

It is a business card, not a manual: hero, visualizers, sources, pipeline, and a
download. Every image is a real capture produced by `make screenshots` in the
repo root, which drives the shipping build — there is no re-creation of the app
anywhere on the page. (There used to be: a canvas re-implementation of the
visualizers and a microphone demo. Both are gone.)

`src/scripts/boot.ts` is the landing page's JavaScript and does two things:

- **Reveal** — one `IntersectionObserver` fades `[data-reveal]` sections in once.
- **Carousel** — `src/components/ShotCarousel.astro` crossfades the three
  windowed captures in the hero. It autoplays only while it is on screen, the
  tab is in front, the pointer is elsewhere, and the visitor hasn't taken the
  wheel themselves; `prefers-reduced-motion` disables autoplay entirely, and the
  stop/play button next to the tabs is what makes it pass WCAG 2.2.2 — hover and
  focus already paused it, but neither exists on a touch screen.

Both degrade to nothing: without JS every section is visible, the first slide
stays put, and the carousel controls are hidden rather than dead.

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
