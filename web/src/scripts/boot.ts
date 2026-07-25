/**
 * Wires the page up: mounts each canvas, keeps offscreen ones from drawing,
 * runs the microphone toggle, and reveals sections on scroll.
 */

import { isClockRunning, onFrame, primeStatic, signal, startClock, stopClock } from './signal';
import { mountAurora, mountComet, mountNebula, mountSpectrum, mountTunnel } from './visuals';

const RENDERERS = {
	comet: mountComet,
	spectrum: mountSpectrum,
	nebula: mountNebula,
	tunnel: mountTunnel,
	aurora: mountAurora,
} as const;

type VizName = keyof typeof RENDERERS;

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

document.documentElement.classList.add('js');

/* ------------------------------------------------------------- canvases */

const canvases = document.querySelectorAll<HTMLCanvasElement>('canvas[data-viz]');
let anyVisible = false;

const visibility = new IntersectionObserver(
	(entries) => {
		for (const entry of entries) {
			(entry.target as HTMLElement).dataset.visible = String(entry.isIntersecting);
		}
		anyVisible = [...canvases].some((c) => c.dataset.visible === 'true');
		syncClock();
	},
	{ rootMargin: '120px' },
);

for (const canvas of canvases) {
	const name = canvas.dataset.viz as VizName;
	const mount = RENDERERS[name];
	if (!mount) continue;

	const render = mount(canvas);
	canvas.dataset.visible = 'true';
	onFrame((dt) => {
		if (canvas.dataset.visible !== 'false') render(dt);
	});
	visibility.observe(canvas);
}

/* --------------------------------------------------------------- readouts */

// Live scalars, updated well below frame rate — text layout is expensive and
// nobody can read 60 changes a second anyway.
const readouts = [...document.querySelectorAll<HTMLElement>('[data-readout]')];
let readoutClock = 0;

onFrame((dt) => {
	readoutClock += dt;
	const refract = Math.min(1, signal.level * 1.6 + signal.beat * 0.35);
	document.documentElement.style.setProperty('--refract', refract.toFixed(3));

	if (readoutClock < 0.09) return;
	readoutClock = 0;
	for (const el of readouts) {
		const key = el.dataset.readout as 'bass' | 'mid' | 'treble' | 'level';
		const value = signal[key] ?? 0;
		el.textContent = Math.round(Math.min(1, value) * 100)
			.toString()
			.padStart(2, '0');
	}
});

/* ----------------------------------------------------------------- clock */

function syncClock() {
	const shouldRun = anyVisible && !document.hidden && (!reduceMotion.matches || signal.micActive);
	if (shouldRun) startClock();
	else if (isClockRunning()) stopClock();
}

document.addEventListener('visibilitychange', syncClock);
reduceMotion.addEventListener('change', () => {
	if (reduceMotion.matches && !signal.micActive) {
		stopClock();
		primeStatic();
	} else {
		syncClock();
	}
});

/* ------------------------------------------------------------------- mic */

const micButtons = [...document.querySelectorAll<HTMLButtonElement>('[data-mic-toggle]')];
const micStatus = document.querySelector<HTMLElement>('[data-mic-status]');

function paintMicState() {
	for (const button of micButtons) {
		const label = button.querySelector('[data-mic-label]') ?? button;
		label.textContent = signal.micActive ? 'Stop listening' : 'Use your mic';
		button.dataset.live = String(signal.micActive);
		button.setAttribute('aria-pressed', String(signal.micActive));
	}
	if (micStatus) {
		micStatus.textContent =
			signal.micError ??
			(signal.micActive
				? 'Listening. Audio stays in this browser.'
				: 'Nothing is recorded, and no audio leaves this page.');
		micStatus.dataset.error = String(Boolean(signal.micError));
	}
}

signal.onChange(paintMicState);

for (const button of micButtons) {
	button.addEventListener('click', async () => {
		button.disabled = true;
		await signal.toggleMic();
		button.disabled = false;
		syncClock();
	});
}

paintMicState();

/* ---------------------------------------------------------------- reveal */

const reveal = new IntersectionObserver(
	(entries) => {
		for (const entry of entries) {
			if (!entry.isIntersecting) continue;
			entry.target.classList.add('is-in');
			reveal.unobserve(entry.target);
		}
	},
	{ rootMargin: '-8% 0px -8% 0px' },
);

document.querySelectorAll('[data-reveal]').forEach((el, i) => {
	(el as HTMLElement).style.transitionDelay = `${Math.min(i % 4, 3) * 70}ms`;
	reveal.observe(el);
});

/* -------------------------------------------------------------- kick off */

if (reduceMotion.matches) {
	// Still show a real, composed frame — just a still one.
	primeStatic();
} else {
	anyVisible = true;
	syncClock();
}
