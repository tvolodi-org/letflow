defmodule Letflow.Routers.RecordTriggerBindings do
  @moduledoc """
  REQ-570 slice T-1 part 2 (GH #3248, decision 0067 D9): the record trigger binding routes, mounted
  at `/record-trigger-bindings` by `Letflow.Plugs.ApiPipeline` over `Letflow.RecordTriggers`.

  | Route | Policy key | Permission |
  |---|---|---|
  | `GET /` (the tenant's bindings) | `:RecordTriggerBindingsList` | `:ScriptsWrite` |
  | `PUT /:entity_type/:event` (bind; rebind with body `"rebind": true`) | `:RecordTriggerBindingsManage` | `:ScriptsPublish` |
  | `DELETE /:entity_type/:event` (unbind) | `:RecordTriggerBindingsManage` | `:ScriptsPublish` |

  ## Feature flag

  `call/2` reads `Letflow.RecordTriggers.enabled?/0` on every request. While it is false every caller
  gets the pipeline's own not-found, as for an unregistered path, before any permission is looked at.
  This router is the only caller of `enabled?/0`.

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1); the path, query and body carry no
  tenant. Every write requires an OIDC credential (403 `api_token_not_allowed`). An absent type,
  another tenant's type, and an unbind or rebind of an unbound pair all answer the same plain 404
  (INV-5, INV-10). Responses are built by the allowlist `binding_map/1` (INV-2): no source, no
  manifest, no tenant id.

  Refusal statuses (decision 0067 leaves them open): 403 `api_token_not_allowed`,
  `entity_type_managed`; 404 not found; 422 `invalid_input`, `script_not_found`,
  `hook_kind_mismatch`, `write_target_invalid`, `write_field_forbidden`,
  `write_restriction_widened`; 409 `script_not_published`, `sha_mismatch`, `already_bound`; 500 for
  a failed transaction, with no detail.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.RecordTriggers
  alias Letflow.RecordTriggers.Binding

  def call(conn, opts) do
    if RecordTriggers.enabled?(), do: super(conn, opts), else: Response.not_found(conn)
  end

  authz_get "/", :RecordTriggerBindingsList do
    items = conn |> prefix() |> RecordTriggers.list() |> Enum.map(&binding_map/1)
    Response.ok(conn, %{"items" => items})
  end

  authz_put "/:entity_type/:event", :RecordTriggerBindingsManage do
    case conn.body_params do
      %{"rebind" => true} = params ->
        reply(conn, 200, rebind(conn, Map.delete(params, "rebind")))

      %{"rebind" => value} when value != false ->
        Response.unprocessable(conn, "invalid_input")

      params ->
        reply(conn, 201, bind(conn, Map.delete(params, "rebind")))
    end
  end

  authz_delete "/:entity_type/:event", :RecordTriggerBindingsManage do
    result =
      RecordTriggers.unbind(
        prefix(conn),
        conn.params["entity_type"],
        conn.params["event"],
        actor(conn)
      )

    case result do
      {:ok, _binding} -> Response.no_content(conn)
      other -> reply(conn, 200, other)
    end
  end

  authz_unmatched(:ordinary)

  defp bind(conn, params) do
    RecordTriggers.bind(
      prefix(conn),
      conn.params["entity_type"],
      conn.params["event"],
      params,
      actor(conn)
    )
  end

  defp rebind(conn, params) do
    RecordTriggers.rebind(
      prefix(conn),
      conn.params["entity_type"],
      conn.params["event"],
      params,
      actor(conn)
    )
  end

  # ── replies ────────────────────────────────────────────────────────────────

  defp reply(conn, status, {:ok, %Binding{} = binding}),
    do: Response.send_json(conn, status, binding_map(binding))

  defp reply(conn, _status, {:error, :not_found}), do: Response.not_found(conn)

  defp reply(conn, _status, {:error, :api_token_not_allowed}),
    do: Response.forbidden(conn, "api_token_not_allowed")

  defp reply(conn, _status, {:error, :entity_type_managed}),
    do: Response.send_problem(conn, Error.entity_type_managed())

  defp reply(conn, _status, {:error, code})
       when code in [
              :invalid_input,
              :script_not_found,
              :hook_kind_mismatch,
              :write_target_invalid,
              :write_field_forbidden,
              :write_restriction_widened
            ],
       do: Response.unprocessable(conn, Atom.to_string(code))

  defp reply(conn, _status, {:error, code})
       when code in [:script_not_published, :sha_mismatch, :already_bound],
       do: Response.conflict(conn, Atom.to_string(code))

  # {:transaction_failed, _} and anything unforeseen: no detail, no exception text (INV-4, INV-8).
  defp reply(conn, _status, _other), do: Response.internal_error(conn)

  # ── allowlist builder (INV-2) ──────────────────────────────────────────────

  defp binding_map(%Binding{} = binding) do
    %{
      "entity_type" => binding.entity_type,
      "event" => Atom.to_string(binding.event),
      "script_key" => binding.script_key,
      "script_version" => binding.script_version,
      "script_sha256" => binding.script_sha256,
      "status" => Atom.to_string(binding.status),
      "bound_at" => binding.inserted_at,
      "updated_at" => binding.updated_at,
      "bound_by" => binding.bound_by
    }
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
