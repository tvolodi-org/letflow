defmodule Letflow.Modules.Maintenance.Handlers do
  @moduledoc """
  REQ-897 (CMMS slice 1 part 5, `docs/cmms/scope-draft.md` section 4): the two write handlers of
  module `maintenance`. They are called from the `module_writes` lines of the HUMAN_TASK nodes of
  the pack process `maintenance_work_order`: `record_done` on `maintenance_work` and
  `record_closed` on `maintenance_close`.

  Each handler changes only its own fields of the work order `maintenance_work_order`, through
  `Letflow.Entities.HandlerWrites.update/3`, inside the transaction of the task completion: the
  write commits with the completion or not at all.

    * `record_done` stores `work_done` (the text the technician typed in the task form), `done_by`
      (the completer, the context's actor) and `done_at` (the moment of the completion).
    * `record_closed` stores `closed_by` (the completer) and `closed_at`.

  The manifest's `updates` key names the fields each handler may change, so neither can touch the
  other's fields and neither may touch anything else: `HandlerWrites.update/3` refuses a field
  outside the list with `:update_field_not_allowed`.

  The order id comes from the instance variable `maintenance_order_id`, and the completer's own
  output variables are merged over the instance variables before a handler runs, so a completer
  could name any other order. Therefore each handler first reads the order through
  `HandlerWrites.read/3` (the manifest lists the order type under `reads`) and refuses unless the
  order's own `instance_id` equals the instance of the task being completed (`ctx.instance_id`,
  set by the platform). `record_done` and `record_closed` also refuse an order that is already
  closed (`closed_at` set): a closed order is never changed again.

  The handler is otherwise pure: it holds no repo, starts no process and writes
  no table of its own. The one clock read is the timestamp the field itself means
  (`DateTime.to_iso8601/1`; the platform's own clock module `System` is the one the handler
  purity scan of `test/letflow/entities/handler_writes_callers_test.exs` forbids).

  A refusal is the closed contract of the platform: `{:error, :invalid_arguments}` for an argument
  the handler will not accept (an empty or over-long work text, an id that is not a UUID) and
  `{:error, :not_permitted}` when the platform refuses the write itself.
  """

  alias Letflow.Entities.HandlerWrites

  @type result :: {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}

  @order_type "maintenance_work_order"
  # The form of `maintenance_work` bounds the text: 1 to 2000 characters (the pack's form schema).
  @max_work_done 2000
  @max_work_done_bytes 8_000

  @doc "Stores what was done: the text of the task's `work_done` output, who and when."
  @spec record_done(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def record_done(multi, ctx, %{"order_id" => order_id, "work_done" => work_done})
      when is_binary(order_id) and is_binary(work_done) do
    with {:ok, order_id} <- valid_order_id(order_id),
         {:ok, work_done} <- work_done_text(work_done),
         :ok <- own_open_order(ctx, order_id) do
      update(multi, ctx, order_id, %{
        "work_done" => work_done,
        "done_by" => ctx.actor_id,
        "done_at" => now()
      })
    else
      :error -> {:error, :invalid_arguments}
    end
  end

  def record_done(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  @doc "Stores who closed the order and when."
  @spec record_closed(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def record_closed(multi, ctx, %{"order_id" => order_id}) when is_binary(order_id) do
    with {:ok, order_id} <- valid_order_id(order_id),
         :ok <- own_open_order(ctx, order_id) do
      update(multi, ctx, order_id, %{
        "closed_by" => ctx.actor_id,
        "closed_at" => now()
      })
    else
      :error -> {:error, :invalid_arguments}
    end
  end

  def record_closed(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  # The write target is bound to the order of the completing task's own instance and must still
  # be open. Any other order, an unknown id or a closed order is `:invalid_arguments`, the same
  # answer for all of them (INV-5: no hint whether another order exists).
  defp own_open_order(ctx, order_id) do
    case HandlerWrites.read(ctx, @order_type, order_id) do
      {:ok, %{"instance_id" => instance_id} = order}
      when is_binary(instance_id) and instance_id == ctx.instance_id ->
        if is_nil(Map.get(order, "closed_at")), do: :ok, else: :error

      _other ->
        :error
    end
  end

  # The one write path: the platform re-checks the target, the field allow-list of the
  # registration and the record version, and refuses with its own closed reasons.
  defp update(multi, ctx, record_id, set) do
    command = %{
      entity_type: @order_type,
      record_id: record_id,
      expect: %{},
      set: set
    }

    case HandlerWrites.update(multi, ctx, command) do
      {:ok, multi} -> {:ok, multi}
      {:error, _reason} -> {:error, :not_permitted}
    end
  end

  defp valid_order_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> {:ok, id}
      :error -> :error
    end
  end

  # 1 to 2000 characters, as the form of `maintenance_work` says. The byte cap comes first, so a
  # huge text costs nothing (INV-8).
  defp work_done_text(text) do
    if String.valid?(text) and byte_size(text) <= @max_work_done_bytes and
         String.length(text) in 1..@max_work_done do
      {:ok, text}
    else
      :error
    end
  end

  defp now, do: DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second))
end
