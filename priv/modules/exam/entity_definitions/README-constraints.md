# Relocated and dropped source constraints — BilimBaga exam configuration (REQ-327)

This file records what happened to every `CHECK` constraint in the two source
migrations this directory's exam-configuration definitions port from, and records
one entity type that was deliberately not authored at all. It exists so that a later
executor authoring the form schemas knows exactly what must be re-expressed there,
and so a reviewer can confirm nothing was silently dropped.

Sources:

- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\012_exams.up.sql`
  (header `-- FR-BB31: Exam Configuration Model`)
- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\013_exam_assignments.up.sql`
  (header `-- FR-BB33: Exam Assignment`)
- Product spec: `corporate_exam_platform_roadmap.md` sections 3.1 (exam configuration
  model), 3.2 (configuration API) and 3.3 (exam assignment).

## Why none of these can be expressed as an entity-definition constraint

`Letflow.Entities.Definition`'s `constraint_def` type declares
`required(:type) => :unique` — a single literal atom, not a union — and there is no
`check_def` type of any kind. The enforcing code is
`lib/letflow/entities/definition/validator.ex`'s `constraint_shape_violations/1`,
which rejects any constraint whose `type` is not `:unique`:

```elixir
Map.get(constraint, :type) != :unique ->
  [malformed([:constraints, Map.get(constraint, :name)], "constraint type must be :unique")]
```

`Letflow.Definitions.SolutionPack`'s `translate_constraint/1` narrows this further at
the pack-parsing boundary: the only string it will translate for a constraint's
`type` is `"unique"`; anything else is `{:error, :invalid_pack_document}`.

Nor is there a field-level escape hatch. `field_def` has no `min`, `max`, `range` or
`check` attribute — its optional keys are exactly `required`, `queried`, `enum_values`,
`decimal_precision`, `decimal_scale`, `default`, `locales` and `search_strategy`. A
numeric field cannot carry a bound today.

So every `CHECK` below has no storage-layer expression in Letflow, and this file
relocates it explicitly rather than dropping it silently.

## Verification that this list is complete

`grep -n CHECK` over both source migrations, output quoted verbatim:

```
=== 012_exams.up.sql ===
18:    time_limit_minutes  INT NOT NULL CHECK (time_limit_minutes > 0),
19:    passing_score_pct   DECIMAL(5, 2) NOT NULL CHECK (passing_score_pct BETWEEN 0 AND 100),
20:    max_attempts        INT NOT NULL DEFAULT 1 CHECK (max_attempts > 0),
31:    CONSTRAINT exams_availability_check CHECK (
44:    sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
61:    count       INT NOT NULL CHECK (count > 0),
62:    sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
73:    sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),

=== 013_exam_assignments.up.sql ===
14:    CONSTRAINT exam_assignments_id_required CHECK (
```

Nine `CHECK` occurrences across the two files; all nine appear in the table below.

## Group (i) — the one multi-column comparison

### `exams_availability_check`

Source: `012_exams.up.sql` lines 31–33, on table `exams`, verbatim:

```sql
    CONSTRAINT exams_availability_check CHECK (
        available_from IS NULL OR available_until IS NULL OR available_from < available_until
    )
```

- **Entity type / fields constrained:** `exam` — `available_from`, `available_until`
  (both `:datetime`, both `queried: true`, both `required: false`).
- **Why inexpressible:** it compares two columns. There is no `check_def`, and a
  two-column predicate has no field-level shape either.
- **Relocates to:** the exam's authoring form schema, as an `Expr` predicate evaluated
  by the `Expr` evaluators REQ-291 (definition-time evaluation), REQ-292 (server-side
  evaluation) and REQ-293 (the TypeScript evaluator) landed — S10 gap 7, closed.
  REQ-327 does not author the form schema; it records this relocation.
- **Enforcement after relocation:** form-layer only. See the honesty note below — it
  applies to this constraint as much as to group (ii).

## Group (ii) — single-column range checks

All seven of these are range predicates on one column. Each relocates to the same
form-schema / `Expr` layer named above (REQ-291 / REQ-292 / REQ-293).

