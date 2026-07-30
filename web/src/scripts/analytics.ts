/**
 * Behavioural analytics on top of the GA4 page view.
 *
 * The tag itself is bootstrapped in `components/Analytics.astro`, which is also
 * where the opt-out check lives: it sets `<html data-analytics="on">` only if it
 * actually loaded gtag.js. Everything here reads that flag, so a visitor with Do
 * Not Track or Global Privacy Control set has no listeners attached at all —
 * not listeners that quietly drop their events.
 *
 * This module is loaded from `layouts/Base.astro`, so it runs on every page,
 * including the legal ones (which have no other JavaScript). `boot.ts` imports
 * `track` from here for the two events only the carousel can know about.
 *
 * What is measured, and why:
 *
 *   download_click  the conversion. Which channel, and which of the three
 *                   buttons on the page produced it.
 *   outbound_click  GitHub, Apple, Google — where the page leaks attention to.
 *   contact_click   mailto: on the support and privacy pages.
 *   nav_click       in-page anchors; tells you which section people go looking
 *                   for rather than which one they scroll past.
 *   section_view    the same question answered by scroll: what got seen.
 *   scroll_depth    how far down a one-page pitch actually gets read.
 *   select_visualizer  which of the three hero shots people choose to look at.
 *   web_vitals      LCP/CLS/INP from real visitors, since a single-page site has
 *                   no other way to notice a regression.
 *
 * None of these carry anything about the visitor — no ids, no text they typed,
 * no query strings. `link_text` is the label of our own link.
 */
import { RELEASE } from "../consts";

declare global {
  interface Window {
    dataLayer?: unknown[];
    gtag?: (...args: unknown[]) => void;
    /** Set once, so a duplicated bundle can't double-count every event. */
    __synesthiaAnalytics?: boolean;
  }
}

type Params = Record<string, string | number | boolean>;

const ENABLED = document.documentElement.dataset.analytics === "on";

/** Fire a GA4 event, or do nothing at all if analytics never loaded. */
export function track(name: string, params: Params = {}): void {
  if (!ENABLED) return;
  window.gtag?.("event", name, params);
}

/* ------------------------------------------------------------------- clicks */

/** Where on the page a link lives, for attributing the click. */
function placementOf(link: Element): string {
  const explicit = (link as HTMLElement).dataset.placement;
  if (explicit) return explicit;
  if (link.closest("header")) return "header";
  if (link.closest("footer")) return "footer";
  return "body";
}

function onLinkActivate(event: Event): void {
  const target = event.target;
  if (!(target instanceof Element)) return;

  const link = target.closest<HTMLAnchorElement>("a[href]");
  if (!link) return;

  // A middle click is a real visit; a right click is not.
  if (
    event instanceof MouseEvent &&
    event.type === "auxclick" &&
    event.button !== 1
  ) {
    return;
  }

  let url: URL;
  try {
    url = new URL(link.href, location.href);
  } catch {
    return;
  }

  const channel = link.dataset.downloadLink;
  if (channel) {
    // Deliberately not GA4's automatic `file_download`: that only fires for
    // same-origin links ending in a known extension, and neither channel
    // qualifies — the App Store button leaves the site, and `/download` is a
    // redirect with no extension. One event name for both keeps "downloads"
    // a single number instead of a sum of two.
    track("download_click", {
      channel: channel === "app-store" ? "app_store" : "direct",
      placement: placementOf(link),
      release_version: RELEASE.version,
      link_url: url.href,
    });
    return;
  }

  if (url.protocol === "mailto:") {
    track("contact_click", {
      address: url.pathname,
      placement: placementOf(link),
    });
    return;
  }

  if (url.origin === location.origin) {
    // An in-page anchor, as opposed to navigating to another page.
    if (url.hash && url.pathname === location.pathname) {
      track("nav_click", {
        target: url.hash,
        placement: placementOf(link),
      });
    }
    return;
  }

  if (url.protocol === "http:" || url.protocol === "https:") {
    track("outbound_click", {
      link_url: url.href,
      link_domain: url.hostname,
      link_text: (link.textContent ?? "").trim().slice(0, 80),
      placement: placementOf(link),
    });
  }
}

/* ------------------------------------------------------------- what got seen */

function watchSections(): void {
  const sections = document.querySelectorAll<HTMLElement>("main section[id]");
  if (!sections.length) return;

  const seen = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        seen.unobserve(entry.target);
        track("section_view", { section: entry.target.id });
      }
    },
    // A section only counts once a fifth of the viewport is inside it, so a
    // fast scroll to the footer doesn't report every section as read.
    { rootMargin: "0px 0px -20% 0px" },
  );

  for (const section of sections) seen.observe(section);
}

