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

  `prepare/2`, `validate_lines/2`, `multi/3` and `interpret_failure/2` carry the
  process-step entity writes. `prepare/2` is real (PR A3); `validate_lines/2` is real from PR
  B1 (activation-time validation; it never writes); `multi/3` and `interpret_failure/2` are
  real from PR B2, called by the HUMAN_TASK completion transaction (`Letflow.Engine`) and, from
  PR C2, by the SERVICE_TASK apply transaction (HTTP and script routes; open for new
  definitions since the C1 fence lift).
  `Letflow.Definitions` calls `validate_lines/2` at the three activation paths. Script paths
  (the dispatcher and `Letflow.Scripts.*`) call `prefetch/3` ONLY, and a static test asserts
  it.
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

  @typedoc "One declared `module_writes` line (string-keyed, as pinned; GH #2590 R4b)."
  @type module_write_line :: %{required(String.t()) => term()}

  @typedoc """
  The module ownership stamp of the definition row a completion's plan read: opaque strings the
  engine carries without naming a module (GH #2590 R4b, design 4.5).
  """
  @type owner_stamp :: %{
          required(:module_id) => String.t(),
          required(:module_version) => String.t(),
          required(:manifest_hash) => String.t(),
          required(:body_hash) => String.t()
        }

  @typedoc "One refused line: its declared index and a stable atom code (never a field value)."
  @type line_violation :: %{index: non_neg_integer(), code: atom()}

  @typedoc "Context for `prepare/2`: the tenant schema prefix from the caller's server context."
  @type prepare_ctx :: %{
          required(:prefix) => String.t(),
          optional(:module_writes) => [module_write_line()]
        }

  @typedoc """
  The activator authority recorded at activation (GH #2587 PR B1, decision 0054 D4a): the
  principal whose delegated privilege a definition's `entity_writes` run under. Built from
  the server-side `auth_context` by `Letflow.Definitions.Activator.from_auth_context/2`.
  """
  @type activator :: %{
          required(:user_id) => Ecto.UUID.t(),
          required(:roles) => [String.t()],
          required(:entities_records_write?) => boolean(),
          required(:permissions) => [String.t()]
        }

  @typedoc """
  Context for `validate_lines/2` (PR B1): the tenant schema prefix and the node being
  validated. `graph_output_vars` lists the `output_record_id_var` names declared by lines of
  OTHER nodes of the same graph (uniqueness across the graph).
  """
  @type definition_ctx :: %{
          required(:prefix) => String.t(),
          optional(:node_id) => String.t(),
          optional(:node_type) => :HUMAN_TASK | :SERVICE_TASK,
          optional(:graph_output_vars) => [String.t()],
          optional(atom()) => term()
        }

  @typedoc "Who caused a step write (PR C2): a human task or a service/script dispatch row."
  @type origin :: {:task, Ecto.UUID.t()} | {:dispatch, Ecto.UUID.t()}

  @typedoc """
  Context for `multi/3` (PR B2). `variables` and `skip?` are closures over the transaction's
  accumulated changes, so the entity side never learns the engine's step names: `variables`
  returns the merged instance variables after the engine's merge, `skip?` is true when the
  merge or transition ended in an execution error (nothing is written then). `now_fun` is a
  monotonic-millisecond test seam for the 10 s wall-clock guard. PR C2: `actor_id` is the event actor
  (the completer; the platform sentinel on the service origin), `subject_id` the write-side
  field-restriction subject (defaults to `actor_id`; the activator on the service origin).
  """
  @type multi_ctx :: %{
          required(:prefix) => String.t(),
          # GH #2687: the tagged origin of the step is required; it replaces the former
          # `task_id` / `dispatch_id` pair, so "exactly one of the two" cannot be violated.
          required(:origin) => origin(),
          optional(:subject_id) => Ecto.UUID.t(),
          optional(:guard_budget_ms) => non_neg_integer(),
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:definition_id) => Ecto.UUID.t(),
          required(:definition_version) => String.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:activator_id) => Ecto.UUID.t(),
          required(:authorized) => [{String.t(), String.t()}],
          required(:variables) => (map() -> map()),
          required(:skip?) => (map() -> boolean()),
          optional(:now_fun) => (-> integer()),
          optional(:module_writes) => [module_write_line()],
          optional(:owner) => owner_stamp() | nil,
          optional(:entity_write_count) => non_neg_integer()
        }

  @typedoc "One applied line: ids and sequences only (INV-2)."
  @type applied_line :: %{
          required(:line_index) => non_neg_integer(),
          required(:entity_type) => String.t(),
          required(:record_id) => Ecto.UUID.t(),
          required(:event_global_seq) => non_neg_integer(),
          optional(:output_var) => String.t() | nil,
          optional(:handler_module) => String.t(),
          optional(:handler_name) => String.t(),
          optional(:write_ordinal) => pos_integer()
        }

  @typedoc "The value of the `:entity_writes` step `multi/3` ends with."
  @type entity_writes_result ::
          :skipped
          | %{
              required(:applied) => [applied_line()],
              required(:lines_hash) => String.t(),
              required(:sys_values) => %{optional(String.t()) => String.t() | non_neg_integer()}
            }

  @typedoc """
  The outcome of a failed line step: a refusal (`detail` is a closed atom for the tenant
  audit entry only), an internal fault, or "not a line step".
  """
  @type failure ::
          {:refused, non_neg_integer(), refusal_code(), detail :: atom()}
          | {:failed, non_neg_integer(), step :: atom()}
          | :not_a_line_failure

  @type refusal_code ::
          :write_not_permitted
          | :validation_failed
          | :entity_append_only
          | :idempotency_conflict
          | :record_version_conflict
          | :entity_type_inactive
          | :entity_write_contention

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

  @doc """
  GH #2590 R4b, run time and pre-transaction (INV-3): authorizes a node's `module_writes` lines
  against the stamp of the definition row, the tenant's CURRENT install state and the PINNED
  snapshot, before `prepare/2` and every entity lock. `{:error, {declared_index, detail}}` is a
  refusal; `detail` is a closed atom for the tenant audit entry only (the public code is one
  `write_not_permitted`). Reads only, no lock.
  """
  @callback authorize_module_writes([module_write_line()], %{
              required(:prefix) => String.t(),
              required(:snapshot_graph) => map(),
              optional(:owner) => owner_stamp() | nil,
              optional(:entity_write_count) => non_neg_integer()
            }) ::
              :ok | {:error, {index :: non_neg_integer(), detail :: atom()}}

  @doc """
  Validates declared lines against the current definitions (PR B1). Reports every violation,
  sorted by `{index, code}`; never writes, never takes a lock.
  """
  @callback validate_lines(lines :: [line()], definition_ctx()) ::
              :ok | {:error, [line_violation()]}

  @doc """
  Adds the per-line write steps to the Multi and ENDS with the named step `:entity_writes`
  whose value is `entity_writes_result()`. With no lines it returns the Multi unchanged.
  """
  @callback multi(Ecto.Multi.t(), lines :: [line()], multi_ctx()) :: Ecto.Multi.t()

  @doc """
  GH #2704 (decision 0061 rules 3 and 4), OPTIONAL: appends to the Multi a group of lock-only
  `{:pre_type_lock, entity_type}` steps, one per type in the ASCENDING union of the declared line
  types and the registered target types of the `module_writes` handlers (types without a synthetic
  instance are skipped), each taking the type's `instance_sequences` row. The service apply calls
  it right after its ancestor-group lock and BEFORE its task activation (the first audit chain row),
  so the entity-type rows precede the audit chain row on both child kinds. It writes nothing and
  reads no record data; the later per-line lock steps then re-lock the same rows.

  Optional so that test doubles of this behaviour keep compiling (`lock_types/4` below is then the
  identity); the PRODUCTION adapter must implement it: `@impl true`, `verify_adapter!/0` at boot
  and the wiring test `entity_port_prelock_wired_test.exs`.
  """
  @callback lock_types(
              Ecto.Multi.t(),
              lines :: [line()],
              module_lines :: [module_write_line()],
              lock_ctx :: %{required(:prefix) => String.t()}
            ) :: Ecto.Multi.t()

  @optional_callbacks lock_types: 4

  @doc """
  Maps a failed `{:line, i, step}` Multi step (and its reason) to a `failure()`. The engine
  cannot call the entity layer's own interpreter (engine -> entities is forbidden), so this
  is the one door. Never carries a field value or name.
  """
  @callback interpret_failure(failed_step :: term(), reason :: term()) :: failure()

  @doc """
  The injected implementation module, read from `config :letflow, :entity_port`. The single
  reader of that key (D-A3.7).
  """
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:letflow, :entity_port)

  @doc """
  The pre-lock through the configured implementation (`impl/0`): the Multi unchanged when the
  implementation does not export `lock_types/4` (a test double). See the callback.
  """
  @spec lock_types(
          Ecto.Multi.t(),
          [line()],
          [module_write_line()],
          %{required(:prefix) => String.t()}
        ) :: Ecto.Multi.t()
  def lock_types(multi, lines, module_lines, lock_ctx),
    do: lock_types(impl(), multi, lines, module_lines, lock_ctx)

  @doc false
  @spec lock_types(module(), Ecto.Multi.t(), [line()], [module_write_line()], map()) ::
          Ecto.Multi.t()
  def lock_types(impl, multi, lines, module_lines, lock_ctx) do
    if exports_lock_types?(impl),
      do: impl.lock_types(multi, lines, module_lines, lock_ctx),
      else: multi
  end

  @doc """
  Boot-time guarantee (decision 0061 rule 4): raises when the CONFIGURED adapter does not export
  the optional `lock_types/4`, so omitting it from the production adapter cannot go unnoticed.
  Called from `Letflow.Application.start/2`; test doubles are installed with `Application.put_env`
  after boot and keep the no-op default.
  """
  @spec verify_adapter!() :: :ok
  def verify_adapter!, do: verify_adapter!(impl())

  @doc false
  @spec verify_adapter!(module()) :: :ok
  def verify_adapter!(adapter) when is_atom(adapter) do
    if exports_lock_types?(adapter) do
      :ok
    else
      raise "config :letflow, :entity_port (#{inspect(adapter)}) does not export lock_types/4: " <>
              "the service apply's entity-type pre-lock (GH #2704, decision 0061 rule 4) would be skipped."
    end
  end

  defp exports_lock_types?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :lock_types, 4)

  @doc "The instance event type PR B/C append once a step's entity writes committed."
  @spec applied_event_type() :: String.t()
  def applied_event_type, do: @event_type
end
