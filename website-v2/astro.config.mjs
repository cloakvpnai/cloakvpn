import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';

// Lattice VPN marketing site.
// Static build, deploys to Cloudflare Pages.
// See website/ for the legacy holo-glass site until this V2 fully replaces it.
export default defineConfig({
  site: 'https://latticevpn.ai',
  output: 'static',
  integrations: [tailwind({ applyBaseStyles: false })],
  build: {
    inlineStylesheets: 'auto',
  },
  vite: {
    ssr: { noExternal: ['gsap', 'three'] },
  },
});