function watchScrollDepth(): void {
  const marks = [25, 50, 75, 90];
  let next = 0;
  let queued = false;

  const measure = () => {
    queued = false;
    const reach = document.documentElement.scrollHeight - window.innerHeight;
    if (reach <= 0) return;

    const percent = (window.scrollY / reach) * 100;
    while (next < marks.length && percent >= marks[next]) {
      track("scroll_depth", { percent: marks[next] });
      next += 1;
    }
    if (next >= marks.length) {
      window.removeEventListener("scroll", onScroll);
    }
  };

  const onScroll = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(measure);
  };

  window.addEventListener("scroll", onScroll, { passive: true });
}

/* -------------------------------------------------------------- web vitals */

/**
 * LCP, CLS and INP from the PerformanceObserver entries they are defined on.
 *
 * Hand-rolled rather than pulling in `web-vitals`: three metrics on a static
 * page is about forty lines, and the library would be the only runtime
 * dependency the site has. The trade is that these are the straightforward
 * readings — CLS uses the standard session-window algorithm, but INP reports
 * the worst interaction rather than the p98 the official metric specifies,
 * which on a page with a carousel and nothing else is the same interaction.
 */
function watchVitals(): void {
  if (!("PerformanceObserver" in window)) return;

  interface ShiftEntry extends PerformanceEntry {
    value: number;
    hadRecentInput: boolean;
  }

  const observe = (
    type: string,
    handle: (entries: PerformanceEntry[]) => void,
    extra: Record<string, unknown> = {},
  ) => {
    try {
      const observer = new PerformanceObserver((list) =>
        handle(list.getEntries()),
      );
      observer.observe({ type, buffered: true, ...extra });
    } catch {
      // An engine that doesn't know the entry type throws; that metric is
      // simply not reported.
    }
  };

  let lcp = 0;
  observe("largest-contentful-paint", (entries) => {
    const last = entries[entries.length - 1];
    if (last) lcp = last.startTime;
  });

  // CLS is the largest burst of shifts, not the total: a session window closes
  // after a 1 s gap or 5 s of continuous shifting.
  let cls = 0;
  let window_ = 0;
  let windowStart = 0;
  let lastShift = 0;
  observe("layout-shift", (entries) => {
    for (const entry of entries as ShiftEntry[]) {
      if (entry.hadRecentInput) continue;
      const continues =
        window_ > 0 &&
        entry.startTime - lastShift < 1000 &&
        entry.startTime - windowStart < 5000;
      if (continues) {
        window_ += entry.value;
      } else {
        window_ = entry.value;
        windowStart = entry.startTime;
      }
      lastShift = entry.startTime;
      cls = Math.max(cls, window_);
    }
  });

  let inp = 0;
  observe(
    "event",
    (entries) => {
      for (const entry of entries) {
        if (entry.duration > inp) inp = entry.duration;
      }
    },
    { durationThreshold: 40 },
  );

  const sent = new Set<string>();
  const report = (name: string, value: number, good: number, poor: number) => {
    if (sent.has(name)) return;
    sent.add(name);
    track("web_vitals", {
      metric_name: name,
      // CLS is unitless and tiny; ×1000 keeps it a useful integer in reports
      // that assume milliseconds. Divide by 1000 when reading CLS back.
      metric_value: Math.round(name === "CLS" ? value * 1000 : value),
      metric_rating:
        value <= good ? "good" : value <= poor ? "needs_improvement" : "poor",
      value: Math.round(name === "CLS" ? value * 1000 : value),
    });
  };

  // Vitals are only final when the visit is. `visibilitychange` is the reliable
  // signal; `pagehide` covers the browsers that skip it on navigation.
  const flush = () => {
    if (lcp > 0) report("LCP", lcp, 2500, 4000);
    report("CLS", cls, 0.1, 0.25);
    if (inp > 0) report("INP", inp, 200, 500);
  };

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flush();
  });
  window.addEventListener("pagehide", flush);
}

/* ------------------------------------------------------------------- install */

if (ENABLED && !window.__synesthiaAnalytics) {
  window.__synesthiaAnalytics = true;

  // Capture, so a handler that stops propagation can't hide a click from us.
  document.addEventListener("click", onLinkActivate, { capture: true });
  document.addEventListener("auxclick", onLinkActivate, { capture: true });

  watchSections();
  watchScrollDepth();
  watchVitals();
}
