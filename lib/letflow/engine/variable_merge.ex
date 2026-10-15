defmodule Letflow.Engine.VariableMerge do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Pure variable scoping and merge — ports `instance.zig`'s `mergeVariables()`
  (EE-09, `lib/letflow/design/req049-variable-merge.md`, the gate-approved
  design this module implements). `merge/3` merges an `incoming_variables`
  map produced by a completed task/service task into `current_variables`
  (the live `Letflow.Engine.InstanceState.variables`, REQ-044), per key:

    * A key absent from `current_variables` is inserted, no event, provided
      `variable_validations` has no `{:rejected, _}` outcome recorded for it.
    * A key already present is overwritten and produces one
      `{:variable_overwritten, key, old_value, new_value}` event, provided
      `variable_validations` has no `{:rejected, _}` outcome recorded for it
      (an absent entry, or an explicit `:ok`, both mean "no rejection").
    PROVENANCE (historical, not current decision authority):
    * **Every** incoming key is checked against `variable_validations`, new or
      overwrite alike (`docs/migration/decisions/0007-variable-merge-validates-new-keys.md`,
      GH#300/ISS-0077) — collision (new vs. overwrite) only decides whether a
      passing key's application emits a `VARIABLE_OVERWRITTEN` event, never
      whether it is validated. The first key (in sorted order) whose
      `variable_validations` entry is `{:rejected, failures}` aborts the
      **entire** batch: nothing from this call is merged (not even
      otherwise-unproblematic inserts of other keys), and `merge/3` returns
      `{:rejected, current_variables, [execution_error_event]}` instead
      (design doc §3.2 — **verified against
      `instance.zig`'s literal source** by REQ-109, which read the R-Co tree
      directly: `mergeVariables`'s own doc comment at
      `src/engine/instance.zig:2300-2304` documents the ISS-202 two-phase
      merge — "Phase 1: Validate ALL output variables … with NO state change.
      On any failure, return early with violation. Phase 2: Apply all
      validated keys … only if Phase 1 succeeds. On failure, leave variables
      untouched." — confirmed by the code beneath it (`:2395` "Phase 1
      succeeded", `:2470` `PHASE 2: APPLICATION`). This was previously
      qualified as an unverified reconstruction on the grounds that no R-Co
      source tree was reachable; the tree **is** reachable and the
      reconstruction was correct. Closes ISS-0075 / GH#296 claim 2).
    * An empty `incoming_variables` map is a no-op: zero events, the same
      `current_variables` value returned unchanged (design doc §9).

  `merge/3` never runs schema validation itself — `variable_validations` is
  a map of **already-computed** per-key outcomes the caller resolves (design
  doc §2, §7) before invoking `merge/3`, **not a second JSON Schema
  implementation.** That substance is unchanged; what resolves the outcomes
  changed with REQ-109. The caller is now
  `Letflow.Engine.VariableSchema.variable_validations/5`
  (`lib/letflow/design/req109-variable-schemas.md` §4.3), which looks the
  per-key schema up in the tenant-scoped `variable_schemas` table and calls
  `Letflow.EventStore.Registry.JsonSchema.validate/2` **directly** rather than
  going through REQ-024's `Letflow.EventStore.Registry.validate_payload/3`.
  Still no second implementation: `JsonSchema.validate/2` **is**
  `validate_payload/3`'s own internal pure delegate
  (`lib/letflow/event_store/registry.ex:147`). `validate_payload/3` itself is
  bypassed because it is bound to `get_type/2` → `event_type_registry`, and
  REQ-109 resolved variable-schema storage as a dedicated table instead. This
  is what keeps `merge/3` itself pure and testable without a database.

  ## Dependency ordering: this module does not depend on REQ-061

  AC3 describes a rejected variable value as transitioning the instance to
  ERROR "via REQ-061's EE-10 path." **At the time this module was
  implemented,** REQ-061 (EE-10, execution error handling) was `status:
  pending` and unimplemented — this module's own `depends_on` is
  [REQ-044, REQ-024], not REQ-061. REQ-061 has since shipped (`done`), and
  REQ-109 wired the caller so that its ERROR path was reachable through
  `Letflow.Engine.complete_task/3`. **Amended by REQ-459 / REQ-460 (2026-10):**
  on a HUMAN_TASK completion the engine now checks the same validations itself
  and refuses a rejected output with a retryable 422 before anything is written,
  so that ERROR path is no longer taken from `complete_task/3`; it remains for the
  SUB_PROCESS completion merge (REQ-062) and other engine-internal callers.
  `merge/3` and its whole-batch semantics are unchanged. **None of that changes
  this module, and the reasoning below is exactly why** (ISS-0075 / GH#296
  claim 1).
  `merge/3` is pure (see the purity section below): it never calls,
  aliases, or references any REQ-061 module. A rejected batch is signalled
  purely through `merge/3`'s own return value -- the `{:rejected,
  unchanged_variables, [execution_error_event]}` tuple -- which the caller
  (not this module) inspects and acts on, including invoking whichever
  REQ-061 function eventually performs the actual ERROR transition.
  `Letflow.Engine.InstanceState.status` already includes `:error` in its
  existing 4-atom union (REQ-044), so REQ-061 has a pre-existing target value
  to transition into; this module does not anticipate REQ-061's own API
  beyond that already-shipped atom.

  ## Purity

  `Letflow.Engine.VariableMerge` depends on Elixir/Erlang stdlib only
  (`Map`, `Enum`, `Kernel`) plus `Letflow.EventStore.Registry.ValidationFailure`
  (a plain, non-`Ecto`, never-persisted struct, REQ-024) referenced purely
  for its `@type t` shape in `execution_error_event()`/`validation_outcome()`
  — never invoked as a function call. No `alias Letflow.Repo`, no `import
  Ecto.Query`, no `Ecto.Changeset`, no call to
  `Letflow.EventStore.Registry.validate_payload/3` or `.get_type/2` (both
  perform `Repo` I/O) anywhere in this module.

  Verification (grep-checkable; **ISS-0080 / GH#301 fix, 2026-08-20** — the
  prior recipe here grepped the whole file including this moduledoc's own
  prose, which necessarily *names* the functions it promises never to
  *call* and so registered false positives against itself, including its
  own recipe line. This recipe strips every `\"""`-delimited doc block (the
  `@moduledoc` and every `@typedoc` in this file) before grepping, so it
  checks call sites in the actual code, not mentions in documentation of
  what the caller does):

  ```bash
  awk '/\"""/{f=!f; next} !f' lib/letflow/engine/variable_merge.ex \
    | grep -n "Repo\\.\\|Logger\\.\\|DateTime\\.\\|System\\.os_time\\|System\\.system_time\\|HTTPoison\\|Req\\.\\|File\\.\\|:rand\\.\\|:crypto\\.\\|Registry\\.validate_payload\\|Registry\\.get_type\\|Registry\\.register_type"
  ```

  must return zero matches — and does, verified this run. The real invariant
  is the prose above it: no `Repo` I/O, no `alias Letflow.Repo`, no `import
  Ecto.Query`, no `Ecto.Changeset`, no invocation of
  `validate_payload/3`/`get_type/2`/`register_type/2`, no clock, no
  `:rand`/`:crypto` — verified by reading this module's `alias`/`import`
  list and its function bodies. Deliberately NOT fixed by deleting or
  rewording the prose that mentions those names (REQ-049 AC4's evidence
  artifact and REQ-109's caller-paragraph both live in that prose) — doing
  that would satisfy a gate by editing what it measures instead of fixing
  the recipe, exactly what ISS-0080 flagged as the risk of touching this
  moduledoc carelessly.

  ## Reserved `_sys` namespace (decision 0054 D1a, GH #2587)

  The top-level key `"_sys"` and every top-level key beginning `"_sys."` are
  reserved for values the engine itself writes (decision 0054 D1a: minted
  record ids and their `event_global_seq` after a process-step entity write).
  The reserved set is compared on the string form of a TOP-LEVEL key (an atom
  key via `Atom.to_string/1`); a nested key is never reserved.

    * `merge/3` checks reserved keys FIRST, before any `variable_validations`
      outcome is consulted, and refuses the whole batch with
      `{:rejected, current_variables, [{:execution_error, key, nil,
      :reserved_variable_key, []}]}` for the first reserved key in sorted
      order. The rejected value is never carried (`nil`), so an
      attacker-supplied value never reaches an error event, detail or log.
    * `put_sys/3` is the ONLY function that sets a reserved key. Its callers
      are a reviewed static allow-list
      (`test/letflow/engine/put_sys_callers_test.exs`); it must never receive
      request, form, HTTP response, start-input, message or script data.
    * `reserved_key?/1`, `reserved_keys/1`, `drop_reserved/1`, `sys_key?/1`,
      `sys_value?/1` and `sys_event_type/0` are how every other module reaches
      the namespace: no other file in `lib/` holds a binary literal starting
      with the reserved prefix (same static test).

  ## Determinism

  Calling `merge(current_variables, incoming_variables, variable_validations)`
  twice with `==`-equal arguments returns `==`-equal results, both times.
  `all_keys` is sorted (`Enum.sort/1`, ordinary Erlang term order on
  binaries) purely for determinism — event list order and which key wins a
  first-failure race never depend on map iteration order. No clock read, no
  `:rand`/`:crypto` call, no UUID generation anywhere in `merge/3`'s call
  graph.
  """

  alias Letflow.EventStore.Registry.ValidationFailure

  @typedoc """
  One `VARIABLE_OVERWRITTEN` outcome — emitted once per key in
  `overwrite_keys` that passed validation, never for a `new_keys` insert.
  """
  @type merge_event ::
          {:variable_overwritten, key :: String.t(), old_value :: term(), new_value :: term()}

  @typedoc """
  One `EXECUTION_ERROR` outcome — emitted for the first (sorted-order) key,
  new or overwrite, whose `variable_validations` entry is `{:rejected,
  failures}` (`docs/migration/decisions/0007-variable-merge-validates-new-keys.md`,
  GH#300/ISS-0077). `reason` is a fixed atom identifying this as EE-09's own
  contribution to what will become EE-10's (REQ-061) full `EXECUTION_ERROR`
  reason taxonomy — deliberately not a closed enumeration declared by this
  module.
  """
  @type execution_error_event ::
          {:execution_error, key :: String.t(), rejected_value :: term(),
           reason :: :variable_schema_rejected, failures :: [ValidationFailure.t()]}
          | {:execution_error, key :: String.t(), rejected_value :: nil,
             reason :: :reserved_variable_key, failures :: []}

  @typedoc """
  A key `put_sys/3` accepts: the reserved prefix followed by one or more
  dot-separated `[A-Za-z0-9_]+` segments, at most 160 bytes in total.
  """
  @type sys_key :: String.t()

  @typedoc "A value `put_sys/3` accepts: a minted record id or an `event_global_seq`."
  @type sys_value :: String.t() | non_neg_integer()

  @typedoc """
  The already-computed validation outcome for one incoming key's value,
  new or overwrite alike. `:ok` covers both "an explicit `:ok` outcome" and "no
  schema registered for this key" (an absent entry defaults to `:ok`, §3.1
  step 3). `merge/3` never runs a validator itself — this outcome is
  resolved by the caller, which since REQ-109 is
  `Letflow.Engine.VariableSchema.variable_validations/5`, wrapping a call to
  `Letflow.EventStore.Registry.JsonSchema.validate/2` (REQ-024's own pure
  delegate) rather than to `Letflow.EventStore.Registry.validate_payload/3`.
  See the moduledoc's caller paragraph for why.
  """
  @type validation_outcome :: :ok | {:rejected, failures :: [ValidationFailure.t()]}

  @typedoc """
  Per-key precomputed validation outcomes for **every** key in this call's
  `incoming_variables` — new keys and overwrite keys alike
  (`docs/migration/decisions/0007-variable-merge-validates-new-keys.md`,
  GH#300/ISS-0077; before that fix, only overwrite candidates were looked up
  here). `nil` and `%{}` are equivalent: every key defaults to `:ok`, so a key
  with no registered schema is unaffected either way.
  """
  @type variable_validations :: %{optional(String.t()) => validation_outcome()}

  @typedoc """
  `merge/3`'s return shape follows `Letflow.Definitions.Graph.validate_graph/1`'s
  "legitimate output value, not a function failure" convention, not the
  ordinary `{:ok, _} | {:error, _}` convention `Letflow.Engine.Transition`
  uses — a schema-rejected variable value is an expected business outcome,
  not a violation of `merge/3`'s own calling contract.
  """
  @type merge_result ::
          {:ok, new_variables :: map(), events :: [merge_event()]}
          | {:rejected, unchanged_variables :: map(), events :: [execution_error_event()]}

  @reserved "_sys"
  @reserved_prefix "_sys."
  @sys_key_max_bytes 160
  @sys_name_pattern ~r/\A[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*\z/
  @sys_event_type "INSTANCE_SYS_VARIABLES_SET"

  @doc """
  Merges `incoming_variables` into `current_variables`, per key. See the
  moduledoc for the full behavior; design doc §3.1 for the algorithm this
  implements step by step:

    0. (GH #2587) Any top-level reserved key in `incoming_variables`
       (`reserved_keys/1` non-empty) refuses the whole batch with
       `{:rejected, current_variables, [{:execution_error, key, nil,
       :reserved_variable_key, []}]}`, `key` the first reserved key in sorted
       order; no validation outcome is consulted and no key is applied.
    1. `all_keys` = `Map.keys(incoming_variables)`, sorted (determinism only).
    2. Partition into `new_keys` (absent from `current_variables`) and
       `overwrite_keys` (present) — used only to decide event emission in
       step 4, not which keys get validated in step 3.
    3. Scan **`all_keys`** in sorted order for the first key whose
       `variable_validations` entry is `{:rejected, failures}` — new and
       overwrite keys alike (`docs/migration/decisions/0007-variable-merge-validates-new-keys.md`,
       GH#300/ISS-0077).
    4. No rejection found -> apply every insert and overwrite (inserts produce
       no event, overwrites produce a `VARIABLE_OVERWRITTEN` event each),
       return `{:ok, new_variables, overwritten_events}`.
    5. Rejection found on key `K` -> return `{:rejected, current_variables,
       [execution_error_event]}`, `current_variables` returned unchanged
       (not even otherwise-unproblematic `new_keys` inserts are applied).

  Never raises. `variable_validations` may be `nil` (equivalent to `%{}`).
  """
  @spec merge(
          current_variables :: map(),
          incoming_variables :: map(),
          variable_validations :: variable_validations() | nil
        ) :: merge_result()
  def merge(current_variables, incoming_variables, variable_validations) do
    case reserved_keys(incoming_variables) do
      [] -> merge_unreserved(current_variables, incoming_variables, variable_validations)
      [key | _] -> {:rejected, current_variables, [reserved_rejection(key)]}
    end
  end

  defp reserved_rejection(key), do: {:execution_error, key, nil, :reserved_variable_key, []}

  defp merge_unreserved(current_variables, incoming_variables, variable_validations) do
    validations = variable_validations || %{}
    all_keys = incoming_variables |> Map.keys() |> Enum.sort()

    {new_keys, overwrite_keys} =
      Enum.split_with(all_keys, fn key -> not Map.has_key?(current_variables, key) end)

    case find_rejection(all_keys, validations) do
      {key, failures} ->
        rejected_value = Map.fetch!(incoming_variables, key)
        event = {:execution_error, key, rejected_value, :variable_schema_rejected, failures}
        {:rejected, current_variables, [event]}

      nil ->
        variables_with_inserts =
          Enum.reduce(new_keys, current_variables, fn key, vars ->
            Map.put(vars, key, Map.fetch!(incoming_variables, key))
          end)

        {new_variables, events_reversed} =
          Enum.reduce(overwrite_keys, {variables_with_inserts, []}, fn key, {vars, events} ->
            old_value = Map.get(current_variables, key)
            new_value = Map.fetch!(incoming_variables, key)
            event = {:variable_overwritten, key, old_value, new_value}
            {Map.put(vars, key, new_value), [event | events]}
          end)

        {:ok, new_variables, Enum.reverse(events_reversed)}
    end
  end

  @doc """
  Whether `key` is reserved: the string form of a binary or atom key is
  exactly the reserved name or starts with the reserved prefix (name plus a
  dot). `false` for any other term (an integer key, a tuple, ...).
  """
  @spec reserved_key?(term()) :: boolean()
  def reserved_key?(key) when is_binary(key),
    do: key == @reserved or String.starts_with?(key, @reserved_prefix)

  def reserved_key?(key) when is_atom(key), do: reserved_key?(Atom.to_string(key))
  def reserved_key?(_key), do: false

  @doc """
  The TOP-LEVEL reserved keys of `variables`, as strings, sorted ascending;
  `[]` when there are none. Pure.
  """
  @spec reserved_keys(map()) :: [String.t()]
  def reserved_keys(variables) when is_map(variables) do
    variables
    |> Map.keys()
    |> Enum.filter(&reserved_key?/1)
    |> Enum.map(&key_string/1)
    |> Enum.sort()
  end

  @doc """
  `variables` without its top-level reserved keys. Pure. Nested keys are
  never touched.
  """
  @spec drop_reserved(map()) :: map()
  def drop_reserved(variables) when is_map(variables),
    do: Map.reject(variables, fn {key, _value} -> reserved_key?(key) end)

  @doc """
  Whether `key` is a `t:sys_key/0`: a binary of at most 160 bytes made of the
  reserved prefix and one or more dot-separated `[A-Za-z0-9_]+` segments. The
  bare reserved name is NOT a `sys_key`. Never raises, for any term.
  """
  @spec sys_key?(term()) :: boolean()
  def sys_key?(<<@reserved_prefix, name::binary>> = key)
      when byte_size(key) <= @sys_key_max_bytes,
      do: Regex.match?(@sys_name_pattern, name)

  def sys_key?(_key), do: false

  @doc """
  Whether `value` is a `t:sys_value/0` (a binary or a non-negative integer).
  Never raises, for any term.
  """
  @spec sys_value?(term()) :: boolean()
  def sys_value?(value) when is_binary(value), do: true
  def sys_value?(value) when is_integer(value) and value >= 0, do: true
  def sys_value?(_value), do: false

  @doc """
  Sets the reserved `key` to `value` in `variables`. The ONLY function that
  writes a reserved key (decision 0054 D1a.3); its callers are a reviewed
  static allow-list (`test/letflow/engine/put_sys_callers_test.exs`).

  It must never receive request, form, HTTP response, start-input, message or
  script data: its inputs are engine-minted record ids and `event_global_seq`
  integers only (on replay, read back from an engine-appended event of type
  `sys_event_type/0`).

  Raises `FunctionClauseError` when `key` is not a `t:sys_key/0` (the bare
  reserved name included) or `value` is not a `t:sys_value/0`: a programmer
  error in allow-listed engine code, never reachable from external input.
  """
  @spec put_sys(map(), sys_key(), sys_value()) :: map()
  def put_sys(variables, key, value) when is_map(variables) do
    if sys_key?(key) and sys_value?(value) do
      Map.put(variables, key, value)
    else
      raise FunctionClauseError, module: __MODULE__, function: :put_sys, arity: 3
    end
  end

  @doc """
  The event type of the engine-only event recording `put_sys/3` writes
  (decision 0054 D1, GH #2587), folded on replay by
  `Letflow.Engine.Reconstruction` through `put_sys/3`.
  """
  @spec sys_event_type() :: String.t()
  def sys_event_type, do: @sys_event_type

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)

  @spec find_rejection([String.t()], variable_validations()) ::
          {String.t(), [ValidationFailure.t()]} | nil
  defp find_rejection(keys, validations) do
    Enum.find_value(keys, fn key ->
      case Map.get(validations, key, :ok) do
        :ok -> nil
        {:rejected, failures} -> {key, failures}
      end
    end)
  end
end
