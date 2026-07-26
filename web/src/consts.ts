/**
 * Single source of truth for the things that change between environments or
 * that are still pending. Anything marked PLACEHOLDER needs a real value before
 * launch.
 */

export const SITE = {
	name: 'Synesthia',
	/** Used in <title> and the Open Graph title. */
	title: 'Synesthia — Music you can see',
	tagline: 'Music visualizer for macOS',
	description:
		'Synesthia turns whatever your Mac is playing into light. A 64-band FFT drives three Metal visualizers in real time, from Apple Music, any app’s audio, a mic, or a file.',
	author: 'Jon Jaques',
	locale: 'en_US',
	/** Twitter/X handle for the summary card. PLACEHOLDER. */
	social: '@synesthia_app',
} as const;

/**
 * PLACEHOLDER — the Mac App Store listing does not exist yet. Swap this for the
 * real product URL (https://apps.apple.com/app/id0000000000) and every download
 * button on the page follows.
 */
export const APP_STORE_URL = 'https://apps.apple.com/app/id0000000000';

/**
 * The notarized direct download — the build that keeps the Music.app source,
 * and the only one that updates itself via Sparkle.
 *
 * Not a real file path: `/download` is a Pages Function that redirects to the
 * current DMG in R2 (see web/functions/download.ts), so this link keeps working
 * across releases and the site never has to be rebuilt to publish one.
 */
export const DIRECT_DOWNLOAD_URL = '/download';

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
	version: '1.0',
	// The deployment target is 26.0, not 26.5 — the only API pinning the floor
	// is `glassEffect`, which is a 26.0 API.
	requires: 'macOS 26 or later',
	// Release archives are universal (arm64 + x86_64); macOS 26 Tahoe is the
	// last release supporting Intel Macs, so they are still in scope.
	chip: 'Apple silicon or Intel',
	// The notarized, stapled, signed DMG from `make direct`: 4,351,091 bytes.
	// Read it from `/download?json`, or `stat -f %z` — NOT from `du -h`, which
	// reports allocated blocks and answered 5.1M for this very file.
	size: '4.4 MB',
} as const;

/**
 * Contact addresses published on the support and privacy pages. Apple requires
 * a reachable support URL, and a dead address there is a review risk.
 * PLACEHOLDER — these need real mail routing on the synesthia.app domain.
 */
export const CONTACT = {
	support: 'support@synesthia.app',
	privacy: 'privacy@synesthia.app',
} as const;

/** Last substantive revision of the privacy policy, shown on that page. */
export const LEGAL = {
	effective: '25 July 2026',
} as const;

/**
 * Google Analytics 4 measurement ID. PUBLIC_GA_ID overrides the literal below,
 * which is the production property. Set PUBLIC_GA_ID to 'G-XXXXXXXXXX' (or any
 * non-`G-` value) to build without emitting the analytics script at all.
 */
export const GA_MEASUREMENT_ID = import.meta.env.PUBLIC_GA_ID ?? 'G-MEDVX83G9P';

export const GA_ENABLED =
	typeof GA_MEASUREMENT_ID === 'string' &&
	GA_MEASUREMENT_ID.startsWith('G-') &&
	GA_MEASUREMENT_ID !== 'G-XXXXXXXXXX';
