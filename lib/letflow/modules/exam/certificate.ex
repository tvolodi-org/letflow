defmodule Letflow.Modules.Exam.Certificate do
  @moduledoc """
  REQ-355 -- idempotent issue-on-first-request certificate issuance. Ported
  from `backend/internal/certificates/service.go`'s `GetOrCreate`
  (FR-BB43, migration `019_certificates.up.sql`, spec
  `docs/requirements/FR-BB43.Certificate-generation.md`) --
  `c:\\Users\\tvolo\\dev\\ai-dala\\BilimBaga\\backend\\internal\\certificates\\`.
  Per this stage's own "the Go code does not transfer" rule, only the
  BEHAVIOUR is ported: a fixed-order guard pipeline, then
  return-existing-if-already-issued, then a branding-snapshot capture and
  insert.

  ## Rule-2 justification -- flagged for REVIEWER, NOT self-adjudicated here

  REQ-355's own requirements.yaml entry states plainly that this module
  needs a per-entry rule-2 sign-off that the entry itself deliberately does
  NOT contain, because writing it is REVIEWER's job, not
  REQ-ANALYST's/ELIXIR-DEV's. The honest A/B question REVIEWER must answer:
  a certificate record is largely declarative and its issuance is close to
  an ordinary entity-record create, so "why is this not simply bucket A
  pack content plus the existing `Letflow.Entities.Records` write surface"
  is a real question with a real candidate answer, not a formality. This
  module's own candidate answer, for REVIEWER to weigh: the eligibility
  rule set below (session submitted, session passed -- itself a
  three-valued read that must not be collapsed with "not submitted", exam
  `certificate_enabled`) cannot be stated without naming exams and
  sessions (0022 rule 1), and the ordered-guard-then-idempotent-write
  sequence is a multi-step `with`-chain with no execution semantics an
  entity definition alone can express -- the same shape
  `Letflow.Modules.Exam.Session`'s own rule-2 table already established for this
  vertical. This module does NOT self-certify that answer as sufficient;
  it is recorded here only so REVIEWER's sign-off (to be written into
  `docs/migration/stage-10-bilimbaga-vertical.md`'s "## REVIEWER sign-off"
  section, per that section's own established precedent) has this
  module's own reasoning in view, not a blank page.

  ## Data lives in bucket A -- no migration, no Ecto schema here

  Every read and write goes through `Letflow.Entities.Records` (create) and
  `Letflow.Modules.Exam.Session.get_session_for_user/3` (session read, which already
  owns ownership/not-found semantics -- reused here rather than
  re-implemented) and `Letflow.Modules.Exam.Session.get_snapshot_for_user/3` (the exam facts, from
  the session snapshot; no live `exam` read since GH #2682).
  `certificate` (REQ-355) is the only entity type this module writes; extra
  reads are `Letflow.Identity`'s `users` table (candidate display name) and
  `Letflow.Identity.Tenant` (branding).

  ## Guard order (service.go's `GetOrCreate`, read top to bottom)

  1. Ownership, unless admin -- **admin bypass is NOT wired**: REQ-355's own
     scope fence is "an authenticated route by which a candidate requests
     issuance for their own session," not an admin route, so there is no
     caller today that could ever pass `is_admin: true`. Rather than carry
     an unreachable parameter no route calls, this function's ownership check is simply
     unconditional -- `Session.get_session_for_user/3`'s own
     `:not_owner`/`:session_not_found` pair, already indistinguishable per
     INV-5 (that function's own `@doc`/the session router's moduledoc).
     Adding an admin bypass is future work for whichever requirement
     authorizes an admin certificate route, not something to fake here.
  2. Session status is `:grading_pending` -> `{:error, :grading_pending}`,
     checked and returned BEFORE the generic "not submitted" guard and
     BEFORE the "not passed" guard -- see "grading_pending is not a passed=false"
     below for why this is its own guard with its own atom, not folded into
     either.
  3. Session status must be `:submitted` (not `:in_progress`,
     `:auto_submitted`, or -- per guard 2 above -- `:grading_pending`) ->
     `{:error, :session_not_submitted}` otherwise. Source AC-4.
  4. Exam must have `certificate_enabled: true` ->
     `{:error, :exam_not_certifiable}` otherwise. Source AC-2. GH #2682 / REQ-511: this fact (and
     the certificate title) is read ONLY from the session's own exam snapshot
     (`Session.get_snapshot_for_user/3` then `Snapshot.certificate_facts/1`), never from the
     live exam row, so an exam edited or deleted after the session started cannot change the
     certificate. A legacy submitted session without a snapshot gets certificate-only facts
     (`origin: "late_certificate"`, audited) once; a `{:grading_error, _}` or
     `{:snapshot_error, _}` from that read is returned as is.
  5. Session must have passed -> `{:error, :session_not_passed}` otherwise.
     Source AC-3. By this point `status == :submitted` is already
     established (guard 3), so `Session.get_session_for_user/3`'s own
     `passed_for_status/2` guarantees `passed` is a real `true`/`false`
     here, never `nil` -- guard 2 already intercepted the only status that
     produces `nil`.
  6. Return existing if already issued, else capture a branding snapshot
     and insert. Source AC-5/AC-9/AC-10 -- see "Idempotency" below.

  ## `grading_pending` is not a `passed: false` refusal -- REQ-355's own required distinction

  `lib/letflow/exam/scoring.ex:255-257` forces `status: :grading_pending`
  and `passed: nil` for any session containing a `:short_text` question.
  The source's own AC-3 collapses "passed = false" and "passed is null"
  into ONE `ErrNotPassed`/`SESSION_NOT_PASSED` refusal -- correct for the
  source, which has a manual short-text grading queue that could later
  resolve `nil` into `true`. Letflow has no such queue
  (`lib/letflow/routers/exam_sessions.ex`'s own scope fence says so
  plainly), so a `grading_pending` session here can NEVER later become
  `passed`. Collapsing the two would tell a candidate whose session is
  merely awaiting grading the same "you failed" message told to a
  candidate who genuinely scored below the passing threshold -- dishonest
  in a way the source's own design did not intend and could not have,
  since its queue makes the collapse temporary there and permanent here.
  `check_not_grading_pending/1` below is therefore its own guard, fired
  before the generic submitted-status guard, with its own `:grading_pending`
  atom -- distinct from both `:session_not_submitted` (an honest "not
  submitted yet, come back after you finish/submit") and
  `:session_not_passed` (an honest "you did not meet the passing score").
  `Letflow.Modules.Exam.Router`' certificate route renders three different
  messages for these three atoms; see that router's own render clause.

  ## Idempotency -- what the source expresses and what this module expresses instead

  Source: `session_id UUID NOT NULL UNIQUE REFERENCES exam_sessions(id)`
  plus `INSERT ... ON CONFLICT (session_id) DO NOTHING`, so two concurrent
  `GetOrCreate` calls for the same session race safely at the database and
  the loser's insert is silently absorbed, both callers ending up with the
  identical row.

  This document's own entity definition
  (`priv/packs/bilimbaga/entity_definitions/certificate.json`) deliberately
  declares NO `constraints` entry for `session_id`, even though
  `Letflow.Entities.Definition`'s `constraint_def` type could express a
  `:unique` constraint over `["session_id"]` -- because ISS-0648 wired
  `constraints` to trigger AUTOMATIC column promotion at definition
  activation (a real per-entity-type SQL table plus a real Postgres
  `UNIQUE` constraint on a promoted column, the mechanism
  `session_question`/`session_answer`/`session_question_score`'s own
  natural-key constraints already ride). That machinery is heavier than
  this record shape needs, and reaching for it here would silently
  pre-answer the very question this requirement's own flagged REVIEWER
  rule-2 sign-off exists to ask ("why is this not simply bucket A pack
  content plus the existing write surface").

  **What is actually used instead**: `issue_or_get_for_user/3` calls
  `Letflow.Entities.Records.create_record/2` with a DETERMINISTIC
  `idempotency_key` -- `"certificate:issue:" <> session_id` -- rather than
  the fresh `Ecto.UUID.generate()` every OTHER write in this vertical
  (`Letflow.Modules.Exam.Session`'s own `write_record/4`) uses for its one-time
  writes. `Letflow.EventStore`'s own idempotency mechanism
  (`claim_idempotency/3`, `lib/letflow/event_store.ex:641-691`) is a REAL,
  ALREADY-UNIQUE-INDEXED Postgres constraint (`uq_event_idempotency_key`
  on `event_idempotency`, `priv/repo/migrations/20260816120006_create_event_idempotency.exs`)
  that every entity-record write in this codebase already goes through --
  not a new mechanism authored for this requirement. Two concurrent (or
  sequential) `issue_or_get_for_user/3` calls for the SAME `session_id`
  derive the SAME idempotency key, so the second caller's insert attempt is
  caught by that real unique index (`on_conflict: :nothing, conflict_target:
  :idempotency_key`), and `Letflow.Entities.Records.create_record/2`'s own
  documented AC3 behaviour (`{:ok, %{record: ..., is_duplicate: true}}`,
  decoded from the ORIGINAL creating event's own stored payload, never a
  fresh `entity_record_latest` re-`SELECT`) hands back the identical
  original row both times, with no read-then-write race at any point --
  the DB uniqueness check and the row creation are the SAME atomic insert
  attempt, exactly like the source's `ON CONFLICT (session_id) DO NOTHING`.
  GH #2543: the second call's `field_values` differ (`issued_at`, live
  branding, candidate name), so it passes the internal-only
  `idempotency_match: :target` -- the key stays bound to the command, the
  `certificate` entity type and the candidate actor, but not to the values.

  **Guarantee level, stated precisely**: this is not literally
  `UNIQUE (session_id)` at the storage layer the way the source's column
  is -- two DIFFERENT idempotency keys could in principle collide with two
  DIFFERENT `session_id` values if this module's own key derivation were
  ever changed inconsistently, which a real `UNIQUE (session_id)` column
  could not permit even under a bug. What is guaranteed, unconditionally,
  by the real unique index on `idempotency_key`: for THIS module's own
  fixed `"certificate:issue:" <> session_id` derivation, at most one
  certificate row is ever created per `session_id`, atomically, under any
  concurrency -- the exact practical outcome the source's schema-level
  constraint exists to provide.

  ## Branding snapshot -- read once, stored forever (source AC-9)

  `capture_branding_snapshot/1` reads `lib/letflow/routers/tenant_config.ex`'s
  `branding_from_settings/1` (made `def`, was `defp`, by this requirement --
  see that module's own `@doc` on the function) against the tenant's live
  `Tenant.settings`, but ONLY inside `issue_or_get_for_user/3`'s create path
  -- i.e. only the FIRST time a certificate is issued for a session. Every
  subsequent call for the same session returns the idempotent-replay row
  (previous section) without ever calling `branding_from_settings/1` again,
  so a branding change made after issuance is invisible to an
  already-issued certificate's `branding_snapshot` field, matching the
  source's own `TemplateSnapshot` comment ("captures tenant branding at the
  time of first certificate issuance ... so later branding changes do not
  alter existing certificates"). REQ-595: the snapshot also carries
  `signatory_name` / `signatory_title` copied from the tenant settings, each
  only when set to a non-blank string; the snapshot is the sole source of the
  PDF signatory block afterwards. Proven by
  `test/letflow/exam/certificate_test.exs`'s branding-mutation test.

  ## Scope fence (REQ-355's own, restated here)

  This module does NOT render a PDF and does NOT encode a QR code
  (REQ-356) -- no `verification_code` field exists on this entity type at
  all. It issues (or re-fetches) one declarative record; nothing here
  reads or writes `mix.exs`.

  ## `first_issuance`/`public_read_resource_id` (REQ-357)

  `issue_or_fetch/4` now threads `Letflow.Entities.Records.create_record/2`'s
  own `is_duplicate` flag through as `first_issuance` (`not is_duplicate`)
  instead of discarding it, and `certificate_view/2` carries it plus
  `public_read_resource_id` (the record's own `id` -- the Ecto primary key,
  NOT `record_id`) so `Letflow.Modules.Exam.Router` can mint a
  `Letflow.PublicRead` handle exactly once per certificate, on first
  issuance only. Both fields are internal wiring, never part of the
  authenticated JSON response -- see
  `lib/letflow/design/req357-certificate-public-projection.md` §5.
  """

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Exam.Snapshot
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Routers.TenantConfig
  alias Letflow.TenantProvisioning

  # ISS-0676 -- exhaustiveness over this union is NOT compiler-enforced.
  # `Letflow.Modules.Exam.Router.render_issue_certificate/2` has one clause
  # per atom below, plus a catch-all clause (that router's own comment
  # above it explains why). Elixir's `@type` unions carry no case/function-
  # clause exhaustiveness check the way a real sum type would, and Dialyzer
  # does not fill that gap either -- confirmed by a real `mix dialyzer` run
  # during this issue's investigation: temporarily adding a 7th atom here
  # (with and without an explicit `@spec` on the router function naming
  # this type) produced ZERO new warnings, because the router's catch-all
  # clause widens the accepted type to `term()`, so Dialyzer's success
  # typing sees no contract violation to report. `Letflow.Modules.Exam.Session`'s
  # own `eligibility_error`/`autosave_error`/`submit_error` unions
  # (session.ex:129-146) are the same shape for the same reason -- REVIEWER
  # already accepted this as an established, non-blocking precedent for
  # this vertical.
  #
  # When adding a new atom to this union: (1) add a matching
  # `render_issue_certificate/2` clause in exam_sessions.ex, not just this
  # type, and (2) add a case to
  # `test/letflow/routers/exam_sessions_test.exs`'s "every issue_error atom
  # ... renders its own distinct response" test (ISS-0676) asserting the
  # new atom reaches its own clause rather than falling into the 500
  # catch-all. Neither step is compiler-checked; both are how this gap is
  # actually covered.
  @type issue_error ::
          :session_not_found
          | :not_owner
          | :grading_pending
          | :session_not_submitted
          | :exam_not_certifiable
          | :session_not_passed
          | Snapshot.grading_error()
          | {:snapshot_error,
             :definition_missing | :restrictions_missing | :audit_failed | :write_failed}

  @type certificate_view :: %{
          id: String.t(),
          session_id: String.t(),
          issued_at: DateTime.t(),
          candidate_name: String.t(),
          exam_title: term(),
          score_pct: float(),
          branding_snapshot: map(),
          first_issuance: boolean(),
          public_read_resource_id: String.t()
        }

  @doc """
  Issues a certificate for `session_id` on `candidate_id`'s behalf, or
  returns the already-issued one -- see this module's moduledoc for the
  full guard order and idempotency guarantee. `candidate_id` is always the
  AUTHENTICATED CALLER's own id (never a caller-supplied identity, matching
  every other `Letflow.Modules.Exam.Session`/`Letflow.Modules.Exam.AntiCheat` entry point
  in this vertical) -- ownership is enforced by delegating the session read
  itself to `Letflow.Modules.Exam.Session.get_session_for_user/3`.
  """
  @spec issue_or_get_for_user(
          candidate_id :: String.t(),
          session_id :: String.t(),
          prefix :: String.t()
        ) :: {:ok, certificate_view()} | {:error, issue_error() | term()}
  def issue_or_get_for_user(candidate_id, session_id, prefix)
      when is_binary(candidate_id) and is_binary(session_id) and is_binary(prefix) do
    with {:ok, session} <- Session.get_session_for_user(session_id, candidate_id, prefix),
         :ok <- check_not_grading_pending(session),
         :ok <- check_submitted(session),
         {:ok, snapshot} <- Session.get_snapshot_for_user(session_id, candidate_id, prefix),
         {:ok, facts} <- Snapshot.certificate_facts(snapshot),
         :ok <- check_certificate_enabled(facts),
         :ok <- check_passed(session),
         {:ok, record, first_issuance} <- issue_or_fetch(session, facts, candidate_id, prefix) do
      {:ok, certificate_view(record, first_issuance)}
    end
  end

  # -----------------------------------------------------------------------
  # Guards, in the exact order documented in the moduledoc.
  # -----------------------------------------------------------------------

  defp check_not_grading_pending(%{status: :grading_pending}), do: {:error, :grading_pending}
  defp check_not_grading_pending(_session), do: :ok

  defp check_submitted(%{status: :submitted}), do: :ok
  defp check_submitted(_session), do: {:error, :session_not_submitted}

  defp check_certificate_enabled(%{certificate_enabled: true}), do: :ok
  defp check_certificate_enabled(_facts), do: {:error, :exam_not_certifiable}

  defp check_passed(%{passed: true}), do: :ok
  defp check_passed(_session), do: {:error, :session_not_passed}

  # -----------------------------------------------------------------------
  # Issue-or-fetch (source AC-5/AC-9/AC-10) -- see moduledoc "Idempotency".
  # -----------------------------------------------------------------------

  defp issue_or_fetch(session, %{title: exam_title}, candidate_id, prefix) do
    with {:ok, candidate_name} <- fetch_candidate_name(candidate_id, prefix),
         {:ok, branding_snapshot} <- capture_branding_snapshot(prefix) do
      field_values = %{
        "session_id" => session.id,
        "issued_at" => iso8601(utc_now()),
        "candidate_name" => candidate_name,
        "exam_title" => exam_title,
        "score_pct" => to_float(session.score_pct || 0.0),
        "branding_snapshot" => branding_snapshot
      }

      # scope-all: SEC-518-R1 (exam module, own-record system path)
      case Records.create_record(
             %{
               entity_type: "certificate",
               field_values: field_values,
               actor_id: candidate_id,
               idempotency_key: "certificate:issue:" <> session.id,
               idempotency_match: :target
             },
             prefix,
             exam_owner()
           ) do
        {:ok, %{record: record, is_duplicate: is_duplicate}} ->
          {:ok, with_primary_key(record, prefix), not is_duplicate}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # REQ-592: an idempotent replay returns a record rebuilt from the original event, which
  # carries no Ecto primary key (`id`), yet `public_read_resource_id` must be that key on every
  # download. Re-read it from the tenant's own latest row (same prefix, keyed by the record id
  # the replay returned); a fresh insert already has it.
  defp with_primary_key(%{id: nil, record_id: record_id} = record, prefix) do
    case Repo.get_by(
           Letflow.Entities.Record.Latest,
           [record_id: record_id, entity_type: "certificate"],
           prefix: prefix
         ) do
      %{id: id} -> %{record | id: id}
      nil -> record
    end
  end

  defp with_primary_key(record, _prefix), do: record

  # GH #2596: the exam module's own Owner for the certificate write; built per call.
  @spec exam_owner() :: ManagedTypes.Owner.t()
  defp exam_owner, do: ManagedTypes.owner_for!(Exam)

  # The candidate's own display name at issuance time -- see moduledoc
  # "Branding snapshot" for why this and branding are both captured only on
  # the FIRST (create) path, never re-derived on the idempotent-replay path.
  # A missing user record is unreachable in practice (candidate_id is
  # always the authenticated caller's own id, resolved by
  # `Letflow.Plugs.AuthPipeline` from a real token belonging to a real
  # user row) -- folded into `:session_not_found` for the same reason
  # `fetch_exam/2` folds a dangling `exam_id` into it, rather than adding a
  # fourth error atom no acceptance criterion names.
  defp fetch_candidate_name(candidate_id, prefix) do
    case Identity.get_user(candidate_id, prefix: prefix) do
      {:ok, %{display_name: display_name}} -> {:ok, display_name}
      {:error, :not_found} -> {:error, :session_not_found}
    end
  end

  defp capture_branding_snapshot(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      settings =
        case Repo.get(Tenant, tenant_id) do
          %Tenant{settings: settings} -> settings
          nil -> nil
        end

      branding = TenantConfig.branding_from_settings(settings)

      {:ok,
       branding
       |> put_signatory(settings, "signatory_name")
       |> put_signatory(settings, "signatory_title")}
    end
  end

  # REQ-595: two explicit named reads (no wholesale copy of settings, INV-2).
  # A key is added only when the stored value is a non-blank string; nil,
  # null, blank and non-string values add nothing.
  defp put_signatory(branding, %{} = settings, key) do
    case Map.get(settings, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: branding, else: Map.put(branding, key, value)

      _ ->
        branding
    end
  end

  defp put_signatory(branding, _settings, _key), do: branding

  # -----------------------------------------------------------------------
  # View projection
  # -----------------------------------------------------------------------

  defp certificate_view(record, first_issuance) do
    %{
      id: record.record_id,
      session_id: fv(record, "session_id"),
      issued_at: parse_dt!(fv(record, "issued_at")),
      candidate_name: fv(record, "candidate_name"),
      exam_title: fv(record, "exam_title"),
      score_pct: to_float(fv(record, "score_pct")),
      branding_snapshot: fv(record, "branding_snapshot"),
      first_issuance: first_issuance,
      public_read_resource_id: record.id
    }
  end

  # -----------------------------------------------------------------------
  # Small helpers -- same idioms as `Letflow.Modules.Exam.Session`'s own private
  # helpers of the same name (no shared module extracted for two callers).
  # -----------------------------------------------------------------------

  defp fv(%{field_values: field_values}, key), do: Map.get(field_values, key)

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_dt!(value) when is_binary(value) do
    {:ok, dt, _offset} = DateTime.from_iso8601(value)
    dt
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
