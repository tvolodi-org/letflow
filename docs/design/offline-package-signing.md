# Offline install package: signing (draft design and test plan)

Task T-1827, PM decision D-121. Docs only. No code, no real key, nothing on production.
Written by the business analyst, 2026-11-12. Draft for the owner.

**Decision for UAT only; the process owner configures production.**
Labels: **[F]** fact checked in a source file, **[G]** guess or recommendation, **[Q]** open question.

## 0. Short answer

1. **Pilot (one controlled customer): hash-only.** The package carries a SHA-256 list. The installer checks every file against it. The hash of the list itself comes by a second channel (phone, a signed e-mail, a printed sheet). [G]
2. **Before general release: signature.** A detached signature over the package manifest, checked offline with a public key. Recommended tool: `minisign`-style Ed25519, or OpenSSL Ed25519. [G]
3. **The key place is a config setting** (a path or a URI), never a value in the repo. The owner said any convenient place is fine for now; the real place is decided at the first real customer case (D-121). [F: task text]
4. **The team creates or stores no real key.** Tests use a throwaway key made at test time and deleted after. Never committed.
5. **Nothing exists today.** No package format, no signature, no installer. [F: T-1519, section 7 and slice S7; re-checked below]

## 1. What exists today (verified facts)

| Fact | Source | Status |
|---|---|---|
| T-1519 section 7 says nothing exists for on-site delivery: no package format, no signature, no installer | `proposals/letflow-runtime-updates-design-T-1519.md` in the sibling repository `ai-dala-portfolio` (outside this repo; opened at `/home/tvolodi/dev/ai-dala/ai-dala-portfolio/`, commit bb4d490; not in this worktree), sections 7 and 8 (slice S7, "Open; blocked on O1") | [F] |
| A tenant upgrade (plan, apply) needs no restart; new code needs a new build | same note, section 0 | [F] |
| Rollback route for a tenant module exists now (T-1549, decision 0055 D9). T-1519 listed it as "open" (slice S5); that is out of date | `docs/runbooks/demo-upgrade-notes.md`, "Rolling back an upgrade"; `lib/letflow/routers/tenant_modules.ex`, `authz_post "/:module_id/rollback"` | [F] |
| Upgrade on deploy is an env setting, default off, exactly `true` or `false` | `config/runtime.exs`, `LETFLOW_MODULE_UPGRADE_ON_BOOT` | [F] |
| A "setting from the environment, value never echoed" pattern exists | same file: the error text says "The value is not echoed." | [F] |
| A script already writes a `SHA256SUMS` file for the web build | `scripts/pwa_web_package.sh` (removes and rewrites `$dir/SHA256SUMS`) | [F] |
| No `mix release` configuration is found in `mix.exs` (grep "release" finds only a comment about test seams) | `mix.exs` line 187 | [F] |
| A `min_data_version` exists in code (API error and install paths) but T-1519 says no gate exists | `lib/letflow/api/error.ex`, `lib/letflow/modules/installs.ex`; T-1519 slice S3 | [F] that the name exists; [G] that the package manifest can reuse it |
| `openssl`, `sha256sum`, `gpg`, `ssh-keygen` are on this host. `minisign`, `cosign`, `signify` are not | `command -v` on 2026-11-12 | [F] |
| Security rule INV-4: no key material in git, logs, responses, errors | `docs/agents/instructions/security-invariants.md` (as quoted in the project skill) | [F] |
| How the public-schema migration runs in a release was not found in this repo | T-1519 section 2 | [F] gap |

## 2. Package layout and manifest

One archive per application version. Everything the installer needs is inside; no internet at the customer. [G]

```
letflow-<version>/
  PACKAGE-MANIFEST.json      # the file the installer reads first
  PACKAGE-MANIFEST.json.sig  # signature mode only (section 4)
  RELEASE-NOTES.md           # plain language
  build/                     # release build or image archive
  modules/                   # module manifests and pack files
  migrations/                # public and tenant schema migrations
  web/                       # web bundle
  installer/                 # verifier and install script
```

