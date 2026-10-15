# GH #2623: refuse `_sys` references in a service-catalog `endpoint_url` at register and publish

Author: CODE-DESIGNER, 2026-10-15. Branch `design/GH-2621-2623`, from `origin/main` `10e6688f`.
Parent: #2587 / REQ-499 (decision 0054 D1a; invariant I-13 of
`gh2587-req499-pr-a-prerequisites.md` 2A.7). Depends on PR A1b (merged `4053c30a`).
Must land BEFORE #2587 PR B. Design only: signatures, shapes, test briefs; no bodies.

## Changelog

* Revision 0 (2026-10-15): first design. Supervisor ruling of 2026-10-15 on the issue is the
  source of the requirement; section 7 lists what still needs a ruling.

* Revision 1 (2026-10-15): CDV PASS_WITH_FINDINGS and supervisor rulings applied. F5 positive
  and no-op-detecting test; F6 exact inventory pattern and result cited (0 rows); F7 regex
  grep scoped (the directory has no regex literal); F8 docs location. OQ-1..OQ-5 closed
  (section 9).

## 0. Sources and verification (all on `origin/main` `10e6688f`)

| Fact | Where |
|---|---|
| ONE placeholder grammar: `template_placeholder/0` returns `~r/\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}/`; KEY class has no dot; I-13 text says a change to it must ship the catalog check | `lib/letflow/engine/service_task.ex:346-363` |
| `template_variable_keys/1` = captured KEYs in order, `nil` -> `[]` | `service_task.ex:366-376` |
| the renderer substitutes with that grammar, for inline `url_template` and for the PINNED catalog `endpoint_url` | `lib/letflow/engine.ex:1162, 1180, 1416-1424` |
| pinned version resolved by id / `(service_id, version)`, never from the live row | `engine.ex:1309`; `lib/letflow/service_catalog.ex:569-640` (`locate_pinned_version/2`) |
| A1b's predicate for templates: keys from `template_variable_keys/1` filtered by `VariableMerge.reserved_key?/1`; reserved = `"_sys"` or prefix `"_sys."`, case-sensitive | `lib/letflow/definitions/reserved_references.ex:148-156`; `lib/letflow/engine/variable_merge.ex:306-311` |
| the pin test: the placeholder source is pinned and must not contain `a-zA-Z0-9_.` | `test/letflow/definitions/reserved_references_test.exs:373-390` |
| register: `Entry.insert_changeset/2`, which calls `validate_endpoint_url/1` | `lib/letflow/service_catalog.ex:222-250`; `lib/letflow/service_catalog/entry.ex:150-156` |
| publish: `Entry.publish_changeset/2`, which calls the same `validate_endpoint_url/1` on the EFFECTIVE value (`get_field`), so an inherited stored URL is covered | `service_catalog.ex:345-415`; `entry.ex:192-224, 285-310` |
| `check_endpoint_url/1` (pure, advisory): head up to the first `/ ? #` must have no brace and pass `UrlValidator.validate_syntactic/1`; the tail is not inspected | `entry.ex:255-266` |
| error shape: `add_error(:endpoint_url, msg, validation: :endpoint_url_not_allowed)`; every changeset error on the admin routes is today the generic `Response.unprocessable(conn, "validation failed")` | `entry.ex:299-307`; `lib/letflow/routers/admin_services.ex:228-231, 310-313` |
| 422 JSON bodies with a stable `"error"` code exist for peers | `lib/letflow/api/response.ex:195-217` (`script_binding_invalid`, `expression_references_reserved_variable`, via `send_json/3` `:73`) |
| versions are immutable once archived; `service_catalog_versions` is written only by `publish/3`; `retire/1` flips the live row | `service_catalog.ex:313-460`, `lib/letflow/service_catalog/version.ex` |
| only `register/1` and `publish/3` write catalog endpoint data in `lib/` and `priv/` (the other `Entry.insert_changeset` hit, `dlq.ex:110`, is the DLQ's own `Entry`) | grep on the tree |

### 0.1 What `{{variables._sys...}}` does at run time today

* `{{variables._sys}}`: matches the grammar; KEY `_sys`; the engine never sets the bare key
  (`put_sys/3` refuses it, `merge/3` refuses it), so it renders the empty string. No leak, but
  the reference is exactly what A1b refuses in a definition.
* `{{variables._sys.x}}`: does NOT match (dot-free class), stays literal text in the URL.
  The A1b parse sees no reference either. It is inert today and would render a real engine
  value the moment the grammar admits a dot (the I-13 trap).
* Therefore the refusal must detect a WIDER shape than the renderer grammar, without a
  hand-written second regex (D-2).
* A1b's L5/L6 definition check has the same blind spot for `{{variables._sys.x}}` in an
  inline `endpoint`/`body_template`; it is inert there for the same reason. Not changed here
  (scope fence); OQ-3.

## 1. Decisions (one-line rationale each)

* **D-1 Refuse at the catalog write, in the existing changeset validator.** One new refusal
  inside `Entry.validate_endpoint_url/1`, used by BOTH `insert_changeset/2` and
  `publish_changeset/2`. Rationale: the validator already reads the effective value, so
  supplied and inherited are one code path; no change to `register/1` or `publish/3` bodies.
* **D-2 Detection = the renderer's own grammar, widened by derivation, not a copy.**
  `ServiceTask` gains `template_reference_placeholder/0 :: Regex.t()`: the compiled form of
  `Regex.source(template_placeholder())` with its KEY class `[a-zA-Z0-9_]+` replaced by
  `[a-zA-Z0-9_.]+` (a dot admitted). It is derived from the single source at call time, so
  the prefix, the braces, the `variables.` literal and the `\s*` whitespace handling can never
  drift. If the strict KEY class is ever edited so the replacement no longer matches, the
  derived pattern equals the strict one (still correct, strict then admits dots). A function,
  not a module attribute (the existing convention for regexes). Rationale: the issue's "not a
  second regex that can drift"; follow-up #2624 (shared reference constructor) can replace
  the derivation later without changing this interface.
* **D-3 Predicate = `VariableMerge.reserved_key?/1`, applied to each derived KEY.** Exposed as
  `ReservedReferences.reserved_template_names/1` so the catalog calls the same module A1b
  uses. `_system`, `_SYS`, `a._sys`, `a.b` are NOT reserved (exact `"_sys"` or the `"_sys."`
  prefix, case-sensitive: the renderer is case-sensitive, so `_SYS` is a different, ordinary
  key). Rationale: one predicate for definitions and catalog.
* **D-4 New stable code `:endpoint_url_reserved_variable`, distinct from
  `:endpoint_url_not_allowed`.** Rationale: the AC asks for a stable code; the existing code is
  also used for scheme/host failures, so a client could not tell the two apart.
* **D-5 Reserved check runs BEFORE the syntactic check.** A `_sys` reference in the host
  position would otherwise answer `:endpoint_url_not_allowed` (a brace in the head). Rationale:
  a reference to the engine namespace always gets the specific code, wherever it sits.
* **D-6 HTTP: 422 with a JSON body `{"error": "endpoint_url_reserved_variable", "field":
  "endpoint_url"}`** from one new `Response.endpoint_url_reserved_variable/1`, used by both
  admin handlers. The body echoes no URL and no reference name. Rationale: same envelope style
  as the A1b/7c-1 peers; INV-2/INV-5 hygiene (the URL may carry a secret-bearing template).
  All other changeset errors on those routes keep today's generic 422.
* **D-7 `register/1` and `publish/3` keep their `{:error, %Ecto.Changeset{}}` result.** The
  router recognises the refusal by `changeset.errors[:endpoint_url]` opts
  `validation: :endpoint_url_reserved_variable`. Rationale: no new tuple member, so the typespec
  and every existing caller are unchanged.
* **D-8 No dispatch change and no data change in this PR for existing rows** (the default
  for both inventory outcomes; details in section 4). Rationale: the issue forbids silently
  changing dispatch of an already-pinned version; today's behaviour for a pinned `_sys`
  reference is inert (0.1).
* **D-9 Length and order.** The 2048-byte length error still wins (the validator already skips
  when `:endpoint_url` carries an error), then reserved, then the syntactic check.
* **D-10 I-13 is satisfied and re-pinned.** The reserved-references test that pins the strict
  source stays; a new test pins the derived pattern (section 5).

## 2. Interfaces (signatures and types only)

```
# Letflow.Engine.ServiceTask (lib/letflow/engine/service_task.ex)
@spec template_reference_placeholder() :: Regex.t()
# the strict template_placeholder/0 with its KEY class widened to admit "." ; derived, never hand-copied.

@spec template_reference_keys(String.t() | nil) :: [String.t()]
# the KEYs captured by template_reference_placeholder/0, in order, duplicates kept; nil -> [] . Pure, total.
# template_placeholder/0, template_variable_keys/1 and the renderers are UNCHANGED (byte-identical output).

# Letflow.Definitions.ReservedReferences (lib/letflow/definitions/reserved_references.ex)
@spec reserved_template_names(String.t() | nil) :: [String.t()]
# the template_reference_keys/1 KEYs for which VariableMerge.reserved_key?/1 is true, in order,
# duplicates kept; [] for nil, a non-binary, or no reference. Pure, total.

# Letflow.ServiceCatalog.Entry (lib/letflow/service_catalog/entry.ex)
@spec check_endpoint_url_references(endpoint_url :: String.t()) ::
        :ok | {:error, :endpoint_url_reserved_variable}
# :ok iff ReservedReferences.reserved_template_names/1 is []. Pure, no DNS. Independent of check_endpoint_url/1.
# validate_endpoint_url/1 (private) order: nil -> skip; existing :endpoint_url error -> skip;
# reserved -> add_error(:endpoint_url, msg, validation: :endpoint_url_reserved_variable);
# else the existing check_endpoint_url/1 branch unchanged.

# Letflow.Api.Response (lib/letflow/api/response.ex)
@spec endpoint_url_reserved_variable(Plug.Conn.t()) :: Plug.Conn.t()
# HTTP 422, body {"error": "endpoint_url_reserved_variable", "field": "endpoint_url"} via send_json/3.
```

Changeset error message (the router never renders it): "must not reference the reserved
engine variable namespace".

`Letflow.Routers.AdminServices` (`handle_register`, `handle_publish`): a new first clause
before the generic `{:error, %Ecto.Changeset{}}` that matches a changeset carrying the code,
and answers `Response.endpoint_url_reserved_variable/1`; the generic clause is unchanged.

DB tables / columns / migrations: NONE. No new permission. No change to `engine.ex`.

## 3. Detection table (what is refused; `E` = endpoint_url template)

| Template text | Refused | Why |
|---|---|---|
| `https://h/{{variables._sys}}` | yes | KEY `_sys` |
| `https://h/{{variables._sys.r}}`, `{{variables._sys.r.seq}}`, `{{variables._sys.}}` | yes | KEY starts `_sys.` |
| `https://h/{{ variables._sys }}`, `{{\tvariables._sys.x\n}}` | yes | the grammar's `\s*` |
| `https://{{variables._sys}}.h/x` | yes (`endpoint_url_reserved_variable`) | D-5 |
| `https://h/{{variables._system}}`, `{{variables._SYS}}`, `{{variables.a._sys}}`, `{{variables.x_sys}}` | no | not reserved |
| `https://h/_sys/{{variables.a}}` | no | text outside a placeholder |
| `https://h/{{Variables._sys}}`, `{{variables["_sys"]}}` | no | not matched by the renderer, rendered literally; same as A1b |

## 4. Existing rows (the inventory result is pending from infra)

Context: pinned instances resolve a version by id and render its `endpoint_url` with the
strict grammar (`engine.ex:1180`). Such a row renders `_sys` to "" or leaves it literal (0.1).

* **Inventory RESULT (infra, already run): 0 rows**, record
  `runs/2026-10-15-inv-catalog-sys-refs-001`, over `service_catalog` and
  `service_catalog_versions`. The PR body cites it: "inventory: 0 rows (QA, record
  runs/2026-10-15-inv-catalog-sys-refs-001)". No dispatch, retire or data action. Creation is
  closed by D-1; no other writer exists (section 0). The N > 0 branch below stays only as
  contingency text if the count is re-run and differs.
