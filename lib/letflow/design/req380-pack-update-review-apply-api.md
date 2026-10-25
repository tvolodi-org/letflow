# REQ-380 — Solution-pack update review and apply API

Second of three requirements from the same GUI-review finding as REQ-379 (backend
write path, merged at commit `6c756a15`) and REQ-381 (frontend, not built here). See
`test/uat-reports/gui-review-2026-09-20-template-update-conflict-resolution.md` for the
originating GUI-review finding and REQ-379's design doc
(`lib/letflow/design/req379-...md` if present, else its own moduledocs) for the
install-time base-capture trace.

This document covers **only** the HTTP-facing layer: two new routes under
`Letflow.Routers.SolutionPacks` and the context-module functions backing them. It does
**not** touch `compute_pack_update_plan/5` or `classify_artefact/3` (both already
correct, per REQ-041's own gate history) — no defect was found in either while
designing this layer.

## 1. What already exists (investigated before designing anything new)

| Artefact | Status | Evidence |
|---|---|---|
| `pack_update_resolutions` table + migration | **Already shipped** (REQ-041) | `priv/repo/migrations/20260817083803_create_pack_update_resolutions.exs`, renamed by `20260824143417_rename_resolution_enum_values.exs` (`keep_theirs`→`keep_local`, `custom`→`merged`) |
| `Letflow.Definitions.PackUpdateResolution` Ecto schema | **Already shipped**, changeset-only | `lib/letflow/definitions/pack_update_resolution.ex` — `insert_changeset/2` exists as scaffolding, never called by any production code path yet. **This requirement is the first caller.** |
| `Letflow.Definitions.compute_pack_update_plan/5` | **Already shipped, correct** | `lib/letflow/definitions.ex:390-449`. Read-only (INV-PU-5). Takes `tenant_id, pack_id, incoming_version, theirs_artefacts, incoming_artefacts` — the latter two **caller-supplied**, per its own moduledoc ("no real install/export path exists yet to source them from (SOL-01/02/03, unscoped)"). Looks up `base` itself from `solution_pack_artefact_bases`; looks up `resolved` itself from `pack_update_resolutions`, keyed on `(tenant_id, pack_id, target_version: incoming_version, artefact_type, artefact_id)`. |
| `Letflow.Definitions.classify_artefact/3` | **Already shipped, correct** | Pure truth-table function, `lib/letflow/definitions.ex:482-491`. |
| `Letflow.Definitions.SolutionPackArtefactBase` | **Already shipped** | `upsert_changeset/2`'s own moduledoc *explicitly anticipates this requirement*: "A future update-application call site (REQ-380, not built yet): would legitimately want wholesale replace — `Repo.insert/2` with an `on_conflict: :replace_all`-style option." This design follows that pointer. |
| `Letflow.Definitions.SolutionPack.capture_artefact_bases/4` | **Already shipped** (REQ-379, just merged) | `lib/letflow/definitions/solution_pack.ex:1115-1149`. Insert-if-absent only (`on_conflict: :nothing`) — install-time capture semantics, not reusable as-is for apply (apply needs wholesale replace for some entries, per the pointer above). |
| `lib/letflow/routers/solution_packs.ex` | **Two existing routes** (`POST /export`, `POST /install`), **no update-review/apply routes at all** | Confirmed by full read — no partial scaffolding exists. This requirement adds two new `authz_post`/`authz_get`-style clauses to this same module (not a sibling router — the module is 438 lines pre-this-change, well under the size where REVIEWER would judge it too large; no split needed). |
| A route/HTTP layer calling `compute_pack_update_plan/5` | **Does not exist** | Confirmed by grep — `compute_pack_update_plan` has zero callers outside `lib/letflow/definitions.ex` itself and its test file. |
| A write path into `pack_update_resolutions` | **Does not exist** | `insert_changeset/2` has zero callers. **This requirement builds the first one.** |

**Conclusion: no new migration.** The table, schema, and classification logic are all
already correct and already shipped. This requirement adds: one new context function
(`Letflow.Definitions.SolutionPack.apply_pack_update/6`, §4 below), and two new router
clauses (§3). The update-review route needs no new context function at all — it calls
`Letflow.Definitions.compute_pack_update_plan/5` directly.

## 2. Terminology carried over from `compute_pack_update_plan/5`

- **`theirs`** — the tenant's current content for an artefact (what the tenant's schema
  holds *right now*). Caller-supplied on every call (no real "read the tenant's live
  artefact content" path exists yet — same limitation `compute_pack_update_plan/5`
  itself already carries and this requirement does not lift).
- **`incoming`** — the content offered by the newer pack version. Also caller-supplied.
- **`base`** — the content captured at the artefact's last-known pack-delivered
  reference point. **Never caller-supplied** — always looked up from
  `solution_pack_artefact_bases` by `(tenant_id, pack_id, artefact_type, artefact_id)`.
- **`target_version`** (route/request field) — the pack version being offered, i.e. the
  `incoming_version` argument `compute_pack_update_plan/5` takes and the same value
  `pack_update_resolutions.target_version` is scoped by.

