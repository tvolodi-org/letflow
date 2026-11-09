{{flutter_js}}
{{flutter_build_config}}

// PWA M5 (D-112): no third-party host at runtime. Glyphs outside the bundled Roboto are asked
// from this origin (the server answers 404), never from fonts.gstatic.com.
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    fontFallbackBaseUrl: new URL('fonts-fallback/', document.baseURI).href,
  },
});
