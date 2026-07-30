// @ts-check
import { defineConfig, fontProviders } from "astro/config";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";

// https://astro.build/config
export default defineConfig({
  // The production domain. Canonical URLs, Open Graph tags, the JSON-LD graph
  // and the sitemap are all derived from this, so it has to be right before a
  // deploy — it is not inferred from where the build ends up.
  site: "https://synesthia.app",
  integrations: [
    sitemap({
      // Three URLs, and the landing page is the one that matters. Left to
      // itself the sitemap emits neither hint at all; this at least says which
      // page is the site and which two are reference material behind it.
      changefreq: "monthly",
      priority: 0.5,
      serialize(item) {
        if (new URL(item.url).pathname === "/") item.priority = 1;
        return item;
      },
    }),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
  fonts: [
    {
      // Display face. A Swedish grotesque — warmer and less corporate than
      // the usual Inter/Archivo default, but sober enough at 600 to carry a
      // product page that is meant to stay out of the app's way.
      // One weight, because the page only ever sets one: every `.display`,
      // `.h3` and wordmark is 600. 500 and 700 were downloaded and preloaded on
      // every visit without a single rule asking for them.
      provider: fontProviders.google(),
      name: "Familjen Grotesk",
      cssVariable: "--font-familjen",
      weights: [600],
      styles: ["normal"],
      subsets: ["latin"],
      fallbacks: ["Helvetica Neue", "Helvetica", "sans-serif"],
    },
    {
      provider: fontProviders.google(),
      name: "IBM Plex Sans",
      cssVariable: "--font-plex",
      weights: [400, 500, 600],
      styles: ["normal"],
      subsets: ["latin"],
      fallbacks: ["Helvetica Neue", "sans-serif"],
    },
    {
      provider: fontProviders.google(),
      name: "IBM Plex Mono",
      cssVariable: "--font-plex-mono",
      weights: [400, 500],
      styles: ["normal"],
      subsets: ["latin"],
      fallbacks: ["ui-monospace", "monospace"],
    },
  ],
});
