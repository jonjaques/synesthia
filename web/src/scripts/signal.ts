/**
 * The signal that drives every canvas on the page.
 *
 * It mirrors what the app itself does: 64 log-spaced bands between 30 Hz and
 * 16 kHz, a 256-sample waveform, bass/mid/treble/level scalars and a beat
 * envelope from bass transients.
 *
 * Two producers feed it. By default it synthesises a signal so the page is
 * alive with no interaction and no permission prompt. When the visitor turns on
 * their microphone it reads a real AnalyserNode instead, and crossfades between
 * the two so the switch is never a jump cut.
 */

export const BAND_COUNT = 64;
export const WAVE_COUNT = 256;
export const F_LOW = 30;
export const F_HIGH = 16_000;

const ATTACK = 0.5;
const RELEASE = 0.11;

function lerp(a: number, b: number, t: number) {
	return a + (b - a) * t;
}

function clamp01(v: number) {
	return v < 0 ? 0 : v > 1 ? 1 : v;
}

class Signal {
	/** Normalised band magnitudes, index 0 = 30 Hz, index 63 = 16 kHz. */
	readonly bands = new Float32Array(BAND_COUNT);
	/** Normalised waveform, -1..1. */
	readonly wave = new Float32Array(WAVE_COUNT);

	bass = 0;
	mid = 0;
	treble = 0;
	level = 0;
	/** Decaying envelope that spikes on a bass transient. */
	beat = 0;

	/** True once a microphone stream is running. */
	micActive = false;
	/** Set when the browser or the visitor refuses the microphone. */
	micError: string | null = null;

	time = 0;

	private synth = new Float32Array(BAND_COUNT);
	private live = new Float32Array(BAND_COUNT);
	private synthWave = new Float32Array(WAVE_COUNT);
	private liveWave = new Float32Array(WAVE_COUNT);
	private mix = 0; // 0 = synthetic, 1 = microphone
	private bassAvg = 0;

	private ctx: AudioContext | null = null;
	private analyser: AnalyserNode | null = null;
	private stream: MediaStream | null = null;
	private freqBytes: Uint8Array | null = null;
	private timeBytes: Uint8Array | null = null;
	private binRanges: Array<[number, number]> = [];

	private listeners = new Set<() => void>();

	onChange(fn: () => void) {
		this.listeners.add(fn);
		return () => this.listeners.delete(fn);
	}

	private emit() {
		for (const fn of this.listeners) fn();
	}

	/** Advance the signal. `dt` is in seconds. */
	update(dt: number) {
		this.time += dt;
		this.renderSynthetic(this.time);
		if (this.analyser) this.readMicrophone();

		const target = this.micActive ? 1 : 0;
		this.mix = lerp(this.mix, target, 1 - Math.exp(-dt * 6));

		let sum = 0;
		for (let i = 0; i < BAND_COUNT; i++) {
			const want = lerp(this.synth[i]!, this.live[i]!, this.mix);
			const prev = this.bands[i]!;
			// Fast attack, slow release — the same asymmetry the app uses so
			// peaks read clearly but nothing flickers.
			this.bands[i] = prev + (want - prev) * (want > prev ? ATTACK : RELEASE);
			sum += this.bands[i]!;
		}

		for (let i = 0; i < WAVE_COUNT; i++) {
			this.wave[i] = lerp(this.synthWave[i]!, this.liveWave[i]!, this.mix);
		}

		this.bass = this.average(0, 10);
		this.mid = this.average(10, 34);
		this.treble = this.average(34, BAND_COUNT);
		this.level = sum / BAND_COUNT;

		// Beat: how far the current bass sits above its own running average.
		this.bassAvg = lerp(this.bassAvg, this.bass, 1 - Math.exp(-dt * 2.2));
		const transient = clamp01((this.bass - this.bassAvg) * 4.5);
		this.beat = Math.max(transient, this.beat - dt * 3.4);
	}

	private average(from: number, to: number) {
		let s = 0;
		for (let i = from; i < to; i++) s += this.bands[i]!;
		return s / (to - from);
	}

	/* ---------------------------------------------------------------- synth */

	/**
	 * A plausible piece of music: a tilted spectrum, two formants drifting
	 * across the mids, per-band shimmer, and a kick that lands on the beat.
	 */
	private renderSynthetic(t: number) {
		const bpm = 104;
		const beats = (t * bpm) / 60;
		const phase = beats % 1;
		const bar = Math.floor(beats) % 4;
		const kick = Math.exp(-phase * 7) * (bar === 2 ? 0.75 : 1);
		const snare = bar % 2 === 1 ? Math.exp(-phase * 13) : 0;

		for (let i = 0; i < BAND_COUNT; i++) {
			const f = i / (BAND_COUNT - 1);
			const tilt = Math.pow(1 - f, 1.5) * 0.78 + 0.12;
			const f1 = 0.3 + 0.2 * Math.sin(t * 0.23);
			const f2 = 0.68 + 0.18 * Math.sin(t * 0.17 + 2.1);
			const peak1 = Math.exp(-Math.pow((f - f1) / 0.12, 2));
			const peak2 = Math.exp(-Math.pow((f - f2) / 0.09, 2));
			const shimmer = 0.5 + 0.5 * Math.sin(t * (1.6 + i * 0.29) + i * 1.71);

			let v = tilt * (0.34 + 0.52 * shimmer) + 0.55 * peak1 + 0.34 * peak2;
			v *= 0.62 + 0.5 * kick * (1 - f * 0.75);
			v += snare * 0.42 * Math.exp(-Math.pow((f - 0.55) / 0.3, 2));
			this.synth[i] = clamp01(v * 0.88);
		}

		for (let i = 0; i < WAVE_COUNT; i++) {
			const x = i / WAVE_COUNT;
			this.synthWave[i] =
				(Math.sin(x * Math.PI * 4 - t * 2.4) * 0.5 +
					Math.sin(x * Math.PI * 11 + t * 1.7) * 0.28 +
					Math.sin(x * Math.PI * 23 - t * 3.9) * 0.14) *
				(0.45 + 0.55 * kick);
		}
	}

