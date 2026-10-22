defmodule Letflow.Engine.ModuleWriteScriptReviewTest do
  @moduledoc """
  GH #2725 gap 3 / REQ-501 design D-R.18 + decision 0053 D6: a script that reaches a module write
  handler (a stamped SERVICE_TASK with `script_key` and `module_writes`) is under the SAME
  script governance as any other script.

    * `ScriptsWrite` (PROCESS_DESIGNER, TENANT_ADMIN) authors a version; `ScriptsPublish`
      (TENANT_ADMIN only) publishes it, on the endpoints that fix those permissions;
    * SoD (`scripts.sod = strict`, the default): the author of a version cannot publish it
      (`:publisher_is_contributor`);
    * until a version is published (by someone else) no definition binding it can be activated,
      so no handler can run through it; once it is, the handler writes commit.

  `module_write_service_task_test.exs` COND 1-2 cover what a published script's OUTPUT can do to
  the handler; this file covers who can put such a script in front of one. Real Postgres.
  `async: false`: module installs and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.FixtureLedger
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Scripts
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    t = F.tenant!("gh2725-script-review")
    schema = t.schema_name
    SP.seed_roles!(schema)
    {:ok, _} = EventTypes.seed!(schema)
    activator = Fx.user!(schema, "activator")
    Mw.install_ledger!(schema)
    tenant_id = t.tenant_id

    on_exit(fn ->
      Repo.delete_all(
        from(i in Letflow.Definitions.SolutionPackInstall, where: i.tenant_id == ^tenant_id)
      )

      Repo.delete_all(
        from(b in Letflow.Definitions.SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id)
      )

      Repo.delete_all(
        from(cp in Letflow.TenantProvisioning.ColumnPromotion, where: cp.tenant_id == ^tenant_id)
      )
    end)

    %{schema: schema, activator: activator, author: SP.user!(schema), reviewer: SP.user!(schema)}
  end

  defp script_body do
    %{
      "hook_kind" => "service_task",
      "source" => F.doubling_source(),
      "manifest" => F.closed_manifest(),
      "test_cases" => [
        %{
          "name" => "doubles",
          "input" => %{"amount" => 2},
          "expect" => %{"output" => %{"total" => 4}}
        }
      ]
    }
  end

  defp handler_lines do
    [
      %{
        "module" => "fixture_ledger",
        "handler" => "post_entry",
        "args" => %{"item" => %{"const" => "widget"}, "quantity" => %{"var" => "total"}}
      }
    ]
  end

  defp bound_draft!(schema, activator, key) do
    graph =
      update_in(F.script_graph(key, 1), ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "svc", "attributes" => attrs} = node ->
            %{node | "attributes" => Map.put(attrs, "module_writes", handler_lines())}

          node ->
            node
        end)
      end)

    {:ok, draft} =
      Definitions.create_owned(
        %{
          name: Fx.unique("gh2725-script"),
          version: "1",
          graph: graph,
          created_by: activator.id
        },
        [prefix: schema],
        ManagedTypes.module_owner(FixtureLedger)
      )

    draft
  end

  defp activate(schema, activator, draft) do
    auth =
      Activator.from_auth_context(%{user_id: activator.id, roles: ["TENANT_ADMIN"]}, false)

    Definitions.activate(draft.id, prefix: schema, activator: auth)
  end

  defp publish(schema, rule, publisher_id) do
    Scripts.publish(schema, rule.key, rule.version, rule.sha256, SP.actor(publisher_id), false)
  end

  test "ScriptsWrite authors and ScriptsPublish publishes: the permissions on the script routes" do
    for {method, path, permission} <- [
          {"POST", "/script-rules/:key/versions", :ScriptsWrite},
          {"PUT", "/script-rules/:key/versions/:version", :ScriptsWrite},
          {"POST", "/script-rules/:key/versions/:version/publish", :ScriptsPublish}
        ] do
      assert Authorization.endpoint_policy_key(method, path) == permission
    end

    assert Authorization.has_permission?([:PROCESS_DESIGNER], :ScriptsWrite)
    assert Authorization.has_permission?([:TENANT_ADMIN], :ScriptsWrite)
    assert Authorization.has_permission?([:TENANT_ADMIN], :ScriptsPublish)

    # the designer who may author the script in front of a handler may not publish it
    refute Authorization.has_permission?([:PROCESS_DESIGNER], :ScriptsPublish)

    for role <- [:PROCESS_OPERATOR, :TASK_WORKER, :CANDIDATE] do
      refute Authorization.has_permission?([role], :ScriptsWrite)
      refute Authorization.has_permission?([role], :ScriptsPublish)
    end
  end

  test "an unpublished script cannot be activated into a handler-calling node", ctx do
    {:ok, rule} =
      Scripts.create_draft(ctx.schema, "gh2725_unpub", script_body(), SP.actor(ctx.author))

    assert rule.status == :draft

    draft = bound_draft!(ctx.schema, ctx.activator, "gh2725_unpub")

    assert {:error, {:script_binding_invalid, "svc", :script_not_published}} =
             activate(ctx.schema, ctx.activator, draft)

    assert Fx.all_records(ctx.schema) == []
  end

  test "SoD: the author cannot publish their own script; a second user's publish unlocks the handler",
       ctx do
    {:ok, rule} =
      Scripts.create_draft(ctx.schema, "gh2725_sod", script_body(), SP.actor(ctx.author))

    draft = bound_draft!(ctx.schema, ctx.activator, "gh2725_sod")

    # strict (the default): the contributor is refused, the version stays a draft
    assert {:error, :publisher_is_contributor} = publish(ctx.schema, rule, ctx.author)

    assert Repo.get_by!(ScriptRule, [key: "gh2725_sod", version: 1], prefix: ctx.schema).status ==
             :draft

    assert {:error, {:script_binding_invalid, "svc", :script_not_published}} =
             activate(ctx.schema, ctx.activator, draft)

    # a publisher outside the contributors publishes; only then does the definition activate
    assert {:ok, published} = publish(ctx.schema, rule, ctx.reviewer)
    assert published.status == :published
    assert published.publisher_id == ctx.reviewer
    refute published.publisher_id in published.contributors

    assert {:ok, %{definition: definition}} = activate(ctx.schema, ctx.activator, draft)
    assert %{"module_handlers" => ["fixture_ledger/post_entry"]} = definition.activated_by

    # ... and the run through the reviewed script commits the handler's writes
    instance_id = F.start!(ctx.schema, definition, %{"amount" => 2}, Ecto.UUID.generate())
    assert {_row, {:ok, :applied}} = F.run_next!(ctx.schema)
    assert F.projection(ctx.schema, instance_id).status == :completed
    assert [ledger] = Fx.records(ctx.schema, "fxl_ledger")
    assert ledger.field_values == %{"item" => "widget", "quantity" => 4}
  end
end
