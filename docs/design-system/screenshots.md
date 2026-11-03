# Screenshots and the screen harness (task S0d)

Screens are looked at before review (skill `letflow-design-system`, rule 8). The harness renders a named screen
with fixture data, without login or a backend; `web/scripts/screenshot.sh` photographs it with headless Firefox.

## The harness route

`/__harness/<screen>?theme=light|dark&lang=en|ru|kk&state=default|empty|loading|error` in the Vite dev server.
An unknown value falls back to `light`, `en`, `default`; an unknown screen lists the registered ones.

- **Dev only.** `router.tsx` adds the route inside `import.meta.env.DEV`, a build-time constant, so the production
  bundle has neither the route nor the `web/src/dev/harness/` modules. `web/src/dev/harness/__tests__/harness.build.test.ts`
  builds the app (as `npm run build` does) and fails if any built file contains a harness string.
- **Data seam.** While a harness screen is mounted `window.fetch` is answered from the screen's fixture routes
  (`fixtureFetch.ts`); the screen, the API client and the query layer are the production code. `loading` never
  answers, `error` answers 500, `empty` and `default` are what the fixture's `reply(state)` returns. A request no
  fixture matches gets 404 and a console warning. The real `fetch` comes back on unmount.
- **Theme and language.** `data-theme` and `lang` are set on `<html>` only; the stored theme (`lf-theme`) is not
  written. A screen that has its own i18n provider reads `lang` in its `render({ lang, state })`; screens that
  resolve the locale from `navigator.languages` ignore it until they are given the harness language.
- **Router.** The app's router is already mounted, so the harness gives the screen's location to `<Routes location>`
  instead of nesting a second router. `initialPath` is the URL the screen expects (`/verify/demo-handle`),
  `routePattern` its route (`/verify/:handle`).
- **Ready signal.** `firefox --screenshot` fires on the page's load event. In the dev server only,
  `harnessGatePlugin` (`web/vite.config.ts`) adds a hidden iframe to harness pages whose document is held until
  the harness reports it has drawn and its fixture requests have settled (`readySignal.ts`; 3 s cap for the
  never-answering loading state, 10 s cap on the server).

## Adding a screen

Add one entry to `web/src/dev/harness/registry.tsx`: `name`, `initialPath` / `routePattern` if it reads route params,
`routes` (the API calls it makes, with a reply per state), `render`. Worked example: `verify-certificate`
(`VerifyCertificatePage`, a public page that reads `GET /api/public/certificate/:handle`). Fixture data is plain
invented data: no real names, ids or secrets.

Registered screens: `verify-certificate`; `org-legal`, `org-sites`, `org-units`, `org-positions`, `org-employees` (S1, S2, `web/src/dev/harness/orgFixtures.tsx`: the org module screens with an auth and access stub; in the default state the harness opens one record in the detail panel). A fixture route's `reply(state, path, body)` gets the parsed JSON request body, so one fake `POST /api/v1/entities/query` can answer by `entity_type`.

## Taking screenshots

```
web/scripts/screenshot.sh <screen> <out.png> [width] [height]    # 1440x900 by default
LF_SHOT_THEME=dark LF_SHOT_LANG=ru LF_SHOT_STATE=empty web/scripts/screenshot.sh <screen> out.png 390 844
web/scripts/screenshot.sh --all <screen> [state]                 # 1440 and 390 x light, dark x en, ru, kk
```

`--all` writes `<screen>-<lang if not en>-<theme>-<width>.png` into `$TEAM_TASKDIR/shots/` (`./shots` when the
variable is unset): 12 files, for example `verify-certificate-ru-dark-390.png`.

The script starts `vite` on a free port, waits (60 s) until it answers, runs Firefox with
`--headless --no-remote --profile <fresh temp dir>` (never the default profile; the owner's Firefox is running) under
`timeout 90`, then stops the dev server (its whole process group) and removes the temp profile, also on failure or
interrupt. One Firefox at a time. It installs nothing; `npm ci` in `web/` must have been run. Read the PNGs with the
file-reading tool and compare with the style guide before review.
