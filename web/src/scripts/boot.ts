/**
 * The whole of the page's JavaScript: reveal sections as they scroll in, and
 * drive the hero carousel.
 *
 * There used to be a canvas re-implementation of the visualizers here, plus a
 * microphone demo. Both are gone — the page now shows real captures of the app
 * instead of an approximation of it.
 */

document.documentElement.classList.add('js');

/* ------------------------------------------------------------------ reveal */

const reveal = new IntersectionObserver(
	(entries) => {
		for (const entry of entries) {
			if (!entry.isIntersecting) continue;
			entry.target.classList.add('is-in');
			reveal.unobserve(entry.target);
		}
	},
	{ rootMargin: '0px 0px -6% 0px' },
);

for (const el of document.querySelectorAll('[data-reveal]')) {
	reveal.observe(el);
}

/* ---------------------------------------------------------------- carousel */

const calm = window.matchMedia('(prefers-reduced-motion: reduce)');

function initCarousel(root: HTMLElement) {
	const slides = [...root.querySelectorAll<HTMLElement>('.carousel-slide')];
	const tabs = [...root.querySelectorAll<HTMLButtonElement>('[data-tab]')];
	if (slides.length < 2 || tabs.length !== slides.length) return;

	const interval = Number(root.dataset.interval) || 4600;
	let index = 0;
	let timer: number | undefined;
	// Autoplay only runs while the hero is on screen, the tab is in front, the
	// pointer is elsewhere, and the visitor hasn't taken the wheel themselves.
	let visible = true;
	let held = false;
	let surrendered = false;

	const show = (next: number) => {
		index = (next + slides.length) % slides.length;
		slides.forEach((slide, i) => {
			slide.toggleAttribute('data-active', i === index);
			slide.setAttribute('aria-hidden', i === index ? 'false' : 'true');
		});
		tabs.forEach((tab, i) => {
			tab.setAttribute('aria-selected', i === index ? 'true' : 'false');
			tab.tabIndex = i === index ? 0 : -1;
		});
	};

	const sync = () => {
		const run = visible && !held && !surrendered && !calm.matches && !document.hidden;
		if (run && timer === undefined) {
			timer = window.setInterval(() => show(index + 1), interval);
		} else if (!run && timer !== undefined) {
			clearInterval(timer);
			timer = undefined;
		}
	};

	tabs.forEach((tab, i) => {
		tab.addEventListener('click', () => {
			surrendered = true;
			sync();
			show(i);
		});
		tab.addEventListener('keydown', (event) => {
			const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
			if (!step) return;
			event.preventDefault();
			surrendered = true;
			sync();
			show(index + step);
			tabs[index].focus();
		});
	});

	for (const event of ['pointerenter', 'focusin'] as const) {
		root.addEventListener(event, () => {
			held = true;
			sync();
		});
	}
	for (const event of ['pointerleave', 'focusout'] as const) {
		root.addEventListener(event, () => {
			held = false;
			sync();
		});
	}

	document.addEventListener('visibilitychange', sync);
	calm.addEventListener('change', sync);

	new IntersectionObserver(
		([entry]) => {
			visible = entry.isIntersecting;
			sync();
		},
		{ threshold: 0.2 },
	).observe(root);

	sync();
}

for (const el of document.querySelectorAll<HTMLElement>('[data-carousel]')) {
	initCarousel(el);
}
