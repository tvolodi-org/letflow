defmodule Letflow.Modules.Exam.AntiCheat do
  @moduledoc """
  REQ-333 -- anti-cheat signal capture and the `on_tab_switch` policy branch,
  the 4th and last bucket-C module `lib/letflow/exam/` is authorised to
  contain. Ported from `backend/internal/sessions/service.go`'s
  `ReportEvent` (FR-BB38, roadmap 3.8). Authorized by
  `lib/letflow/design/req330-exam-live-session.md` §7's rule-2 module table,
  `Letflow.Modules.Exam.AntiCheat` row -- read that document in full (§5 and §7) and
  decision `0030-exam-session-p3-bucket-verdicts.md` §"Finding 2" before
  changing this module's responsibilities.

  ## Rule-2 justification (verbatim from the design doc's table, REQ-330/0022 rule 2)

  **Why not A (a definition).** Validates one of exactly three signal types,
  checks session ownership/in-progress/deadline state, derives
  `action_taken` from the exam's `on_tab_switch` config (never from caller
  input), applies a per-session write-rate debounce, and branches
  `log`/`warn`/`submit` -- a live conditional with a side effect (in the
  `submit` branch, triggering `Letflow.Modules.Exam.Session.submit/3`), which an
  entity definition cannot express.

  **Why not B (a generic platform capability).** Stating this generically
  requires naming the signal vocabulary (`tab_switch`/`blur`/
  `fullscreen_exit`) and the terminal action (auto-submitting a session) --
  both vertical-specific per rule 1's own test; a generic
  "signal-triggered record transition" capability would be built for
  exactly one caller today, the speculative-generality failure mode `0022`
  exists to prevent.

  ## Storage shape -- REQ-330/decision 0030's own conclusion, quoted verbatim

  Decision `0030` §"Finding 2": **"Answer: entity-record events -- the
  `session_event` entity REQ-329 already defines, written through
  `Letflow.Entities.Records`, exactly like every other P3 storage table."**
  `record_signal/4` below writes and reads `session_event` rows only, via
  the ordinary `Letflow.Entities.Records`/`Letflow.Entities.Query` path
  (`Compiler`/`Latest`) -- no migration, no Ecto schema, no raw
  `Letflow.EventStore` call, no aggregate-counter table.

  ## NO per-session process or process-lookup table (REQ-045/decision 0022, non-negotiable)

  This module deliberately names none of the three forbidden mechanisms
  literally in its own source, so that a `grep` for them across
  `lib/letflow/exam/` (this requirement's own acceptance criterion) returns
  zero hits, including in prose -- not just zero real usages. This is a
  plain module with ordinary functions over `Letflow.Entities.Records`/
  `Letflow.Entities.Query`, exactly like `Letflow.Modules.Exam.Session`'s own
  "Process-vs-row decision" framing.

  ## `action_taken` is derived from config, never from the caller (service.go AC-10)

  `record_signal/4`'s parameter list has no `action_taken` argument at all --
  it is structurally impossible for a caller to supply one. The value
  actually written to the `session_event` row's `action_taken` field is
  always read fresh from the calling session's exam's `on_tab_switch`
  field, via an ordinary `Letflow.Entities.Query` read. This is the
  security-relevant property `session_event.json`'s own "ENFORCEMENT NOTE"
  flags as a REQ-333 obligation.

  ## Write-amplification mitigation (REQ-330's own scope, no other mitigation built)

  Before inserting a new `session_event` row, `record_signal/4` reads the
  calling session's most recent `session_event.occurred_at` (an ordinary
  `Letflow.Entities.Query` read, no new subsystem, no cache, no process) and
  rejects -- short-circuits without writing -- a signal arriving inside a
  configured debounce window. The window is read fresh on every call via
  `Application.get_env/3` (`config :letflow, :anti_cheat_debounce_seconds`),
  never cached, matching `Letflow.Scheduler.RecordDeadlineSweep`'s own
  config-reading convention for exactly the same reason (a deploy-time
  tunable, not a runtime capability). No other mitigation (rate limiting,
  aggregate counter, alternate storage shape) is built -- decision `0030`
  §"Finding 2" settles the storage shape and assigns this exact mitigation
  to this module.

  ## No HTTP route, no new permission atom

  This requirement produces the runtime function only -- nothing here is
  reachable from tenant-scoped request handling yet, so no permission atom
  is needed for it (same reasoning `Letflow.Scheduler.RecordDeadlineSweep`
  gives for its own config-only surface).
  """

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Session
  alias Letflow.Repo

  @type signal_type :: :tab_switch | :blur | :fullscreen_exit
  @type on_tab_switch_policy :: :log | :warn | :submit
  @type signal_error ::
          :session_not_found
          | :not_owner
          | :session_not_in_progress
          | :deadline_passed
          | :invalid_signal_type

  @type signal_outcome :: %{
          action_taken: on_tab_switch_policy(),
          event_count: non_neg_integer(),
          warning: boolean(),
          submission: Session.submission_outcome() | nil
        }

  @valid_signal_types ~w(tab_switch blur fullscreen_exit)a

  @default_debounce_seconds 5

  @doc """
  Records one anti-cheat signal for `session_id` on behalf of `user_id`
  (design §8, FR-BB38/roadmap 3.8). Guard order: signal-type validity,
  ownership, in-progress, server-side deadline. `action_taken` is always
  derived from the exam's `on_tab_switch` config -- there is no
  `action_taken` parameter here for a caller to supply one. A signal
  arriving inside the configured debounce window is silently absorbed
  (no new `session_event` row, `event_count` unchanged, no policy branch
  taken).
  """
  @spec record_signal(
          session_id :: String.t(),
          user_id :: String.t(),
          signal_type :: signal_type(),
          prefix :: String.t()
        ) :: {:ok, signal_outcome()} | {:error, signal_error() | term()}
  def record_signal(session_id, user_id, signal_type, prefix)
      when is_binary(session_id) and is_binary(user_id) and is_binary(prefix) do
    with :ok <- check_signal_type(signal_type),
         {:ok, session} <- fetch_session(session_id, prefix),
         :ok <- check_owner(session, user_id),
         :ok <- check_in_progress(session),
         :ok <- check_deadline(session),
         {:ok, action_taken} <- fetch_action_taken(session, prefix) do
      apply_signal(session, user_id, signal_type, action_taken, prefix)
    end
  end

  # =======================================================================
  # Guards
  # =======================================================================

  defp check_signal_type(signal_type) do
    if signal_type in @valid_signal_types do
      :ok
    else
      {:error, :invalid_signal_type}
    end
  end

  defp fetch_session(session_id, prefix) do
    case Latest.get(session_id, "session", prefix) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :session_not_found}
      {:error, :invalid_schema_name} = error -> error
    end
  end

  defp check_owner(session, user_id) do
    if fv(session, "user_id") == user_id, do: :ok, else: {:error, :not_owner}
  end

  defp check_in_progress(session) do
    if fv(session, "status") == "in_progress", do: :ok, else: {:error, :session_not_in_progress}
  end

  # Server-side deadline enforcement, identical idiom to
  # `Letflow.Modules.Exam.Session`'s own `check_deadline/1` -- compares
  # `DateTime.utc_now()` against the session's OWN STORED `expires_at`. No
  # client-supplied timestamp appears anywhere in this function.
  defp check_deadline(session) do
    if DateTime.compare(utc_now(), parse_dt!(fv(session, "expires_at"))) == :gt do
      {:error, :deadline_passed}
    else
      :ok
    end
  end

  # =======================================================================
  # action_taken derivation -- from the exam's on_tab_switch config, ALWAYS
  # =======================================================================

  defp fetch_action_taken(session, prefix) do
    case Latest.get(fv(session, "exam_id"), "exam", prefix) do
      {:ok, exam} -> {:ok, policy_atom(fv(exam, "on_tab_switch"))}
      {:error, :not_found} -> {:error, :session_not_found}
      {:error, :invalid_schema_name} = error -> error
    end
  end

  defp policy_atom("log"), do: :log
  defp policy_atom("warn"), do: :warn
  defp policy_atom("submit"), do: :submit

  # =======================================================================
  # Debounce + write + policy branch
  # =======================================================================

  defp apply_signal(session, user_id, signal_type, action_taken, prefix) do
    session_id = session.record_id

    with {:ok, existing_events} <- query_events(session_id, prefix) do
      case debounce_ok?(existing_events, utc_now()) do
        false ->
          {:ok,
           %{
             action_taken: action_taken,
             event_count: length(existing_events),
             warning: false,
             submission: nil
           }}

        true ->
          with {:ok, _record} <-
                 write_event(session_id, signal_type, action_taken, user_id, prefix) do
            branch_on_policy(
              action_taken,
              length(existing_events) + 1,
              session,
              user_id,
              prefix
            )
          end
      end
    end
  end

  # Private write-amplification mitigation (decision 0030 §"Finding 2",
  # design doc §8) -- not part of this module's public contract, so no
  # `@spec` here is load-bearing. Returns `false` (do not write) when the
  # most recent event for this session occurred less than
  # `:anti_cheat_debounce_seconds` ago; `true` (an empty event list counts
  # as "ok to write") otherwise.
  defp debounce_ok?([], _now), do: true

  defp debounce_ok?(existing_events, now) do
    most_recent =
      existing_events
      |> Enum.map(&parse_dt!(fv(&1, "occurred_at")))
      |> Enum.max(DateTime, fn -> nil end)

    DateTime.diff(now, most_recent, :second) >= debounce_seconds()
  end

  defp debounce_seconds do
    Application.get_env(:letflow, :anti_cheat_debounce_seconds, @default_debounce_seconds)
  end

  defp query_events(session_id, prefix) do
    # scope-all: SEC-518-R1
    with {:ok, query} <-
           Compiler.compile(
             %{entity_type: "session_event", filters: [eq("session_id", session_id)]},
             prefix,
             :all
           ) do
      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  defp write_event(session_id, signal_type, action_taken, actor_id, prefix) do
    Records.create_record(
      %{
        entity_type: "session_event",
        field_values: %{
          "session_id" => session_id,
          "occurred_at" => iso8601(utc_now()),
          "action_taken" => Atom.to_string(action_taken),
          "event_type" => Atom.to_string(signal_type)
        },
        actor_id: actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix,
      exam_owner()
    )
  end

  # GH #2596: the exam module's own Owner, passed to every `Records` write so the six runtime
  # types can be managed (`Exam.manifest().manages_entity_types`). Built per call, never stored.
  @spec exam_owner() :: ManagedTypes.Owner.t()
  defp exam_owner, do: ManagedTypes.owner_for!(Exam)

  defp branch_on_policy(:log, event_count, _session, _user_id, _prefix) do
    {:ok, %{action_taken: :log, event_count: event_count, warning: false, submission: nil}}
  end

  defp branch_on_policy(:warn, event_count, _session, _user_id, _prefix) do
    {:ok, %{action_taken: :warn, event_count: event_count, warning: true, submission: nil}}
  end

  defp branch_on_policy(:submit, event_count, session, user_id, prefix) do
    case Session.submit(session.record_id, user_id, prefix) do
      {:ok, outcome} ->
        {:ok,
         %{action_taken: :submit, event_count: event_count, warning: false, submission: outcome}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # =======================================================================
  # Shared plumbing (same idiom as `Letflow.Modules.Exam.Session`)
  # =======================================================================

  defp fv(%{field_values: field_values}, key), do: Map.get(field_values, key)

  defp eq(field, value), do: %{field: field, op: :eq, value: value}

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_dt!(value) when is_binary(value) do
    {:ok, dt, _offset} = DateTime.from_iso8601(value)
    dt
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
