/// Features: per-module code, one subdirectory per module id
/// (`lib/features/<id>/`), mirroring `web/src/modules/<id>/`
/// (`docs/mobile/architecture.md` §6). No module code lives outside its
/// own `features/<id>/` subtree; `module_manifest.json` next to this file
/// declares each feature's `depends_on` list, enforced by
/// `test/guards/module_boundary_guard_test.dart`.
///
/// First module: `codes` (REQ-732), the camera scan of barcodes and QR codes.
/// Second module: `stock` (phase D, D3s), a skeleton with an empty state.
library;
