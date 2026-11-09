// Loads the zxing WASM file from this app, not from the bundle's default CDN (PWA M4, D-112).
ZXingWASM.setZXingModuleOverrides({
  locateFile: (path, prefix) =>
    path.endsWith('.wasm') ? new URL('zxing/zxing_reader.wasm', document.baseURI).href : prefix + path,
});
