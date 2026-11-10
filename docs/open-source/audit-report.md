# Open-source exposure audit of tvolodi-org/letflow (T-1597, OSS-1)

Written 2026-11-10. Read-only audit: nothing was removed, rewritten, rotated or pushed. The repository stays public
(owner decision, PM 2026-11-10). This report holds no secret values: only service names, paths, short commit ids and
counts. The raw scanner output (masked hints are still partial secrets) is kept outside the repository.

> **ROTATE NOW (see section 4):** one shared bearer token for the team's task-queue service is written in clear text in
> 12 tracked `handoffs/` files and in history since commit `e2b8ce689` (2026-09-23). Its liveness was not tested.
> Treat it as live until the owner or infra rotates it, even after it is removed from the tree.

## 1. Scope and method

- Tool: `scripts/oss_audit/oss_audit.sh` (stdlib Python, pattern rules S01-S14, P01-P02, I01-I03, N01-N02; see
  `scripts/oss_audit/README.md`). `command -v gitleaks trufflehog git-filter-repo` prints nothing on the host
  (exit 1): none of the three is installed, so no dedicated secret-scanning tool was used. Installing one needs the
  owner's approval; a second pass with gitleaks or trufflehog is recommended before the repository is promoted.
- Working tree: the files **tracked** at HEAD `0981a7c8b2c7` (11,058 files, of which 3,864 under `handoffs/`, 1 under
  `state/`; `replay-work/` does not exist on main). **Limitation:** ignored or untracked local files (for example a local
  `.env`, which `.gitignore` excludes) are not read, because they are not public; passwords in such a file are not
  covered here. A tracked env file or example is covered.
- History: `git log --all -p -U0 -m --no-renames` (all refs, merge-resolution lines and renamed-and-edited files
  included), 5,710 distinct commits = `git rev-list --all --count` (5,710), 401 refs, not a shallow clone. Binary
  files seen in history were read with `git cat-file` (51 distinct blobs), and SQLite files are opened in memory
  and scanned table by table: `state/team.db` (current and every historic version) has 8 tables and **0 rows**
  (schema only), so it holds no data. 130 other tracked binaries got a strings-style pass. 46 very long lines were
  scanned in windows, none truncated.
