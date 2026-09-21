import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // El backend de Python sirve esta carpeta en produccion.
  build: { outDir: "dist" },
  server: {
    port: 5173,
    // En desarrollo, /api va al backend de Python. Asi el frontend se recarga
    // solo sin tener que recompilar nada del lado del servidor.
    proxy: { "/api": { target: "http://localhost:8080", changeOrigin: true } },
  },
});
