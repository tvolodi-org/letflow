defmodule Letflow.Identity.RoleScopeGrantsTest do
  @moduledoc """
  REQ-497 / GH #2533 PR 1a, AC1/AC2: the core module `Letflow.Identity.RoleScopeGrants` and the
  schema `Letflow.Identity.RoleScopeGrant` (design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` sections 2.1, 2.2 and
  6.2, T-C1..T-C4; spec `test/specs/REQ-497-1a.md`).

  T-C1 drives `reconcile_widening!/3` and `reconcile_non_widening!/3` (GH #2848: the split of
  the former `reconcile_binding!/3`) through every row of the decision table with in-memory
  `TenantRole` structs (the function reads only `kind`, `group_id` and `name`; `principal_id`
  has no FK), each inside a transaction that holds lock A, as every binding writer calls it.
  The r1 cases (j)-(l) pin SEC B1: a repair never widens a group holding only a scoped row.

  Real tenant schema (`TenantFixture`), committed writes, so `async: false`.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  setup do
    _ = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req497-core")
    {:ok, schema: tenant.schema_name}
  end

  defp p(name, group_id), do: %TenantRole{name: name, kind: :platform_role, group_id: group_id}

  defp r(name, group_id),
    do: %TenantRole{name: name, kind: :process_routing_role, group_id: group_id}

  # As a binding writer calls it: inside a transaction, after lock A.
  defp in_tx(schema, fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        :ok = Identity.lock_tenant_admins!(schema)
        fun.()
      end)

    result
  end

  defp platform?(%TenantRole{kind: :platform_role}), do: true
  defp platform?(_binding), do: false

  # The entry point each binding writer picks: a write that creates a platform binding is the
  # widening one, every other shape is the non-widening one.
  defp reconcile!(schema, before_binding, after_binding) do
    in_tx(schema, fn ->
      if platform?(after_binding) and not platform?(before_binding) do
        RoleScopeGrants.reconcile_widening!(before_binding, after_binding, schema)
      else
        RoleScopeGrants.reconcile_non_widening!(before_binding, after_binding, schema)
      end
    end)
  end

  defp group_rows(schema, group_id) do
    schema |> rows() |> Enum.filter(fn {_, pid, _, _, _} -> pid == group_id end)
  end

  defp ids_and_stamps(schema, group_id),
    do: schema |> group_structs(group_id) |> Enum.map(&{&1.id, &1.updated_at})

  # ===========================================================================================
  describe "GH #2848: the entry points refuse the other direction (no row is written)" do
    test "reconcile_widening!/3 raises on a binding that was already a platform role", %{
      schema: s
    } do
      g = Ecto.UUID.generate()
      raw_tenant_wide_row!(s, g, "TASK_WORKER")
      before = rows(s)

      assert_raise ArgumentError, ~r/use reconcile_non_widening!\/3/, fn ->
        in_tx(s, fn ->
          apply(RoleScopeGrants, :reconcile_widening!, [
            p("TASK_WORKER", g),
            p("TASK_WORKER", g),
            s
          ])
        end)
      end

      assert rows(s) == before
    end

    test "reconcile_widening!/3 answers :ok for a removal shape (routing or nil after)", %{
      schema: s
    } do
      g = Ecto.UUID.generate()
      assert in_tx(s, fn -> RoleScopeGrants.reconcile_widening!(r("rsg-x", g), nil, s) end) == :ok
      assert group_rows(s, g) == []
    end

    test "reconcile_non_widening!/3 raises on a binding that becomes a platform role", %{
      schema: s
    } do
      g = Ecto.UUID.generate()
      before = rows(s)

      assert_raise ArgumentError, ~r/use reconcile_widening!\/3/, fn ->
        in_tx(s, fn ->
          RoleScopeGrants.reconcile_non_widening!(nil, p("TASK_WORKER", g), s)
        end)
      end

      assert_raise ArgumentError, ~r/use reconcile_widening!\/3/, fn ->
        in_tx(s, fn ->
          RoleScopeGrants.reconcile_non_widening!(r("rsg-y", g), p("TASK_WORKER", g), s)
        end)
      end

      assert rows(s) == before
    end
  end

  describe "T-C1: reconcile_widening!/3 and reconcile_non_widening!/3 decision table" do
    test "nil -> P inserts one tenant-wide row; nil -> not P writes nothing", %{schema: s} do
      g = Ecto.UUID.generate()
      assert reconcile!(s, nil, p("TASK_WORKER", g)) == :ok
      assert group_rows(s, g) == [tw(g, "TASK_WORKER")]

      h = Ecto.UUID.generate()
      assert reconcile!(s, nil, r("rsg-route", h)) == :ok
      assert group_rows(s, h) == []
    end

    test "P -> P same group: a covered binding is left byte-identical; an uncovered one gets exactly one row",
         %{schema: s} do
      covered = Ecto.UUID.generate()
      raw_tenant_wide_row!(s, covered, "TASK_WORKER")
      before = ids_and_stamps(s, covered)

      assert reconcile!(s, p("TASK_WORKER", covered), p("TASK_WORKER", covered)) == :ok
      assert ids_and_stamps(s, covered) == before

      # (k) no row at all: the repair inserts exactly one tenant-wide row.
      bare = Ecto.UUID.generate()
      assert reconcile!(s, p("TASK_WORKER", bare), p("TASK_WORKER", bare)) == :ok
      assert group_rows(s, bare) == [tw(bare, "TASK_WORKER")]
    end

    test "(j) r1 SEC B1: P -> P same group with ONLY a scoped row is not widened to tenant-wide",
         %{schema: s} do
      node = node!(s)
      g = Ecto.UUID.generate()
      raw_scoped_row!(s, g, "TENANT_ADMIN", node)
      before = ids_and_stamps(s, g)

      assert reconcile!(s, p("TENANT_ADMIN", g), p("TENANT_ADMIN", g)) == :ok

      assert group_rows(s, g) == [scoped(g, "TENANT_ADMIN", node)]
      assert ids_and_stamps(s, g) == before
      refute Enum.any?(group_rows(s, g), fn {_, _, _, _, tw?} -> tw? end)
    end

    test "P -> P other group moves every row (tenant-wide and scoped) and clears a stale row on the target",
         %{schema: s} do
      node = node!(s)
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      raw_tenant_wide_row!(s, a, "PROCESS_OPERATOR")
      raw_scoped_row!(s, a, "PROCESS_OPERATOR", node)
      # A row of ANOTHER role on A stays where it is.
      raw_tenant_wide_row!(s, a, "TASK_WORKER")
      # A stale orphan on the target for the same role.
      raw_tenant_wide_row!(s, b, "PROCESS_OPERATOR")
      [stale] = group_structs(s, b)

      moved_ids =
        s
        |> group_structs(a)
        |> Enum.filter(&(&1.role == "PROCESS_OPERATOR"))
        |> Enum.map(& &1.id)

      assert reconcile!(s, p("PROCESS_OPERATOR", a), p("PROCESS_OPERATOR", b)) == :ok

      assert group_rows(s, a) == [tw(a, "TASK_WORKER")]

      assert group_rows(s, b) ==
               Enum.sort([tw(b, "PROCESS_OPERATOR"), scoped(b, "PROCESS_OPERATOR", node)])

      b_ids = s |> group_structs(b) |> Enum.map(& &1.id) |> Enum.sort()
      assert b_ids == Enum.sort(moved_ids)
      refute stale.id in b_ids
    end

    test "P -> P other group with no row on the source repairs the target with one tenant-wide row",
         %{schema: s} do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      assert reconcile!(s, p("CANDIDATE", a), p("CANDIDATE", b)) == :ok
      assert group_rows(s, a) == []
      assert group_rows(s, b) == [tw(b, "CANDIDATE")]
    end

    test "P -> not P and P -> nil remove every row of (group, role), tenant-wide and scoped, and nothing else",
         %{schema: s} do
      node = node!(s)

      for after_fun <- [&r("AGENT_RUNNER", &1), fn _g -> nil end] do
        g = Ecto.UUID.generate()
        raw_tenant_wide_row!(s, g, "AGENT_RUNNER")
        raw_scoped_row!(s, g, "AGENT_RUNNER", node)
        raw_tenant_wide_row!(s, g, "TASK_WORKER")

        assert reconcile!(s, p("AGENT_RUNNER", g), after_fun.(g)) == :ok
        assert group_rows(s, g) == [tw(g, "TASK_WORKER")]
      end
    end

    test "not P -> P inserts the tenant-wide row unconditionally (1b-2 case (i), pinned as the 1a behaviour)",
         %{schema: s} do
      g = Ecto.UUID.generate()
      assert reconcile!(s, r("TENANT_AUDITOR", g), p("TENANT_AUDITOR", g)) == :ok
      assert group_rows(s, g) == [tw(g, "TENANT_AUDITOR")]

      # Unconditional: even next to a scoped row (design 2.2, carried to 1b/#2535 as 1b-2 (i)).
      node = node!(s)
      h = Ecto.UUID.generate()
      raw_scoped_row!(s, h, "TENANT_AUDITOR", node)
      assert reconcile!(s, r("TENANT_AUDITOR", h), p("TENANT_AUDITOR", h)) == :ok

      assert group_rows(s, h) ==
               Enum.sort([scoped(h, "TENANT_AUDITOR", node), tw(h, "TENANT_AUDITOR")])
    end

    test "not P -> not P and not P -> nil write and delete nothing", %{schema: s} do
      g = Ecto.UUID.generate()
      # A row that a wrong removal would hit (same group, same name).
      raw_tenant_wide_row!(s, g, "TASK_WORKER")
      before = rows(s)

      assert reconcile!(s, r("TASK_WORKER", g), r("TASK_WORKER", g)) == :ok
      assert reconcile!(s, r("TASK_WORKER", g), nil) == :ok
      assert reconcile!(s, nil, nil) == :ok
      assert rows(s) == before
    end

    test "outside a transaction every writer raises ArgumentError and writes nothing", %{
      schema: s
    } do
      g = Ecto.UUID.generate()
      raw_tenant_wide_row!(s, g, "TASK_WORKER")
      before = rows(s)
      other = Ecto.UUID.generate()

      assert_raise ArgumentError, fn ->
        RoleScopeGrants.reconcile_widening!(nil, p("CANDIDATE", other), s)
      end

      assert_raise ArgumentError, fn ->
        RoleScopeGrants.repair_group_row!(other, "CANDIDATE", s)
      end

      assert_raise ArgumentError, fn ->
        RoleScopeGrants.remove_group_rows!(g, "TASK_WORKER", s)
      end

      assert_raise ArgumentError, fn ->
        RoleScopeGrants.move_group_rows!("TASK_WORKER", g, other, s)
      end

      assert_raise ArgumentError, fn -> RoleScopeGrants.delete_group_principal_rows!(g, s) end

      assert rows(s) == before
    end

    test "(l) repair_group_row!/3 returns :covered for a scoped-only or tenant-wide group, :inserted for a bare one; ensure is idempotent",
         %{schema: s} do
      node = node!(s)
      scoped_only = Ecto.UUID.generate()
      raw_scoped_row!(s, scoped_only, "TENANT_ADMIN", node)
      wide = Ecto.UUID.generate()
      raw_tenant_wide_row!(s, wide, "TENANT_ADMIN")
      bare = Ecto.UUID.generate()

      assert in_tx(s, fn -> RoleScopeGrants.repair_group_row!(scoped_only, "TENANT_ADMIN", s) end) ==
               :covered

      assert in_tx(s, fn -> RoleScopeGrants.repair_group_row!(wide, "TENANT_ADMIN", s) end) ==
               :covered

      assert in_tx(s, fn -> RoleScopeGrants.repair_group_row!(bare, "TENANT_ADMIN", s) end) ==
               :inserted

      assert group_rows(s, scoped_only) == [scoped(scoped_only, "TENANT_ADMIN", node)]
      assert group_rows(s, wide) == [tw(wide, "TENANT_ADMIN")]
      assert group_rows(s, bare) == [tw(bare, "TENANT_ADMIN")]

      assert in_tx(s, fn ->
               RoleScopeGrants.ensure_tenant_wide_group_row!(bare, "TENANT_ADMIN", s)
             end) ==
               :exists

      assert group_rows(s, bare) == [tw(bare, "TENANT_ADMIN")]
    end
  end

  # ===========================================================================================
  describe "T-C2: bindings_without_row/1 and bindings_without_row_count/1 (T9)" do
    test "empty on a clean tenant; lists uncovered platform bindings by name; never a routing binding; a scoped row covers",
         %{schema: s} do
      assert RoleScopeGrants.bindings_without_row(s) == []
      assert RoleScopeGrants.bindings_without_row_count(s) == 0

      g1 = fresh_group!(s)
      g2 = fresh_group!(s)
      g3 = fresh_group!(s)
      g4 = fresh_group!(s)
      tw_b = raw_binding!(s, "TENANT_ADMIN", :platform_role, g1.id)
      cand = raw_binding!(s, "CANDIDATE", :platform_role, g2.id)
      _routing = raw_binding!(s, "rsg-route-x", :process_routing_role, g3.id)
      scoped_b = raw_binding!(s, "TASK_WORKER", :platform_role, g4.id)
      raw_scoped_row!(s, g4.id, "TASK_WORKER", node!(s))

      assert RoleScopeGrants.bindings_without_row(s) == [
               %{role_id: cand.id, name: "CANDIDATE", group_id: g2.id},
               %{role_id: tw_b.id, name: "TENANT_ADMIN", group_id: g1.id}
             ]

      assert RoleScopeGrants.bindings_without_row_count(s) == 2
      refute Enum.any?(RoleScopeGrants.bindings_without_row(s), &(&1.role_id == scoped_b.id))

      # A row for the right group but the wrong role does not cover.
      raw_tenant_wide_row!(s, g1.id, "CANDIDATE")
      assert RoleScopeGrants.bindings_without_row_count(s) == 2

      # A user row never covers a group binding.
      assert RoleScopeGrants.user_row_count(s) == 0
    end
  end

  # ===========================================================================================
  describe "T-C3: parity of the application T9 with the migration's frozen assert" do
    test "both see the same gap (count 1 vs raise) and both report 0 / :ok after the repair", %{
      schema: s
    } do
      assert migration().assert_no_gap!(s) == :ok
      assert RoleScopeGrants.bindings_without_row_count(s) == 0

      g = fresh_group!(s)
      raw_binding!(s, "PROCESS_DESIGNER", :platform_role, g.id)
      # A routing binding counts for neither.
      raw_binding!(s, "rsg-route-parity", :process_routing_role, fresh_group!(s).id)

      assert RoleScopeGrants.bindings_without_row_count(s) == 1

      assert_raise RuntimeError, "role_scope_grants backfill gap: 1", fn ->
        migration().assert_no_gap!(s)
      end

      # A scoped-only row covers for both.
      node = node!(s)
      raw_scoped_row!(s, g.id, "PROCESS_DESIGNER", node)
      assert RoleScopeGrants.bindings_without_row_count(s) == 0
      assert migration().assert_no_gap!(s) == :ok

      raw_delete_rows!(s, g.id, "PROCESS_DESIGNER")
      assert RoleScopeGrants.bindings_without_row_count(s) == 1
      assert_raise RuntimeError, fn -> migration().assert_no_gap!(s) end

      assert in_tx(s, fn -> RoleScopeGrants.repair_group_row!(g.id, "PROCESS_DESIGNER", s) end) ==
               :inserted

      assert RoleScopeGrants.bindings_without_row_count(s) == 0
      assert migration().assert_no_gap!(s) == :ok
    end
  end

  # ===========================================================================================
  describe "T-C4: orphan_group_rows/1 and RoleScopeGrant.changeset/2" do
    test "an orphan is a group row whose binding is gone or not a platform role", %{schema: s} do
      covered = fresh_group!(s)
      raw_binding!(s, "TASK_WORKER", :platform_role, covered.id)
      raw_tenant_wide_row!(s, covered.id, "TASK_WORKER")

      gone = Ecto.UUID.generate()
      raw_tenant_wide_row!(s, gone, "CANDIDATE")

      routing = fresh_group!(s)
      raw_binding!(s, "AGENT_RUNNER", :process_routing_role, routing.id)
      raw_tenant_wide_row!(s, routing.id, "AGENT_RUNNER")

      orphans = RoleScopeGrants.orphan_group_rows(s)

      assert orphans |> Enum.map(&{&1.principal_id, &1.role}) |> Enum.sort() ==
               Enum.sort([{gone, "CANDIDATE"}, {routing.id, "AGENT_RUNNER"}])

      assert Enum.all?(orphans, &(Map.keys(&1) |> Enum.sort() == [:id, :principal_id, :role]))
    end

    test "the changeset rejects a role outside Authorization.roles/0, an unknown principal_type and a missing tenant_wide" do
      base = %{principal_type: :group, principal_id: Ecto.UUID.generate(), tenant_wide: true}

      assert RoleScopeGrant.changeset(%RoleScopeGrant{}, Map.put(base, :role, "TASK_WORKER")).valid?

      cs = RoleScopeGrant.changeset(%RoleScopeGrant{}, Map.put(base, :role, "NOT_A_ROLE"))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :role)

      cs =
        RoleScopeGrant.changeset(
          %RoleScopeGrant{},
          base |> Map.put(:role, "TASK_WORKER") |> Map.put(:principal_type, "token")
        )

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :principal_type)

      cs =
        RoleScopeGrant.changeset(
          %RoleScopeGrant{},
          base |> Map.delete(:tenant_wide) |> Map.put(:role, "TASK_WORKER")
        )

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :tenant_wide)
    end

    test "the changeset maps the XOR CHECK and both partial unique indexes to errors", %{
      schema: s
    } do
      node = node!(s)
      gid = Ecto.UUID.generate()

      attrs = fn role, tenant_wide, node_id ->
        %{
          principal_type: :group,
          principal_id: gid,
          role: role,
          tenant_wide: tenant_wide,
          scope_node_id: node_id
        }
      end

      insert = fn a ->
        %RoleScopeGrant{} |> RoleScopeGrant.changeset(a) |> Repo.insert(prefix: s)
      end

      assert {:error, cs} = insert.(attrs.("TASK_WORKER", true, node))
      assert {_msg, opts} = cs.errors[:scope_node_id]
      assert opts[:constraint] == :check
      assert opts[:constraint_name] == "role_scope_grants_tenant_wide_xor_node"

      assert {:ok, _} = insert.(attrs.("TASK_WORKER", true, nil))
      assert {:error, cs} = insert.(attrs.("TASK_WORKER", true, nil))
      assert {_msg, opts} = cs.errors[:principal_type]
      assert opts[:constraint] == :unique
      assert opts[:constraint_name] == "role_scope_grants_tenant_wide_uniq"

      assert {:ok, _} = insert.(attrs.("TENANT_ADMIN", false, node))
      assert {:error, cs} = insert.(attrs.("TENANT_ADMIN", false, node))
      assert {_msg, opts} = cs.errors[:principal_type]
      assert opts[:constraint] == :unique
      assert opts[:constraint_name] == "role_scope_grants_scoped_uniq"
    end
  end
end
