# Mobile app and PWA parity

## Status

This file is docs only. It builds nothing and decides nothing. Whether a gap below is closed in the Android app or in the PWA is a later choice (`docs/uat/ba-decisions/T-1631.md`, item 8). The table is read from the code under `apps/mobile/lib`; it was not run on a device. The device pass (camera, microphone, airplane mode) is `docs/runbooks/mobile-web-pwa-ready-check.md`.

## What is compared

The PWA is not a separate product. It is the web build of the same Flutter code in `apps/mobile` that is built as the Android app (`docs/runbooks/mobile-web-pwa-hosting.md`, first paragraph; plan D-112). So this table compares the Android build with the web build. A difference can only come from a platform branch in the code: a `kIsWeb` check or a conditional import (`if (dart.library.js_interop)`). The two commands below find all of them. Both were run in the repository root on origin/main at commit `3926469bd0b46c56bcdde09d6ada574cee76a26b`, and these are their full outputs.

`grep -rn kIsWeb apps/mobile/lib`

```
apps/mobile/lib/bootstrap/navigation_bootstrap.dart:14:import 'package:flutter/foundation.dart' show kIsWeb;
apps/mobile/lib/bootstrap/navigation_bootstrap.dart:548:    this.webMode = kIsWeb,
apps/mobile/lib/features/codes/mobile_scanner_source.dart:60:  bool get needsUserTap => kIsWeb;
apps/mobile/lib/features/stock/documents/offline_providers.dart:1:import 'package:flutter/foundation.dart' show kIsWeb;
apps/mobile/lib/features/stock/documents/offline_providers.dart:16:  (_) => kIsWeb,
apps/mobile/lib/auth/auth.dart:106:FlutterSecureStorage productionSecureStorage({bool web = kIsWeb}) =>
apps/mobile/lib/auth/auth.dart:170:    if (kIsWeb && ptr != null) {
```

`grep -rn "dart.library" apps/mobile/lib`

```
apps/mobile/lib/auth/app_auth_platform.dart:8:    if (dart.library.js_interop) 'app_auth_platform_web.dart';
apps/mobile/lib/definitions/sembast_platform.dart:6:    if (dart.library.js_interop) 'sembast_platform_web.dart';
apps/mobile/lib/features/stock/voice/voice_source_platform.dart:7:    if (dart.library.js_interop) 'voice_source_platform_web.dart';
apps/mobile/lib/offline/install_state.dart:6:    if (dart.library.js_interop) 'install_state_web.dart';
```

How to read the Android app and PWA cells: "same" means the function has no platform branch. "different" means a platform branch exists, and the sentence says what each build does. "only here" and "not built" say the function exists on one build only.

## Parity table

