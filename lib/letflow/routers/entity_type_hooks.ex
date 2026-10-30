defmodule Letflow.Routers.EntityTypeHooks do
  @moduledoc """
  REQ-567 slice E-1 part 2 (GH #3217, decision 0065 D4, D7): the entity pre-write hook binding
  routes, mounted at `/entity-type-hooks` by `Letflow.Plugs.ApiPipeline` over
  `Letflow.EntityTypeHooks`.

  | Route | Policy key | Permission |
  |---|---|---|
  | `GET /` (the tenant's bindings) | `:EntityTypeHooksList` | `:ScriptsWrite` |
  | `PUT /:entity_type` (bind; rebind with body `"rebind": true`) | `:EntityTypeHooksManage` | `:ScriptsPublish` |
  | `DELETE /:entity_type` (unbind) | `:EntityTypeHooksManage` | `:ScriptsPublish` |
  | `POST /:entity_type/dry-run` (run the bound script on a draft, writes no record; REQ-633) | `:EntityTypeHooksDryRun` | `:ScriptsWrite` |

  The dry-run body is exactly `{"candidate": {...}}`; anything else answers 422 `invalid_input`
  before any lookup. A script outcome (also a failed one) is a plain 200 with `outcome`. Each call
  that reaches the runner appends one `entity_write_hook.dry_run` audit row (a call refused with
  403, 404 or 422 appends none); a row that cannot be written answers 500 with no detail.

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1); the path, query and body carry no
  tenant. Every write requires an OIDC credential (403 `api_token_not_allowed`). An absent type,
  another tenant's type, and an unbind or rebind of an unbound type all answer the same plain 404
  (INV-5, INV-10). Responses are built by the allowlist `binding_map/1` (INV-2): no source and no
  manifest.

  Refusal statuses (decision 0065 leaves them open): 403 `api_token_not_allowed`,
  `entity_type_managed`; 404 not found; 422 `invalid_input`, `script_not_found`,
  `hook_kind_mismatch`; 409 `script_not_published`, `sha_mismatch`, `already_bound`,
  `entity_type_hooked`; 500 for a failed transaction, with no detail.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.EntityTypeHooks
  alias Letflow.EntityTypeHooks.Binding

  authz_get "/", :EntityTypeHooksList do
    items = conn |> prefix() |> EntityTypeHooks.list() |> Enum.map(&binding_map/1)
    Response.ok(conn, %{"items" => items})
  end

  authz_put "/:entity_type", :EntityTypeHooksManage do
    case conn.body_params do
      %{"rebind" => true} = params ->
        reply(conn, 200, rebind(conn, Map.delete(params, "rebind")))

      %{"rebind" => value} when value != false ->
        Response.unprocessable(conn, "invalid_input")

      params ->
        reply(conn, 201, bind(conn, Map.delete(params, "rebind")))
    end
  end

  authz_delete "/:entity_type", :EntityTypeHooksManage do
    case EntityTypeHooks.unbind(prefix(conn), conn.params["entity_type"], actor(conn)) do
      {:ok, _binding} -> Response.no_content(conn)
      other -> reply(conn, 200, other)
    end
  end

  authz_post "/:entity_type/dry-run", :EntityTypeHooksDryRun do
    case candidate(conn.body_params) do
      {:ok, candidate} ->
        conn
        |> prefix()
        |> EntityTypeHooks.dry_run(conn.params["entity_type"], candidate, actor(conn))
        |> dry_run_reply(conn)

      :error ->
        Response.unprocessable(conn, "invalid_input")
    end
  end

  authz_unmatched(:ordinary)

  defp bind(conn, params),
    do: EntityTypeHooks.bind(prefix(conn), conn.params["entity_type"], params, actor(conn))

  defp rebind(conn, params),
    do: EntityTypeHooks.rebind(prefix(conn), conn.params["entity_type"], params, actor(conn))

  # ── replies ────────────────────────────────────────────────────────────────

  defp reply(conn, status, {:ok, %Binding{} = binding}),
    do: Response.send_json(conn, status, binding_map(binding))

  defp reply(conn, _status, {:error, :not_found}), do: Response.not_found(conn)

  defp reply(conn, _status, {:error, :api_token_not_allowed}),
    do: Response.forbidden(conn, "api_token_not_allowed")

  defp reply(conn, _status, {:error, :entity_type_managed}),
    do: Response.send_problem(conn, Error.entity_type_managed())

  defp reply(conn, _status, {:error, code})
       when code in [:invalid_input, :script_not_found, :hook_kind_mismatch],
       do: Response.unprocessable(conn, Atom.to_string(code))

  defp reply(conn, _status, {:error, code})
       when code in [:script_not_published, :sha_mismatch, :already_bound, :entity_type_hooked],
       do: Response.conflict(conn, Atom.to_string(code))

  # {:transaction_failed, _} and anything unforeseen: no detail, no exception text (INV-4, INV-8).
  defp reply(conn, _status, _other), do: Response.internal_error(conn)

  # ── allowlist builder (INV-2) ──────────────────────────────────────────────

  defp binding_map(%Binding{} = binding) do
    %{
      "entity_type" => binding.entity_type,
      "script_key" => binding.script_key,
      "script_version" => binding.script_version,
      "script_sha256" => binding.script_sha256,
      "bound_at" => binding.inserted_at,
      "updated_at" => binding.updated_at,
      "bound_by" => binding.bound_by
    }
  end

  # ── dry-run (REQ-633) ──────────────────────────────────────────────────────

  # Body is exactly `{"candidate": {...}}`; validation needs no lookup, so it comes first.
  defp candidate(%{"candidate" => candidate} = body)
       when map_size(body) == 1 and is_map(candidate),
       do: {:ok, candidate}

  defp candidate(_body), do: :error

  defp dry_run_reply({:ok, result}, conn), do: Response.ok(conn, dry_run_map(result))
  defp dry_run_reply({:error, :not_found}, conn), do: Response.not_found(conn)

  defp dry_run_reply({:error, :api_token_not_allowed}, conn),
    do: Response.forbidden(conn, "api_token_not_allowed")

  defp dry_run_reply(_other, conn), do: Response.internal_error(conn)

  # Allowlist (INV-2): `derived` only on success, `fail_code` only for a failed script.
  defp dry_run_map(result) do
    base = %{
      "outcome" => result.outcome,
      "stats" => %{
        "instructions_used" => result.stats[:instructions_used],
        "heap_words_at_end" => result.stats[:heap_words_at_end],
        "duration_us" => result.stats[:duration_us]
      }
    }

    case result do
      %{outcome: "ok", derived: derived} -> Map.put(base, "derived", derived)
      %{outcome: "script_failed", fail_code: code} -> Map.put(base, "fail_code", code)
      _other -> base
    end
  end

  # ── context ────────────────────────────────────────────────────────────────

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp actor(conn) do
    context = conn.assigns.auth_context

    %{
      user_id: context.user_id,
      credential: Map.get(context, :credential),
      trace_id: conn.assigns[:trace_id]
    }
  end
end
