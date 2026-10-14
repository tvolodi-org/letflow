# 0039 — Platform / module / solution / tenant-configuration layering, as a modular monolith

Amended by 0053 (`0053-tenant-scripted-rules.md`): D7's 'Client scripts are not in scope ... a later decision once that registry exists' is superseded for tenant scripted rules. D8 is interpreted for the business suite by 0050 (`0050-foundation-modules-org-catalog-and-reference-contract.md`).

Status: decided (2026-09-24, user-directed); `REVIEWER` PASS 2026-09-24 on
second review (section at the end). Owner: `ORCH` (stage S11). Amends 0022 (where bucket-C code lives);
leaves 0026, 0027 and 0029 standing unchanged.

## Question

BilimBaga (0022) was the first vertical. Building it exposed that Letflow has
two layers — the **platform** and **one tenant's pack** — and nothing in
between. The user's direction (2026-09-24): Letflow should offer reusable
**application modules** (exam, HR, project management, WMS, ERP, …) that are
combined, like building blocks, into a **solution** for a concrete client, and
the client then **configures** that solution. At the same time the project stays
**one monolith** — one repository, one pipeline, one deployment.

Two questions:

1. Is a four-layer shape — platform core → application module → solution
   (a set of modules) → client configuration — achievable inside one monolith?
2. If so, what concretely is each layer in this codebase?

## Evidence: the missing layer is already costing something

Re-verified in the tree on 2026-09-24. BilimBaga's exam domain is not contained
anywhere; it is threaded through platform code:

| Where | What the platform knows about exams |
|---|---|
| `lib/letflow/definitions/solution_pack.ex` (`alias Letflow.Packs.Bilimbaga`, `seed_pack_specific_field_restrictions/2`) | The **generic** pack installer calls BilimBaga-specific code by name. |
| `lib/letflow/api/authorization.ex` (`:ExamSessionStart` … `:ExamSessionReportEvent`, `:ExamCertificateIssue`) | Exam permissions are compiled into the platform permission set, for every tenant. |
| `lib/letflow/plugs/api_pipeline.ex` (`forward("/exam-sessions", …)`) | Exam routes are mounted for every tenant, whether or not it runs BilimBaga. |
| `lib/letflow/routers/tenant_config.ex`, `lib/letflow/routers/help.ex` | Doc-comment mentions only (`tenant_config.ex:290`, `help.ex:80,83`). The real dependency runs exam → core (`lib/letflow/exam/certificate.ex:202` aliases `Letflow.Routers.TenantConfig`), which D3 permits — not a seam to replace. |
| `web/src/router.tsx`, `web/src/components/layout/AppShell.tsx` (`/exam`, `/admin/bilimbaga` nav items) | Exam screens are part of every tenant's SPA. |
| `lib/letflow/exam/` (≈3,000 lines) | Bucket-C code lives in the platform's own namespace. |

0022's bucket rule stopped exam *names* entering bucket-B requirements, but it
gave bucket C no boundary of its own — so the wiring that connects bucket C to the
running system had nowhere to go but into the platform. A second vertical built
the same way would add a second set of these threads. That is the problem this
record solves.

## Decision

**Yes — as a modular monolith.** One repository, one OTP application, one
release, one agent pipeline (0004), one set of gates. Layers are separated by
**enforced code boundaries and a runtime per-tenant install list**, not by
separate repositories, umbrella apps, or separate deployments.

### D1. The four layers

| Layer | Definition | Lives in | May depend on |
|---|---|---|---|
| **Platform core** | Tenancy, identity, roles, entities, process engine, forms, scripting runtime, audit, event store, UI shell. Names no business domain. | `lib/letflow/` (except `lib/letflow/modules/`), `web/src/` (except `web/src/modules/`) | nothing above it |
| **Application module** | A named, versioned unit of business functionality: its definitions (a solution-pack document), and optionally its own backend code, routes, permissions and screens. Example: `exam`. | `lib/letflow/modules/<id>/`, `web/src/modules/<id>/`, `priv/modules/<id>/` | core's public API + modules listed in its own `depends_on` |
| **Solution** | A manifest: a list of `{module_id, version}` plus default module settings. It carries **no content of its own**. Example: `bilimbaga` = `[exam]`. | `priv/solutions/<id>.json` | modules |
| **Tenant configuration** | Per-tenant data: which modules are installed, module settings values, branding. Stored as tenant data, **never as code**, never as an edit to a module's own definitions. | tenant schema / tenant settings | a module's declared settings schema |

