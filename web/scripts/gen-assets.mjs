
import sharp from 'sharp';
import { mkdir } from 'node:fs/promises';

const SRC = '../assets';
const ICON = `${SRC}/Icon Exports/Icon-iOS-Default-1024x1024@1x.png`;
const COMET = `${SRC}/Icon.icon/Assets/icon-1784999000502-1.png`;
const OUT = './public';

await mkdir(`${OUT}/img`, { recursive: true });

// --- App icon at the sizes the page and browsers need -----------------------
const sizes = [
  [1024, `${OUT}/img/icon-1024.png`],
  [512, `${OUT}/img/icon-512.png`],
  [256, `${OUT}/img/icon-256.png`],
  [192, `${OUT}/img/icon-192.png`],
  [180, `${OUT}/apple-touch-icon.png`],
  [32, `${OUT}/favicon-32.png`],
  [16, `${OUT}/favicon-16.png`],
];
for (const [size, dest] of sizes) {
  await sharp(ICON).resize(size, size, { fit: 'cover' }).png({ compressionLevel: 9 }).toFile(dest);
}

// --- The bare comet, trimmed of dead black and kept on black so the page can
// --- composite it with `screen` blending.
await sharp(COMET).resize(1400, 1400).png({ compressionLevel: 9 }).toFile(`${OUT}/img/comet.png`);

// --- Open Graph card --------------------------------------------------------
const W = 1200;
const H = 630;

const bg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs>
    <radialGradient id="g" cx="72%" cy="42%" r="78%">
      <stop offset="0%" stop-color="#2E1E8F"/>
      <stop offset="55%" stop-color="#150A45"/>
      <stop offset="100%" stop-color="#07031A"/>
    </radialGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="#07031A"/>
  <rect width="${W}" height="${H}" fill="url(#g)"/>
</svg>`);

// Crop the diagonal streak out of the square artwork so it can bleed off the
// right edge of the card at full size.
const comet = await sharp(COMET)
  .resize(1000, 1000)
  .extract({ left: 110, top: 140, width: 660, height: 630 })
  .toBuffer();

const type = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs>
    <linearGradient id="spec" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0%" stop-color="#7FC5FF"/>
      <stop offset="34%" stop-color="#3FE39B"/>
      <stop offset="62%" stop-color="#F2D544"/>
      <stop offset="100%" stop-color="#FF7A18"/>
    </linearGradient>
  </defs>
  <g font-family="Helvetica Neue, Helvetica, Arial" fill="#EDE9FF">
    <text x="82" y="243" font-size="26" letter-spacing="7" font-weight="500" fill="#A79CE0">MUSIC VISUALIZER FOR MACOS</text>
    <text x="78" y="360" font-size="112" font-weight="700" letter-spacing="-4">Music you</text>
    <text x="78" y="470" font-size="112" font-weight="700" letter-spacing="-4" fill="url(#spec)">can see.</text>
    <text x="82" y="536" font-size="27" font-weight="400" fill="#A79CE0">Synesthia &#183; 64-band FFT &#183; Metal</text>
  </g>
</svg>`);

await sharp(bg)
  .composite([
    { input: comet, top: 0, left: 540, blend: "screen" },
    { input: type, top: 0, left: 0 },
  ])
  .png({ compressionLevel: 9 })
  .toFile(`${OUT}/img/og.png`);

console.log('assets written');
