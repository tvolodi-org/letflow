defmodule Letflow.Definitions.HumanTaskValidationActivationTest do
  @moduledoc """
  REQ-569 / GH #3246 AC2, AC4, AC5, AC6, AC9 (decision 0067 D9, slice F-1): a HUMAN_TASK
  `validation_script_key`/`validation_script_version` pair is checked at activation like a
  SERVICE_TASK script binding, but against a published `form_validation` version, and only while
  `:form_validation_hook_enabled` holds. Tenant isolation (INV-1, INV-10) and the retire block are
  covered here too. `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Scripts
  alias Letflow.Scripts.Runtime
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @definitions_opts Letflow.Routers.Definitions.init([])

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp human_node(id, key, version),
    do: %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => %{
        "role" => "REVIEWER",
        "validation_script_key" => key,
        "validation_script_version" => version
      }
    }

  defp svc_node(id, key, version),
    do: %{
      "id" => id,
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"script_key" => key, "script_version" => version}
    }

  # START -> nodes in a chain -> END
  defp chain(nodes) do
    all =
      [%{"id" => "start", "node_type" => "START"}] ++
        nodes ++ [%{"id" => "end", "node_type" => "END"}]

    ids = Enum.map(all, & &1["id"])

    edges =
      ids
      |> Enum.zip(tl(ids))
      |> Enum.with_index(1)
      |> Enum.map(fn {{a, b}, i} -> %{"id" => "e#{i}", "source" => a, "target" => b} end)

    %{"nodes" => all, "edges" => edges}
  end

  defp human_graph(key, version), do: chain([human_node("review", key, version)])

  defp graph_struct(map) do
    {:ok, graph} = Graph.from_map(map)
    graph
  end

  defp check(schema, map), do: Runtime.check_bindings(graph_struct(map), schema)

  defp fv!(schema, key, status \\ :published) do
    manifest = F.closed_manifest()
    opts = [hook_kind: "form_validation"]

    case status do
      :published ->
        F.published!(schema, key, F.doubling_source(), manifest, opts)

      :draft ->
        F.draft!(schema, key, F.doubling_source(), manifest, opts)

      :retired ->
        schema
        |> F.published!(key, F.doubling_source(), manifest, opts)
        |> then(&F.retire_raw!(schema, &1))

      :revoked ->
        schema
        |> F.published!(key, F.doubling_source(), manifest, opts)
        |> then(&F.revoke_raw!(schema, &1))
    end
  end

  defp set_flag(value) do
    previous = Application.fetch_env(:letflow, :form_validation_hook_enabled)
    Application.put_env(:letflow, :form_validation_hook_enabled, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :form_validation_hook_enabled, old)
        :error -> Application.delete_env(:letflow, :form_validation_hook_enabled)
      end
    end)
  end

  setup do
    set_flag(true)

    %{
      t: F.tenant_without_hmac!("r569-act"),
      other: F.tenant_without_hmac!("r569-other")
    }
  end

  defp not_published(node_id),
    do: {:error, {:script_binding_invalid, node_id, :script_not_published}}

  describe "AC4 success" do
    test "A1 a published form_validation version activates", %{t: t} do
      rule = fv!(t.schema_name, "check_amount")
      graph = human_graph("check_amount", rule.version)

      assert check(t.schema_name, graph) == :ok

      assert {:ok, %{definition: %{status: :active}}} =
               Definitions.activate(F.draft_definition!(t.schema_name, graph, []).id,
                 prefix: t.schema_name
               )
    end
  end

  describe "AC5 refusals" do
    test "A2 absent, draft, retired, revoked and wrong kind are not published", %{t: t} do
      s = t.schema_name
      assert check(s, human_graph("nothing", 1)) == not_published("review")

      for status <- [:draft, :retired, :revoked] do
        key = unique("fv")
        rule = fv!(s, key, status)
        assert check(s, human_graph(key, rule.version)) == not_published("review"), "#{status}"
      end

      key = unique("svc")
      rule = F.published!(s, key, F.doubling_source(), F.closed_manifest())
      assert check(s, human_graph(key, rule.version)) == not_published("review")
    end

    test "A3 a published form_validation version named by a SERVICE_TASK is not published", %{
      t: t
    } do
      rule = fv!(t.schema_name, "fv_only")

      assert check(t.schema_name, chain([svc_node("svc", "fv_only", rule.version)])) ==
               not_published("svc")
    end

    test "A4 flag off: a stored published form_validation version is not published", %{t: t} do
      rule = fv!(t.schema_name, "check_amount")
      svc = F.published!(t.schema_name, "svc_key", F.doubling_source(), F.closed_manifest())

      assert check(t.schema_name, human_graph("check_amount", rule.version)) == :ok
      assert check(t.schema_name, F.script_graph("svc_key", svc.version)) == :ok

      set_flag(false)

      assert check(t.schema_name, human_graph("check_amount", rule.version)) ==
               not_published("review")

      assert check(t.schema_name, F.script_graph("svc_key", svc.version)) == :ok
    end

    test "A7 an open output schema is refused", %{t: t} do
      open = put_in(F.closed_manifest(), ["output_schema", "additionalProperties"], true)

      rule =
        F.published!(t.schema_name, "open_fv", F.doubling_source(), open,
          hook_kind: "form_validation"
        )

      assert check(t.schema_name, human_graph("open_fv", rule.version)) ==
               {:error, {:script_binding_invalid, "review", :script_output_schema_open}}
    end

    test "A2f the activate route answers the script_binding_invalid 422 body", %{t: t} do
      draft = F.draft_definition!(t.schema_name, human_graph("absent_key", 1), [])
      resp = activate_route(draft.id, t)

      assert resp.status == 422

      assert Jason.decode!(resp.resp_body) == %{
               "error" => "script_binding_invalid",
               "node_id" => "review",
               "reason" => "script_not_published"
             }

      assert Repo.get!(ProcessDefinition, draft.id, prefix: t.schema_name).status == :draft
    end
  end

  describe "AC6 version conflict and kind clash" do
    test "A5 different versions of one key are a conflict at the later node", %{t: t} do
      s = t.schema_name
      v1 = fv!(s, "fv_two")
      v2 = fv!(s, "fv_two")
      svc1 = F.published!(s, "svc_two", F.doubling_source(), F.closed_manifest())
      svc2 = F.published!(s, "svc_two", F.doubling_source(), F.closed_manifest())

      assert check(
               s,
               chain([
                 human_node("h1", "fv_two", v1.version),
                 human_node("h2", "fv_two", v2.version)
               ])
             ) ==
               {:error, {:script_binding_invalid, "h2", :script_version_conflict}}

      assert check(
               s,
               chain([
                 svc_node("s1", "svc_two", svc1.version),
                 human_node("h", "svc_two", svc2.version)
               ])
             ) ==
               {:error, {:script_binding_invalid, "h", :script_version_conflict}}
    end

    test "A5b the same version on two HUMAN_TASK nodes is accepted", %{t: t} do
      rule = fv!(t.schema_name, "fv_same")

      assert check(
               t.schema_name,
               chain([
                 human_node("h1", "fv_same", rule.version),
                 human_node("h2", "fv_same", rule.version)
               ])
             ) ==
               :ok
    end

    test "A5c the same key and version on both node types is refused at the later node", %{t: t} do
      rule = F.published!(t.schema_name, "both", F.doubling_source(), F.closed_manifest())

      assert check(
               t.schema_name,
               chain([
                 svc_node("svc", "both", rule.version),
                 human_node("h", "both", rule.version)
               ])
             ) ==
               not_published("h")
    end

    test "A6 the restriction flow stays SERVICE_TASK only", %{t: t} do
      manifest =
        Map.put(F.closed_manifest(), "restricted_inputs", [
          %{"name" => "amount", "from" => [%{"entity_type" => "customer", "field" => "salary"}]}
        ])

      rule =
        F.published!(t.schema_name, "restr_fv", F.doubling_source(), manifest,
          hook_kind: "form_validation"
        )

      assert check(t.schema_name, human_graph("restr_fv", rule.version)) == :ok
    end
  end

  describe "AC9 tenant isolation" do
    test "X1 a key present only in tenant A answers like an absent key in tenant B", %{
      t: a,
      other: b
    } do
      rule = fv!(a.schema_name, "check_amount")
      graph = human_graph("check_amount", rule.version)

      assert check(a.schema_name, graph) == :ok
      assert check(b.schema_name, graph) == not_published("review")

      assert Runtime.pin_lookup(b.schema_name).("check_amount", rule.version) ==
               {:error, :not_found}

      assert {:ok, _} = Runtime.pin_lookup(a.schema_name).("check_amount", rule.version)

      draft_b = F.draft_definition!(b.schema_name, graph, [])
      absent = F.draft_definition!(b.schema_name, human_graph("in_no_tenant", rule.version), [])
      body_b = activate_route(draft_b.id, b).resp_body
      body_absent = activate_route(absent.id, b).resp_body

      assert body_b == body_absent
    end

    test "X2 tenant B completing tenant A's task answers like an unknown task id", %{
      t: a,
      other: b
    } do
      rule = fv!(a.schema_name, "check_amount")
      definition = F.definition!(a.schema_name, human_graph("check_amount", rule.version), [])
      instance_id = F.start!(a.schema_name, definition, %{}, Ecto.UUID.generate())

      task =
        Repo.one!(
          from(k in Letflow.Engine.Task,
            where: k.instance_id == ^instance_id and k.status == :pending
          ),
          prefix: a.schema_name
        )

      cross = complete_route(task.id, b)
      unknown = complete_route(Ecto.UUID.generate(), b)

      assert cross.status == unknown.status
      assert cross.resp_body == unknown.resp_body
      assert cross.status in [403, 404]

      still = Repo.get!(Letflow.Engine.Task, task.id, prefix: a.schema_name)
      assert still.status == :pending
    end
  end

  describe "retire block" do
    test "R1 a version bound by an active definition's HUMAN_TASK pair cannot be retired", %{
      t: t
    } do
      s = t.schema_name
      rule = fv!(s, "check_amount")
      _active = F.definition!(s, human_graph("check_amount", rule.version), [])

      assert Runtime.referenced_by_active_definition?(s, "check_amount", rule.version)
      refute Runtime.referenced_by_active_definition?(s, "check_amount", rule.version + 1)
      refute Runtime.referenced_by_active_definition?(s, "other_key", rule.version)
      assert function_exported?(Scripts, :form_validation_enabled?, 0)
    end
  end

  defp complete_route(task_id, tenant) do
    conn(:post, "/#{task_id}/complete")
    |> Map.put(:body_params, %{})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "r569-complete")
    |> Letflow.Routers.Tasks.call(Letflow.Routers.Tasks.init([]))
  end

  defp activate_route(definition_id, tenant) do
    PlatformTenantFixture.pin!(tenant.tenant_id)

    conn(:post, "/#{definition_id}/activate")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    })
    |> assign(:trace_id, "r569-routes")
    |> Letflow.Routers.Definitions.call(@definitions_opts)
  end
end
