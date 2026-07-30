/**
 * The landing page's JavaScript: reveal sections as they scroll in, drive the
 * hero carousel, and open screenshots full size.
 *
 * There used to be a canvas re-implementation of the visualizers here, plus a
 * microphone demo. Both are gone — the page now shows real captures of the app
 * instead of an approximation of it.
 *
 * Analytics lives in `analytics.ts`, which the layout loads on every page. Only
 * the carousel's events are emitted from here, because only this file knows
 * which slide is showing and whose doing it was.
 */
import { track } from "./analytics";

document.documentElement.classList.add("js");

/* ------------------------------------------------------------------ reveal */

const reveal = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("is-in");
      reveal.unobserve(entry.target);
    }
  },
  { rootMargin: "0px 0px -6% 0px" },
);

for (const el of document.querySelectorAll("[data-reveal]")) {
  reveal.observe(el);
}

/* ---------------------------------------------------------------- carousel */

const calm = window.matchMedia("(prefers-reduced-motion: reduce)");

/**
 * Whether a screenshot is open full size.
 *
 * The carousel has to know: opening the viewer moves focus to the dialog, which
 * is a `focusout` as far as the carousel root is concerned, so its hover-pause
 * releases and autoplay resumes behind the modal. Close the viewer four seconds
 * later and you are looking at a different visualizer than the one you clicked.
 * `lightboxchange` is fired by initLightbox on both edges.
 */
const zoomed = () => document.querySelector("dialog.lightbox[open]") !== null;

function initCarousel(root: HTMLElement) {
  const stage = root.querySelector<HTMLElement>(".carousel-stage");
  const slides = [...root.querySelectorAll<HTMLElement>(".carousel-slide")];
  const tabs = [...root.querySelectorAll<HTMLButtonElement>("[data-tab]")];
  const toggle = root.querySelector<HTMLButtonElement>(
    "[data-carousel-toggle]",
  );
  const toggleLabel = root.querySelector<HTMLElement>(
    "[data-carousel-toggle-label]",
  );
  if (slides.length < 2 || tabs.length !== slides.length) return;

  const interval = Number(root.dataset.interval) || 4600;
  let index = 0;
  let timer: number | undefined;
  // Autoplay only runs while the hero is on screen, the tab is in front, the
  // pointer is elsewhere, and the visitor hasn't taken the wheel themselves.
  let visible = true;
  let held = false;
  // Explicitly stopped — by the stop button, or by picking a slide by hand.
  // Kept apart from the transient pauses above because it is the only one the
  // control reflects, and the only one that never resolves on its own.
  let stopped = false;

  const nameOf = (i: number) => tabs[i]?.dataset.slide ?? String(i);

  const show = (next: number) => {
    index = (next + slides.length) % slides.length;
    slides.forEach((slide, i) => {
      slide.toggleAttribute("data-active", i === index);
      slide.setAttribute("aria-hidden", i === index ? "false" : "true");
      // Each slide contains a link to its full-size capture. The inactive ones
      // are transparent rather than gone, so without `inert` the Tab key walks
      // straight into links nobody can see.
      slide.toggleAttribute("inert", i !== index);
    });
    tabs.forEach((tab, i) => {
      tab.setAttribute("aria-selected", i === index ? "true" : "false");
      tab.tabIndex = i === index ? 0 : -1;
    });
  };

  const sync = () => {
    const run =
      visible &&
      !held &&
      !stopped &&
      !calm.matches &&
      !document.hidden &&
      !zoomed();

    if (run && timer === undefined) {
      timer = window.setInterval(() => show(index + 1), interval);
    } else if (!run && timer !== undefined) {
      clearInterval(timer);
      timer = undefined;
    }

    root.toggleAttribute("data-paused", stopped);
    if (toggleLabel) toggleLabel.textContent = stopped ? "Play" : "Pause";
    if (toggle) {
      toggle.setAttribute(
        "aria-label",
        stopped
          ? "Play the visualizer slideshow"
          : "Pause the visualizer slideshow",
      );
      // Nothing to stop when the visitor has asked for less motion: autoplay
      // never starts, so offering to pause it would be a lie and offering to
      // start it would override the preference.
      toggle.hidden = calm.matches;
    }
    // Announce slide changes only when they are the visitor's own doing. A live
    // region that speaks every 4.6 seconds by itself is unusable.
    stage?.setAttribute("aria-live", stopped ? "polite" : "off");
  };

  const stop = () => {
    stopped = true;
    sync();
  };

  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => {
      stop();
      show(i);
      track("select_visualizer", { visualizer: nameOf(i), method: "tab" });
    });
    tab.addEventListener("keydown", (event) => {
      const step =
        event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
      if (!step) return;
      event.preventDefault();
      stop();
      show(index + step);
      tabs[index].focus();
      track("select_visualizer", {
        visualizer: nameOf(index),
        method: "keyboard",
      });
    });
  });

  toggle?.addEventListener("click", () => {
    stopped = !stopped;
    sync();
    track("carousel_toggle", { state: stopped ? "paused" : "playing" });
  });

  for (const event of ["pointerenter", "focusin"] as const) {
    root.addEventListener(event, () => {
      held = true;
      sync();
    });
  }
  for (const event of ["pointerleave", "focusout"] as const) {
    root.addEventListener(event, () => {
      held = false;
      sync();
    });
  }

  document.addEventListener("visibilitychange", sync);
  document.addEventListener("lightboxchange", sync);
  calm.addEventListener("change", sync);

  new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      sync();
    },
    { threshold: 0.2 },
  ).observe(root);

  sync();
}