	/* ------------------------------------------------------------ microphone */

	private readMicrophone() {
		const analyser = this.analyser!;
		const freq = this.freqBytes!;
		const time = this.timeBytes!;
		analyser.getByteFrequencyData(freq as Uint8Array<ArrayBuffer>);
		analyser.getByteTimeDomainData(time as Uint8Array<ArrayBuffer>);

		for (let i = 0; i < BAND_COUNT; i++) {
			const [lo, hi] = this.binRanges[i]!;
			let peak = 0;
			for (let b = lo; b <= hi; b++) peak = Math.max(peak, freq[b]!);
			// Lift the quiet end so a laptop mic still fills the picture.
			this.live[i] = clamp01(Math.pow(peak / 255, 0.78) * 1.35);
		}

		const step = time.length / WAVE_COUNT;
		for (let i = 0; i < WAVE_COUNT; i++) {
			this.liveWave[i] = (time[Math.floor(i * step)]! - 128) / 128;
		}
	}

	async enableMic(): Promise<boolean> {
		this.micError = null;
		if (this.micActive) return true;

		if (!navigator.mediaDevices?.getUserMedia) {
			this.micError = 'This browser can’t open a microphone.';
			this.emit();
			return false;
		}

		try {
			const stream = await navigator.mediaDevices.getUserMedia({
				audio: {
					echoCancellation: false,
					noiseSuppression: false,
					autoGainControl: false,
				},
			});
			const ctx = new AudioContext();
			await ctx.resume();

			const analyser = ctx.createAnalyser();
			analyser.fftSize = 2048;
			analyser.smoothingTimeConstant = 0.72;
			ctx.createMediaStreamSource(stream).connect(analyser);

			this.stream = stream;
			this.ctx = ctx;
			this.analyser = analyser;
			this.freqBytes = new Uint8Array(analyser.frequencyBinCount);
			this.timeBytes = new Uint8Array(analyser.fftSize);
			this.binRanges = buildLogBins(analyser.frequencyBinCount, ctx.sampleRate, analyser.fftSize);
			this.micActive = true;
			this.emit();
			return true;
		} catch {
			this.micError = 'Microphone blocked. Allow access in your browser, then try again.';
			this.emit();
			return false;
		}
	}

	disableMic() {
		this.stream?.getTracks().forEach((track) => track.stop());
		void this.ctx?.close();
		this.stream = null;
		this.ctx = null;
		this.analyser = null;
		this.micActive = false;
		this.micError = null;
		this.live.fill(0);
		this.liveWave.fill(0);
		this.emit();
	}

	toggleMic() {
		return this.micActive ? (this.disableMic(), Promise.resolve(false)) : this.enableMic();
	}
}

/** Map FFT bins onto 64 log-spaced bands between 30 Hz and 16 kHz. */
function buildLogBins(binCount: number, sampleRate: number, fftSize: number) {
	const ranges: Array<[number, number]> = [];
	const nyquistBin = binCount - 1;
	for (let i = 0; i < BAND_COUNT; i++) {
		const lo = F_LOW * Math.pow(F_HIGH / F_LOW, i / BAND_COUNT);
		const hi = F_LOW * Math.pow(F_HIGH / F_LOW, (i + 1) / BAND_COUNT);
		const binLo = Math.min(nyquistBin, Math.floor((lo * fftSize) / sampleRate));
		const binHi = Math.min(nyquistBin, Math.max(binLo, Math.floor((hi * fftSize) / sampleRate)));
		ranges.push([binLo, binHi]);
	}
	return ranges;
}

export const signal = new Signal();

/* ------------------------------------------------------------------- clock */

type Frame = (dt: number) => void;
const frames = new Set<Frame>();
let running = false;
let last = 0;

/** Register a per-frame callback. Returns an unsubscribe function. */
export function onFrame(fn: Frame) {
	frames.add(fn);
	return () => frames.delete(fn);
}

function tick(now: number) {
	if (!running) return;
	const dt = Math.min(0.05, (now - last) / 1000 || 0.016);
	last = now;
	signal.update(dt);
	for (const fn of frames) fn(dt);
	requestAnimationFrame(tick);
}

export function startClock() {
	if (running) return;
	running = true;
	last = performance.now();
	requestAnimationFrame(tick);
}

export function stopClock() {
	running = false;
}

export function isClockRunning() {
	return running;
}

/** Draw one frame's worth of state without starting the loop. */
export function primeStatic(seconds = 1.7) {
	for (let i = 0; i < 120; i++) signal.update(seconds / 120);
	for (const fn of frames) fn(0);
}
