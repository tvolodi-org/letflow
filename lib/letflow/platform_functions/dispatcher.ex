defmodule Letflow.PlatformFunctions.Dispatcher do
  @moduledoc """
  The DURABLE dispatcher of a platform step (T-2589, pilot gap G1a of the
  "Register a tenant" pilot; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (a)). The product's page
  on the step library is `docs/platform-steps.md`.

  A platform step is a SERVICE_TASK bound to a platform function of the
  compiled catalogue. This module is the step library's runtime: it arms the
  step, claims it, checks its authority, runs the function and records the
  result.

  ## Why it is durable and outside the engine's transaction

  A platform function may run DDL -- `tenant.provision` creates a tenant
  schema and replays its migrations. DDL cannot run inside the engine's
  transaction, which holds the instance's own rows for the whole step. So the
  work is split in three:

    1. `arm/1` -- a short transaction that writes the `platform_step_dispatches`
       row. The engine calls it inside its own transaction; the row is the
       hand-over point.
    2. the RUN -- the function body runs OUTSIDE every transaction this module
       owns. The claim transaction has committed before the body starts and
       the result transaction opens only after the body returned, so no
       engine transaction and no dispatcher transaction is open while the
       body runs.
    3. the RESULT -- a short transaction that writes the outputs (or the
       failure kind) into the row. The row IS the per-step result row: it
       carries the status, the attempt count, the outputs, the failure kind
       and the timestamps.

  A crash between (1) and (3) loses nothing: the row stays `running` and its
  lease (`next_attempt_at`) expires, so the next claim takes it over.

  ## The lease and the claim token

  The lease is the row's `next_attempt_at` while it is `running`. A dispatcher
  that finds a `running` row whose lease has NOT expired must NOT take it
  over: the run that holds the row is still in flight, and a second run of
  the same body for the same call is exactly the threat S8 names (a double
  click, a retry, a poller restart). Such a dispatch is refused with
  `platform_step_in_flight` and the body does not run a second time.

  The attempt that holds the row holds a CLAIM TOKEN with it: the row's
  `attempt_index`. The result of an attempt is written only while the row
  still carries THAT number and is still `running`. An attempt whose lease
  expired and whose row a later attempt took over therefore cannot overwrite
  the result of the attempt that owns the row now: its outcome is dropped and
  the answer is `platform_step_lease_lost`.

  ## The authority fence

  Every attempt calls `Letflow.PlatformFunctions.Guard.authorize_dispatch/1`
  BEFORE the function runs: the call must be in the platform tenant (INV-10),
  the function must be in the compiled catalogue, the stored graph must carry
  no foreign source beside the call, the `activated_by` document must still
  verify against the tenant's signing key, and the activator must still hold
  the entry's permission (a lost permission marks the definition
  `needs_reactivation`). A refused call never reaches the function body.

  ## The idempotency of a repeated dispatch

  Every call has a KEY, composed by this module from the catalogue entry's
  declared key inputs (the slug for a registration, the tenant id for the
  tenant family). The key is unique per tenant schema, so:

    * the same key with the SAME arguments is the SAME call: the first result
      is returned and the function is not run a second time;
    * the same key with DIFFERENT arguments is a key reuse: the dispatch is
      refused with `idempotency_key_reuse` and nothing runs.

  The key inputs are TENANT-CONTROLLED values (a start variable), so the key
  carries a DIGEST of them and never the raw value: no value a caller passes
  can overflow the key column (`varchar(255)` under a unique index). A value
  over the input cap is refused with `platform_call_arg_invalid` before
  anything is written.

  The arming is INSERT-FIRST: the row is written with
  `ON CONFLICT (call_key) DO NOTHING`, so a double click, a retry or a
  poller restart can never raise on the unique index -- the row that carries
  the key is read back and the first result wins.

  ## The tenant of a row

  A row physically sits in ONE tenant's schema, so the tenant it claims to
  belong to is DERIVED from that schema
  (`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`), never accepted
  from the caller (decision 0003's addendum). The derivation is pure, so a
  MALFORMED prefix is refused `:invalid_schema_name` before any I/O; a
  WELL-FORMED prefix that names no live tenant schema is refused the same
  way, before the row is written.

  ## The prefix of a call

  EVERY public function of this module takes a prefix, and EVERY one of them
  asks the same question first: does this prefix name a live tenant schema
  that CARRIES the dispatch table? A schema that is gone (the tenant was
  purged) or that never had the table (a tenant provisioned before this
  migration) cannot hold a dispatch row, so it is refused
  `:invalid_schema_name` -- the arming, the dispatch, the due query and the
  outcome write alike. The question is asked by a read with a BOUND parameter
  (INV-7), never by SQL text built from the caller's value.

  The check is on every path because the alternative is a raw database error
  out of a public function: a prefix that names no live schema used to make
  the dispatch path raise `42P01` (the relation does not exist) where the
  module promises an error tuple (INV-8). The arming path was guarded first
  and the dispatch path was not -- a fix that covers one variant of the class
  leaves the next one live.

  ## The binding of a row to its node

  A dispatch row is bound to the node of the definition it claims to run: the
  dispatcher re-derives the node's declared call from the STORED graph and
  refuses a row whose function or arguments the node does not declare. The
  authority fence proves WHO may run the call; this proves WHAT the call is.

  ## The failure kind of a row

  `last_failure_kind` is a STABLE CODE, never a customer text: the row is
  read by the step log (gap G6) and must not carry anything a tenant typed
  (INV-4). A reason that is an ATOM names a code of this module's own
  vocabulary -- and an atom that is NOT one of those codes is reduced to the
  generic code, exactly like a binary reason: the vocabulary is CLOSED, so
  the row only ever carries a code a reader can act on. A reason that is a
  BINARY is caller-supplied text and is reduced to a code of the closed
  vocabulary, and to the generic code `platform_step_failed` when it is none
  of them. Nothing is ever inspected: an inspected reason would carry the
  customer's text into the row, and it can be longer than the column that
  holds it.

  The vocabulary is not a hand list that may drift: `failure_codes/0` hands
  it out, and the registered bodies' own declared vocabularies are checked
  against it (`test/letflow/platform_functions/failure_vocabulary_test.exs`),
  so a body cannot answer a code the row would refuse to carry.

  ## The attempt cap

  A run killed uncatchably leaves the row `running` with an expired lease, so
  the next claim takes it over. The number of such takes is capped
  (`max_attempts/0`): a call that reaches the cap is DEAD-LETTERED -- the row
  leaves the queue for good and keeps the failure kind
  `platform_step_max_attempts`.

  ## What it does NOT do

  It does not advance the instance and it does not merge the outputs into the
  instance variables: the engine picks the result up (gap G1's engine slice).
  It does not write an audit row of its own (gap G6 owns the step log), and it
  never raises: every failure is an error tuple (INV-8).
  """

  import Ecto.Query

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.Guard
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @default_batch_size 64
  @lease_ms 300_000
  @max_attempts 5

  # The byte cap of ONE declared input value. The inputs are tenant-controlled
  # values (a start variable), so they are bounded BEFORE the dispatcher does
  # any per-character work on them (SF-01): over the cap is a typed refusal,
  # never a write that fails in the database.
  @max_input_bytes 4096

  # The byte cap of the NODE ID. The node id is a caller-supplied string that
  # goes into a `varchar(255)` column, and it is NOT one of the entry's
  # declared inputs -- so the input cap does not cover it. The cap is in
  # BYTES: the column counts characters, so a byte cap is the stricter of the
  # two and can never overflow the column.
  @max_node_id_bytes 255

  # The byte cap of the failure kind in the row (`last_failure_kind` is a
  # `varchar(255)`): a code longer than that is the generic code.
  @max_failure_kind_bytes 255

  # The CLOSED vocabulary of the codes the row may carry in
  # `last_failure_kind`. A BINARY reason is caller-supplied text, so it is
  # reduced to a code of this vocabulary -- and to the generic code when it is
  # none of them. The vocabulary is closed on purpose: the row is read by the
  # step log (gap G6), and a code nobody can enumerate is a code nobody can
  # act on.
  @failure_codes MapSet.new(~w(
    conflicting_platform_call_routes
    idempotency_key_reuse
    invalid_schema_name
    platform_call_arg_invalid
    platform_call_arg_mismatch
    platform_call_arg_missing
    platform_call_arg_unknown
    platform_call_default_modules_failed
    platform_call_definition_missing
    platform_call_duplicate_realm
    platform_call_duplicate_slug
    platform_call_foreign_source_refused
    platform_call_function_mismatch
    platform_call_function_unknown
    platform_call_grant_failed
    platform_call_invalid_display_name
    platform_call_invalid_email
    platform_call_invalid_slug
    platform_call_needs_reactivation
    platform_call_node_missing
    platform_call_node_not_declared
    platform_call_permission_required
    platform_call_provision_failed
    platform_call_realm_already_bound
    platform_call_realm_bind_failed
    platform_call_signature_invalid
    platform_call_tenant_create_failed
    platform_call_tenant_not_active
    platform_call_tenant_not_allowed
    platform_call_tenant_not_found
    platform_call_tenant_purged
    platform_function_not_implemented
    platform_function_unknown
    platform_step_arm_failed
    platform_step_bad_result
    platform_step_claim_failed
    platform_step_in_flight
    platform_step_lease_lost
    platform_step_max_attempts
    platform_step_not_found
    platform_step_outcome_failed
    platform_step_raised
  ))

  # The code a reason that names no code of the vocabulary is reduced to.
  @generic_failure_kind "platform_step_failed"

  # The options `arm/1` accepts. An option outside this list is REFUSED, not
  # ignored: a caller must not believe that an option the dispatcher does not
  # read (`:tenant_id` above all) is honoured.
  @arm_options [:prefix, :instance_id, :definition_id, :node_id, :function, :inputs]

  defmodule StepDispatch do
    @moduledoc """
    Ecto schema for the `platform_step_dispatches` table: the durable queue of
    a platform step and, at the same time, its per-step result row.

    Every tenant-scoped table in this codebase lives in many Postgres schemas
    (one per tenant), so every read and write passes `prefix: schema_name` at
    call time. There is no `@schema_prefix` here for the same reason there is
    none in `Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch`.

    ## `status`

    `pending` (armed), `running` (claimed; the lease is `next_attempt_at`),
    `advanced` (the function returned its outputs) and `given_up` (the call
    failed and is not retried). The DB-level CHECK
    (`chk_platform_step_dispatches_status`) is the backstop; the Elixir side
    is an `Ecto.Enum` over the unchanged `:string` column, so an invalid
    value is a changeset error and not a DB error.

    ## Extension point (owner decision D-180, not built here)

    A tenant may later fork a standard definition into its own copy
    (`custom`, `based_on`). This table needs NO column for that: the row
    references the definition row by `definition_id`, and a forked copy is a
    different definition row.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "platform_step_dispatches" do
      field(:tenant_id, Ecto.UUID)
      field(:instance_id, Ecto.UUID)
      field(:definition_id, Ecto.UUID)
      field(:node_id, :string)

      field(:function_name, :string)
      field(:call_key, :string)
      field(:input_fingerprint, :string)
      field(:inputs, :map, default: %{})
      field(:outputs, :map)

      field(:status, Ecto.Enum,
        values: [:pending, :running, :advanced, :given_up],
        default: :pending
      )

      field(:attempt_index, :integer, default: 0)
      field(:next_attempt_at, :utc_datetime_usec)

      field(:last_failure_kind, :string)
      field(:dispatched_at, :utc_datetime_usec)

      field(:created_at, :utc_datetime_usec)
    end

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            tenant_id: Ecto.UUID.t(),
            instance_id: Ecto.UUID.t(),
            definition_id: Ecto.UUID.t(),
            node_id: String.t(),
            function_name: String.t(),
            call_key: String.t(),
            input_fingerprint: String.t(),
            inputs: map(),
            outputs: map() | nil,
            status: :pending | :running | :advanced | :given_up,
            attempt_index: non_neg_integer(),
            next_attempt_at: DateTime.t(),
            last_failure_kind: String.t() | nil,
            dispatched_at: DateTime.t() | nil,
            created_at: DateTime.t()
          }

    @doc """
    The changeset of the INSERT path -- `arm/1`'s own write.

    The unique constraint on `call_key` is declared here so that a write that
    hits the index is a CHANGESET error and not an `Ecto.ConstraintError`
    (INV-8). The arming path does not rely on it: it writes with
    `on_conflict: :nothing` and reads the row that carries the key back, so a
    repeated arming of the same call replays the first result instead of
    raising.
    """
    @spec arm_changeset(t(), map()) :: Ecto.Changeset.t()
    def arm_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [
        :id,
        :tenant_id,
        :instance_id,
        :definition_id,
        :node_id,
        :function_name,
        :call_key,
        :input_fingerprint,
        :inputs,
        :status,
        :attempt_index,
        :next_attempt_at,
        :created_at
      ])
      |> validate_required([
        :id,
        :tenant_id,
        :instance_id,
        :definition_id,
        :node_id,
        :function_name,
        :call_key,
        :input_fingerprint,
        :status,
        :attempt_index,
        :next_attempt_at,
        :created_at
      ])
      |> unique_constraint(:call_key, name: :uniq_platform_step_dispatches_call_key)
    end

    @doc """
    The changeset of the CLAIM: the row becomes `running`, the attempt count
    grows and the lease (`next_attempt_at`) moves forward.
    """
    @spec claim_changeset(t(), map()) :: Ecto.Changeset.t()
    def claim_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [:status, :attempt_index, :next_attempt_at])
      |> validate_required([:status, :attempt_index, :next_attempt_at])
    end

    @doc """
    The changeset of the terminal write: the outputs of a succeeded call, or
    the failure kind of a refused one.
    """
    @spec terminal_changeset(t(), map()) :: Ecto.Changeset.t()
    def terminal_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [:status, :outputs, :last_failure_kind, :dispatched_at])
      |> validate_required([:status, :dispatched_at])
    end
  end

  @typedoc "The outcome of arming a step."
  @type arm_result :: %{
          status: :armed | :replayed | :rearmed,
          dispatch: StepDispatch.t(),
          outputs: map() | nil
        }

  @doc """
  Arms a platform step: the durable row of the call.

  `opts`:

    * `:prefix` -- the tenant schema the step runs in. The tenant the row
      belongs to is DERIVED from it, never taken from the caller: the row
      physically sits in this tenant's schema and must claim to be that
      tenant's (decision 0003's addendum). A prefix that names no tenant
      schema a dispatch row can live in -- malformed, well-formed but absent,
      or a schema without the dispatch table -- is refused
      `:invalid_schema_name` before the row is written;
    * `:instance_id`, `:definition_id`, `:node_id` -- where the step sits.
      The node id is a caller-supplied string, so it is byte-bounded like
      the declared inputs (255 bytes);
    * `:function` -- the catalogue entry's name;
    * `:inputs` -- the resolved arguments, keyed by the entry's declared
      input names.

  An option outside this list is REFUSED (`platform_call_arg_unknown`), never
  ignored: a caller must not believe that an option the dispatcher does not
  read is honoured.

  Returns `{:ok, %{status: :armed, dispatch: row}}` for a new call,
  `{:ok, %{status: :replayed, dispatch: row, outputs: outputs}}` when the same
  call already ran (the first result is returned and nothing runs again),
  `{:ok, %{status: :rearmed, dispatch: row}}` when a previously failed call is
  armed again, and `{:error, reason}` otherwise -- `idempotency_key_reuse`
  when the same key carries different arguments, `platform_function_unknown`
  for a name the compiled catalogue does not know, `platform_function_not_implemented`
  for a name the catalogue declares but has no body yet, `invalid_schema_name`
  for a prefix that names no schema a dispatch row can live in,
  `platform_call_arg_invalid` for a
  value over the input cap or a node id over its byte cap.
  """
  @spec arm(keyword()) :: {:ok, arm_result()} | {:error, term()}
  def arm(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.validate(opts, @arm_options) do
        {:ok, _validated} -> arm_call(opts)
        {:error, _unknown} -> {:error, :platform_call_arg_unknown}
      end
    else
      {:error, :platform_call_arg_unknown}
    end
  rescue
    # A failure of the database itself (the schema check cannot be read) is a
    # typed refusal and never an exception out of `arm/1` (INV-8).
    _exception -> {:error, :platform_step_arm_failed}
  end

  defp arm_call(opts) do
    prefix = Keyword.get(opts, :prefix)
    instance_id = Keyword.get(opts, :instance_id)
    definition_id = Keyword.get(opts, :definition_id)
    node_id = Keyword.get(opts, :node_id)
    function = Keyword.get(opts, :function)
    inputs = Keyword.get(opts, :inputs) || %{}

    with :ok <- check_node_id(node_id),
         {:ok, tenant_id} <- derive_tenant_id(prefix),
         :ok <- check_tenant_schema(prefix),
         {:ok, entry} <- fetch_entry(function),
         :ok <- check_inputs(entry, inputs),
         {:ok, _mfa} <- fetch_implementation(function) do
      call_key = call_key(entry, inputs)
      fingerprint = fingerprint(inputs)

      upsert(prefix, %{
        tenant_id: tenant_id,
        instance_id: instance_id,
        definition_id: definition_id,
        node_id: node_id,
        function_name: function,
        call_key: call_key,
        input_fingerprint: fingerprint,
        inputs: inputs
      })
    else
      {:error, :not_found} -> {:error, :platform_function_unknown}
      {:error, :not_implemented} -> {:error, :platform_function_not_implemented}
      {:error, reason} -> {:error, reason}
    end
  end

  # The tenant of a row is DERIVED from the schema the row is written into,
  # never accepted as an independently-trusted field from the caller
  # (decision 0003's addendum: "the value written into a table's `tenant_id`
  # column is derived by the writing context module from the Postgres schema
  # (:prefix) it is already writing into for that call"). The derivation is
  # PURE, so a MALFORMED prefix is refused before any I/O (INV-8: a caller
  # mistake answers an error tuple, never a crash).
  defp derive_tenant_id(prefix) do
    TenantProvisioning.tenant_id_for_schema_name(prefix)
  end

  # The row is written INTO the prefix's schema, so a prefix that names no
  # LIVE schema is a refusal and not a database error: the derivation above
  # only parses the name, it cannot know whether the schema exists. Nor can
  # it know whether the schema CARRIES the dispatch table: a tenant
  # provisioned before this migration has a schema but no table, and a query
  # against it raises `42P01` (the relation does not exist).
  #
  # So the check asks both questions in ONE read, with a BOUND parameter
  # (INV-7): no SQL text is built from the caller's value -- the table's name
  # is a literal of this module. EVERY public path that takes a prefix asks
  # it, so that no path escapes with a raw database error (INV-8).
  defp check_tenant_schema(prefix) when is_binary(prefix) do
    case Repo.query(
           """
           SELECT 1
           FROM pg_namespace n
           JOIN pg_class c ON c.relnamespace = n.oid
           WHERE n.nspname = $1
             AND c.relname = 'platform_step_dispatches'
             AND c.relkind IN ('r', 'p')
           """,
           [prefix]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      _absent_or_unreadable -> {:error, :invalid_schema_name}
    end
  end

  defp check_tenant_schema(_prefix), do: {:error, :invalid_schema_name}

  # The node id is a caller-supplied string that goes into a `varchar(255)`
  # column, and it is not one of the entry's declared inputs -- so the input
  # cap does not cover it. It gets its own byte cap, and a node id that is
  # not a string at all is refused the same way. The refusal is typed
  # (INV-8): the row is never written with a value that does not fit.
  defp check_node_id(node_id) when is_binary(node_id) do
    if byte_size(node_id) <= @max_node_id_bytes do
      :ok
    else
      {:error, :platform_call_arg_invalid}
    end
  end

  defp check_node_id(_node_id), do: {:error, :platform_call_arg_invalid}

  @doc """
  Claims the row, checks the authority of the call and runs the function.

  The body runs OUTSIDE every transaction this module owns: the claim has
  committed before it starts and the result transaction opens after it
  returned.

  Returns `{:ok, {:advanced, outputs}}` when the function returned its
  outputs, `{:ok, {:already_final, outputs}}` when the row had already run
  (the stored outputs are returned), and `{:error, reason}` otherwise -- the
  reason is the refusal of the authority fence, the code of the function's own
  refusal, `platform_step_max_attempts` when the call was dead-lettered,
  `platform_step_in_flight` when another run holds the row and its lease has
  not expired, `platform_step_not_found` for a row that is not in this tenant
  schema (or for an id that is not an id at all), `invalid_schema_name` for a
  prefix that names no schema a dispatch row can live in, or
  `platform_step_raised` for an unexpected failure (INV-8: the step fails, the
  dispatcher does not crash).
  """
  @spec attempt_dispatch(Ecto.UUID.t(), String.t()) ::
          {:ok, {:advanced, map()}} | {:ok, {:already_final, map() | nil}} | {:error, term()}
  def attempt_dispatch(dispatch_id, prefix) when is_binary(prefix) do
    with :ok <- check_tenant_schema(prefix) do
      case Ecto.UUID.cast(dispatch_id) do
        {:ok, id} -> dispatch(id, prefix)
        :error -> {:error, :platform_step_not_found}
      end
    end
  rescue
    # A failure of the database itself (a schema that lost its table between
    # the check and the query) is a typed refusal and never an exception out
    # of the dispatcher (INV-8).
    _exception -> {:error, :platform_step_raised}
  end

  defp dispatch(dispatch_id, prefix) do
    case claim(dispatch_id, prefix) do
      {:ok, {:already_final, row}} ->
        {:ok, {:already_final, row.outputs}}

      {:ok, {:claimed, row}} ->
        run(row, prefix)

      {:ok, {:given_up, _row}} ->
        {:error, :platform_step_max_attempts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Claims every DUE row of a tenant schema and runs it: the entry point a
  poller calls (and the one the tests drive).

  A row is due when it is `pending` and its `next_attempt_at` has passed, or
  when it is `running` and its lease has expired (the run that held it
  crashed).

  Returns the counts of the cycle, or `{:error, reason}` when the cycle
  cannot run at all -- `invalid_schema_name` for a prefix that names no
  schema a dispatch row can live in. Never raises: a failure of the database
  itself is `platform_step_raised`.
  """
  @spec run_due(String.t(), pos_integer()) ::
          %{
            claimed: non_neg_integer(),
            advanced: non_neg_integer(),
            failed: non_neg_integer()
          }
          | {:error, term()}
  def run_due(prefix, limit \\ @default_batch_size)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    case due_dispatch_ids(prefix, limit) do
      {:error, reason} ->
        {:error, reason}

      due_ids ->
        Enum.reduce(
          due_ids,
          %{claimed: 0, advanced: 0, failed: 0},
          fn dispatch_id, acc ->
            # The schema was checked ONCE for the whole cycle (by the due
            # query above), so the dispatch of a row does not ask again.
            case dispatch(dispatch_id, prefix) do
              {:ok, {:advanced, _outputs}} ->
                %{acc | claimed: acc.claimed + 1, advanced: acc.advanced + 1}

              {:ok, {:already_final, _outputs}} ->
                %{acc | claimed: acc.claimed + 1}

              {:error, _reason} ->
                %{acc | claimed: acc.claimed + 1, failed: acc.failed + 1}
            end
          end
        )
    end
  rescue
    _exception -> {:error, :platform_step_raised}
  end

  @doc """
  The ids of the rows that are due in `prefix`, oldest first.

  A prefix that names no schema a dispatch row can live in is refused with
  `{:error, :invalid_schema_name}` -- the same refusal every public path of
  this module answers for it, so that no path escapes with a raw database
  error (INV-8).
  """
  @spec due_dispatch_ids(String.t(), pos_integer()) :: [Ecto.UUID.t()] | {:error, term()}
  def due_dispatch_ids(prefix, limit \\ @default_batch_size)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    with :ok <- check_tenant_schema(prefix) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      StepDispatch
      |> where(
        [d],
        d.status in [:pending, :running] and d.next_attempt_at <= ^now
      )
      |> order_by([d], asc: d.next_attempt_at)
      |> limit(^limit)
      |> select([d], d.id)
      |> Repo.all(prefix: prefix)
    end
  rescue
    _exception -> {:error, :platform_step_raised}
  end

  # ── the catalogue and the arguments ─────────────────────────────────────────────────────

  defp fetch_entry(function) when is_binary(function) do
    case Catalog.fetch(function) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp fetch_entry(_function), do: {:error, :not_found}

  defp fetch_implementation(function) when is_binary(function) do
    case Registry.fetch(function) do
      {:ok, mfa} -> {:ok, mfa}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_implementation(_function), do: {:error, :not_found}

  # The arguments must be the entry's own: no unknown name, every required
  # name present, every value of the declared type and every value within
  # the byte cap.
  defp check_inputs(%Entry{inputs: declared}, inputs) when is_map(inputs) do
    declared_names = MapSet.new(declared, & &1.name)

    unknown =
      Enum.any?(Map.keys(inputs), fn name ->
        not (is_binary(name) and MapSet.member?(declared_names, name))
      end)

    cond do
      unknown ->
        {:error, :platform_call_arg_unknown}

      true ->
        missing =
          Enum.any?(declared, fn input ->
            input.required and not Map.has_key?(inputs, input.name)
          end)

        mistyped =
          Enum.any?(declared, fn input ->
            case Map.get(inputs, input.name) do
              nil -> false
              value -> not value_of_type?(input.type, value)
            end
          end)

        # The byte bound comes FIRST: an over-long value is refused before
        # the dispatcher composes the key, fingerprints the arguments or
        # hands them to the body (SF-01). Without it an over-long value
        # would reach the database as a key that does not fit its column.
        oversized =
          Enum.any?(declared, fn input ->
            case Map.get(inputs, input.name) do
              nil -> false
              value -> is_binary(value) and byte_size(value) > @max_input_bytes
            end
          end)

        cond do
          missing -> {:error, :platform_call_arg_missing}
          mistyped -> {:error, :platform_call_arg_invalid}
          oversized -> {:error, :platform_call_arg_invalid}
          true -> :ok
        end
    end
  end

  defp check_inputs(_entry, _inputs), do: {:error, :platform_call_arg_invalid}

  defp value_of_type?(:string, value), do: is_binary(value)
  defp value_of_type?(:uuid, value), do: is_binary(value)
  defp value_of_type?(:integer, value), do: is_integer(value)
  defp value_of_type?(:boolean, value), do: is_boolean(value)
  defp value_of_type?(_type, _value), do: false

  # The KEY of the call: the function's name and a DIGEST of the entry's
  # declared key inputs. The key inputs are tenant-controlled values (a start
  # variable), so the key carries a digest and never the raw value: no value
  # a caller passes can overflow the key column (`varchar(255)` under a
  # unique index). A collision is safe -- the fingerprint check below refuses
  # a different call that carries the same key.
  defp call_key(%Entry{name: name, idempotency_key: key_inputs}, inputs) do
    composition =
      Enum.map_join(key_inputs, "|", fn key ->
        "#{key}=#{Map.get(inputs, key)}"
      end)

    "#{name}|#{sha256_hex(composition)}"
  end

  # The FINGERPRINT of the whole argument set: same key + same fingerprint is
  # the same call; same key + a different fingerprint is a key reuse.
  defp fingerprint(inputs) when is_map(inputs) do
    canonical =
      inputs
      |> Enum.map(fn {name, value} -> {to_string(name), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, value} -> name <> "=" <> encode_value(value) end)

    sha256_hex(canonical)
  end

  defp sha256_hex(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  # A value that JSON cannot carry (a tuple, a pid) still has to produce a
  # stable fingerprint: the dispatcher never raises (INV-8).
  defp encode_value(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  # ── the arming ────────────────────────────────────────────────────────────────────────

  # The INSERT is the atomic step of the arming: the row is written with
  # `ON CONFLICT (call_key) DO NOTHING`, so a repeated arming of the SAME call
  # is a no-op instead of an error. There is no read-then-write race left:
  # the row that carries the key is read back AFTER the write, and it is
  # either the row this call just wrote (its id is the id we tried to write)
  # or the row another dispatcher wrote first -- the same call, whose first
  # result is returned (S8: a double click, a retry or a poller restart may
  # never raise).
  defp upsert(prefix, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    attempted_id = Ecto.UUID.generate()

    changeset =
      StepDispatch.arm_changeset(%StepDispatch{id: attempted_id}, %{
        id: attempted_id,
        tenant_id: attrs.tenant_id,
        instance_id: attrs.instance_id,
        definition_id: attrs.definition_id,
        node_id: attrs.node_id,
        function_name: attrs.function_name,
        call_key: attrs.call_key,
        input_fingerprint: attrs.input_fingerprint,
        inputs: attrs.inputs,
        status: :pending,
        attempt_index: 0,
        next_attempt_at: now,
        created_at: now
      })

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :call_key,
           prefix: prefix
         ) do
      {:ok, _inserted} ->
        case Repo.get_by(StepDispatch, [call_key: attrs.call_key], prefix: prefix) do
          %StepDispatch{id: ^attempted_id} = row ->
            {:ok, %{status: :armed, dispatch: row, outputs: nil}}

          %StepDispatch{} = existing ->
            # Another dispatcher armed the same call first: the existing row IS
            # this call, so it is handled like one.
            handle_existing(prefix, existing, attrs)

          nil ->
            {:error, :platform_step_arm_failed}
        end

      {:error, _changeset} ->
        {:error, :platform_step_arm_failed}
    end
  rescue
    # A failure of the database itself (a constraint the changeset does not
    # know, a schema that lost its table between the check and the write) is
    # a typed refusal and never an exception out of `arm/1` (INV-8).
    _exception -> {:error, :platform_step_arm_failed}
  end

  defp handle_existing(prefix, existing, attrs) do
    cond do
      existing.input_fingerprint != attrs.input_fingerprint ->
        # The same key with different arguments: a reuse, refused. The first
        # call keeps its result.
        {:error, :idempotency_key_reuse}

      existing.status == :advanced ->
        {:ok, %{status: :replayed, dispatch: existing, outputs: existing.outputs}}

      existing.status == :given_up ->
        # A failed call may be armed again: the arguments are the same, so the
        # call is the same call.
        rearm(prefix, existing, attrs)

      true ->
        {:ok, %{status: :armed, dispatch: existing, outputs: nil}}
    end
  end

  defp rearm(prefix, existing, _attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    existing
    |> StepDispatch.claim_changeset(%{
      status: :pending,
      attempt_index: existing.attempt_index,
      next_attempt_at: now
    })
    |> Repo.update(prefix: prefix)
    |> case do
      {:ok, updated} -> {:ok, %{status: :rearmed, dispatch: updated, outputs: nil}}
      {:error, _changeset} -> {:error, :platform_step_arm_failed}
    end
  end

  # ── the claim ─────────────────────────────────────────────────────────────────────────

  @doc """
  The maximum number of attempts one call gets before it is DEAD-LETTERED.

  A run killed uncatchably (the VM dies, the node is killed) leaves the row
  `running` with a lease that expires, so the next claim takes it over.
  Without a cap that take-over would go on forever -- one attempt a lease
  period, the attempt counter growing without bound. The cap is the
  DECISION that a call which cannot complete is given up on; the row leaves
  the queue for good and keeps the failure kind `platform_step_max_attempts`.
  """
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  The lease of a claim, in milliseconds: how long a run may hold the row
  before another dispatcher may take it over.

  The lease must outlast the slowest platform function body: a body that
  outgrows it is retried by a later attempt (the bodies are idempotent by
  contract) and the claim token keeps the stale attempt's result harmless.
  """
  @spec lease_ms() :: pos_integer()
  def lease_ms, do: @lease_ms

  @doc """
  The CLOSED vocabulary of the codes a dispatch row may carry in
  `last_failure_kind`, as a sorted list of strings.

  The vocabulary is closed on purpose: the row is read by the step log (gap
  G6), and a code nobody can enumerate is a code nobody can act on. Every
  refusal a registered body can answer is one of these codes -- the
  vocabulary is CHECKED against the bodies' own declared vocabularies
  (`test/letflow/platform_functions/failure_vocabulary_test.exs`), so a new
  body cannot answer a code the row would not accept.
  """
  @spec failure_codes() :: [String.t()]
  def failure_codes, do: @failure_codes |> MapSet.to_list() |> Enum.sort()

  defp claim(dispatch_id, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      row =
        StepDispatch
        |> where([d], d.id == ^dispatch_id)
        |> lock("FOR UPDATE")
        |> Repo.one(prefix: prefix)

      case row do
        nil ->
          Repo.rollback(:platform_step_not_found)

        %StepDispatch{status: status} = existing when status in [:advanced, :given_up] ->
          {:already_final, existing}

        %StepDispatch{status: :running, next_attempt_at: lease} = existing ->
          if DateTime.compare(lease, now) == :gt do
            # The lease has NOT expired: the run that holds the row is still in
            # flight. A second dispatcher must NOT take the row over -- the
            # body would run a second time for the same call (S8).
            Repo.rollback(:platform_step_in_flight)
          else
            # The lease has expired: the run that held it is gone (the node
            # died), so this claim takes the row over.
            claim_or_give_up(existing, now, prefix)
          end

        %StepDispatch{} = existing ->
          claim_or_give_up(existing, now, prefix)
      end
    end)
  end

  defp claim_or_give_up(%StepDispatch{attempt_index: attempts} = existing, _now, prefix)
       when attempts >= @max_attempts do
    # The cap is reached: the call is DEAD-LETTERED. The row leaves the
    # queue (its status is no longer `pending`/`running`, so the due
    # query stops selecting it) and keeps the failure kind.
    {:given_up, dead_letter(existing, prefix)}
  end

  defp claim_or_give_up(existing, now, prefix) do
    existing
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: existing.attempt_index + 1,
      next_attempt_at: DateTime.add(now, @lease_ms, :millisecond)
    })
    |> Repo.update(prefix: prefix)
    |> case do
      {:ok, updated} -> {:claimed, updated}
      {:error, _changeset} -> Repo.rollback(:platform_step_claim_failed)
    end
  end

  defp dead_letter(row, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row
    |> StepDispatch.terminal_changeset(%{
      status: :given_up,
      last_failure_kind: "platform_step_max_attempts",
      dispatched_at: now
    })
    |> Repo.update(prefix: prefix)
    |> case do
      {:ok, updated} -> updated
      {:error, _changeset} -> row
    end
  end

  # ── the run (outside every transaction this module owns) ──────────────────────────────

  defp run(row, prefix) do
    with {:ok, definition} <- load_definition(row, prefix),
         :ok <- authorize(definition, row, prefix),
         :ok <- check_binding(definition, row),
         {:ok, mfa} <- fetch_implementation(row.function_name),
         {:ok, outputs} <- invoke(mfa, row),
         :ok <- record_outcome(row, prefix, {:ok, outputs}) do
      {:ok, {:advanced, outputs}}
    else
      {:error, reason} ->
        _ = record_outcome(row, prefix, {:error, reason})
        {:error, reason}
    end
  end

  # The row is BOUND to the definition's node. The fence above proves WHO may
  # run the call; this proves WHAT the call is: the node the row names must
  # exist in the definition's stored graph, it must declare a platform call,
  # and that call must be the row's function with the row's arguments. An
  # arming caller that is not the engine could otherwise run a function with
  # arguments no definition declares -- outside the "declared variables only"
  # rule of decision 0094.
  defp check_binding(definition, row) do
    with {:ok, nodes} <- graph_nodes(definition),
         {:ok, call} <- PlatformCalls.node_call_binding(nodes, row.node_id),
         :ok <- check_bound_function(call, row),
         :ok <- check_bound_args(call, row) do
      :ok
    end
  end

  defp graph_nodes(definition) do
    case Map.get(definition, :graph) do
      graph_map when is_map(graph_map) ->
        case Graph.from_map(graph_map) do
          {:ok, %Graph{nodes: nodes}} -> {:ok, nodes}
          _not_a_graph -> {:error, :platform_call_node_missing}
        end

      _no_graph ->
        {:error, :platform_call_node_missing}
    end
  end

  defp check_bound_function(%{"function" => function}, row) do
    if function == row.function_name do
      :ok
    else
      {:error, :platform_call_function_mismatch}
    end
  end

  # The row's arguments are the node's DECLARED arguments and nothing else:
  # the same names, and the same values for the arguments the node declares as
  # constants. An argument the node reads from a variable is the instance's
  # own value, which the engine resolves, so the dispatcher cannot check it --
  # but it refuses a name the node never declared.
  defp check_bound_args(%{"args" => args}, row) do
    declared = MapSet.new(Map.keys(args))
    given = MapSet.new(Map.keys(row.inputs))

    cond do
      declared != given -> {:error, :platform_call_arg_mismatch}
      not consts_match?(args, row.inputs) -> {:error, :platform_call_arg_mismatch}
      true -> :ok
    end
  end

  defp consts_match?(args, inputs) do
    Enum.all?(args, fn {name, source} ->
      case source do
        %{"const" => value} -> Map.get(inputs, name) == value
        _other -> true
      end
    end)
  end

  defp load_definition(row, prefix) do
    case Repo.get(ProcessDefinition, row.definition_id, prefix: prefix) do
      nil -> {:error, :platform_call_definition_missing}
      definition -> {:ok, definition}
    end
  end

  # THE FENCE. Nothing runs before this says yes.
  defp authorize(definition, row, prefix) do
    Guard.authorize_dispatch(
      definition: definition,
      prefix: prefix,
      tenant_id: row.tenant_id,
      function: row.function_name
    )
  end

  defp invoke({module, function, arity}, row) do
    context = %{
      inputs: row.inputs,
      dispatch: %{
        id: row.id,
        node_id: row.node_id,
        instance_id: row.instance_id,
        tenant_id: row.tenant_id,
        function: row.function_name
      }
    }

    args = List.duplicate(context, arity)

    case apply(module, function, args) do
      {:ok, outputs} when is_map(outputs) -> {:ok, outputs}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :platform_step_bad_result}
    end
  rescue
    _exception -> {:error, :platform_step_raised}
  catch
    _kind, _reason -> {:error, :platform_step_raised}
  end

  # ── the result ────────────────────────────────────────────────────────────────────────

  @doc """
  Records the OUTCOME of an attempt into the row: the outputs of a succeeded
  call or the failure kind of a refused one.

  The write lands only while the row still carries THAT attempt's number
  (`attempt_index`) and is still `running` -- the CLAIM TOKEN. An attempt
  whose lease expired and whose row a later attempt took over therefore
  cannot overwrite the result of the attempt that owns the row now: its
  outcome is dropped and the answer is `{:error, :platform_step_lease_lost}`.

  The outcome is BOUNDED before the write: outputs that JSON cannot carry
  are refused with `{:error, :platform_step_bad_result}` and nothing is
  written, and a failure of the database itself is
  `{:error, :platform_step_outcome_failed}`. A prefix that names no schema a
  dispatch row can live in is refused with
  `{:error, :invalid_schema_name}`, the same answer every public path gives
  it. The function never raises (INV-8).

  The function is public because the token it enforces is a property of the
  dispatcher a caller must be able to see: a result that was dropped is a
  result nobody can read.
  """
  @spec record_outcome(StepDispatch.t(), String.t(), {:ok, map()} | {:error, term()}) ::
          :ok
          | {:error, :platform_step_lease_lost}
          | {:error, :platform_step_bad_result}
          | {:error, :platform_step_outcome_failed}
          | {:error, :invalid_schema_name}
          | {:error, :platform_step_raised}
  def record_outcome(dispatch, prefix, outcome)
      when is_binary(prefix) and is_map(dispatch) do
    with :ok <- check_tenant_schema(prefix) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      case outcome do
        {:ok, outputs} when is_map(outputs) ->
          with :ok <- encodable(outputs) do
            write_outcome(dispatch, prefix,
              set: [status: :advanced, outputs: outputs, dispatched_at: now]
            )
          end

        {:error, reason} ->
          write_outcome(dispatch, prefix,
            set: [
              status: :given_up,
              last_failure_kind: failure_kind(reason),
              dispatched_at: now
            ]
          )

        _other ->
          # An outcome that is neither an output map nor a refusal is not a
          # result at all: the dispatcher never raises (INV-8).
          {:error, :platform_step_bad_result}
      end
    end
  rescue
    _exception -> {:error, :platform_step_raised}
  end

  # The outputs go into a jsonb column, so they must be values JSON can
  # carry. The check and the write share ONE encoder: `Jason.encode/1` is
  # what the column's dumper calls, so a value it refuses is refused here
  # too -- a typed error instead of an exception out of the write (INV-8).
  defp encodable(outputs) do
    case Jason.encode(outputs) do
      {:ok, _encoded} -> :ok
      {:error, _reason} -> {:error, :platform_step_bad_result}
    end
  end

  # The write of the outcome. It lands only while the row still carries THAT
  # attempt's number and is still `running` (the CLAIM TOKEN). A failure of
  # the database itself is a typed refusal and never an exception out of the
  # public writer (INV-8).
  defp write_outcome(dispatch, prefix, updates) do
    {count, _returned} =
      StepDispatch
      |> where([d], d.id == ^dispatch.id and d.attempt_index == ^dispatch.attempt_index)
      |> where([d], d.status == :running)
      |> Repo.update_all(updates, prefix: prefix)

    if count == 1, do: :ok, else: {:error, :platform_step_lease_lost}
  rescue
    _exception -> {:error, :platform_step_outcome_failed}
  end

  # The failure kind is a STABLE code, never a customer text: the row is read
  # by the step log (gap G6) and must not carry anything a tenant typed
  # (INV-4). A reason that is an ATOM names a code of this module's own
  # vocabulary -- and a code that is NOT one of them is reduced to the
  # generic code, exactly like a binary reason: the vocabulary is closed, so
  # the row only ever carries a code a reader can act on. A reason that is a
  # BINARY is caller-supplied text: it is reduced to a code of the closed
  # vocabulary, and to the generic code when it is none of them. A reason that
  # is neither is the generic code too. Nothing is ever INSPECTED: an
  # inspected reason would carry the customer's text into the row, and it can
  # be longer than the column.
  defp failure_kind(reason) when is_atom(reason) do
    code = Atom.to_string(reason)

    if byte_size(code) <= @max_failure_kind_bytes and MapSet.member?(@failure_codes, code) do
      code
    else
      @generic_failure_kind
    end
  end

  defp failure_kind(reason) when is_binary(reason) do
    if MapSet.member?(@failure_codes, reason) do
      reason
    else
      @generic_failure_kind
    end
  end

  defp failure_kind(_reason), do: @generic_failure_kind
end
