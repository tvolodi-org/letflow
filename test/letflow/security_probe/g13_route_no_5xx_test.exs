defmodule Letflow.SecurityProbe.G13RouteNo5xxTest do
  @moduledoc """
  G-13, second half: the no-5xx matrix over the mutating routes with a body that
  REACHES a handler, plus the three targeted cases the parser-level matrix
  cannot cover (a SUB_PROCESS child refusal, a start refusal, a malformed
  cursor).

  The parser-level sibling (`g13_malformed_input_matrix_test.exs`) covers the
  shapes the parser itself refuses. This file covers the shapes that get
  through the parser and land in a handler, so the request has to be a real,
  authenticated one: a real tenant, a real TENANT_ADMIN token, the real
  `Letflow.Router`.

  The class (INV-8): a caller's own mistake answers a typed 4xx, never a 5xx
  and never an unhandled error. The verdict is the shared
  `Letflow.Support.G13Matrix.violations/1` -- the same one the parser-level
  matrix and the seeded failing case use.

  `async: false`: the tenant fixture provisions a real schema and the sandbox
  mode is global.
  """

  use Letflow.DataCase, async: false

  @moduletag :security_probe
  @moduletag probe_cost_s: 60

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.G13Matrix
  alias Letflow.TenantFixture

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "g13")
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    {:ok, tenant: tenant, token: plaintext}
  end

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "g13-caller-#{Ecto.UUID.generate()}",
      display_name: "G-13 Caller",
      email: "g13-caller-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp api_conn(method, path, token, slug, body, content_type) do
    conn = Plug.Test.conn(method, path, body)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
    conn = Plug.Conn.put_req_header(conn, "x-tenant-slug", slug)

    case content_type do
      nil -> conn
      type -> Plug.Conn.put_req_header(conn, "content-type", type)
    end
  end

  # The driver of the authenticated matrix: the FULL router, the real path
  # (the pipeline is mounted at /api/v1), the real token and the real tenant.
  defp driver(token, slug) do
    fn route, shape ->
      path = "/api/v1" <> G13Matrix.concrete_path(route.path)

      route.method
      |> String.downcase()
      |> String.to_atom()
      |> api_conn(path, token, slug, shape.body, shape.content_type)
      |> G13Matrix.dispatch(Letflow.Router)
    end
  end

  describe "a body that reaches a handler" do
    test "is never a 5xx on any mutating route", %{tenant: tenant, token: token} do
      routes = G13Matrix.mutating_routes()
      shapes = Enum.filter(G13Matrix.shapes(), &(&1.refusal == :handler))

      assert shapes != [], "the handler-reaching shapes are missing from the shape list"

      outcomes = G13Matrix.run(routes, shapes, driver(token, tenant.tenant.slug))

      violations = for outcome <- outcomes, outcome.violations != [], do: outcome

      assert violations == [],
             """
             #{length(violations)} matrix cell(s) break the no-5xx class:
             #{inspect(Enum.take(violations, 5), pretty: true)}
             """
    end
  end

  describe "a SUB_PROCESS child refusal" do
    test "a parent naming a child definition that does not exist answers 404, not a 500", %{
      tenant: tenant,
      token: token
    } do
      parent = active_definition!(tenant.schema_name, graph_parent_subprocess("no-such-child"))

      response =
        :post
        |> api_conn(
          "/api/v1/instances",
          token,
          tenant.tenant.slug,
          ~s({"definition_id":"#{parent.id}","initial_variables":{}}),
          "application/json"
        )
        |> dispatch()

      assert response.status == 404, inspect(response.resp_body)
      assert response.status < 500
    end

    test "a parent naming a child definition that needs reactivation answers 409, not a 500", %{
      tenant: tenant,
      token: token
    } do
      child = active_definition!(tenant.schema_name, graph_child_two_step())

      mark_needs_reactivation!(tenant.schema_name, child.id)

      parent = active_definition!(tenant.schema_name, graph_parent_subprocess(child.name))

      response =
        :post
        |> api_conn(
          "/api/v1/instances",
          token,
          tenant.tenant.slug,
          ~s({"definition_id":"#{parent.id}","initial_variables":{}}),
          "application/json"
        )
        |> dispatch()

      assert response.status == 409, inspect(response.resp_body)
      assert response.status < 500
    end
  end

  describe "a malformed cursor (the codec fallback)" do
    test "answers a typed 4xx, not a 5xx", %{tenant: tenant, token: token} do
      for cursor <- ["%%%not-base64%%%", "not-a-cursor", "12345678901234567890123456789012"] do
        response =
          :get
          |> api_conn(
            "/api/v1/tasks/inbox?cursor=#{URI.encode_www_form(cursor)}",
            token,
            tenant.tenant.slug,
            nil,
            nil
          )
          |> dispatch()

        assert response.status in [400, 422],
               "cursor #{inspect(cursor)} answered #{response.status}"

        assert response.status < 500
      end
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────────

  defp unique_name(prefix \\ "g13-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name(),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # START -> SUB_PROCESS("sp") -> END, the SUB_PROCESS node naming `child_definition_name`.
  defp graph_parent_subprocess(child_definition_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK("work") -> END: a child that starts and waits.
  defp graph_child_two_step do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "work", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "worker"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "work"},
        %{"id" => "e2", "source" => "work", "target" => "end"}
      ]
    }
  end

  # The reactivation marker the runtime checks at start time (the same pair of
  # columns the reactivation machinery writes: both or neither).
  defp mark_needs_reactivation!(schema_name, definition_id) do
    Repo.update_all(
      from(d in ProcessDefinition, where: d.id == ^definition_id),
      [
        set: [
          needs_reactivation_at: DateTime.utc_now() |> DateTime.truncate(:second),
          needs_reactivation_reason: "g13_probe_fixture"
        ]
      ],
      prefix: schema_name
    )
  end
end
