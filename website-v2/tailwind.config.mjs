/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
  theme: {
    extend: {
      colors: {
        // Lattice brand palette — mirrors the iOS LatticeDesign system.
        mint:  { 300: '#A5F0D2', 400: '#7EE5C2', 500: '#5FE3B5', 600: '#3FCFA0', 700: '#2A9876', 800: '#1F7559' },
        amber: { 300: '#FFCC7A', 400: '#FFB347', 500: '#FF9E1C', 600: '#E08400', 700: '#B06600', 800: '#854C00' },
        navy:  { 900: '#0A1628', 800: '#0E1F3A', 700: '#132B4F', 600: '#1B3D6B' },
        ink:   { 950: '#040810', 900: '#070C18' },
      },
      fontFamily: {
        // System-first stack — fast loads, native feel.
        // Display: Geist for clean modern marketing copy.
        // Mono: JetBrains Mono for code/identifiers.
        display: ['Geist', 'Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        body: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SF Mono', 'monospace'],
      },
      animation: {
        'pulse-node': 'pulse-node 3s ease-in-out infinite',
        'lattice-rotate': 'lattice-rotate 40s linear infinite',
      },
    },
  },
  plugins: [],
};
