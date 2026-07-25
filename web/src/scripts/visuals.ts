/**
 * Canvas renderers. Everything here reads from `signal` and draws additively on
 * a transparent canvas, so the page background shows through as the field.
 */

import { BAND_COUNT, signal } from './signal';

/* -------------------------------------------------------------- dispersion */

type Stop = [number, number, number, number]; // position, r, g, b

// The comet's own dispersion, sampled from the icon.
const SPECTRUM: Stop[] = [
	[0.0, 0x2e, 0x9b, 0xff],
	[0.18, 0x43, 0xd9, 0xff],
	[0.38, 0x3f, 0xe3, 0x9b],
	[0.58, 0xf2, 0xd5, 0x44],
	[0.78, 0xff, 0x7a, 0x18],
	[1.0, 0xff, 0x2d, 0x2d],
];

/** Sample the dispersion at 0..1. */
export function spectral(t: number, alpha = 1) {
	const p = t < 0 ? 0 : t > 1 ? 1 : t;
	let i = 0;
	while (i < SPECTRUM.length - 2 && p > SPECTRUM[i + 1]![0]) i++;
	const a = SPECTRUM[i]!;
	const b = SPECTRUM[i + 1]!;
	const k = (p - a[0]) / (b[0] - a[0] || 1);
	const r = Math.round(a[1] + (b[1] - a[1]) * k);
	const g = Math.round(a[2] + (b[2] - a[2]) * k);
	const bl = Math.round(a[3] + (b[3] - a[3]) * k);
	return `rgba(${r},${g},${bl},${alpha})`;
}

function gradientAlong(
	ctx: CanvasRenderingContext2D,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	alpha: number,
) {
	const g = ctx.createLinearGradient(x0, y0, x1, y1);
	for (const [pos, r, gr, b] of SPECTRUM) g.addColorStop(pos, `rgba(${r},${gr},${b},${alpha})`);
	return g;
}

/* ------------------------------------------------------------------ canvas */

interface Surface {
	ctx: CanvasRenderingContext2D;
	w: number;
	h: number;
	dpr: number;
}

function surface(canvas: HTMLCanvasElement, maxDpr = 2): Surface | null {
	const ctx = canvas.getContext('2d');
	if (!ctx) return null;
	return { ctx, w: 0, h: 0, dpr: Math.min(maxDpr, window.devicePixelRatio || 1) };
}

/** Resize the backing store to match layout. Returns false if it has no size. */
function fit(canvas: HTMLCanvasElement, s: Surface) {
	const rect = canvas.getBoundingClientRect();
	if (rect.width < 2 || rect.height < 2) return false;
	const w = Math.round(rect.width * s.dpr);
	const h = Math.round(rect.height * s.dpr);
	if (canvas.width !== w || canvas.height !== h) {
		canvas.width = w;
		canvas.height = h;
	}
	s.w = w;
	s.h = h;
	return true;
}

const band = (i: number) => signal.bands[Math.max(0, Math.min(BAND_COUNT - 1, i | 0))]!;
const bandAt = (t: number) => band(t * (BAND_COUNT - 1));

/* ------------------------------------------------------------------- comet */

/**
 * The hero. A fan of tapered strands sweeping from a white-hot head at the
 * lower left to a point at the upper right, dispersing blue through red along
 * the way — the icon, animated. Each strand's thickness is modulated by the
 * band sitting under it, so loud frequencies swell as bulges travelling down
 * the streak.
 */