Manifest fields (all recommended, [G]; names are drafts):

| Field | Meaning |
|---|---|
| `package_name`, `package_version` | what it is |
| `built_at`, `source_commit` | when and from which commit |
| `can_upgrade_from` | list of earlier package versions this one can upgrade (owner question O6 in T-1519) |
| `required_platform_version` | refuse if the installed platform is older |
| `min_data_version` | per module, same idea as the product's existing name |
| `files` | list of `{path, size, sha256}` for every file except the manifest and its signature |
| `signature_mode` | `hash-only` or `signed` |
| `key_id` | fingerprint of the public key that must verify it (signed mode) |
| `revoked_key_ids` | optional list, see section 6 |

Rules: manifest is canonical JSON (sorted keys, no extra spaces) so the bytes are stable. The installer refuses any file in the archive that is not in `files`, and any file in `files` that is missing. [G]

## 3. Mode 1: hash-only (controlled pilot)

How it works:

1. The release step builds the archive and writes `PACKAGE-MANIFEST.json`.
2. It computes `SHA-256` of the manifest and of the whole archive.
3. The vendor sends the archive by one channel and **the two hashes by a second channel** (phone call read-out, a signed e-mail, a printed sheet). [G]
4. The customer administrator types or pastes the manifest hash into the installer. The installer compares it, then checks every file in `files`. Any mismatch stops the install before anything is changed.

| | |
|---|---|
| Good | No key at all. Nothing to lose or leak. Works fully offline. Easy to explain. |
| Bad | Protects against damage and a changed file only if the second channel is trusted. Does not protect if the attacker controls both channels. No proof of who made the package. |
| When it is enough | One known customer, a person-to-person hand-over, a pilot. [G] |
| When it is not | Many customers, packages sent over open channels, any customer who wants to prove the origin. [G] |

Installer prints the manifest hash it computed, so the customer can read it back to the vendor.

## 4. Mode 2: signature (before general release)

Options compared (all [G] unless a source is named):

| Option | How | Pros | Cons | Offline check at customer |
|---|---|---|---|---|
| **A. Detached signature, own key pair (Ed25519)** with `minisign`-style tool or OpenSSL | Vendor signs `PACKAGE-MANIFEST.json`. Installer holds the public key. | Simple. Small. No third party. Private key stays with the vendor. Matches T-1519 option A. | Vendor must keep and protect a private key; loss and leak steps needed (section 6). | **Yes**: the public key is in the installer; no network. |
| B. OpenSSL or GPG signature | Same idea with older tools. | Tools already on the host (`openssl`, `gpg`). | GPG key handling is heavy; more ways to misuse. | Yes. |
| C. Keyless CI signing (Sigstore style) | The CI proves its identity and gets a short-lived certificate; the signature goes in a public log. | No long-lived private key to guard. | Normal verification needs the public log and the internet; an offline check needs extra bundled proofs and a trust root update path; the tool is not on this host. Harder to explain to an isolated customer. | **Only with extra work**; weak fit for isolated sites. |
| D. Per-customer shared secret (HMAC) | Same secret on both sides. | Easy. | A shared secret leaks with the customer's backup and can forge packages. T-1519 rejects it. | Yes, but unsafe. |
| E. Hardware token or cloud KMS holds the private key | Option A with the key in a device or service. | Key cannot be copied out. | Cost and a place to run it; decision belongs to the owner. | Yes. |

**Recommendation [G]:** Option A for the first signed release; the private key place can later move to option E without changing the package or the installer, because only the signing step changes. Option C is not recommended while customers are offline.

Verification at the customer, in order: (1) read the manifest; (2) verify the signature with the public key from the installer's trusted set; (3) check `key_id` is in the trusted set and not in `revoked_key_ids`; (4) check every file hash; (5) only then print the plan and ask to continue. Failure at any step stops with a plain message and changes nothing.

