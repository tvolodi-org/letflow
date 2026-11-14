defmodule Letflow.Modules.Assets.DocumentPrintSource do
  @moduledoc """
  T-1915 / GH #4443 (official forms audit D4): the impure side of the printed asset document.
  `read/3` checks, in this order and with nothing built before all pass: the document exists in the
  caller's tenant (`Documents.fetch/2`, the read behind `GET /documents/:id`), its kind is
  commission, change, hand over or write-off, its derived state is issued, posted or reversed, then
  reads the ISSUED version content (never the live header and line records) and the names.

  Isolation: the tenant is the `prefix` of the token only (INV-1); an unknown, malformed,
  discarded or other-tenant id is `{:error, :not_found}` (INV-5). Every read below takes `prefix`.
  Name reads are one indexed read per distinct id (a document has at most 100 lines). A time zone
  offset is one bound-parameter statement per instant (INV-7).

  The small zone, offset and issued-version reads are copies of the stock count paperwork ones:
  `core-extraction-design.md` section 2 says "down, never sideways", so assets does not call
  `Letflow.Modules.Stock.*`; moving them into the core is a follow-up slice.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents, as: CoreDocuments
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Identity
  alias Letflow.Identity.TenantTimezone
  alias Letflow.Modules.Assets.Documents
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @kinds DocumentPrint.kinds()
  @issued_states ["issued", "posted", "reversed"]

  @spec read(String.t(), term(), term()) ::
          {:ok, %{issued: map(), names: map()}}
          | {:error, :not_found | :print_not_available | :document_not_issued}
  def read(prefix, id, tenant_id) when is_binary(prefix) do
    with {:ok, view} <- Documents.fetch(prefix, id),
         :ok <- check_kind(view.kind),
         :ok <- check_state(view.state),
         {:ok, issued} <- issued(prefix, view.id) do
      {:ok, %{issued: issued, names: names(prefix, issued, tenant_id)}}
    end
  end

  defp check_kind(kind) when kind in @kinds, do: :ok
  defp check_kind(_), do: {:error, :print_not_available}

  defp check_state(state) when state in @issued_states, do: :ok
  defp check_state(_), do: {:error, :document_not_issued}

  defp issued(prefix, doc_id) do
    with {:ok, summary} <- CoreDocuments.issued_summary(prefix, doc_id),
         %DocumentVersion{content: %{} = content} <- version(prefix, doc_id, summary.version_no),
         true <- content["kind"] in @kinds do
      {:ok, Map.put(summary, :content, content)}
    else
      _ -> {:error, :document_not_issued}
    end
  end

  defp version(prefix, doc_id, version_no) do
    with {:ok, id} <- Ecto.UUID.cast(doc_id) do
      Repo.one(
        from(v in DocumentVersion,
          join: d in Document,
          on: d.id == v.document_id,
          where: d.id == ^id and v.version_no == ^version_no and v.status == :issued,
          select: v
        ),
        prefix: prefix
      )
    else
      _ -> nil
    end
  end

  # -- names ----------------------------------------------------------------------------------

  defp names(prefix, issued, tenant_id) do
    header = map(issued.content["header"])
    lines = lines(issued.content)
    zone = zone(tenant_id)
    header_ids = fn keys -> Enum.map(keys, &header[&1]) end

    %{
      timezone: zone,
      offsets: %{
        issued_at: offset(zone, issued[:issued_at]),
        event_time: offset(zone, header["event_time"])
      },
      org_units:
        header_ids.(~w(org_unit_id to_org_unit_id))
        |> resolve(&named(Org.lookup(prefix, &1))),
      locations:
        header_ids.(~w(location_id from_location_id to_location_id))
        |> resolve(&named(Locations.lookup(prefix, &1))),
      employees:
        header_ids.(
          ~w(material_responsible_id actual_user_id from_material_responsible_id from_actual_user_id to_material_responsible_id to_actual_user_id)
        )
        |> resolve(&employee(prefix, &1)),
      cards: lines |> Enum.map(& &1["asset_id"]) |> resolve(&card(prefix, &1))
    }
  end

  defp map(%{} = m), do: m
  defp map(_), do: %{}

  defp lines(content) do
    case content["lines"] do
      l when is_list(l) -> Enum.filter(l, &is_map/1)
      _ -> []
    end
  end

  defp resolve(ids, fun) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, fun.(id)} end)
  end

  defp named({:ok, r}), do: %{code: r["code"], name: r["name"]}
  defp named(_), do: nil

  defp employee(prefix, id) do
    case Org.lookup(prefix, id) do
      {:ok, r} -> %{full_name: r["full_name"], code: r["code"]}
      _ -> nil
    end
  end

  defp card(prefix, id) do
    case ReadApi.lookup(prefix, id, ["assets_card"]) do
      {:ok, r} -> %{inventory_number: r["inventory_number"], name: r["name"]}
      _ -> nil
    end
  end

  # -- time zone ------------------------------------------------------------------------------

  defp zone(tenant_id) do
    with {:ok, tenant} <- Identity.get_tenant(tenant_id),
         name = TenantTimezone.of(tenant),
         true <- TenantTimezone.known_zone?(name) do
      name
    else
      _ -> TenantTimezone.default()
    end
  end

  defp offset(zone, value) do
    with {:ok, at} <- instant(value),
         {:ok, %{rows: [[seconds]]}} when is_integer(seconds) <-
           Repo.query(
             "SELECT EXTRACT(EPOCH FROM ($1::timestamptz AT TIME ZONE $2) - ($1::timestamptz AT TIME ZONE 'UTC'))::int",
             [at, zone]
           ) do
      seconds
    else
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp instant(%DateTime{} = dt), do: {:ok, dt}

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp instant(_), do: :error
end
