Code.require_file("org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Org.UnitsTest do
  @moduledoc """
  GH #3618 / REQ-495: the org unit writers of module `org` with the scope tree index, on real
  provisioned tenants (design tests U, C, M, R, P, A, T, S). `async: false`: tenant provisioning
  switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Consistency
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @bin "123456789012"
  @units_path Path.join(File.cwd!(), "lib/letflow/modules/org/units.ex")

  setup do
    ctx = OrgFixture.installed_tenant!("gh3618-org")

    {:ok, c} =
      Org.create_legal_entity(ctx.schema, %{"code" => "C", "name" => "C", "bin" => @bin}, opts())

    {:ok, s} =
      Org.create_site(
        ctx.schema,
        %{"code" => "S", "name" => "S", "legal_entity_id" => c["record_id"]},
        opts()
      )

    {:ok, Map.merge(ctx, %{company: c["record_id"], site: s["record_id"]})}
  end

  defp opts(key \\ nil),
    do: %{actor_id: Ecto.UUID.generate(), idempotency_key: key || Ecto.UUID.generate()}

  defp attrs(ctx, code, extra \\ %{}) do
    Map.merge(
      %{
        "code" => code,
        "name" => "U #{code}",
        "legal_entity_id" => ctx.company,
        "site_id" => ctx.site
      },
      extra
    )
  end

  defp unit!(ctx, code, parent \\ nil) do
    extra = if parent, do: %{"parent" => parent}, else: %{}
    {:ok, u} = Org.create_unit(ctx.schema, attrs(ctx, code, extra), opts())
    u
  end

  defp count(schema, type),
    do: Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)

  defp nodes(schema), do: Repo.aggregate(Node, :count, prefix: schema)

  defp audit_rows(schema) do
    Repo.all(
      from(e in Audit.Entry, where: like(e.action, "org_unit.%"), order_by: e.timestamp),
      prefix: schema
    )
  end

  defp snapshot(ctx),
    do: {count(ctx.schema, "org_unit"), nodes(ctx.schema), length(audit_rows(ctx.schema))}

  defp assert_refused(ctx, expected, fun) do
    before = snapshot(ctx)
    assert fun.() == expected
    assert snapshot(ctx) == before
  end

  defp node(schema, id) do
    {:ok, %{node: n}} = ScopeNodePaths.resolve(id, schema)
    n
  end

  defp assert_consistent(schema) do
    assert {:ok, %{status: :ok}} = Consistency.check(schema)
  end

  # --- AC 1 -----------------------------------------------------------------------------------

  test "U-01 four functions are exported", _ctx do
    for {f, a} <- [create_unit: 3, update_unit: 4, move_unit: 4, retire_unit: 3],
        do: assert(function_exported?(Org, f, a))
  end

  test "U-02 U-03 root and child create keep the index and stay consistent", ctx do
    root = unit!(ctx, "R")
    child = unit!(ctx, "K", root["record_id"])

    assert root["active"] == true and not Map.has_key?(root, "parent")
    assert child["parent"] == root["record_id"]
    assert node(ctx.schema, root["record_id"]).path == "/#{root["record_id"]}/"
    assert node(ctx.schema, child["record_id"]).depth == 2

    assert node(ctx.schema, child["record_id"]).path ==
             "/#{root["record_id"]}/#{child["record_id"]}/"

    assert_consistent(ctx.schema)
  end

  # --- AC 2 -----------------------------------------------------------------------------------

  test "C-01..C-14 create refusals write nothing", ctx do
    root = unit!(ctx, "R")
    retired_parent = unit!(ctx, "RP")
    {:ok, _} = Org.retire_unit(ctx.schema, retired_parent["record_id"], opts())
    gone = OrgFixture.create!(ctx.schema, "org_unit", OrgFixture.values("org_unit", "G"))
    :ok = OrgFixture.delete!(ctx.schema, gone)

    {:ok, c2} =
      Org.create_legal_entity(
        ctx.schema,
        %{"code" => "C2", "name" => "C", "bin" => "210987654321"},
        opts()
      )

    {:ok, _} = Org.retire_legal_entity(ctx.schema, c2["record_id"], opts())

    {:ok, s2} =
      Org.create_site(
        ctx.schema,
        %{"code" => "S2", "name" => "S", "legal_entity_id" => ctx.company},
        opts()
      )

    {:ok, _} = Org.retire_site(ctx.schema, s2["record_id"], opts())
    unknown = Ecto.UUID.generate()

    cases = [
      {%{"bogus" => 1}, {:error, {:field_not_allowed, "bogus"}}},
      {%{"active" => false}, {:error, {:field_not_allowed, "active"}}},
      {%{"code" => " "}, {:error, {:field_invalid, "code"}}},
      {%{"name" => ""}, {:error, {:field_invalid, "name"}}},
      {%{"parent" => "not-a-uuid"}, {:error, :parent_not_found}},
      {%{"parent" => unknown}, {:error, :parent_not_found}},
      {%{"parent" => gone.record_id}, {:error, :parent_not_found}},
      {%{"parent" => ctx.site}, {:error, :parent_not_found}},
      {%{"parent" => retired_parent["record_id"]}, {:error, :parent_inactive}},
      {%{"legal_entity_id" => unknown}, {:error, :legal_entity_not_found}},
      {%{"legal_entity_id" => c2["record_id"]}, {:error, :legal_entity_inactive}},
      {%{"site_id" => unknown}, {:error, :site_not_found}},
      {%{"site_id" => s2["record_id"]}, {:error, :site_inactive}}
    ]

    for {extra, expected} <- cases do
      assert_refused(ctx, expected, fn ->
        Org.create_unit(ctx.schema, attrs(ctx, "X", extra), opts())
      end)
    end

    assert_refused(ctx, {:error, {:field_invalid, "code"}}, fn ->
      Org.create_unit(ctx.schema, Map.delete(attrs(ctx, "X"), "code"), opts())
    end)

    # duplicate code: the record write refuses before the index write
    before = snapshot(ctx)

    assert {:error, {:record_payload_invalid, _}} =
             Org.create_unit(ctx.schema, attrs(ctx, "R"), opts())

    assert snapshot(ctx) == before
    assert root["record_id"]
    assert_consistent(ctx.schema)
  end

  test "C-15 the 41st level is :depth_exceeded and writes nothing", ctx do
    max = ScopeNodePaths.max_depth()

    last =
      Enum.reduce(1..max, nil, fn i, parent ->
        unit!(ctx, "D#{i}", parent)["record_id"]
      end)

    assert node(ctx.schema, last).depth == max

    assert_refused(ctx, {:error, :depth_exceeded}, fn ->
      Org.create_unit(ctx.schema, attrs(ctx, "TOO", %{"parent" => last}), opts())
    end)

    assert_consistent(ctx.schema)
  end

  # --- AC 3 -----------------------------------------------------------------------------------

  test "M-01 M-02 M-04 M-05 move refusals write nothing", ctx do
    a = unit!(ctx, "A")["record_id"]
    b = unit!(ctx, "B", a)["record_id"]
    c = unit!(ctx, "C", b)["record_id"]
    dead = unit!(ctx, "DEAD")["record_id"]
    {:ok, _} = Org.retire_unit(ctx.schema, dead, opts())

    assert_refused(ctx, {:error, :cycle}, fn -> Org.move_unit(ctx.schema, a, a, opts()) end)
    assert_refused(ctx, {:error, :cycle}, fn -> Org.move_unit(ctx.schema, a, c, opts()) end)

    assert_refused(ctx, {:error, :unit_inactive}, fn ->
      Org.move_unit(ctx.schema, dead, nil, opts())
    end)

    assert_refused(ctx, {:error, :parent_inactive}, fn ->
      Org.move_unit(ctx.schema, c, dead, opts())
    end)

    assert_refused(ctx, {:error, :unit_not_found}, fn ->
      Org.move_unit(ctx.schema, Ecto.UUID.generate(), nil, opts())
    end)

    assert_refused(ctx, {:error, :parent_not_found}, fn ->
      Org.move_unit(ctx.schema, c, "x", opts())
    end)

    assert {:ok, %{"parent" => ^b}} = Org.lookup(ctx.schema, c)
    assert_consistent(ctx.schema)
  end

  test "M-03 a move that pushes the subtree past the bound is :depth_exceeded", ctx do
    max = ScopeNodePaths.max_depth()
    deepest = Enum.reduce(1..(max - 1), nil, fn i, p -> unit!(ctx, "L#{i}", p)["record_id"] end)
    top = unit!(ctx, "TOP")["record_id"]
    mid = unit!(ctx, "MID", top)["record_id"]
    _leaf = unit!(ctx, "LEAF", mid)
    # `top` (3 levels) under `deepest` (max - 1) would reach max + 2
    assert_refused(ctx, {:error, :depth_exceeded}, fn ->
      Org.move_unit(ctx.schema, top, deepest, opts())
    end)

    assert_consistent(ctx.schema)
  end

  test "M-06 M-08 a move rewrites the subtree and changes only parent", ctx do
    a = unit!(ctx, "A")["record_id"]
    b = unit!(ctx, "B")["record_id"]
    c = unit!(ctx, "C", b)["record_id"]
    d = unit!(ctx, "D", c)["record_id"]
    {:ok, before} = Org.lookup(ctx.schema, b)

    assert {:ok, moved} = Org.move_unit(ctx.schema, b, a, opts())
    assert moved == Map.put(before, "parent", a)
    assert node(ctx.schema, d).path == "/#{a}/#{b}/#{c}/#{d}/"
    assert node(ctx.schema, d).depth == 4
    assert_consistent(ctx.schema)

    assert {:ok, root} = Org.move_unit(ctx.schema, b, nil, opts())
    assert not Map.has_key?(root, "parent")
    assert node(ctx.schema, d).path == "/#{b}/#{c}/#{d}/"
    assert_consistent(ctx.schema)
  end

  test "M-07 the same parent writes nothing", ctx do
    a = unit!(ctx, "A")["record_id"]
    b = unit!(ctx, "B", a)["record_id"]
    root = unit!(ctx, "R")["record_id"]

    assert_refused(ctx, {:ok, elem(Org.lookup(ctx.schema, b), 1)}, fn ->
      Org.move_unit(ctx.schema, b, a, opts())
    end)

    assert_refused(ctx, {:ok, elem(Org.lookup(ctx.schema, root), 1)}, fn ->
      Org.move_unit(ctx.schema, root, nil, opts())
    end)
  end

  # --- AC 4 -----------------------------------------------------------------------------------

  test "R-01 R-02 active staff blocks a retire, inactive staff does not", ctx do
    u = unit!(ctx, "U1")["record_id"]

    emp =
      OrgFixture.create!(
        ctx.schema,
        "org_employee",
        OrgFixture.values("org_employee", "E1", %{"org_unit_id" => u})
      )

    assert_refused(ctx, {:error, :unit_has_active_staff}, fn ->
      Org.retire_unit(ctx.schema, u, opts())
    end)

    assert node(ctx.schema, u).retired_at == nil

    {:ok, _} =
      Letflow.Entities.Records.update_record(
        %{
          entity_type: "org_employee",
          record_id: emp.record_id,
          field_values: Map.put(emp.field_values, "active", false),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema,
        OrgFixture.owner()
      )

    u2 = unit!(ctx, "U2")["record_id"]

    OrgFixture.create!(
      ctx.schema,
      "org_position",
      OrgFixture.values("org_position", "P1", %{"org_unit_id" => u2})
    )

    assert_refused(ctx, {:error, :unit_has_active_staff}, fn ->
      Org.retire_unit(ctx.schema, u2, opts())
    end)

    assert {:ok, %{"active" => false}} = Org.retire_unit(ctx.schema, u, opts())
  end

  test "R-03 a scope grant blocks the retire", ctx do
    u = unit!(ctx, "G1")["record_id"]
    group = RSG.fresh_group!(ctx.schema)
    RSG.raw_scoped_row!(ctx.schema, group.id, "TASK_WORKER", u)

    assert_refused(ctx, {:error, :node_has_grants}, fn ->
      Org.retire_unit(ctx.schema, u, opts())
    end)

    assert {:ok, %{"active" => true}} = Org.lookup(ctx.schema, u)
  end

  test "R-04 R-05 retire keeps the children live and is idempotent", ctx do
    p = unit!(ctx, "P")["record_id"]
    k = unit!(ctx, "K", p)["record_id"]

    assert {:ok, %{"active" => false}} = Org.retire_unit(ctx.schema, p, opts())
    assert %DateTime{} = node(ctx.schema, p).retired_at
    assert {:ok, %{"active" => true}} = Org.lookup(ctx.schema, k)
    assert node(ctx.schema, k).retired_at == nil

    before = snapshot(ctx)
    assert {:ok, %{"active" => false}} = Org.retire_unit(ctx.schema, p, opts())
    assert snapshot(ctx) == before
    assert_consistent(ctx.schema)
  end

  # --- AC 5 -----------------------------------------------------------------------------------

  test "P-01..P-04 update actions and refusals", ctx do
    u = unit!(ctx, "U")["record_id"]

    {:ok, s2} =
      Org.create_site(
        ctx.schema,
        %{"code" => "S9", "name" => "S", "legal_entity_id" => ctx.company},
        opts()
      )

    assert {:ok, %{"name" => "New"}} = Org.update_unit(ctx.schema, u, %{"name" => "New"}, opts())

    assert {:ok, %{"site_id" => sid}} =
             Org.update_unit(ctx.schema, u, %{"site_id" => s2["record_id"]}, opts())

    assert sid == s2["record_id"]

    assert Enum.map(audit_rows(ctx.schema), & &1.action) == [
             "org_unit.created",
             "org_unit.renamed",
             "org_unit.updated"
           ]

    before = snapshot(ctx)
    assert {:ok, _} = Org.update_unit(ctx.schema, u, %{"name" => "New"}, opts())
    assert snapshot(ctx) == before

    for key <- ["code", "parent", "active"] do
      assert_refused(ctx, {:error, {:field_not_allowed, key}}, fn ->
        Org.update_unit(ctx.schema, u, %{key => "x"}, opts())
      end)
    end

    assert_refused(ctx, {:error, :unit_not_found}, fn ->
      Org.update_unit(ctx.schema, "nope", %{}, opts())
    end)

    assert_consistent(ctx.schema)
  end

  # --- AC 6 -----------------------------------------------------------------------------------

  test "A-01 one audit row per accepted change with actor and states", ctx do
    actor = Ecto.UUID.generate()
    o = fn -> %{actor_id: actor, idempotency_key: Ecto.UUID.generate()} end
    {:ok, a} = Org.create_unit(ctx.schema, attrs(ctx, "A"), o.())
    {:ok, b} = Org.create_unit(ctx.schema, attrs(ctx, "B"), o.())
    {:ok, _} = Org.move_unit(ctx.schema, b["record_id"], a["record_id"], o.())
    {:ok, _} = Org.retire_unit(ctx.schema, b["record_id"], o.())

    rows = audit_rows(ctx.schema)

    assert Enum.map(rows, & &1.action) == [
             "org_unit.created",
             "org_unit.created",
             "org_unit.moved",
             "org_unit.retired"
           ]

    assert Enum.all?(rows, &(&1.actor_id == actor))
    moved = Enum.at(rows, 2)
    assert moved.resource_id == b["record_id"]
    refute Map.has_key?(moved.before_state, "parent")
    assert moved.after_state["parent"] == a["record_id"]
    assert Enum.at(rows, 3).after_state["active"] == false
  end

  test "A-02 a failing audit insert rolls record and index back" do
    ctx = OrgFixture.installed_tenant!("gh3618-aud")

    {:ok, c} =
      Org.create_legal_entity(ctx.schema, %{"code" => "C", "name" => "C", "bin" => @bin}, opts())

    {:ok, s} =
      Org.create_site(
        ctx.schema,
        %{"code" => "S", "name" => "S", "legal_entity_id" => c["record_id"]},
        opts()
      )

    ctx = Map.merge(ctx, %{company: c["record_id"], site: s["record_id"]})

    a = unit!(ctx, "A")["record_id"]
    b = unit!(ctx, "B")["record_id"]
    Repo.query!(~s(DROP TABLE "#{ctx.schema}".audit_entries))
    units = count(ctx.schema, "org_unit")
    node_count = nodes(ctx.schema)

    assert {:error, :audit_failed} = Org.create_unit(ctx.schema, attrs(ctx, "N"), opts())
    assert {:error, :audit_failed} = Org.move_unit(ctx.schema, b, a, opts())
    assert {:error, :audit_failed} = Org.retire_unit(ctx.schema, a, opts())

    assert count(ctx.schema, "org_unit") == units and nodes(ctx.schema) == node_count
    assert not Map.has_key?(elem(Org.lookup(ctx.schema, b), 1), "parent")
    assert node(ctx.schema, b).path == "/#{b}/"
    assert node(ctx.schema, a).retired_at == nil
    assert elem(Org.lookup(ctx.schema, a), 1)["active"] == true
  end

  test "A-03 replay with the same key writes nothing new", ctx do
    key = Ecto.UUID.generate()
    actor = Ecto.UUID.generate()
    o = fn k -> %{actor_id: actor, idempotency_key: k} end
    {:ok, a} = Org.create_unit(ctx.schema, attrs(ctx, "A"), o.(key))
    assert {:ok, again} = Org.create_unit(ctx.schema, attrs(ctx, "A"), o.(key))
    assert again["record_id"] == a["record_id"]
    assert count(ctx.schema, "org_unit") == 1 and nodes(ctx.schema) == 1

    b = unit!(ctx, "B")["record_id"]
    mkey = Ecto.UUID.generate()
    assert {:ok, _} = Org.move_unit(ctx.schema, b, a["record_id"], o.(mkey))
    snap = snapshot(ctx)
    assert {:ok, %{"parent" => _}} = Org.move_unit(ctx.schema, b, a["record_id"], o.(mkey))
    assert snapshot(ctx) == snap

    rkey = Ecto.UUID.generate()
    assert {:ok, _} = Org.retire_unit(ctx.schema, b, o.(rkey))
    snap = snapshot(ctx)
    assert {:ok, %{"active" => false}} = Org.retire_unit(ctx.schema, b, o.(rkey))
    assert snapshot(ctx) == snap
    assert_consistent(ctx.schema)
  end

  # --- AC 7 -----------------------------------------------------------------------------------

  test "T-01 an id of another tenant is not found, nothing written", ctx do
    other = OrgFixture.installed_tenant!("gh3618-oth")

    {:ok, c} =
      Org.create_legal_entity(
        other.schema,
        %{"code" => "C", "name" => "C", "bin" => @bin},
        opts()
      )

    {:ok, s} =
      Org.create_site(
        other.schema,
        %{"code" => "S", "name" => "S", "legal_entity_id" => c["record_id"]},
        opts()
      )

    theirs =
      unit!(Map.merge(other, %{company: c["record_id"], site: s["record_id"]}), "T")["record_id"]

    mine = unit!(ctx, "M")["record_id"]
    other_snap = {count(other.schema, "org_unit"), nodes(other.schema)}

    assert_refused(ctx, {:error, :unit_not_found}, fn ->
      Org.update_unit(ctx.schema, theirs, %{"name" => "x"}, opts())
    end)

    assert_refused(ctx, {:error, :unit_not_found}, fn ->
      Org.move_unit(ctx.schema, theirs, nil, opts())
    end)

    assert_refused(ctx, {:error, :unit_not_found}, fn ->
      Org.retire_unit(ctx.schema, theirs, opts())
    end)

    assert_refused(ctx, {:error, :parent_not_found}, fn ->
      Org.move_unit(ctx.schema, mine, theirs, opts())
    end)

    assert_refused(ctx, {:error, :parent_not_found}, fn ->
      Org.create_unit(ctx.schema, attrs(ctx, "Z", %{"parent" => theirs}), opts())
    end)

    assert {:error, :parent_not_found} ==
             Org.move_unit(ctx.schema, mine, Ecto.UUID.generate(), opts())

    assert {count(other.schema, "org_unit"), nodes(other.schema)} == other_snap
  end

  test "T-02 units.ex names no tenant id and no principal" do
    src = File.read!(@units_path)
    refute src =~ "tenant_id"
    refute src =~ "opts[:tenant"
    refute src =~ "Records."
    refute src =~ "Audit."
  end

  # --- AC 8 / 9 -------------------------------------------------------------------------------

  test "S-01 no scope declaration or route is added by the unit writers" do
    assert function_exported?(Org, :create_unit, 3)
    refute function_exported?(Letflow.Modules.Org.Units, :scope_declarations, 0)
  end
end
