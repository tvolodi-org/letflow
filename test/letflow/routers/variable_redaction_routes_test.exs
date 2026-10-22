defmodule Letflow.Routers.VariableRedactionRoutesTest do
  @moduledoc """
  SR-OPT-3(a) (decision 0062 R8, GH #2616 part 2): a caller without the grant for a restricted
  field sees the placeholder for a labelled instance variable on `GET /instances/:id`,
  `POST /instances/:id/reconstruct` and the `POST /tasks/:id/complete` response. An unlabelled
  variable is clear. A caller with the grant sees the value. `GET /tasks/:id` returns no variables
  and is not a surface here (decision 0062 correction, A4).

  The labelled `total` comes from the script-result seam (part 1), so the restriction row
  `customer.salary` is the only grant-dependent input.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Identity.User
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Support.ScriptTaskFixture, as: F

  @placeholder "__field_redacted__"

  # START -> svc (script: total = 4, labelled customer.salary) -> review (HUMAN_TASK) -> END
  defp graph(key, version) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => key, "script_version" => version}
        },
        %{"id" => "review", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "review"},
        %{"id" => "e3", "source" => "review", "target" => "end"}
      ]
    }
  end

  setup do
    t = F.tenant!("gh2616-routes")

    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: "customer",
          field_name: "salary",
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema_name
    )

    %{t: t}
  end

  defp labelled_review!(t) do
    b =
      F.bound_graph!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2}, &graph/2, [])

    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    result =
      {:ok, %{"total" => 4},
       %{
         row: row,
         phase: :ran,
         outcome: :ok,
         detail: nil,
         fail_code: nil,
         hmac: nil,
         stats: nil,
         output_labels: %{"total" => ["customer.salary"]}
       }}

    assert {:ok, :applied} = Engine.apply_script_task_result(F.claim(row), result, t.schema_name)
    b
  end

  defp insert_user!(t) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "redaction-#{Ecto.UUID.generate()}",
      display_name: "Redaction Route Test User",
      email: "redaction-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: t.schema_name)
  end

  # A user in a group that holds the task's routing role REVIEWER (the assignee of the review).
  defp assignee!(t) do
    user = insert_user!(t)

    group =
      %Group{}
      |> Ecto.Changeset.change(%{name: "redaction-#{Ecto.UUID.generate()}", display_name: "G"})
      |> Repo.insert!(prefix: t.schema_name)

    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group.id, user_id: user.id})
    |> Repo.insert!(prefix: t.schema_name)

    %TenantRole{}
    |> Ecto.Changeset.change(%{name: "REVIEWER", kind: :process_routing_role, group_id: group.id})
    |> Repo.insert!(prefix: t.schema_name)

    user
  end

  defp grant!(t, user) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user.id),
          entity_type: "customer",
          field_name: "salary",
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema_name
    )
  end

  defp conn_for(router, method, path, t, user_id, body \\ nil) do
    conn = conn(method, path)

    conn =
      if body,
        do: %{conn | body_params: body} |> put_req_header("content-type", "application/json"),
        else: conn

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: t.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "redaction-route-trace")
    |> router.call(router.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "a caller without the grant" do
    test "GET /instances/:id shows the placeholder for the labelled variable; the other is clear",
         %{
           t: t
         } do
      b = labelled_review!(t)

      conn =
        conn_for(Letflow.Routers.Instances, :get, "/#{b.instance_id}", t, Ecto.UUID.generate())

      assert conn.status == 200
      assert body(conn)["variables"]["total"] == @placeholder
      assert body(conn)["variables"]["amount"] == 2
    end

    test "POST /instances/:id/reconstruct shows the placeholder", %{t: t} do
      b = labelled_review!(t)

      conn =
        conn_for(
          Letflow.Routers.Instances,
          :post,
          "/#{b.instance_id}/reconstruct",
          t,
          Ecto.UUID.generate()
        )

      assert conn.status == 200
      assert body(conn)["variables"]["total"] == @placeholder
    end

    test "POST /tasks/:id/complete shows the placeholder in the response", %{t: t} do
      b = labelled_review!(t)
      assignee = assignee!(t)

      task =
        Repo.one!(
          from(x in Letflow.Engine.Task,
            where: x.instance_id == ^b.instance_id and x.status == :pending
          ),
          prefix: t.schema_name
        )

      conn = conn_for(Letflow.Routers.Tasks, :post, "/#{task.id}/complete", t, assignee.id, %{})

      assert conn.status == 200
      assert body(conn)["variables"]["total"] == @placeholder
      assert body(conn)["variables"]["amount"] == 2
    end
  end

  describe "a caller with the grant" do
    test "GET /instances/:id shows the value", %{t: t} do
      b = labelled_review!(t)
      viewer = insert_user!(t)
      grant!(t, viewer)

      conn = conn_for(Letflow.Routers.Instances, :get, "/#{b.instance_id}", t, viewer.id)

      assert conn.status == 200
      assert body(conn)["variables"]["total"] == 4
    end
  end
end
