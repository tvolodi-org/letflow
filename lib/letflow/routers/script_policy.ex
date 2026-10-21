defmodule Letflow.Routers.ScriptPolicy do
  @moduledoc """
  GH 2534 PR 7b-2a (decision 0053 D5, D7 "Kill switch"; advisor Q3): the tenant's script policy
  routes, mounted at `/script-policy` by `Letflow.Plugs.ApiPipeline`. Design:
  `lib/letflow/design/gh2534-7b2a-script-policy.md` section 9.1.

  | Route | Policy key -> permission |
  |---|---|
  | `GET /` (the kill switch state) | `:ScriptPolicyRead` -> `:ScriptsWrite` |
  | `PUT /kill-switch` (`{on, reason}`, the TENANT latch) | `:ScriptPolicyManage` -> `:ScriptsPublish` |
  | `GET /readable-masters` | `:ScriptPolicyRead` -> `:ScriptsWrite` |
  | `PUT /readable-masters/:entity_type` (`{reason}`) | `:ScriptPolicyManage` -> `:ScriptsPublish` |
  | `POST /readable-masters/:entity_type/clear` (`{reason}`) | `:ScriptPolicyManage` -> `:ScriptsPublish` |
  | `PUT /sod` (`{sod, reason}`, 7b-2b) | `:ScriptPolicyManage` -> `:ScriptsPublish` |
  | `GET /pending-review` (7b-2b) | `:ScriptPolicyRead` -> `:ScriptsWrite` |

  The route keys are distinct from the permissions on purpose (P3): 0051 D11 classifies the
  admin plane by route key; the two `:ScriptPolicyManage` writes are admin-plane, the reads
  tenant-wide (GH #2533 adds the runtime check). The platform latch is not reachable here; it is
  `PUT /tenants/:slug/script-policy/kill-switch` (`Letflow.Routers.Tenants`).

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1); the actor, its credential and
  the trace id only from the DB-resolved `auth_context` and the request's trace id. Every write
  requires an OIDC credential (403 `api_token_not_allowed`, P4). Responses are built by the
  allowlist functions `policy_map/1`, `master_map/1` and the clear map (INV-2); bodies never
  echo submitted values.

  7b-2b (`lib/letflow/design/gh2534-7b2b-script-sod.md` sections 6.1, 6.6, S8): `policy_map/2`
  gains `sod` (declared, effective, effective reason, writer, platform_allowed); no response
  ever carries the tenant-wide admin count or the admin set. `PUT /sod` maps 403
  `not_tenant_wide_admin`, 409 `solo_audited_forbidden` / `multiple_tenant_admins`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Routers.ScriptRules
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ReadableMaster
  alias Letflow.Scripts.ScriptPolicy

  authz_get "/", :ScriptPolicyRead do
    case Policy.get(prefix(conn)) do
      {:ok, policy} -> Response.ok(conn, policy_map(policy, prefix(conn)))
      # A missing policy row is a provisioning defect: never fabricated.
      {:error, :not_found} -> Response.internal_error(conn)
    end
  end

  authz_put "/kill-switch", :ScriptPolicyManage do
    reply(
      conn,
      Policy.set_tenant_kill_switch(
        prefix(conn),
        conn.body_params["on"],
        conn.body_params["reason"],
        actor(conn)
      ),
      &policy_map(&1, prefix(conn))
    )
  end

  authz_put "/sod", :ScriptPolicyManage do
    reply(
      conn,
      Policy.set_sod(
        prefix(conn),
        conn.body_params["sod"],
        conn.body_params["reason"],
        actor(conn)
      ),
      &policy_map(&1, prefix(conn))
    )
  end

  authz_get "/pending-review", :ScriptPolicyRead do
    {rows, truncated} = Policy.pending_review(prefix(conn))

    Response.ok(conn, %{
      "items" => Enum.map(rows, &ScriptRules.summary_map/1),
      "truncated" => truncated
    })
  end

  authz_get "/readable-masters", :ScriptPolicyRead do
    items = prefix(conn) |> Policy.list_readable_masters() |> Enum.map(&master_map/1)
    Response.ok(conn, %{"items" => items})
  end

  authz_put "/readable-masters/:entity_type", :ScriptPolicyManage do
    case Policy.set_readable_master(
           prefix(conn),
           conn.params["entity_type"],
           conn.body_params["reason"],
           actor(conn)
         ) do
      {:ok, :created, master} -> Response.created(conn, master_map(master))
      {:ok, :unchanged, master} -> Response.ok(conn, master_map(master))
      other -> reply(conn, other, &master_map/1)
    end
  end

  authz_post "/readable-masters/:entity_type/clear", :ScriptPolicyManage do
    reply(
      conn,
      Policy.clear_readable_master(
        prefix(conn),
        conn.params["entity_type"],
        conn.body_params["reason"],
        actor(conn)
      ),
      &clear_map/1
    )
  end

  authz_unmatched(:ordinary)

  # ── replies ────────────────────────────────────────────────────────────────

  defp reply(conn, {:ok, value}, builder), do: Response.ok(conn, builder.(value))
  defp reply(conn, {:error, :not_found}, _builder), do: Response.not_found(conn)

  defp reply(conn, {:error, code}, _builder)
       when code in [:api_token_not_allowed, :not_tenant_wide_admin],
       do: Response.forbidden(conn, Atom.to_string(code))

  # 7b-2b: the switch to solo_audited refused by the platform flag or a second admin.
  defp reply(conn, {:error, code}, _builder)
       when code in [:solo_audited_forbidden, :multiple_tenant_admins],
       do: Response.conflict(conn, Atom.to_string(code))

  # :policy_missing: the policy row is absent (provisioning defect), as GET: 500.
  defp reply(conn, {:error, code}, _builder) when code in [:audit_failed, :policy_missing],
    do: Response.internal_error(conn)

  defp reply(conn, {:error, code}, _builder)
       when code in [
              :invalid_reason,
              :invalid_state,
              :unknown_entity_type,
              :entity_type_restricted,
              :too_many_masters
            ],
       do: Response.unprocessable(conn, Atom.to_string(code))

  defp reply(conn, {:error, _unexpected}, _builder), do: Response.internal_error(conn)

  # ── allowlist builders (INV-2) ─────────────────────────────────────────────

  # S8: the effective value and its reason, never the admin count.
  defp policy_map(%ScriptPolicy{} = policy, prefix) do
    {effective, effective_reason} = Policy.effective_sod(prefix, policy)

    %{
      "sod" => %{
        "declared" => Atom.to_string(policy.sod),
        "effective" => Atom.to_string(effective),
        "effective_reason" => Atom.to_string(effective_reason),
        "set_by" => policy.sod_set_by,
        "set_by_class" => policy.sod_set_by_class,
        "set_at" => policy.sod_set_at,
        "reason" => policy.sod_reason,
        "platform_allowed" => policy.platform_solo_audited_allowed
      },
      "kill_switch_on" => ScriptPolicy.effective?(policy),
      "tenant" => %{
        "on" => policy.tenant_kill_switch,
        "set_by" => policy.tenant_kill_switch_set_by,
        "set_at" => policy.tenant_kill_switch_set_at,
        "reason" => policy.tenant_kill_switch_reason
      },
      "platform" => %{
        "on" => policy.platform_kill_switch,
        "set_at" => policy.platform_kill_switch_set_at,
        "reason" => policy.platform_kill_switch_reason
      }
    }
  end

  defp master_map(%ReadableMaster{} = master) do
    %{
      "entity_type" => master.entity_type,
      "set_by" => master.set_by,
      "set_at" => master.set_at,
      "reason" => master.reason
    }
  end

  defp clear_map(%{entity_type: entity_type, referenced_by: refs, referenced_total: total}) do
    %{
      "entity_type" => entity_type,
      "referenced_by" =>
        Enum.map(
          refs,
          &%{"key" => &1.key, "version" => &1.version, "status" => Atom.to_string(&1.status)}
        ),
      "referenced_total" => total
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
