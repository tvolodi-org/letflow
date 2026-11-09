defmodule Letflow.Modules.Stock.FreezeGuard do
  @moduledoc """
  REQ-765 / GH #3906 (owner decision D-094): the posting guard of the `stock` ledger registration
  (`posting_guard: {Letflow.Modules.Stock.FreezeGuard, :check}`, REQ-764). The platform calls
  `check/2` inside the completion transaction of every stock posting, under the SHARED hold lock of
  the ledger id, once, with the tenant schema prefix and a neutral summary
  (`ledger_id, cause, document_type, document_id, keys`). The answer is `:ok` or `{:held, label}`; the
  platform turns the label into the refusal `posting_held` (stock alias `location_frozen`, detail
  `held_by`) and writes its own `ledger.posting_held` audit entry.

  A posting is held when at least one of its balance keys is frozen by a count order whose freeze is
  in force (`Letflow.Modules.Stock.FreezeState.active/2`, computed from the data and the clock): the
  key's `org_unit` slot is the order's org unit and its `location` slot is one of the order's frozen
  locations (the pair rule of decision 0079 section 4: stock of another org unit at the same place is
  not frozen). The label is the number of the order's issued `count.order` document. The only
  exemption is the count's own posting: `document_type` `count.differences` and `document_id` the
  order's differences document; another count's differences document on a frozen key stays held.
  The guard writes nothing and takes no lock, reads module-managed types only, and never raises on a
  missing order or row (an order without rows freezes nothing).

  ## Lock order (REQ-765)

  `CountSheet.open/3` of a freeze order: (1) the per-order advisory lock (`CountSheet.lock_order!/2`)
  as the first statement; (2) `Letflow.Ledger.hold_exclusive!/2` on `stock`; (3) the order is re-read
  and the book quantities are read INSIDE the transaction, after (2); (4) the Records writes (lines,
  `count_freeze_location` rows, the order) and the Documents locks; (5) the audit entry. No ledger
  lock is taken. A posting completion takes its entity-type rows, then the shared hold lock, then the
  guard reads (this module), then the ledger lock step. So a posting that passed the guard before the
  open has committed and is inside `cutoff_seq`, and a posting after it reads the freeze. No posting
  handler of the stock registration writes a type that `open/3` writes (their only target is
  `stock_posting_mark`), so the two orders cannot form a cycle. `Counts.cancel/3` takes the order
  lock only.

  ## Test seam

  `Application.get_env(:letflow, :stock_freeze_test_hook)` is `nil` in production. A test sets
  `{:wait, test_pid, point}` to hold a process at one named point (`:open_locked` after the exclusive
  hold in `CountSheet.open/3`, `:guard_checked` after the reads of `check/2`): the process sends
  `{:stock_freeze_hook, point, self()}` to the test and waits for `:go` (continue) or `:fail` (raise,
  so the transaction rolls back), with a bounded timeout. It is read in `hook/1` only, in this module.
  """

  alias Letflow.Modules.Stock.FreezeState

  @hook_timeout 15_000

  @doc "The guard of the `stock` registration (arity 2, REQ-764)."
  @spec check(String.t(), map()) :: :ok | {:held, String.t()}
  def check(prefix, %{ledger_id: "stock", keys: keys} = summary)
      when is_binary(prefix) and is_list(keys) do
    result =
      case FreezeState.active(prefix, DateTime.utc_now()) do
        [] -> :ok
        orders -> first_held(orders, summary)
      end

    hook(:guard_checked)
    result
  end

  def check(_prefix, _summary), do: :ok

  defp first_held(orders, summary) do
    case Enum.find(orders, &(not exempt?(&1, summary) and frozen?(&1, summary.keys))) do
      nil -> :ok
      order -> {:held, label(order)}
    end
  end

  # The count's own posting: its differences document, and only that document.
  defp exempt?(order, summary) do
    summary.document_type == "count.differences" and
      is_binary(order.differences_document_id) and
      summary.document_id == order.differences_document_id
  end

  defp frozen?(order, keys) do
    Enum.any?(keys, fn key ->
      key["org_unit"] == order.org_unit_id and MapSet.member?(order.locations, key["location"])
    end)
  end

  # The platform fails closed on a label outside its pattern; an order without a number cannot be
  # named, so the fallback is the fixed word below (matches the pattern).
  defp label(%{number: number}) when is_binary(number) and number != "", do: number
  defp label(_order), do: "count"

  @doc false
  @spec hook(atom()) :: :ok
  def hook(point) do
    case Application.get_env(:letflow, :stock_freeze_test_hook) do
      {:wait, pid, ^point} when is_pid(pid) ->
        send(pid, {:stock_freeze_hook, point, self()})

        receive do
          :go -> :ok
          :fail -> raise "stock freeze test hook: failure requested at #{point}"
        after
          @hook_timeout -> :ok
        end

      _ ->
        :ok
    end
  end
end
