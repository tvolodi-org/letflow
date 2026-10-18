defmodule Letflow.Identity.TenantAdminMigrationTest do
  @moduledoc """
  REQ-447 PR 1, PART B, AC5: `Letflow.Identity.TenantAdminMigration.run/1` and `verify/0`, and
  `Letflow.Identity.ApiToken.roles_rewrite_changeset/2`
  (design `lib/letflow/design/req447-tenant-admin-role.md` section 3.8; spec
  `test/specs/REQ-447-PR1.md`, PART B).

  Every tenant is a real provisioned schema (`Letflow.TenantFixture`). The pin is VM-global, so
  `async: false`. The sweep covers every registered tenant, so assertions about the sweep are made
  on the fixture tenants only (looked up by tenant id), never on the whole report.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.TenantAdminMigrationFixture

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantAdminMigration, as: Migration
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  @write_sql ~r/^\s*(insert|update|delete|savepoint|rollback|begin|commit|release|create|drop|alter|truncate)/i

  # --- fixtures -------------------------------------------------------------------

  # What THIS module logs: lines that name the migration. They carry the exception module and the
  # tenant id only; the Ecto/Postgrex debug lines around them are not this module's output.
  defp assert_module_only_log(log, forbidden) do
    own = log |> String.split(~r/\R/) |> Enum.filter(&(&1 =~ "tenant_admin_migration"))
    assert own != []
    assert Enum.all?(own, &(&1 =~ "exception=Postgrex.Error"))

    for text <- forbidden, line <- own do
      refute line =~ text
    end
  end

  defp mine(list, fixtures) do
    ids = Enum.map(fixtures, & &1.tenant_id)
    Enum.filter(list, fn %{tenant_id: id} -> id in ids end)
  end

  defp mine_ids(list, fixtures) do
    ids = Enum.map(fixtures, & &1.tenant_id)
    Enum.filter(list, &(&1 in ids))
  end

  defp role_names(schema),
    do: Repo.all(from(r in TenantRole, select: r.name, order_by: r.name), prefix: schema)

  defp group_member_ids(schema, group_name) do
    Repo.all(
      from(m in GroupMember,
        join: g in Group,
        on: g.id == m.group_id,
        where: g.name == ^group_name,
        select: m.user_id
      ),
      prefix: schema
    )
    |> Enum.sort()
  end

  defp audit_rows(schema, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.id), prefix: schema)
  end

  defp token(schema, id), do: Repo.get!(ApiToken, id, prefix: schema)

  # Every column of a token except `roles`.
  defp fields(%ApiToken{} = t) do
    Map.take(t, [
      :id,
      :user_id,
      :name,
      :token_hash,
      :expires_at,
      :revoked_at,
      :last_used_at,
      :inserted_at
    ])
  end

  # =================================================================================
  describe "AC5: conversion of a non-platform tenant" do
    test "two PLATFORM_ADMIN members and tokens end as TENANT_ADMIN members, no PLATFORM_ADMIN binding, tokens rewritten and otherwise untouched" do
      p = operator_tenant!()
      a = tenant!("req447-a")
      %{group: legacy_group, users: [u1, u2]} = legacy!(a, 2)

      bystander = new_user!(a.schema_name)
      plain = token!(a.schema_name, bystander, ["PROCESS_DESIGNER"])
      t_only = token!(a.schema_name, u1, ["PLATFORM_ADMIN"])
      t_both = token!(a.schema_name, u2, ["PLATFORM_ADMIN", "PROCESS_DESIGNER", "TENANT_ADMIN"])
      t_order = token!(a.schema_name, u2, ["PROCESS_DESIGNER", "PLATFORM_ADMIN"])

      t_revoked =
        a.schema_name
        |> token!(u1, ["PLATFORM_ADMIN"])
        |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)})
        |> Repo.update!(prefix: a.schema_name)

      p_before = snapshot([p])

      assert {:ok, report} = Migration.run(good_opts(p))

      assert report.dry_run == false
      assert report.platform_tenant_id == p.tenant_id
      assert report.would_refuse == []

      assert [rep] = mine(report.migrated, [a])

      assert Map.keys(rep) |> Enum.sort() ==
               Enum.sort([
                 :tenant_id,
                 :slug,
                 :idp_realm_id,
                 :tenant_admin_binding_created,
                 :members_copied,
                 :platform_admin_binding_removed,
                 :tokens_rewritten,
                 :tenant_admin_member_count_after,
                 :rows
               ])

      assert %{
               tenant_id: tid,
               slug: slug,
               idp_realm_id: realm,
               tenant_admin_binding_created: true,
               members_copied: 2,
               platform_admin_binding_removed: true,
               tokens_rewritten: 4,
               tenant_admin_member_count_after: 2
             } = rep

      assert {tid, slug, realm} == {a.tenant_id, a.slug, a.realm}

      # Members: both users now in TENANT_ADMIN, which is bound.
      assert group_member_ids(a.schema_name, "TENANT_ADMIN") == Enum.sort([u1.id, u2.id])
      assert "TENANT_ADMIN" in role_names(a.schema_name)

      # No PLATFORM_ADMIN binding; the legacy group and its members are kept (inert).
      refute "PLATFORM_ADMIN" in role_names(a.schema_name)
      assert %Group{} = Repo.get(Group, legacy_group.id, prefix: a.schema_name)
      assert group_member_ids(a.schema_name, "PLATFORM_ADMIN") == Enum.sort([u1.id, u2.id])

      ta_binding = Repo.get_by!(TenantRole, [name: "TENANT_ADMIN"], prefix: a.schema_name)
      assert ta_binding.kind == :platform_role

      # Tokens: roles rewritten in place (order kept, de-duplicated) and nothing else changed.
      for {before, expected_roles} <- [
            {t_only, ["TENANT_ADMIN"]},
            {t_both, ["TENANT_ADMIN", "PROCESS_DESIGNER"]},
            {t_order, ["PROCESS_DESIGNER", "TENANT_ADMIN"]},
            {t_revoked, ["TENANT_ADMIN"]}
          ] do
        after_row = token(a.schema_name, before.id)
        assert after_row.roles == expected_roles
        assert fields(after_row) == fields(before)
      end

      assert fields(token(a.schema_name, plain.id)) == fields(plain)
      assert token(a.schema_name, plain.id).roles == ["PROCESS_DESIGNER"]

      # The platform tenant is untouched and not in any list of the report.
      assert snapshot([p]) == p_before
      refute p.tenant_id in Enum.map(report.migrated, & &1.tenant_id)
      refute p.tenant_id in report.unchanged
      refute p.tenant_id in Enum.map(report.failed, & &1.tenant_id)
    end

    test "a second run changes nothing: every fixture tenant is unchanged, no row changes, no new audit rows; a member added later to the inert legacy group is NOT promoted" do
      p = operator_tenant!()
      a = tenant!("req447-idem")
      %{group: legacy_group} = legacy!(a, 2)
      u = new_user!(a.schema_name)
      token!(a.schema_name, u, ["PLATFORM_ADMIN"])

      assert {:ok, first} = Migration.run(good_opts(p))
      assert [%{members_copied: 2, tokens_rewritten: 1}] = mine(first.migrated, [a])

      # Added AFTER the migration to the now-unbound legacy group.
      late = member!(a.schema_name, legacy_group, new_user!(a.schema_name))

      before = snapshot([p, a])

      assert {:ok, second} = Migration.run(good_opts(p))

      # The registrations were isolated to this test's tenants, so the WHOLE report can be asserted.
      assert second.migrated == []
      assert second.failed == []
      assert second.unchanged == [a.tenant_id]

      assert snapshot([p, a]) == before
      refute late.id in group_member_ids(a.schema_name, "TENANT_ADMIN")
      assert length(audit_rows(a.schema_name, "role_binding.removed")) == 1
    end

    test "an existing TENANT_ADMIN binding keeps its group: only missing members are copied, and an already-converted tenant with a leftover token is reported with that token" do
      p = operator_tenant!()
      c = tenant!("req447-existing")
      %{users: [u1, u2]} = legacy!(c, 2)

      # An existing binding named TENANT_ADMIN pointing at a differently named group, holding u1.
      custom = group!(c.schema_name, "custom-ta-group")
      bind!(c.schema_name, "TENANT_ADMIN", :platform_role, custom)
      member!(c.schema_name, custom, u1)

      assert {:ok, report} = Migration.run(good_opts(p))

      assert [rep] = mine(report.migrated, [c])
      assert rep.tenant_admin_binding_created == false
      assert rep.members_copied == 1
      assert rep.platform_admin_binding_removed == true
      assert rep.tenant_admin_member_count_after == 2

      assert Repo.get_by!(TenantRole, [name: "TENANT_ADMIN"], prefix: c.schema_name).group_id ==
               custom.id

      assert group_member_ids(c.schema_name, "custom-ta-group") == Enum.sort([u1.id, u2.id])
      # Exactly one group_member.copied entry: the member already present is not re-copied.
      assert [%Entry{resource_id: copied}] = audit_rows(c.schema_name, "group_member.copied")
      assert copied == u2.id
    end

    test "a tenant with nothing to convert but a missing TENANT_ADMIN binding gets the binding with zero members (lockout surfaced as 0)" do
      p = operator_tenant!()
      e = tenant!("req447-empty")

      assert {:ok, report} = Migration.run(good_opts(p))

      assert [rep] = mine(report.migrated, [e])
      assert rep.tenant_admin_binding_created == true
      assert rep.members_copied == 0
      assert rep.platform_admin_binding_removed == false
      assert rep.tokens_rewritten == 0
      assert rep.tenant_admin_member_count_after == 0
      assert "TENANT_ADMIN" in role_names(e.schema_name)
    end

    test "platform_tenant_binding_ensured reports whether the platform tenant has a TENANT_ADMIN binding; the migration never creates it" do
      p = operator_tenant!()

      assert {:ok, %{platform_tenant_binding_ensured: false}} = Migration.run(good_opts(p))
      refute "TENANT_ADMIN" in role_names(p.schema_name)

      bind!(p.schema_name, "TENANT_ADMIN", :platform_role, group!(p.schema_name, "TENANT_ADMIN"))

      assert {:ok, %{platform_tenant_binding_ensured: true}} = Migration.run(good_opts(p))
    end
  end

  describe "ApiToken.roles_rewrite_changeset/2" do
    test "casts only roles: the changes carry no other field, so the hash, name, expiry and revocation cannot move" do
      p = operator_tenant!()
      u = new_user!(p.schema_name)
      row = token!(p.schema_name, u, ["PLATFORM_ADMIN"])

      cs = ApiToken.roles_rewrite_changeset(row, ["TENANT_ADMIN"])

      assert cs.valid?
      assert cs.changes == %{roles: ["TENANT_ADMIN"]}

      # A same-struct update through the changeset leaves every other column as it was.
      {:ok, updated} = Repo.update(cs, prefix: p.schema_name)
      assert fields(updated) == fields(row)
    end
  end

  # =================================================================================
  describe "per-tenant transaction and sweep continuation" do
    test "a tenant failing on a routing role named TENANT_ADMIN is reported with an atom tag only, rolled back, and the sweep continues" do
      p = operator_tenant!()

      # Created first, so it is first in the registration order and the sweep must continue past it.
      f = tenant!("req447-fail")
      a = tenant!("req447-after")

      %{users: [fu]} = legacy!(f, 1)
      token!(f.schema_name, fu, ["PLATFORM_ADMIN"])
      routing = group!(f.schema_name, "routing-group")
      bind!(f.schema_name, "TENANT_ADMIN", :process_routing_role, routing)

      legacy!(a, 1)

      f_before = snapshot([f])

      assert {:ok, report} = Migration.run(good_opts(p))

      assert [failure] = mine(report.failed, [f])
      assert failure.reason == :role_name_taken_by_routing_role
      assert Map.keys(failure) |> Enum.sort() == [:reason, :schema_name, :tenant_id]
      assert is_atom(failure.reason)
      assert failure.schema_name == f.schema_name

      assert snapshot([f]) == f_before

      assert [%{platform_admin_binding_removed: true}] = mine(report.migrated, [a])
      refute "PLATFORM_ADMIN" in role_names(a.schema_name)
    end

    test "a routing role named PLATFORM_ADMIN is reported as platform_admin_name_is_routing_role and never touched" do
      p = operator_tenant!()
      f = tenant!("req447-pa-routing")
      routing = group!(f.schema_name, "routing-pa")
      bind!(f.schema_name, "PLATFORM_ADMIN", :process_routing_role, routing)
      before = snapshot([f])

      assert {:ok, report} = Migration.run(good_opts(p))

      assert [%{reason: :platform_admin_name_is_routing_role}] = mine(report.failed, [f])
      assert snapshot([f]) == before
    end

    test "a failure after earlier writes rolls the whole tenant back (no binding, no copy, no token rewrite) and leaks no exception text" do
      p = operator_tenant!()
      f = tenant!("req447-rollback")
      a = tenant!("req447-rollback-ok")

      %{users: [fu]} = legacy!(f, 1)
      token!(f.schema_name, fu, ["PLATFORM_ADMIN"])
      legacy!(a, 1)

      # The audit insert is the LAST step inside the transaction after binding creation and the copy;
      # dropping its lock table makes it raise (DDL is rolled back with the sandbox).
      Repo.query!(~s(DROP TABLE "#{f.schema_name}".audit_chain_locks CASCADE))
      f_before = snapshot_without_audit(f)

      log =
        capture_log(fn ->
          send(self(), {:report, Migration.run(good_opts(p))})
        end)

      assert_received {:report, {:ok, report}}

      assert [failure] = mine(report.failed, [f])
      assert failure.reason in [:tenant_schema_missing, :unexpected_error]
      assert is_atom(failure.reason)
      assert snapshot_without_audit(f) == f_before
      refute "TENANT_ADMIN" in role_names(f.schema_name)
      assert "PLATFORM_ADMIN" in role_names(f.schema_name)

      assert [%{platform_admin_binding_removed: true}] = mine(report.migrated, [a])

      # The report carries atoms and ids only; the log names the exception MODULE, not its message.
      refute inspect(report) =~ "audit_chain_locks"
      refute inspect(report) =~ "relation"
      assert_module_only_log(log, ["audit_chain_locks", "does not exist"])
    end
  end

  # The audit table's lock table was dropped for this fixture; read the other tables only.
  defp snapshot_without_audit(fx) do
    Map.fetch!(snapshot_tables(fx), fx.schema_name)
  end

  defp snapshot_tables(%{schema_name: s}) do
    %{
      s => %{
        groups: Repo.all(from(g in Group, order_by: g.id, select: {g.id, g.name}), prefix: s),
        members:
          Repo.all(
            from(m in GroupMember,
              order_by: [m.group_id, m.user_id],
              select: {m.group_id, m.user_id}
            ),
            prefix: s
          ),
        roles:
          Repo.all(from(r in TenantRole, order_by: r.id, select: {r.id, r.name, r.group_id}),
            prefix: s
          ),
        tokens: Repo.all(from(t in ApiToken, order_by: t.id, select: {t.id, t.roles}), prefix: s),
        audit: Repo.all(from(e in Entry, order_by: e.id, select: e.id), prefix: s)
      }
    }
  end

  # =================================================================================
  describe "preconditions: each refusal returns the exact tag and writes nothing" do
    setup do
      p = operator_tenant!()
      a = tenant!("req447-pre-a")
      %{users: [u]} = legacy!(a, 1)
      token!(a.schema_name, u, ["PLATFORM_ADMIN"])
      %{p: p, a: a, before: snapshot([p, a])}
    end

    defp assert_refused(opts, tag, fixtures, before) do
      assert Migration.run(opts) == {:error, {:precondition_failed, tag}}
      assert snapshot(fixtures) == before
    end

    test "pin unset", %{p: p, a: a, before: before} do
      Fixture.unpin!()
      assert_refused(good_opts(p), :platform_tenant_not_configured, [p, a], before)
    end

    test "non-UUID pin counts as not configured", %{p: p, a: a, before: before} do
      Fixture.pin!("not-a-uuid")
      assert_refused(good_opts(p), :platform_tenant_not_configured, [p, a], before)
    end

    test "pin is a UUID that is not a registered tenant", %{p: p, a: a, before: before} do
      Fixture.pin!(Ecto.UUID.generate())
      assert_refused(good_opts(p), :platform_tenant_not_registered, [p, a], before)
    end

    test "wrong slug", %{p: p, a: a, before: before} do
      assert_refused(
        [platform_tenant_slug: "not-" <> p.slug, expected_realm_id: p.realm],
        :platform_tenant_slug_mismatch,
        [p, a],
        before
      )
    end

    test "missing slug", %{p: p, a: a, before: before} do
      assert_refused(
        [expected_realm_id: p.realm],
        :platform_tenant_slug_required,
        [p, a],
        before
      )
    end

    test "missing expected_realm_id", %{p: p, a: a, before: before} do
      assert_refused(
        [platform_tenant_slug: p.slug],
        :platform_tenant_realm_required,
        [p, a],
        before
      )
    end

    test "expected_realm_id mismatch", %{p: p, a: a, before: before} do
      assert_refused(
        [platform_tenant_slug: p.slug, expected_realm_id: "other-" <> p.realm],
        :platform_tenant_realm_mismatch,
        [p, a],
        before
      )
    end

    test "no options at all: the first refusal is the slug", %{p: p, a: a, before: before} do
      assert_refused([], :platform_tenant_slug_required, [p, a], before)
    end

    test "pinned tenant without any PLATFORM_ADMIN binding", %{a: a} do
      q = tenant!("req447-pre-nobinding")
      Fixture.pin!(q.tenant_id)
      before = snapshot([q, a])
      assert_refused(good_opts(q), :platform_tenant_has_no_operator, [q, a], before)
    end

    test "pinned tenant whose PLATFORM_ADMIN binding has no members", %{a: a} do
      q = tenant!("req447-pre-nomembers")
      legacy!(q, 0)
      Fixture.pin!(q.tenant_id)
      before = snapshot([q, a])
      assert_refused(good_opts(q), :platform_tenant_has_no_operator, [q, a], before)
    end

    test "pinned tenant whose members sit in a group named PLATFORM_ADMIN that has no binding", %{
      a: a
    } do
      q = tenant!("req447-pre-nobound")
      group = group!(q.schema_name, "PLATFORM_ADMIN")
      member!(q.schema_name, group, new_user!(q.schema_name))
      Fixture.pin!(q.tenant_id)
      before = snapshot([q, a])
      assert_refused(good_opts(q), :platform_tenant_has_no_operator, [q, a], before)
    end

    test "pinned tenant with no realm cannot satisfy any expected realm", %{a: a} do
      q = TenantFixture.provisioned_tenant!(slug_prefix: "req447-pre-norealm")
      legacy!(q, 1)
      Fixture.pin!(q.tenant_id)
      before = snapshot([q, a])

      assert_refused(
        [platform_tenant_slug: q.tenant.slug, expected_realm_id: "anything"],
        :platform_tenant_realm_mismatch,
        [q, a],
        before
      )
    end

    test "a wrong-but-registered pin (an ordinary tenant that holds PLATFORM_ADMIN members) cannot be used to strip the operator without the matching slug AND realm",
         %{p: p, a: a} do
      # The pin points at ordinary tenant A, which has a populated legacy binding.
      Fixture.pin!(a.tenant_id)
      before = snapshot([p, a])

      # The operator's real slug and realm (what infra believes) do not match the pinned tenant.
      assert_refused(good_opts(p), :platform_tenant_slug_mismatch, [p, a], before)

      assert_refused(
        [platform_tenant_slug: a.slug, expected_realm_id: p.realm],
        :platform_tenant_realm_mismatch,
        [p, a],
        before
      )

      assert_refused(
        [platform_tenant_slug: a.slug],
        :platform_tenant_realm_required,
        [p, a],
        before
      )
    end

    test "the precondition checks all pass with the right pin, slug, realm and an operator: the control",
         %{
           p: p
         } do
      assert {:ok, %{dry_run: false}} = Migration.run(good_opts(p))
    end
  end

  # =================================================================================
  describe "dry run" do
    setup do
      p = operator_tenant!()
      a = tenant!("req447-dry-a")
      %{users: [au1, _au2]} = legacy!(a, 2)
      token!(a.schema_name, au1, ["PLATFORM_ADMIN", "PROCESS_DESIGNER"])
      token!(a.schema_name, au1, ["PLATFORM_ADMIN"])

      c = tenant!("req447-dry-c")
      %{users: [cu1, _cu2]} = legacy!(c, 2)
      custom = group!(c.schema_name, "custom-ta")
      bind!(c.schema_name, "TENANT_ADMIN", :platform_role, custom)
      member!(c.schema_name, custom, cu1)

      # Already converted: a TENANT_ADMIN binding and nothing legacy.
      d = tenant!("req447-dry-d")
      bind!(d.schema_name, "TENANT_ADMIN", :platform_role, group!(d.schema_name, "TENANT_ADMIN"))

      %{p: p, a: a, c: c, d: d}
    end

    test "writes nothing: row snapshots and audit counts unchanged, and no write statement is issued",
         %{
           p: p,
           a: a,
           c: c,
           d: d
         } do
      all = [p, a, c, d]
      before = snapshot(all)

      {result, queries} =
        Fixture.capture_repo_queries(fn -> Migration.run(dry_run: true) end)

      assert {:ok, %{dry_run: true}} = result
      assert snapshot(all) == before

      assert queries != []

      write_queries =
        for %{query: q} <- queries, is_binary(q), Regex.match?(@write_sql, q), do: q

      assert write_queries == []

      # Also with valid slug and realm supplied.
      {_, queries2} =
        Fixture.capture_repo_queries(fn -> Migration.run([dry_run: true] ++ good_opts(p)) end)

      assert for(%{query: q} <- queries2, is_binary(q), Regex.match?(@write_sql, q), do: q) == []
      assert snapshot(all) == before
    end

    test "dry-run counts equal a real run's counts on identical data", %{p: p, a: a, c: c, d: d} do
      all = [a, c, d]

      assert {:ok, dry} = Migration.run([dry_run: true] ++ good_opts(p))
      assert {:ok, real} = Migration.run(good_opts(p))

      assert dry.dry_run == true
      assert real.dry_run == false

      sort = &Enum.sort_by(&1, fn %{tenant_id: id} -> id end)
      assert sort.(mine(dry.migrated, all)) == sort.(mine(real.migrated, all))
      assert Enum.sort(mine_ids(dry.unchanged, all)) == Enum.sort(mine_ids(real.unchanged, all))
      assert mine(dry.failed, all) == mine(real.failed, all)
      assert dry.preconditions == real.preconditions
      assert dry.platform_tenant_binding_ensured == real.platform_tenant_binding_ensured

      # The data really exercised three different outcomes.
      assert [%{members_copied: 2, tokens_rewritten: 2, tenant_admin_binding_created: true}] =
               mine(real.migrated, [a])

      assert [%{members_copied: 1, tokens_rewritten: 0, tenant_admin_binding_created: false}] =
               mine(real.migrated, [c])

      assert mine_ids(real.unchanged, [d]) == [d.tenant_id]
      assert [] == mine(real.migrated, [d])
    end

    test "never refuses: every refusal becomes a would_refuse tag, in a fixed order", %{p: p} do
      Fixture.unpin!()

      assert {:ok, %{dry_run: true, would_refuse: [:platform_tenant_not_configured]}} =
               Migration.run(dry_run: true)

      Fixture.pin!("not-a-uuid")

      assert {:ok, %{would_refuse: [:platform_tenant_not_configured]}} =
               Migration.run(dry_run: true)

      Fixture.pin!(Ecto.UUID.generate())

      assert {:ok, %{would_refuse: [:platform_tenant_not_registered]}} =
               Migration.run(dry_run: true)

      Fixture.pin!(p.tenant_id)
      assert {:ok, %{would_refuse: []}} = Migration.run(dry_run: true)
      assert {:ok, %{would_refuse: []}} = Migration.run([dry_run: true] ++ good_opts(p))

      assert {:ok, %{would_refuse: [:platform_tenant_slug_mismatch]}} =
               Migration.run(dry_run: true, platform_tenant_slug: "nope")

      assert {:ok, %{would_refuse: [:platform_tenant_realm_mismatch]}} =
               Migration.run(dry_run: true, expected_realm_id: "nope")

      q = tenant!("req447-dry-noop")
      Fixture.pin!(q.tenant_id)

      assert {:ok,
              %{
                would_refuse: [
                  :platform_tenant_slug_mismatch,
                  :platform_tenant_realm_mismatch,
                  :platform_tenant_has_no_operator
                ]
              }} =
               Migration.run(dry_run: true, platform_tenant_slug: "x", expected_realm_id: "y")

      assert {:ok, %{would_refuse: [:platform_tenant_has_no_operator]}} =
               Migration.run([dry_run: true] ++ good_opts(q))
    end

    test "preconditions are reported: pinned slug, realm, operator count, uuid and registered flags",
         %{p: p} do
      assert {:ok, %{preconditions: pre}} = Migration.run([dry_run: true] ++ good_opts(p))

      assert pre == %{
               pin_configured: true,
               realm_matches_expected: true,
               pin_is_uuid: true,
               registered: true,
               pinned_slug: p.slug,
               pinned_idp_realm_id: p.realm,
               operator_count: 1
             }

      assert {:ok, %{preconditions: %{realm_matches_expected: false}}} =
               Migration.run(dry_run: true, expected_realm_id: "nope")

      assert {:ok, %{preconditions: %{realm_matches_expected: nil}}} =
               Migration.run(dry_run: true)
    end

    test "failed tenants are listed in a dry run too, and do not change would_refuse", %{p: p} do
      f = tenant!("req447-dry-fail")
      routing = group!(f.schema_name, "routing-dry")
      bind!(f.schema_name, "TENANT_ADMIN", :process_routing_role, routing)

      assert {:ok, report} = Migration.run([dry_run: true] ++ good_opts(p))
      assert [%{reason: :role_name_taken_by_routing_role}] = mine(report.failed, [f])
      assert report.would_refuse == []
    end

    test "only an exact dry_run: true is a dry run (\"true\", 1, nil, :yes are real runs and refuse without the options)",
         %{
           p: p,
           a: a,
           c: c,
           d: d
         } do
      before = snapshot([p, a, c, d])

      for not_true <- ["true", 1, :yes, nil, "dry"] do
        assert Migration.run(dry_run: not_true) ==
                 {:error, {:precondition_failed, :platform_tenant_slug_required}}
      end

      assert snapshot([p, a, c, d]) == before

      # And with the options, a non-true value really writes.
      assert {:ok, %{dry_run: false}} = Migration.run([dry_run: "true"] ++ good_opts(p))
      refute snapshot([a]) == Map.take(before, [a.schema_name])
    end
  end

  # =================================================================================
  describe "audit entries and no user attributes" do
    test "group_member.copied carries the user id only, role_binding.removed the name, token.roles_migrated the roles; no user attribute reaches an entry or the report" do
      p = operator_tenant!()
      a = tenant!("req447-audit")
      %{users: [u1, u2]} = legacy!(a, 2)
      t = token!(a.schema_name, u1, ["PLATFORM_ADMIN", "PROCESS_DESIGNER"])

      assert {:ok, report} = Migration.run(good_opts(p))

      copied = audit_rows(a.schema_name, "group_member.copied")
      assert Enum.sort(Enum.map(copied, & &1.resource_id)) == Enum.sort([u1.id, u2.id])

      for e <- copied do
        assert e.actor_id == nil
        assert e.resource_type == "group_member"
        assert e.before_state == nil
        assert e.after_state == %{"user_id" => e.resource_id}
      end

      assert [removed] = audit_rows(a.schema_name, "role_binding.removed")
      assert removed.actor_id == nil
      assert removed.resource_type == "tenant_role"
      assert removed.before_state == %{"name" => "PLATFORM_ADMIN"}
      assert removed.after_state == nil

      assert [migrated] = audit_rows(a.schema_name, "token.roles_migrated")
      assert migrated.actor_id == nil
      assert migrated.resource_type == "api_token"
      assert migrated.resource_id == t.id
      assert migrated.before_state == %{"roles" => ["PLATFORM_ADMIN", "PROCESS_DESIGNER"]}
      assert migrated.after_state == %{"roles" => ["TENANT_ADMIN", "PROCESS_DESIGNER"]}

      all_audit = inspect(Repo.all(Entry, prefix: a.schema_name))

      for u <- [u1, u2] do
        refute all_audit =~ u.email
        refute all_audit =~ u.username
        refute all_audit =~ u.display_name
        refute inspect(report) =~ u.email
        refute inspect(report) =~ u.username
      end

      refute all_audit =~ t.token_hash
      refute inspect(report) =~ t.token_hash

      # The platform tenant got no audit row.
      assert Repo.all(Entry, prefix: p.schema_name) == []
    end
  end

  # =================================================================================
  describe "exceptions are mapped to :unexpected_error and nothing is printed" do
    test "run/1 with the pinned tenant's role table gone returns :unexpected_error (real and dry run), no output, no message in the log" do
      p = operator_tenant!()
      Repo.query!(~s(DROP TABLE "#{p.schema_name}".tenant_role CASCADE))

      out =
        capture_io(fn ->
          log =
            capture_log(fn ->
              send(self(), {:real, Migration.run(good_opts(p))})
              send(self(), {:dry, Migration.run(dry_run: true)})
            end)

          send(self(), {:log, log})
        end)

      assert_received {:real, real}
      assert_received {:dry, dry}
      assert_received {:log, log}

      assert real == {:error, {:precondition_failed, :unexpected_error}}
      assert dry == {:error, {:precondition_failed, :unexpected_error}}
      assert out == ""
      assert_module_only_log(log, ["tenant_role", "does not exist"])
    end

    test "verify/0 returns {:error, :unexpected_error} when a registered tenant's table is gone" do
      p = operator_tenant!()
      a = tenant!("req447-verify-broken")
      Repo.query!(~s(DROP TABLE "#{a.schema_name}".tenant_role CASCADE))

      out =
        capture_io(fn ->
          log = capture_log(fn -> send(self(), {:v, Migration.verify()}) end)
          send(self(), {:log, log})
        end)

      assert_received {:v, v}
      assert_received {:log, log}
      assert v == {:error, :unexpected_error}
      assert out == ""
      assert_module_only_log(log, ["tenant_role", "does not exist"])
      assert p.tenant_id
    end
  end

  # =================================================================================
  describe "verify/0" do
    test "shape and values: the pin flag and one tenant_state per registered tenant, ids/booleans/counts only" do
      p = operator_tenant!()
      a = tenant!("req447-verify")
      %{users: [u1, _u2]} = legacy!(a, 2)
      t = token!(a.schema_name, u1, ["PLATFORM_ADMIN"])
      token!(a.schema_name, u1, ["PROCESS_DESIGNER"])

      out =
        capture_io(fn ->
          send(self(), {:before, Migration.verify()})
        end)

      assert out == ""
      assert_received {:before, {:ok, before}}

      assert Map.keys(before) |> Enum.sort() == [:pin_configured, :tenants]
      assert before.pin_configured == true

      keys =
        Enum.sort([
          :tenant_id,
          :slug,
          :platform_tenant?,
          :platform_admin_binding?,
          :tenant_admin_binding?,
          :tenant_admin_member_count,
          :platform_admin_group_member_count,
          :tokens_with_platform_admin
        ])

      for s <- before.tenants, do: assert(Map.keys(s) |> Enum.sort() == keys)

      assert [pstate] = Enum.filter(before.tenants, &(&1.tenant_id == p.tenant_id))

      assert pstate == %{
               tenant_id: p.tenant_id,
               slug: p.slug,
               platform_tenant?: true,
               platform_admin_binding?: true,
               tenant_admin_binding?: false,
               tenant_admin_member_count: 0,
               platform_admin_group_member_count: 1,
               tokens_with_platform_admin: 0
             }

      assert [astate] = Enum.filter(before.tenants, &(&1.tenant_id == a.tenant_id))

      assert astate == %{
               tenant_id: a.tenant_id,
               slug: a.slug,
               platform_tenant?: false,
               platform_admin_binding?: true,
               tenant_admin_binding?: false,
               tenant_admin_member_count: 0,
               platform_admin_group_member_count: 2,
               tokens_with_platform_admin: 1
             }

      assert {:ok, _} = Migration.run(good_opts(p))
      assert {:ok, after_run} = Migration.verify()
      assert [astate2] = Enum.filter(after_run.tenants, &(&1.tenant_id == a.tenant_id))

      assert astate2 == %{
               astate
               | platform_admin_binding?: false,
                 tenant_admin_binding?: true,
                 tenant_admin_member_count: 2,
                 platform_admin_group_member_count: 0,
                 tokens_with_platform_admin: 0
             }

      # No user attribute and no token anywhere in the returned terms.
      text = inspect({before, after_run}, limit: :infinity)

      for u <- Repo.all(User, prefix: a.schema_name) ++ Repo.all(User, prefix: p.schema_name) do
        refute text =~ u.email
        refute text =~ u.username
        refute text =~ u.display_name
      end

      refute text =~ t.token_hash
    end

    test "pin_configured is false when no pin is set" do
      _p = operator_tenant!()
      Fixture.unpin!()

      assert {:ok, %{pin_configured: false, tenants: tenants}} = Migration.verify()
      assert Enum.all?(tenants, &(&1.platform_tenant? == false))
    end
  end

  # =================================================================================
  describe "release rpc runbook expressions (infra file section 8) evaluate against the test database" do
    @runbook Path.expand("../../../lib/letflow/design/req447-infra-realm-mapping.md", __DIR__)

    # The first fenced block after the line that starts with "Step <letter>".
    defp runbook_expression(letter) do
      # normalise Windows checkouts (autocrlf) so the fence split below is line-ending independent
      text = String.replace(File.read!(@runbook), <<13, 10>>, <<10>>)
      [_before, rest] = String.split(text, "Step #{letter}", parts: 2)
      [_prose, after_fence] = String.split(rest, "```\n", parts: 2)
      [code, _tail] = String.split(after_fence, "\n```", parts: 2)
      String.trim(code)
    end

    defp eval_runbook(code) do
      capture_io(fn -> Code.eval_string(code) end)
    end

    test "steps A, B, D, E, F, G: each prints a result and no ERROR line; E and F with the placeholders substituted behave as the runbook says" do
      p = operator_tenant!()
      a = tenant!("req447-runbook")
      %{users: [u1, u2]} = legacy!(a, 2)
      token!(a.schema_name, u1, ["PLATFORM_ADMIN"])

      # A
      out_a = eval_runbook(runbook_expression("A"))
      assert String.split(String.trim(out_a), "\n") == ["true", "true"]

      # B (read-only state before)
      out_b = eval_runbook(runbook_expression("B"))
      assert out_b =~ "SUMMARY tenants="
      refute out_b =~ "ERROR"
      assert out_b =~ "pin_configured=true"

      assert out_b =~
               "tenant #{a.tenant_id} slug=#{a.slug} platform=false pa_binding=true ta_binding=false"

      # D (dry run)
      before = snapshot([p, a])
      out_d = eval_runbook(runbook_expression("D"))
      assert out_d =~ "SUMMARY dry_run=true"
      refute out_d =~ "ERROR"
      assert out_d =~ "pinned slug=#{p.slug} realm=#{p.realm} operators=1 would_refuse=[]"

      assert out_d =~
               "tenant #{a.tenant_id} slug=#{a.slug} realm=#{a.realm} members_copied=2 tokens=1 binding_removed=true"

      assert snapshot([p, a]) == before

      # E (real run), placeholders substituted from the dry run's own output.
      e_code =
        runbook_expression("E")
        |> String.replace(~s("bpm-default-slug"), inspect(p.slug))
        |> String.replace(
          ~s(expected_realm_id: "bpm-default"),
          "expected_realm_id: #{inspect(p.realm)}"
        )

      refute e_code =~ "bpm-default"

      out_e = eval_runbook(e_code)
      assert out_e =~ "SUMMARY dry_run=false"
      refute out_e =~ "ERROR"

      assert out_e =~
               "tenant #{a.tenant_id} slug=#{a.slug} realm=#{a.realm} members_copied=2 tokens=1 admins_after=2"

      # F (the same expression again: nothing migrated, nothing failed for our tenant)
      after_e = snapshot([p, a])
      out_f = eval_runbook(e_code)
      assert out_f =~ "SUMMARY dry_run=false"
      refute out_f =~ "ERROR"
      refute out_f =~ "tenant #{a.tenant_id}"
      assert out_f =~ "SUMMARY dry_run=false migrated=0 unchanged=1 failed=0"
      refute out_f =~ "FAILED"
      assert snapshot([p, a]) == after_e

      # G (verification)
      out_g = eval_runbook(runbook_expression("G"))
      assert out_g =~ "SUMMARY tenants="
      refute out_g =~ "ERROR"

      assert out_g =~
               "tenant #{a.tenant_id} slug=#{a.slug} platform=false pa_binding=false ta_binding=true ta_members=2 pa_group_members=0 tokens_pa=0"

      assert out_g =~ "slug=#{p.slug} platform=true pa_binding=true"

      # No user attribute in anything the runbook printed.
      for u <- [u1, u2], out <- [out_b, out_d, out_e, out_f, out_g] do
        refute out =~ u.email
        refute out =~ u.username
      end
    end

    test "a wrong slug in step E's expression prints the ERROR precondition line and writes nothing" do
      p = operator_tenant!()
      a = tenant!("req447-runbook-wrong")
      legacy!(a, 1)
      before = snapshot([p, a])

      e_code =
        runbook_expression("E")
        |> String.replace(~s("bpm-default-slug"), ~s("wrong-slug"))
        |> String.replace(
          ~s(expected_realm_id: "bpm-default"),
          "expected_realm_id: #{inspect(p.realm)}"
        )

      out = eval_runbook(e_code)
      assert out =~ "ERROR precondition platform_tenant_slug_mismatch"
      assert snapshot([p, a]) == before
    end
  end
end
