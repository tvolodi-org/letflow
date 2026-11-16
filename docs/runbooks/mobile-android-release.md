# Mobile Android: signed release build and distribution (REQ-868)

The Android app (`apps/mobile`) is handed out as a plain APK from a download page (owner decision
2026-11-16); the PWA stays the main way to use the app. There is no update banner in the app: a phone
updates by installing the newer APK over the old one. QA only; no production build is made here and
no CI workflow signs a release (no signing secret exists).

## 1. The upload key (once)

The release build is signed with a key you make once and keep outside git. A lost key means installed
phones cannot take an update: they must uninstall first and lose local data. Keep the keystore and its
passwords in a password manager and keep a second backup copy on another machine.

```
keytool -genkeypair -v -keystore ~/letflow-upload.jks -alias letflow-upload \
  -keyalg RSA -keysize 2048 -validity 10000
```

Then write `apps/mobile/android/key.properties` (git-ignored, as are `*.jks` and `*.keystore`):

```
storeFile=/home/you/letflow-upload.jks
storePassword=...
keyAlias=letflow-upload
keyPassword=...
```

All four keys are required. `apps/mobile/android/app/build.gradle.kts` reads this file for the release
build and fails with a message naming `key.properties` when it is missing. There is no fallback to the
debug key. Debug builds (`flutter build apk --debug`, used by CI) do not need the file.

## 2. Build for QA

Raise the number after `+` in the `version:` line of `apps/mobile/pubspec.yaml` (the versionCode) for
every release, then run:

```
bash scripts/android_release_build.sh --out ~/letflow-android-out \
  --base-url https://qa.example.org/android/ \
  --api-base-url https://qa.bizdala.com --platform-host qa.bizdala.com \
  --first-release            # or --last-published N when no latest.json is in --out yet
```

Options: `--out DIR` (required, must be outside the repository), `--base-url URL` (required, https; where the
files will be published), `--api-base-url URL` (https), `--platform-host HOST`, `--min-version-code N`
(default: the value in `<out>/latest.json`, else 1), `--notes-file FILE` (lines `ru: `, `kk: `, `en: `),
`--dry-run` (runs every check, prints the build commands, builds nothing).

The script exits 2 without building when `key.properties` is missing, a URL is not https, or the version
code is not higher than the last published one. It builds the APK and the AAB, runs `apksigner verify
--print-certs` and exits 1 when verification fails or the certificate is the Android debug certificate. It
never prints a `key.properties` value. Output in `--out`: `letflow-<versionName>-<versionCode>.apk`, the
same name with `.apk.sha256`, `letflow-<versionName>-<versionCode>.aab`, and `latest.json`
(`versionCode`, `versionName`, `url`, `sha256`, `minVersionCode`, `notes` with `ru`, `kk`, `en`,
`published` in UTC). `latest.json` is the release record the next run reads to refuse a version code that
is not higher; the app does not read it.

## 3. Hand over

Give infra the whole output folder for the QA download location, at the `--base-url` you used. Do not
publish anything to production.

## 4. Install and update on a phone

1. Open the download page on the phone and download the APK.
2. Android asks to allow installs from this source (the browser or the file manager): allow it.
3. Open the APK and install. To update, install the newer APK over the old one; the data stays because the
   signing key is the same.

## 5. Store listing

The AAB is built so that a Google Play listing needs no new build. The store listing and its account are
money and accounts steps: the store account is the owner's decision and is not decided here.