* **Exact inventory pattern (F6; for any re-run).** The renderer's prefix is `{{`, optional
  whitespace, `variables.`; the reserved KEY is `_sys` exactly or `_sys.` followed by anything.
  PostgreSQL ARE, on `endpoint_url`: `\{\{[[:space:]]*variables\._sys([^a-zA-Z0-9_]|$)` for the
  bare key, or `\{\{[[:space:]]*variables\._sys\.` for the dotted forms (match either; operator
  `~`). The renderer and `reserved_key?/1` are CASE-SENSITIVE, so the authoritative run is
  case-sensitive; a case-insensitive run (`~*`) is a superset that also reports inert `_SYS`
  rows, which are "info" only. Output columns `service_id`, `version` only, never the URL.
* **If it reports N > 0 rows:** the PR body lists `(service_id, version)` pairs, and states
  DEFAULT option (c) "leave, with the reason": the dispatch of every already-pinned version is
  byte-for-byte unchanged (the reference is inert today, 0.1); versions are immutable; an
  operator who wants it gone publishes a new version with a corrected `endpoint_url`
  (supplied explicitly: an inherited bad value is now refused, which is the repair path) and
  retires or leaves the old one. Option (a) retire and option (b) refuse at dispatch are NOT
  done in this PR; (b) changes the behaviour of running instances and needs its own ruling
  (OQ-1). Because an inherited bad `endpoint_url` is refused, such a service cannot publish a
  next version without supplying a URL; that is stated in the PR body.
