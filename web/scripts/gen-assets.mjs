/**
 * Derives every image the site serves from the two sources of truth:
 *
 *   assets/Icon Exports/…   the Icon Composer export (the real app icon)
 *   src/assets/screenshots/ the real app, captured by `make screenshots`
 *
 * Nothing here is hand-drawn. Run with `npm run assets` after either source
 * changes.
 */

import sharp from 'sharp';
import { mkdir } from 'node:fs/promises';

const SRC = '../assets';
const ICON = `${SRC}/Icon Exports/Icon-iOS-Default-1024x1024@1x.png`;
const SHOT = './src/assets/screenshots/aurora-fullscreen.png';
const OUT = './public';

await mkdir(`${OUT}/img`, { recursive: true });

// --- App icon at the sizes the page and browsers need -----------------------
// The 32/64/128 trio backs the <img srcset> in the header and footer mark; the
// rest are favicons, the touch icon, and the web manifest.
const sizes = [
	[512, `${OUT}/img/icon-512.png`],
	[256, `${OUT}/img/icon-256.png`],
	[192, `${OUT}/img/icon-192.png`],
	[180, `${OUT}/apple-touch-icon.png`],
	[128, `${OUT}/img/icon-128.png`],
	[64, `${OUT}/img/icon-64.png`],
	[48, `${OUT}/favicon-48.png`],
	[32, `${OUT}/favicon-32.png`],
	[16, `${OUT}/favicon-16.png`],
];
for (const [size, dest] of sizes) {
	await sharp(ICON).resize(size, size, { fit: 'cover' }).png({ compressionLevel: 9 }).toFile(dest);
}

// --- Open Graph card --------------------------------------------------------
// A real frame of the app with the mark set into the bottom-left corner, rather
// than a synthetic composition. The scrim only has to carry two lines of type,
// so it stays shallow and lets the art through.
const W = 1200;
const H = 630;

const frame = await sharp(SHOT).resize(W, H, { fit: 'cover', position: 'centre' }).toBuffer();

const scrim = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs>
    <linearGradient id="s" x1="0" y1="1" x2="0.55" y2="0">
      <stop offset="0%" stop-color="#08080C" stop-opacity="0.95"/>
      <stop offset="55%" stop-color="#08080C" stop-opacity="0.35"/>
      <stop offset="100%" stop-color="#08080C" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#s)"/>
</svg>`);

const mark = await sharp(ICON).resize(104, 104).toBuffer();

const type = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <g font-family="Helvetica Neue, Helvetica, Arial">
    <text x="212" y="472" font-size="58" font-weight="600" letter-spacing="-1.5" fill="#F3F2F7">Synesthia</text>
    <text x="214" y="516" font-size="25" font-weight="400" fill="#A3A1AF">Music visualizer for macOS</text>
  </g>
</svg>`);

await sharp(frame)
	.composite([
		{ input: scrim, top: 0, left: 0 },
		{ input: mark, top: 412, left: 84 },
		{ input: type, top: 0, left: 0 },
	])
	.png({ compressionLevel: 9 })
	.toFile(`${OUT}/img/og.png`);

console.log('assets written');
