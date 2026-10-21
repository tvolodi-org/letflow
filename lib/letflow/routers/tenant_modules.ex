defmodule Letflow.Routers.TenantModules do
  @moduledoc """
  REQ-403 — the HTTP half of `docs/migration/decisions/0039-platform-module-solution-layering.md`
  D5's install path. See
  `lib/letflow/design/req403-module-install-route.md` §2 for the full
  design (a CODE-DESIGN-VALIDATOR-approved design), not a fresh design of
  its own.

  Mounted at `/tenant/modules` by `Letflow.Plugs.ApiPipeline` (full path
  `/api/v1/tenant/modules`), the same forwarding shape as the existing
  `forward("/tenant/settings", to: Letflow.Routers.TenantSettings)` line.

  One route: `POST /` (full path `POST /api/v1/tenant/modules`), gated by
  `:ModulesManage` (tenant scope: `TENANT_ADMIN`, and the platform tenant's `PLATFORM_ADMIN`, per the roles matrix).

  Request body (decision 0052 D3, GH 2531; BREAKING since then):
  `{"module_id": "<id>", "rationale": "<non-blank text>"}`. `rationale` is
  REQUIRED for every module, including ones with only `on_install/2`; it is the
  installer's justification, recorded verbatim in the activation trail when the
  module's `on_install/3` activates its entity definitions. Missing, non-string or
  blank answers 422 `rationale is required` and installs nothing; the router never
  synthesises a default.

  Deliberately mounted at `/tenant/modules`, NOT under `/api/v1/modules/`
  (REQ-404's future per-module mount) — so this route can never collide
  with a future module whose catalog id happens to be `install`.

  Delegates to `Letflow.Modules.Installs.install/3`. The `prefix` argument
  comes **only** from `conn.assigns.scoped_opts` (set by
  `Letflow.Plugs.Authorize`, itself derived server-side from
  `conn.assigns.auth_context.tenant_id` via
  `Letflow.Api.Context.scoped_repo_opts/1`) — never from the request body,
  path, or query string (INV-1). Any `tenant_id`/`tenant`/`prefix` key
  present in the JSON body is read by nothing in this router and has no
  effect.

  `actor_id` passed to `install/3` is `conn.assigns.auth_context.user_id`
  (the authenticated caller — same source `Letflow.Routers.TenantSettings`
  and `Letflow.Routers.Me` use for identity, never a body field).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule

  authz_post "/", :ModulesManage do
    handle_install(conn)
  end

  authz_put "/:module_id/settings", :ModulesManage do
    handle_put_settings(conn, conn.params["module_id"])
  end

  authz_unmatched(:ordinary)

  # ── POST /tenant/modules (design §2.3/§2.4) ─────────────────────────────

  @spec handle_install(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_install(%Plug.Conn{body_params: %{"module_id" => module_id}} = conn)
       when is_binary(module_id) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
    actor_id = conn.assigns.auth_context.user_id

    # Decision 0052 D3 (GH 2531): `rationale` is REQUIRED in the body and passed through
    # unchanged; Installs.install/3 is the one place that decides it (missing, non-string
    # or blank -> 422). The router never synthesises one.
    rationale = Map.get(conn.body_params, "rationale")

    case Installs.install(module_id, actor_id, prefix: prefix, rationale: rationale) do
      {:ok, tenant_module} ->
        Response.created(conn, install_response_map(tenant_module))

      {:error, :rationale_required} ->
        Response.unprocessable(conn, "rationale is required")

      {:error, :unknown_module} ->
        Response.not_found(conn)

      {:error, :already_installed} ->
        Response.conflict(conn, "module already installed")

      {:error, {:dependency_not_installed, dep_id}} ->
        Response.unprocessable(conn, "missing dependency: #{dep_id}")

      {:error, :module_install_ddl_failed} ->
        Response.module_install_ddl_failed(conn)

      {:error, {:pack_install_failed, _reason}} ->
        Response.unprocessable(conn, "module installation failed")

      {:error, {:on_install_failed, _reason}} ->
        Response.unprocessable(conn, "module installation failed")

      {:error, %Ecto.Changeset{} = changeset} ->
        Response.unprocessable(conn, changeset_error_message(changeset))
    end
  end

  defp handle_install(conn) do
    Response.unprocessable(conn, "request body must include a string \"module_id\"")
  end

  @spec install_response_map(TenantModule.t()) :: map()
  defp install_response_map(%TenantModule{} = tenant_module) do
    %{
      "module_id" => tenant_module.module_id,
      "version" => tenant_module.version,
      "installed_at" => DateTime.to_iso8601(tenant_module.installed_at)
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

  # ── PUT /:module_id/settings (REQ-414) ──────────────────────────────────

  @spec handle_put_settings(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp handle_put_settings(conn, module_id) when is_binary(module_id) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
    settings = conn.body_params

    case Installs.put_settings(module_id, settings, prefix: prefix) do
      {:ok, tenant_module} ->
        Response.ok(conn, %{"settings" => tenant_module.settings})

      {:error, {:module_not_installed, _}} ->
        Response.not_found(conn)

      {:error, {:settings_validation_failed, failures}} ->
        Response.unprocessable(conn, format_validation_failures(failures))
    end
  end

  defp handle_put_settings(conn, _module_id) do
    Response.not_found(conn)
  end

  @spec format_validation_failures(term()) :: String.t()
  defp format_validation_failures(:no_schema),
    do: "module has no settings_schema; only an empty settings map is accepted"

  defp format_validation_failures(failures) when is_list(failures) do
    failures
    |> Enum.map(fn f -> "#{f.field_path}: #{f.constraint}" end)
    |> Enum.join("; ")
  end

  defp format_validation_failures(other), do: inspect(other)
end
