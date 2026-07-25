/**
 * The whole of the page's JavaScript: reveal sections as they scroll in, once.
 *
 * There used to be a canvas re-implementation of the visualizers here, plus a
 * microphone demo. Both are gone — the page now shows real captures of the app
 * instead of an approximation of it.
 */

document.documentElement.classList.add('js');

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