* **Case-insensitive inventory note:** the renderer and `reserved_key?/1` are case-sensitive,
  so `{{variables._SYS}}` rows are inert and unreserved; they are reported as "info", never
  as findings that this PR acts on.

## 5. Error table

| Condition | Where | Code / shape |
|---|---|---|
| supplied `endpoint_url` references `_sys` (register) | `Entry.insert_changeset/2` | `{:error, %Ecto.Changeset{errors: [endpoint_url: {_, validation: :endpoint_url_reserved_variable}]}}`; nothing inserted |
| supplied or INHERITED `endpoint_url` references `_sys` (publish) | `Entry.publish_changeset/2` | same changeset error; the transaction rolls back, including the archive insert; live row and `service_catalog_versions` unchanged |
| `POST /admin/services`, `POST /admin/services/:id/versions` | `admin_services.ex` | HTTP 422 `{"error": "endpoint_url_reserved_variable", "field": "endpoint_url"}` |
| other bad `endpoint_url` (scheme, private host, brace in head) | unchanged | `:endpoint_url_not_allowed`, generic 422 "validation failed" |
| `endpoint_url` over 2048 bytes | unchanged | length error wins (D-9) |

Nothing raises: every function above is pure and total (INV-8): a non-binary argument returns
`[]` / `:ok` from the reference helpers (the changeset's own cast already types the field).

## 6. AC -> design -> test brief

| AC | Design | Test |
|---|---|---|
| inventory first, read-only | section 4 | not a code test; the PR body quotes the infra/QA record (0 rows, or the `(service_id, version)` list). The query: constant SQL over both tables, `service_id`, `version` only, no URL value, run by infra. |
| refusal at creation: register | D-1, D-4 | `test/letflow/service_catalog/endpoint_url_reserved_test.exs` (DB): `register/1` with each "yes" row of section 3 -> `{:error, %Ecto.Changeset{}}` whose `:endpoint_url` error has `validation: :endpoint_url_reserved_variable`; zero rows in `service_catalog`. |
| publish, supplied and inherited | D-1, D-9 | same file: `publish/3` with a supplied reserved URL -> the changeset error, live row's `version`/`endpoint_url` unchanged, no `service_catalog_versions` row added (archive rolled back); inherited: a row whose live `endpoint_url` holds `{{variables._sys.r}}` is inserted with `Repo.insert!` through a raw changeset-free fixture (a test-only helper writing the column directly), then `publish/3` WITHOUT `:endpoint_url` -> refused; WITH a clean `:endpoint_url` -> `{:ok, _}` (the repair path). |
| `_system` and near-misses accepted | D-3 | same file: `register/1` and `publish/3` with the "no" rows of section 3 -> `{:ok, _}`; pure `Entry.check_endpoint_url_references/1` truth table; `ReservedReferences.reserved_template_names/1` truth table incl. order and duplicates, `nil`. |
| stable code and HTTP 422 on admin routes | D-4, D-6, D-7 | `test/letflow/routers/admin_services_reserved_endpoint_test.exs` (existing admin-services router test helpers): `POST /admin/services` and `POST /admin/services/:id/versions` with a reserved URL -> 422, JSON `error == "endpoint_url_reserved_variable"`, `field == "endpoint_url"`, the response body does NOT contain the submitted URL; a scheme failure still gives today's generic 422; clean URL -> 201. |
| single source of truth | D-2, D-3 | `test/letflow/definitions/reserved_references_test.exs` (edit): the derived pattern's source differs from the strict one only in the KEY class; for a generated corpus of templates (StreamData: random text around `{{ variables.<key> }}` with keys over `[a-zA-Z0-9_.]`) every strict match is also a derived match (strict KEYs are a subsequence of derived KEYs); F5 positive cases: the derived pattern MATCHES `{{variables._sys}}`, `{{variables._sys.x}}` and `{{ variables._sys.a.b }}` (captured KEYs `_sys`, `_sys.x`, `_sys.a.b`), AND `Regex.source(template_reference_placeholder()) != Regex.source(template_placeholder())`, so a derivation that silently became a no-op (a `String.replace/3` that matched nothing) fails loudly while the strict class stays dot-free. F7: a grep-style test that `lib/letflow/service_catalog/` and `service_catalog.ex` hold no `~r`/`Regex.` literal and no `"_sys"`-prefixed literal; verified on `10e6688f` that they contain NO `~r/` or `Regex.` today, so the whole-directory scope is valid (R3 of `put_sys_callers_test.exs` already forbids the latter literal outside variable_merge.ex; its real-tree set stays `[variable_merge.ex]`). |
| I-13 pin retained | D-10 | the existing "pinned and dot-free" test passes unedited; `template_variable_keys("{{variables.a.b}}") == []` still; `template_reference_keys("{{variables.a.b}}") == ["a.b"]`. |
| existing rows | section 4 | PR body statement matching the inventory outcome; a test that `resolve_pinned_version/3` still returns a version whose stored URL contains a reserved reference (fixture inserted raw) unchanged, i.e. dispatch resolution is not altered. |
| existing catalog suites unchanged | | `test/letflow/service_catalog/endpoint_url_validation_test.exs`, `service_catalog_test.exs`, `admin_services_*` pass unedited; `Entry.check_endpoint_url/1` contract untouched. |

## 7. Invariants, security, scope fence

* **I-13 (A1b 2A.7)** satisfied: the grammar's strict class is unchanged and a catalog template
  can no longer carry the namespace; the same predicate decides definitions and catalog.
* **INV-9 (outbound)**: the dispatch-time gate stays binding and untouched; this check is
  creation-time hygiene for engine-owned values reaching an outbound URL.
* **INV-2 / INV-5**: the 422 body echoes neither the URL nor the matched name; the admin route's
  permission gate is unchanged. **INV-8**: pure and total helpers; no new raise. **INV-7**: no SQL.
* **INV-PD-1**: pinned versions are never rewritten; no archived row is touched.
* Scope fence: NO change to `engine.ex`, the renderer, `template_placeholder/0`,
  `Entry.check_endpoint_url/1`, A1b's definition check, `VariableMerge`, any migration, or
  catalog scope/retire/delete behaviour. Not done here: the `_sys.x` blind spot in a
  DEFINITION template (inert; OQ-3) and a shared reference constructor (#2624).

## 8. Files touched

`lib/letflow/engine/service_task.ex` (2 functions), `lib/letflow/definitions/reserved_references.ex`
(1 function + moduledoc line), `lib/letflow/service_catalog/entry.ex` (new check, validator
branch, moduledoc), `lib/letflow/service_catalog.ex` (register/publish `@doc` lines only),
`lib/letflow/api/response.ex` (1 function), `lib/letflow/routers/admin_services.ex` (two
clauses; moduledoc error table). Tests: `test/letflow/service_catalog/endpoint_url_reserved_test.exs`
(new), `test/letflow/routers/admin_services_reserved_endpoint_test.exs` (new),
`test/letflow/definitions/reserved_references_test.exs` (edit). Docs (F8, grepped `docs/` and `README.md`): no document lists the 422 codes of
`POST /admin/services` or `POST /admin/services/:id/versions`;
`docs/migration/stage-4-api-surface.md:126` only names the routes and
`docs/frontend/contract-gaps.md:123` describes a different (read) route. The code list lives
in the router moduledoc of `lib/letflow/routers/admin_services.ex`, the one place to edit
(listed above); no `docs/` file changes.

## 9. Open questions: all CLOSED by supervisor rulings (revision 1)

* **OQ-1 Existing rows, N > 0. CLOSED / moot:** inventory is 0 rows (section 4); the default
  "leave, with the reason" stays as contingency text.
* **OQ-2 Derivation. CLOSED: derive** the wider regex from `Regex.source(template_placeholder())`;
  no #2624 constructor in this PR.
* **OQ-3 Definition-side blind spot. CLOSED: leave with #2624.** A1b's L5/L6 check uses the strict
  grammar, so `{{variables._sys.x}}` in a definition `endpoint`/`body_template` is not flagged;
  it is inert (stays literal). Noted in 0.1; the PR body notes it for #2624.
* **OQ-4 Docs location. CLOSED:** section 8 (router moduledoc only).
* **OQ-5 Echo. CLOSED: no echo** of the placeholder or the URL (D-6).

## 10. Merge-order note

Independent of GH #2621 (disjoint files and tests, section 8 here and section 6 there). One
functional PR in CI at a time (core-directives merge discipline): either order; both must merge
BEFORE #2587 PR B. This PR needs the infra inventory result in its body before merge, not
before it is opened; if the result is late, merge #2621 first.
