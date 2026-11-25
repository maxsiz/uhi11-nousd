import type { Config } from "tailwindcss";

// noUSD design tokens — the unisafe set, unchanged (design handoff: "No new colors were added").
// The tinted warn/danger fills and lines are the handoff's alpha variants of the same two colors.
const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "#0A0C10",
        s1: "#101319", // cards
        s2: "#161A22", // inputs, chips, nested
        s3: "#1D222C", // tracks, hover, disabled CTA
        line: "rgba(255,255,255,0.07)",
        line2: "rgba(255,255,255,0.11)",
        tx: "#EAEEF4",
        tx2: "#9AA4B2", // secondary text and every label
        tx3: "#626C7A", // placeholders and decoration only (below AA on s1)
        accent: "#34E3AC",
        "accent-soft": "rgba(52,227,172,0.12)",
        "accent-line": "rgba(52,227,172,0.30)",
        "accent-hover": "#7DF0CB",
        warn: "#FFC76B",
        "warn-soft": "rgba(255,199,107,0.07)",
        "warn-line": "rgba(255,199,107,0.35)",
        danger: "#FF7A7A",
        "danger-soft": "rgba(255,122,122,0.07)",
        "danger-line": "rgba(255,122,122,0.35)",
        ink: "#03110C", // text on accent
        "warn-ink": "#1A1200", // text on warn
        chipline: "#0D1015", // ring around overlapping token chips
      },
      fontFamily: {
        display: ["var(--font-display)", "ui-sans-serif", "system-ui", "sans-serif"],
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "SFMono-Regular", "Menlo", "monospace"],
      },
      borderRadius: { card: "16px", modal: "22px" },
      maxWidth: { content: "1160px" },
      boxShadow: {
        cta: "0 6px 20px -8px rgba(52,227,172,0.30)",
        pop: "0 30px 80px -20px rgba(0,0,0,0.7)",
      },
      keyframes: {
        nuPulse: { "0%,100%": { opacity: "1" }, "50%": { opacity: "0.4" } },
        nuRise: {
          from: { opacity: "0", transform: "translate(-50%,10px)" },
          to: { opacity: "1", transform: "translate(-50%,0)" },
        },
      },
      animation: {
        "nu-pulse": "nuPulse 2s ease-in-out infinite",
        "nu-rise": "nuRise .25s ease-out",
      },
    },
  },
  plugins: [],
};

export default config;