| Source line | Verbatim | Entity type | Field |
|---|---|---|---|
| `012` :18 | `time_limit_minutes  INT NOT NULL CHECK (time_limit_minutes > 0),` | `exam` | `time_limit_minutes` |
| `012` :19 | `passing_score_pct   DECIMAL(5, 2) NOT NULL CHECK (passing_score_pct BETWEEN 0 AND 100),` | `exam` | `passing_score_pct` |
| `012` :20 | `max_attempts        INT NOT NULL DEFAULT 1 CHECK (max_attempts > 0),` | `exam` | `max_attempts` |
| `012` :44 | `sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),` | `exam_section` | `sort_order` |
| `012` :61 | `count       INT NOT NULL CHECK (count > 0),` | `exam_question_rule` | `count` |
| `012` :62 | `sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),` | `exam_question_rule` | `sort_order` |
| `012` :73 | `sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),` | `exam_manual_question` | `sort_order` |

(Seven rows: `sort_order >= 0` appears on three separate tables and is listed once
per table, since each is a distinct constraint on a distinct entity type.)

### THIS IS A LOSS, NOT AN EQUIVALENT RELOCATION

State it plainly, because softening it would mislead whoever reads this next.

In the source system, PostgreSQL rejected a negative `time_limit_minutes`, a
`passing_score_pct` of `500`, a `count` of `0` or a negative `sort_order` at the
database level, on **every** write path, including any path that bypassed the
application. In Letflow after this port, **nothing in the storage layer will reject
any of those values.** A negative time limit written through the record API directly
is accepted and persisted. There is no entity-definition attribute that would stop it
and no DDL emitted by `lib/letflow/entities/definition/ddl.ex` that encodes a range.

Form-schema / `Expr` validation catches these only on the write paths that go through
a form. It is a weaker guarantee than the source had, and it is not defence in depth
against a direct record write. Do not read the "relocates to" column above as meaning
the constraint is preserved somewhere else — it means the requirement it expressed is
recorded somewhere else, to be re-implemented, with a gap in the meantime.

Closing that gap properly would require either a `check_def` shape in
`Letflow.Entities.Definition` or min/max attributes on `field_def`. Neither exists,
and REQ-327 does not author them — that is a platform change (bucket B), not pack
content.

## Group (iii) — `exam_assignments_id_required`, and the entity that was not authored

Source: `013_exam_assignments.up.sql` lines 14–16, on table `exam_assignments`,
verbatim:

```sql
    CONSTRAINT exam_assignments_id_required CHECK (
        assignee_type = 'all' OR assignee_id IS NOT NULL
    )
```

This is a conditional-requiredness rule across two columns — inexpressible for the
same reason as group (i), and doubly moot here, because the entity type it would
constrain is not authored at all.

### `exam_assignment` — was NOT authored (was an OPEN QUESTION); REQ-582 took shape 1

**Update (REQ-582):** shape 1 below was taken. `entity_definitions/exam_assignment.json` exists, with
an unenforced string `assignee_id` and `assignee_type` over `all|user|group|org_unit`; the
conditional-requiredness rule is not expressible, so a consumer treats a violating record as matching
nobody. The text below is the original analysis, kept as history.

FR-BB33, source table `exam_assignments` in
`013_exam_assignments.up.sql`, roadmap section 3.3.

The reason is substantive, not sizing. The source table's shape:

```sql
CREATE TABLE exam_assignments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id         UUID NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
    assignee_type   assignee_type NOT NULL,
    assignee_id     UUID,
    deadline        TIMESTAMPTZ,
    assigned_by     UUID NOT NULL REFERENCES users(id),
    assigned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ...
```

where `assignee_type` is `CREATE TYPE assignee_type AS ENUM ('user', 'department', 'all')`.

- `assignee_id` is a **polymorphic** reference: its target depends on `assignee_type` —
  a user id, a department id, or nothing at all when the type is `'all'`. No `fk_def`
  can express that: `references_entity` names exactly one entity type, statically.
- Two of the three targets (user, department) live in the **identity subsystem**,
  which an entity `fk_def` cannot reach at all. This is the same boundary that drops
  `created_by` from `exam.json` and, per REQ-326, from that requirement's documents.
- `assigned_by` hits the same boundary as `created_by`, with the same answer: the
  event stream's `actor_id`.

**This is recorded as an open question and is NOT settled here.** REQ-327 may not pick
a shape for it. The candidate shapes noted, without preference:

