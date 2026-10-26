# REQ-345 — Deterministic seeded exam fixture for e2e runs (mixed exam, scoreable exam, one submitted session)

**Module (new):** `Mix.Tasks.Letflow.Seed.ExamFixtures`
**Task invocation:** `mix letflow.seed.exam_fixtures`
**Stage:** S10 P5 (test fixture)
**Author:** CODE-DESIGNER, 2026-09-14
**Depends on (read before implementing):** REQ-328 (pack definitions), REQ-332
(`Letflow.Exam.Session`/`Letflow.Exam.Scoring`/`Letflow.Exam.QuestionSetResolver`),
REQ-335 (`Letflow.Routers.ExamSessions`)

## 0. Task-shape decision — sibling task, not a flag on `mix letflow.seed`

**Decision: a new sibling task, `mix letflow.seed.exam_fixtures`, not a flag added to
`Mix.Tasks.Letflow.Seed`.**

Reasoning:
- `mix letflow.seed` (`lib/mix/tasks/letflow.seed.ex`) has exactly one job today —
  provision the `bpm-default` tenant row and replay its migrations — and its own
  `@moduledoc` states that plainly ("provisions the tenant only"). It takes no
  arguments (`run(_args)`).
- This fixture needs the tenant to already exist and be schema-provisioned (it reads
  `bpm-default`'s `entity_definitions` and writes `entity_record_latest` rows against
  it) — a strict *after* dependency, not a parallel concern. Folding it in as
  `--with-exam-fixtures` would make one task do two independently-versioned things
  (tenant bootstrap vs. domain test-content seeding) and would force every caller of
  bare `mix letflow.seed` (CI tenant bootstrap, `mix ecto.setup`, if it shells out to
  it) to actively opt out of exam-fixture creation forever, or accept it unconditionally.
- A sibling task can be invoked on its own after `mix letflow.seed` in whatever order a
  CI/e2e setup script wants, matches the existing precedent of task-per-concern in
  `lib/mix/tasks/` (one file, one job), and needs no argument-parsing changes to the
  existing task at all.
- `Mix.Tasks.Letflow.Seed.ExamFixtures` runs `Mix.Task.run("letflow.seed")` as its own
  first step (below) so a bare `mix letflow.seed.exam_fixtures` on a fresh database is
  still self-sufficient for e2e setup scripts that only want to invoke one command.

## 1. `@moduledoc` — exact required content (verbatim data ELIXIR-DEV must reproduce)

