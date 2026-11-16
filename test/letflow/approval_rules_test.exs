defmodule Letflow.ApprovalRulesTest do
  @moduledoc """
  T-1986 (four-eyes switch, slice 1): `Letflow.ApprovalRules` and its table. M1 the table exists and
  is empty in a fresh tenant, L1 `list/1`, U1 `put/5` validation order (nothing written before the
  last step). The routes are covered in `test/letflow/routers/approval_rules_test.exs`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.ApprovalRules
  alias Letflow.Audit.Entry
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Repo
  alias Letflow.SodSupport, as: S
  alias Letflow.TenantFixture

  @n1 S.n1()
  @n2 S.n2()

  defp case!(attrs \\ %{"distinct_from" => [@n1]}),
    do: S.new_case!(S.seq_graph(attrs), %{}, %{"seed" => "value"})

  defp actor, do: %{user_id: Ecto.UUID.generate(), trace_id: nil}

  test "M1 a fresh tenant has the empty table, and it is in the expected table list" do
    ctx = case!()
    assert Repo.all(ApprovalRuleSetting, prefix: ctx.schema_name) == []
    assert "approval_rule_settings" in TenantFixture.expected_tenant_tables()
  end

  test "L1 only a step with distinct_from is listed (ON); a stored row of no active step shows as inactive" do
    plain = case!(%{})
    assert ApprovalRules.list(plain.schema_name) == []

    ctx = case!()
    assert [item] = ApprovalRules.list(ctx.schema_name)

    assert %{node_id: @n2, four_eyes: true, in_active_definition: true, changed_at: nil} = item
    assert item.definition_name == ctx.definition.name

    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: "gone",
        node_id: "x",
        four_eyes: false,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "r"
      },
      prefix: ctx.schema_name
    )

    assert [%{definition_name: "gone", in_active_definition: false, four_eyes: false}, _] =
             Enum.sort_by(ApprovalRules.list(ctx.schema_name), & &1.definition_name)
  end

  test "L2 changed_by_name: the user's name; nil for an unknown user and for a never-changed step" do
    ctx = case!()
    user = S.insert_user!(ctx.schema_name, "chg")
    assert [%{changed_by_name: nil}] = ApprovalRules.list(ctx.schema_name)

    assert {:ok, %{changed_by_name: name}} =
             ApprovalRules.put(
               ctx.schema_name,
               ctx.definition.name,
               @n2,
               %{"four_eyes" => false, "reason" => "r"},
               %{user_id: user.id, trace_id: nil}
             )

    assert name == user.display_name
    assert [%{changed_by_name: ^name}] = ApprovalRules.list(ctx.schema_name)

    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: "gone",
        node_id: "x",
        four_eyes: false,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "r"
      },
      prefix: ctx.schema_name
    )

    gone = Enum.find(ApprovalRules.list(ctx.schema_name), &(&1.definition_name == "gone"))
    assert gone.changed_by != nil and gone.changed_by_name == nil
  end

  test "U1 bad body, then bad reason, then unknown step: each writes nothing" do
    ctx = case!()
    schema = ctx.schema_name
    name = ctx.definition.name
    audit_before = Repo.aggregate(Entry, :count, prefix: schema)

    assert {:error, :invalid_body} =
             ApprovalRules.put(
               schema,
               name,
               "nope",
               %{"four_eyes" => 1, "reason" => "x"},
               actor()
             )

    assert {:error, :invalid_reason} =
             ApprovalRules.put(
               schema,
               name,
               "nope",
               %{"four_eyes" => false, "reason" => ""},
               actor()
             )

    assert {:error, :not_a_four_eyes_step} =
             ApprovalRules.put(
               schema,
               name,
               "nope",
               %{"four_eyes" => false, "reason" => "x"},
               actor()
             )

    assert {:error, :invalid_body} = ApprovalRules.put(schema, name, @n2, "string", actor())

    assert Repo.all(ApprovalRuleSetting, prefix: schema) == []
    assert Repo.aggregate(Entry, :count, prefix: schema) == audit_before
  end

  defp set_row!(ctx, name, node, four_eyes) do
    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: name,
        node_id: node,
        four_eyes: four_eyes,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "r"
      },
      prefix: ctx.schema_name
    )
  end

  test "FE-R1 self_approval_allowed? is true only for oidc + an OFF row of this definition and node" do
    ctx = case!()
    task = S.pending_task!(ctx, @n1)
    name = ctx.definition.name
    schema = ctx.schema_name

    # no row: ON
    refute ApprovalRules.self_approval_allowed?(schema, task, :oidc)

    # another node, another definition name: not this step
    set_row!(ctx, name, "other_node", false)
    set_row!(ctx, "other_definition", task.node_id, false)
    refute ApprovalRules.self_approval_allowed?(schema, task, :oidc)

    # an ON row
    on = set_row!(ctx, name, task.node_id, true)
    refute ApprovalRules.self_approval_allowed?(schema, task, :oidc)

    # OFF row: oidc only
    Repo.delete!(on, prefix: schema)
    set_row!(ctx, name, task.node_id, false)
    assert ApprovalRules.self_approval_allowed?(schema, task, :oidc)
    refute ApprovalRules.self_approval_allowed?(schema, task, :api_token)
    refute ApprovalRules.self_approval_allowed?(schema, task, nil)
  end

  test "FE-R2 an unreadable tenant schema answers {:error, :unreadable} / false, never raises" do
    ctx = case!()
    task = S.pending_task!(ctx, @n1)

    assert {:error, :unreadable} =
             ApprovalRuleSetting.off_for_instance_step(
               Repo,
               "tenant_missing_t1987",
               task.instance_id,
               task.node_id
             )

    refute ApprovalRules.self_approval_allowed?("tenant_missing_t1987", task, :oidc)
  end
end
