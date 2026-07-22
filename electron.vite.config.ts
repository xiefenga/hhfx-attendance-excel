import react from "@vitejs/plugin-react";
import { defineConfig } from "electron-vite";

export default defineConfig(({ command }) => {
  const isDevelopment = command === "serve";

  return {
    main: {},
    preload: {},
    renderer: {
      base: "./",
      build: {
        minify: "esbuild"
      },
      plugins: [
        react(),
        {
          name: "attendance-development-csp",
          transformIndexHtml(html) {
            if (!isDevelopment) {
              return html;
            }
            return html
              .replace("script-src 'self'", "script-src 'self' 'unsafe-inline'")
              .replace(
                "connect-src 'self'",
                "connect-src 'self' ws://localhost:* http://localhost:*"
              );
          }
        }
      ]
    }
  };
});
