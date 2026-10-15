defmodule Letflow.Engine.EntityPort do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (decision 0054 D2 and open point 8): the ONE engine-defined port
  through which the engine reaches entity records. It subsumes the 0053 `ScriptReadPort`
  (GH 2534 PR 7c-2): one behaviour, one injected implementation
  (see the `:entity_port` config key), one config key, one
  `mix letflow.check_boundaries` allowance. Design
  `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 4.

  The engine owns this behaviour; the entity-record implementation lives outside the engine and
  is selected at run time from the `config :letflow, :entity_port` value (set in
  `config/config.exs`) through `impl/0`, the single reader of that key, so no engine file names
  an entity module. `mix letflow.check_boundaries` Rule 6 enforces that on direct file edges.

  ## Read half (0053 D5)

  The dispatcher calls `prefetch/3` only when the manifest's `reads` is non-empty, after the
  kill switch, tenant, version, manifest backstops (closed output schema, restricted opt-in
  refusal, `Letflow.Scripts.Policy.check_reads/2`) and the HMAC key, and before admission.

  Contract for an implementation. These are guarantees the port gives ON ITS OWN: they hold
  whether or not the caller ran `check_reads` first (the dispatcher does; a future caller might
  not), and they are re-evaluated against the tenant's CURRENT state on every call:

    * Phase 1, for EVERY read, before any record query: the type is STILL flagged readable
      (closing the window between the caller's `check_reads` and this call); the type has an
      active definition and no type restriction; every `fields` and `match.field` name is a field of it;
      `restricted_fields` is absent or empty (hook 1 has no opt-in, C10); a `match.field` that
      is restricted NOW is refused (SEC N1). Any failure is `{:error, :reads_not_allowed}`.
    * Phase 2: exactly ONE record query per read, whether it hits or misses (no existence
      oracle); at most `limit` (<= 50) rows; a field restricted NOW is omitted from every row.
      A record query the database refuses (a stored value that does not fit its field's cast)
      refuses the whole call with `{:error, :reads_not_allowed}`; it never raises.
    * The tenant prefix is the caller's run-context prefix, never derived from manifest text.
    * Nothing survives a call: no cache across runs.

  ## Write half (0054 D2)

  `prepare/2`, `validate_lines/2` and `multi/3` carry the process-step entity writes. In PR A3
  only `prepare/2` is real; the other two fail closed on a non-empty line list (PR B replaces
  them). Nothing in the engine calls the write half yet. Script paths (the dispatcher and
  `Letflow.Scripts.*`) call `prefetch/3` ONLY, and a static test asserts it.
  """

  @typedoc """
  One declared read (a validated manifest entry). `restricted_fields` is always empty here:
  the restricted opt-in is refused before the port is called (C10).
  """
  @type read_spec :: %{required(String.t()) => term()}

  @typedoc "One delivered row: the record id under `\"id\"` plus the declared, unredacted fields."
  @type row :: %{required(String.t()) => term()}

  @doc """
  Pre-fetches every read in `reads` from the tenant schema `prefix`, taking match values from
  `input_vars` (the script's declared input variables). Returns every read name, a miss as
  `[]`, or `{:error, :reads_not_allowed}` before any record query.
  """
  @callback prefetch(prefix :: String.t(), reads :: [read_spec()], input_vars :: map()) ::
              {:ok, %{optional(String.t()) => [row()]}} | {:error, :reads_not_allowed}

  @typedoc "One declared `entity_writes` line (string-keyed, as pinned); PR B fixes its keys."
  @type line :: %{required(String.t()) => term()}

  @typedoc "One refused line: its declared index and a stable atom code (never a field value)."
  @type line_violation :: %{index: non_neg_integer(), code: atom()}

  @typedoc "Context for `prepare/2`: the tenant schema prefix from the caller's server context."
  @type prepare_ctx :: %{required(:prefix) => String.t()}

  @typedoc "Context for `validate_lines/2`; PR B extends it."
  @type definition_ctx :: %{required(:prefix) => String.t(), optional(atom()) => term()}

  @typedoc "Context for `multi/3`; PR B extends it."
  @type multi_ctx :: %{required(:prefix) => String.t(), optional(atom()) => term()}

  @event_type "TASK_ENTITY_WRITES_APPLIED"

  @doc """
  Runs, BEFORE the completion transaction, the short bounded transaction that creates the
  synthetic per-type instances the lines will write to (0054 D3 step 0). Never runs inside a
  caller's transaction.
  """
  @callback prepare(lines :: [line()], prepare_ctx()) ::
              :ok
              | {:error, :entity_write_contention}
              | {:error, :prepare_inside_transaction}
              | {:error, {:entity_type_prepare_failed, String.t()}}

  @doc "Validates declared lines against the current definitions. PR A: fail closed."
  @callback validate_lines(lines :: [line()], definition_ctx()) ::
              :ok | {:error, [line_violation()]}

  @doc "Adds the per-line write steps to the Multi. PR A: fail closed."
  @callback multi(Ecto.Multi.t(), lines :: [line()], multi_ctx()) :: Ecto.Multi.t()

  @doc """
  The injected implementation module, read from `config :letflow, :entity_port`. The single
  reader of that key (D-A3.7).
  """
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:letflow, :entity_port)

  @doc "The instance event type PR B/C append once a step's entity writes committed."
  @spec applied_event_type() :: String.t()
  def applied_event_type, do: @event_type
end
