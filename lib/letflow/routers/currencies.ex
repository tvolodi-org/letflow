defmodule Letflow.Routers.Currencies do
  @moduledoc """
  The currency directory routes, mounted at `/currencies` by `Letflow.Plugs.ApiPipeline`
  (REQ-824, GH #4393, design `docs/design/currency-directory.md` section 4).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `GET /` | `:MyAccessRead` (role-agnostic) | `:self_service` (ruling `SEC-824-currencies`) |
  | `PUT /:code` (body `active`, optional `tenant_currency: true`) | `:CurrenciesManage` | `:tenant_wide` |

  Both answer 200 with `tenant_currency` (the code) and `currencies` (`Letflow.Currencies.list/1`,
  each item exactly `code`, `numeric_code`, `minor_units`, `names`, `active`).

  The tenant comes only from the DB-resolved `conn.assigns.scoped_opts` and `auth_context`
  (INV-1); no route takes a tenant identifier and a `tenant_id` in the query or body is never
  read (INV-10). The permission is checked first at `Letflow.Plugs.Authorize`, which does not look
  at the code, so a caller without `:CurrenciesManage` gets the same 403 for a known and an
  unknown code (INV-5). Refusals are 422 with a fixed text per reason (`currency_unknown`,
  `currency_is_tenant_currency`, `invalid_body`); the submitted body is never echoed.
  The platform list is public reference data, not a secret.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Currencies

  authz_get "/", :MyAccessRead, scope: :self_service do
    reply_directory(conn)
  end

  authz_put "/:code", :CurrenciesManage, scope: :tenant_wide do
    case Currencies.switch(prefix(conn), conn.params["code"], body(conn), actor_id(conn)) do
      {:ok, _switched} -> reply_directory(conn)
      other -> reply_error(conn, other)
    end
  end

  authz_unmatched(:ordinary)

  defp reply_directory(conn) do
    prefix = prefix(conn)

    Response.ok(conn, %{
      "tenant_currency" => Currencies.tenant_currency(prefix),
      "currencies" => Enum.map(Currencies.list(prefix), &item/1)
    })
  end

  defp item(entry) do
    %{
      "code" => entry.code,
      "numeric_code" => entry.numeric_code,
      "minor_units" => entry.minor_units,
      "names" => entry.names,
      "active" => entry.active
    }
  end

  # Fixed text per reason: the submitted text is never echoed.
  defp reply_error(conn, {:error, :currency_unknown}),
    do: Response.unprocessable(conn, "currency_unknown")

  defp reply_error(conn, {:error, :currency_is_tenant_currency}),
    do: Response.unprocessable(conn, "currency_is_tenant_currency")

  defp reply_error(conn, {:error, :invalid_body}),
    do: Response.unprocessable(conn, "invalid_body")

  # Anything else (audit failure, concurrent writer, tenant row missing): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp actor_id(conn), do: conn.assigns.auth_context.user_id
end
