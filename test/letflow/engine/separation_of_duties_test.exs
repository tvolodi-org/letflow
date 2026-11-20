defmodule Letflow.Engine.SeparationOfDutiesTest do
  @moduledoc """
  T-1986 (four-eyes switch, slice 1; docs/design/four-eyes-switch.md): the check in
  `Letflow.Engine.SeparationOfDuties` with the stored setting `approval_rule_settings`, through the
  real `Letflow.Engine.complete_task/3` and `Letflow.Tasks.claim_task/3`. ON (no row, or a row
  `true`) refuses exactly as before; OFF lets an interactive person (credential `:oidc`) approve
  their own work and writes one `task.self_approved` audit entry in the completion transaction.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Audit.Entry
  alias Letflow.Engine
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Engine.SeparationOfDuties
  alias Letflow.Repo
  alias Letflow.SodSupport, as: S
  alias Letflow.Tasks

  @n1 S.n1()
  @n2 S.n2()

  defp case! do
    ctx = S.new_case!(S.seq_graph(%{"distinct_from" => [@n1]}), %{}, %{"seed" => "value"})
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-a", [u.id])
    S.grant_role!(ctx.schema_name, "role-b", [u.id, v.id])
    Map.merge(ctx, %{u: u, v: v})
  end

  defp put_setting!(schema, definition_name, node_id, four_eyes) do
    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: definition_name,
        node_id: node_id,
        four_eyes: four_eyes,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "t-1986 fixture"
      },
      prefix: schema
    )
  end

  defp complete_with(ctx, task, actor_id, credential) do
    Engine.complete_task(
      task.id,
      %{output_variables: %{}, actor_id: actor_id, idempotency_key: S.unique("t1986")},
      prefix: ctx.schema_name,
      credential: credential
    )
  end

  defp audit(schema, action),
    do: Entry |> where([a], a.action == ^action) |> Repo.all(prefix: schema)

  # u completed N1; the pending N2 task is returned
  defp after_n1!(ctx) do
    S.complete_node!(ctx, @n1, ctx.u.id, %{})
    S.pending_task!(ctx, @n2)
  end

  describe "ON (the default)" do
    test "E1 no row: refused as before, one refusal audit, no self-approval" do
      ctx = case!()
      n2 = after_n1!(ctx)
      before = S.rows(ctx)

      assert {:error, :separation_of_duties} = complete_with(ctx, n2, ctx.u.id, :oidc)
      assert S.rows(ctx) == before
      assert length(S.refusal_rows(ctx.schema_name)) == 1
      assert audit(ctx.schema_name, "task.self_approved") == []
    end

    test "E2 a row four_eyes true is ON" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, @n2, true)
      n2 = after_n1!(ctx)

      assert {:error, :separation_of_duties} = complete_with(ctx, n2, ctx.u.id, :oidc)
      assert audit(ctx.schema_name, "task.self_approved") == []
    end

    test "E7 check/5 is unchanged: an OFF row is not read without a context" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)

      {:ok, snapshot} =
        Letflow.Definitions.SnapshotStore.get_by_instance_id(ctx.instance_id,
          prefix: ctx.schema_name
        )

      {:ok, graph} = Engine.build_graph(snapshot.graph)

      assert {:error, {:separation_of_duties, [@n1]}} =
               SeparationOfDuties.check(Repo, graph, n2, ctx.u.id, ctx.schema_name)

      assert {:self_approved, %{node_id: @n2, same_person_as: [@n1]}} =
               SeparationOfDuties.check(Repo, graph, n2, ctx.u.id, ctx.schema_name, %{
                 definition_name: ctx.definition.name,
                 credential: :oidc
               })
    end
  end

  describe "OFF" do
    test "E3 the same interactive person completes; exactly one task.self_approved entry" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)

      assert {:ok, _} = complete_with(ctx, n2, ctx.u.id, :oidc)
      assert S.reload_task!(ctx, n2).completed_by == ctx.u.id

      assert [entry] = audit(ctx.schema_name, "task.self_approved")
      assert entry.actor_id == ctx.u.id
      assert entry.resource_type == "task"
      assert entry.resource_id == n2.id
      assert entry.before_state == nil

      assert %{
               "note" => "self-approved, four-eyes off",
               "four_eyes" => "off",
               "node_id" => @n2,
               "same_person_as" => [@n1],
               "setting_changed_at" => changed_at
             } = entry.after_state

      assert entry.after_state["definition_name"] == ctx.definition.name
      assert {:ok, _, _} = DateTime.from_iso8601(changed_at)
      assert length(audit(ctx.schema_name, "task.complete")) == 2
      assert S.refusal_rows(ctx.schema_name) == []
    end

    test "E3b a different person completes: no self-approval entry" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)

      assert {:ok, _} = complete_with(ctx, n2, ctx.v.id, :oidc)
      assert audit(ctx.schema_name, "task.self_approved") == []
    end

    test "E4 a non-interactive credential or none is refused (fails closed)" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)

      for credential <- [nil, :api_token, :service_principal] do
        assert {:error, :separation_of_duties} = complete_with(ctx, n2, ctx.u.id, credential)
      end

      assert audit(ctx.schema_name, "task.self_approved") == []
    end

    test "E5 an unreadable setting refuses and logs one warning without ids" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)
      before = S.rows(ctx)
      schema = ctx.schema_name

      Repo.query!(
        ~s|ALTER TABLE "#{schema}".approval_rule_settings RENAME TO approval_rule_settings_x|
      )

      log =
        capture_log(fn ->
          assert {:error, :separation_of_duties} = complete_with(ctx, n2, ctx.u.id, :oidc)
        end)

      Repo.query!(
        ~s|ALTER TABLE "#{schema}".approval_rule_settings_x RENAME TO approval_rule_settings|
      )

      assert log =~ "four-eyes setting unreadable for task #{n2.id}"

      # only the warning line itself (the test log also carries debug query lines)
      [warning] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]"))
      refute warning =~ ctx.u.id
      assert S.rows(ctx) == before
    end

    test "E6 OFF for another step or another process does not apply" do
      ctx = case!()
      put_setting!(ctx.schema_name, ctx.definition.name, "other-node", false)
      put_setting!(ctx.schema_name, "other-def", @n2, false)
      n2 = after_n1!(ctx)

      assert {:error, :separation_of_duties} = complete_with(ctx, n2, ctx.u.id, :oidc)
    end

    test "E6x another tenant's OFF row does not apply" do
      ctx = case!()
      other = S.tenant!()
      put_setting!(other.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)

      assert {:error, :separation_of_duties} = complete_with(ctx, n2, ctx.u.id, :oidc)
      assert Repo.all(ApprovalRuleSetting, prefix: ctx.schema_name) == []
    end

    test "E8 the live value counts: flipped back ON, the next instance is refused" do
      ctx = case!()
      setting = put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)
      n2 = after_n1!(ctx)
      assert {:ok, _} = complete_with(ctx, n2, ctx.u.id, :oidc)

      setting
      |> Ecto.Changeset.change(%{four_eyes: true})
      |> Repo.update!(prefix: ctx.schema_name)

      ctx2 = %{
        ctx
        | instance_id: S.start_instance!(ctx.schema_name, ctx.definition, %{"seed" => "v2"})
      }

      n2b = after_n1!(ctx2)
      assert {:error, :separation_of_duties} = complete_with(ctx2, n2b, ctx.u.id, :oidc)
    end

    test "E9 a different person's completion costs the same queries with or without a row" do
      ctx = case!()
      n2 = after_n1!(ctx)
      {_, without_row} = count_queries(fn -> complete_with(ctx, n2, ctx.v.id, :oidc) end)

      ctx2 = case!()
      put_setting!(ctx2.schema_name, ctx2.definition.name, @n2, false)
      n2b = after_n1!(ctx2)
      {_, with_row} = count_queries(fn -> complete_with(ctx2, n2b, ctx2.v.id, :oidc) end)

      assert with_row == without_row
    end

    test "C1c claim: OFF lets the completer of the named step claim; ON refuses" do
      ctx = case!()
      n2 = after_n1!(ctx)

      assert {:error, :separation_of_duties} =
               Tasks.claim_task(n2.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)

      put_setting!(ctx.schema_name, ctx.definition.name, @n2, false)

      assert {:ok, _} = Tasks.claim_task(n2.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)
    end
  end

  # REQ-912: the shared stock access of the old Qoimeks address may self-approve ONE step, the approval
  # of a quick count, and only when the tenant stored four_eyes false for it.
  describe "REQ-912 the shared access and the quick count approval" do
    @submit "submit"
    @approve "approve"

    defp quick_count_case! do
      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          S.human(@submit, "role-a", %{}),
          S.human(@approve, "role-b", %{"distinct_from" => [@submit]}),
          S.human("recheck", "role-b", %{"distinct_from" => [@submit]}),
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => @submit},
          %{"id" => "e2", "source" => @submit, "target" => @approve},
          %{"id" => "e3", "source" => @approve, "target" => "recheck"},
          %{"id" => "e4", "source" => "recheck", "target" => "end"}
        ]
      }

      ctx = S.new_case!(graph, %{}, %{"seed" => "value"})
      u = S.insert_user!(ctx.schema_name, "u")
      S.complete_node!(ctx, @submit, u.id, %{})
      approve = S.pending_task!(ctx, @approve)

      {:ok, snapshot} =
        Letflow.Definitions.SnapshotStore.get_by_instance_id(ctx.instance_id,
          prefix: ctx.schema_name
        )

      {:ok, built} = Engine.build_graph(snapshot.graph)
      {ctx, u, approve, built}
    end

    defp check6(ctx, built, task, actor, name, credential) do
      SeparationOfDuties.check(Repo, built, task, actor, ctx.schema_name, %{
        definition_name: name,
        credential: credential
      })
    end

    test "E12 OFF: :shared_access on stock_quick_count / approve is self-approved" do
      {ctx, u, approve, built} = quick_count_case!()
      put_setting!(ctx.schema_name, "stock_quick_count", @approve, false)

      assert {:self_approved,
              %{
                definition_name: "stock_quick_count",
                node_id: @approve,
                same_person_as: [@submit]
              }} =
               check6(ctx, built, approve, u.id, "stock_quick_count", :shared_access)
    end

    test "E13 the widening is narrow: another process, credential, no row and a row true refuse" do
      {ctx, u, approve, built} = quick_count_case!()
      put_setting!(ctx.schema_name, "stock_quick_count", @approve, false)
      put_setting!(ctx.schema_name, "stock_opening", @approve, false)
      refused = {:error, {:separation_of_duties, [@submit]}}

      # the same credential on another process, even with its own OFF row
      assert refused == check6(ctx, built, approve, u.id, "stock_opening", :shared_access)
      # another non-interactive credential on the quick count
      for credential <- [:api_token, :service_principal, nil] do
        assert refused == check6(ctx, built, approve, u.id, "stock_quick_count", credential)
      end

      # a step of the quick count that is not `approve`, even with its own OFF row
      put_setting!(ctx.schema_name, "stock_quick_count", "recheck", false)
      v = S.insert_user!(ctx.schema_name, "v")
      S.complete_node!(ctx, @approve, v.id, %{})
      recheck = S.pending_task!(ctx, "recheck")

      {:ok, snapshot} =
        Letflow.Definitions.SnapshotStore.get_by_instance_id(ctx.instance_id,
          prefix: ctx.schema_name
        )

      {:ok, built2} = Engine.build_graph(snapshot.graph)

      assert refused == check6(ctx, built2, recheck, u.id, "stock_quick_count", :shared_access)
    end

    test "E12b T-2410 OFF: :system_self_approval is self-approved on the one step and says so" do
      {ctx, u, approve, built} = quick_count_case!()
      put_setting!(ctx.schema_name, "stock_quick_count", @approve, false)

      assert {:self_approved,
              %{
                definition_name: "stock_quick_count",
                node_id: @approve,
                same_person_as: [@submit],
                approved_by: "system"
              }} =
               check6(ctx, built, approve, u.id, "stock_quick_count", :system_self_approval)

      # the old address and the interactive person keep today's info (no `approved_by`)
      assert {:self_approved, info} =
               check6(ctx, built, approve, u.id, "stock_quick_count", :shared_access)

      refute Map.has_key?(info, :approved_by)
    end

    test "E13b T-2410 :system_self_approval is as narrow as :shared_access: other process, no row, row true" do
      {ctx, u, approve, built} = quick_count_case!()
      refused = {:error, {:separation_of_duties, [@submit]}}
      credential = :system_self_approval

      # no row (rule ON by default) and a stored true
      assert refused == check6(ctx, built, approve, u.id, "stock_quick_count", credential)
      put_setting!(ctx.schema_name, "stock_quick_count", @approve, true)
      assert refused == check6(ctx, built, approve, u.id, "stock_quick_count", credential)

      # another process, even with its own OFF row
      put_setting!(ctx.schema_name, "stock_opening", @approve, false)
      assert refused == check6(ctx, built, approve, u.id, "stock_opening", credential)
    end

    test "E14 no row and a row four_eyes true refuse :shared_access (fails closed)" do
      {ctx, u, approve, built} = quick_count_case!()
      refused = {:error, {:separation_of_duties, [@submit]}}
      assert refused == check6(ctx, built, approve, u.id, "stock_quick_count", :shared_access)

      put_setting!(ctx.schema_name, "stock_quick_count", @approve, true)
      assert refused == check6(ctx, built, approve, u.id, "stock_quick_count", :shared_access)
    end

    test "E15 an unreadable setting refuses :shared_access" do
      {ctx, u, approve, built} = quick_count_case!()
      put_setting!(ctx.schema_name, "stock_quick_count", @approve, false)
      schema = ctx.schema_name

      Repo.query!(
        ~s|ALTER TABLE "#{schema}".approval_rule_settings RENAME TO approval_rule_settings_x|
      )

      try do
        capture_log(fn ->
          assert {:error, {:separation_of_duties, [@submit]}} =
                   check6(ctx, built, approve, u.id, "stock_quick_count", :shared_access)
        end)
      after
        Repo.query!(
          ~s|ALTER TABLE "#{schema}".approval_rule_settings_x RENAME TO approval_rule_settings|
        )
      end
    end
  end

  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = "t1986-count-" <> inspect(ref)

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _e, _m, _md, _c -> if self() == test_pid, do: send(test_pid, {ref, :query}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
