# Letflow platform design system in `web/`

The values (colours, type, space, component CSS, logos) are made in the separate design repo
`letflow-design` (decisions D-080, D-081). `web/` only receives generated files. Nobody edits them by
hand; to change a value, change the design repo first and refresh.

## Where the files came from

| File in this repo | Source (design repo) |
|---|---|
| `web/src/styles/tokens.css` | `platform/tokens.css`, generated from `tokens.json` by `core/tools/build_tokens.py` |
| `web/src/styles/components.css` | `platform/style-guide/components.css` |
| `web/public/brand/*` (logos, app icons, og image) | `core/brand/` |

## Refresh

```
cd <path to>/letflow-design
python3 -I core/tools/build_tokens.py platform --check     # must say "up to date"
core/tools/release.sh platform "$(mktemp -d)"              # note the directory it prints
cp <dir>/css/tokens.css <dir>/css/components.css <repo>/web/src/styles/
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
- Geologica, Onest and IBM Plex Mono are loaded from Google Fonts in `web/index.html` (with preconnect).
- Tenant branding is unchanged for now: it still writes `--color-brand-600` (an alias of `--current` in the bridge).
  Moving it to `--tenant-current` is task S0e.

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
