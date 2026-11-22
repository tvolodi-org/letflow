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

  ## What it does NOT do

  It does not advance the instance and it does not merge the outputs into the
  instance variables: the engine picks the result up (gap G1's engine slice).
  It does not write an audit row of its own (gap G6 owns the step log), and it
  never raises: every failure is an error tuple (INV-8).
  """

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.Guard
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Repo

  @default_batch_size 64
  @lease_ms 60_000

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

    * `:prefix` -- the tenant schema the step runs in;
    * `:tenant_id` -- the tenant the INSTANCE runs in (the dispatcher may be
      handed a row forged in another schema, so the instance's own tenant is
      what the authority fence checks);
    * `:instance_id`, `:definition_id`, `:node_id` -- where the step sits;
    * `:function` -- the catalogue entry's name;
    * `:inputs` -- the resolved arguments, keyed by the entry's declared
      input names.

  Returns `{:ok, %{status: :armed, dispatch: row}}` for a new call,
  `{:ok, %{status: :replayed, dispatch: row, outputs: outputs}}` when the same
  call already ran (the first result is returned and nothing runs again),
  `{:ok, %{status: :rearmed, dispatch: row}}` when a previously failed call is
  armed again, and `{:error, reason}` otherwise -- `idempotency_key_reuse`
  when the same key carries different arguments, `platform_function_unknown`
  for a name the compiled catalogue does not know, `platform_function_not_implemented`
  for a name the catalogue declares but has no body yet.
  """
  @spec arm(keyword()) :: {:ok, arm_result()} | {:error, term()}
  def arm(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    tenant_id = Keyword.get(opts, :tenant_id)
    instance_id = Keyword.get(opts, :instance_id)
    definition_id = Keyword.get(opts, :definition_id)
    node_id = Keyword.get(opts, :node_id)
    function = Keyword.get(opts, :function)
    inputs = Keyword.get(opts, :inputs) || %{}

    with {:ok, entry} <- fetch_entry(function),
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

  @doc """
  Claims the row, checks the authority of the call and runs the function.

  The body runs OUTSIDE every transaction this module owns: the claim has
  committed before it starts and the result transaction opens after it
  returned.

  Returns `{:ok, {:advanced, outputs}}` when the function returned its
  outputs, `{:ok, {:already_final, outputs}}` when the row had already run
  (the stored outputs are returned), and `{:error, reason}` otherwise -- the
  reason is the refusal of the authority fence, the code of the function's own
  refusal, or `platform_step_raised` for an unexpected failure (INV-8: the
  step fails, the dispatcher does not crash).
  """
  @spec attempt_dispatch(Ecto.UUID.t(), String.t()) ::
          {:ok, {:advanced, map()}} | {:ok, {:already_final, map() | nil}} | {:error, term()}
  def attempt_dispatch(dispatch_id, prefix) when is_binary(prefix) do
    case claim(dispatch_id, prefix) do
      {:ok, {:already_final, row}} ->
        {:ok, {:already_final, row.outputs}}

      {:ok, {:claimed, row}} ->
        run(row, prefix)

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

  Returns the counts of the cycle. Never raises.
  """
  @spec run_due(String.t(), pos_integer()) :: %{
          claimed: non_neg_integer(),
          advanced: non_neg_integer(),
          failed: non_neg_integer()
        }
  def run_due(prefix, limit \\ @default_batch_size)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    due_ids = due_dispatch_ids(prefix, limit)

    Enum.reduce(
      due_ids,
      %{claimed: 0, advanced: 0, failed: 0},
      fn dispatch_id, acc ->
        result = attempt_dispatch(dispatch_id, prefix)

        case result do
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

  @doc """
  The ids of the rows that are due in `prefix`, oldest first.
  """
  @spec due_dispatch_ids(String.t(), pos_integer()) :: [Ecto.UUID.t()]
  def due_dispatch_ids(prefix, limit \\ @default_batch_size)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
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
  # name present, every value of the declared type.
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

        cond do
          missing -> {:error, :platform_call_arg_missing}
          mistyped -> {:error, :platform_call_arg_invalid}
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

  # The KEY of the call: the function's name and the values of the entry's
  # declared key inputs. A collision is safe -- the fingerprint check below
  # refuses a different call that carries the same key.
  defp call_key(%Entry{name: name, idempotency_key: key_inputs}, inputs) do
    parts =
      Enum.map(key_inputs, fn key ->
        "#{key}=#{Map.get(inputs, key)}"
      end)

    Enum.join([name | parts], "|")
  end

  # The FINGERPRINT of the whole argument set: same key + same fingerprint is
  # the same call; same key + a different fingerprint is a key reuse.
  defp fingerprint(inputs) when is_map(inputs) do
    canonical =
      inputs
      |> Enum.map(fn {name, value} -> {to_string(name), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, value} -> name <> "=" <> encode_value(value) end)

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
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

  defp upsert(prefix, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        case Repo.get_by(StepDispatch, [call_key: attrs.call_key], prefix: prefix) do
          nil ->
            insert_row(prefix, attrs, now)

          existing ->
            handle_existing(prefix, existing, attrs)
        end
      end)

    case result do
      {:ok, {:ok, arm_result}} -> {:ok, arm_result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_row(prefix, attrs, now) do
    row = %StepDispatch{id: Ecto.UUID.generate()}

    row
    |> StepDispatch.arm_changeset(%{
      id: row.id,
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
    |> Repo.insert(prefix: prefix)
    |> case do
      {:ok, inserted} ->
        {:ok, %{status: :armed, dispatch: inserted, outputs: nil}}

      {:error, %Ecto.Changeset{}} ->
        # The unique index on `call_key` fired: another dispatcher armed the
        # same call between the read and the write. The existing row IS this
        # call, so it is read and handled like one.
        case Repo.get_by(StepDispatch, [call_key: attrs.call_key], prefix: prefix) do
          nil -> {:error, :platform_step_arm_failed}
          existing -> handle_existing(prefix, existing, attrs)
        end
    end
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

        %StepDispatch{} = existing ->
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
    end)
  end

  # ── the run (outside every transaction this module owns) ──────────────────────────────

  defp run(row, prefix) do
    with {:ok, definition} <- load_definition(row, prefix),
         :ok <- authorize(definition, row, prefix),
         {:ok, mfa} <- fetch_implementation(row.function_name),
         {:ok, outputs} <- invoke(mfa, row) do
      record_success(row, prefix, outputs)
      {:ok, {:advanced, outputs}}
    else
      {:error, reason} ->
        record_failure(row, prefix, reason)
        {:error, reason}
    end
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

  defp record_success(row, prefix, outputs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row
    |> StepDispatch.terminal_changeset(%{
      status: :advanced,
      outputs: outputs,
      dispatched_at: now
    })
    |> Repo.update(prefix: prefix)
  end

  defp record_failure(row, prefix, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row
    |> StepDispatch.terminal_changeset(%{
      status: :given_up,
      last_failure_kind: to_string(reason),
      dispatched_at: now
    })
    |> Repo.update(prefix: prefix)
  end
end
