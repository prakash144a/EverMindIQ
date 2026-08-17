import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    sourcemap: false,
    rollupOptions: {
      output: {
        // Firebase and Recharts are large and change far less often than the
        // console itself, so keeping them separate means an ordinary UI change
        // does not invalidate a 600 kB download.
        manualChunks: {
          firebase: ["firebase/app", "firebase/auth"],
          charts: ["recharts"],
        },
      },
    },
  },
  server: {
    port: 5173,
    // The backend allows this origin explicitly in production via
    // VOICEIQ_CORS_ORIGINS; locally it defaults to "*".
    strictPort: true,
  },
});
