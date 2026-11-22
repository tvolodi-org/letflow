defmodule Letflow.Definitions.StepMappingDesignerValidateTest do
  @moduledoc """
  The TYPED STEP MAPPING in the DESIGNER (T-2594, "Register a tenant" pilot, gap
  G13).

  The designer's validate route -- `POST /api/v1/definitions/:id/validate` --
  runs the same rules the activation fence runs, so a designer sees an
  undeclared variable or a write to a protected variable BEFORE the version is
  switched on. The designer is the place where the owner of the pilot changes
  a process without asking for code, so the finding has to be there.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @opts Letflow.Routers.Definitions.init([])
  @designer_role "PROCESS_DESIGNER"

  setup do
    tenant = Fx.tenant!("t2594-designer")
    PlatformFx.pin!(tenant.tenant_id)

    %{tenant: tenant}
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp build_conn(method, path, tenant, body) do
    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: [@designer_role]
    })
    |> assign(:trace_id, "t2594-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  defp call(mapping) do
    Map.merge(
      %{
        "function" => "tenant.create",
        "args" => %{"slug" => %{"var" => "slug"}, "name" => %{"const" => "Acme"}}
      },
      mapping
    )
  end

  defp graph(call) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"platform_call" => call}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }
  end

  defp create_body(call, variable_schemas) do
    body = %{"name" => unique("t2594-designer"), "version" => "1.0.0", "graph" => graph(call)}

    if variable_schemas == [] do
      body
    else
      Map.put(body, "variable_schemas", variable_schemas)
    end
  end

  defp post_create!(tenant, call, variable_schemas) do
    conn = build_conn("POST", "/", tenant, create_body(call, variable_schemas)) |> dispatch()
    assert conn.status == 201, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp error_codes(conn), do: conn.resp_body |> Jason.decode!() |> Map.fetch!("errors")

  test "POST /:id/validate reports a variable the definition does not declare", ctx do
    created =
      post_create!(
        ctx.tenant,
        call(%{"reads" => %{"slug" => "string", "ghost" => "string"}, "writes" => %{}}),
        [%{"variable_key" => "slug", "json_schema" => %{"type" => "string"}}]
      )

    conn = build_conn("POST", "/#{created["id"]}/validate", ctx.tenant, nil) |> dispatch()

    assert conn.status == 422
    codes = Enum.map(error_codes(conn), & &1["code"])
    assert "step_mapping_variable_undeclared" in codes
  end

  test "POST /:id/validate reports a write to the reserved engine namespace", ctx do
    created =
      post_create!(
        ctx.tenant,
        call(%{"reads" => %{"slug" => "string"}, "writes" => %{"_sys" => "string"}}),
        [
          %{"variable_key" => "slug", "json_schema" => %{"type" => "string"}},
          %{"variable_key" => "_sys", "json_schema" => %{"type" => "string"}}
        ]
      )

    conn = build_conn("POST", "/#{created["id"]}/validate", ctx.tenant, nil) |> dispatch()

    assert conn.status == 422
    codes = Enum.map(error_codes(conn), & &1["code"])
    assert "step_mapping_reserved_refused" in codes
  end

  test "POST /:id/validate is 200 'valid' when the mapping agrees with the schemas", ctx do
    created =
      post_create!(
        ctx.tenant,
        call(%{"reads" => %{"slug" => "string"}, "writes" => %{"tenant_id" => "string"}}),
        [
          %{"variable_key" => "slug", "json_schema" => %{"type" => "string"}},
          %{"variable_key" => "tenant_id", "json_schema" => %{"type" => "string"}}
        ]
      )

    conn = build_conn("POST", "/#{created["id"]}/validate", ctx.tenant, nil) |> dispatch()

    assert conn.status == 200
    assert %{"status" => "valid"} = Jason.decode!(conn.resp_body)
  end

  test "the validate route reports the same findings as the context function", ctx do
    created =
      post_create!(
        ctx.tenant,
        call(%{"reads" => %{"slug" => "string", "ghost" => "string"}, "writes" => %{}}),
        [%{"variable_key" => "slug", "json_schema" => %{"type" => "string"}}]
      )

    assert {:ok, %{valid: false, violations: violations}} =
             Definitions.validate_definition_graph(created["id"], prefix: ctx.tenant.schema_name)

    codes = Enum.map(violations, & &1.code)
    assert :step_mapping_variable_undeclared in codes
  end

  test "a company tenant is never told what the catalogue declares", _ctx do
    company = Fx.tenant!("t2594-designer-company")

    # a row written straight into the company schema: the write path refuses a
    # platform_call there, so the row is forged (the same shape the company
    # tenant refusal test uses)
    forged =
      %Definitions.ProcessDefinition{}
      |> Definitions.ProcessDefinition.create_changeset(%{
        name: unique("t2594-company"),
        version: "1",
        graph: graph(call(%{"reads" => %{"slug" => "string"}, "writes" => %{}})),
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: company.schema_name)

    conn = build_conn("POST", "/#{forged.id}/validate", company, nil) |> dispatch()

    assert conn.status == 422
    codes = Enum.map(error_codes(conn), & &1["code"])
    assert codes == ["platform_call_not_allowed"]
  end

  test "the draft is not refused by the write path: the designer may draw the step", ctx do
    created =
      post_create!(
        ctx.tenant,
        call(%{"reads" => %{"slug" => "string", "ghost" => "string"}, "writes" => %{}}),
        [%{"variable_key" => "slug", "json_schema" => %{"type" => "string"}}]
      )

    row = Repo.get!(Definitions.ProcessDefinition, created["id"], prefix: ctx.tenant.schema_name)
    assert row.status == :draft
  end
end