The `@moduledoc` MUST state, verbatim or near-verbatim, the following facts (each
maps to one of REQ-345's acceptance criteria):

```
mix letflow.seed.exam_fixtures — REQ-345

Seeds, in the bpm-default tenant, via Letflow.Entities.Records (never direct SQL):

  * category "REQ-345 Mixed Exam Bank" (track: nil) — houses exactly the 5
    questions below, used by NO other exam.
  * category "REQ-345 Scoreable Exam Bank" (track: nil) — houses exactly the 3
    questions below, used by NO other exam.

  * Exam 1 — "REQ-345 E2E Mixed Exam" (status: active), one question per
    question.json's full 5-member type enum:
      Q1 single    "REQ-345 Mixed Q1 (single)"    — 2 options, option A correct
      Q2 multiple  "REQ-345 Mixed Q2 (multiple)"  — 3 options, options A+B correct
      Q3 truefalse "REQ-345 Mixed Q3 (truefalse)" — 2 options, "True" correct
      Q4 likert    "REQ-345 Mixed Q4 (likert)"    — 2 options, weights 1.0/5.0, positive
      Q5 shorttext "REQ-345 Mixed Q5 (shorttext)" — 0 options (free text, ungraded)
    Because Q5's type is shorttext, lib/letflow/exam/scoring.ex:255's
    `Enum.any?(questions, &(&1.type == :short_text))` is true for EVERY session
    of this exam, so build_outcome/3 (scoring.ex:255/:257) can only ever
    produce status: :grading_pending and passed: nil for this exam — never a
    score. This is a property of the fixture, not a defect.

  * Exam 2 — "REQ-345 E2E Scoreable Exam" (status: active), passing_score_pct:
    60.00, 3 questions, NONE shorttext:
      R1 single    "REQ-345 Scoreable R1 (single)"    — 2 options, option A correct
      R2 truefalse "REQ-345 Scoreable R2 (truefalse)" — 2 options, "True" correct
      R3 multiple  "REQ-345 Scoreable R3 (multiple)"  — 3 options, options A+B correct
    Worked arithmetic (lib/letflow/exam/scoring.ex score_question/2, all three
    questions max_score 1.0 each, total_max_score 3.0):
      PASSING combination — R1 correct (1.0), R2 correct (1.0), R3 both
        correct options selected, no incorrect ((2-0)/2 = 1.0 clamped to
        [0,1]) — total_score 3.0/3.0 = 100.00% >= 60.00 => passed: true.
      FAILING combination — R1 incorrect (0.0), R2 incorrect (0.0), R3
        unanswered (unanswered = wrong per scoring.ex's own rule, 0.0) —
        total_score 0.0/3.0 = 0.00% < 60.00 => passed: false.
    Both Passed and Failed are therefore reachable against this exam.

  * One session against Exam 1 (the mixed exam), created via
    POST /exam-sessions and finished via POST /exam-sessions/:id/submit —
    Letflow.Routers.ExamSessions, REQ-335's real route table — dispatched
    in-process through Letflow.Router.call/2 (the exact same full Plug
    pipeline test/letflow/routers/exam_sessions_test.exs itself dispatches
    through), authenticated as a dedicated seed candidate user
    ("req345.candidate@example.com" / username "req345-e2e-candidate") minted
    a TASK_WORKER-role token via Letflow.Identity.create_token/3. No answers
    are autosaved before submit — unanswered questions score 0 per
    scoring.ex's "unanswered = wrong, not skipped" rule, which changes
    nothing about this session's outcome (it is grading_pending regardless,
    because of Q5). Persisted/returned outcome: status "grading_pending",
    score_pct 0.0, passed nil.

  ASSIGNED (REQ-582): Session.check_assigned/3 is now enforced, so the seed
  writes one active "all" exam_assignment per fixture exam (it was a no-op
  when this design was written).

  ASSERTABLE ONLY OVER RAW HTTP. The seeded session can be asserted via
  GET /exam-sessions/:id only. web/src/pages/exam/ExamSessionPage.tsx:112-127's
  mount effect calls examApi.startSession(examId) UNCONDITIONALLY (guarded
  only by a startedRef ref, not by "does a session already exist") — there is
  no branch in that component, or anywhere in web/src/router.tsx's exam
  routes, that loads an existing session by id. Navigating a browser to the
  session route starts a NEW session instead of reading this one. Do not
  treat this fixture as backing any rendered result screen.

  IDEMPOTENT. Re-running this task converges: a second run creates zero new
  exam/category/question/answer_option/exam_question_rule records (each
  create_record/2 call carries a fixed, content-derived idempotency_key, and
  Letflow.Entities.Records.create_record/2 returns the ORIGINAL record for a
  repeated key — design doc req228, AC3) and creates zero new sessions (the
  task queries for an existing session against Exam 1 for the seed candidate
  before calling POST /exam-sessions at all, and skips straight to reporting
  its already-persisted outcome if one is found).

  QUESTION TYPE ENUM, VERIFIED: priv/packs/bilimbaga/entity_definitions/
  question.json's `type` field enum is
  ["single","multiple","truefalse","likert","shorttext"] — all five of
  BilimBaga's original five question types carry over unchanged; NONE of the
  five lacks a Letflow counterpart. ("shorttext", no underscore, is the pack
  enum's own spelling; lib/letflow/exam/session.ex:1174's
  question_type_atom/1 maps it to the :short_text atom, which is what
  scoring.ex:255 tests against — this design and its implementation assert
  on the pack's "shorttext" spelling when WRITING question records, and on
  the :short_text atom only when reading back Letflow.Exam.Session/Scoring's
  own in-memory shapes — never on a fabricated ":shorttext" atom.)
```

## 2. Public API

```
@spec run(args :: [String.t()]) :: :ok
```

No arguments read or accepted (mirrors `Letflow.Seed`'s own `run(_args)` shape). No
other public functions — this is a `Mix.Task`, not a library module; all seeding
logic lives in private functions in the same file, organized into three private
sections mirroring the three artifacts (categories+questions+options, exams+rules,
session).

## 3. Constants (module attributes — the "fixed, documented" identifying content)

```
@candidate_username "req345-e2e-candidate"
@candidate_email "req345.candidate@example.com"
@candidate_display_name "REQ-345 E2E Seed Candidate"

@mixed_exam_title "REQ-345 E2E Mixed Exam"
@scoreable_exam_title "REQ-345 E2E Scoreable Exam"
@scoreable_passing_score_pct 60.0

@mixed_category_title "REQ-345 Mixed Exam Bank"
@scoreable_category_title "REQ-345 Scoreable Exam Bank"
```

Every question/option's title/stem/text string used below is likewise a hardcoded
literal, not derived at runtime, so a Playwright/e2e spec (REQ-346's consumer) can
assert on it by name.

## 4. Idempotency mechanism — exact mechanics, no ambiguity left to ELIXIR-DEV

Two DIFFERENT idempotency mechanisms are used, for two different kinds of writes,
and the design doc is explicit about which applies where:

### 4a. Entity records (category / question / answer_option / exam / exam_question_rule)

`Letflow.Entities.Records.create_record/2` (`lib/letflow/entities/records.ex:158`)
already has a **repeat-idempotency_key → return-original-record** guarantee (its own
`@doc`, step 6: "A duplicate `idempotency_key` returns the **original** record
(AC3)"). This task exploits that directly instead of hand-rolling a
query-then-create pattern: **every entity-record write in this task passes a
fixed, non-random, content-derived `idempotency_key`** — never
`Ecto.UUID.generate()` (that is what `Letflow.ExamFixtures.create_record!/4`, the
TEST-only helper, deliberately does for test isolation; this task's writes must
NOT copy that helper's random-key behavior, since randomness there is exactly what
would defeat convergence here).

Concrete key scheme (one constant string per record, built once as a private
`@idempotency_keys` map or a set of module attributes — implementor's choice of
data shape, not of VALUES):

```
"req345-seed-category-mixed"
"req345-seed-category-scoreable"
"req345-seed-question-mixed-q1-single"
"req345-seed-question-mixed-q2-multiple"
"req345-seed-question-mixed-q3-truefalse"
"req345-seed-question-mixed-q4-likert"
"req345-seed-question-mixed-q5-shorttext"
"req345-seed-question-scoreable-r1-single"
"req345-seed-question-scoreable-r2-truefalse"
"req345-seed-question-scoreable-r3-multiple"
"req345-seed-option-mixed-q1-a" / "-b"
"req345-seed-option-mixed-q2-a" / "-b" / "-c"
"req345-seed-option-mixed-q3-true" / "-false"
"req345-seed-option-mixed-q4-low" / "-high"
"req345-seed-option-scoreable-r1-a" / "-b"
"req345-seed-option-scoreable-r2-true" / "-false"
"req345-seed-option-scoreable-r3-a" / "-b" / "-c"
"req345-seed-exam-mixed"
"req345-seed-exam-scoreable"
"req345-seed-rule-mixed"
"req345-seed-rule-scoreable"
```

Every one of these calls is a plain `Letflow.Entities.Records.create_record/2` call
with `actor_id:` set to the seed candidate user's own id (§5 below — no
`Letflow.EventStore.platform_actor_id/0` reuse: that sentinel's own moduledoc scopes
it to "non-instance-scoped scheduler events," a different, later-stage concern; this
fixture doesn't need a second synthetic identity to stand in for "who authored this
content" when the seed candidate itself is already a real, if fixture-only, user).
On EVERY run (first or Nth), the task calls `create_record/2` with the SAME attrs
and the SAME `idempotency_key` for each of the ~24 records above; a first run
inserts, every later run gets back `{:ok, %{record: same_original_record,
is_duplicate: true}}` — no branch on "does this already exist" is written by hand
anywhere in this task; convergence is a property `create_record/2` itself already
guarantees, reused as-is (per REQ-345's own "NOT a hand-rolled second write path"
instruction).

### 4b. The candidate user (`Letflow.Identity`)

`Letflow.Identity.create_user/2` has no `idempotency_key` mechanism (it is a plain
`Ecto.Multi.insert` — different subsystem, different guarantee shape). Idempotency
here follows `mix letflow.seed`'s OWN create-or-resolve pattern exactly:

1. Call `Letflow.Identity.create_user(%{"username" => @candidate_username,
   "display_name" => @candidate_display_name, "email" => @candidate_email},
   prefix: prefix)`.
2. `{:ok, user}` → this is the first run; proceed with `user`.
3. `{:error, :duplicate_username}` → resolve the existing row with a direct,
   read-only `Letflow.Repo.get_by(Letflow.Identity.User, [username:
   @candidate_username], prefix: prefix)` call. This is a **read**, not a write —
   it does not touch the entity-records subsystem REQ-345's "no direct SQL"
   language governs (that language is about the exam/session content, which lives
   in `entity_record_latest`; `Letflow.Identity.User` is an ordinary Ecto-schema
   table the identity subsystem already owns and reads via plain `Repo` calls
   itself, e.g. `Letflow.Identity.get_user/2`'s own `Repo.get/3`). No public
   `Letflow.Identity.get_user_by_username/2` exists today (only
   `get_user/2` by id) — this is the one place this task reads a table directly
   rather than through a named `Letflow.Identity` function, and it is flagged here
   explicitly rather than silently done, per this project's anti-pattern
   discipline.
4. Any other `{:error, _}` from `create_user/2` → `Mix.raise/1` with the reason,
   same failure idiom as `Letflow.Seed`'s own `{:error, %Ecto.Changeset{}}` branch.

A fresh token is minted via `Letflow.Identity.create_token(user.id, %{roles:
["TASK_WORKER"], expires_at: nil}, prefix: prefix)` on EVERY run (first or Nth) —
this is deliberately NOT idempotency-guarded: a token is a disposable credential
used only to authenticate this task's own in-process HTTP dispatch (§6) and is
never asserted on by any acceptance criterion or consumed by REQ-346. Minting a
fresh one every run is simpler than resolving/reusing an old one and carries no
observable behavior difference for anything this requirement or its consumers
check. (Flagged so ELIXIR-DEV doesn't mistake this for an oversight: it is a
deliberate scope-narrowing, not a gap.)

### 4c. The session

`Letflow.Exam.Session.create/3`'s own eligibility pipeline (`session.ex`) rejects a
second concurrent open session for the same `(candidate, exam)` pair
(`:session_already_open`), and rejects a second session at all past
`max_attempts` (`:attempts_exhausted`) — neither is the mechanism this task relies
on for convergence, because BOTH are errors, not "return the same session," and
because this task's flow submits its one session immediately (no lingering
`in_progress` state to collide with). Convergence for the session is instead a
**query-before-create** the task performs itself, using the SAME
`Letflow.Entities.Query.Compiler.compile/2` + `Repo.all/2` idiom
`lib/letflow/exam/session.ex`'s own private `query_all/3` helper uses (not raw
SQL — the compiled-query surface backing `POST /entities/query` itself):

```
Compiler.compile(%{entity_type: "session",
                    filters: [%{field: "exam_id", op: :eq, value: mixed_exam_id},
                              %{field: "user_id", op: :eq, value: candidate.id}]},
                  prefix)
|> Repo.all(prefix: prefix)
```

- Zero rows found → this is the first run: dispatch `POST /exam-sessions` then
  `POST /exam-sessions/:id/submit` (§6, "create path").
- One row found → a prior run already created this session; skip
  `POST /exam-sessions` and go straight to `POST /exam-sessions/:id/submit` for
  that existing `session_id` (§6, "resolve path") — relying on
  `Letflow.Exam.Session.submit/3`'s own documented idempotence ("an
  already-submitted/auto-submitted/grading-pending session returns the recorded
  outcome without re-scoring") to get back the SAME `submission_outcome_json/1`
  body a first run would have produced, through the SAME real route. This is
  deliberately NOT a `GET /exam-sessions/:id` call: `session_state_json/1`
  (the `GET` route's response shape) carries no `score_pct`/`passed`/`percentage`
  field at all (only `submission_outcome_json/1`, `POST .../submit`'s own response
  shape, does) — quoting the acceptance-criteria-required
  status/score_pct/passed after a second run therefore requires ending on the
  submit call either way, so both branches converge on the same final HTTP call
  and differ only in whether `POST /exam-sessions` runs first.
- More than one row → `Mix.raise/1` naming the count; this should be structurally
  impossible given the above (a real bug if it ever happens), and this task must
  not silently pick one.

`Letflow.Exam.Session.submit/3` is ALSO independently idempotent (its own `@doc`:
"an already-submitted/auto-submitted/grading-pending session returns the recorded
outcome without re-scoring") — so even if the query-before-create step above were
skipped by a future edit, calling submit twice on the same session id is still
safe. This task relies on the query step as the PRIMARY convergence mechanism
(so re-running the task doesn't even issue a second `POST /exam-sessions` call,
avoiding a wasted `session_already_open`/`attempts_exhausted` round trip) and on
submit's own idempotency as a secondary, defense-in-depth property — not the
other way around.

## 5. Actor id for entity-record writes

The seed candidate user's own `id` (an `Ecto.UUID.t()`, resolved in §4b before any
entity-record write happens — the candidate user must therefore be created/resolved
FIRST, before any category/question/exam write, changing the natural call order from
"content then candidate" to "candidate then content"). Passed as `actor_id:` to
every `create_record/2` call in §4a. No second, content-authoring identity is
invented.

## 6. HTTP call sequence — exact dispatch mechanism

"Real HTTP" here means dispatching through the real `Letflow.Router` Plug pipeline
in-process — the identical mechanism
`test/letflow/routers/exam_sessions_test.exs` already uses to test these same
routes (`dispatch/1` = `Letflow.Router.call(conn, Letflow.Router.init([]))`), NOT a
literal TCP round trip against a bound port (this task runs inside `mix`, which has
not started `Letflow.Endpoint`'s listener at the point this task runs, and does not
need to for "the real route" to be exercised — the router module IS the route).
This is the same "real route" REQ-335's own acceptance criteria were proven
against, by the same test file, and is stated here explicitly as a design decision
rather than left for ELIXIR-DEV to improvise, since REQ-345's wording ("POST
/exam-sessions") could otherwise be misread as requiring a live network call.

Sequence (only on the "zero rows found" branch of §4c):

1. Build a `Plug.Test.conn(:post, "/exam-sessions", Jason.encode!(%{"exam_id" =>
   mixed_exam_id}))`, `put_req_header("content-type", "application/json")`,
   `put_req_header("authorization", "Bearer " <> token_plaintext)`,
   `put_req_header("x-tenant-slug", "bpm-default")`.
2. Dispatch via `Letflow.Router.call(conn, Letflow.Router.init([]))`.
3. Assert `conn.status == 201`; `Jason.decode!(conn.resp_body)` gives the
   `session_state_json/1` shape (`"session" => %{"id" => session_id, ...}`,
   `"remaining_seconds"`, `"questions"`, `"answers"`) — extract `session_id`.
   Any other status → `Mix.raise/1` quoting the full response body verbatim (this
   is the literal text the close-out's "close-out quotes both real HTTP responses"
   acceptance criterion requires capturing).
4. Build a second conn: `Plug.Test.conn(:post, "/exam-sessions/#{session_id}/submit")`
   with the same two headers (no body — `handle_submit_session/2` reads only the
   path `:id`).
5. Dispatch the same way. Assert `conn.status == 200`;
   `Jason.decode!(conn.resp_body)` gives `submission_outcome_json/1`'s shape
   (`"status"`, `"total_score"`, `"total_max_score"`, `"percentage"`, `"passed"`).
   Any other status → `Mix.raise/1` quoting the body verbatim.
6. `Mix.shell().info/1` both raw JSON response bodies verbatim (this is what the
   close-out later quotes) plus a one-line human summary
   ("status=grading_pending score_pct=0.0 passed=null" style).

No answers are autosaved between steps 3 and 4 — `PUT
/exam-sessions/:id/answers/:question_id` is never called by this task. This is a
deliberate simplification: the mixed exam's outcome is `grading_pending`/`passed:
nil` regardless of what is answered (Q5 alone forces that), so answering the other
four questions would add HTTP calls and per-question option ids to track for zero
observable change in the one property (`status`) this fixture exists to make
assertable. Flagged as a deliberate simplification, not an oversight, for
CODE-DESIGN-VALIDATOR and any later reader who expects a "fully answered" fixture
session — REQ-345's own text asks only for "started and submitted," not "fully
answered."

**"One row found" branch of §4c — final decision:** run ONLY steps 4-6 above
(build/dispatch `POST /exam-sessions/#{existing_session_id}/submit`, assert 200,
capture the body), skipping steps 1-3 (`POST /exam-sessions` is never called
again). This relies on `Session.submit/3`'s own documented idempotence (§4c) to
return the SAME `submission_outcome_json/1` body a first run would have produced,
through the same real route, and keeps both branches structurally identical past
step 3. `GET /exam-sessions/:id` is never called by this task at all — REQ-345's
own text states that route as a fact about what a LATER caller/spec can assert
through (§9's "assertable only over raw HTTP" framing), not an instruction that
this seed task itself must call it, and `session_state_json/1` (the `GET` route's
own response shape) carries no `score_pct`/`passed`/`percentage` field anyway
(only `submission_outcome_json/1` does), so `GET` could not supply the close-out's
required second-run quote even if called.

## 7. Field-value shapes for each entity-record write (exact `field_values` maps)

All `:localized_text` fields below use a single `"en"` locale key only (the pack
declares `["kk","ru","en"]` as available locales, but only `en` is required content
for this fixture — an e2e spec asserting in English is the only consumer named in
REQ-345/REQ-346).

### 7a. Categories

```
category (mixed):    %{"name" => %{"en" => "REQ-345 Mixed Exam Bank"}, "track" => nil, "sort_order" => 0}
category (scoreable): %{"name" => %{"en" => "REQ-345 Scoreable Exam Bank"}, "track" => nil, "sort_order" => 0}
```

### 7b. Questions (`category_id` = the resolved category record's `record_id` from 7a)

```
Q1 (mixed, single):    %{"category_id" => cat_id, "difficulty" => "easy", "type" => "single",
                          "default_locale" => "en", "status" => "active", "version" => 1,
                          "stem" => %{"en" => "REQ-345 Mixed Q1 (single)"}}
Q2 (mixed, multiple):  %{..., "type" => "multiple", "stem" => %{"en" => "REQ-345 Mixed Q2 (multiple)"}}
Q3 (mixed, truefalse): %{..., "type" => "truefalse", "stem" => %{"en" => "REQ-345 Mixed Q3 (truefalse)"}}
Q4 (mixed, likert):    %{..., "type" => "likert", "stem" => %{"en" => "REQ-345 Mixed Q4 (likert)"}}
Q5 (mixed, shorttext): %{..., "type" => "shorttext", "stem" => %{"en" => "REQ-345 Mixed Q5 (shorttext)"}}
R1 (scoreable, single):    %{..., "category_id" => scoreable_cat_id, "type" => "single",
                              "stem" => %{"en" => "REQ-345 Scoreable R1 (single)"}}
R2 (scoreable, truefalse): %{..., "type" => "truefalse", "stem" => %{"en" => "REQ-345 Scoreable R2 (truefalse)"}}
R3 (scoreable, multiple):  %{..., "type" => "multiple", "stem" => %{"en" => "REQ-345 Scoreable R3 (multiple)"}}
```

(`explanation` omitted — `required: false`.)

### 7c. Answer options (`question_id` = the resolved question record's `record_id`)

```
Q1: option A %{"question_id"=>q1,"sort_order"=>0,"is_correct"=>true,  "text"=>%{"en"=>"A"}}
    option B %{"question_id"=>q1,"sort_order"=>1,"is_correct"=>false, "text"=>%{"en"=>"B"}}
Q2: option A %{"question_id"=>q2,"sort_order"=>0,"is_correct"=>true,  "text"=>%{"en"=>"A"}}
    option B %{"question_id"=>q2,"sort_order"=>1,"is_correct"=>true,  "text"=>%{"en"=>"B"}}
    option C %{"question_id"=>q2,"sort_order"=>2,"is_correct"=>false, "text"=>%{"en"=>"C"}}
Q3: option True  %{"question_id"=>q3,"sort_order"=>0,"is_correct"=>true,  "text"=>%{"en"=>"True"}}
    option False %{"question_id"=>q3,"sort_order"=>1,"is_correct"=>false, "text"=>%{"en"=>"False"}}
Q4 (likert, is_correct always false — likert has no "correct" option, only weight/polarity):
    option Low  %{"question_id"=>q4,"sort_order"=>0,"is_correct"=>false,
                   "likert_weight"=>1.0,"likert_polarity"=>"positive","text"=>%{"en"=>"Strongly disagree"}}
    option High %{"question_id"=>q4,"sort_order"=>1,"is_correct"=>false,
                   "likert_weight"=>5.0,"likert_polarity"=>"positive","text"=>%{"en"=>"Strongly agree"}}
Q5 (shorttext): NO answer_option records — short-text questions have no options,
    matching build_question_row/2's own likert-only special-casing and the absence
    of any options-based scoring path for :short_text in scoring.ex.
R1: option A %{"question_id"=>r1,"sort_order"=>0,"is_correct"=>true,  "text"=>%{"en"=>"A"}}
    option B %{"question_id"=>r1,"sort_order"=>1,"is_correct"=>false, "text"=>%{"en"=>"B"}}
R2: option True  %{"question_id"=>r2,"sort_order"=>0,"is_correct"=>true,  "text"=>%{"en"=>"True"}}
    option False %{"question_id"=>r2,"sort_order"=>1,"is_correct"=>false, "text"=>%{"en"=>"False"}}
R3: option A %{"question_id"=>r3,"sort_order"=>0,"is_correct"=>true,  "text"=>%{"en"=>"A"}}
    option B %{"question_id"=>r3,"sort_order"=>1,"is_correct"=>true,  "text"=>%{"en"=>"B"}}
    option C %{"question_id"=>r3,"sort_order"=>2,"is_correct"=>false, "text"=>%{"en"=>"C"}}
```

### 7d. Exams

```
mixed:     %{"title"=>%{"en"=>"REQ-345 E2E Mixed Exam"}, "status"=>"active",
             "time_limit_minutes"=>30, "passing_score_pct"=>60.0, "max_attempts"=>5,
             "shuffle_questions"=>false, "shuffle_options"=>false,
             "show_answers"=>"never", "on_tab_switch"=>"log", "certificate_enabled"=>false}
scoreable: %{"title"=>%{"en"=>"REQ-345 E2E Scoreable Exam"}, "status"=>"active",
             "time_limit_minutes"=>30, "passing_score_pct"=>60.0, "max_attempts"=>5,
             "shuffle_questions"=>false, "shuffle_options"=>false,
             "show_answers"=>"never", "on_tab_switch"=>"log", "certificate_enabled"=>false}
```

`status: "active"` is the pack's own enum member (`["draft","active","archived"]`)
standing in for "published" — the pack has no literal "published" value; this is
stated explicitly per REQ-345's own instruction not to assume unverified vocabulary.
`available_from`/`available_until` omitted (`required: false`; an absent value means
`check_availability_window/1` (`session.ex`) finds no window and passes both exams
unconditionally). `max_attempts: 5` (not `1`) is deliberate headroom so a re-run
that (for whatever reason) needed a second `create/3` call for the SAME candidate
would not spuriously hit `:attempts_exhausted` — irrelevant to correctness today
(§4c's query-before-create means at most one `create/3` call is ever made per
candidate/exam pair across all runs) but cheap insurance against a future edit
weakening that guarantee.

### 7e. `exam_question_rule` (the ONLY mechanism `Letflow.Exam.Session.materialize_session/5`
reads to pick a session's questions — a `mode: "manual"` rule is silently ignored by
`fetch_question_pools/2`'s own `Enum.filter(&(fv(&1, "mode") == "random"))`, so
`mode` MUST be `"random"` here even though nothing about these two categories'
membership is actually randomized in practice, since `count` equals each category's
full active-question count)

```
mixed:     %{"exam_id"=>mixed_exam_id, "section_id"=>nil, "mode"=>"random",
             "category_id"=>mixed_cat_id, "difficulty"=>nil, "count"=>5, "sort_order"=>0}
scoreable: %{"exam_id"=>scoreable_exam_id, "section_id"=>nil, "mode"=>"random",
             "category_id"=>scoreable_cat_id, "difficulty"=>nil, "count"=>3, "sort_order"=>0}
```

`count` exactly equals the number of active questions in each dedicated category —
each category is used by NO other exam in this tenant (fresh, fixture-only
categories), so `QuestionSetResolver.resolve/5`'s `pick_from_rules/2`
(`Enum.shuffle |> Enum.take(count)`) always selects ALL of that category's
questions regardless of the random seed `Session.create/3` draws — membership is
deterministic even though the seed/shuffle machinery still runs (a pool of exactly
5 members with `count: 5` always yields all 5; `count < pool size` is the only case
where shuffle affects WHICH questions are picked, not this one). Only per-question
ORDER can vary run to run (`shuffle_questions: false` on both exams additionally
fixes ordering to whatever `pick_from_rules/2`'s internal shuffle produced, which
this task does not need to control since REQ-345 does not require a fixed
on-screen question order — only fixed question CONTENT/types).

## 8. Failure/output contract

- Every `create_record/2` / `create_user/2` / `create_token/3` failure not already
  named above → `Mix.raise/1` quoting `inspect(reason)`, same idiom as
  `Letflow.Seed`.
- On full success, `Mix.shell().info/1` a summary naming both exam titles, both
  exam ids, both categories' question-id lists (id + type, so a close-out can quote
  them), the session id, and the final submit response body verbatim — this is the
  literal text a close-out is expected to paste, so the task's own stdout must
  already contain everything the acceptance criteria ask the close-out to quote
  (no criterion should require re-deriving something the task itself didn't print).
- The task performs NO cleanup/deletion of any prior run's records — convergence is
  achieved by resolving to the SAME records (§4), never by deleting and recreating.

## 9. What this task does NOT do (explicit non-goals, restating REQ-345's own fences)

- No `exam_assignment` entity, table, or workaround of any kind — `grep -rn
  exam_assignment` over this task's own source and over `git diff` must return
  nothing (aside from this design doc's and the task's own comments describing the
  gap, which are prose, not code).
- No direct `INSERT` SQL anywhere — every exam-domain write goes through
  `Letflow.Entities.Records.create_record/2`; the session is created/submitted only
  through the two real HTTP routes (§6); the only direct `Repo` calls this task
  makes are: (a) the one identity-user resolve-by-username read (§4b, a READ, and
  explicitly flagged), and (b) the session existence check's `Repo.all/2` over a
  `Letflow.Entities.Query.Compiler`-COMPILED query (§4c) — the same compiled-query
  surface `POST /entities/query` itself runs, not a hand-written SQL fragment.
- No direct write of `score_pct`/`passed`/`status` onto any session record — those
  three fields are set exclusively by `Letflow.Exam.Session.submit/3` itself,
  reached only through `POST /exam-sessions/:id/submit`.
- No autosave calls (`PUT /exam-sessions/:id/answers/:question_id`) — see §6's own
  reasoning for why this is a deliberate simplification, not a gap.
- No result-view/UI assertion of any kind — this task is backend-only (`mix` task
  writing through backend routes); REQ-346/REQ-349 (FRONTEND-DEV, separate
  requirements) are the only later consumers of the two SEEDED EXAMS, and
  REQ-349's own dependency note (per REQ-346's description) says it needs the
  SECOND exam and its `passing_score_pct`, not this seeded session.

## 10. Open questions for ELIXIR-DEV / CODE-DESIGN-VALIDATOR

1. **`likert_weight`/`likert_polarity` field types on `answer_option`** — the pack
   declares `likert_weight` as `:decimal` (precision 5, scale 2). §7c above writes
   plain floats (`1.0`, `5.0`) as Elixir literals in `field_values`; confirm against
   `Letflow.Entities.Record.Validator`'s `:decimal` field-subschema whether a bare
   float is accepted as-is or must be wrapped/cast (e.g. via `Decimal.new/1` or a
   string) before being handed to `create_record/2` — `lib/letflow/exam/
   session.ex`'s own `to_float/1` helper only ever CONVERTS `Decimal.t()` values
   read BACK from storage; it says nothing about what shape is accepted on the way
   IN. Not resolved here — ELIXIR-DEV must check the validator (or a passing
   existing test writing a `:decimal` field, e.g. `passing_score_pct` in
   `session_test.exs`'s own `create_exam!/2`, which does pass a bare float `60.0`
   successfully) before writing this task's `field_values` maps literally as shown.
2. **Whether `Letflow.Router` needs `Mix.Task.run("app.start")` alone, or something
   more, to be dispatchable from inside a `mix` task** — `Letflow.Seed` only ever
   calls plain context functions, never dispatches through the Plug router itself
   from a `Mix.Task`; confirm `Letflow.Router.call/2` is safe to invoke this way
   outside of ExUnit's `Letflow.DataCase`/`Letflow.ConnCase`-style setup (e.g.
   whether any test-only `Sandbox` checkout the router pipeline implicitly relies
   on in tests needs a substitute for a `mix` task running against the real,
   non-sandboxed `Letflow.Repo` connection pool). Flagged as a real risk, not
   silently assumed safe.