- Coverage line of the run: `COMPLETE` (no deadline, no oversize file, no blob cap, no rule error); elapsed 98 s.
- Not covered: commit metadata (author names and e-mail addresses: 3 distinct author addresses exist in history,
  one is the owner's personal address), GitHub-side data (issues, PR text, Actions logs, releases), the scanner's own
  files, its test and this report (excluded because their text matches their own rules), and
  base64/encoded or split secrets. Pattern rules miss unknown token formats; entropy rule S14 was off.
- Counts below are findings after de-duplication per (rule, path, value). A hit is a lead; each class below was
  triaged by opening the file locally and replacing the value with its length in the notes.

## 2. Verdict

- AUTHENTIC CREDENTIAL EXPOSED IN PUBLIC REPO: needs-owner-check (probable yes). The shape is a 64-character
  hexadecimal bearer token used in `curl` commands against the task-queue service at the test host (`queue-test`
  under the owner's domain). It appears identically in many files, which is how a shared service token behaves. Only
  the owner or infra can say whether it is a real token.
- LIVENESS: not tested by this audit (a read-only audit never calls a service); treat as live until the owner/infra
  rotates or confirms revoked.
- No private key, cloud-provider key, Keycloak admin or client secret, connection string with a real credential, GitHub
  / OpenAI / Anthropic token, or real JWT was found in the tree or in history.
- PR title carries `SECURITY` because of the first bullet.

## 3. Findings by severity

Totals of the run: C = 6, H = 601, M = 223, L = 8,800 (tree and history rows together; most history rows repeat a
tree row). The audit was re-run after the review changed the credential filter twice: a password is no longer ignored
for having no digit, containing the word `test`, containing a period, or starting with `@`. Only explicit code
references are skipped (`$VAR`, `${VAR}`, `:atom`, `@module_attr`, `params.password`-style accessors, CamelCase module
paths). That raised H from 116 to 559 and then to 601 (rule S13: 284 tree rows in 178 files, 222 of the rows under
`test/`, 51 under `handoffs/`: fixture passwords of tests and transcripts); C stayed at 6, all of them the F1 token.
The non-test, non-handoff S13 rows (config/runtime.exs, three `docs/issues` files, `docs/requirements.yaml`, the two
realm templates, `scripts/e2e/stack_up.sh`, `scripts/uat_preflight.sh`) are the same set as before the second change;
they were opened and are field names, environment-variable reads, prose or the local e2e stack's own throw-away
accounts (F7); none is a live credential.

| Id | Class | Rule | Path class | Count (tree) | First commit | In HEAD | Action |
|---|---|---|---|---|---|---|---|
| F1 | credential: task-queue service (bearer) | S10, S13 | `handoffs/` (12 files, 20 occurrences) | 12 files | `e2b8ce689` | yes | rotate, then remove |
| F2 | infra: owner hostnames (demo, auth-demo, QA, test hosts, queue hosts) | I03 | docs, runbooks, `handoffs/`, `deploy/nginx`, scripts, tests | 38 | early 2026-08/09 | yes | keep (public by design) except queue hosts: move-private |
| F3 | infra: a server host name and its public IPv4, and one client IPv4 | I01 | `docs/issues/ISS-0690.yaml`, one UAT report, `handoffs/WF03-ISS0703-...` | 3 files | 2026-09 | yes | remove from tree; rotate nothing, consider reprovisioning if the address is sensitive |
| F4 | infra: public Cloudflare ranges in the nginx config and one handoff; example addresses and version strings in tests and specs | I01 | `deploy/`, `handoffs/`, `test/`, `docs/` | 38 | n/a | yes | keep (public data / not addresses) |
| F5 | personal data: the owner's personal address in git-identity transcripts | P01 | `handoffs/` (4), `docs/issues/ISS-0350.yaml`, one design file, one test | 7 | 2026-08/09 | yes | move-private (handoffs); keep none in docs |
| F6 | personal data: dummy addresses (`x.com`, `b.com`, `x.kz`, `host.tld` ...) | P01 | tests, specs | 28 | n/a | yes | keep |
| F7 | secret-shaped but not secret: password policy text, field names, `${VAR}` references, fake JWT constants in tests and a design note, `Bearer` placeholders | S11, S13 | tests, docs, `priv/keycloak/provisioner`, `scripts/e2e/stack_up.sh` | 8 + 284 | n/a | yes | keep (false positives) |
| F8 | internal-only text: operator transcripts and agent hand-offs | none (path class) | `handoffs/` (3,864 files, incl. `orchestrator.log`, `registry.json`) | 3,864 | 2026-08 | yes | move-private (see section 7) |
| F9 | internal-only text: local Windows user paths and the predecessor system path | N02 | `handoffs/` (414), `lib/letflow/design` and docs (about 120), tests, `docker-compose.yml`, `CLAUDE.md` | 596 | 2026-08 | yes | remove from tree (docs, compose comment); handoffs with F8 |
| F10 | customer and partner wording: BilimBaga, Qoimeks | N01 | tests, docs, `web/`, `lib/`, `priv/` seeds, `docs/uat`, handoffs | about 400 | 2026-08 | yes | see section 6 |
| F11 | company wording: ai-dala, R-Co (predecessor), and the demo verticals Meridian, SwiftRoute, Vortex | N01 | everywhere | about 3,300 | 2026-08 | yes | see section 6 |
| F12 | `state/team.db`: schema only, no rows | n/a | `state/` | 1 file | `a6ca41fea` (2026-11-04) | yes | remove from tree (engine state does not belong in the product repo); no data to purge |

## 4. Exposed credentials: rotate now

| Service (not the value) | Where | Commit first seen | Liveness | Action |
|---|---|---|---|---|
| Task-queue service bearer token (`queue-test` host, task release/claim API) | 12 tracked `handoffs/` files: the step records of WF02-REQ390, 393, 395, 396 and WF03-ISS0761, 0774, 0785, 0788 (`step-00-git-setup`, `step-02a-*` and `step-final-*` files) | `e2b8ce689` (2026-09-23) | not tested | owner/infra rotates the token **now**; removing it from the tree does not help, it stays in history and in every clone |

No other credential class was found. Whether other secrets exist in places the scanner cannot see (issue comments,
Actions logs, PR descriptions, release assets) is unknown and is an open question for the owner (section 9).

## 5. Internal-only text

- `handoffs/`: 3,864 tracked files of the old agent pipeline: step records, validator reports, `orchestrator.log` and
  `registry.json`. They hold operator transcripts, host names of the test and demo servers, local paths, a server
  provider host name, a client IP address and the owner's identity strings. The product does not read these files at
  run time (only `handoffs/registry.json` and `handoffs/*/step*` are named by CI path rules).
- `state/team.db` (engine state, schema only) and a few operator notes in `docs/uat/ba-decisions/`.
- `replay-work/`: not present on main.
- Local paths of the owner's Windows machine (`c:\Users\...`) in about 600 places, mostly in `handoffs/`; also in
  `docker-compose.yml` and `CLAUDE.md` comments (the predecessor stack path).
- Infra names: the demo / auth-demo / QA / test host names under the owner's domain (38 places), the Hetzner-style
  server name and its address in two files.

## 6. Customer and company wording

Counts are content hits in the tracked tree (de-duplicated per path and word), by path area.

| Word | tests | docs / runbooks / migration / UAT | lib and priv (seeds, fixtures) | web | handoffs |
|---|---|---|---|---|---|
| BilimBaga | 212 | 66 + 26 + 9 | 40 + 24 | 54 | 41 |
| Qoimeks | 9 rows in total, spread over docs, runbooks and UAT files | | | | |
| Meridian / SwiftRoute / Vortex (UAT demo verticals) | 130 / 298 / 123 | 77 / 59 / 65 | 28 / 39 / 33 | 19 (SwiftRoute) | 156 / 148 / 135 |
| R-Co (predecessor system) | 146 | 103 + 36 | 265 + 38 | 7 | 475 |
| ai-dala (company name and domain) | 73 | 83 + 31 | 77 + 13 | 0 | 437 |

297 tracked file **names** also contain a vertical or partner word (seed scripts, fixtures, test files). The scanner
reads content, not file names; that count comes from `git ls-files`.

Triage: BilimBaga and Qoimeks are real customers/pilots; their names occur in exam-module code, seeds, tests and
UAT files, which is also what makes the product recognisable to them. Meridian, SwiftRoute and Vortex are the platform's
own UAT demo verticals (invented companies in the repository's docs and seeds); they were not found to be customers.
R-Co and ai-dala are the owner's own systems/company. No customer personal data, price or contract text was found
in the sampled hits.

## 7. Recommended actions per finding group

| Group | Action | Why |
|---|---|---|
| F1 task-queue token | **rotate** (owner/infra), then **remove from tree** | the only credential found; history keeps it forever |
| F8 `handoffs/` (3,864 files), `state/team.db` | **move to a private repository**, keep only `handoffs/registry.json`-style files the product's CI reads, or delete from the tree and keep in the private repo | internal pipeline text with hosts, paths, identities; no product function |
| F9 local paths in docs, compose, `CLAUDE.md` | **remove from tree** (rewrite the comments) | personal path leakage, cheap to fix |
| F3 server name and IPs | **remove from tree** | reveals the owner's host and a client address |
| F5 owner address | **move-private** with `handoffs/`; remove from the design/issue docs | personal data |
| F2 demo/QA/test host names | **keep** (demo hosts are public); **move-private** the queue hosts with `handoffs/` | |
| F4, F6, F7 | **keep** | public ranges, dummy addresses, false positives |
| F10, F11 customer and company wording | **keep** BilimBaga/Qoimeks in code, seeds and tests unless the customer objects (owner decision, section 9); **keep** the demo verticals and R-Co/ai-dala; **move-private** the copies inside `handoffs/` with F8 | |
| Scanner | **keep** `scripts/oss_audit/` and re-run it before any release or visibility decision | read-only, safe |

Removing files from the tree changes HEAD only. History still holds everything above; see section 8.

## 8. History rewriting: proposal only, not executed

A rewrite is warranted for the token only if the owner wants to reduce exposure; **rotation is the real remedy**,
because the repository is public and clones, forks and caches already exist. Optional scope of a rewrite: the task-queue
token (replace text) and, if decided, `handoffs/` and `state/` (path removal).

Plan (nothing of this was run; `git-filter-repo` is not installed on the host and installing it is the owner's call):

1. Rotate the token first.
2. Pause the team engine and all worktrees (`state/worktrees/*`); freeze merges.
3. Fresh mirror clone; run `git filter-repo` with `--replace-text` for the token and, if decided, `--path handoffs/
   --path state/ --invert-paths`, over all refs.
4. Verify with this scanner on the mirror; compare the file tree of `main` before and after.
5. Force-push all refs (branches and tags) to `tvolodi-org/letflow`; this needs the `main-queue` ruleset bypass.

Consequences:

- Every commit id changes. Anything that cites a commit id breaks: `handoffs/registry.json`, runbooks, issue and PR text,
  decision records, the team's task database, `team/*` branches and open worktrees (must be re-cut).
- All open PRs and their review comments detach from the new history; the merge queue and required checks restart.
- Forks and clones (the repository is public, so unknown third parties) keep the old history and the token. GitHub
  keeps unreachable objects and cached pull-request refs until its support purges them.
- CI caches and any pinned shas fail until re-seeded; auto-CD deploys main, so the first post-rewrite merge redeploys.
- Alternative with the same exposure effect for much less risk: publish a fresh squashed repository (as in
  `docs/uat/ba-decisions/T-1521.md` section 0.3) and make the old one private.

This needs the owner's decision.

## 9. Open questions for the owner

1. Is the 64-character token in `handoffs/` a live credential of the queue service? Rotate it now either way.
2. Does the queue-host name need to stay private? (It is in F2 and F8.)
3. Remove `handoffs/` and `state/` from the public tree (and move to a private repository), or keep them?
4. Rewrite history, squash into a new repository, or neither? (section 8)
5. Are BilimBaga and Qoimeks content allowed to stay public, and under what licence? The repository still has no LICENSE
   file.
6. Are issue comments, PR text, Actions logs and release assets reviewed? They are outside this audit.
7. Run a second pass with a dedicated tool (gitleaks or trufflehog) after approving its installation.