1. An entity type with an unenforced string reference for `assignee_id`, plus the
   conditional-requiredness rule relocated to the form layer (inheriting the same loss
   documented in group (ii) above).
2. A process-definition concern. Decision `0022`'s reasoning section 1 maps the exam
   lifecycle "assign → notify → take → grade → certify → expire" to a process
   definition on `Letflow.Engine` (bucket A), which would make assignment a process
   instance rather than an entity record.
3. Something else.

Resolution belongs to a later decision-record requirement or to the
process-definition requirement that follows in S10 P2.

## Not a constraint, but recorded here for completeness: `tag_ids`

`012_exams.up.sql` line 59 declares `tag_ids JSONB NOT NULL DEFAULT '[]'::jsonb` on
`exam_question_rules`. That column is not ported as a field; it is remodelled as the
`exam_question_rule_tag` join entity in this directory, per
`docs/anti-patterns.md`'s "Modelling many-to-many as an array of references on the
parent record" entry. The `NOT NULL DEFAULT '[]'` behaviour has no analogue in the
join shape and needs none — the absence of join rows *is* the empty set.

## REQ-329 additions — live-session entities (`session`, `session_question`, `session_answer`, `session_event`, `session_question_score`)

Everything below relocates or records constraints from the three live-session source
migrations:

- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\014_exam_sessions.up.sql`
  (FR-BB35, `exam_sessions` and `session_questions`)
- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\015_session_tables.up.sql`
  (FR-BB36, the AC-2 reshape of `session_questions`, `session_answers`,
  `tab_switch_events`)
- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\016_session_question_scores.up.sql`
  (FR-BB311, `session_question_scores`)

The same governing fact from the sections above applies: `Letflow.Entities.Definition`'s
`constraint_def` only accepts `type: :unique`, there is no `check_def`, and `field_def`
has no range/bound attribute — so every source `CHECK` below has no storage-layer
expression in Letflow and is relocated here explicitly instead of being dropped
silently.

### Relocated `CHECK` constraints

| Source | Verbatim | Entity type | Field |
|---|---|---|---|
| `015` :8-9 | `CONSTRAINT exam_sessions_score_range CHECK (score_pct IS NULL OR score_pct BETWEEN 0 AND 100)` | `session` | `score_pct` |
| `015` :12-13 | `CONSTRAINT exam_sessions_expires_after_start CHECK (expires_at > started_at)` | `session` | `expires_at` / `started_at` (two-column comparison) |
| `014` :29 | `sort_order INT NOT NULL CHECK (sort_order >= 0)` | `session_question` | `sort_order` |
| `015` :57 | `time_spent_seconds INT NOT NULL DEFAULT 0 CHECK (time_spent_seconds >= 0)` | `session_answer` | `time_spent_seconds` |

Same loss as recorded above for the exam-configuration constraints, stated again
because it applies identically here: nothing in the storage layer will reject a
negative `time_spent_seconds`, a `score_pct` of `500`, a negative `sort_order`, or an
`expires_at` earlier than `started_at`, on a record written directly through the
record API. `exam_sessions_expires_after_start` is a two-column comparison, same shape
as `exams_availability_check` above, and inexpressible for the same reason. These
relocate to the form-schema / `Expr` layer (REQ-291/REQ-292/REQ-293) if and when a
form-driven write path exists for sessions; until then the gap is real, not covered.

### ON DELETE — all seven foreign keys across the five documents

`Letflow.Entities.Definition`'s `fk_def` (`lib/letflow/entities/definition.ex`) has no
`on_delete` key at all — its keys are `name`, `field`, `references_entity` and optional
`references_field`. `lib/letflow/entities/definition/ddl.ex:675` emits a fixed,
unconditional `ON DELETE RESTRICT` on every promoted FK column, per decision
`0025` sub-question 1. RESTRICT is therefore not something Letflow might fail to
express — it is the *only* behaviour Letflow can produce, and the only question per FK
is which source behaviour it thereby diverges from.

| # | FK | Source ON DELETE | Letflow ON DELETE | Result |
|---|---|---|---|---|
| 1 | `session.exam_id` | CASCADE | RESTRICT (fixed) | **DIVERGES** |
| 2 | `session.user_id` | CASCADE | *(no `fk_def` — identity subsystem, unreachable)* | no Letflow FK exists; listed for completeness |
| 3 | `session_question.session_id` | CASCADE | RESTRICT (fixed) | **DIVERGES** |
| 4 | `session_question.question_id` | RESTRICT (changed from CASCADE by `015` AC-2) | RESTRICT (fixed) | MATCHES |
| 5 | `session_answer.session_id` | CASCADE | RESTRICT (fixed) | **DIVERGES** |
| 6 | `session_answer.question_id` | RESTRICT | RESTRICT (fixed) | MATCHES |
| 7 | `session_event.session_id` | CASCADE | RESTRICT (fixed) | **DIVERGES** |
| 8 | `session_question_score.session_id` | CASCADE | RESTRICT (fixed) | **DIVERGES** |
| 9 | `session_question_score.question_id` | RESTRICT | RESTRICT (fixed) | MATCHES |

Nine rows total: `session.user_id` (row 2) has no Letflow `fk_def` at all and is listed
for completeness only, not as an FK. The other eight rows are the eight real `fk_def`s
declared across the five documents' `foreign_keys` arrays — `session` declares 1
(`exam_id`), `session_question` declares 2, `session_answer` declares 2, `session_event`
declares 1, `session_question_score` declares 2 (1+2+2+1+2 = 8), of which three MATCH
(rows 4, 6, 9) and five DIVERGE (rows 1, 3, 5, 7, 8) — the same 3-match/5-diverge split
the requirement itself states in its description. Note: the acceptance criterion's own
title calls this "the seven foreign keys," but its body enumerates "THREE FKs MATCH" and
"FIVE DIVERGE," which is eight, matching the actual count of `fk_def`s in the five
documents; the "seven" in the title does not match either the requirement's own body
count or the documents as authored, and is flagged here rather than silently reconciled.

**THIS IS A BEHAVIOURAL LOSS, NOT A COSMETIC ONE.** In the source system, deleting an
exam **cascaded** its entire session history away: every session, every resolved
question set, every saved answer, every tab-switch/blur/fullscreen event, and every
per-question score tied to that exam's sessions was silently removed along with it. In
Letflow, that same delete is **refused by Postgres** with a foreign-key violation for
as long as any `session` row still references the exam (and transitively, for as long
as any `session_question`, `session_answer`, `session_event` or
`session_question_score` row still references that session) — every one of rows 1, 3,
5, 7, 8 above is a CASCADE-to-RESTRICT divergence, not just the `exam_id` one. Any
tenant-facing exam-deletion path must therefore explicitly delete (or otherwise
retire) the dependent session rows itself, in dependency order, before the exam
delete will succeed — otherwise the operation simply fails. Naming decision `0025`
without naming this consequence understates what changed.

### TIMESTAMPTZ → naive `timestamp(6)` — new entry, nothing to inherit

Every `datetime` column across the three source migrations is `TIMESTAMPTZ`:
`exam_sessions.started_at`, `expires_at`, `submitted_at`, `created_at` (dropped, see
`session.json`'s OMISSIONS), `session_answers.saved_at`, and
`tab_switch_events.occurred_at`. `lib/letflow/entities/definition/ddl.ex:318` maps
Letflow's `:datetime` to `timestamp(6) without time zone` — the UTC/local offset each
source value carried is dropped on every one of these columns, unconditionally, the
same way it is dropped for every other `:datetime` field this pack has declared so far.

This is recorded as a new entry because none of REQ-326/REQ-327's documents raised it
(their `:datetime` fields — `exam.available_from`/`available_until` — did not carry the
same downstream comparison risk). It matters here in a way it did not there:
**`session.expires_at` is not a cosmetic loss.** REQ-331's auto-submit sweep compares
`expires_at` against a computed `now` **across tenants**, on a schedule, without a
human in the loop. A naive column populated from values written in mixed UTC offsets
would expire timed sessions early or late relative to the wall-clock deadline the
candidate was actually given — that is a correctness bug in the exam deadline itself,
not a display nit anyone would notice and shrug off.

The invariant that keeps the comparison correct, now that the column type itself no
longer enforces any offset guarantee, must be held by the runtime instead: **every
`:datetime` value on these five entity types is normalised to UTC before it is written,
and the sweep's `now` is computed in UTC.** This is a runtime obligation from here on,
not a storage-layer guarantee — nothing in `ddl.ex` or the entity subsystem will catch
a value written in local time.
