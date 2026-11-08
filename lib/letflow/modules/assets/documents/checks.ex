defmodule Letflow.Modules.Assets.Documents.Checks do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10): the checks of the issue step of an asset document, all reads, no
  write. Mirrors `Letflow.Modules.Stock.Documents.Checks` for the asset kinds. The caller
  (`Letflow.Modules.Assets.Documents.issue/4`) runs both inside the per-tenant advisory lock of the
  issue, so two simultaneous issues of one fixed card cannot both pass `asset_already_in_register`.

  `event_time/2` is pure: the header time may not be more than `max_event_lateness_hours` (96, read
  from the `assets` ledger registration, not a second literal) before the clock nor more than 5
  minutes after it; the boundaries are accepted, one second beyond is refused (`event_time_too_old`,
  `event_time_in_future`).

  `masters/2` runs the master checks in this order and stops at the first failure: the org unit is a
  live active `org_unit` (`org_unit_not_active`); the material responsible and, when given, the actual
  user are active employees (`employee_not_active` with `"field"`); then per line in `line_no` order
  (extras `"line_no"`): the card exists in this tenant and is active (`card_not_active`: unknown,
  retired and another tenant's id are one answer), the asset is not on an earlier line
  (`duplicate_asset`), the quantity is a whole number above zero and exactly 1 for a fixed or
  intangible card (`quantity_invalid`), the card's org unit, when it has one, is the header's (`org_unit_mismatch`), the
  location rule of the card kind (`location_not_allowed` for intangible, `location_required` for fixed
  and low value), the location is active and linked to the org unit (`not_linked`), and a fixed or
  intangible asset is not already in the register (`asset_already_in_register`: another commission
  document that is issued and not reversed holds it). A master retired between this check and the
  posting is not caught until slice L7 (runbook).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents.DocumentVersion
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @future_seconds 300

  @type refusal :: {:error, {String.t(), map()}}

  @doc "The 96-hour window of the `assets` ledger registration, in seconds."
  @spec lateness_seconds() :: pos_integer()
  def lateness_seconds do
    Assets.manifest().ledger["assets"].max_event_lateness_hours * 3600
  end

  @doc "Checks the event time (UTC ISO text) against `now`."
  @spec event_time(String.t(), DateTime.t()) :: :ok | refusal()
  def event_time(text, %DateTime{} = now) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    delta = DateTime.diff(at, now, :second)

    cond do
      delta > @future_seconds -> {:error, {"event_time_in_future", %{}}}
      delta < -lateness_seconds() -> {:error, {"event_time_too_old", %{}}}
      true -> :ok
    end
  end

  @doc "Runs the master checks of `view` (the document map of `Letflow.Modules.Assets.Documents`)."
  @spec masters(String.t(), map()) :: :ok | refusal()
  def masters(prefix, %{kind: "kind_change"} = view),
    do: Letflow.Modules.Assets.Documents.KindChangeChecks.run(prefix, view)

  def masters(prefix, %{kind: kind} = view) when kind in ["change", "handover", "writeoff"],
    do: sided_masters(prefix, Kinds.get(kind), view)

  def masters(prefix, view) do
    with :ok <- org_unit(prefix, view.org_unit_id),
         :ok <- employee(prefix, view.material_responsible_id, "material_responsible_id"),
         :ok <- optional_employee(prefix, view.actual_user_id, "actual_user_id") do
      lines(prefix, view)
    end
  end

  # -- change, handover, write off (GH #3889 / REQ-753, C11) -------------------------------------------
  #
  # `sides_equal` (pure) first, then the org units (from, then to), the employees in header-key order,
  # then per line in `line_no` order: card, duplicate, quantity, then the location rule and the link of
  # each side that has a location. These kinds do not run `org_unit_mismatch` nor
  # `asset_already_in_register` (a posted hand over leaves the card org unit stale until the card sync
  # of part 2; the ledger balance is the arbiter at posting).
  defp sided_masters(prefix, spec, view) do
    header = Kinds.header_of(spec, view)
    {from, to} = Kinds.sides(spec, header)

    with :ok <- sides_equal(spec.kind, from, to),
         :ok <- side_org_unit(prefix, spec, from, :from),
         :ok <- side_org_unit(prefix, spec, to, :to),
         :ok <- side_employees(prefix, spec, from, :from),
         :ok <- side_employees(prefix, spec, to, :to) do
      sided_lines(prefix, spec, view, from, to)
    end
  end

  defp sides_equal("change", from, to) do
    same? =
      from.material_responsible == to.material_responsible and from.actual_user == to.actual_user

    check(not same?, "sides_equal", %{})
  end

  defp sides_equal("handover", from, to) do
    same? = from.org_unit == to.org_unit and from.location == to.location
    check(not same?, "sides_equal", %{})
  end

  defp sides_equal(_kind, _from, _to), do: :ok

  defp side_org_unit(_prefix, _spec, nil, _which), do: :ok

  defp side_org_unit(prefix, spec, side, which) do
    field = Kinds.side_fields(spec, which).org_unit
    extras = if field == "org_unit_id", do: %{}, else: %{"field" => field}

    case org_unit(prefix, side.org_unit) do
      :ok -> :ok
      {:error, {reason, _}} -> {:error, {reason, extras}}
    end
  end

  defp side_employees(_prefix, _spec, nil, _which), do: :ok

  defp side_employees(prefix, spec, side, which) do
    fields = Kinds.side_fields(spec, which)

    with :ok <- employee(prefix, side.material_responsible, fields.material_responsible) do
      optional_employee(prefix, side.actual_user, fields.actual_user)
    end
  end

  defp sided_lines(prefix, spec, view, from, to) do
    view.lines
    |> Enum.sort_by(& &1.line_no)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn line, {:ok, seen} ->
      case sided_line(prefix, spec, line, seen, from, to) do
        :ok -> {:cont, {:ok, MapSet.put(seen, line.asset_id)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = error -> error
    end
  end

  defp sided_line(prefix, spec, line, seen, from, to) do
    extras = %{"line_no" => line.line_no}

    with {:ok, card} <- card(prefix, line.asset_id, extras),
         :ok <- check(not MapSet.member?(seen, line.asset_id), "duplicate_asset", extras),
         :ok <- check(quantity_ok?(card["kind"], line.quantity), "quantity_invalid", extras),
         :ok <- side_place(prefix, card["kind"], spec.kind, :from, from, extras) do
      side_place(prefix, card["kind"], spec.kind, :to, to, extras)
    end
  end

  defp side_place(_prefix, _card_kind, _kind, _which, nil, _extras), do: :ok

  defp side_place(prefix, card_kind, kind, which, side, extras) do
    extras =
      if kind == "handover", do: Map.put(extras, "side", Atom.to_string(which)), else: extras

    with :ok <- location_rule(card_kind, side.location, extras) do
      if is_nil(side.location),
        do: :ok,
        else: check(Locations.linked?(prefix, side.org_unit, side.location), "not_linked", extras)
    end
  end

  @doc false
  @spec org_unit(String.t(), term()) :: :ok | refusal()
  def org_unit(prefix, id) do
    ok? =
      match?({:ok, %{"entity_type" => "org_unit"}}, Org.lookup(prefix, id)) and
        Org.active?(prefix, id)

    check(ok?, "org_unit_not_active", %{})
  end

  @doc false
  @spec employee(String.t(), term(), String.t()) :: :ok | refusal()
  def employee(prefix, id, field),
    do: check(Org.active_employee?(prefix, id), "employee_not_active", %{"field" => field})

  defp optional_employee(_prefix, nil, _field), do: :ok
  defp optional_employee(prefix, id, field), do: employee(prefix, id, field)

  defp lines(prefix, view) do
    view.lines
    |> Enum.sort_by(& &1.line_no)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn line, {:ok, seen} ->
      case line(prefix, view, line, seen) do
        :ok -> {:cont, {:ok, MapSet.put(seen, line.asset_id)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = error -> error
    end
  end

  defp line(prefix, view, line, seen) do
    extras = %{"line_no" => line.line_no}

    with {:ok, card} <- card(prefix, line.asset_id, extras),
         :ok <- check(not MapSet.member?(seen, line.asset_id), "duplicate_asset", extras),
         :ok <- check(quantity_ok?(card["kind"], line.quantity), "quantity_invalid", extras),
         :ok <- check(card["org_unit_id"] in [nil, view.org_unit_id], "org_unit_mismatch", extras),
         :ok <- location_rule(card["kind"], view.location_id, extras),
         :ok <- linked(prefix, view, extras) do
      in_register(prefix, card, line.asset_id, extras)
    end
  end

  defp card(prefix, asset_id, extras) do
    case ReadApi.lookup(prefix, asset_id, ["assets_card"]) do
      {:ok, %{"active" => true} = card} -> {:ok, card}
      _unknown_or_retired -> {:error, {"card_not_active", extras}}
    end
  end

  defp quantity_ok?(kind, quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = q, ""} ->
        whole? = Decimal.equal?(Decimal.round(q, 0), q)
        positive? = Decimal.gt?(q, 0)
        one? = Decimal.equal?(q, 1)
        whole? and positive? and (kind not in ["fixed", "intangible"] or one?)

      _bad ->
        false
    end
  end

  defp location_rule("intangible", location, extras),
    do: check(is_nil(location), "location_not_allowed", extras)

  defp location_rule(_kind, location, extras),
    do: check(not is_nil(location), "location_required", extras)

  defp linked(_prefix, %{location_id: nil}, _extras), do: :ok

  defp linked(prefix, view, extras),
    do: check(Locations.linked?(prefix, view.org_unit_id, view.location_id), "not_linked", extras)

  # A fixed or intangible asset is one unit in the register: another commission document that is
  # issued and not reversed holds it. A draft, a cancelled and a reversed document do not count.
  defp in_register(prefix, %{"kind" => kind}, asset_id, extras)
       when kind in ["fixed", "intangible"] do
    check(not held?(prefix, asset_id), "asset_already_in_register", extras)
  end

  defp in_register(_prefix, _card, _asset_id, _extras), do: :ok

  defp held?(prefix, asset_id) do
    header_ids =
      Repo.all(
        from(l in Latest,
          where:
            l.entity_type == "assets_commission_line" and not l.deleted and
              fragment("?->>'asset_id' = ?", l.field_values, ^asset_id),
          select: fragment("?->>'header_id'", l.field_values)
        ),
        prefix: prefix
      )
      |> Enum.flat_map(fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)
      |> Enum.uniq()

    doc_ids = document_ids(prefix, header_ids)
    issued = issued_ids(prefix, doc_ids)
    marks = Posting.marks(prefix, issued)

    Enum.any?(issued, fn id -> not Map.has_key?(Map.get(marks, id, %{}), "reversed") end)
  end

  defp document_ids(_prefix, []), do: []

  defp document_ids(prefix, header_ids) do
    Repo.all(
      from(h in Latest,
        where:
          h.entity_type == "assets_commission" and not h.deleted and h.record_id in ^header_ids,
        select: fragment("?->>'document_id'", h.field_values)
      ),
      prefix: prefix
    )
    |> Enum.reject(&is_nil/1)
  end

  defp issued_ids(_prefix, []), do: []

  defp issued_ids(prefix, doc_ids) do
    ids =
      Enum.flat_map(doc_ids, fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)

    Repo.all(
      from(v in DocumentVersion,
        where: v.document_id in ^ids and v.status == :issued,
        select: v.document_id
      ),
      prefix: prefix
    )
    |> Enum.uniq()
  end

  defp check(true, _reason, _extras), do: :ok
  defp check(false, reason, extras), do: {:error, {reason, extras}}
end
