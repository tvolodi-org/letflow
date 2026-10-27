# priv/packs/bilimbaga

This directory holds authored bucket-A pack **content** for the BilimBaga
vertical (S10 P2) -- pure definitions, no Elixir application code and no
TypeScript. See `docs/migration/decisions/0022-*.md`'s bucket table:
bucket A is "pure definitions -- no Elixir, no TypeScript. Entity
definitions, process definitions, form schemas, role-registry seeds, Lua
grading rules", built by REQ-ANALYST + CODE-DESIGNER and delivered in a
solution-pack document. Nothing under `priv/packs/` may depend on or
duplicate code under `lib/letflow/` or `web/`.

## REQ-582: `exam_assignment`

The pack now carries seventeen entity types (the ten authoring types, the six runtime/result types and
`exam_assignment`, who an exam is assigned to). `exam_assignment` is managed by the exam module
(`manages_entity_types`) but is NOT one of the sixteen names `Stamp.stamp_names/0` covers. A tenant
that installed the pack before it existed gets the definition (created owner-stamped and activated)
from `Letflow.Release.ManagedTypes.ensure_assignment_definition/1`, run once per deploy. A tenant that
installs the pack afterwards carries it inactive like the other sixteen and activates it with them.

Tenants that installed the pack before REQ-594 get `session.score_pct`/`passed` queried and the optional
queried `session_question_score.exam_id`/`correct` from
`Letflow.Release.ManagedTypes.ensure_exam_analytics_definitions/1`, run once per deploy (no column is promoted).

## Convention: one file per entity type

`entity_definitions/` holds one JSON file per entity type, named after the
entity (`category.json`, `tag.json`, `question.json`,
`answer_option.json`, `question_tag.json`). Each file's top-level object is
exactly a `Letflow.Entities.Definition.t()` document with string keys:
`name`, `display_name`, an optional `description`, `fields`, and the
optional `indexes`, `foreign_keys` and `constraints` arrays -- no wrapper
object, no metadata envelope. JSON (not YAML) because
`Letflow.Definitions.SolutionPack`'s install path parses a string-keyed
`definition_json` object through `solution_pack.ex`'s
`atomize_definition_json/1`, so these are the same bytes the pack document
will carry once REQ-328 packages them.

A later executor adding a sixth definition to this pack should follow the
same shape: one JSON file, no wrapper object, and every `indexes` /
`foreign_keys` / `constraints` entry carrying its own `name` key following
the `<prefix>_<entity>_<columns>` convention (`idx_`/`fk_`/`uq_`).

## FR-BB citation rule

Every definition document in this pack cites its source functional
requirement id inside its own `description` field -- FR-BB21 for `category`
and `tag` (source: `008_categories_tags.up.sql`, roadmap section 2.1),
FR-BB22 for `question`, `answer_option` and `question_tag` (source:
`009_questions.up.sql`, roadmap sections 2.2/2.3). This lets a later reader
trace any field back to the port source without leaving the document.

## parent_id on category and question