export function mountComet(canvas: HTMLCanvasElement) {
	const s = surface(canvas, 1.75);
	if (!s) return () => {};

	const scene = document.createElement('canvas');
	const sctx = scene.getContext('2d')!;
	const blur = document.createElement('canvas');
	const bctx = blur.getContext('2d')!;

	const STRANDS = 11;
	const STEPS = 52;

	/** Thickness profile along the streak: rounded head, needle tip. */
	const taper = (u: number) => Math.pow(1 - u, 1.35) * Math.pow(Math.min(1, u / 0.1), 0.55);

	function drawScene(w: number, h: number, t: number) {
		sctx.clearRect(0, 0, w, h);

		const L = Math.hypot(w, h);
		// Axis of the streak: lower left to upper right, like the icon.
		const hx = w * 0.11;
		const hy = h * 0.82;
		const tx = w * 0.81;
		const ty = h * 0.19;
		const dx = tx - hx;
		const dy = ty - hy;
		const len = Math.hypot(dx, dy);
		const px = -dy / len;
		const py = dx / len;

		// Ambient wash so the streak sits in a field rather than on a void.
		const glow = sctx.createRadialGradient(
			hx + dx * 0.5,
			hy + dy * 0.5,
			0,
			hx + dx * 0.5,
			hy + dy * 0.5,
			len * 0.62,
		);
		glow.addColorStop(0, `rgba(88,60,220,${0.1 + 0.16 * signal.level})`);
		glow.addColorStop(1, 'rgba(88,60,220,0)');
		sctx.fillStyle = glow;
		sctx.fillRect(0, 0, w, h);

		sctx.globalCompositeOperation = 'lighter';

		for (let k = 0; k < STRANDS; k++) {
			const spread = (k / (STRANDS - 1)) * 2 - 1; // -1 outer, 0 centre, 1 outer
			const inner = 1 - Math.abs(spread); // 1 at the core strand
			// Each strand answers to its own slice of the spectrum.
			const energy = band(4 + k * 5);
			const fan = L * 0.078 * (0.42 + 0.95 * energy) * spread;
			// The core is the luminous body; the outer strands stay filament-thin,
			// the way they peel off the streak in the icon.
			const thickness =
				L * 0.019 * (0.08 + 1.05 * Math.pow(inner, 1.7)) * (0.6 + 0.62 * signal.level);
			const alpha = 0.13 + 0.26 * inner + 0.2 * energy;

			const edge = (i: number, side: 1 | -1) => {
				const u = i / STEPS;
				const bow = Math.sin(Math.PI * Math.pow(u, 0.85));
				const wobble =
					Math.sin(u * 5.2 - t * 1.5 + k * 1.27) * L * 0.014 * (0.35 + signal.beat);
				const off = (fan + wobble * inner) * bow;
				const wd = thickness * taper(u) * (0.45 + 0.9 * bandAt(u * 0.92));
				const cx = hx + dx * u + px * off;
				const cy = hy + dy * u + py * off;
				return [cx + px * wd * side, cy + py * wd * side] as const;
			};

			sctx.beginPath();
			for (let i = 0; i <= STEPS; i++) {
				const [x, y] = edge(i, 1);
				if (i === 0) sctx.moveTo(x, y);
				else sctx.lineTo(x, y);
			}
			for (let i = STEPS; i >= 0; i--) {
				const [x, y] = edge(i, -1);
				sctx.lineTo(x, y);
			}
			sctx.closePath();
			sctx.fillStyle = gradientAlong(sctx, hx, hy, tx, ty, alpha);
			sctx.fill();
		}

		// White-hot head.
		const headR = L * 0.024 * (0.8 + 0.5 * signal.bass);
		const head = sctx.createRadialGradient(hx, hy, 0, hx, hy, headR);
		head.addColorStop(0, 'rgba(255,255,255,1)');
		head.addColorStop(0.18, `rgba(214,240,255,${0.7 + 0.25 * signal.beat})`);
		head.addColorStop(0.45, 'rgba(80,190,255,0.35)');
		head.addColorStop(1, 'rgba(46,120,255,0)');
		sctx.fillStyle = head;
		sctx.beginPath();
		sctx.arc(hx, hy, headR, 0, Math.PI * 2);
		sctx.fill();

		sctx.globalCompositeOperation = 'source-over';
	}

	function render() {
		if (!fit(canvas, s)) return;
		const { ctx, w, h } = s;

		if (scene.width !== w || scene.height !== h) {
			scene.width = w;
			scene.height = h;
			blur.width = Math.max(1, Math.round(w / 4));
			blur.height = Math.max(1, Math.round(h / 4));
		}

		drawScene(w, h, signal.time);

		// Bloom: a quarter-scale copy blurred back up under the sharp pass.
		bctx.clearRect(0, 0, blur.width, blur.height);
		bctx.drawImage(scene, 0, 0, blur.width, blur.height);

		ctx.clearRect(0, 0, w, h);
		ctx.save();
		ctx.filter = `blur(${Math.max(3, Math.round(w / 260))}px)`;
		ctx.globalAlpha = 0.72;
		ctx.drawImage(blur, 0, 0, w, h);
		ctx.restore();
		ctx.globalCompositeOperation = 'lighter';
		ctx.drawImage(scene, 0, 0);
		ctx.globalCompositeOperation = 'source-over';
	}

	return render;
}

/* ---------------------------------------------------------- spectrum strip */

