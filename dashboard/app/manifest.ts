import type { MetadataRoute } from "next";

/**
 * Lets the control room be added to a phone's home screen and open full screen, like an app.
 * It opens on Today. Nothing is cached offline: the numbers are always live.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "SBM Partners",
    short_name: "SBM",
    description: "What the agents are doing today, and what is waiting for you.",
    start_url: "/",
    scope: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#f4f7fb",
    theme_color: "#f4f7fb",
    icons: [
      { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
