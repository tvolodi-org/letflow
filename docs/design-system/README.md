# Letflow platform design system in `web/`

The values (colours, type, space, component CSS, logos) are made in the separate design repo
`letflow-design` (decisions D-080, D-081). `web/` only receives generated files. Nobody edits them by
hand; to change a value, change the design repo first and refresh.

## Where the files came from

| File in this repo | Source (design repo) |
|---|---|
| `web/src/styles/tokens.css` | `platform/tokens.css`, generated from `tokens.json` by `core/tools/build_tokens.py` |
| `web/src/styles/components.css` | `platform/style-guide/components.css` |
| `web/src/fonts/*` (woff2 files and OFL texts; the `@font-face` urls in `components.css` are `../fonts/...`) | `core/fonts/` |
| `web/public/brand/*` (logos, app icons, og image) | `core/brand/` |

## Refresh

```
cd <path to>/letflow-design
python3 -I core/tools/build_tokens.py platform --check     # must say "up to date"
core/tools/release.sh platform "$(mktemp -d)"              # note the directory it prints
cp <dir>/css/tokens.css <dir>/css/components.css <repo>/web/src/styles/
cp <dir>/fonts/* <repo>/web/src/fonts/
cp <dir>/img/* <repo>/web/public/brand/
```

## Hand-written files next to them

- `web/src/styles/legacy-bridge.css`: the old token names (`--surface-page`, `--color-brand-600`, ...) as aliases of
  the new tokens, for one release (design repo `platform/NOTES.md` section 4). New code uses the new names. Remove the
  file once `web/src/styles/__tests__/legacyBridge.test.ts` has no old name left to list.
- `web/src/styles/base.css`: page ground and body type (sans family).
- Import order in `web/src/main.tsx`: tokens, components, bridge, base.

## Theme and fonts

- `data-theme="light|dark"` on `<html>`; without it the system setting applies. A script in `web/index.html` reads
  `localStorage["lf-theme"]` before first paint; `ThemeToggle` (`web/src/components/ui/ThemeToggle.tsx`) writes both.
- Geologica, Onest and IBM Plex Mono are self-hosted (D-089): `@font-face` in `components.css` points at `web/src/fonts/*.woff2`, which vite emits as hashed, immutable assets in `dist/assets/`. No Google font host is named anywhere in `web/`. The bundled style guide under `/design-system/` carries its own `fonts/` copy (`scripts/sync-design-system.sh`). The static host of `dist/` is outside this repo: it must serve `.woff2` as `font/woff2` with a long cache (hashed names).
- Tenant branding writes `--tenant-current` (and the derived `-strong`, `-tint`, `--tenant-on-current` and the `-dark` set) from
  `primary`; a colour that gives under 4.5:1 for on-current text on paper-raised is refused and the Letflow teal stays.
  `secondary` stays in the allowlist but is unused.


## Data-display components (T-1166)

In `web/src/components/ui/`, styled only by `components.css` classes: `DataTable` (sort, selected, error/retired rows,
density, skeleton rows, empty, load error with retry), `PaginationControls`, `FilterBar` (layout only; chips with
remove; clear only when a filter is active), `StatusPill` (tone + glyph + word), `Tabs`, `TreeView`, `EmptyState`,
`Skeleton`, `Tally`, `Steps`. `StatusBadge` is now a thin wrapper over `StatusPill` until its callers move to a
per-module tone/glyph map. Fixed labels (Previous, Try again, Expand...) have English defaults and a `labels` prop;
the page passes the translated text.

## Behaviour rules

The behaviour rules kept from the retired `docs/frontend/design-system.md` (ConfirmDialog, status, pagination,
FilterBar, DynamicForm mapping, toast timing, process canvas, breakpoints) are in [principles.md](principles.md).

## Gate A style check

The check of the six phase A screens before the owner's Gate A look, with its open items:
[gate-a-style-check.md](gate-a-style-check.md).
