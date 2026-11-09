# Self-hosted zxing-wasm (PWA M4)

The web build's barcode fallback. `mobile_scanner` on web uses the browser's own
`BarcodeDetector` when there is one (Safari 17+, Chrome on Android) and zxing-wasm
otherwise. By default the package loads zxing-wasm from `cdn.jsdelivr.net`; D-112 allows no
CDN, so the files are served by the app itself from this folder.

- Package: `zxing-wasm` 3.1.6 (MIT, see `LICENSE`). This is exactly `zxingWasmVersion` in
  `mobile_scanner` 7.5.0 (`lib/src/web/web_library_versions.dart`).
- `zxing-reader.iife.js` = `package/dist/iife/reader/index.js`
  sha256 `ffd72d59d54082194f7c086b384dcd930bdeb0c5b39fbb13779694e69bb0d344`
- `zxing_reader.wasm` = `package/dist/reader/zxing_reader.wasm`
  sha256 `5003fb4b88c4fbd1fd518a2fd8c8ad365c519e183a08c03a322dddfea3cea84e`
- `zxing-config.js` (ours): points the bundle's `locateFile` at `zxing/zxing_reader.wasm`
  relative to `document.baseURI`, so a non-root `--base-href` works too.

`web/index.html` loads the bundle with `id="mobile-scanner-zxing-wasm"` (the package's
`ZXingWasmBarcodeReader.scriptId`). The package sees the tag and does not inject its CDN
script. The WASM file is fetched only on the first zxing decode.

## Refresh (when `mobile_scanner` is bumped)

1. Read the new `zxingWasmVersion` in the package's `web_library_versions.dart`.
2. In an empty scratch folder: `npm pack zxing-wasm@<version> --ignore-scripts`, then
   `tar xzf zxing-wasm-<version>.tgz`.
3. Copy the two files above (and `LICENSE`) here, update the version and both sha256 lines.
4. Update the pinned versions in `test/guards/web_zxing_selfhost_test.dart` and run
   `flutter test test/guards/web_zxing_selfhost_test.dart test/guards/web_zxing_runtime_test.dart`.