### D2. One application, not an umbrella or separate repos

Modules are directories and a namespace (`Letflow.Modules.<Id>`) inside the
existing `:letflow` OTP application. Rejected alternatives:

- **Umbrella / separate OTP apps per module** — adds per-app `mix.exs`, config
  and dependency plumbing to every requirement, which weak executing models get
  wrong, in exchange for a boundary a compile-time check (D3) gives more cheaply.
- **Separate repositories per module or per client** — rejected by 0022 §2
  (a fork loses the shared gate) and 0011 §3, unchanged.

### D3. Boundaries are enforced by a check, not by convention

A boundary no tool checks will be crossed by the first agent in a hurry.

**What is core and what is a module (file-level, exact).** The module
*mechanism* is core code and lives directly in `lib/letflow/modules/*.ex` (one
level, no subdirectory): `Letflow.Modules.Module` (behaviour),
`Letflow.Modules.Catalog`, `Letflow.Modules.Installs` (install context) and
`Letflow.Modules.TenantModule` (schema). A **module** is everything under a
subdirectory, `lib/letflow/modules/<id>/`, namespace `Letflow.Modules.<Id>.*`
(the entry module `Letflow.Modules.<Id>` lives at
`lib/letflow/modules/<id>/<id>.ex`, never at `lib/letflow/modules/<id>.ex`). The frontend
mirrors this: `web/src/modules/registry.ts` and `web/src/modules/types.ts` are
core; `web/src/modules/<id>/` is a module.

Two checks, both run in CI and both failing the build:

1. **Backend** — a mix task `mix letflow.check_boundaries`, built on
   `mix xref graph --format plain` (file-level edges; no new dependency), that
   fails when:
   - any file outside `lib/letflow/modules/<id>/` directories references a file
     inside one, **except** `lib/letflow/modules/catalog.ex`, which is the one
     sanctioned place core learns the module list;
   - a file in `lib/letflow/modules/a/` references a file in
     `lib/letflow/modules/b/` when `b` is not in `a`'s `depends_on`.

   Known limit, accepted: xref does not see `apply/3` or string-built module
   names. Core code therefore never builds a module name dynamically; it only
   calls functions on entry modules the Catalog returns.
2. **Frontend** — an ESLint `no-restricted-imports` rule with the same two rules
   for `web/src/modules/<id>/`, with `web/src/modules/registry.ts` as the one
   sanctioned importer of module code.

A module *may* call any public function of core. "Public" means a
documented function on a context module (`@doc` present, not `@doc false`); this
record does not introduce a separate public-API layer.

### D4. The module contract

Each module has one entry module implementing a behaviour
`Letflow.Modules.Module`:

- `manifest/0` — `%{id, version, depends_on: [module_id], pack: path | nil,
  permissions: [atom], role_grants: %{role_atom => [permission_atom]},
  required_roles: [String.t()], settings_schema: map | nil}`.
  `required_roles` is **advisory**, exactly as 0029 §2 keeps
  `manifest.required_roles` advisory — a module does not create roles.