## 3. Route 1 — `POST /solution-packs/:pack_id/update-review` (EO-001)

Read-only. Computes and returns the four-way classification for a caller-supplied
artefact set against a caller-supplied `target_version`. No route-level caching, no
mutation of any kind (delegates entirely to `compute_pack_update_plan/5`, itself
INV-PU-5 read-only).

### 3.1 Authorization

`authz_post "/:pack_id/update-review", :DefinitionsRead` — reuses the existing
`:DefinitionsRead` policy key (already backed by `required_permission(:DefinitionsRead)
-> :DefinitionsRead`, granted to `PLATFORM_ADMIN`, `PROCESS_DESIGNER`,
`PROCESS_OPERATOR`, `TASK_WORKER` per `lib/letflow/api/authorization.ex`'s role
matrix). This is the same "reuse the closest-matching existing policy key" judgment
call REQ-078 already made for `POST /export` (see that module's moduledoc,
"Authorization gap — REQ-131 closes it") — flagged for REVIEWER, not silently decided,
same as that precedent. `:DefinitionsRead` is the correct class here: this route reads
and classifies, writes nothing.

The requirement text's "PLATFORM_ADMIN-or-tenant-admin-equivalent" (the UAT scenario's
`actor-platform-admin`) is satisfied because `PLATFORM_ADMIN` always passes
`role_allows?/2` (`role_allows?(:PLATFORM_ADMIN, _permission), do: true`); the scenario
exercising that actor does not by itself require excluding `PROCESS_DESIGNER`/
`PROCESS_OPERATOR`/`TASK_WORKER` from a **read-only** classification view — those roles
already hold `:DefinitionsRead` for every other definitions-read endpoint. If REVIEWER
judges the read view itself should be PLATFORM_ADMIN-only, that is a one-line change to
which existing policy key this clause names (`:DefinitionsRead` → a new, narrower key)
and does not otherwise change this design — noted as an open question, OQ-1 below.

### 3.2 Request

```
POST /api/v1/solution-packs/:pack_id/update-review
{
  "target_version": "2.0.0",
  "theirs_artefacts": [
    {"artefact_type": "process_definition", "artefact_id": "<uuid>", "content": "<canonical-json-text>"},
    ...
  ],
  "incoming_artefacts": [
    {"artefact_type": "process_definition", "artefact_id": "<uuid>", "content": "<canonical-json-text>"},
    ...
  ]
}
```

`pack_id` is a path segment (string, matches `solution_pack_installs.pack_id`'s type,
no format constraint beyond non-empty — same as the existing `pack_id` field
elsewhere in this codebase, which is a caller-chosen string, not a UUID).

`FieldConstraint` validation schema (`@update_review_schema`), mirroring
`Letflow.Api.Validation.FieldConstraint` usage in this same module's
`@export_schema`:

| Field | Type | Required | Constraint |
|---|---|---|---|
| `target_version` | `:string` | yes | `reject_empty_string: true`, `max_length: 255` (matches `pack_update_resolutions.target_version`'s column) |
| `theirs_artefacts` | `:array` | yes | `min_items: 0` (an empty array is legal on its own — see below) |
| `incoming_artefacts` | `:array` | yes | `min_items: 0` |

Each array element is validated by a route-level helper (`validate_artefact_input/1`,
new private function), not by `FieldConstraint` (no per-element-shape rule exists in
that vocabulary, same limitation `export_with_ids/3`'s own
`Enum.all?(definition_ids, &is_binary/1)` post-check already works around):
`artefact_type` — non-empty string, ≤255 bytes; `artefact_id` — non-empty string,
≤255 bytes; `content` — a string (the canonical-JSON text `classify_artefact/3`
expects; this route does **not** re-canonicalize it — see §6 "Canonicalization is the
caller's responsibility, at every entry point" for why that is deliberate and
consistent with every other call site).

Both arrays present but both empty → the route does not call
`compute_pack_update_plan/5` at all (which would itself return
`{:error, :empty_artefact_set}`) — it maps that combination straight to
`Response.unprocessable(conn, "theirs_artefacts and incoming_artefacts must not both be empty")`
before calling the context function, so the 422 detail is meaningful rather than a
bare passthrough of an internal atom.

### 3.3 Response — `200 OK`

```
{
  "pack_id": "...",
  "target_version": "2.0.0",
  "entries": [
    {
      "artefact_type": "process_definition",
      "artefact_id": "<uuid>",
      "classification": "unchanged" | "safe_to_update" | "local_only" | "both_sides_conflict",
      "resolved": true | false
    },
    ...
  ],
  "has_unresolved_conflicts": true | false
}
```

**Wire-name mapping (EO-001's own vocabulary vs. `classify_artefact/3`'s internal
atoms) — deliberate, not accidental drift:**

| `classify_artefact/3` atom | Wire string (EO-001's names) |
|---|---|
| `:unchanged` | `"unchanged"` |
| `:clean_update` | `"safe_to_update"` |
| `:local_only` | `"local_only"` |
| `:conflict` | `"both_sides_conflict"` |

EO-001 names the four groups literally as "unchanged/safe-to-update/local-only/
both-sides-conflict" — the requirement's own four-way vocabulary, distinct from
`compute_pack_update_plan/5`'s internal atom names (`:clean_update`/`:conflict`). The
response map function (`update_review_response_map/2`, new private function in the
router, hand-built key list — INV-2, never a bare `Jason.Encoder` derivation) performs
this translation once, at the response boundary. `base`/`theirs`/`incoming` content
strings from `plan_entry()` are **deliberately NOT echoed** in the response (see §6,
"Response never echoes raw content" — this is the payload REQ-381's frontend diff view
would want, but is out of this requirement's scope fence, which names only the four-way
classification as EO-001's deliverable; a follow-up can widen the response shape
without a breaking change, since it would only add fields).

`entries` order matches `compute_pack_update_plan/5`'s own key order (first-seen,
`theirs_artefacts` then `incoming_artefacts` — see that function's moduledoc).

### 3.4 Error mapping

| Context result | HTTP |
|---|---|
| Both artefact arrays empty (route-level pre-check) | `422`, detail above |
| Any artefact entry missing `artefact_type`/`artefact_id`/`content`, or a string field over its byte limit | `422` via `Validation.problem/1`-style field errors, one per offending entry (index named in the detail, content itself never echoed — same convention as `render_install/2`'s `:blank_variable_key`) |
| `compute_pack_update_plan/5`'s own `{:error, :empty_artefact_set}` | Unreachable given the route-level pre-check above — not mapped, but the last-resort `_unexpected -> Response.internal_error/1` clause covers it defensively, same "type-table-vs-error-map drift" idiom `render_install/2` documents at its own last-resort clause. |
| `TenantProvisioning.tenant_id_for_schema_name/1` failure (a `common_error()`) | `500` — a route-construction bug (unscoped request reaching this handler), same treatment `render_install/2` gives `:missing_prefix`/`:invalid_schema_name` |

## 4. Route 2 — `POST /solution-packs/:pack_id/update-apply` (EO-002/EO-003/EO-004/EO-005)

Mutating. Single atomic operation: persists every resolution the caller submits in this
call, recomputes the plan, and — **only if no both-sides-conflict entry remains
unresolved** — advances the relevant `solution_pack_artefact_bases` rows. If any
conflict remains unresolved after persisting the submitted resolutions, **the entire
call rolls back and writes nothing at all**, including the resolutions submitted in
that same call (see §4.4 "All-or-nothing, including the resolutions themselves" for
why this reading of EO-002's "applies nothing in that case" was chosen over a
partial-persist alternative).

### 4.1 Authorization

`authz_post "/:pack_id/update-apply", :DefinitionsCreate` — reuses the existing
`:DefinitionsCreate` policy key (`required_permission(:DefinitionsCreate) ->
:DefinitionsWrite`, granted to `PLATFORM_ADMIN` and `PROCESS_DESIGNER` only — neither
`PROCESS_OPERATOR` nor `TASK_WORKER` hold `:DefinitionsWrite`, per the role matrix).
Same "reuse the closest write-class policy key" judgment REQ-078's `POST /install`
already made for the same reason: this route mutates tenant-adjacent content
(resolutions + base snapshots), the same permission class as authoring/installing
definitions, not the read class. Flagged for REVIEWER, same as §3.1.

### 4.2 Request

```
POST /api/v1/solution-packs/:pack_id/update-apply
{
  "target_version": "2.0.0",
  "theirs_artefacts": [ ... same shape as §3.2 ... ],
  "incoming_artefacts": [ ... same shape as §3.2 ... ],
  "resolutions": [
    {
      "artefact_type": "process_definition",
      "artefact_id": "<uuid>",
      "resolution": "keep_local" | "take_incoming" | "merged",
      "resolved_content": "<canonical-json-text>"   // required iff resolution == "merged", omitted/null otherwise
    },
    ...
  ]
}
```

`theirs_artefacts`/`incoming_artefacts` are **required on the apply call, in the same
shape as the review call** — apply must recompute the same plan the caller last saw
(§4.3 step 2) to determine what "unresolved" means *right now*, and
`compute_pack_update_plan/5` has no other way to obtain them (§2). This is a direct,
disclosed consequence of `theirs`/`incoming` having no real source yet (§1's table);
noted as OQ-2 below, not silently absorbed.

`FieldConstraint` schema (`@update_apply_schema`) — same three fields as
`@update_review_schema` (§3.2) plus:

| Field | Type | Required | Constraint |
|---|---|---|---|
| `resolutions` | `:array` | yes | `min_items: 0` (an apply call with zero new resolutions is legal — it simply re-applies whatever was already resolved in a prior call, and blocks with EO-002's named-artefact error if anything is still outstanding) |

Each `resolutions[]` entry validated by a new private helper
(`validate_resolution_input/1`): `artefact_type`/`artefact_id` — same non-empty/≤255
rule as §3.2; `resolution` — must be exactly one of the three
`PackUpdateResolution.resolution()` strings (`"keep_local"`, `"take_incoming"`,
`"merged"`), any other value is `422`; `resolved_content` — required (non-empty string)
**iff** `resolution == "merged"`, and **must be absent or `null`** for the other two —
a `resolved_content` present alongside `"keep_local"`/`"take_incoming"` is `422`
(prevents a caller silently believing a supplied merge body was honoured when it would
in fact be ignored).

### 4.3 Apply semantics — the new context function

New public function, `Letflow.Definitions.SolutionPack.apply_pack_update/6`:

```
@type resolution_input :: %{
        artefact_type: String.t(),
        artefact_id: String.t(),
        resolution: PackUpdateResolution.resolution(),
        resolved_content: String.t() | nil
      }

@type apply_result :: %{
        pack_id: String.t(),
        target_version: String.t(),
        applied_entries: [
          %{
            artefact_type: String.t(),
            artefact_id: String.t(),
            classification: Definitions.classification(),
            action: :advanced_to_incoming | :advanced_to_merged | :left_unchanged
          }
        ],
        resolutions_recorded: non_neg_integer()
      }

@type apply_error ::
        {:error, {:unresolved_conflict, artefact_type :: String.t(), artefact_id :: String.t()}}
        | {:error, {:invalid_resolution, artefact_type :: String.t(), artefact_id :: String.t(), reason :: :not_a_conflict}}
        | {:error, :empty_artefact_set}
        | Definitions.common_error()

@spec apply_pack_update(
        pack_id :: String.t(),
        target_version :: String.t(),
        theirs_artefacts :: [Definitions.artefact_input()],
        incoming_artefacts :: [Definitions.artefact_input()],
        resolutions :: [resolution_input()],
        opts :: Definitions.opts() | [prefix: String.t(), actor_id: Ecto.UUID.t()]
      ) :: {:ok, apply_result()} | apply_error()
```

`opts` carries both `:prefix` (as every other function in this module) and
`:actor_id` (the resolver, per `pack_update_resolutions.resolved_by`) — new keyword,
`Keyword.fetch!/2`'d, no default, same no-default stance `rollback_definition_version/4`
already established for its own mandatory caller-supplied identity input.

**Steps, all inside one `Repo.transaction/1`:**

1. `TenantProvisioning.tenant_id_for_schema_name/1` on `opts[:prefix]` (same as every
   other function in this module).
2. Guard: `resolution_input.resolved_content` present iff `resolution == :merged` — a
   second, defensive structural check inside the context function, not only at the
   route (mirrors `decode_variable_schema/1`'s own two-layer validation precedent).
   Malformed shape here is a programmer error from the router, not a caller error —
   this function trusts the router already ran §4.2's validation and does not
   duplicate its user-facing messaging, only a defensive `Keyword`-style guard clause.
3. Insert each submitted resolution via
   `PackUpdateResolution.insert_changeset/2`, `Repo.insert(on_conflict: :nothing,
   conflict_target: :uq_pack_update_resolution)`. **`:nothing`, not
   `:replace_all`** — deliberate: `pack_update_resolutions` rows are an attribution
   record (`resolved_by`/`resolved_at`), and the first-recorded resolution for a given
   `(tenant_id, pack_id, target_version, artefact_type, artefact_id)` wins,
   permanently, the same "insert-if-absent, never silently overwritten" idiom
   `capture_artefact_bases/4` already established for `solution_pack_artefact_bases`
   at install time (§1's table). A caller resubmitting a *different* resolution for an
   already-resolved artefact within the same `target_version` gets no error and no
   effect — their new choice is silently not the one recorded. This is flagged as
   **OQ-3** below (a real, disclosed behavioural choice, not a silent gap): an
   alternative design would `:replace_all` here so the most recent submission wins;
   this design chose immutability-of-first-attribution because REQ-380's own AC set
   (EO-003, EO-005) only ever tests a single resolve-then-apply-then-re-review
   sequence, never a resolution correction, so there is no acceptance criterion this
   choice could violate, and immutable attribution is the safer default for an audit
   trail. REVIEWER may override.
4. `Definitions.compute_pack_update_plan(tenant_id, pack_id, target_version,
   theirs_artefacts, incoming_artefacts)` — re-run **inside the same transaction**, so
   it sees the resolution rows step 3 just inserted (`resolution_exists?/5`'s
   `Repo.get_by/2` runs against the transaction's own connection, read-your-writes
   within one transaction, no isolation-level concern).
   - `{:error, :empty_artefact_set}` → `Repo.rollback(:empty_artefact_set)`.
5. If `plan.has_unresolved_conflicts` — find the first entry (in `plan.entries`
   order, i.e. deterministic, matching `compute_pack_update_plan/5`'s own first-seen
   ordering) where `classification == :conflict and resolved == false` and
   `Repo.rollback({:unresolved_conflict, entry.artefact_type, entry.artefact_id})`
   (EO-002 — "names the specific unresolved artefact"). **The entire transaction rolls
   back here, including step 3's inserts** — see §4.4.
6. Otherwise (no unresolved conflict remains), for each entry in `plan.entries`:
   - `classification == :unchanged` → `action: :left_unchanged`, no write.
   - `classification == :local_only` → `action: :left_unchanged`, no write (nothing
     to apply — the tenant's local content is already ahead of `base`, and
     `incoming` never touched it; EO-004's "untouched by both the tenant and the
     incoming version" is the `:unchanged` case specifically, but `:local_only`'s
     "untouched by incoming" half gets the identical no-write treatment for the
     same reason).
   - `classification == :clean_update` → advance: `SolutionPackArtefactBase.upsert_changeset/2`
     with `base_content: entry.incoming, base_version:
     target_version, captured_at: now` — `entry.incoming` is already canonical-JSON
     text (§6, "Canonicalization is the caller's responsibility, at every entry
     point"); stored as-is, **not** re-canonicalized (`canonicalize_artefact_content/1`
     expects a decoded map, not text — calling it here would be a type mismatch this
     layer never has to resolve), `Repo.insert(on_conflict: {:replace,
     [:base_content, :base_version, :captured_at, :updated_at]}, conflict_target:
     [:tenant_id, :pack_id, :artefact_type, :artefact_id])` — the wholesale-replace
     path `SolutionPackArtefactBase.upsert_changeset/2`'s own moduledoc names this
     requirement as the intended caller for. `action: :advanced_to_incoming`.
   - `classification == :conflict` (now guaranteed `resolved == true`, by step 5's
     guard) → look up which `resolution_input` (from **this call's** `resolutions`
     list, not a re-read of the DB row — the DB row may have come from an *earlier*
     call per step 3's immutability) named this artefact:
     - Not found in this call's `resolutions` (i.e. it was already resolved by an
       earlier call, and this call submitted nothing new for it) → re-read the
       persisted `pack_update_resolutions` row's own `resolution` value instead, to
       decide the action.
     - `:keep_local` → `action: :left_unchanged`, no base write (EO-003 — "that
       artefact's content is unchanged"). The resolution row itself (written in a
       prior call, or in step 3 of this call) is the durable attribution record;
       nothing else changes.
     - `:take_incoming` → advance the base exactly like `:clean_update` above
       (`base_content` ← `entry.incoming`, stored as-is, `base_version` ←
       `target_version`). `action: :advanced_to_incoming`.
     - `:merged` → advance the base to the **resolution's own `resolved_content`**,
       not `entry.incoming` (`base_content` ← `resolved_content`, stored as-is,
       `base_version` ← `target_version`). `action: :advanced_to_merged`.
7. Commit; return `{:ok, %{pack_id: ..., target_version: ..., applied_entries: ...,
   resolutions_recorded: <count of step-3 inserts that actually inserted a fresh row>}}`.

### 4.4 All-or-nothing, including the resolutions themselves

EO-002 states: "the apply endpoint refuses to apply ... and applies nothing in that
case." Two readings were possible: (a) only the *base-advancement* writes roll back,
but resolutions submitted in the same call persist; or (b) the entire call — including
resolution inserts — rolls back atomically. This design chose **(b)**, for three
reasons, stated so a validator or REVIEWER can check the reasoning rather than the
outcome alone:

1. **Literal reading.** "Applies nothing" most naturally means *this call had zero
   effect*, not *this call had a partial effect scoped to a subset of its writes*.
2. **No silent partial success.** Under reading (a), a caller submitting resolutions
   for artefacts A and B in one call, where C is also an unresolved conflict, would
   have A and B's resolutions durably recorded even though the call as a whole
   reports failure — a caller retrying the identical request after fixing C would
   then hit the `:nothing`-conflict-target no-op from step 3 for A/B (harmless) but
   the *first* call's response gave no indication those two writes had already
   landed. Atomicity avoids this entirely: a failed call is unambiguously a no-op,
   and the caller resubmits the full set.
3. **Consistent with every other multi-step write in this module.** `run_install/5`
   (§1's table, `lib/letflow/definitions/solution_pack.ex:978-1010`) already uses
   exactly this shape — one `Repo.transaction/1`, `Repo.rollback/1` on the first
   failure, no partial commit — for the exact same reason (`install/3`'s moduledoc:
   "Any error in steps 5-7 rolls the whole transaction back").

### 4.5 Error mapping (router)

| Context result | HTTP |
|---|---|
| `{:error, {:unresolved_conflict, artefact_type, artefact_id}}` | `409`, detail names both (caller-supplied values, safe to echo — same reasoning `render_install/2`'s `key` echo convention uses for caller-submitted identifiers) |
| `{:error, :empty_artefact_set}` | `422` (route-level pre-check makes this unreachable in practice, same defensive-only status as §3.4) |
| `{:error, :version_not_newer}` / `{:error, :version_downgrade}` (REQ-573: apply only for the equal case; update-review answers the plan on equal and refuses a downgrade) | `422`, detail is the bare code |
| Resolution shape validation failures (§4.2) | `422`, field-level, at the route layer before the context function is even called |
| `common_error()` members | `500`, same treatment as §3.4 |
| `{:error, {:invalid_resolution, ...}}` | Not reachable through the router (the router's own §4.2 validation rejects a malformed `resolutions[]` entry before the context call) — kept in the type as a defensive contract for a non-HTTP caller (e.g. a future CLI/test harness calling `apply_pack_update/6` directly), same "unreachable via the route, still typed" idiom `render_install/2`'s trailing catch-all documents. |

### 4.6 Response — `200 OK`

```
{
  "pack_id": "...",
  "target_version": "2.0.0",
  "applied_entries": [
    {
      "artefact_type": "process_definition",
      "artefact_id": "<uuid>",
      "classification": "unchanged" | "safe_to_update" | "local_only" | "both_sides_conflict",
      "action": "advanced_to_incoming" | "advanced_to_merged" | "left_unchanged"
    },
    ...
  ],
  "resolutions_recorded": 2
}
```

Same classification wire-name mapping as §3.3's table. Never echoes raw content (§6).

## 5. Idempotent re-review after apply (EO-005) — no new mechanism needed

**This falls out of the existing design with zero additional code**, and is worth
stating explicitly rather than left implicit, since EO-005 reads as if it demands new
machinery:

A second `POST .../update-review` call, made with the **same `target_version`** as the
prior apply and the **same (unchanged) `theirs_artefacts` content** for the
keep_local-resolved artefact (keep_local performed no write, per §4.3 step 6, so the
tenant's real content — and therefore whatever the caller supplies as `theirs` for
it — is unchanged by construction), re-runs `compute_pack_update_plan/5`. For that
artefact:

- `classify_artefact/3` still returns `:conflict` (base/theirs/incoming relationship
  is unchanged — this is **not** claimed to change, and EO-005 does not require it
  to).
- `resolution_exists?/5` (`lib/letflow/definitions.ex:513-523`) looks up
  `(tenant_id, pack_id, target_version, artefact_type, artefact_id)` — an exact match
  against the row §4.3 step 3 already persisted (same `target_version`, since this is
  the *same* offered update, not a new one). Returns `true`.
- So `plan_entry.resolved == true` for that artefact, and it does **not** contribute
  to `has_unresolved_conflicts` — i.e. it is not "re-flagged as a fresh conflict" in
  the sense that matters (it does not block a subsequent apply, and the response
  marks it `"resolved": true` rather than presenting it as newly outstanding).

**What this design does NOT claim:** it does not make `classification` itself read
`"unchanged"` on the second call — the artefact is still, structurally, a genuine
three-way conflict (tenant and pack both diverged from base); only its *resolved*
status differs. If a reader expected EO-005 to mean "the entry disappears from the
conflict group entirely," that is not what this design implements, and is flagged as
**OQ-4** below for REQ-VALIDATOR/CODE-DESIGN-VALIDATOR to confirm against the literal
AC wording ("does not re-flag ... as a fresh conflict" — read here as "does not present
it as newly *unresolved*," which is what `has_unresolved_conflicts` and `resolved`
already, precisely, distinguish).

This is also why keep_local deliberately does **not** advance the base (§4.3 step
6): advancing it would make `classify_artefact/3` return `:unchanged` on the next
review for a **different, later** `target_version` too — silently discarding the
tenant's deliberate "keep my version" choice the moment any *newer* pack version is
offered, which nothing in the AC set asks for and which the resolution's own
`target_version` scoping was designed to avoid (a resolution is scoped to one offered
version, not permanent).

## 6. Cross-cutting design notes

**Canonicalization is the caller's responsibility, at every entry point.**
`classify_artefact/3`'s own moduledoc states this framework-wide constraint:
"`base`/`theirs`/`incoming` are compared by byte-level string equality over content
that MUST already be canonical-JSON text by the time it reaches this function." Both
new routes inherit this unchanged — `theirs_artefacts[].content`,
`incoming_artefacts[].content`, and `resolutions[].resolved_content` are all taken
as-is, never re-encoded or reformatted by this layer. This is consistent with
`capture_artefact_bases/4`'s own separate `canonicalize_artefact_content/1` call,
which exists because *that* function receives a raw `packed.graph` **map**, not
caller-supplied text — the two call sites differ in whether their input is already
text (this requirement's routes: yes, so no canonicalization step) or a decoded
structure (REQ-379's install path: no, so it canonicalizes). Not a duplicated
concern — a genuinely different input shape at each site.

**Response never echoes raw content.** Neither §3.3 nor §4.6 return `base`/`theirs`/
`incoming`/`resolved_content` text in the response body. `plan_entry()` carries these
fields internally (`compute_pack_update_plan/5`'s own return shape), but the router's
hand-built response maps (INV-2 — never a bare pass-through of the context module's
internal map, matching `pack_document_map/1`'s and `install_result_map/1`'s existing
convention in this same file) omit them. This keeps both responses small and avoids a
class of problem this requirement does not need to solve (arbitrarily large diff
payloads in an HTTP response) — REQ-381's frontend diff view is out of scope here and
can widen this response additively later if it needs the raw text.

**Tenant scoping (INV-1).** Both routes derive `opts[:prefix]` solely from
`conn.assigns.scoped_opts` (`Letflow.Api.Context.scoped_repo_opts/1`), identical to
every existing route in this module — no tenant identifier appears in either new URL
or either new request body. `pack_update_resolutions`/`solution_pack_artefact_bases`
are GLOBAL tables (§1's table; REQ-041's documented classification), but every write
into them still derives `tenant_id` from the resolved prefix via
`TenantProvisioning.tenant_id_for_schema_name/1` inside the context function — **never**
a caller-supplied `tenant_id` field in either request body (matching
`Definitions.create/2`'s own `:tenant_id_not_accepted` precedent; neither
`@update_review_schema` nor `@update_apply_schema` declares a `tenant_id` field at
all, so there is nothing for a caller to even attempt to supply).

**`resolved_by` attribution (EO-003).** `opts[:actor_id]` for `apply_pack_update/6`
is read from the same `actor_id(conn)` helper this router already has
(`lib/letflow/routers/solution_packs.ex:367-372`, reads
`conn.assigns[:auth_context][:user_id]`) — not a caller-supplied body field. A `nil`
actor (auth pipeline not run) is `Response.internal_error/1`, same treatment
`install_document/1` already gives that case.

**No migration.** Confirmed in §1: `pack_update_resolutions` and its indexes already
exist. This requirement adds zero `priv/repo/migrations/` files.

## 7. Requirement-to-design mapping (every EO)

| Acceptance criterion | Design element |
|---|---|
| EO-001 — four-way classification for a tenant with ≥1 artefact per group | §3 (route), §3.3's wire-name mapping table, §3.3 response shape |
| EO-002 — apply refuses and names the specific unresolved artefact; applies nothing | §4.3 step 5 (`{:error, {:unresolved_conflict, type, id}}`), §4.5 (`409` mapping), §4.4 (atomicity reasoning) |
| EO-003 — keep_local leaves content unchanged; resolution row records `resolved_by`/`resolved_at` | §4.3 step 3 (insert, with `resolved_by`/`resolved_at` — both `validate_required` fields on `PackUpdateResolution.insert_changeset/2` already), §4.3 step 6 `:keep_local` branch (`action: :left_unchanged`, no base write) |
| EO-004 — an artefact untouched by both sides is unchanged in content and version | §4.3 step 6 `:unchanged`/`:local_only` branches (`action: :left_unchanged`, no write to `solution_pack_artefact_bases` at all — `base_content`/`base_version` both stay exactly as they were) |
| EO-005 — a second review call doesn't re-flag a keep_local-resolved artefact as a fresh conflict | §5 (falls out of `resolution_exists?/5`'s existing `target_version`-scoped lookup; no new mechanism) |
| `mix letflow.check` passes | Owned by ELIXIR-DEV at implementation time — not a design-time artefact; flagged here only so CODE-DESIGN-VALIDATOR can confirm nothing in this design requires a check this project doesn't already run |

## 8. Regression-test design (for TEST-DESIGNER)

All new tests live in `test/letflow/definitions/solution_pack_update_test.exs` (context
function, `apply_pack_update/6`) and
`test/letflow/routers/solution_packs_update_test.exs` (route-level, HTTP status/body
shape) — new files, following this codebase's existing
`test/letflow/definitions/solution_pack_test.exs` /
`test/letflow/routers/` split convention (grep confirms `solution_pack_test.exs`
already tests `install/3`/`export/3` at the context layer; a router-level test file for
`solution_packs.ex` was not found by this search and may need to be created fresh, or
folded into an existing `test/letflow/routers/solution_packs_test.exs` if
TEST-DESIGNER finds one — confirm at test-design time, not assumed here).

Every fixture is directly DB-inserted (`Repo.insert!` against
`SolutionPackArtefactBase`/`PackUpdateResolution` structs), the same
"fixture-insertable, no FK to `solution_pack_installs`" pattern INV-PU-6 documents and
`pack_update_migration_test.exs` already exercises for REQ-041 — no dependency on a
real `install/3` call is required to set up any of these scenarios.

1. **EO-001 (four groups).** Insert one `solution_pack_artefact_bases` row per group
   member so `base` is under this test's control: (a) `:unchanged` — base==theirs==
   incoming; (b) `:safe_to_update` — base==theirs≠incoming; (c) `:local_only` —
   base≠theirs, base==incoming; (d) `:both_sides_conflict` — base≠theirs≠incoming, no
   equal pair. Call `POST .../update-review` with all four artefacts in one
   `theirs_artefacts`/`incoming_artefacts` payload. Assert each `entries[]` element's
   `"classification"` matches its group via the §3.3 wire-name table, and that no
   group is empty (i.e. the test genuinely exercises all four, not merely doesn't
   contradict them).

2. **EO-002 (block on unresolved conflict, applies nothing).** One conflict artefact,
   no matching `pack_update_resolutions` row. Call `POST .../update-apply` with
   `resolutions: []`. Assert `409`, detail names that artefact's `artefact_type`/
   `artefact_id`. Then assert, by direct query: zero `pack_update_resolutions` rows
   exist for this `(tenant_id, pack_id, target_version)`, and the pre-existing
   `solution_pack_artefact_bases` row for the conflict artefact (and for any other
   artefact in the same payload) is byte-identical to its pre-call state (covers §4.4's
   atomicity claim, not just the 409 status).

3. **EO-003 (keep_local content unchanged + attribution).** One conflict artefact
   with a pre-existing base row (adapted: base≠theirs≠incoming). Call
   `POST .../update-apply` with `resolutions: [{artefact, "keep_local"}]`. Assert
   `200`. Assert, by direct query: the `solution_pack_artefact_bases` row for that
   artefact is unchanged (`base_content`/`base_version`/`captured_at` all identical to
   pre-call). Assert a `pack_update_resolutions` row now exists for
   `(tenant_id, pack_id, target_version, artefact_type, artefact_id)` with
   `resolution == :keep_local`, non-nil `resolved_by` equal to the calling actor's id,
   and non-nil `resolved_at`.

4. **EO-004 (untouched artefact unchanged in content and version).** An `:unchanged`-
   classified artefact (base==theirs==incoming) included in the same apply-call
   payload as case 3's artefact (so the call succeeds — no unresolved conflicts).
   Assert `200`. Assert, by direct query: this artefact's
   `solution_pack_artefact_bases` row is unchanged (`base_content` AND `base_version`
   both identical to pre-call — the two fields EO-004 names explicitly).

5. **EO-005 (idempotent re-review).** Continue from case 3's committed state (same
   `target_version`, same `theirs_artefacts` content for the keep_local artefact —
   unchanged by construction, since keep_local wrote nothing). Call
   `POST .../update-review` again with the identical `target_version` and artefact
   payload. Assert `200`; assert the keep_local artefact's `entries[]` element has
   `"classification": "both_sides_conflict"` (unchanged — §5 explicitly does not claim
   this flips) **and** `"resolved": true`; assert top-level
   `"has_unresolved_conflicts": false` (assuming no other unresolved conflict exists
   in this payload) — the artefact does not block a hypothetical follow-up apply call.

6. **Negative/shape coverage** (not tied to a numbered EO, but needed so the route
   layer itself is exercised, not only the context function): empty body → `400`;
   both artefact arrays empty → `422` with the stated detail; a `resolutions[]` entry
   with `resolution: "merged"` and no `resolved_content` → `422`; a `resolutions[]`
   entry with `resolution: "keep_local"` and a non-null `resolved_content` → `422`;
   an unauthenticated request (no bearer token) → `401`/`403` per
   `Letflow.Plugs.AuthPipeline`'s existing behaviour (same convention every other
   route in this module's test suite already checks); a `PROCESS_OPERATOR`-roled
   caller against `update-apply` → `403` (does not hold `:DefinitionsWrite`); the same
   role against `update-review` → `200` (does hold `:DefinitionsRead`) — this last
   pair is the concrete proof for §3.1/§4.1's stated role-matrix reasoning, not merely
   an assertion repeated from the design doc.

## 9. Open questions (not silently resolved)

- **OQ-1.** §3.1 — whether `update-review` should be gated more narrowly than the
  existing `:DefinitionsRead` policy key (e.g. PLATFORM_ADMIN-only), given the
  requirement text's specific framing around an `actor-platform-admin` UAT scenario.
  This design reuses the existing read-class key, consistent with REQ-078's own
  precedent for `POST /export`; REVIEWER may override.
- **OQ-2.** §4.2 — `update-apply` requires the full `theirs_artefacts`/
  `incoming_artefacts` payload on every call (not only on `update-review`), which is a
  direct, unavoidable consequence of those inputs having no real server-side source
  yet. This is disclosed rather than smoothed over; it will need revisiting once a
  real "read the tenant's live artefact content" path exists (SOL-01/02/03, per
  `compute_pack_update_plan/5`'s own moduledoc), at which point `update-apply` could
  plausibly drop these two fields entirely and read them itself.
- **OQ-3.** §4.3 step 3 — resolution rows are insert-if-absent (`:nothing`), so the
  first submitted resolution for a given `(tenant_id, pack_id, target_version,
  artefact_type, artefact_id)` is permanent for that offered version; a later
  correction attempt in the same call sequence silently has no effect. No AC in this
  requirement's set exercises a resolution-correction scenario, so this choice
  violates nothing tested, but is a real, disclosed design decision REVIEWER should
  confirm rather than discover later.
- **OQ-4.** §5 — confirms the reading of EO-005 as "does not present the artefact as a
  newly *unresolved* conflict" (i.e. `resolved: true`, does not block
  `has_unresolved_conflicts`), not as "the artefact's `classification` itself changes
  to a non-conflict value." Flagged explicitly for CODE-DESIGN-VALIDATOR/REVIEWER to
  confirm against the literal AC wording before TEST-DESIGNER builds test 5 in §8
  against the wrong expectation.