Hash-only and signed use the same manifest; only `signature_mode` and the `.sig` file differ. So the pilot package is a valid input to the later installer. [G]

## 5. Key place as a config setting

Rule: the repo holds no key value, only the name of a setting. [F: task text, D-121]

| Setting (draft names, [G]) | Meaning | Rule |
|---|---|---|
| `LETFLOW_PACKAGE_SIGNING_KEY_REF` | Where the **private** key is read by the **signer** (release pipeline only): a file path (`file:/path`) or a URI (`kms://...`, `vault://...`) | Never present at the customer. The value is never printed or logged (INV-4). The error for a bad value does not echo it, as `config/runtime.exs` does for the upgrade flag. [F pattern] |
| `LETFLOW_PACKAGE_TRUSTED_KEYS` | Where the **installer** reads the trusted **public** keys: a directory or file path | Public keys may be in the package; trust comes from the installer, not from the package being checked. |
| `LETFLOW_PACKAGE_SIGNATURE_MODE` | `hash-only` or `signed` | Default `signed`; `hash-only` must be chosen on purpose and is printed in the install report. |

Setting rules: the signer fails closed when the reference is empty, unreadable, or points inside the repo working tree (refuses a key inside the checkout). A file key must have owner-only permissions (mode 0600) or the signer refuses. The place can change without code change: the real place is decided at the first real customer case. [Q-K1]

## 6. Key loss, leak, rotation, revoke

| Case | What happens | Who acts [G] |
|---|---|---|
| **Rotation (planned)** | Make a new key pair. Sign the new public key with the old private key (a "key statement" file). Ship the statement in the next package; the installer adds the new key to its trusted set. Old key stays trusted for a set overlap, then is removed. | Vendor release owner |
| **Key lost** (private key unreadable, no copy) | No new package can be signed with it. Installed customers still run. The vendor makes a new key pair and delivers the new public key **by a second channel** (like hash-only mode), because the old key cannot sign the statement. Each customer confirms the new key fingerprint by phone. | Vendor owner, customer admin |
| **Key leaked** | Treat every package signed since the leak as suspect. Put the old `key_id` in `revoked_key_ids` of the next package, which is signed by the new key. New public key goes by the second channel. Tell customers to verify packages by fingerprint until they hold the new key. | Vendor owner |
| **Revoke one package** | Add its manifest hash to a revoked list in the next package; the installer refuses a revoked package. | Vendor release owner |
| **Weakness** | An offline customer learns of a revoke only when a newer package or a notice arrives. A revoked old package can still be installed on a site that has never seen the list. Accepted limit; the second channel is the cover. | Owner decision [Q-K2] |

Not decided here: who may use the private key and whether two people are needed (T-1519 O1). [Q]

## 7. Test plan (throwaway dev/test key)

Rules: the test makes its own key pair at test time in a temporary folder, uses it, deletes it at the end. Never committed. Never a customer key. The signer and installer read it only through the settings in section 5 (a path to the temp folder). No test touches production, DNS, money, or a real secret. A repo check (grep for private-key markers in the diff) is part of the plan.

| ID | Case | Expected | Mode |
|---|---|---|---|
| P1 | Build a small test package, write the manifest | Manifest lists every file with SHA-256; canonical bytes are the same on a second run | both |
| H1 | Hash-only: correct manifest hash, all files intact | Install check passes | hash-only |
| H2 | Wrong manifest hash typed | Refused before any file is read; nothing changed | hash-only |
| H3 | One file changed by one byte | Refused, names the file | hash-only |
| H4 | One file removed; one extra file added | Both refused | hash-only |
| S1 | Signature made with the throwaway key, correct public key | Passes | signed |
| S2 | Manifest changed after signing | Refused (signature fails) | signed |
| S3 | Signature from another throwaway key | Refused: key not trusted | signed |
| S4 | No `.sig` file while mode is `signed` | Refused; no silent fall back to hash-only | signed |
| S5 | `signature_mode` field in the manifest says `hash-only` but the installer is set to `signed` | Refused | signed |
| R1 | Rotation: key statement signed by old key adds the new key | New key trusted; package signed by new key passes | signed |
| R2 | Revoked `key_id` in the list | Package signed by it is refused | signed |
| R3 | Revoked package hash | Refused | signed |
| C1 | Signer with empty key reference | Fails closed with a message that does not show the value | signer |
| C2 | Key reference points inside the repo working tree | Signer refuses | signer |
| C3 | Private key file with open permissions | Signer refuses | signer |
| C4 | Run signer and installer with output captured | No key bytes in output or logs (INV-4) | both |
| O1 | Run the verifier with network blocked (no network namespace or no route) | Passes the same as with network | signed |
| X1 | After the test, the temp key folder is gone; `git status` shows no key file; diff scan finds no private-key marker | Clean | both |
| U1 | `can_upgrade_from` does not list the installed version | Refused with a plain message, before any change | both |

