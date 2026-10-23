defmodule Letflow.Routers.Entities.RecordHistory do
  @moduledoc """
  Record history handler (REQ-516 S2, GH #2701), mounted by Letflow.Routers.Entities at
  `GET /entities/records/:entity_type/:record_id/history` (permission `:EntitiesQuery`).

  The record's create, update and delete events live on its synthetic instance, which the
  Instances routes hide (GH #2702). This route is the one read path to them. Its rules:

    * INV-1: the prefix comes from the auth context and the resolved tenant (`prefix!/1`), never
      from the path or the query string.
    * INV-5: an invalid id, a denied type, a record outside the caller's scope, an absent record
      and a record of another tenant are one 404 (`Response.not_found/1`). Visibility is decided
      before any page parameter is read, so a bad `page_size` cannot tell them apart.
    * INV-2: each item is built by hand. No raw payload, `$ref`, `external_ref` or `_sys` value
      leaves this module, and `record_id` is not repeated (it is the path).
    * Redaction is at read time: `field_values` pass through
      `Letflow.Entities.FieldPolicy.redact_event_payload_with_sets/3` with the caller's CURRENT
      restriction rows and grants. A restriction removed later therefore exposes the values that
      history wrote while it applied (decision 0059 D2; see docs/roles.md).

  The query and the visibility decision live in `Letflow.Entities.RecordHistory`; this module
  holds the HTTP shape only.
  """

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.FieldPolicy
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.RecordHistory
  alias Letflow.Instances

  import Letflow.Routers.Entities.Support

  import Plug.Conn, only: [fetch_query_params: 1]

  @cursor_prefix "RH:"

  @doc false
  def handle_get_record_history(conn, entity_type, raw_record_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesQuery)
    prefix = prefix!(conn)
    user_id = conn.assigns.auth_context.user_id
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         :ok <- RecordHistory.visible?(user_id, entity_type, record_id, scope, prefix),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, after_seq} <- decode_cursor(Map.get(query, "cursor")),
         principal = %{user_id: user_id, prefix: prefix},
         {:ok, sets} <- FieldPolicy.load_sets(principal, [entity_type]),
         {:ok, rows} <-
           RecordHistory.events_page(prefix, entity_type, record_id, after_seq, page_size + 1) do
      {page, next_cursor} = split_page(rows, page_size)
      specs = Definitions.strict_specs(entity_type, prefix)
      names = Instances.actor_display_names(page, opts)

      items = Enum.map(page, &history_item(&1, names, sets, entity_type, specs))
      Response.ok(conn, %{"items" => items, "next_cursor" => next_cursor})
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      :not_found ->
        Response.not_found(conn)

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")

      # A loader error is an internal failure, never a page with unredacted values.
      {:error, :invalid_schema_name} ->
        Response.internal_error(conn)
    end
  end

  # The sequence cursor of this route. Its prefix (`RH:`) differs from the instance history
  # cursor, so a cursor from another endpoint is refused as invalid.
  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @cursor_prefix, byte_size(@cursor_prefix)) do
      {:ok, %Pagination.Cursor{inner: inner}} ->
        case Pagination.decode_seek_parts(inner, @cursor_prefix, [:skip, :int]) do
          {:ok, [seq]} -> {:ok, seq}
          {:error, _invalid} -> {:error, :invalid_cursor}
        end

      {:error, _reason} ->
        {:error, :invalid_cursor}
    end
  end

  defp split_page(rows, page_size) when length(rows) > page_size do
    page = Enum.take(rows, page_size)
    {page, build_next_cursor(List.last(page))}
  end

  defp split_page(rows, _page_size), do: {rows, nil}

  defp build_next_cursor(%{sequence_number: seq}) do
    now_us = System.system_time(:microsecond)

    @cursor_prefix
    |> Pagination.build_raw_cursor(now_us, Integer.to_string(seq))
    |> Pagination.encode_cursor()
  end

  defp history_item(event, display_names, sets, entity_type, specs) do
    payload = FieldPolicy.redact_event_payload_with_sets(sets, entity_type, event.payload)

    %{
      "event_id" => event.event_id,
      "event_type" => event.event_type,
      "sequence_number" => event.sequence_number,
      "created_at" => DateTime.to_iso8601(event.created_at),
      "actor_id" => event.actor_id,
      "actor_display_name" => Map.get(display_names, event.actor_id),
      "entity_def_version" => Map.get(payload, "entity_def_version")
    }
    |> put_field_values(payload, specs)
  end

  # The delete event carries no `field_values`, so its item has none either.
  defp put_field_values(item, %{"field_values" => field_values}, specs),
    do: Map.put(item, "field_values", Decimals.render_field_values(field_values, specs))

  defp put_field_values(item, _payload, _specs), do: item
end
