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

/** Shown next to the download button. */
export const RELEASE = {
	version: '1.0',
	requires: 'macOS 26.5 or later',
	chip: 'Apple silicon',
	size: '4.2 MB',
} as const;

/**
 * PLACEHOLDER — drop in the Google Analytics 4 measurement ID (G-XXXXXXXXXX).
 * Prefer setting PUBLIC_GA_ID in the environment; the literal below is only a
 * fallback so the markup is easy to find. While the value is still the
 * placeholder, no analytics script is emitted.
 */
export const GA_MEASUREMENT_ID = import.meta.env.PUBLIC_GA_ID ?? 'G-XXXXXXXXXX';

export const GA_ENABLED =
	typeof GA_MEASUREMENT_ID === 'string' &&
	GA_MEASUREMENT_ID.startsWith('G-') &&
	GA_MEASUREMENT_ID !== 'G-XXXXXXXXXX';
