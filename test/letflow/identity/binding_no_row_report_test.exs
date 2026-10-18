defmodule Letflow.Identity.BindingNoRowReportTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 1 state NO-ROW: "no silent skips" (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.5, 3.6, 3.6a, tests
  T-N1..T-N6; spec `test/specs/REQ-519-2e-a.md`). In a tenant stored `on` a writer that cannot
  insert a tenant-wide row writes the binding (or keeps it) WITHOUT one and REPORTS it three
  ways: an explicit result, ONE constant log line (no ids, no names, INV-4) and the T9 query /
  integrity endpoint showing the zero-row binding.

  The log assertions look only at this module's own constant lines (`binding_row_skipped ...`):
  the captured log also holds the Ecto debug QUERY lines, which carry ids and are not output of
  the code under test.

  `async: false`: committed writes and registration-wide sweeps.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.RoleScopeGrants.Backfill
  alias Letflow.Identity.TenantAdminMigration, as: Migration
  alias Letflow.Identity.TenantRole
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TenantAdminMigrationFixture, as: Mig
  alias Letflow.Support.TokenMintFixture

  @role_keys ~w(created_at group_id id kind name)

  setup do
    # The constant lines are Logger.info; make the assertions independent of LOG_LEVEL.
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp skip_lines(log) do
    log |> String.split(~r/\R/) |> Enum.filter(&(&1 =~ "binding_row_skipped"))
  end

  # "binding_row_skipped reason=enforced writer=<x>" for every own line, whatever its prefix.
  defp skip_writers(log) do
    for line <- skip_lines(log),
        [_, writer] <- [
          Regex.run(~r/binding_row_skipped reason=enforced writer=([a-z_]+)$/, line)
        ],
        do: writer
  end

  defp upsert(s, name, kind, group_id),
    do: RoleRegistry.upsert_role_report(name, kind, group_id, prefix: s)

  defp mine(list, fixtures) do
    ids = Enum.map(fixtures, & &1.tenant_id)
    Enum.filter(list, fn %{tenant_id: id} -> id in ids end)
  end

  defp shell_lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | shell_lines()]
    after
      0 -> []
    end
  end

  # ===========================================================================================
  describe "T-N1 upsert_role: the repair of a binding with no row" do
    test "the report says :skipped_enforced, the public shape is unchanged, ONE constant line, no ids" do
      fx = seeded_tenant!("req519-n1", :off)
      s = fx.schema_name
      g = group_of!(s, "PROCESS_DESIGNER")
      assert raw_delete_rows!(s, g, "PROCESS_DESIGNER") == 1
      set_mode!(fx, :on)

      log =
        capture_log(fn ->
          assert {:ok, %TenantRole{}, :skipped_enforced} =
                   upsert(s, "PROCESS_DESIGNER", :platform_role, g)

          # The public upsert_role/4 keeps its two-tuple.
          assert {:ok, %TenantRole{}} =
                   RoleRegistry.upsert_role("PROCESS_DESIGNER", :platform_role, g, prefix: s)
        end)

      assert skip_writers(log) == ["upsert_role", "upsert_role"]

      for line <- skip_lines(log) do
        refute line =~ g
        refute line =~ "PROCESS_DESIGNER"
        refute line =~ fx.tenant_id
      end

      assert rows(s) |> Enum.filter(&(elem(&1, 1) == g)) == []
    end

    test "POST /roles: grant_rows=skipped_enforced appears ONLY for the skipped case" do
      fx = seeded_tenant!("req519-n1h", :off)
      s = fx.schema_name
      g = group_of!(s, "PROCESS_DESIGNER")
      other = group_of!(s, "TASK_WORKER")
      assert raw_delete_rows!(s, g, "PROCESS_DESIGNER") == 1
      set_mode!(fx, :on)

      skipped =
        http(:post, "/roles", fx, %{
          "name" => "PROCESS_DESIGNER",
          "kind" => "platform_role",
          "group_id" => g
        })

      assert skipped.status == 200, skipped.resp_body
      assert body(skipped)["grant_rows"] == "skipped_enforced"

      assert body(skipped) |> Map.delete("grant_rows") |> Map.keys() |> Enum.sort() ==
               @role_keys

      # A binding that HAS its row: the body is byte-identical to the pre-519 shape.
      covered =
        http(:post, "/roles", fx, %{
          "name" => "TASK_WORKER",
          "kind" => "platform_role",
          "group_id" => other
        })

      assert covered.status == 200, covered.resp_body
      assert body(covered) |> Map.keys() |> Enum.sort() == @role_keys
    end
  end

  # ===========================================================================================
  describe "T-N2 rebind_role" do
    test "zero rows moving is skipped (and reported); a scoped row that follows the binding is not" do
      fx = tenant!("req519-n2", :off)
      s = fx.schema_name
      g = group!(fx)
      target = group!(fx)
      role = raw_binding!(s, "PROCESS_DESIGNER", :platform_role, g.id)
      set_mode!(fx, :on)

      log =
        capture_log(fn ->
          conn =
            http(:post, "/roles/#{role.id}/rebind", fx, %{
              "group_id" => target.id,
              "reason" => "REQ-519 rebind with no rows"
            })

          assert conn.status == 200, conn.resp_body
          assert body(conn)["grant_rows"] == "skipped_enforced"
          assert body(conn)["group_id"] == target.id
        end)

      assert skip_writers(log) == ["rebind_role"]
      assert rows(s) == []
      assert RoleScopeGrants.bindings_without_row_count(s) == 1

      # The scoped row follows a binding to its new group (UNCHANGED), no key in the body.
      other = group!(fx)
      node = make_group_scoped_only!(s, target.id, "PROCESS_DESIGNER")

      moved =
        http(:post, "/roles/#{role.id}/rebind", fx, %{
          "group_id" => other.id,
          "reason" => "REQ-519 rebind with a scoped row"
        })

      assert moved.status == 200, moved.resp_body
      refute Map.has_key?(body(moved), "grant_rows")
      assert rows(s) == [scoped(other.id, "PROCESS_DESIGNER", node)]
    end
  end

  # ===========================================================================================
  describe "T-N3 seeding and the RoleBackfill sweep" do
    test "the report names the skipped roles; the public shape and the audit key rows=skipped_enforced" do
      fx = tenant!("req519-n3a", :off)
      s = fx.schema_name
      # A group named after the role, with a member, so the binding write is audited.
      tw_group = group!(s, "TASK_WORKER")
      _member = member!(s, tw_group.id, user!(s))
      set_mode!(fx, :on)

      log =
        capture_log(fn ->
          assert {:ok, %{roles: roles, skipped_enforced: skipped}} =
                   RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

          assert length(roles) == length(RoleRegistry.seedable_role_names(s))
          assert Enum.sort(skipped) == Enum.sort(RoleRegistry.seedable_role_names(s))
        end)

      assert length(skip_writers(log)) == length(RoleRegistry.seedable_role_names(s))
      assert Enum.uniq(skip_writers(log)) == ["seeding"]

      assert rows(s) == []

      assert RoleScopeGrants.bindings_without_row_count(s) ==
               length(RoleRegistry.seedable_role_names(s))

      # The fixed audit key: present exactly on the binding that was created without a row.
      assert [created] = entries(s, "role_binding.created")
      assert created.after_state["name"] == "TASK_WORKER"
      assert created.after_state["rows"] == "skipped_enforced"
    end

    test "the audit key rows is ABSENT when the binding gets its row (off and shadow)" do
      for mode <- [:off, :shadow] do
        fx = tenant!("req519-n3k-#{mode}", mode)
        s = fx.schema_name
        tw_group = group!(s, "TASK_WORKER")
        _member = member!(s, tw_group.id, user!(s))

        assert {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: s)
        assert [created] = entries(s, "role_binding.created")
        refute Map.has_key?(created.after_state, "rows")
      end
    end

    test "RoleBackfill.run/0 lists the on tenant under skipped_enforced and carries on to the next tenant" do
      first = tenant!("req519-n3b-first", :off)
      Mig.isolate_registrations!(first)
      on_tenant = tenant!("req519-n3b-on", :on)
      off_tenant = tenant!("req519-n3b-off", :off)
      names = RoleRegistry.seedable_role_names(on_tenant.schema_name)

      assert {:ok, result} = RoleBackfill.run()

      assert result.skipped_enforced == [on_tenant.tenant_id]
      assert on_tenant.tenant_id in result.seeded
      assert off_tenant.tenant_id in result.seeded
      assert first.tenant_id in result.seeded

      # The on tenant: bindings, no rows. The tenants swept around it: bindings AND rows.
      assert RoleScopeGrants.bindings_without_row_count(on_tenant.schema_name) == length(names)
      assert rows(on_tenant.schema_name) == []
      assert_t9_zero!(off_tenant.schema_name)
      assert_t9_zero!(first.schema_name)
      assert length(rows(off_tenant.schema_name)) == length(names)
    end

    test "chain: a tenant seeded while on carries a T9 gap that blocks the reachable gate (off -> shadow)" do
      fx = tenant!("req519-n3c", :on)
      s = fx.schema_name

      assert {:ok, %{skipped_enforced: [_ | _]}} =
               RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

      # No route sets on yet; take the tenant back down by the fixture and try to enable shadow.
      set_mode!(fx, :off)

      assert {:error, {:precondition_failed, failed, report}} =
               ScopeEnforcement.flip(fx.tenant_id, s, :shadow, %{
                 actor_id: nil,
                 reason: nil,
                 trace_id: nil
               })

      assert :bindings_without_row in failed
      assert report.bindings_without_row == length(RoleRegistry.seedable_role_names(s))
    end
  end

  # ===========================================================================================
  describe "T-N4 TenantAdminMigration: an on tenant is skipped and reported" do
    test "real run: rows=:skipped_enforced, zero counts, nothing written, one constant line" do
      p = Mig.operator_tenant!()
      a = Mig.tenant!("req519-n4")
      %{users: [_u1]} = Mig.legacy!(a, 1)
      set_mode!(a, :on)
      before = Mig.snapshot([a])

      log =
        capture_log(fn ->
          assert {:ok, report} = Migration.run(Mig.good_opts(p))
          assert [rep] = mine(report.migrated, [a])
          assert rep.rows == :skipped_enforced
          assert rep.tenant_admin_binding_created == false
          assert rep.members_copied == 0
          assert rep.platform_admin_binding_removed == false
          assert rep.tokens_rewritten == 0
          assert rep.tenant_admin_member_count_after == 0
          assert mine(report.failed, [a]) == []
        end)

      assert "tenant_admin_migration" in skip_writers(log)
      assert Mig.snapshot([a]) == before
    end

    test "dry run reads the mode without a lock and reports the same skip, writing nothing" do
      p = Mig.operator_tenant!()
      a = Mig.tenant!("req519-n4d")
      Mig.legacy!(a, 1)
      set_mode!(a, :on)
      before = Mig.snapshot([a])

      assert {:ok, report} = Migration.run(Keyword.put(Mig.good_opts(p), :dry_run, true))
      assert [rep] = mine(report.migrated, [a])
      assert rep.rows == :skipped_enforced
      assert Mig.snapshot([a]) == before
    end
  end

  # ===========================================================================================
  describe "T-N5a Backfill.run_tenant in an enforced tenant (real run)" do
    test "no error, no audit entry, no row inserted, T9 unchanged, the report flags it" do
      fx = seeded_tenant!("req519-n5a", :off)
      s = fx.schema_name
      g = group_of!(s, "TENANT_AUDITOR")
      assert raw_delete_rows!(s, g, "TENANT_AUDITOR") == 1
      set_mode!(fx, :on)
      rows_before = rows(s)

      log =
        capture_log(fn ->
          assert Backfill.run_tenant(s, []) ==
                   {:ok,
                    %{
                      tenant_id: fx.tenant_id,
                      platform_role_bindings: length(RoleRegistry.seedable_role_names(s)),
                      group_rows_inserted: 0,
                      bindings_without_row_after: 1,
                      skipped_enforced: true
                    }}
        end)

      assert skip_writers(log) == ["backfill"]
      assert rows(s) == rows_before
      assert RoleScopeGrants.bindings_without_row_count(s) == 1
      assert entries(s, "scope.backfill_completed") == []
    end
  end

  describe "T-N5b Backfill dry run" do
    test "an on tenant is flagged via get_mode/1, an off tenant is not, and it never errors" do
      on = seeded_tenant!("req519-n5b-on", :on)
      off = seeded_tenant!("req519-n5b-off", :off)

      assert {:ok, %{skipped_enforced: true, bindings_without_row_before: 0}} =
               Backfill.run_tenant(on.schema_name, dry_run: true)

      assert {:ok, %{skipped_enforced: false}} =
               Backfill.run_tenant(off.schema_name, dry_run: true)
    end

    test "an unreadable or absent mode reports false and does not error the dry run" do
      fx = seeded_tenant!("req519-n5b-unreg", :on)
      "tenant_" <> hex = fx.schema_name
      renamed = "rsg_" <> hex
      Repo.query!(~s|ALTER SCHEMA "#{fx.schema_name}" RENAME TO "#{renamed}"|)

      try do
        assert {:ok, %{skipped_enforced: false, tenant_id: nil}} =
                 Backfill.run_tenant(renamed, dry_run: true)
      after
        Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{fx.schema_name}"|)
      end
    end
  end

  describe "T-N5c a sweep over an on tenant followed by an off tenant" do
    test "the on tenant is skipped without halting; the off tenant is repaired; the result names the skip" do
      on = seeded_tenant!("req519-n5c-on", :off)
      Mig.isolate_registrations!(on)
      off = seeded_tenant!("req519-n5c-off", :off)

      on_group = group_of!(on.schema_name, "TASK_WORKER")
      off_group = group_of!(off.schema_name, "TASK_WORKER")
      assert raw_delete_rows!(on.schema_name, on_group, "TASK_WORKER") == 1
      assert raw_delete_rows!(off.schema_name, off_group, "TASK_WORKER") == 1
      set_mode!(on, :on)

      assert {:ok, report} = Backfill.run([])

      assert report.skipped_enforced_tenants == [on.tenant_id]
      assert report.inserted_total == 1
      assert [%{skipped_enforced: true}] = mine(report.tenants, [on])
      assert [%{skipped_enforced: false, group_rows_inserted: 1}] = mine(report.tenants, [off])
      assert_t9_zero!(off.schema_name)
      assert RoleScopeGrants.bindings_without_row_count(on.schema_name) == 1
    end
  end

  describe "T-N5 the mix task output" do
    setup do
      original = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original) end)
      :ok
    end

    test "prints one counts-only skipped_enforced line per on tenant; no role name, no group id" do
      fx = seeded_tenant!("req519-n5-mix", :off)
      Mig.isolate_registrations!(fx)
      g = group_of!(fx.schema_name, "TENANT_AUDITOR")
      assert raw_delete_rows!(fx.schema_name, g, "TENANT_AUDITOR") == 1
      set_mode!(fx, :on)

      assert Mix.Tasks.Letflow.BackfillRoleScopeGrants.run([]) == :ok
      lines = shell_lines()

      assert Enum.any?(
               lines,
               &(&1 == "  tenant #{fx.tenant_id}: skipped_enforced (1 binding(s) without a row)")
             )

      out = Enum.join(lines, "\n")
      refute out =~ "TENANT_AUDITOR"
      refute out =~ g
      assert Enum.any?(lines, &(&1 =~ ~r/0 row\(s\) inserted/))
    end

    test "the dry run prints the same line" do
      fx = seeded_tenant!("req519-n5-mixd", :off)
      Mig.isolate_registrations!(fx)
      set_mode!(fx, :on)

      assert Mix.Tasks.Letflow.BackfillRoleScopeGrants.run(["--dry-run"]) == :ok

      assert Enum.any?(
               shell_lines(),
               &(&1 == "  tenant #{fx.tenant_id}: skipped_enforced (0 binding(s) without a row)")
             )
    end
  end

  # ===========================================================================================
  describe "T-N6 the T9 query and the integrity endpoint show the zero-row binding" do
    test "T9 counts and lists it; GET /integrity reports it (read after the tenant is stored shadow)" do
      Fixture.unpin!()
      fx = tenant!("req519-n6", :off)
      s = fx.schema_name
      g = group!(fx)
      binding = raw_binding!(s, "PROCESS_DESIGNER", :platform_role, g.id)
      set_mode!(fx, :on)

      # The repair path in `on`: skipped, binding stays without a row.
      assert {:ok, %TenantRole{}, :skipped_enforced} =
               upsert(s, "PROCESS_DESIGNER", :platform_role, g.id)

      assert RoleScopeGrants.bindings_without_row_count(s) == 1

      assert [%{name: "PROCESS_DESIGNER", group_id: group_id}] =
               RoleScopeGrants.bindings_without_row(s)

      assert group_id == g.id

      assert %{bindings_without_row: 1, items: [%{role_id: role_id}]} =
               ScopeEnforcement.integrity(s)

      assert role_id == binding.id

      # The endpoint (a tenant-wide TENANT_ADMIN, interactive) reports the same zero-row binding.
      set_mode!(fx, :shadow)
      admin = TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"])

      conn =
        :get
        |> Fixture.router_conn("/integrity", fx, ["TENANT_ADMIN"], nil)
        |> Plug.Conn.assign(:auth_context, %{
          user_id: admin.id,
          tenant_id: fx.tenant_id,
          roles: ["TENANT_ADMIN"],
          credential: :oidc
        })
        |> Plug.Conn.assign(:trace_id, trace())
        |> Letflow.Routers.TenantScopeEnforcement.call(
          Letflow.Routers.TenantScopeEnforcement.init([])
        )

      assert conn.status == 200, conn.resp_body
      assert %{"bindings_without_row" => 1, "items" => [item]} = body(conn)
      assert item == %{"role_id" => binding.id, "name" => "PROCESS_DESIGNER", "group_id" => g.id}
    end
  end
end