Facts about the test host: `openssl` is on the host, so Ed25519 test keys can be made with it [F: `command -v`]; `minisign` is not installed, so the first build task would either use OpenSSL or ask to install it (installing from an enabled repo is allowed by the operating rules; a new repo is not) [G].

## 8. What a later build task would contain

Split into small changes, each a `requirement` first (T-1519 slice S7 is sized L):

| # | Change | Size [G] | Needs |
|---|---|---|---|
| B1 | Manifest format and builder (no signing): canonical JSON, file list, hashes; extend the web `SHA256SUMS` idea to the whole package | S | none |
| B2 | Verifier, hash-only mode: checks hash by second channel, every file, extra and missing files | S | B1 |
| B3 | Signer in the release pipeline: reads the key from the setting, fails closed (C1 to C3) | S | B1; **key place decision at first real customer** |
| B4 | Verifier, signed mode with trusted-keys setting, revoke list, rotation statement | M | B2, B3 |
| B5 | Installer flow: refuse unsupported upgrade jump, backup step, run migrations, report with key fingerprint to audit (T-1519 section 7 flow) | L | B2; how the public migration runs in a release (gap, section 1) |
| B6 | Runbook: key loss, leak, rotation, revoke, second channel | S | B4 |

No build task should be queued before the first real on-site customer (T-1519 order: S7 last). B1 and B2 can serve the controlled pilot.

## 9. Open questions

| ID | Question | Default for now [G] |
|---|---|---|
| Q-K1 | Where does the real private key live (file, hardware token, KMS)? Owner said: decide at the first real customer case | Throwaway key only; setting holds a path |
| Q-K2 | Is a vendor-held key acceptable to customers, or must some have their own trust root? (T-1519 O1) | Vendor-held |
| Q-K3 | Who may sign; is a second person needed? | One release owner, after green gates |
| Q-K4 | Which pilot customer, and which second channel do they accept? | Phone read-out of the manifest hash |
| Q-K5 | How many earlier versions must a package upgrade from? (T-1519 O6) | Previous one only |
| Q-K6 | Is a verified backup before install a hard stop? (T-1519 O7) | Yes |

## 10. Sources opened

- `proposals/letflow-runtime-updates-design-T-1519.md` in the sibling repository `ai-dala-portfolio` (outside this repo; opened at `/home/tvolodi/dev/ai-dala/ai-dala-portfolio/`, commit bb4d490; not in this worktree), sections 0, 7, 8, 9.
- `docs/runbooks/demo-upgrade-notes.md` (headings, "Rolling back an upgrade").
- `config/runtime.exs` (upgrade-on-boot flag parse), `lib/letflow/routers/tenant_modules.ex` (rollback route), `scripts/pwa_web_package.sh` (SHA256SUMS), `mix.exs` (grep "release").
- Commands: `command -v openssl minisign cosign sha256sum gpg signify age ssh-keygen`; `grep -rln min_data_version lib`.
- Not opened: infra's deploy scripts (outside this repository); no web search, so facts about tools (minisign, Sigstore) are general knowledge, marked [G].
