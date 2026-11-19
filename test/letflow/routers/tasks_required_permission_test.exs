defmodule Letflow.Routers.TasksRequiredPermissionTest do
  @moduledoc """
  Decision 0093 F1 / T1-T4: a HUMAN_TASK's pinned `required_permission` is
  enforced on claim and completion in addition to its assignee. Requests use
  real API tokens through the full `Letflow.Router`; no shipped process or
  permission is changed by these fixtures.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Identity
  alias Letflow.SodSupport, as: S

  @required "AuditRead"

  defp graph(role, extra_attributes) do
    attributes =
      Map.merge(
        %{"role" => role, "required_permission" => @required},
        extra_attributes
      )

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        S.human("approval", role, Map.delete(attributes, "role")),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "approval"},
        %{"id" => "e2", "source" => "approval", "target" => "end"}
      ]
    }
  end

  defp case!(role, extra_attributes \\ %{}) do
    ctx = S.new_case!(graph(role, extra_attributes), %{}, %{"seed" => "value"})
    Map.put(ctx, :task, S.pending_task!(ctx, "approval"))
  end

  defp post(ctx, user, roles, task_id, action, body \\ %{}) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    conn(:post, "/api/v1/tasks/#{task_id}/#{action}", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp wire(conn) do
    body = conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")
    {conn.status, get_resp_header(conn, "content-type"), body}
  end

  test "T1/T2: the permission is required before and after reassignment to the caller" do
    ctx = case!("TENANT_ADMIN")
    storekeeper = S.insert_user!(ctx.schema_name, "storekeeper")
    admin = S.insert_user!(ctx.schema_name, "admin")

    # The routing label is satisfied by both users. Only TENANT_ADMIN holds AuditRead.
    :ok = S.grant_role!(ctx.schema_name, "TENANT_ADMIN", [storekeeper.id, admin.id])

    for action <- ["claim", "complete"] do
      conn = post(ctx, storekeeper, ["STOREKEEPER"], ctx.task.id, action)
      assert conn.status == 404, "#{action} before reassignment: #{conn.resp_body}"
    end

    assert S.reload_task!(ctx, ctx.task).assignee_type == "ROLE"
    assert S.reload_task!(ctx, ctx.task).status == :pending

    reassigned =
      post(ctx, admin, ["TENANT_ADMIN"], ctx.task.id, "reassign", %{
        "user_id" => storekeeper.id
      })

    assert reassigned.status == 200, reassigned.resp_body
    assert S.reload_task!(ctx, ctx.task).assignee_type == "USER"
    assert S.reload_task!(ctx, ctx.task).assignee_ref == storekeeper.id

    for action <- ["claim", "complete"] do
      conn = post(ctx, storekeeper, ["STOREKEEPER"], ctx.task.id, action)
      assert conn.status == 404, "#{action} after reassignment: #{conn.resp_body}"
    end

    assert S.reload_task!(ctx, ctx.task).status == :pending
    assert S.reload_task!(ctx, ctx.task).assignee_ref == storekeeper.id
  end

  test "T3: renaming the routing role does not replace the permission check" do
    ctx = case!("STOREKEEPER")
    storekeeper = S.insert_user!(ctx.schema_name, "renamed-storekeeper")
    operator = S.insert_user!(ctx.schema_name, "operator")
    :ok = S.grant_role!(ctx.schema_name, "STOREKEEPER", [storekeeper.id, operator.id])

    for action <- ["claim", "complete"] do
      conn = post(ctx, storekeeper, ["STOREKEEPER"], ctx.task.id, action)
      assert conn.status == 404, "#{action}: #{conn.resp_body}"
    end

    # A holder in a role not named TENANT_ADMIN is allowed when addressing also matches.
    claimed = post(ctx, operator, ["PROCESS_OPERATOR"], ctx.task.id, "claim")
    assert claimed.status == 200, claimed.resp_body

    completed = post(ctx, operator, ["PROCESS_OPERATOR"], ctx.task.id, "complete")
    assert completed.status == 200, completed.resp_body
    assert S.reload_task!(ctx, ctx.task).status == :completed
  end

  test "T4: a holder in tenant B gets tenant A's task and a missing id as the same 404" do
    tenant_a = case!("TENANT_ADMIN")
    tenant_b = S.tenant!()
    admin_b = S.insert_user!(tenant_b.schema_name, "other-tenant-admin")
    missing_id = Ecto.UUID.generate()

    for action <- ["claim", "complete"] do
      missing = post(tenant_b, admin_b, ["TENANT_ADMIN"], missing_id, action)
      foreign = post(tenant_b, admin_b, ["TENANT_ADMIN"], tenant_a.task.id, action)

      assert missing.status == 404

      assert wire(foreign) == wire(missing),
             "#{action}: #{inspect({wire(foreign), wire(missing)})}"

      refute foreign.resp_body =~ tenant_a.task.id
    end

    assert S.reload_task!(tenant_a, tenant_a.task).status == :pending
    assert S.reload_task!(tenant_a, tenant_a.task).assignee_type == "ROLE"
  end

  test "an unreadable pinned permission fails closed for a caller who otherwise holds it" do
    tenant = S.tenant!()
    caller = S.insert_user!(tenant.schema_name, "pinned-caller")

    definition =
      S.activate!(tenant.schema_name, graph(caller.id, %{"assignee_type" => "USER"}), %{})

    instance_id = S.start_instance!(tenant.schema_name, definition, %{"seed" => "value"})

    ctx =
      tenant
      |> Map.merge(%{definition: definition, instance_id: instance_id})
      |> Map.put(
        :task,
        S.pending_task!(%{instance_id: instance_id, schema_name: tenant.schema_name}, "approval")
      )

    invalid_graph =
      put_in(
        definition.graph,
        ["nodes", Access.at(1), "attributes", "required_permission"],
        "NoSuchPermission"
      )

    {1, _} =
      Repo.update_all(
        from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^ctx.instance_id),
        [set: [graph: invalid_graph]],
        prefix: ctx.schema_name
      )

    for action <- ["claim", "complete"] do
      conn = post(ctx, caller, ["TENANT_ADMIN"], ctx.task.id, action)
      assert conn.status == 404, "#{action}: #{conn.resp_body}"
    end

    assert S.reload_task!(ctx, ctx.task).status == :pending
    assert S.reload_task!(ctx, ctx.task).assignee_ref == caller.id
  end
end
