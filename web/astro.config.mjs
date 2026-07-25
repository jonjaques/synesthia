// @ts-check
import { defineConfig, fontProviders } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
	// TODO: replace with the production domain before deploying — canonical URLs,
	// Open Graph tags and the sitemap are all derived from this.
	site: 'https://synesthia.app',
	integrations: [sitemap()],
	vite: {
		plugins: [tailwindcss()],
	},
	fonts: [
		{
			// Display face. A Swedish grotesque — warmer and less corporate than
			// the usual Inter/Archivo default, but sober enough at 600 to carry a
			// product page that is meant to stay out of the app's way.
			provider: fontProviders.google(),
			name: 'Familjen Grotesk',
			cssVariable: '--font-familjen',
			weights: [500, 600, 700],
			styles: ['normal'],
			subsets: ['latin'],
			fallbacks: ['Helvetica Neue', 'Helvetica', 'sans-serif'],
		},
		{
			provider: fontProviders.google(),
			name: 'IBM Plex Sans',
			cssVariable: '--font-plex',
			weights: [400, 500, 600],
			styles: ['normal'],
			subsets: ['latin'],
			fallbacks: ['Helvetica Neue', 'sans-serif'],
		},
		{
			provider: fontProviders.google(),
			name: 'IBM Plex Mono',
			cssVariable: '--font-plex-mono',
			weights: [400, 500],
			styles: ['normal'],
			subsets: ['latin'],
			fallbacks: ['ui-monospace', 'monospace'],
		},
	],
});
