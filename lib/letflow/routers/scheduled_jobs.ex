defmodule Letflow.Routers.ScheduledJobs do
  @moduledoc """
  REQ-561 part 2 (GH #3194): the management routes of the tenant-defined scheduled jobs, mounted at
  `/scheduled-jobs` by `Letflow.Plugs.ApiPipeline` over `Letflow.ScheduledJobs`.

  | Route | Handler |
  |---|---|
  | `GET /` | the tenant's jobs |
  | `GET /:id` | one job |
  | `POST /` | create (enabled) |
  | `PATCH /:id` | edit title, variables, interval, anchor, scope node |
  | `POST /:id/enable`, `POST /:id/disable` | switch a job |

  All six routes use the one policy key `:ScheduledJobsManage` (TENANT_ADMIN only).

  ## Feature flag

  `call/2` reads `Letflow.ScheduledJobs.enabled?/0` on every request. While it is false every caller
  gets the pipeline's own not-found, as for an unregistered path, before any permission is looked at:
  a job starts work unattended with a user's authority, so a platform operator opts in.

  ## Not found vs forbidden (INV-5, INV-10)

  `:ScheduledJobsManage` is a concealed key of `Letflow.Plugs.Authorize`: a caller without the
  permission gets the plain 404, never a 403. An absent id, another tenant's id and a missing
  permission are indistinguishable (same status and body).

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1); the path, query and body carry no
  tenant, and a body `tenant_id` is a validation error. The router makes no `Repo` call itself.

  ## Create and enable

  A job cannot start what its owner could not start by hand. Create and enable require an OIDC
  credential (403 `api_token_not_allowed`: the sweep re-checks the creating user), the
  `:InstancesStart` permission (403 `forbidden`) and the start-scope rule of `POST /instances`
  (422 `invalid_scope_node`, the one answer for unknown, retired, out-of-scope and other-tenant
  nodes). Nothing is stored on a refusal. Edits are not re-checked: the sweep re-checks the creating
  user at every run.

  Responses are built by the allowlist `job_map/1` (INV-2): no `tenant_id`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldError
  alias Letflow.ScheduledJobs
  alias Letflow.ScheduledJobs.Job

  def call(conn, opts) do
    if ScheduledJobs.enabled?(), do: super(conn, opts), else: Response.not_found(conn)
  end

  authz_get "/", :ScheduledJobsManage do
    items = conn |> prefix() |> ScheduledJobs.list() |> Enum.map(&job_map/1)
    Response.ok(conn, %{"items" => items})
  end

  authz_get "/:id", :ScheduledJobsManage do
    reply(conn, 200, ScheduledJobs.get(prefix(conn), conn.params["id"]))
  end

  authz_post "/", :ScheduledJobsManage do
    with {:ok, params} <- object_body(conn),
         :ok <- authorize_job_start(conn, Map.get(params, "scope_node_id")) do
      reply(conn, 201, ScheduledJobs.create(prefix(conn), params, actor(conn)))
    else
      other -> refuse(conn, other)
    end
  end

  authz_patch "/:id", :ScheduledJobsManage do
    case object_body(conn) do
      {:ok, params} ->
        reply(
          conn,
          200,
          ScheduledJobs.update(prefix(conn), conn.params["id"], params, actor(conn))
        )

      other ->
        refuse(conn, other)
    end
  end

  authz_post "/:id/enable", :ScheduledJobsManage do
    id = conn.params["id"]

    with {:ok, job} <- ScheduledJobs.get(prefix(conn), id),
         :ok <- authorize_job_start(conn, job.scope_node_id) do
      reply(conn, 200, ScheduledJobs.enable(prefix(conn), id, actor(conn)))
    else
      other -> refuse(conn, other)
    end
  end

  authz_post "/:id/disable", :ScheduledJobsManage do
    reply(conn, 200, ScheduledJobs.disable(prefix(conn), conn.params["id"], actor(conn)))
  end

  authz_unmatched(:ordinary)

  # ── create and enable checks ───────────────────────────────────────────────

  defp authorize_job_start(conn, node_id) do
    with :ok <- oidc_only(conn),
         {:ok, _conn, principal} <- principal(conn),
         :ok <- may_start(principal) do
      authorize_start_scope(conn, node_id)
    end
  end

  defp oidc_only(conn) do
    if Map.get(conn.assigns.auth_context, :credential) == :oidc,
      do: :ok,
      else: {:error, :api_token_not_allowed}
  end

  defp principal(conn) do
    case Scope.principal_from_conn(conn) do
      {:ok, conn, principal} -> {:ok, conn, principal}
      {:error, _no_principal} -> {:error, :forbidden}
    end
  end

  defp may_start(principal) do
    if Authorization.has_permission_in_scope?(
         principal.roles,
         :InstancesStart,
         principal.platform_tenant?
       ),
       do: :ok,
       else: {:error, :forbidden}
  end

  # Same two calls as `authorize_start_scope/2` of `Letflow.Routers.Instances` (REQ-531): a node is
  # checked like a grant in every enforcement mode; no node, nothing is read.
  defp authorize_start_scope(_conn, nil), do: :ok

  defp authorize_start_scope(conn, node_id) when is_binary(node_id) do
    with {:ok, _conn, principal} <- Scope.principal_from_conn(conn),
         {:allow, _why} <- Scope.allowed?(principal, :InstancesStart, {:node, node_id}) do
      :ok
    else
      _denied -> {:error, :invalid_scope_node}
    end
  end

  # A non-string node id is left to `Job.validate/2`, which answers 422 `invalid`.
  defp authorize_start_scope(_conn, _node_id), do: :ok

  # ── replies ────────────────────────────────────────────────────────────────

  defp object_body(%{body_params: %{} = params}) when not is_struct(params), do: {:ok, params}
  defp object_body(_conn), do: {:error, :bad_body}

  defp refuse(conn, {:error, :bad_body}), do: Response.bad_request(conn, "body must be an object")

  defp refuse(conn, {:error, :api_token_not_allowed}),
    do: Response.forbidden(conn, "api_token_not_allowed")

  defp refuse(conn, {:error, :forbidden}),
    do: Response.forbidden(conn, "instances start permission required")

  defp refuse(conn, {:error, :invalid_scope_node}),
    do: Response.unprocessable(conn, "invalid_scope_node")

  defp refuse(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp reply(conn, status, {:ok, %Job{} = job}),
    do: Response.send_json(conn, status, job_map(job))

  defp reply(conn, _status, {:error, :not_found}), do: Response.not_found(conn)

  defp reply(conn, _status, {:error, {:validation, [_ | _] = errors}}),
    do: Response.send_problem(conn, errors |> Enum.map(&field_error/1) |> Validation.problem())

  # {:audit_failed, _} and anything unforeseen: no detail (INV-8).
  defp reply(conn, _status, _other), do: Response.internal_error(conn)

  defp field_error({field, code}) do
    constraint = constraint(code)
    %FieldError{field: to_string(field), constraint: constraint, message: message(constraint)}
  end

  @constraints ~w(required invalid not_utc too_long too_large secret_like not_accepted taken)a

  defp constraint(code) when code in @constraints, do: Atom.to_string(code)
  defp constraint(_code), do: "invalid"

  defp message("required"), do: "field is required"
  defp message("not_utc"), do: "must be a UTC timestamp"
  defp message("too_long"), do: "value is too long"
  defp message("too_large"), do: "value is too large"
  defp message("secret_like"), do: "must not carry secrets"
  defp message("not_accepted"), do: "field is not accepted"
  defp message("taken"), do: "value is already used"
  defp message(_invalid), do: "value is not valid"

  # ── allowlist builder (INV-2) ──────────────────────────────────────────────

  defp job_map(%Job{} = job) do
    %{
      "id" => job.id,
      "key" => job.key,
      "title" => job.title,
      "definition_name" => job.definition_name,
      "variables" => Response.public_variables(job.variables, %{}, MapSet.new()),
      "scope_node_id" => job.scope_node_id,
      "interval_minutes" => job.interval_minutes,
      "anchor_at" => job.anchor_at,
      "enabled" => job.enabled,
      "next_run_at" => job.next_run_at,
      "last_run_at" => job.last_run_at,
      "last_outcome" => job.last_outcome,
      "last_outcome_details" => job.last_outcome_details,
      "consecutive_failures" => job.consecutive_failures,
      "created_by" => job.created_by,
      "inserted_at" => job.inserted_at,
      "updated_at" => job.updated_at
    }
  end

  # ── context ────────────────────────────────────────────────────────────────

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp actor(conn), do: conn.assigns.auth_context.user_id
end
