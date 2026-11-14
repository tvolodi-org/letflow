defmodule Letflow.DataExport do
  @moduledoc """
  Synchronous Data export, S1a-1 (`docs/design/data-export.md`). Requires explicit
  machine mode until readable mode ships. Each installed provider rechecks its
  own read permission and org-unit scope. No rows or secrets enter the audit.

  Each dataset is capped at 10,000 rows, each actor at 10 successful exports in
  600 seconds. Parallel requests may both pass at the window edge. Audit failure
  fails closed. All collections and rendering finish before the audit insert.
  `:data_export_row_cap` and `:data_export_page_limit` are test seams only.
  Balance pages pin posting cutoff; changing tenant timezone during a dated export
  can change the recomputed day boundary between pages.
  """
  import Ecto.Query, only: [from: 2]
  alias Letflow.{Audit, Repo}
  alias Letflow.Audit.Entry
  alias Letflow.DataExport.Render
  alias Letflow.Modules.Installs

  @action "data_export.downloaded"

  @doc "Only installed datasets whose read authority the caller holds."
  def datasets(conn) do
    for {id, provider, _ctx} <- offered(conn) do
      %{
        id: id,
        formats: ~w(xlsx csv json),
        filters: Enum.map(provider.filters(id), fn {key, kind} -> %{key: key, kind: kind} end)
      }
    end
  end

  @doc "Validates the whole request before any data read and audits before releasing bytes."
  def export(conn, body) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
    actor = conn.assigns.auth_context.user_id
    now = DateTime.utc_now()

    with :ok <- validate_body(body),
         :ok <- validate_formats(body["datasets"]),
         {:ok, requests} <- prepare(body["datasets"], offered(conn)),
         false <- rate_limited?(prefix, actor, now),
         {:ok, exports} <- collect_all(requests),
         {:ok, file} <- Render.render(exports, Map.get(body, "lang", "ru"), now),
         {:ok, _entry} <- audit(prefix, actor, body, exports) do
      {:ok, Map.put(file, :truncated, Enum.filter(exports, & &1.truncated) |> Enum.map(& &1.id))}
    else
      true -> {:error, :rate_limited}
      {:error, _} = error -> error
    end
  end

  defp offered(conn) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    for provider <- Application.get_env(:letflow, :data_export_datasets, []),
        Installs.installed?(provider.module_id(), prefix: prefix),
        id <- provider.dataset_ids(),
        {:ok, ctx} <- [provider.authorize(id, conn)],
        do: {id, provider, ctx}
  end

  defp validate_body(body) when is_map(body) and not is_struct(body) do
    entries = Map.get(body, "datasets")

    maximum =
      Application.get_env(:letflow, :data_export_datasets, [])
      |> Enum.flat_map(& &1.dataset_ids())
      |> length()

    valid =
      Enum.all?(Map.keys(body), &(&1 in ~w(datasets ids lang))) and
        body["ids"] == "machine" and Map.get(body, "lang", "ru") in ~w(en ru kk) and
        is_list(entries) and length(entries) in 1..maximum and
        Enum.all?(entries, &valid_entry?/1)

    if valid and length(Enum.uniq_by(entries, & &1["id"])) == length(entries),
      do: :ok,
      else: {:error, :invalid_body}
  end

  defp validate_body(_), do: {:error, :invalid_body}

  defp valid_entry?(entry) when is_map(entry) and not is_struct(entry),
    do:
      Enum.all?(Map.keys(entry), &(&1 in ~w(id format filters))) and
        is_binary(entry["id"]) and Map.has_key?(entry, "format")

  defp valid_entry?(_), do: false

  defp validate_formats(entries) do
    if Enum.all?(entries, &(&1["format"] in ~w(xlsx csv json))),
      do: :ok,
      else: {:error, :invalid_format}
  end

  defp prepare(entries, offered) do
    # Resolve every id before validating any filters; unknown and forbidden are identical.
    if Enum.all?(entries, fn entry -> Enum.any?(offered, &(elem(&1, 0) == entry["id"])) end) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        {id, provider, ctx} = Enum.find(offered, &(elem(&1, 0) == entry["id"]))
        raw = Map.get(entry, "filters", %{})

        case provider.validate_filters(id, raw) do
          {:ok, filters} ->
            {:cont,
             {:ok,
              acc ++
                [
                  %{
                    id: id,
                    provider: provider,
                    ctx: ctx,
                    filters: filters,
                    raw_filters: raw,
                    format: entry["format"]
                  }
                ]}}

          error ->
            {:halt, error}
        end
      end)
    else
      {:error, :dataset_unknown}
    end
  end

  defp collect_all(requests) do
    cap = Application.get_env(:letflow, :data_export_row_cap, 10_000)

    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, acc} ->
      case collect(request.provider, request.id, {request.ctx, request.filters}, cap) do
        {:ok, data} ->
          {:cont,
           {:ok,
            acc ++
              [
                Map.merge(data, %{
                  id: request.id,
                  format: request.format,
                  filters: request.raw_filters,
                  cap: cap,
                  columns: request.provider.columns(request.id)
                })
              ]}}

        error ->
          {:halt, error}
      end
    end)
  end

  @doc false
  def collect(provider, id, {ctx, filters}, cap) when is_integer(cap) and cap > 0,
    do: collect_page(provider, id, ctx, filters, nil, cap, [], [], cap + 1)

  defp collect_page(provider, id, ctx, filters, cursor, left, chunks, meta, budget) do
    with {:ok, page} <- provider.fetch_page(id, ctx, filters, cursor) do
      taken = Enum.take(page.rows, left)
      chunks = [taken | chunks]
      meta = if cursor == nil, do: page.meta, else: merge_meta(meta, page.meta)
      remaining = left - length(taken)
      more = length(page.rows) > length(taken) or page.next != nil

      cond do
        remaining == 0 or page.next == nil or page.next == cursor or budget == 1 ->
          rows = chunks |> Enum.reverse() |> List.flatten()

          {:ok,
           %{
             rows: rows,
             meta: written_meta(meta, rows),
             truncated: more and (remaining == 0 or page.next == cursor or budget == 1)
           }}

        true ->
          collect_page(provider, id, ctx, filters, page.next, remaining, chunks, meta, budget - 1)
      end
    end
  end

  # A cap may cut a movement page (or even a posting's legs). Report only the
  # sequence range actually written, rather than the rest of the fetched page.
  defp written_meta(meta, rows) do
    if List.keymember?(meta, "last_posting_seq", 0) do
      first = List.first(rows)
      last = List.last(rows)

      meta
      |> List.keystore("first_posting_seq", 0, {"first_posting_seq", first && first.posting_seq})
      |> List.keystore("last_posting_seq", 0, {"last_posting_seq", last && last.posting_seq})
    else
      meta
    end
  end

  defp merge_meta(first, later) do
    case List.keyfind(later, "last_posting_seq", 0) do
      {_, n} when not is_nil(n) ->
        List.keystore(first, "last_posting_seq", 0, {"last_posting_seq", n})

      _ ->
        first
    end
  end

  @doc false
  def rate_limited?(prefix, actor_id, now) do
    since = DateTime.add(now, -600, :second)

    Repo.aggregate(
      from(e in Entry,
        where:
          e.action == @action and e.actor_id == ^actor_id and
            e.timestamp > ^since
      ),
      :count,
      :id,
      prefix: prefix
    ) >= 10
  rescue
    _ -> true
  end

  defp audit(prefix, actor, body, exports) do
    Audit.insert_entry(
      Repo,
      %{
        actor_id: actor,
        action: @action,
        resource_type: "data_export",
        resource_id: Ecto.UUID.generate(),
        after_state: %{
          "ids" => "machine",
          "lang" => Map.get(body, "lang", "ru"),
          "datasets" =>
            Enum.map(exports, fn export ->
              %{
                "id" => export.id,
                "format" => export.format,
                "filters" => export.filters,
                "rows" => length(export.rows),
                "truncated" => export.truncated
              }
            end)
        }
      },
      prefix
    )
  rescue
    _ -> {:error, :audit_failed}
  end
end