| Function | Code | Android app | PWA | Why different | Storekeeper use |
|---|---|---|---|---|---|
| Sign-in and resuming a session | `apps/mobile/lib/auth/auth.dart`, `apps/mobile/lib/auth/app_auth_platform.dart`, `apps/mobile/lib/bootstrap/navigation_bootstrap.dart` | different: sign-in opens the system browser through the AppAuth adapter; tokens are kept in the Keystore/Keychain, so the session resumes after the app is closed | different: sign-in is a full-page redirect; tokens are held in memory, only the tenant pointer is in browser storage, so after the page is closed the app restarts sign-in (silent while the identity-provider session lives) | `kIsWeb` in `auth.dart` (`productionSecureStorage` uses session storage on web; `TenantTokenStore.production` picks memory tokens); conditional import in `app_auth_platform.dart` (`app_auth_platform_web.dart` against `app_auth_platform_stub.dart`); `kIsWeb` in `navigation_bootstrap.dart` (`webMode`, used by `attemptSessionResume`) | daily |
| Opening the app offline with cached forms | `apps/mobile/lib/definitions/sembast_platform.dart`, `apps/mobile/lib/definitions/sembast_cache_repository.dart`, `apps/mobile/lib/bootstrap/navigation_bootstrap.dart` | different: the definition cache is a file; with stored tokens the session resumes from the cache without the network | different: the definition cache is in IndexedDB, but tokens are memory-only, so a page opened after close restarts sign-in, which needs the network | conditional import in `sembast_platform.dart` (`sembast_platform_web.dart` against `sembast_platform_io.dart`); the token difference is the `webMode` check of the first row | weekly |
| Scanning a code with the camera | `apps/mobile/lib/features/codes/scan_screen.dart`, `apps/mobile/lib/features/codes/scan_controller.dart`, `apps/mobile/lib/features/codes/mobile_scanner_source.dart` | different: the camera starts as soon as the scan screen opens | different: the screen shows an intro and the camera starts only after the user taps "Start camera" | `kIsWeb` in `mobile_scanner_source.dart` (`needsUserTap`), read by `scan_controller.dart` | daily |
| The stock count list | `apps/mobile/lib/features/stock/count_list_screen.dart`, `apps/mobile/lib/features/stock/count_list_controller.dart` | same | same | none: same code | daily |
| Counting in a count (count detail, including a surplus line) | `apps/mobile/lib/features/stock/count_detail_screen.dart`, `apps/mobile/lib/features/stock/count_detail_controller.dart`, `apps/mobile/lib/features/stock/surplus_line_sheet.dart` | same | same | none: same code (the scan and voice parts of this screen are the rows "Scanning a code" and "Voice input") | daily |
| The stock documents list | `apps/mobile/lib/features/stock/documents/documents_list_screen.dart`, `apps/mobile/lib/features/stock/documents/documents_providers.dart` | same | same | none: same code (queued drafts and the install hint shown on this screen are separate rows) | daily |
| Creating a stock document (including filling it by scan) | `apps/mobile/lib/features/stock/documents/document_form_screen.dart`, `apps/mobile/lib/features/stock/documents/document_form_controller.dart`, `apps/mobile/lib/features/stock/documents/scan_fill_sheet.dart` | same | same | none: same code (the camera start is the row "Scanning a code") | daily |
| A stock document draft saved offline and sent later | `apps/mobile/lib/features/stock/documents/offline_providers.dart`, `apps/mobile/lib/offline/offline_queue.dart`, `apps/mobile/lib/offline/offline_sync.dart` | not built | only here | `kIsWeb` in `offline_providers.dart` (`offlineQueueEnabledProvider`); the queue is passed to the bootstrap only on web (`offlineQueue` in `navigation_bootstrap.dart`) | weekly |
| Voice input | `apps/mobile/lib/features/stock/voice/voice_source_platform.dart`, `apps/mobile/lib/features/stock/voice/voice_panel.dart`, `apps/mobile/lib/features/stock/voice/record_voice_source.dart`, `apps/mobile/lib/features/stock/voice/web_voice_source.dart` | different: the native recorder package records the audio | different: the browser recorder records the audio, after the browser's own microphone prompt | conditional import in `voice_source_platform.dart` (`voice_source_platform_web.dart` against `voice_source_platform_io.dart`) | weekly |
| The install hint | `apps/mobile/lib/offline/install_state.dart`, `apps/mobile/lib/offline/install_hint_store.dart`, `apps/mobile/lib/features/stock/documents/documents_list_screen.dart` | not built | only here | conditional import in `install_state.dart` (`install_state_web.dart` against `install_state_stub.dart`); the hint is shown only where `offlineQueueEnabledProvider` is on | rare |
| The generic definition screens (form, list, process, task) | `apps/mobile/lib/renderers/form/form.dart`, `apps/mobile/lib/renderers/list/list.dart`, `apps/mobile/lib/renderers/process/process.dart`, `apps/mobile/lib/renderers/task/task.dart` | same | same | none: same code | rare |

Storekeeper use for the rows the rule does not fix, one line each:

- Opening the app offline with cached forms: weekly, because it matters only on a shift where the signal drops, not on every shift.
- A stock document draft saved offline and sent later: weekly, because it is used only where a document is made without a signal.
- Voice input: weekly, because it is an optional way to fill a count or a document; scanning and typing do the same work.
- The install hint: rare, because it is shown once per device.
- The generic definition screens: rare, because only the storekeeper's own tasks are inside the STOREKEEPER "Does" line of `docs/roles.md`; starting processes and filling other forms is not.

The use column is not measured. It is a UAT assumption, to be confirmed by the process owner.

## Gaps ranked by daily use

One item for every table row whose Android app or PWA cell is not "same". Order: daily, weekly, rare, within one value in table order. No item gives a size, a date or which build gets the fix.

1. Sign-in and resuming a session (daily): on the Android app the storekeeper stays signed in after closing the app; on the PWA the storekeeper is sent through the identity provider again after the page is closed.
2. Scanning a code with the camera (daily): on the Android app the camera starts at once; on the PWA the storekeeper must tap "Start camera" first.
3. Opening the app offline with cached forms (weekly): on the Android app a closed app reopens offline from the cache; on the PWA a reopened page needs the network to sign in before the cache is used.
4. A stock document draft saved offline and sent later (weekly): on the PWA the storekeeper can save a draft without a signal and send it later; the Android app has no such queue.
5. Voice input (weekly): both builds offer it, through different recorders, so the microphone prompt and the audio the server receives come from different code.
6. The install hint (rare): the PWA tells the storekeeper to install it and warns about storage in a plain browser tab; the Android app has no hint.

## Not compared

Native iOS and the React web application in `web/` are not compared. The functional requirements MOB-1 to MOB-8 of `docs/mobile/requirements.md` that are not built in either build are out of this table; see [docs/mobile/requirements.md](requirements.md).

## Sources

- `docs/uat/ba-decisions/T-1631.md`, item 8
- `docs/runbooks/mobile-web-pwa-hosting.md`, `docs/runbooks/mobile-web-pwa-signin.md`, `docs/runbooks/mobile-web-pwa-ready-check.md`
- `docs/mobile/README.md`, `docs/mobile/requirements.md`, `docs/mobile/architecture.md`
- `docs/roles.md`, section STOREKEEPER
- Code under `apps/mobile/lib` at commit `3926469bd0b46c56bcdde09d6ada574cee76a26b`
