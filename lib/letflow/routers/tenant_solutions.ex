defmodule Letflow.Routers.TenantSolutions do
  @moduledoc """
  REQ-415 — the solution-install HTTP route.

  Mounted at `/tenant/solutions` by `Letflow.Plugs.ApiPipeline` (full path
  `POST /api/v1/tenant/solutions`). Follows the same shape as
  `Letflow.Routers.TenantModules`: a single `authz_post` route gated by
  `:ModulesManage` (tenant scope: `TENANT_ADMIN`, and the platform tenant's `PLATFORM_ADMIN`), delegating to
  `Letflow.Modules.Solutions.install/3`.

  Request body (decision 0052 D3, GH 2531; BREAKING since then):
  `{"solution_id": "<id>", "rationale": "<non-blank text>"}`. ONE required
  rationale, applied to every module the solution installs. Missing, non-string or
  blank answers 422 `rationale is required` and installs nothing; never synthesised.

  Tenant scoping (INV-1): `prefix` comes ONLY from
  `conn.assigns.scoped_opts` (set by `Letflow.Plugs.Authorize`, itself
  derived server-side from `conn.assigns.auth_context.tenant_id` via
  `Letflow.Api.Context.scoped_repo_opts/1`) — never from the request body,
  path, or query string. Any `tenant_id`/`prefix` key present in the JSON
  body is ignored.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Modules.Solutions
  alias Letflow.Modules.TenantModule

  authz_post "/", :ModulesManage do
    handle_install(conn)
  end

  authz_unmatched(:ordinary)

  # ── POST /tenant/solutions ─────────────────────────────────────────────────

  @spec handle_install(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_install(%Plug.Conn{body_params: %{"solution_id" => solution_id}} = conn)
       when is_binary(solution_id) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
    actor_id = conn.assigns.auth_context.user_id

    # Decision 0052 D3 (GH 2531): one REQUIRED `rationale` for the whole solution, applied
    # to every module install; decided by Solutions.install/3 (missing, non-string or
    # blank -> 422, nothing installed). The router never synthesises one.
    rationale = Map.get(conn.body_params, "rationale")

    case Solutions.install(solution_id, actor_id, prefix: prefix, rationale: rationale) do
      {:error, :rationale_required} ->
        Response.unprocessable(conn, "rationale is required")

      {:ok, tenant_modules} ->
        Response.created(conn, %{
          "installed_modules" => Enum.map(tenant_modules, &module_response_map/1)
        })

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, {:unknown_module, _}} ->
        Response.not_found(conn)

      {:error, {:version_mismatch, _, _, _}} ->
        Response.not_found(conn)

      {:error, {:already_installed, _module_id}} ->
        Response.conflict(conn, "one or more modules in this solution are already installed")

      {:error, :unknown_module} ->
        Response.unprocessable(conn, "unknown module")

      {:error, :already_installed} ->
        Response.conflict(conn, "module already installed")

      {:error, {:dependency_not_installed, dep_id}} ->
        Response.unprocessable(conn, "missing dependency: #{dep_id}")

      {:error, :module_install_ddl_failed} ->
        Response.module_install_ddl_failed(conn)

      {:error, {:pack_install_failed, _}} ->
        Response.unprocessable(conn, "module installation failed")

      {:error, {:on_install_failed, _}} ->
        Response.unprocessable(conn, "module installation failed")

      {:error, %Ecto.Changeset{} = changeset} ->
        Response.unprocessable(conn, changeset_error_message(changeset))
    end
  end

  defp handle_install(conn) do
    Response.unprocessable(conn, "request body must include a string \"solution_id\"")
  end

  @spec module_response_map(TenantModule.t()) :: map()
  defp module_response_map(%TenantModule{} = tm) do
    %{
      "module_id" => tm.module_id,
      "version" => tm.version,
      "installed_at" => DateTime.to_iso8601(tm.installed_at)
    }
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> case do
      [] -> "validation failed"
      messages -> Enum.join(messages, "; ")
    end
  end
end