for (const el of document.querySelectorAll<HTMLElement>("[data-carousel]")) {
  initCarousel(el);
}

/* ---------------------------------------------------------------- lightbox */

/**
 * Open a screenshot full size in the page's single `<dialog>`.
 *
 * The links work without any of this — each one points at the full-resolution
 * transform — so everything here is an upgrade over a navigation, and every
 * path that isn't a plain left click is left alone: ⌘-click, middle-click and
 * "Open image in new tab" should still do what the visitor expects.
 */
function initLightbox() {
  const dialog = document.querySelector<HTMLDialogElement>(
    "[data-lightbox-dialog]",
  );
  // No `showModal` means no focus trap and no Escape, and a half-working modal
  // is worse than the plain link it replaced.
  if (!dialog || typeof dialog.showModal !== "function") return;

  const image = dialog.querySelector<HTMLImageElement>("[data-lightbox-image]");
  const label = dialog.querySelector<HTMLElement>("[data-lightbox-label]");
  const original = dialog.querySelector<HTMLAnchorElement>(
    "[data-lightbox-original]",
  );
  if (!image || !label || !original) return;

  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
      return;

    const target = event.target;
    if (!(target instanceof Element)) return;
    const link = target.closest<HTMLAnchorElement>("a[data-lightbox]");
    if (!link) return;

    event.preventDefault();

    // The caption names the shot; the image inside the link already carries the
    // long description, so reuse it rather than writing it twice.
    const source = link.querySelector("img");
    image.src = link.href;
    image.alt = source?.alt ?? "";
    label.textContent = link.dataset.label ?? "";
    original.href = link.href;

    dialog.showModal();
    document.dispatchEvent(new Event("lightboxchange"));
  });

  // Clicking the padding around the figure closes it — the dialog element is
  // the only thing under the pointer out there.
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) dialog.close();
  });

  dialog
    .querySelector("[data-lightbox-close]")
    ?.addEventListener("click", () => dialog.close());

  // Drop the decoded image when the viewer closes. Holding several megapixels
  // of AVIF for a dialog nobody is looking at is pure resident memory.
  dialog.addEventListener("close", () => {
    image.removeAttribute("src");
    image.alt = "";
    document.dispatchEvent(new Event("lightboxchange"));
  });
}

initLightbox();
