defmodule Letflow.Definitions.DefinitionTestCasesActivationTest do
  @moduledoc """
  T-2604 (the "Register a tenant" pilot, gap G16): the AUTOMATIC TEST RUN
  BEFORE AN ACTIVATION -- a definition version may carry declared test cases,
  and a version whose declared case FAILS may not be activated.

  The guardrail is the third of the three D-176 guardrails the pilot needs
  before business users change processes on their own ("nobody reviews
  scripts, so safety must be mechanical"); the first two are G14 (the channel
  allow-list) and G15 (the actor in the definition audit). It is listed in
  D-179 (c) as part of the authority rule.

  This file proves the fence at the CONTEXT level (the version stays DRAFT and
  nothing is switched on) and at the ROUTE level (the refusal reaches the
  caller as a typed 422, never a 500 -- INV-8).

  `async: false`: tenant provisioning and the migration replay need
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])

  setup do
    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t2604-cases")}
  end

  defp build_conn(method, path, tenant, fields) do
    roles = Map.get(fields, :roles, [])
    user_id = Map.get(fields, :user_id, Ecto.UUID.generate())
    body = Map.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  defp unique_name(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> HUMAN_TASK `task` -> END
  defp minimal_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # A case that HOLDS: the human task is completed and the run ends.
  defp passing_case do
    %{
      "name" => "the applicant is approved",
      "complete_tasks" => [%{"node_id" => "task", "outputs" => %{"approved" => true}}],
      "expect" => %{
        "status" => "completed",
        "variables" => %{"approved" => true},
        "visited_nodes" => ["start", "task", "end"]
      }
    }
  end

  # A case that FAILS: the run ends, but the variable does not hold.
  defp failing_case do
    %{
      "name" => "the applicant is approved",
      "complete_tasks" => [%{"node_id" => "task", "outputs" => %{"approved" => true}}],
      "expect" => %{"variables" => %{"approved" => false}}
    }
  end

  defp create_definition!(schema_name, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: unique_name("t2604-def"),
          version: "1.0.0",
          graph: minimal_graph(),
          created_by: Ecto.UUID.generate()
        },
        overrides
      )

    assert {:ok, %ProcessDefinition{} = definition} =
             Definitions.create(attrs, prefix: schema_name)

    definition
  end

  describe "the activation fence (context level)" do
    test "a version whose declared case FAILS is not activated", ctx do
      draft = create_definition!(ctx.tenant.schema_name, %{test_cases: [failing_case()]})

      assert {:error, {:definition_test_cases_failed, [failure]}} =
               Definitions.activate(draft.id, prefix: ctx.tenant.schema_name)

      assert %{name: "the applicant is approved", reason: :variable_mismatch, key: "approved"} =
               failure

      row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
      assert row.status == :draft
      assert row.activated_by == nil
    end

    test "a version whose declared case HOLDS is activated", ctx do
      draft = create_definition!(ctx.tenant.schema_name, %{test_cases: [passing_case()]})

      assert {:ok, %{definition: activated, already_active: false}} =
               Definitions.activate(draft.id, prefix: ctx.tenant.schema_name)

      assert activated.status == :active
    end

    test "a version that declares NO case is activated exactly as before", ctx do
      draft = create_definition!(ctx.tenant.schema_name)

      assert {:ok, %{definition: activated}} =
               Definitions.activate(draft.id, prefix: ctx.tenant.schema_name)

      assert activated.status == :active
      assert activated.test_cases == nil
    end

    test "a malformed declaration is refused by the write, and no row is written", ctx do
      assert {:error, {:invalid_test_cases, :expect_required}} =
               Definitions.create(
                 %{
                   name: unique_name("t2604-bad"),
                   version: "1.0.0",
                   graph: minimal_graph(),
                   created_by: Ecto.UUID.generate(),
                   test_cases: [%{"name" => "no expectation"}]
                 },
                 prefix: ctx.tenant.schema_name
               )

      rows =
        ProcessDefinition
        |> where([d], d.name == "t2604-bad")
        |> Repo.all(prefix: ctx.tenant.schema_name)

      assert rows == []
    end
  end

  describe "the refusal reaches the caller (route level)" do
    test "POST /:id/activate answers 422 with the case and a closed reason", ctx do
      draft = create_definition!(ctx.tenant.schema_name, %{test_cases: [failing_case()]})

      conn =
        build_conn("POST", "/#{draft.id}/activate", ctx.tenant, %{roles: ["PROCESS_DESIGNER"]})
        |> dispatch()

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "definition_test_cases_failed"

      assert [failure] = body["failures"]
      assert failure["name"] == "the applicant is approved"
      assert failure["reason"] == "variable_mismatch"
      assert failure["key"] == "approved"

      row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
      assert row.status == :draft
    end

    test "POST /:id/activate answers 200 when the declared case holds", ctx do
      draft = create_definition!(ctx.tenant.schema_name, %{test_cases: [passing_case()]})

      conn =
        build_conn("POST", "/#{draft.id}/activate", ctx.tenant, %{roles: ["PROCESS_DESIGNER"]})
        |> dispatch()

      assert conn.status == 200
      row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
      assert row.status == :active
    end

    test "POST / answers 422 for a malformed declaration", ctx do
      body = %{
        "name" => unique_name("t2604-create"),
        "version" => "1.0.0",
        "graph" => minimal_graph(),
        "test_cases" => [%{"name" => "no expectation"}]
      }

      conn =
        build_conn("POST", "/", ctx.tenant, %{roles: ["PROCESS_DESIGNER"], body: body})
        |> dispatch()

      assert conn.status == 422
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] == "definition_test_cases_invalid"
      assert decoded["reason"] == "expect_required"
    end

    test "POST / keeps the declared cases and answers them back", ctx do
      body = %{
        "name" => unique_name("t2604-create"),
        "version" => "1.0.0",
        "graph" => minimal_graph(),
        "test_cases" => [passing_case()]
      }

      conn =
        build_conn("POST", "/", ctx.tenant, %{roles: ["PROCESS_DESIGNER"], body: body})
        |> dispatch()

      assert conn.status == 201
      decoded = Jason.decode!(conn.resp_body)
      assert [case_body] = decoded["test_cases"]
      assert case_body["name"] == "the applicant is approved"
    end

    test "PUT / declares the cases of a draft, and the activation runs them", ctx do
      draft = create_definition!(ctx.tenant.schema_name)

      body = %{
        "name" => draft.name,
        "version" => draft.version,
        "graph" => minimal_graph(),
        "test_cases" => [failing_case()]
      }

      conn =
        build_conn("PUT", "/#{draft.id}", ctx.tenant, %{roles: ["PROCESS_DESIGNER"], body: body})
        |> dispatch()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert [case_body] = decoded["test_cases"]
      assert case_body["name"] == "the applicant is approved"

      # The declared case runs on the activation of the version that carries it.
      assert {:error, {:definition_test_cases_failed, [failure]}} =
               Definitions.activate(draft.id, prefix: ctx.tenant.schema_name)

      assert %{reason: :variable_mismatch} = failure
    end

    test "PATCH / touches the declared cases only when the key is present", ctx do
      draft = create_definition!(ctx.tenant.schema_name, %{test_cases: [passing_case()]})

      conn =
        build_conn("PATCH", "/#{draft.id}", ctx.tenant, %{
          roles: ["PROCESS_DESIGNER"],
          body: %{"description" => "unchanged cases"}
        })
        |> dispatch()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert [case_body] = decoded["test_cases"]
      assert case_body["name"] == "the applicant is approved"
    end
  end
end
