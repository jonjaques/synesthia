/**
 * Single source of truth for the things that change between environments or
 * that are still pending. Anything marked PLACEHOLDER needs a real value before
 * launch.
 */

export const SITE = {
  name: "Synesthia",
  /** Used in <title> and the Open Graph title. */
  title: "Synesthia — Music you can see",
  tagline: "Music visualizer for macOS",
  description:
    "Synesthia turns whatever your Mac is playing into light. A 64-band FFT spectrum analyzer drives its GPU visualizers in real time, from Apple Music, any app’s audio, a mic, or a file.",
  author: "Jon Jaques",
  locale: "en_US",
  /** Twitter/X handle for the summary card. PLACEHOLDER. */
  social: "@synesthia_app",
} as const;

/**
 * The public source repository. Synesthia is MIT licensed, and the site links
 * to it from the footer — the same two destinations the app's Help menu offers.
 */
export const GITHUB_URL = "https://github.com/jonjaques/synesthia";
export const GITHUB_ISSUES_URL = `${GITHUB_URL}/issues`;

/**
 * PLACEHOLDER — the Mac App Store listing does not exist yet. Swap this for the
 * real product URL (https://apps.apple.com/app/id0000000000) and every download
 * button on the page follows.
 */
export const APP_STORE_URL = "https://apps.apple.com/app/id0000000000";

/**
 * The notarized direct download — the build that keeps the Music.app source,
 * and the only one that updates itself via Sparkle.
 *
 * Not a real file path: `/download` is a Pages Function that redirects to the
 * current DMG in R2 (see web/functions/download.ts), so this link keeps working
 * across releases and the site never has to be rebuilt to publish one.
 */
export const DIRECT_DOWNLOAD_URL = "/download";

/**
 * Whether to advertise the direct download on the site.
 *
 * `/download` answers 503 until scripts/publish-release.sh has put a DMG and a
 * latest.json in the R2 bucket, and that cannot happen until the Developer ID
 * certificate exists and a build has been notarized. Until then a visible link
 * is a dead end, so it stays hidden.
 *
 * FLIP THIS TO `true` once `make publish-release` has succeeded — it is the one
 * part of shipping a release that still needs a site rebuild.
 */
export const DIRECT_DOWNLOAD_AVAILABLE = true;

/**
 * Whether to advertise the Mac App Store listing.
 *
 * `false` until the app has actually passed review and APP_STORE_URL points at
 * a real product page — the placeholder ID above resolves to nothing.
 *
 * The two channels are independent on purpose: they go live at different times,
 * and for a while one is the only way to get the app. Turning both off leaves
 * the page with no download button at all, which is intentional and handled —
 * it is the honest state before either exists.
 */
export const APP_STORE_AVAILABLE = false;

/** Shown next to the download button. */
export const RELEASE = {
  version: "1.2.1",
  // The deployment target is 15.0. The only macOS 26 API in the app is
  // `glassEffect`, and it is behind an `#available` check with a material
  // fallback, so Sequoia and Tahoe both run the same binary.
  //
  // This line must not go live ahead of the build it describes: the site
  // deploys independently of the app, and 1.0.1 in R2 is still a 26.0 binary
  // that will not launch on Sequoia. Publish the first 15.0 DMG *before*
  // deploying the site with this value.
  requires: "macOS 15 or later",
  // Release archives are universal (arm64 + x86_64); macOS 26 Tahoe is the
  // last release supporting Intel Macs, so they are still in scope.
  chip: "Apple silicon or Intel",
  // The notarized, stapled, signed DMG from `make direct`: 4,351,091 bytes.
  // Read it from `/download?json`, or `stat -f %z` — NOT from `du -h`, which
  // reports allocated blocks and answered 5.1M for this very file.
  size: "4.4 MB",
} as const;

/**
 * Contact addresses published on the support and privacy pages. Apple requires
 * a reachable support URL, and a dead address there is a review risk.
 *
 * Both are the same personally-monitored mailbox: nothing routes on the
 * synesthia.app domain, and a role address that bounces is worse than a
 * personal one that doesn't. They stay two keys so support can move to
 * support@synesthia.app on its own once that domain has mail, without touching
 * the privacy policy.
 */
export const CONTACT = {
  support: "me@jonjaques.com",
  privacy: "me@jonjaques.com",
} as const;

/**
 * Last substantive revision of the privacy policy, shown on that page.
 *
 * Bump it whenever what the app or the site does with data changes — the page
 * promises that this date moves when the behaviour does.
 */
export const LEGAL = {
  effective: "29 July 2026",
} as const;

/**
 * Google Analytics 4 measurement ID. The literal below is the production
 * property; the PUBLIC_GA_ID environment variable overrides it.
 *
 * To build with no analytics at all — no script, no cookie, no listeners — set
 * PUBLIC_GA_ID to anything that is not a real measurement ID. The literal
 * placeholder `G-XXXXXXXXXX` and any value not starting with `G-` both count:
 *
 *     PUBLIC_GA_ID=off npm run build
 */
export const GA_MEASUREMENT_ID = import.meta.env.PUBLIC_GA_ID ?? "G-MEDVX83G9P";

export const GA_ENABLED =
  typeof GA_MEASUREMENT_ID === "string" &&
  GA_MEASUREMENT_ID.startsWith("G-") &&
  GA_MEASUREMENT_ID !== "G-XXXXXXXXXX";
