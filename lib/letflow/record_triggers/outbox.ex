defmodule Letflow.RecordTriggers.Outbox do
  @moduledoc """
  REQ-606 slice T-2 part 1 (GH #3411, decision 0067 D1/D2/D4) -- the same-transaction insert of a
  record trigger. When `Letflow.RecordTriggers.enabled?/0` is true, `Letflow.Entities.Records` adds
  one `Ecto.Multi` step (`:enqueue_trigger`, `{:line, i, :enqueue_trigger}` for `command_multi/3`)
  to every record write. `run/4` is its body: it reads the active binding of (entity type, event)
  and inserts one `pending` row of `record_trigger_outbox`, or suppresses the trigger (audit entry
  `trigger_loop_suppressed` and a telemetry event) when the lineage says so.

  With the flag off the step is not added at all: nothing reads the binding table or the outbox.

  **Lock position** (decision 0061 item 5b): the step sits after the sequence assignment and the
  number allocation and before the hook audit and the record write. It reads bindings with a plain
  SELECT, inserts a row with a fresh id, takes no lock on an existing row, and only then (on a
  suppression) reaches the audit-chain lock (item 6). A replay fails at `:idempotency` and a version
  conflict at `:check_record_version`, both before this step, so neither inserts a row.

  **Lineage** (D4) comes only from the `:trigger_lineage` option of the 4-arity write functions of
  `Records`, never from `attrs`, a request or a field value; a root write has none (depth 0, empty
  chain). A binding is suppressed when its id is already in the chain, or when `depth + 1` exceeds
  the cap (`:record_trigger_depth_cap`, default 3, application config only). Counter: the telemetry
  event `[:letflow, :record_triggers, :loop_suppressed]` (`%{count: 1}`, metadata `%{reason: ...}`,
  no tenant, binding or record id).

  Tenant scope: every `Repo` call passes `prefix: ctx.prefix`; the table has no `tenant_id` column
  (decision 0006 D2). A failure of the step is rescued and returned as `{:error,
  :trigger_enqueue_failed}`, which rolls the write back (INV-8); only the exception module is logged
  (INV-4). Part 2 adds the backlog count and cap at the top of the insert.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.RecordTriggers.Binding
  alias Letflow.RecordTriggers.OutboxRow

  require Logger

  @default_depth_cap 3
  @events %{create: :created, update: :updated, delete: :deleted}

  @type lineage :: %{depth: non_neg_integer(), chain: [binary()]}

  @doc "The step body. `changes` must hold `:assign_sequence` (for a line, the line's own view)."
  @spec run(module(), map(), map(), binary() | nil) ::
          {:ok, %{inserted: non_neg_integer(), suppressed: non_neg_integer()}}
          | {:error, :trigger_enqueue_failed}
  def run(repo, changes, ctx, actor_id) do
    enqueue(repo, changes, ctx, actor_id)
  rescue
    exception ->
      Logger.error("record trigger enqueue failed: #{inspect(exception.__struct__)}")
      {:error, :trigger_enqueue_failed}
  end

  defp enqueue(repo, changes, ctx, actor_id) do
    event = Map.fetch!(@events, ctx.kind)
    entity_type = ctx.entity_type
    prefix = ctx.prefix

    bindings =
      repo.all(
        from(b in Binding,
          where: b.entity_type == ^entity_type and b.event == ^event and b.status == :active,
          order_by: b.id
        ),
        prefix: prefix
      )

    lineage = Map.get(ctx, :trigger_lineage)

    {rows, suppressed} =
      bindings
      |> Enum.map(&decide(&1, lineage))
      |> Enum.split_with(&match?({:insert, _, _}, &1))

    Enum.each(rows, fn {:insert, binding, {depth, chain}} ->
      occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      repo.insert!(
        %OutboxRow{
          id: Ecto.UUID.generate(),
          binding_id: binding.id,
          entity_type: entity_type,
          record_id: ctx.record_id,
          event: event,
          source_seq: changes.assign_sequence,
          occurred_at: occurred_at,
          script_key: binding.script_key,
          script_version: binding.script_version,
          script_sha256: binding.script_sha256,
          depth: depth,
          chain: chain,
          actor_id: actor_id,
          status: :pending,
          attempt: 0,
          next_attempt_at: occurred_at
        },
        prefix: prefix
      )
    end)

    # Audit entries after every row insert: the outbox insert precedes the first audit-chain lock.
    Enum.each(suppressed, fn {:suppress, binding, depth, reason} ->
      suppress!(repo, binding, depth, reason, actor_id, prefix)
    end)

    {:ok, %{inserted: length(rows), suppressed: length(suppressed)}}
  end

  defp decide(binding, lineage) do
    {depth, chain} =
      case lineage do
        nil -> {0, []}
        %{depth: d, chain: c} -> {d + 1, c}
      end

    cond do
      binding.id in chain -> {:suppress, binding, depth, "in_chain"}
      depth > depth_cap() -> {:suppress, binding, depth, "depth_cap"}
      true -> {:insert, binding, {depth, chain}}
    end
  end

  defp suppress!(repo, binding, depth, reason, actor_id, prefix) do
    {:ok, _entry} =
      Audit.insert_entry(
        repo,
        %{
          actor_id: actor_id,
          action: "trigger_loop_suppressed",
          resource_type: "record_trigger_binding",
          resource_id: binding.id,
          before_state: nil,
          after_state: %{"binding_id" => binding.id, "depth" => depth, "reason" => reason}
        },
        prefix
      )

    :telemetry.execute([:letflow, :record_triggers, :loop_suppressed], %{count: 1}, %{
      reason: reason
    })
  end

  @doc """
  Validates the `:trigger_lineage` option: `nil`, or `%{depth: non_neg_integer, chain: [uuid]}`
  (chain ids are normalised to lower-case UUID strings). Anything else raises `ArgumentError`: it is
  a programmer error of the 4-arity caller, never reachable from a request.
  """
  @spec parse_lineage!(term()) :: nil | lineage()
  def parse_lineage!(nil), do: nil

  def parse_lineage!(%{depth: depth, chain: chain} = lineage)
      when is_integer(depth) and depth >= 0 and is_list(chain) do
    normalised =
      Enum.map(chain, fn id ->
        with true <- is_binary(id), {:ok, uuid} <- Ecto.UUID.cast(id) do
          uuid
        else
          _ -> raise ArgumentError, "invalid trigger_lineage: #{inspect(lineage)}"
        end
      end)

    %{depth: depth, chain: normalised}
  end

  def parse_lineage!(other),
    do: raise(ArgumentError, "invalid trigger_lineage: #{inspect(other)}")

  @doc false
  @spec depth_cap() :: pos_integer()
  def depth_cap do
    case Application.get_env(:letflow, :record_trigger_depth_cap, @default_depth_cap) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> @default_depth_cap
    end
  end
end