/** 64 bars with peak-hold caps — the analyser, shown plainly. */
export function mountSpectrum(canvas: HTMLCanvasElement) {
	const s = surface(canvas, 2);
	if (!s) return () => {};
	const peaks = new Float32Array(BAND_COUNT);

	return function render(dt = 0.016) {
		if (!fit(canvas, s)) return;
		const { ctx, w, h } = s;
		ctx.clearRect(0, 0, w, h);

		const gap = Math.max(1, w / BAND_COUNT / 5);
		const bw = (w - gap * (BAND_COUNT - 1)) / BAND_COUNT;
		const radius = Math.min(bw / 2, w / 420);

		for (let i = 0; i < BAND_COUNT; i++) {
			const v = signal.bands[i]!;
			peaks[i] = Math.max(v, peaks[i]! - dt * 0.42);
			const x = i * (bw + gap);
			const bh = Math.max(h * 0.035, v * h * 0.94);
			const colour = spectral(i / (BAND_COUNT - 1), 0.9);

			ctx.fillStyle = colour;
			ctx.beginPath();
			ctx.roundRect(x, h - bh, bw, bh, [radius, radius, 0, 0]);
			ctx.fill();

			// Peak cap: a hairline that falls back slowly.
			const py = h - Math.max(h * 0.035, peaks[i]! * h * 0.94);
			ctx.globalAlpha = 0.55;
			ctx.fillRect(x, py - Math.max(1, h / 90), bw, Math.max(1, h / 90));
			ctx.globalAlpha = 1;
		}
	};
}

/* ------------------------------------------------------------ miniatures */

/** Deterministic per-particle noise — plain arithmetic sequences phase-lock
 *  into visible spirals, which is exactly what a nebula should not look like. */
function hash(n: number) {
	const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
	return x - Math.floor(x);
}

/** Nebula: particles bound to bands, orbiting and flaring when their band hits. */
export function mountNebula(canvas: HTMLCanvasElement) {
	const s = surface(canvas, 1.5);
	if (!s) return () => {};

	const N = 150;
	const seeds = Array.from({ length: N }, (_, i) => ({
		bandIndex: Math.floor(hash(i + 1) * BAND_COUNT),
		angle: hash(i + 2.7) * Math.PI * 2,
		// Biased toward the middle so the cloud has a dense core rather than
		// scattering evenly across the frame.
		radius: 0.1 + 0.9 * Math.pow(hash(i + 8.3), 1.4),
		y: (hash(i + 19.4) * 2 - 1) * Math.pow(hash(i + 23.9), 0.35),
		speed: 0.18 + hash(i + 31.6) * 0.55,
	}));

	return function render() {
		if (!fit(canvas, s)) return;
		const { ctx, w, h } = s;
		ctx.clearRect(0, 0, w, h);
		ctx.globalCompositeOperation = 'lighter';

		const cx = w / 2;
		const cy = h / 2;
		const scale = Math.min(w, h) * 0.46;
		const t = signal.time;

		for (const p of seeds) {
			const v = signal.bands[p.bandIndex]!;
			const a = p.angle + t * p.speed * (0.55 + v * 1.5);
			const r = p.radius * (1 + 0.22 * v + 0.18 * signal.beat);
			const z = Math.sin(a) * r;
			const depth = 2.2 / (2.2 + z);
			const x = cx + Math.cos(a) * r * scale * 1.3 * depth;
			// The vertical spread is independent of the orbit radius, so the cloud
			// reads as an ellipsoid rather than a flat band.
			const y = cy + p.y * scale * 0.72 * depth;
			const size = (0.7 + 5.2 * v) * depth * (s.dpr * 0.85);
			const tone = p.bandIndex / BAND_COUNT;
			const bright = Math.min(1, (0.12 + v * 1.2) * depth);

			// Halo first, then the core — cheap bloom without a filter pass.
			ctx.fillStyle = spectral(tone, bright * 0.1);
			ctx.beginPath();
			ctx.arc(x, y, size * 2.6, 0, Math.PI * 2);
			ctx.fill();

			ctx.fillStyle = spectral(tone, bright);
			ctx.beginPath();
			ctx.arc(x, y, size, 0, Math.PI * 2);
			ctx.fill();
		}
		ctx.globalCompositeOperation = 'source-over';
	};
}

/**
 * Spectrum Tunnel: a tube flown through end-on. Each angular slice of the wall
 * is one frequency band, so the spectrum wraps the tunnel and loud bands push
 * their slice outward.
 */
