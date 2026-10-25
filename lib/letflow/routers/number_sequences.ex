defmodule Letflow.Routers.NumberSequences do
  @moduledoc """
  The tenant number sequence definition routes, mounted at `/number-sequences` by
  `Letflow.Plugs.ApiPipeline` (REQ-575, GH #3263).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `POST /` (body `key`, `entity_type`, `prefix`, `padding`, `period`) | `:NumberSequencesManage` | `:tenant_wide` |
  | `GET /` | `:NumberSequencesManage` | `:tenant_wide` |

  `POST /` answers 201 with the definition, `GET /` 200 `{"items": [...]}` ordered by key (an empty
  list when the tenant has none). The response carries no `tenant_id` and no counter.

  The tenant comes only from the DB-resolved `auth_context` and `conn.assigns.scoped_opts`
  (INV-1); no route takes a tenant identifier, the body is reduced to the five definition keys
  before it reaches the context, and a `tenant_id` in the body or query is never read (INV-10).
  The permission is checked first at `Letflow.Plugs.Authorize`, before the body is looked at, so
  a caller without `:NumberSequencesManage` gets the same 403 for a valid and an invalid POST
  (INV-5). A refusal is a 422 with a fixed text that echoes no submitted value and writes neither
  a definition nor an audit entry.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.NumberSequences

  @definition_keys ~w(key entity_type prefix padding period)

  authz_post "/", :NumberSequencesManage, scope: :tenant_wide do
    attrs = Map.take(body(conn), @definition_keys)
    actor = %{user_id: actor_id(conn), trace_id: conn.assigns[:trace_id]}

    case NumberSequences.create_definition_audited(attrs, actor, prefix(conn)) do
      {:ok, definition} -> Response.created(conn, render(definition))
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_get "/", :NumberSequencesManage, scope: :tenant_wide do
    items = prefix(conn) |> NumberSequences.list_definitions() |> Enum.map(&render/1)
    Response.ok(conn, %{"items" => items})
  end

  authz_unmatched(:ordinary)

  # Fixed text per reason. One text for a managed, append-only or unknown type, so the answer
  # does not reveal whether a type exists.
  defp error(conn, %Ecto.Changeset{}),
    do: Response.unprocessable(conn, "invalid number sequence definition")

  defp error(conn, :entity_type_managed), do: type_error(conn)
  defp error(conn, {:entity_append_only, _type}), do: type_error(conn)
  defp error(conn, {:entity_type_not_found, _type}), do: type_error(conn)

  # Anything else (transaction failure, tenant lookup): the detail-free 500 (INV-8).
  defp error(conn, _other), do: Response.internal_error(conn)

  defp type_error(conn), do: Response.unprocessable(conn, "entity type cannot be numbered")

  defp render(d) do
    %{
      "id" => d.id,
      "key" => d.key,
      "entity_type" => d.entity_type,
      "prefix" => d.prefix,
      "padding" => d.padding,
      "period" => d.period,
      "inserted_at" => d.inserted_at
    }
  end

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp actor_id(conn), do: conn.assigns.auth_context.user_id
end
