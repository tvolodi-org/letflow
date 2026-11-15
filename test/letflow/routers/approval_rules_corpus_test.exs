defmodule Letflow.Routers.ApprovalRulesCorpusTest do
  @moduledoc """
  T-1990, four-eyes switch slice 6: every shipped pack's `distinct_from` step must reach
  GET /approval-rules. Discover the corpus at runtime so new packs and steps join the guard.
  The fixture stores the unchanged pack graphs as active definitions: this tests the listing
  contract, independently of module installation dependencies and posting handlers.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Scope.Grants
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.TenantFixture

  @opts Letflow.Routers.ApprovalRules.init([])
  @packs Path.expand("../../../priv/modules/**/pack.json", __DIR__)

  defp corpus do
    paths = Path.wildcard(@packs)
    assert paths != [], "no shipped packs found at #{@packs}"

    for path <- paths,
        definition <- path |> File.read!() |> Jason.decode!() |> Map.fetch!("definitions") do
      definition
    end
  end

  defp load!(tenant, definitions) do
    for definition <- definitions do
      Repo.insert!(
        %ProcessDefinition{
          name: Map.fetch!(definition, "process_key"),
          version: Map.fetch!(definition, "version"),
          graph: Map.fetch!(definition, "graph"),
          status: :active,
          created_by: Ecto.UUID.generate()
        },
        prefix: tenant.schema_name
      )
    end
  end

  defp read(tenant) do
    uid = Ecto.UUID.generate()

    auth = %{
      tenant_id: tenant.tenant_id,
      user_id: uid,
      roles: ["TENANT_ADMIN"],
      credential: :oidc,
      scope_grants: %Grants{
        user_id: uid,
        rows_by_role: %{
          "TENANT_ADMIN" => [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]
        }
      }
    }

    conn =
      conn(:get, "/")
      |> assign(:auth_context, auth)
      |> assign(:trace_id, "t1990-corpus")
      |> Letflow.Routers.ApprovalRules.call(@opts)

    assert conn.status == 200
    %{"items" => items} = Jason.decode!(conn.resp_body)
    items
  end

  defp keys(items), do: Enum.map(items, &{&1["definition_name"], &1["node_id"]})

  @tag timeout: 60_000
  test "C1 GET lists every distinct_from step from every shipped pack, default ON" do
    definitions = corpus()

    expected =
      for definition <- definitions,
          node <- definition |> Map.fetch!("graph") |> Map.fetch!("nodes"),
          distinct = get_in(node, ["attributes", "distinct_from"]),
          distinct not in [nil, []] do
        assert node["node_type"] == "HUMAN_TASK"
        assert is_list(distinct) and Enum.all?(distinct, &is_binary/1)
        {Map.fetch!(definition, "process_key"), Map.fetch!(node, "id")}
      end

    # A missing/empty corpus cannot turn this into a vacuous success; additions need no pin update.
    assert {"assets_opening", "approve"} in expected
    assert {"stock_opening", "approve"} in expected

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "approval-corpus")
    load!(tenant, definitions)
    items = read(tenant)

    assert keys(items) == Enum.sort(expected)

    for item <- items do
      assert item["four_eyes"] == true
      assert item["in_active_definition"] == true
      assert item["changed_at"] == nil
    end
  end

  test "C2 GET discovers new process and step names, excluding steps without a rule" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "approval-new")
    name = "future_process"

    nodes = [
      %{"id" => "prepare", "node_type" => "HUMAN_TASK"},
      %{
        "id" => "review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"distinct_from" => ["prepare"]}
      },
      %{
        "id" => "release",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"distinct_from" => ["prepare", "review"]}
      },
      %{
        "id" => "no-rule",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"distinct_from" => []}
      }
    ]

    load!(tenant, [
      %{
        "process_key" => name,
        "version" => "1.0.0",
        "graph" => %{"nodes" => nodes, "edges" => []}
      }
    ])

    assert keys(read(tenant)) == [{name, "release"}, {name, "review"}]
  end

  @tag timeout: 60_000
  test "X1 GET in another tenant never lists the shipped approvals loaded in the first tenant" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "approval-owner")
    other = TenantFixture.provisioned_tenant!(slug_prefix: "approval-other")
    load!(tenant, corpus())

    assert read(tenant) != []
    assert read(other) == []
  end
end
