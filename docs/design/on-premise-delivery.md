# On-premise delivery of Letflow (MES at a plant's own servers): what exists, what is missing, staged plan

Task T-1836. Docs only: no code, nothing on QA, production, demo, secrets, DNS, the public repository or money.
Written by the business analyst, 2026-11-13. Draft for the owner. Nothing here is decided.

**Decision for UAT only; the process owner configures production.**
Labels: **[V]** verified in a file of this repository (path given); **[NF]** looked for and not found (grep given in section 8); **[G]** guess or recommendation; **[Q]** open question.
Effort scale as in the MES notes: **S** = days, **M** = a few weeks, **L** = more than a few weeks. All sizes are guesses; nothing was measured.

## 0. Short answer

1. **No on-premise mechanism exists.** There is no package format, no installer, no signature and no customer-side upgrade path. The owner's question is answered "no" [V: `docs/design/offline-package-signing.md` section 1; T-1519 note in the sibling repository `ai-dala-portfolio`, `proposals/letflow-runtime-updates-design-T-1519.md`, section 7, opened 2026-11-13].
2. **The pieces exist, though.** A production build recipe (`deploy/Dockerfile`), a Postgres+app compose file shape (`deploy/docker-compose.qa.yml`), a backup/restore script set (`scripts/backup/`), a first-run script for the platform tenant (`scripts/demo/demo_platform_bootstrap.sh`), a module upgrade plan/apply/rollback API, and boot-time migrations. What is missing is the wrapper: a package, an installer, a way to run without our cloud, and a way to upgrade with no internet. [V]
3. **Hardest gap: sign-in.** Letflow signs users in through Keycloak, one realm per tenant, and the backend fetches OIDC discovery from a Keycloak URL at runtime [V: `config/runtime.exs` `OIDC_KEYCLOAK_BASE_URL`; `docs/runbooks/demo-operator-inputs.md` O3]. A plant server would have to run its own Keycloak (or the plant's own identity system, which is not supported today [NF]). Nothing in the repo packages Keycloak for a customer; the only Keycloak compose entry is `start-dev` for developers [V: `docker-compose.yml`].
4. **Recommended first step for ONE controlled pilot:** a hand-delivered "kit" on one Linux server with Docker: our image archive + PostgreSQL + Keycloak, a hash-only package (from the signing draft), a short install script, our person on site or on a call. Estimated **M** to build the kit, plus plant preparation (section 2.6). [G]
5. **Licence:** the repository has no licence file at its root [NF]. The owner mentioned "MIT" for the open-source side; that is not backed by a file in this tree. A licence decision comes before any package leaves our hands (section 4.6). [Q]

## 1. What exists today, and what a customer server needs

Checked in this worktree on 2026-11-13. Where a fact was not found it says so.

| Need at the plant | What exists in the repo [V] | What is missing |
|---|---|---|
| **Runtime build / release** | `deploy/Dockerfile`: two stages, Elixir 1.20.3 / OTP 29 builder, `debian:trixie-slim` runtime, non-root user uid 1000, `mix release`, port 4000 fixed in code, `CMD bin/letflow start`. Build arg `GIT_SHA` reported by `GET /health`. | No `releases:` section in `mix.exs` (grep "release" finds only a comment, line 187) [NF]. No image export (`docker save`) step, no version tag scheme other than `:latest` and `rollback-<date>` in `redeploy-qa.sh`. Build needs internet (hex deps, base images) so it is built on our side, never at the plant. |
| **Native parts** | The app depends on `wasmex` (WebAssembly) and `lua` for script sandboxes [V: `mix.exs` lines 75-76]. They are compiled into the image. | Not tested on plant hardware or on a different CPU type (for example ARM); the image is built for the CI host's architecture [G]. |
| **Database** | PostgreSQL 16 (`postgres:16` in compose, `postgres:16-alpine` in QA). Schema-per-tenant. Public schema migrates at boot inside the release; tenant schemas are replayed at boot (`lib/letflow/supervisor/infrastructure.ex` `skip_migrations`, `lib/letflow/tenant_provisioning/migration_replay_boot.ex`). `DATABASE_URL`, `POOL_SIZE` (default 30) in `config/runtime.exs`. | Postgres tuning, disk sizing, who owns the database (plant DBA or us) are not written. |
| **Identity / sign-in** | Keycloak 26.2 as the identity provider, one realm per tenant, realm template and runbooks: `docs/runbooks/onboarding-new-tenant-realm.md`, `docs/runbooks/demo-realm/`, `priv/keycloak/realms`. Settings `OIDC_KEYCLOAK_BASE_URL`, `OIDC_CLIENT_ID`. Provisioner credential for creating realms/users: `docs/runbooks/tenant-provisioner-credential.md` (QA only). | Production-mode Keycloak packaging (own database, TLS, hostname, backup) for a customer [NF]. The provisioner that creates a realm per tenant is infra's, outside this repository [V: goal text; `onboarding-new-tenant-realm.md`]. Option to use the plant's directory (AD/LDAP) is a Keycloak feature, not tested by us [G]. |
| **Reverse proxy** | nginx examples: `deploy/nginx/letflow-test.conf`, `letflow-pwa-web.conf.example`. QA binds the app to `127.0.0.1:3201` and nginx in front. The app trusts a proxy only for addresses in `LETFLOW_TRUSTED_PROXIES` (`config/runtime.exs`). | The two nginx files are for our hosts; no plant template. Websocket / SSE proxy rules are described for the demo (`demo-operator-inputs.md` O8, not re-read in full here [G]). |
| **TLS** | The test nginx file uses a Cloudflare origin certificate (`/etc/ssl/cloudflare/...`) [V]. | Nothing for a plant: a plant has no Cloudflare. It needs a certificate from the plant's own authority or a self-signed one with the root installed on every client [G]. |
| **Web app** | A separate static bundle built from `web/` and swapped in as `web-dist` by `redeploy-qa.sh` (built in a throwaway node container). No static-file serving found in `lib/` (grep `Plug.Static`, `index.html` in `lib` finds nothing) [NF]; the demo runbook says the backend serves the app, so this is a **conflict to settle** [Q]. | A prebuilt bundle in the package (the PWA scripts `scripts/pwa_web_build.sh`, `pwa_web_package.sh` already write a `SHA256SUMS` [V: signing draft]). Which tool serves it at the plant. |
| **Backups** | `scripts/backup/` (dump, base backup, WAL mode, prune, restore test, status files), runbook `docs/runbooks/backup-restore.md`; optional gpg encryption; `BACKUP_ROOT` default `/opt/backups/<env>`. Needs `pg_dump` etc. through `PG_EXEC` (docker exec) and `sha256sum`, `flock`. Status shown to the app through `LETFLOW_BACKUP_STATUS_DIR`. | Timers are "infra's" (units in the runbook are examples). At the plant someone must own them; off-site copy has no target. |
| **Mail** | An SMTP sender exists for the login directory (`lib/letflow/login_discovery/notifier/smtp/`): `LETFLOW_SMTP_HOST`, `_PORT`, `_TLS`, username and password as secrets. `gen_smtp` is a dependency. | Whether all mail (sign-up, notices) goes through it is not verified; a plant may have no mail relay at all, so the install must work with mail off [G]. |
| **Time sync** | Not found: no setting, check or runbook about NTP or clock skew in the repo [NF] (grep in section 8). Tokens (JWT lifetime) and audit entries depend on the clock [G]. | A rule that the server and Keycloak use one time source; a startup check is a candidate task. |
| **Secrets** | `LETFLOW_SECRETS_MASTER_KEY` (64 hex, required, no default, boot fails without it, `config/runtime.exs`); Keycloak and DB passwords from env files. | Where the master key is kept at a plant, and what happens if it is lost (stored secrets become unreadable) [G]. Backup of the key must be separate from the database backup. |
| **First run** | `scripts/demo/demo_platform_bootstrap.sh create / finish / verify` creates the platform tenant and `PLATFORM_ADMIN` on an empty database; the tenant UUID goes into `LETFLOW_PLATFORM_TENANT_ID` and the backend restarts (read once at boot). It is written for the demo realm names. | An install-neutral version without demo names. Tenant creation for the plant itself: `Letflow.TenantOnboarding.provision_and_migrate` and the realm runbook (two systems to keep in step). |
| **Modules** | Install, upgrade plan/apply, rollback, uninstall, reactivate through tenant routes (`lib/letflow/routers/tenant_modules.ex`). Upgrade on boot is a flag, default off (`LETFLOW_MODULE_UPGRADE_ON_BOOT`). `scripts/demo_upgrade_chain.sh`. | Module versions are in the build, so a module change needs a new build, not only a tenant upgrade [V: signing draft section 1, T-1519 section 0]. `min_data_version` gate is not in place (T-1519 S3). |
| **Upgrade of the app** | `deploy/redeploy-qa.sh`: git pull, build image, restart app, rebuild web (needs internet and git). Rolling-deploy design: `docs/design/rolling-deploy.md` (two nodes, expand/contract migrations; design only). | An upgrade without git, internet or Docker build: the package. Single-node on-prem cannot roll (no second node); a short stop is the price [G]. |
| **Monitoring** | `GET /health`, `GET /ready`, `GET /metrics` (`lib/letflow/router.ex`). | No plant-side alert target; offline means no remote monitoring by default (section 4). |
| **Licence / open source** | `scripts/oss_audit/` scans for what must not be public. Dependencies list MIT notes in `mix.exs` comments. | No LICENSE or NOTICE file [NF]; no list of third-party licences shipped with a package. |

## 2. Minimum viable on-prem install for ONE controlled pilot

Scope: one plant, one server, our person involved in every step, a friendly customer. Not for sale, not for a second customer. [G]

### 2.1 Shape

One Linux server (Debian or Ubuntu LTS family, 8 vCPU, 16 GB, 200 GB disk as a starting guess [G], not measured) running Docker with three services: Letflow app, PostgreSQL 16, Keycloak (production mode, own database inside the same Postgres server or a second container [G]). nginx or Caddy in front for TLS. Same shape as `deploy/docker-compose.qa.yml` plus Keycloak. [G]

### 2.2 What we deliver (the "kit")

| Item | Content | Status |
|---|---|---|
| Package | One archive with `PACKAGE-MANIFEST.json` (SHA-256 list), the app image as an archive, the Postgres and Keycloak images as archives (so nothing is pulled from the internet), the web bundle, module manifests, release notes, installer | Format drafted in `offline-package-signing.md` section 2 [V that the draft exists]; **not built** |
| Hash-only check | Manifest hash read over a second channel (phone), installer checks every file | Draft [V]; not built |
| Install script | Checks prerequisites (Docker, disk, ports, clock), checks the package, loads images, writes an env file from a form (asks for hostnames, generates the secrets master key and passwords on the server, shows nothing on screen), starts services | New |
| First run | Starts empty database, platform tenant, `PLATFORM_ADMIN`, plant tenant, realm and first administrator, module install (stock, assets; MES modules only when they exist) | Parts exist (section 1); needs one neutral script |
| Upgrade by package | New package → check → backup → stop app → load new image → start → boot migration → upgrade modules (plan, then apply) → health check | New; a few seconds to minutes of downtime accepted [G] |
| Rollback | Old image stays loaded; stop, start old image. Valid only if the migrations of the new release were expand-only; otherwise restore the backup taken before the upgrade. Tenant modules first via the rollback route, then the image (reverse order is refused with `module_version_ahead`) [V: `rolling-deploy.md` section 5] | Rule exists; script new |
| Backup / restore | `scripts/backup/` as is: daily dump to a local folder, weekly restore test, status file; plus one copy to a plant-owned place (a second disk or file share) chosen by the plant. Restore runbook `backup-restore.md` sections 6-8 | Scripts exist [V]; the plant side is new |
| Pilot runbook | Short plain-language pages: install, daily check, upgrade, rollback, restore, who to call | New |

### 2.3 Installation order (target)

1. Plant IT prepares the server and answers section 6 questions.
2. We hand over the package; the plant administrator confirms the manifest hash with us by phone.
3. Install script: prerequisites → verify → load images → write env file → start Postgres and Keycloak → start Letflow (public schema migrates at boot).
4. Create the platform tenant and set `LETFLOW_PLATFORM_TENANT_ID`, restart once (the variable is read once at boot [V: `demo_platform_bootstrap.sh` header]).
5. Create the plant tenant, its realm and the first administrator (no Keycloak admin rights for that person, as in the provisioning decision [V: goal text, item 3]).
6. Install modules for the pilot; run the smoke check (`scripts/demo_smoke_read.sh` idea).
7. Enable backups; run one restore test; record the result.
8. Hand over: the administrator signs in; we record the version and the manifest hash.

### 2.4 What the pilot deliberately leaves out

Signed packages, automatic update, remote access by us, a second node, high availability, mail, a fleet view, licence keys, PLC/SCADA connection (section 4; phase 4 of the MES roadmap), more than one customer.

### 2.5 Acceptance for the pilot install (checkable)

- A package with one changed byte is refused before anything is changed.
- A server with no internet access completes the install end to end.
- After a power-off and restart of the server, all services return without a person (restart policies).
- A backup taken on day 1 restores into a scratch database and the tenant's counts match (`restore_test.sh`).
- An upgrade from package N to N+1 and back to N (rollback) leaves the counts unchanged.
- No secret appears in the install log.

### 2.6 What plant IT must prepare

A server (physical or virtual) with a supported Linux, root access for our installer, enough disk, Docker or permission to install it from an internal mirror; a fixed address or host name inside the plant; a certificate for that host name (or permission to use a self-signed one and install its root on clients); a time source (NTP) reachable from the server; a backup target; a rule for who may reach the server and from which network; firewall rules between the plant network and the server; an administrator who will own passwords and keys; a window for install and for each upgrade. Short question list: section 6.

## 3. Later stages

| Stage | Content | Size [G] | Depends on |
|---|---|---|---|
| **S1 Pilot kit** (section 2) | Package, installer, first-run, backup, runbook | M | Licence decision; owner OK |
| **S2 Signed package** | Detached Ed25519 signature, trusted keys on the installer, rotation, revoke (as in the signing draft, sections 4-6); key place is a setting, real place decided at the first real customer case (D-121) [V] | M | S1; owner decision on who holds the private key |
| **S3 Offline upgrade chain** | `can_upgrade_from` in the manifest; installer refuses a skip it cannot do; chain of module upgrades with plan/apply and the `min_data_version` gate (T-1519 S3, not built) so a package that needs older data refuses instead of breaking; upgrade checks that the data version of each module is reached before the next package | M to L | S1; T-1519 slices S3 and S7 |
| **S4 Identity options** | Packaged production Keycloak with a documented backup; or import of the plant's directory; or (later) a supported non-Keycloak sign-in | M to L | S1; infra's provisioner design for realms |
| **S5 Fleet of customers** | A register of which customer runs which package and module versions (a manual sheet first, a tool later); a customer-specific release notes view; a rule that customers can stay on old versions for N months; a support matrix | M | S2, S3 |
| **S6 Support access policy** | No access by us by default. Options: (a) screen share with the customer's administrator; (b) an on-demand, time-limited tunnel opened by the customer; (c) a "diagnostics bundle" the customer exports (logs without secrets, version list, counts) and sends by their own channel. Every session logged; customer can see and revoke. Choice belongs to the owner. | S to M | S1 |
| **S7 Licence and obligations** | Licence file and NOTICE with third-party licences in every package; an automated list of dependency licences; decision on the licence of our own code; terms with the customer (support, updates, liability for a package they installed late) | S to M | Owner and legal (not our decision) |
| **S8 High availability** (only if asked) | Two nodes at the plant per `rolling-deploy.md`; Postgres replica | L | Customer need; plant hardware |

### 3.1 Open-source (MIT) obligations: what is verified

- The product repository has no `LICENSE` file at its root [NF: `ls`, `git ls-files | grep -i -E "^(license|copying|notice)"` both empty on 2026-11-13]. `mix.exs` mentions MIT only for some dependencies (comments at lines 56, 78, 89).
- If our own code were released under MIT (the owner's word), MIT requires the copyright and permission notice to stay in copies; MIT does not oblige a seller to give support or updates. [G: general knowledge of the licence, not checked against our files]
- Dependencies keep their own licences (Erlang/OTP Apache-2.0, PostgreSQL licence, Keycloak Apache-2.0, nginx BSD-2, Debian packages various incl. GPL) [G, from general knowledge; **not verified here**]. Shipping the images means shipping those components, so a licence list and, for GPL parts, the offer of source are part of the package. [Q: needs a licence check task]
- `scripts/oss_audit/` is a secrets/history scanner, not a licence checker [V: its README].

## 4. What is different from our cloud for MES

| Topic | Our cloud (today) | Plant on-premise | Consequence [G] |
|---|---|---|---|
| Internet | Always on; builds, mail, OIDC discovery, git | May be off for weeks or months | Everything the install and the running app need is inside the package or the plant; no call to our servers; upgrade only by package |
| Upgrades | We deploy on main merge (CD) | Customer decides the window; many versions apart | Upgrade chain must allow a skip or say exactly which steps are needed (S3); we support a limited set of old versions |
| Data location | Our database | Stays in the plant; no copy to us unless the customer sends a bundle | Support and bug reports work from the diagnostics bundle (S6); we cannot "look at the data" |
| Our access | We can log in to hosts | None by default | Needs a documented policy before the pilot starts (S6) |
| PLC/SCADA/machine network | Not applicable | The plant's control network is separate from office IT; Letflow must not sit in it | Letflow stays on the office/plant IT side; machine values come in through a file import or a gateway that the plant controls, as in MES paper 11 (raw tags stay outside the core: `docs/design/mes/05-platform-options.md` and `11-readings-import-P3.md`). No direct PLC connection in the pilot. Direction of data: from the control network outward only, through the plant's own rules [G] |
| Long offline operation | Not a case | Server may run alone for months | Clock drift, certificate expiry, disk growth, log growth, backup space all become the plant's alarms; the app needs a local "health and space" screen or a daily status file (status files for backups exist [V]) |
| Identity | Our Keycloak, our realms | Their Keycloak or their directory | Highest effort item (S4); passwords and first admin stay in the plant |
| Time | Cloud hosts have synced clocks | A plant server may drift | Time source is a prerequisite; batch records and audit need trusted times [G] |
| Safety / regulation | Not applicable | Chemical plant: records may be audited; availability matters for production | The pilot is a **side system** (paper-and-forms pilot of the MES roadmap), not in the control loop; production stops must not depend on Letflow [G, matches MES paper 07 section 1] |
| Hardware | Our hosts | Whatever the plant has | Supported hardware list; ARM not supported until tested |

## 5. Effort, risks, and asks for infra

### 5.1 Effort per stage (guesses)

| Item | Guess | Basis |
|---|---|---|
| S1 package, installer, first-run script, pilot runbook | M (about 4 to 6 weeks for one developer plus BA) | Parts exist; the packaging, neutral first-run and offline image loading are new. No measurement. |
| S2 signature | S to M (1 to 3 weeks) | Test plan already drafted (`offline-package-signing.md` section 7) |
| S3 upgrade chain with `min_data_version` | M to L | T-1519 S3 and S7 are open |
| S4 identity packaging | M to L | Depends on the plant's choice |
| S5, S6, S7 | S to M each | Mostly documents and policy |
| Plant-side preparation | 1 to 3 weeks calendar for the plant's IT | Typical for a first install; depends on their change process [G] |

### 5.2 Risks

| # | Risk | Weight | Cover [G] |
|---|---|---|---|
| R1 | Keycloak at the plant is a second product to run (own database, patches, certificates) | High | S4; prefer our person operating it during the pilot |
| R2 | We cannot reproduce a bug without access to data | High | Diagnostics bundle (S6) before the pilot |
| R3 | A customer misses upgrades and falls many versions behind | Medium | `can_upgrade_from` rule; support window |
| R4 | A contract (non-expand) migration cannot be rolled back | Medium | Backup before every upgrade; rolling-deploy expand/contract rules apply here too |
| R5 | Lost secrets master key makes stored secrets unreadable | High | Key kept apart from backups; written procedure |
| R6 | Image built for the wrong CPU type or glibc | Medium | One tested hardware type for the pilot; check at install |
| R7 | Licence not decided; a package leaves with no licence terms | High | Section 3.1 decision first |
| R8 | Clock drift breaks sign-in tokens | Medium | Install check; time source prerequisite |
| R9 | Web bundle serving question (backend or nginx) not settled | Low | Settle in S1 design [Q] |
| R10 | Pilot treated by the plant as a control system | High | Written scope: side system only |

### 5.3 Asks for infra (INFRA's to do; nothing done here)

| # | Ask | Detail |
|---|---|---|
| I1 | Release build job that outputs the package | Builds app image, exports with `docker save`, adds Postgres and Keycloak images pinned by digest, web bundle, manifest and `SHA256SUMS`; runs on our side only |
| I2 | A test host that is not connected to the internet | A VM with the network blocked, used to prove "install with no internet" (test O1 of the signing draft uses the same idea) |
| I3 | A production-mode Keycloak recipe | Own database, hostname, TLS, realm import, backup; the current compose uses `start-dev` |
| I4 | Realm provisioner usable without our cloud | The provisioner that infra builds (D-016, D-018 in the goal text) must be runnable at the plant or replaced by a documented manual step |
| I5 | nginx/Caddy template and certificate guidance for a plant host name | No Cloudflare |
| I6 | Backup timers for the plant | Same units as `backup-restore.md`, with a plant-owned destination |
| I7 | A place for the signing key (later, S2) | A setting only; the owner decides the real place (D-121) |
| I8 | Hardware and OS list to support | One OS family and one CPU type for the pilot |

## 6. Questions to ask the plant's IT

English / Русский

| # | English | Русский |
|---|---|---|
| 1 | Can we install on a physical or virtual server? Which operating system and version? | Это будет физический или виртуальный сервер? Какая операционная система и версия? |
| 2 | How many CPU cores, how much memory and disk can you give? | Сколько ядер процессора, памяти и диска можно выделить? |
| 3 | Is Docker allowed? If not, which container or package tool is approved? | Разрешён ли Docker? Если нет, какое средство контейнеров или пакетов утверждено? |
| 4 | Does the server have internet access, never, or only sometimes? Is there an internal mirror for packages? | Есть ли у сервера доступ в интернет: никогда или иногда? Есть ли внутреннее зеркало пакетов? |
| 5 | How do files get into the plant network (USB, file share, a transfer station)? Is a virus scan done on them? | Как файлы попадают в сеть завода (USB, общая папка, станция передачи)? Проверяются ли они антивирусом? |
| 6 | Which host name or address will the server have? Can you give us a TLS certificate for it? Which authority? | Какое имя или адрес будет у сервера? Можно ли выдать для него TLS-сертификат? Какой центр сертификации? |
| 7 | Which sign-in system do you use (Active Directory, LDAP, none)? Must users sign in with it? | Какую систему входа вы используете (Active Directory, LDAP, никакой)? Должны ли пользователи входить через неё? |
| 8 | Is there a time server (NTP) the server can reach? | Есть ли сервер времени (NTP), доступный для сервера? |
| 9 | Is there a mail relay? Do you want notices by mail? | Есть ли почтовый шлюз? Нужны ли уведомления по почте? |
| 10 | Who will run backups and where do copies go (second disk, share, tape)? How long to keep them? | Кто будет делать резервные копии и куда их складывать (второй диск, общая папка, лента)? Как долго хранить? |
| 11 | Who is the administrator of the server and who owns the passwords and keys? | Кто администратор сервера и кто хранит пароли и ключи? |
| 12 | Which networks must reach the server (office, production, none)? May the server reach the machine/SCADA network? Which direction is allowed? | Из каких сетей нужен доступ к серверу (офис, производство, никакой)? Можно ли серверу выходить в сеть машин/SCADA? В какую сторону разрешён трафик? |
| 13 | May our staff connect remotely (never, on request, by screen share)? Who approves each session? | Может ли наш персонал подключаться удалённо (никогда, по запросу, через демонстрацию экрана)? Кто одобряет каждую сессию? |
| 14 | What is your change-approval process and how long does it take? What maintenance windows exist? | Как у вас согласуются изменения и сколько это занимает? Какие есть окна обслуживания? |
| 15 | Which security rules apply (hardening standard, audit, data classification)? Is data allowed to leave the plant? | Какие требования безопасности действуют (стандарт защиты, аудит, классификация данных)? Можно ли выносить данные за пределы завода? |
| 16 | What happens at the plant if this system is down for an hour? A day? | Что происходит на заводе, если система не работает час? Сутки? |

## 7. Verified vs guess (summary)

**Verified [V]:** nothing exists for packages or install (signing draft, T-1519 note); Dockerfile shape and runtime base; compose shape for app and DB; Keycloak is the sign-in and the repo compose runs it only in `start-dev`; secrets master key is required with no default; `DATABASE_URL`, `POOL_SIZE`, trusted-proxy and SMTP settings exist; boot migrations and tenant replay at boot exist; module install/upgrade/rollback routes exist; backup scripts and restore test exist; platform bootstrap script exists; health, ready and metrics routes exist; the rollback order rule (tenants first) exists in `rolling-deploy.md`.

**Not found [NF]:** a `releases:` configuration in `mix.exs`; LICENSE/NOTICE files; NTP or clock-skew handling; a production Keycloak recipe; a static-file server in `lib/`; anything for a plant's own certificate authority.

**Guess [G]:** all sizes and weeks; server size; what the plant has; the kit shape; support access options; licence consequences; downtime of an upgrade; hardware support; MES side-system scope.

**Open [Q]:** licence of our code and obligations of shipped components; who serves the web bundle; who holds the signing key; which identity option for the pilot; whether the pilot needs mail; whether the first MES phase exists in time (the MES core decisions are still with the owner: `docs/design/mes/12-core-decisions-for-owner.md`).

## 8. Sources opened and commands run (2026-11-13)

Opened: `deploy/Dockerfile`, `deploy/docker-compose.qa.yml`, `docker-compose.yml`, `deploy/redeploy-qa.sh` (steps 1-6), `deploy/nginx/letflow-test.conf` (grep), `config/runtime.exs` (secrets key, `DATABASE_URL`, `POOL_SIZE`, OIDC, SMTP, proxies, upgrade flag by grep), `scripts/backup/README.md`, `scripts/demo/demo_platform_bootstrap.sh` (header), `scripts/oss_audit/README.md`, `docs/design/offline-package-signing.md` (sections 0-7), `docs/design/rolling-deploy.md` (sections 5 and 7), `docs/design/mes/07-roadmap-and-pilot.md` (section 1), `05-platform-options.md` and `11-readings-import-P3.md` (grep), `docs/runbooks/demo-instance.md`, `demo-operator-inputs.md` (headings and O3 lines), `onboarding-new-tenant-realm.md`, `tenant-provisioner-credential.md` (headings), `lib/letflow/routers/tenant_modules.ex` (route list), `lib/letflow/router.ex` (health, ready).

Not-found greps: `ls | grep -i licen` (empty); `git ls-files | grep -i -E "^(license|copying|notice)"` (empty); `grep -rn "Plug.Static\|index.html" lib --include=*.ex` (empty); `grep -rn "ntp\|chrony\|skew" lib/letflow` found only unrelated "clock" mentions in files listed as using the word (audit, dlq, documents, help, identity migration; not read); `grep -n "release" mix.exs` (comment only); `ls rel` (absent).

Not read: the full T-1519 note beyond what `offline-package-signing.md` quotes (its path exists in the sibling repository), `deploy-rules.md` in full, `promote-demo.sh` (infra's), the Keycloak realm files, the app's mail use outside the login-directory sender. Nothing was run or installed; no network was used.
