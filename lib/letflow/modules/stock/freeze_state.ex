defmodule Letflow.Modules.Stock.FreezeState do
  @moduledoc """
  REQ-765 / GH #3906 (owner decision D-094, assets phase B counts K9b): the state of the freeze of a
  count order in freeze mode, computed from the data and never from the stored value.

  The state of an order header is `{state, reason}`:

    * `{"none", nil}`: the flag `freeze_locations` is not `true`, or the freeze never started (the
      count was not opened);
    * `{"ended", "cancelled"}`: the order is `cancelled` (cancel wins over everything else);
    * `{"ended", "posted"}`: a `posted` mark exists for the order's differences document (the mark
      commits in the transaction of the ledger entry, so the end is atomic with the posting);
    * `{"expired", "expired"}`: the clock is at or after `freeze_until`;
    * `{"active", nil}`: otherwise.

  The clock is the `now` argument of `state/3`, so the limit is tested with explicit instants; every
  caller passes `DateTime.utc_now/0`. The stored fields (`freeze_state`, `freeze_ended_at`,
  `freeze_end_reason`) are written by `Letflow.Modules.Stock.Counts.cancel/3` at once and, for posted
  and expired, by the first count write after the end (`settle/4`); a late stored value never changes
  what is refused: the guard calls `active/2`, which reads the data. Because an end is final (a posted
  mark is never removed, a cancelled order never reopens, time only moves on), `active/2` skips the
  headers whose stored state is already `ended` or `expired`.

  Every query takes the tenant schema `prefix:` (INV-1); text is compared with text.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @default_limit 120

  @doc "The default time limit of a freeze in minutes (module setting `count_freeze_limit_minutes` absent)."
  @spec default_limit_minutes() :: pos_integer()
  def default_limit_minutes, do: @default_limit

  @doc """
  The freeze limit in minutes: the `count_freeze_limit_minutes` setting of the active `stock` install
  of `prefix`, 120 when the setting is absent, invalid or the module is not installed.
  """
  @spec limit_minutes(String.t()) :: pos_integer()
  def limit_minutes(prefix) when is_binary(prefix) do
    case Repo.get_by(TenantModule, [module_id: "stock", status: :active], prefix: prefix) do
      %TenantModule{settings: %{"count_freeze_limit_minutes" => m}}
      when is_integer(m) and m >= 1 and m <= 5760 ->
        m

      _ ->
        @default_limit
    end
  end

  @doc "The state of a `count_order` header at `now`; `posted?` is whether its differences document has a posted mark."
  @spec state(map(), DateTime.t(), boolean()) :: {String.t(), String.t() | nil}
  def state(header, %DateTime{} = now, posted?) when is_map(header) do
    cond do
      header["freeze_locations"] != true or not present?(header["freeze_started_at"]) ->
        {"none", nil}

      header["status"] == "cancelled" ->
        {"ended", "cancelled"}

      posted? ->
        {"ended", "posted"}

      expired?(header["freeze_until"], now) ->
        {"expired", "expired"}

      true ->
        {"active", nil}
    end
  end

  # A freeze whose limit cannot be read is treated as expired: it must never freeze for ever.
  defp expired?(until, now) do
    case is_binary(until) && DateTime.from_iso8601(until) do
      {:ok, at, _offset} -> DateTime.compare(now, at) != :lt
      _ -> true
    end
  end

  defp present?(v), do: is_binary(v) and v != ""

  @doc "Whether the differences document of the header has a `posted` mark."
  @spec posted?(String.t(), map()) :: boolean()
  def posted?(prefix, header) do
    case header["differences_document_id"] do
      id when is_binary(id) and id != "" ->
        prefix |> Posting.marks([id]) |> Map.get(id, %{}) |> Map.has_key?("posted")

      _ ->
        false
    end
  end

  @doc "The state of a header read from the data at `now` (looks up the posted mark only for a freeze order)."
  @spec state_of(String.t(), map(), DateTime.t()) :: {String.t(), String.t() | nil}
  def state_of(prefix, header, now) do
    posted? =
      header["freeze_locations"] == true and present?(header["freeze_started_at"]) and
        header["status"] != "cancelled" and posted?(prefix, header)

    state(header, now, posted?)
  end

  @doc "The six freeze fields of an order view (times are the stored ISO 8601 UTC strings or nil)."
  @spec view_fields(String.t(), map(), DateTime.t()) :: map()
  def view_fields(prefix, header, now) do
    {state, reason} = state_of(prefix, header, now)

    %{
      "freeze_locations" => header["freeze_locations"] == true,
      "freeze_state" => state,
      "freeze_started_at" => header["freeze_started_at"],
      "freeze_until" => header["freeze_until"],
      "freeze_ended_at" => ended_at(state, header),
      "freeze_end_reason" => reason
    }
  end

  # The stored end time when the stored state caught up; before that, nil (the read stays honest
  # about what was recorded; the state and the reason are computed).
  defp ended_at("none", _header), do: nil
  defp ended_at("active", _header), do: nil
  defp ended_at(_state, header), do: header["freeze_ended_at"]

  @doc """
  The orders whose freeze is in force at `now`, each `%{order_id, org_unit_id, number, differences_document_id,
  freeze_until, locations}` (`locations` a `MapSet` of location ids), sorted by `number`. Two queries
  for the headers and their rows, one more for the posted marks; none when no order has the flag.
  """
  @spec active(String.t(), DateTime.t()) :: [map()]
  def active(prefix, %DateTime{} = now) when is_binary(prefix) do
    headers =
      from(l in Latest,
        where:
          l.entity_type == "count_order" and l.deleted == false and
            fragment("?->>'freeze_locations' = 'true'", l.field_values) and
            fragment("coalesce(?->>'freeze_started_at', '') <> ''", l.field_values) and
            fragment("?->>'status' <> 'cancelled'", l.field_values) and
            fragment(
              "coalesce(?->>'freeze_state', '') not in ('ended', 'expired')",
              l.field_values
            ),
        select: {l.record_id, l.field_values}
      )
      |> Repo.all(prefix: prefix)
      |> Enum.map(fn {rid, fv} -> Map.put(fv, "record_id", rid) end)

    case headers do
      [] -> []
      _ -> active_of(prefix, headers, now)
    end
  end

  defp active_of(prefix, headers, now) do
    diff_ids =
      headers
      |> Enum.map(& &1["differences_document_id"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    marks = Posting.marks(prefix, diff_ids)

    live =
      Enum.filter(headers, fn h ->
        posted? =
          h["differences_document_id"]
          |> then(&Map.get(marks, &1, %{}))
          |> Map.has_key?("posted")

        match?({"active", _}, state(h, now, posted?))
      end)

    ids = Enum.map(live, & &1["record_id"])
    locations = frozen_rows(prefix, ids)

    live
    |> Enum.map(fn h ->
      %{
        order_id: h["record_id"],
        org_unit_id: h["org_unit_id"],
        number: h["number"],
        differences_document_id: h["differences_document_id"],
        freeze_until: h["freeze_until"],
        locations: Map.get(locations, h["record_id"], MapSet.new())
      }
    end)
    |> Enum.sort_by(&{&1.number || "", &1.order_id})
  end

  defp frozen_rows(_prefix, []), do: %{}

  defp frozen_rows(prefix, ids) do
    from(l in Latest,
      where:
        l.entity_type == "count_freeze_location" and l.deleted == false and
          fragment(
            "?->>'count_order_id' = ANY(?)",
            l.field_values,
            type(^ids, {:array, :string})
          ),
      select: {
        fragment("?->>'count_order_id'", l.field_values),
        fragment("?->>'location_id'", l.field_values)
      }
    )
    |> Repo.all(prefix: prefix)
    |> Enum.reduce(%{}, fn {order, loc}, acc ->
      Map.update(acc, order, MapSet.new([loc]), &MapSet.put(&1, loc))
    end)
  end

  @doc """
  Stores the end of a freeze that the data already shows (posted or expired) on the fresh header and
  writes exactly one audit entry; called inside a count write transaction, under the order lock, so
  two writes cannot both audit. `write` stores the merged field values of the header
  (`(map -> {:ok, _} | {:error, term})`). Returns `:settled` when it wrote, `:unchanged` when the
  stored state already caught up or the freeze is not over, `{:error, reason}` on a failed write.
  """
  @spec settle(String.t(), String.t(), map(), (map() -> {:ok, term()} | {:error, term()})) ::
          :settled | :unchanged | {:error, term()}
  def settle(prefix, actor, header, write) do
    now = DateTime.utc_now()

    case state_of(prefix, header, now) do
      {state, reason} when reason in ["posted", "expired"] ->
        if header["freeze_state"] in ["ended", "expired"] do
          :unchanged
        else
          fv =
            header
            |> Map.drop(["record_id", "entity_type"])
            |> Map.merge(%{
              "freeze_state" => state,
              "freeze_ended_at" => iso(now),
              "freeze_end_reason" => reason
            })

          with {:ok, _} <- write.(fv),
               :ok <- audit(prefix, actor, audit_action(state), header, reason) do
            :settled
          end
        end

      _ ->
        :unchanged
    end
  end

  defp audit_action("expired"), do: "freeze_expired"
  defp audit_action("ended"), do: "freeze_ended"

  @doc "Writes one freeze audit entry (`stock.count.freeze_started|freeze_ended|freeze_expired`): ids, times and counts, no quantity."
  @spec audit(String.t(), String.t(), String.t(), map(), String.t() | nil, map()) ::
          :ok | {:error, :audit_failed}
  def audit(prefix, actor, action, header, reason, extra \\ %{}) do
    entry = %{
      actor_id: actor,
      action: "stock.count." <> action,
      resource_type: "count_order",
      resource_id: header["record_id"],
      before_state: nil,
      after_state:
        Map.merge(
          %{
            "status" => header["status"],
            "reason" => reason,
            "freeze_until" => header["freeze_until"]
          },
          extra
        )
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  @doc "ISO 8601 UTC text of an instant, second precision."
  @spec iso(DateTime.t()) :: String.t()
  def iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
