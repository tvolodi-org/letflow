defmodule Letflow.Identity.RoleScopeGrantsBackfillTest do
  @moduledoc """
  REQ-497 / GH #2533 PR 1a, AC3: the repair sweep `Letflow.Identity.RoleScopeGrants.Backfill`
  and the mix task `mix letflow.backfill_role_scope_grants` (design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` sections 4 and 6.4,
  T-B1..T-B8; spec `test/specs/REQ-497-1a.md`).

  Gaps are made the way a pre-release node makes them: a binding or a row written raw, behind
  the writers' back. Every `run/1` test isolates the registrations to its own tenants first
  (`TenantAdminMigrationFixture.isolate_registrations!/1`, restored in `on_exit`): the sweep reads
  every registration, and a committed leftover from elsewhere must not decide these results.

  `async: false`: real tenant schemas, committed writes and DDL, and a registration-wide sweep.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Audit
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.RoleScopeGrants.Backfill
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.TenantAdminMigrationFixture, as: Mig
  alias Letflow.TenantFixture

  @write_sql ~r/^\s*(insert|update|delete|create|drop|alter|truncate|select\s+pg_advisory)/i

  defp seeded_tenant!(slug_prefix) do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    fx
  end

  defp binding_count(schema), do: length(RoleRegistry.seedable_role_names(schema))

  # Deletes the row of one seeded binding (a T9 gap of exactly 1); returns its {group, role}.
  defp open_gap!(schema, role) do
    group_id = group_of!(schema, role)
    assert raw_delete_rows!(schema, group_id, role) == 1
    assert RoleScopeGrants.bindings_without_row_count(schema) == 1
    {group_id, role}
  end

  defp backfill_entries(schema), do: entries(schema, "scope.backfill_completed")

  # The `Mix.Shell.Process` info lines received so far (no wait: they are sent synchronously).
  defp shell_lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | shell_lines()]
    after
      0 -> []
    end
  end

  defp mine(reports, fixtures) do
    ids = Enum.map(fixtures, & &1.tenant_id)
    Enum.filter(reports, &(&1.tenant_id in ids))
  end

  defp create_audit_fault!(schema) do
    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".rsg_audit_fault() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN RAISE EXCEPTION 'injected audit fault (REQ-497 test)'; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER rsg_audit_fault BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".rsg_audit_fault()|
    )
  end

  defp drop_audit_fault!(schema) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS rsg_audit_fault ON "#{schema}".audit_entries|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".rsg_audit_fault()|)
  end

  # Non-raising audit failure (GH 2547 test precedent): under a renamed prefix every table is
  # still there, but the prefix is no longer `tenant_<32 hex>`, so `Audit.insert_entry/3` returns
  # `{:error, :invalid_schema_name}`. Real DDL, reversed in `after`.
  defp with_renamed_schema(schema, fun) do
    "tenant_" <> hex = schema
    renamed = "rsg_" <> hex
    Repo.query!(~s|ALTER SCHEMA "#{schema}" RENAME TO "#{renamed}"|)

    try do
      fun.(renamed)
    after
      Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{schema}"|)
    end
  end

  # ===========================================================================================
  describe "T-B1 / T-B2: run_tenant/2" do
    test "T-B1 an already backfilled tenant: nothing inserted, no entry written" do
      fx = seeded_tenant!("req497-b1")
      s = fx.schema_name
      rows_before = rows(s)

      assert Backfill.run_tenant(s, []) ==
               {:ok,
                %{
                  tenant_id: fx.tenant_id,
                  platform_role_bindings: binding_count(s),
                  group_rows_inserted: 0,
                  bindings_without_row_after: 0,
                  skipped_enforced: false
                }}

      assert rows(s) == rows_before
      assert backfill_entries(s) == []
    end

    test "T-B2 a deleted row: exactly that (principal, role) is re-inserted, reported 1, one backfill_task entry with counts only" do
      fx = seeded_tenant!("req497-b2")
      s = fx.schema_name
      rows_before = rows(s)
      {group_id, role} = open_gap!(s, "TASK_WORKER")

      assert {:ok, %{group_rows_inserted: 1, bindings_without_row_after: 0}} =
               Backfill.run_tenant(s, [])

      assert rows(s) == rows_before
      assert tw(group_id, role) in rows(s)
      assert_t9_zero!(s)

      assert [entry] = backfill_entries(s)
      assert entry.actor_id == nil
      assert entry.resource_type == "role_scope_grants"
      assert entry.resource_id == fx.tenant_id
      assert entry.before_state == nil

      assert entry.after_state == %{
               "source" => "backfill_task",
               "platform_role_bindings" => binding_count(s),
               "group_rows_inserted" => 1,
               "user_rows_inserted" => 0,
               "process_routing_bindings_skipped" => 0,
               "bindings_without_row_after" => 0
             }

      refute inspect(entry.after_state) =~ role
      refute inspect(entry.after_state) =~ group_id
      assert {:ok, :valid} = Audit.verify_chain(s)
    end

    test "T-B8 r1 SEC B1: a binding whose group holds only a scoped row is covered, never widened; an uncovered sibling is repaired" do
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "req497-b8")
      s = fx.schema_name
      node = node!(s)
      scoped_group = fresh_group!(s)
      raw_binding!(s, "TENANT_ADMIN", :platform_role, scoped_group.id)
      raw_scoped_row!(s, scoped_group.id, "TENANT_ADMIN", node)

      assert {:ok, %{group_rows_inserted: 0, platform_role_bindings: 1}} =
               Backfill.run_tenant(s, [])

      assert rows(s) == [scoped(scoped_group.id, "TENANT_ADMIN", node)]
      assert backfill_entries(s) == []

      bare_group = fresh_group!(s)
      raw_binding!(s, "CANDIDATE", :platform_role, bare_group.id)

      assert {:ok, %{group_rows_inserted: 1, platform_role_bindings: 2}} =
               Backfill.run_tenant(s, [])

      assert rows(s) ==
               Enum.sort([
                 scoped(scoped_group.id, "TENANT_ADMIN", node),
                 tw(bare_group.id, "CANDIDATE")
               ])

      assert_t9_zero!(s)
    end
  end

  # ===========================================================================================
  describe "T-B3 / T-B4: run/1 idempotency and dry run" do
    test "T-B3 two runs: the first repairs the gap, the second inserts nothing and writes no entry" do
      fx = seeded_tenant!("req497-b3")
      Mig.isolate_registrations!(fx)
      s = fx.schema_name
      rows_before = rows(s)
      open_gap!(s, "CANDIDATE")

      assert {:ok, first} = Backfill.run([])
      assert first.dry_run == false
      assert first.inserted_total == 1
      assert first.skipped == []
      assert [%{group_rows_inserted: 1}] = mine(first.tenants, [fx])
      assert rows(s) == rows_before
      entries_after_first = backfill_entries(s)
      assert length(entries_after_first) == 1

      assert {:ok, second} = Backfill.run([])
      assert second.inserted_total == 0
      assert [%{group_rows_inserted: 0}] = mine(second.tenants, [fx])
      assert rows(s) == rows_before
      assert backfill_entries(s) == entries_after_first
      assert_t9_zero!(s)
    end

    test "T-B4 dry run: exact report keys, read-only (no write statement, no row, no entry)" do
      fx = seeded_tenant!("req497-b4")
      Mig.isolate_registrations!(fx)
      s = fx.schema_name
      open_gap!(s, "AGENT_RUNNER")
      rows_gap = rows(s)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Backfill.run_tenant(s, dry_run: true)
        end)

      assert result ==
               {:ok,
                %{
                  tenant_id: fx.tenant_id,
                  platform_role_bindings: binding_count(s),
                  bindings_without_row_before: 1,
                  skipped_enforced: false
                }}

      assert queries != []
      refute Enum.any?(queries, &(&1.query =~ @write_sql))

      assert {:ok, report} = Backfill.run(dry_run: true)
      assert report.dry_run == true
      assert report.inserted_total == 0
      assert [%{bindings_without_row_before: 1} = t] = mine(report.tenants, [fx])
      refute Map.has_key?(t, :group_rows_inserted)

      assert rows(s) == rows_gap
      assert RoleScopeGrants.bindings_without_row_count(s) == 1
      assert backfill_entries(s) == []
    end
  end

  # ===========================================================================================
  describe "T-B6 / T-B7: missing schema and failures" do
    test "T-B6 a registration whose schema is gone is skipped and reported; the other tenant is still repaired" do
      gap = seeded_tenant!("req497-b6-gap")
      Mig.isolate_registrations!(gap)
      gone = TenantFixture.provisioned_tenant!(slug_prefix: "req497-b6-gone")
      Repo.query!(~s(DROP SCHEMA "#{gone.schema_name}" CASCADE))
      open_gap!(gap.schema_name, "TASK_WORKER")

      assert {:ok, report} = Backfill.run([])

      assert mine(report.skipped, [gone]) == [
               %{
                 tenant_id: gone.tenant_id,
                 schema_name: gone.schema_name,
                 reason: :tenant_schema_missing
               }
             ]

      assert mine(report.skipped, [gap]) == []
      assert [%{group_rows_inserted: 1}] = mine(report.tenants, [gap])
      assert report.inserted_total == 1
      assert_t9_zero!(gap.schema_name)
    end

    test "T-B7 a non-raising audit failure returns {:audit_failed, tag} and rolls the inserted row back" do
      fx = seeded_tenant!("req497-b7")
      open_gap!(fx.schema_name, "PROCESS_DESIGNER")

      with_renamed_schema(fx.schema_name, fn renamed ->
        assert Backfill.run_tenant(renamed, []) ==
                 {:error, {:audit_failed, :invalid_schema_name}}

        assert RoleScopeGrants.bindings_without_row_count(renamed) == 1
      end)

      assert RoleScopeGrants.bindings_without_row_count(fx.schema_name) == 1
      assert backfill_entries(fx.schema_name) == []
    end

    test "T-B7 a raising audit insert halts run/1 with the exception module only and rolls the row back" do
      fx = seeded_tenant!("req497-b7-raise")
      Mig.isolate_registrations!(fx)
      open_gap!(fx.schema_name, "PROCESS_DESIGNER")
      create_audit_fault!(fx.schema_name)

      try do
        assert Backfill.run([]) ==
                 {:error,
                  {:backfill_failed, fx.tenant_id, {:unexpected_exception, Postgrex.Error}}}
      after
        drop_audit_fault!(fx.schema_name)
      end

      assert RoleScopeGrants.bindings_without_row_count(fx.schema_name) == 1
      assert backfill_entries(fx.schema_name) == []
    end
  end

  # ===========================================================================================
  describe "T-B5: mix letflow.backfill_role_scope_grants" do
    setup do
      original = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original) end)
      :ok
    end

    test "prints the summary and one counts-only line per repaired tenant; no role name or group id" do
      fx = seeded_tenant!("req497-b5")
      Mig.isolate_registrations!(fx)
      {group_id, role} = open_gap!(fx.schema_name, "TENANT_AUDITOR")

      assert Mix.Tasks.Letflow.BackfillRoleScopeGrants.run([]) == :ok
      lines = shell_lines()

      assert Enum.any?(
               lines,
               &(&1 =~
                   ~r/^role_scope_grants backfill complete: \d+ tenant\(s\), 1 row\(s\) inserted, 0 skipped$/)
             )

      assert Enum.any?(lines, &(&1 =~ "tenant #{fx.tenant_id}: 1 row(s) inserted"))
      out = Enum.join(lines, "\n")
      refute out =~ role
      refute out =~ group_id
      assert_t9_zero!(fx.schema_name)
    end

    test "--dry-run prints the gap and writes nothing" do
      fx = seeded_tenant!("req497-b5-dry")
      Mig.isolate_registrations!(fx)
      open_gap!(fx.schema_name, "TENANT_AUDITOR")

      assert Mix.Tasks.Letflow.BackfillRoleScopeGrants.run(["--dry-run"]) == :ok
      lines = shell_lines()

      assert Enum.any?(lines, &(&1 =~ "backfill complete (dry run)"))
      assert Enum.any?(lines, &(&1 =~ "tenant #{fx.tenant_id}: 1 binding(s) without a row"))
      assert RoleScopeGrants.bindings_without_row_count(fx.schema_name) == 1
    end

    test "an unknown switch raises the usage before any work" do
      assert_raise Mix.Error, ~r/usage: mix letflow.backfill_role_scope_grants/, fn ->
        Mix.Tasks.Letflow.BackfillRoleScopeGrants.run(["--bogus"])
      end
    end
  end
end
