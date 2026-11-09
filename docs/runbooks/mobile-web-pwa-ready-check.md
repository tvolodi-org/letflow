# PWA client test kit and "ready for clients" check (M6, D-112)

The owner's clients try the PWA on their own iPhones; the owner contacts them. The team sends nothing to clients.
The link goes out **only after `scripts/pwa_ready_check.sh` prints `ready-check: GREEN`**.

## The kit (`docs/runbooks/pwa-client-test/`)

- `script.en.md`, `script.ru.md`, `script.kk.md`: one-page client script (7 steps: install from Safari, log in, scan 3 codes,
  voice note, work offline once, send feedback, report problems). Button names are the app's own wording from
  `apps/mobile/lib/i18n/l10n/app_*.arb`. Placeholders: `@@LINK@@`, `@@OWNER_EMAIL@@`.
- Feedback route, no accounts: a pre-filled `mailto:` link, or a reply on the messenger the client got the link on.
  There is no server route and no in-app form.
- `result-template.md`: one per client, for the owner.

Fill in the placeholders (outside git, nothing is sent):

    bash scripts/pwa_client_kit_render.sh --link https://HOST/ --email OWNER@ADDRESS --out /tmp/client-kit

The owner's address is not stored in the repository. The script exits 2 on a non-https link, a bad address or a non-empty
output directory.

## The check

    bash scripts/pwa_ready_check.sh --url https://HOST/ --build-dir build/pwa-extracted --emulate \
      --attest login,scan,voice,offline,sync --device "Pixel 7 Chrome 130" --operator NAME

1. **HTTPS probes (A1..A8, A9 with `--build-dir`)**: index, manifest, `build-info.json` (https API address), wasm served as
   `application/wasm`, `/fonts-fallback/` a real 404, `Permissions-Policy` with camera and microphone, no other host, and
   `pwa_web_verify.sh` on the build. A redirect counts as a failure.
2. **Emulation (`--emulate`, needs `flutter`)**: runs the Flutter tests for login (`test/auth/web_app_auth_adapter_test.dart`),
   scan (`test/features/codes/scan_screen_test.dart`, `test/features/codes/camera_phase_test.dart`,
   `test/guards/web_zxing_runtime_test.dart`), voice (`test/features/stock/web_voice_source_test.dart`,
   `test/features/stock/voice_codec_test.dart`) and offline queue and sync (`test/offline/offline_queue_test.dart`,
   `test/offline/offline_sync_test.dart`). They prove the logic, not Safari.
3. **Device pass (by hand, then `--attest`)**: camera, microphone and airplane mode cannot be scripted. Do the client script
   yourself on the HTTPS link on the best device you have, in this order of preference:
   1. a real iPhone with Safari;
   2. a real Android phone with Chrome (real camera, microphone and airplane mode; does not prove Safari);
   3. desktop Chrome started with `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`, with DevTools
      Network set to Offline.

   Then pass all five keys `login,scan,voice,offline,sync` plus `--device` and `--operator`.

Verdict (last output line): `GREEN` (exit 0) only when every probe passed, the emulation ran and passed, and the full
attestation was given; `RED` (exit 1) when anything failed; `INCOMPLETE <what is missing>` (exit 3) otherwise.
The script never takes a password and logs in nowhere.

**Honest limit:** without an iPhone, GREEN means "an Android or desktop device plus emulation", not "works on Safari". The
first clients' result templates are the Safari proof. iOS limits the clients meet: camera only over HTTPS after a tap, no
hardware scanners, saved data may be cleared after 7 days unused if not installed, no background sync (offline drafts are
sent when the app is opened), no push.

## Operator check steps (not run by the team)

- [ ] Run the check against the deployed QA host (needs the URL and a device).
- [ ] Send the link only after GREEN; keep the printed device, operator and time with the result templates.