export function mountTunnel(canvas: HTMLCanvasElement) {
	const s = surface(canvas, 1.5);
	if (!s) return () => {};

	const RINGS = 13;
	const SLICES = 40;

	return function render() {
		if (!fit(canvas, s)) return;
		const { ctx, w, h } = s;
		ctx.clearRect(0, 0, w, h);
		ctx.globalCompositeOperation = 'lighter';

		const cx = w / 2;
		const cy = h / 2;
		const max = Math.hypot(w, h) * 0.62;
		const t = signal.time;

		// Ring geometry at depth z (0 = far, 1 = at the camera).
		const ringRadius = (z: number) => max * Math.pow(z, 1.9);
		const twistAt = (z: number) => (1 - z) * 1.9 + t * 0.35;

		for (let j = 0; j < RINGS; j++) {
			const zNear = ((j + 1) / RINGS + t * 0.22) % 1;
			const zFar = zNear - 1 / RINGS;
			if (zFar <= 0.02) continue;

			const rNear = ringRadius(zNear);
			const rFar = ringRadius(zFar);
			const twistNear = twistAt(zNear);
			const twistFar = twistAt(zFar);
			// Bright in the middle distance, fading out both at the vanishing
			// point and as the wall sweeps past the camera.
			const alpha = Math.sin(Math.PI * zNear) * (0.28 + 0.72 * signal.level) * 0.85;

			for (let i = 0; i < SLICES; i++) {
				const bi = Math.floor((i / SLICES) * BAND_COUNT);
				const v = signal.bands[bi]!;
				const push = 1 + 0.5 * v;
				const a0 = (i / SLICES) * Math.PI * 2;
				const a1 = ((i + 1) / SLICES) * Math.PI * 2;

				ctx.beginPath();
				ctx.moveTo(
					cx + Math.cos(a0 + twistFar) * rFar * push,
					cy + Math.sin(a0 + twistFar) * rFar * push,
				);
				ctx.lineTo(
					cx + Math.cos(a1 + twistFar) * rFar * push,
					cy + Math.sin(a1 + twistFar) * rFar * push,
				);
				ctx.lineTo(
					cx + Math.cos(a1 + twistNear) * rNear * push,
					cy + Math.sin(a1 + twistNear) * rNear * push,
				);
				ctx.lineTo(
					cx + Math.cos(a0 + twistNear) * rNear * push,
					cy + Math.sin(a0 + twistNear) * rNear * push,
				);
				ctx.closePath();
				ctx.fillStyle = spectral(i / SLICES, alpha * (0.18 + 0.9 * v));
				ctx.fill();
			}
		}
		ctx.globalCompositeOperation = 'source-over';
	};
}

/** Aurora: layered ribbons riding the waveform. */
export function mountAurora(canvas: HTMLCanvasElement) {
	const s = surface(canvas, 1.5);
	if (!s) return () => {};

	const RIBBONS = 6;

	return function render() {
		if (!fit(canvas, s)) return;
		const { ctx, w, h } = s;
		ctx.clearRect(0, 0, w, h);
		ctx.globalCompositeOperation = 'lighter';

		const t = signal.time;
		const steps = 72;

		for (let r = 0; r < RIBBONS; r++) {
			const f = r / (RIBBONS - 1);
			const bandIndex = Math.floor(f * (BAND_COUNT - 1));
			const v = signal.bands[bandIndex]!;
			const yBase = h * (0.28 + f * 0.44);
			const amp = h * (0.08 + 0.3 * v);
			const thick = h * (0.02 + 0.07 * v);

			ctx.beginPath();
			for (let i = 0; i <= steps; i++) {
				const u = i / steps;
				const waveIndex = Math.floor(u * 255);
				const y =
					yBase +
					signal.wave[waveIndex]! * amp +
					Math.sin(u * 3.1 + t * (0.7 + f) + r) * h * 0.05;
				if (i === 0) ctx.moveTo(0, y);
				else ctx.lineTo(u * w, y);
			}
			for (let i = steps; i >= 0; i--) {
				const u = i / steps;
				const waveIndex = Math.floor(u * 255);
				const y =
					yBase +
					signal.wave[waveIndex]! * amp +
					Math.sin(u * 3.1 + t * (0.7 + f) + r) * h * 0.05;
				ctx.lineTo(u * w, y + thick);
			}
			ctx.closePath();

			const g = ctx.createLinearGradient(0, yBase - amp, 0, yBase + amp + thick);
			g.addColorStop(0, spectral(f, 0));
			g.addColorStop(0.5, spectral(f, 0.5 + 0.4 * v));
			g.addColorStop(1, spectral(f, 0));
			ctx.fillStyle = g;
			ctx.fill();
		}
		ctx.globalCompositeOperation = 'source-over';
	};
}