- **Permissions and who holds them.** A module declares its own permission
  atoms in `permissions` and grants them to **existing** platform roles in
  `role_grants`. Rules:
  - `Letflow.Api.Authorization.permissions/0` returns core's `@permissions` plus
    every Catalog module's `permissions`. The core `@type permission` stays the
    core union; module permissions are typed `atom()` at the Catalog boundary.
  - `role_allows?/2` keeps every existing core clause first, then falls back to
    the Catalog: `true` iff some module's `role_grants[role]` contains the
    permission. `PLATFORM_ADMIN`'s existing catch-all is unchanged.
  - Every key of `role_grants` must be in `Authorization.roles/0`, and every
    granted atom must be in that module's own `permissions`; a test fails
    otherwise. A module cannot create a role and cannot grant a core permission.
  - The existing closed-set tests (ISS-0646's "CANDIDATE holds exactly these
    permissions" assertion, and any test enumerating `permissions/0`) are
    updated to assert the same sets, now sourced through the Catalog. They must
    pass unchanged in meaning.
  - Applied to `exam`: the six atoms (`:ExamSessionStart`, `:ExamSessionRead`,
    `:ExamSessionSave`, `:ExamSessionSubmit`, `:ExamSessionReportEvent`,
    `:ExamCertificateIssue`) move to the exam manifest, and
    `role_allows?(:CANDIDATE, …)` becomes `role_grants: %{CANDIDATE: [those six]}`.
    The `CANDIDATE` role atom itself stays in core (see 0013 below).
- `router/0` — optional; a Plug router the platform mounts under
  `/api/v1/modules/<id>/…`.
- `on_install/2` — optional; tenant-scoped (`prefix` passed in, per INV-1), runs
  inside the install transaction after the module's pack is installed.

`Letflow.Modules.Catalog` reads the compiled list of modules from application
config (`config :letflow, :modules, [...]`) and is the **only** core code allowed
to name module modules. Every core seam that today names exam code (the table
above) is replaced by a Catalog lookup: the pipeline mounts each registered
module's router, `Letflow.Api.Authorization` unions each module's declared
permissions, and the pack installer calls `on_install/2` rather than
`Letflow.Packs.Bilimbaga`.

### D5. Modules are installed per tenant, and uninstalled modules are invisible

- A tenant-scoped table (`tenant_modules`: `module_id`, `version`, `installed_at`,
  `settings`) records what a tenant has.
- Installing a module checks every `depends_on` entry is already installed (or
  installed in the same request, in dependency order), installs its pack through
  the **existing** `Letflow.Definitions.SolutionPack.install/3`, then calls
  `on_install/2` — all in one transaction.
- A request to `/api/v1/modules/<id>/…` from a tenant without `<id>` installed gets
  `404`, not `403`. A module's absence is not information to leak.
- **Who may install.** A new core permission `:ModulesManage`, granted to
  `PLATFORM_ADMIN` only (same pattern as `:TenantsManage`), gates module install,
  solution install (D6) and module-settings writes (D7). Listing a tenant's
  installed modules needs only an authenticated tenant user (it is what `GET /me`
  exposes anyway).
- **No uninstall in S11.** Removing a module safely means deciding what happens
  to its definitions and tenant data; that is not decided here. S11 builds
  install and list only. Uninstall is an open item in the stage file.
- The SPA reads the installed-module list from `GET /me` and builds its routes
  and navigation from it; a module's screens are not reachable at all for a
  tenant without it.

### D6. A solution is a manifest, and installing it is installing its modules

`priv/solutions/<id>.json` lists modules, versions and default settings.
Installing a solution into a tenant installs each module in dependency order
(D5), then writes the defaults into each module's `tenant_modules.settings`.
Nothing is special about a solution after install — the tenant simply has
modules. The solution is not stored as its own runtime entity.

### D7. Tenant configuration is additive only

A client configures a solution by **setting values a module declared**
(`settings_schema`, validated on write), never by editing the module's own
definitions in place. This is what lets one module version upgrade under many
tenants. Where a tenant *has* changed an installed definition, the existing
3-way pack-update machinery in `solution_pack.ex` remains the fallback, not the
normal path.

**Client scripts are not in scope.** Declared extension points where a tenant
attaches its own Lua need a runtime invocation path and an audit path; 0029 §1
records that neither exists, and names the scripted-rule registry that must be
built first. This record does not change that. Extension points are a later
decision once that registry exists.

### D8. Modules are extracted from real demand, never built speculatively

No HR, WMS, ERP or project-management module is built until a real client
solution needs it. Shared concepts (organisation, department, employee) move
into a shared foundation module (e.g. `org`) **when a second module needs them**,
not before. The first and only module S11 creates is `exam`, extracted from
BilimBaga.

## Relationship to earlier decisions

- **0022 — amended, one point.** Bucket C ("genuinely exam-specific runtime")
  now lands in `lib/letflow/modules/exam/` and `web/src/modules/exam/`, not
  `lib/letflow/exam/` and `web/src/pages/exam/`. 0022 rule 1 generalises: a
  bucket-B (platform) requirement may not name *any* module's domain. Rules 2
  and 3 (REVIEWER sign-off for bucket C, rule 2 as scoped by 0032; the bucket-C inventory as a health
  metric) stand and now apply per module.
- **0026 / 0027 / 0029 — unchanged.** The solution-pack section set stays closed.
  A module *wraps* a pack; it does not add pack sections. Roles stay advisory.
  Scripts stay out. `on_install/2` is code, reviewed through the normal gates —
  not pack content — so it does not reopen 0029.
- **0013 (role set)** — the platform role `CANDIDATE` is exam-specific. Moving it
  into the exam module is **not** done by S11's first batch; it is recorded as an
  open item in the stage file, because it touches the role set 0013 fixed and
  needs its own design.
- **REQ-045** (row-lock engine, empty `InstanceSupervisor`) — unaffected. A
  module is a code boundary, not a process; no module gets its own supervisor
  unless its own design justifies one through the normal gates.

## Consequences

- **Stage S11 ("modular platform") is added**, `depends_on: [S10]`, detail file
  [`../stage-11-modular-platform.md`](../stage-11-modular-platform.md).
- Moving exam code is a mechanical rename plus seam replacement. It must keep
  S10's full test suite and the ported Playwright specs green.
- **Existing tenants keep working.** The P2 migration that introduces the exam
  module also inserts a `tenant_modules` row for `exam` into every tenant schema
  that already has the bilimbaga pack installed (a row in the global
  `solution_pack_installs` table with that tenant's `tenant_id` and
  `pack_id = "bilimbaga-question-bank"`, per `priv/packs/bilimbaga/pack.json`),
  written as a tenant-scoped migration (`if prefix() do` guard, same shape as
  `priv/repo/migrations/20260923010002_create_user_entity_type_grants.exs`).
  Without it, D5's 404 would cut those tenants off.
- **The URL move has no external consumers.** `/api/v1/exam-sessions` is called
  only from inside this repository; there is no production deployment (see
  `CLAUDE.md`), and QR verification links use `CERTIFICATE_VERIFY_BASE_URL`, not
  this route (`lib/letflow/routers/exam_sessions.ex:706-709`). The P2 move
  updates every live caller: `web/src/`, `web/tests/e2e/`, `test/`,
  `lib/mix/tasks/letflow.seed.exam_fixtures.ex`, `test/fixtures/uat/`, and the
  agent docs that cite it (`.claude/agents/ba-analyst.md`,
  `.claude/agents/product-owner.md`, `docs/agents/ba-personas/bilimbaga.yaml`).
  Historical records (`test/uat-reports/`, `test/reports/`, `lib/letflow/design/`)
  are left as written.
- **The payoff is measured, not assumed.** S11 is done when all three hold:
  1. `mix letflow.check_boundaries` passes in CI (no core file references a
     module file, per D3's xref rule);
  2. `lib/letflow/api/authorization.ex` contains none of the six exam permission
     atoms listed in D4 in code (typespecs, `@permissions`, function clauses);
     `@moduledoc`/`@doc`/`#` comment text is excluded;
  3. `lib/letflow/exam/`, `lib/letflow/packs/bilimbaga.ex`,
     `lib/letflow/routers/exam_sessions.ex` and `web/src/pages/exam/` no longer
     exist.

  The only exam-specific item allowed to remain in core is the `CANDIDATE` role
  atom in `Authorization.roles/0` (`@roles`, the `@type role` union) and its
  `role_from_string("CANDIDATE")` clause (the private helper behind
  `roles_from_strings/1`). Prose
  mentions of exams in doc comments are not counted.

## REVIEWER sign-off

**2026-09-24 — REVIEWER — FAIL** (direction sound; seven gaps block requirement filing).

**1. Decision-record consistency.** No silent contradiction. 0001: module
`router/0` as a Plug router matches the 0001 addendum (Plug/Bandit stands;
`api_pipeline.ex:83` `use Plug.Router`). 0004, 0011 §3, 0022 §2 (no fork) are respected.
0014/0029 §1: scripts stay out (D7). 0029 §2: `required_roles` stays advisory.
`on_install/2` leaves 0029 intact because it is reviewed code, not pack content.
That holds only while the manifest carries no executable content; `pack` is a path,
so it holds. REQ-045: no process per module, consistent. The 0022 amendment is
correctly scoped. It did not cite 0032's rule-2 scoping, so I added that
citation. 0013: `CANDIDATE` deferral is honest, but see R2.

**2. Factual accuracy.** Verified: `solution_pack.ex:184,1627-1639`,
`authorization.ex:257-262,364-369`, `api_pipeline.ex:163`, `router.tsx:89-112`,
`AppShell.tsx:23,58`, `lib/letflow/exam/` = 2,998 lines. **Corrected:** the
`tenant_config.ex` row was a doc-comment mention only, and the real edge runs exam → core
(`certificate.ex:202`). **Corrected:** the prefix is `/api/v1/modules/<id>/…`
(`router.ex:130` mounts `ApiPipeline` at `/api/v1`) in both files.

**3. OTP/idiom.** D2 is sound. A single app with checked namespace boundaries is
standard Elixir practice. D3 is feasible without a dependency: `mix xref graph
--format plain` gives file-level edges. Those are enough because namespace maps to directory.
It cannot see dynamic `apply/3` or string-built module names. `Registry` over
`Application.compile_env` is idiomatic. It should be a plain module, not a process
(no supervision change). Non-blocking: the name shadows Elixir's `Registry` when aliased.

**4. Required changes (FAIL):**
- **R1** Reserve the mechanism files (`lib/letflow/modules/*.ex`: `Module`,
  `Registry`, the install context and schema) as core. The D3 rules apply only to
  `Letflow.Modules.<Id>.*` and `lib/letflow/modules/<id>/`. Name the frontend
  registry exception (e.g. `web/src/modules/registry.ts`).
- **R2** D4 lists module `permissions` but says nothing about **which roles are granted them**.
  `authorization.ex:1130` `role_allows?(:CANDIDATE, …)` names exam atoms. Also cover
  the ISS-0646 closed-set test and the closed `@type permission` union.
- **R3** P2 must backfill `tenant_modules` with `exam` for every tenant that has a
  bilimbaga `solution_pack_installs` row. Without that, the D5 404 breaks hard constraint 1.
- **R4** Define uninstall (check dependents; keep data and definitions; remove the row only),
  or drop uninstall from P1.
- **R5** Name the permission/role that gates install and settings writes.
- **R6** Replace the "Consequences" grep. It matches doc comments (`help.ex`,
  `tenant_config.ex`) and cannot reach zero honestly. Use an xref-based code-reference
  check and give the exact `CANDIDATE` carve-out.
- **R7** State that `/exam-sessions` has no external consumers beyond `web/`
  (QR verify URLs use `CERTIFICATE_VERIFY_BASE_URL`, `exam_sessions.ex:706-709`).

**2026-09-24 (re-review) — REVIEWER — PASS.** R1–R7 are all addressed and checked
against the tree.

- **R1** D3 is now file-level and exact, with `catalog.ex` and `registry.ts`
  as the only sanctioned importers. The dynamic-`apply` limit is stated.
  Renaming the module to `Catalog` removes the `Registry` shadowing.
- **R2** D4's `role_grants` fallback is sound. The `PLATFORM_ADMIN` catch-all
  (`authorization.ex:1005`) still covers module permissions. The `CANDIDATE`
  clause (`authorization.ex:1130-1139`) must be *removed*, not left above the
  fallback, and D4's "becomes `role_grants`" says exactly that.
- **R3** The backfill is feasible. `solution_pack_installs` is global
  (`solution_pack_install.ex:23`), and tenant-scoped migrations use the
  `prefix()` guard. **Corrected:** I named the exact
  `pack_id` (`"bilimbaga-question-bank"`, `pack.json:742`) and the migration shape.
- **R4/R5** Uninstall is deferred to an open item. `:ModulesManage` follows the
  `:TenantsManage` pattern (`authorization.ex:349,598`).
- **R6** All three measurements are checkable. **Corrected:** measurement 2 now
  excludes doc and comment text (moduledoc `authorization.ex:137` names the atoms),
  and the `CANDIDATE` carve-out now names `role_from_string/1` (`authorization.ex:452`).
- **R7** The caller list matches `grep -rl exam-sessions`. The `test/` directory
  covers the four extra test files.

Non-blocking, for the implementing run: module permissions are typed
`atom()` at the Catalog boundary, which is a type-safety gap.
When P1's code lands, REVIEWER should file it under `docs/issues/`
tagged `type-safety`. Candidate fix: a compile-time check that every
`role_grants` atom is in `permissions`.
