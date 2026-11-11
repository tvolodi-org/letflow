defmodule Letflow.Routers.InstancesParticipantReadTest do
  @moduledoc """
  GH #2932 (QA: a dispatcher who is neither the starter nor holds a task role of the instance read
  a driver's incident text through `GET /instances/:id` and `/history`).

  A task-worker-only caller reads the variables and event payloads of an instance only when it
  started it or holds a task of it; any other instance answers the ordinary 404. Operators keep the
  tenant-wide read. Real HTTP through `Letflow.Router`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @secret "Jonas Weber reported two damaged pallets"

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "pr-#{Ecto.UUID.generate()}",
      display_name: "Participant Test User",
      email: "pr-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp token!(user, tenant, role) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [role], expires_at: nil},
        prefix: tenant.schema_name
      )

    plaintext
  end

  defp setup_tenant! do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2932",
        display_name: "GH2932 Participant Read Tenant"
      )

    prefix = tenant.schema_name
    starter = insert_user!(tenant)
    holder = insert_user!(tenant)
    outsider = insert_user!(tenant)
    operator = insert_user!(tenant)

    group =
      Repo.insert!(%Group{name: "approvers-#{System.unique_integer([:positive])}"},
        prefix: prefix
      )

    Repo.insert!(%GroupMember{group_id: group.id, user_id: holder.id}, prefix: prefix)

    Repo.insert!(
      %TenantRole{name: "approver", group_id: group.id, kind: :process_routing_role},
      prefix: prefix
    )

    {:ok, definition} =
      Definitions.create(
        %{
          name: "gh2932-def-" <> to_string(System.unique_integer([:positive])),
          version: "1.0.0",
          graph: %{
            "nodes" => [
              %{"id" => "start", "node_type" => "START"},
              %{
                "id" => "task",
                "node_type" => "HUMAN_TASK",
                "attributes" => %{"role" => "approver"}
              },
              %{"id" => "end", "node_type" => "END"}
            ],
            "edges" => [
              %{"id" => "e1", "source" => "start", "target" => "task"},
              %{"id" => "e2", "source" => "task", "target" => "end"}
            ]
          },
          created_by: Ecto.UUID.generate()
        },
        prefix: prefix
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: prefix)

    {:ok, result} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{"description" => @secret},
          actor_id: starter.id,
          idempotency_key: "start-" <> to_string(System.unique_integer([:positive]))
        },
        prefix: prefix
      )

    %{
      slug: tenant.tenant.slug,
      instance_id: result.instance_id,
      tokens: %{
        starter: token!(starter, tenant, "TASK_WORKER"),
        holder: token!(holder, tenant, "TASK_WORKER"),
        outsider: token!(outsider, tenant, "TASK_WORKER"),
        operator: token!(operator, tenant, "PROCESS_OPERATOR")
      }
    }
  end

  defp get(ctx, who, path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> Map.fetch!(ctx.tokens, who))
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  test "G1: an uninvolved task worker gets 404 on GET /instances/:id and /history, no text leaks" do
    ctx = setup_tenant!()

    for suffix <- ["", "/history"] do
      resp = get(ctx, :outsider, "/api/v1/instances/#{ctx.instance_id}#{suffix}")
      assert resp.status == 404
      refute resp.resp_body =~ "Jonas"
    end
  end

  test "G2: the 404 for an uninvolved worker equals the 404 for a nonexistent id" do
    ctx = setup_tenant!()
    real = get(ctx, :outsider, "/api/v1/instances/#{ctx.instance_id}")
    fake = get(ctx, :outsider, "/api/v1/instances/#{Ecto.UUID.generate()}")
    assert real.status == fake.status
  end

  test "G3: the starter reads the instance and its history" do
    ctx = setup_tenant!()

    for suffix <- ["", "/history"] do
      resp = get(ctx, :starter, "/api/v1/instances/#{ctx.instance_id}#{suffix}")
      assert resp.status == 200
      assert resp.resp_body =~ "Jonas"
    end
  end

  test "G4: a holder of the task's routing role reads the instance and its history" do
    ctx = setup_tenant!()

    for suffix <- ["", "/history"] do
      assert get(ctx, :holder, "/api/v1/instances/#{ctx.instance_id}#{suffix}").status == 200
    end
  end

  test "G5: a process operator keeps the tenant-wide read" do
    ctx = setup_tenant!()

    for suffix <- ["", "/history"] do
      assert get(ctx, :operator, "/api/v1/instances/#{ctx.instance_id}#{suffix}").status == 200
    end
  end

  test "G6: the timeline follows the same participation rule as the history (T-1693, OWASP A01)" do
    ctx = setup_tenant!()
    path = "/api/v1/instances/#{ctx.instance_id}/timeline"

    outsider = get(ctx, :outsider, path)
    fake = get(ctx, :outsider, "/api/v1/instances/#{Ecto.UUID.generate()}/timeline")
    assert outsider.status == 404
    assert outsider.status == fake.status
    strip = fn conn -> Regex.replace(~r/"trace_id":"[^"]*"/, conn.resp_body, "") end
    assert strip.(outsider) == strip.(fake)

    for who <- [:starter, :holder, :operator] do
      assert get(ctx, who, path).status == 200
    end
  end

  test "G7: pins follow the same participation rule as the timeline (F4-6, OWASP A01)" do
    ctx = setup_tenant!()
    path = "/api/v1/instances/#{ctx.instance_id}/pins"

    outsider = get(ctx, :outsider, path)
    fake = get(ctx, :outsider, "/api/v1/instances/#{Ecto.UUID.generate()}/pins")
    assert outsider.status == 404
    assert outsider.status == fake.status
    strip = fn conn -> Regex.replace(~r/"trace_id":"[^"]*"/, conn.resp_body, "") end
    assert strip.(outsider) == strip.(fake)

    for who <- [:starter, :holder, :operator] do
      assert get(ctx, who, path).status == 200
    end
  end
end