REQ-586 part A (GH #3315) declares `parent_id` (string, queried, optional) on
both documents, each with a self-referencing foreign key
(`fk_category_parent_id`, `fk_question_parent_id`) and an index. A table
created from the definition gets a nullable `uuid` column with
`ON DELETE RESTRICT` (decision 0025; inert on the soft-delete path).

- `category`: the category tree, `null` is a root.
  `Letflow.Modules.Exam.AuthoringRules` refuses a parent that is absent,
  deleted or malformed (`parent_not_found`, 422, one identical body for every
  case), a re-parent that would form a cycle (`parent_cycle`, 422), and the
  delete of a category that has live children (`category_has_children`, 409).
  The database does not prevent cycles.
- `question`: the version lineage, `null` is a first version. Part A checks
  that the parent exists (`parent_not_found`) and refuses the delete of a
  question that has a live successor (`question_has_children`). Part B refuses a
  second child (`lineage_branch`), a version not above its parent (`version_not_increasing`) and a
  second active version in one lineage (`lineage_active_conflict`).
- A tenant installed before this change keeps the old definitions until the
  upgrade (REQ-586 part C, `Letflow.Release.ExamParentId.rollout/1`; the
  command line is added by part C). Such a tenant rejects a write carrying
  `parent_id` with the undeclared-field 422 (`additionalProperties` on
  `/parent_id`).

## Open item: starter category records

BilimBaga's `008_categories_tags.up.sql` seeds three root categories
(Security Awareness, Workplace Safety, Loyalty and Values) with hard-coded
UUIDs. Those are records, not definitions, and are not authored here or by
REQ-327/REQ-328 -- REQ-328's install is a definition install. Whether this
pack should seed starter category records at all, and if so how, is left
open for a future requirement to decide.

## The pack document: `pack.json` (REQ-328)

### Provenance choice: (a) — `pack.json` IS committed, generated by a script

REQ-328 offered two shapes. This pack uses **(a)**: `pack.json` is committed
alongside `generate_pack.exs`, the only thing permitted to write it.

Why (a) over (b) (assemble at test time, don't commit the document):

- A solution pack is a **shipped artefact**, not a test fixture. It is what an
  operator installs into a tenant. Something that only ever exists inside a
  test run cannot be shipped, diffed in review, or handed to anyone.
- Its diff is reviewable. When a definition changes, the reviewer sees the
  effect on the installable document in the same commit as the cause.
- The drift risk (a) introduces — a committed second copy of the ten documents
  going stale — is closed mechanically, not by discipline:
  `test/letflow/packs/bilimbaga_pack_install_test.exs`'s first test re-reads
  all ten `entity_definitions/*.json` and asserts each embedded
  `definition_json` is structurally equal to its source. A hand-edit of
  `pack.json`, or a change to a source file without regeneration, fails the
  suite.

Regenerate after ANY change to a file under `entity_definitions/`:

```
MIX_ENV=test mix run priv/packs/bilimbaga/generate_pack.exs
```

The generator is deterministic — `exported_at` is a fixed literal and each
`entity_definition_id` is derived from the pack id plus the entity type name —
so regenerating from unchanged sources produces byte-identical output and never
a spurious diff.

### `manifest.required_roles` is READ-ONLY ADVISORY — every entry reports `bound: false`

`required_roles` is `["super_admin", "examiner", "department_admin"]`, the
source system's own role names (`008_categories_tags.up.sql`'s
`role_permissions` INSERTs; roadmap 2.1 / 3.2's "examiner and above" gating).

`solution_pack.ex`'s moduledoc states it plainly: *"`manifest.required_roles` —
supported, **read-only**: it produces the advisory `role_mapping_checklist`
(see `install/3`). No role is created and no install is ever rejected because
of it."* `role_mapping_checklist/1` tests each name for membership in
`Letflow.Api.Authorization.roles()`, which is exactly
`[:PLATFORM_ADMIN, :PROCESS_DESIGNER, :PROCESS_OPERATOR, :TASK_WORKER,
:AGENT_RUNNER]`. None of this pack's three is one of those five, so the real
install returns:

```elixir
role_mapping_checklist: [
  %{bound: false, role_name: "super_admin"},
  %{bound: false, role_name: "examiner"},
  %{bound: false, role_name: "department_admin"}
]
```

**That is today's correct behaviour, not a failure.** Do NOT rename these to
platform role names to make the checklist report `bound: true` — that would
misrepresent what the pack needs and bind nothing. **REQ-325** is the pending
decision on whether a pack seeds roles at all; decision `0029` records that a
solution-pack document does not seed roles. This pack works today either way,
which is why it does not depend on REQ-325.

### Install is `:inactive` — then activate, then promote

Three distinct steps, in this order. Skipping or reordering any of them fails.

1. **Install.** `SolutionPack.install/3` writes ten `entity_definitions` rows
   with `status: :inactive` (decision 0026) and emits **no DDL**. Because it
   emits no DDL, the ORDER of `entity_definitions` in `pack.json` does not
   matter to it.

   Note the two different things in two different places, which must not be
   conflated: the install RESULT map carries `status: "installed"` — the
   literal string `installed_entity_definition_maps/1` hardcodes into every
   entry — while the PERSISTED `EntityDefinition` row's `status` is the atom
   `:inactive`. The result string reports that the install step ran; it says
   nothing about activation state.

2. **Activate**, via `Letflow.Entities.Definitions.activate_definition/4`.
   Until an entity type has an ACTIVE definition, `Records.create_record/2`
   returns `{:error, {:definition_not_found, entity_type}}`.

3. **Promote**, via `TenantProvisioning.register_column_promotion/4` +
   `run_column_promotion/1`. This is what actually creates the per-entity-type
   table and its real Postgres `REFERENCES` constraints. Activation alone
   creates no table.

#### ACTIVATION/PROMOTION ORDER IS A DAG, AND GETTING IT WRONG FAILS OPAQUELY

`resolve_fk_target_tables/1` is a pure `"entity_" <> name` concat with **no
existence check**, and a per-entity-type table is created carrying that entity
type's FULL promoted-column set — including a `REFERENCES` clause for EVERY
`fk_def` it declares, not just the attribute being promoted. So every one of an
entity type's FK targets must already have its table before it is promoted, or
Postgres fails with an opaque `42P01 undefined_table`.

Verified empirically while building this pack: with `exam_section` unpromoted,
promoting `exam_question_rule.exam_id` emitted `REFERENCES` against a missing
`entity_exam_section` and failed exactly that way.

The order, derived from the ten documents' own `foreign_keys`:

| Tier | Entity types | Depends on |
|---|---|---|
| 1 | `category`, `tag`, `exam` | — (zero FKs) |
| 2 | `question`, `exam_section` | `category`; `exam` |
| 3 | `answer_option`, `question_tag`, `exam_question_rule` | `question`; `question`+`tag`; `exam`+`exam_section`+`category` |
| 4 | `exam_question_rule_tag`, `exam_manual_question` | `exam_question_rule`+`tag`; `exam_question_rule`+`question` |

### Re-running the install test

```
MIX_ENV=test mix test test/letflow/packs/bilimbaga_pack_install_test.exs
```

It performs a real `install/3` against a real provisioned tenant from
`test/support/tenant_fixture.ex`, prints the actual `install_result` map, proves
non-activation, activates and promotes in the DAG order above, and proves the
promoted FKs are real Postgres constraints.

### KNOWN BLOCKER: ISS-0624 — no record with a `:localized_text` field can be written

Found by REQ-328's install test; **a platform defect, not pack content.**

`lib/letflow/entities/records.ex`'s `field_document/1` (around line 576)
rebuilds each field from the persisted JSONB carrying only `name`, `type`,
`required` and `enum_values` — it **drops `locales`**. The `:localized_text`
clause that `Letflow.Entities.Record.Validator.field_subschema/1` gained in
ISS-0617 matches on `%{type: :localized_text, locales: locales}`, so the
locales-less map that converter produces matches no clause and the write raises
`FunctionClauseError`.

The persisted `definition_json` DOES carry `locales` — nothing is lost in
storage. The defect is purely in that one converter.

It is not specific to this pack: a minimal hand-built definition with a single
`%{type: :localized_text, locales: ["en"]}` field reproduces it identically.
ISS-0617's own tests never caught it because they call `build_record_schema/1`
directly with a field map that already has `locales`; they never go through
`Records.create_record/2`.

Consequence for this pack: `category`, `question` and `exam` all carry
`:localized_text` fields and so cannot have records written until ISS-0624 is
fixed. Per REQ-328's finding clause, those documents were NOT weakened by
dropping their localized fields, and no production module was patched. The
install test asserts the current failure so that the day it is fixed, that
assertion fails and points whoever fixed it at the writes waiting to be
re-enabled.
