defmodule Letflow.ApprovalRulesDefaultTest do
  @moduledoc """
  T-2391 (owner D-165): the approval rule (four eyes) is OFF by default for NEW tenants and unchanged for
  existing ones. A new tenant is a schema provisioned through the real path (`template: :replay`:
  provision plus replay of every tenant migration), which is where the marker row of
  `approval_rule_defaults` is written. The cloned fixture tenant of the other suites carries no marker:
  it stands for an EXISTING tenant (no marker, no rows = ON).

  D1 new tenant, per kind OFF; D2 one person end to end without a second person; D3 explicit ON row stays ON;
  D4 ON then OFF keeps reason and audit; D5 existing tenant stays ON and an explicit row in a new tenant does
  not leak to another tenant (INV-1); D6 the upgrade flips no existing tenant (the migration writes no
  marker into a schema that has a definition or a setting, and no setting row anywhere).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.ApprovalRules
  alias Letflow.Audit.Entry
  alias Letflow.Engine
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Repo
  alias Letflow.Repo.Migrations.CreateApprovalRuleDefaults
  alias Letflow.SodSupport, as: S
  alias Letflow.TenantFixture

  @moduletag timeout: 240_000

  @n1 S.n1()
  @n2 S.n2()
  @version 20_261_120_100_001

  # A NEW tenant (real provisioning path) with an active definition naming `distinct_from` and one instance.
  defp new_tenant_case! do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2391-new", template: :replay)
    case_on!(fx.schema_name)
  end

  # An EXISTING-style tenant (cloned fixture: no marker row).
  defp existing_tenant_case! do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2391-old")
    case_on!(fx.schema_name)
  end

  defp case_on!(schema) do
    definition = S.activate!(schema, S.seq_graph(%{"distinct_from" => [@n1]}), %{})
    instance_id = S.start_instance!(schema, definition, %{"seed" => "value"})
    u = S.insert_user!(schema, "u")
    S.grant_role!(schema, "role-a", [u.id])
    S.grant_role!(schema, "role-b", [u.id])
    %{schema_name: schema, definition: definition, instance_id: instance_id, u: u}
  end

  defp marker_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(~s|SELECT count(*)::int FROM "#{schema}".approval_rule_defaults|)

    n
  end

  defp complete_oidc(ctx, task) do
    Engine.complete_task(
      task.id,
      %{output_variables: %{}, actor_id: ctx.u.id, idempotency_key: S.unique("t2391")},
      prefix: ctx.schema_name,
      credential: :oidc
    )
  end

  defp audit(schema, action),
    do: Entry |> where([a], a.action == ^action) |> Repo.all(prefix: schema)

  defp stamp_registry!(tenant_id, at) do
    from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
    |> Repo.update_all(set: [migrations_applied_at: at])
  end

  defp actor, do: %{user_id: Ecto.UUID.generate(), trace_id: nil}

  test "D1 a new tenant has the marker and every four-eyes step defaults OFF" do
    ctx = new_tenant_case!()
    assert marker_count(ctx.schema_name) == 1
    assert Repo.all(ApprovalRuleSetting, prefix: ctx.schema_name) == []

    assert [%{node_id: @n2, four_eyes: false, changed_at: nil, reason: nil}] =
             ApprovalRules.list(ctx.schema_name)

    assert ApprovalRules.four_eyes_off?(ctx.schema_name, ctx.definition.name, @n2)
  end

  test "D2 one person issues and approves on a new tenant, with no second person and no setting row" do
    ctx = new_tenant_case!()
    S.complete_node!(ctx, @n1, ctx.u.id, %{})
    n2 = S.pending_task!(ctx, @n2)

    assert {:ok, _} = complete_oidc(ctx, n2)
    assert S.reload_task!(ctx, n2).completed_by == ctx.u.id

    assert [entry] = audit(ctx.schema_name, "task.self_approved")
    assert entry.after_state["note"] == "self-approved, four-eyes off"
    assert entry.after_state["same_person_as"] == [@n1]
    assert entry.after_state["setting_source"] == "tenant_default"
    assert entry.after_state["setting_changed_at"] == nil

    # the task screen flag follows the same rule
    assert ApprovalRules.self_approval_allowed?(ctx.schema_name, n2, :oidc)
  end

  test "D3 an explicit ON row on a new tenant stays ON: the self-approval is refused" do
    ctx = new_tenant_case!()

    assert {:ok, %{four_eyes: true}} =
             ApprovalRules.put(
               ctx.schema_name,
               ctx.definition.name,
               @n2,
               %{"four_eyes" => true, "reason" => "we want four eyes"},
               actor()
             )

    S.complete_node!(ctx, @n1, ctx.u.id, %{})
    n2 = S.pending_task!(ctx, @n2)

    assert {:error, :separation_of_duties} = complete_oidc(ctx, n2)
    assert audit(ctx.schema_name, "task.self_approved") == []
    refute ApprovalRules.four_eyes_off?(ctx.schema_name, ctx.definition.name, @n2)
    refute ApprovalRules.self_approval_allowed?(ctx.schema_name, n2, :oidc)
  end

  test "D4 ON then OFF again keeps the reason and writes one audit entry per change" do
    ctx = new_tenant_case!()
    name = ctx.definition.name

    assert {:ok, %{four_eyes: true, reason: "first"}} =
             ApprovalRules.put(
               ctx.schema_name,
               name,
               @n2,
               %{"four_eyes" => true, "reason" => "first"},
               actor()
             )

    assert {:ok, %{four_eyes: false, reason: "second"}} =
             ApprovalRules.put(
               ctx.schema_name,
               name,
               @n2,
               %{"four_eyes" => false, "reason" => "second"},
               actor()
             )

    assert [%{four_eyes: false, reason: "second"}] = ApprovalRules.list(ctx.schema_name)
    changes = audit(ctx.schema_name, "approval_rule.changed")
    assert length(changes) == 2

    assert Enum.sort(Enum.map(changes, & &1.after_state["reason"])) == ["first", "second"]
    # the first change went from the new-tenant default (OFF) to ON
    assert Enum.any?(
             changes,
             &(&1.before_state["four_eyes"] == false and &1.after_state["four_eyes"] == true)
           )
  end

  test "D5 an existing tenant stays ON, and a new tenant's rows never reach it (INV-1)" do
    old = existing_tenant_case!()
    new = new_tenant_case!()
    assert marker_count(old.schema_name) == 0

    assert [%{four_eyes: true}] = ApprovalRules.list(old.schema_name)
    refute ApprovalRules.four_eyes_off?(old.schema_name, old.definition.name, @n2)

    S.complete_node!(old, @n1, old.u.id, %{})
    n2 = S.pending_task!(old, @n2)
    assert {:error, :separation_of_duties} = complete_oidc(old, n2)

    # an explicit ON row in the new tenant does not change the old one, and the reverse
    assert {:ok, _} =
             ApprovalRules.put(
               new.schema_name,
               new.definition.name,
               @n2,
               %{"four_eyes" => true, "reason" => "r"},
               actor()
             )

    assert Repo.all(ApprovalRuleSetting, prefix: old.schema_name) == []
    assert marker_count(new.schema_name) == 1
  end

  test "D6 the upgrade step marks only a fresh schema and writes no setting row" do
    ctx = existing_tenant_case!()
    schema = ctx.schema_name
    opts = [prefix: schema, log: false]

    # the existing tenant already has a definition: the migration writes no marker
    assert :ok = Ecto.Migrator.down(Repo, @version, CreateApprovalRuleDefaults, opts)
    assert :ok = Ecto.Migrator.up(Repo, @version, CreateApprovalRuleDefaults, opts)
    assert marker_count(schema) == 0
    assert Repo.all(ApprovalRuleSetting, prefix: schema) == []
    assert [%{four_eyes: true}] = ApprovalRules.list(schema)

    # an existing tenant with a stored row and no definition is not marked either
    schema2 = TenantFixture.provisioned_tenant!(slug_prefix: "t2391-row").schema_name
    opts2 = [prefix: schema2, log: false]

    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: "kept",
        node_id: "x",
        four_eyes: false,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "r"
      },
      prefix: schema2
    )

    assert :ok = Ecto.Migrator.down(Repo, @version, CreateApprovalRuleDefaults, opts2)
    assert :ok = Ecto.Migrator.up(Repo, @version, CreateApprovalRuleDefaults, opts2)
    assert marker_count(schema2) == 0
    assert [%{four_eyes: false}] = Repo.all(ApprovalRuleSetting, prefix: schema2)

    # an ALREADY-PROVISIONED tenant (registry row stamped) with no definition and no setting yet, for example
    # an onboarded tenant that has not installed a module: NOT marked, it keeps ON (security_deep blocker)
    fx3 = TenantFixture.provisioned_tenant!(slug_prefix: "t2391-fresh")
    schema3 = fx3.schema_name
    opts3 = [prefix: schema3, log: false]
    stamp_registry!(fx3.tenant_id, ~N[2026-01-01 00:00:00])
    assert :ok = Ecto.Migrator.down(Repo, @version, CreateApprovalRuleDefaults, opts3)
    assert :ok = Ecto.Migrator.up(Repo, @version, CreateApprovalRuleDefaults, opts3)
    assert marker_count(schema3) == 0

    # the FIRST provisioning (registry row not yet stamped) of an empty schema is marked
    stamp_registry!(fx3.tenant_id, nil)
    assert :ok = Ecto.Migrator.down(Repo, @version, CreateApprovalRuleDefaults, opts3)
    assert :ok = Ecto.Migrator.up(Repo, @version, CreateApprovalRuleDefaults, opts3)
    assert marker_count(schema3) == 1

    # a schema with no registry row at all (a sandbox-pool schema) is not marked
    sandbox = "sandbox_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Repo.query!(~s|CREATE SCHEMA "#{sandbox}"|)
    on_exit(fn -> Repo.query!(~s|DROP SCHEMA IF EXISTS "#{sandbox}" CASCADE|) end)
    Repo.query!(~s|CREATE TABLE "#{sandbox}".process_definitions (id int)|)
    Repo.query!(~s|CREATE TABLE "#{sandbox}".approval_rule_settings (id int)|)

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateApprovalRuleDefaults,
               prefix: sandbox,
               log: false
             )

    assert marker_count(sandbox) == 0

    # the manifest knows it, seventh to last (T-2415 AllowZeroCountSetLegs, T-2588's audit column,
    # T-2589's platform step table, T-2591's start-permission column and T-2592's rate-limited reason and outbound counters follow)
    assert {@version, CreateApprovalRuleDefaults} =
             Enum.at(Letflow.TenantProvisioning.tenant_scoped_migrations(), -8)
  end
end
