defmodule Letflow.Entities.DefinitionsListTypeAccessTest do
  @moduledoc """
  GH #2739 -- context-level tests that `Letflow.Entities.Definitions.list_definitions/3`
  filters type-denied definitions (`Letflow.Entities.TypeAccess`) INSIDE the one
  cursor-paginated statement.

  Covers T-4, T-5 (cursors), T-9 (statement count), T-12 (tenant prefix gate, both
  directions), T-13 (rule inputs), T-14 (parity with `authorized?/3` and
  `denied_types/3`) and T-15 (`/2` removed, fail-closed guards). The HTTP-level
  tests live in `test/letflow/routers/entities_definitions_list_type_access_test.exs`.

  Spec: `test/specs/GH2739-definitions-list-type-access.md`. Design:
  `lib/letflow/design/gh2739-definitions-list-type-access.md`.

  All fixture rows have fixed uuids and fixed distinct timestamps
  (`Letflow.TestSupport.DefinitionsListFixture`); no wall clock, no unseeded random
  value is compared.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.TypeAccess
  alias Letflow.TenantFixture
  alias Letflow.TestSupport.DefinitionsListFixture, as: Fx
  alias Letflow.TestSupport.QueryCount

  @denied Fx.denied_name()
  @unknown_id "ffffffff-0000-4000-8000-000000000001"

  defp tenant!(world) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2739-ctx",
        display_name: "GH2739 Definitions List Test Tenant"
      )

    _artifact_version_id = Fx.seed!(tenant.schema_name, tenant.tenant_id, world)
    %{schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp list!(user_id, schema, filters) do
    assert {:ok, page} = Definitions.list_definitions(user_id, filters, schema)
    page
  end

  defp ids(page), do: Enum.map(page.items, & &1.id)
  defp names(page), do: Enum.map(page.items, & &1.name)

  # -- T-4: a cursor minted for an unfiltered view cannot enumerate -----------

  describe "T-4 -- a cursor minted by a granted user, replayed by a denied user" do
    test "returns exactly the visible rows older than the cursor position, no error, no denied row" do
      world = tenant!(:with_x)
      world_without = tenant!(:without_x)
      :ok = Fx.restrict!(world.schema, @denied)

      granted = Fx.insert_user!(world.schema).id
      denied_user = Fx.insert_user!(world.schema).id
      :ok = Fx.grant!(world.schema, granted, @denied)

      # raw order: x3 b1 a3 x2 a2 x1 a1 x0 -- page of 4 as the granted user ends on x2
      minted = list!(granted, world.schema, %{page_size: 4})
      assert ids(minted) == [Fx.id(:x3), Fx.id(:b1), Fx.id(:a3), Fx.id(:x2)]
      assert Fx.cursor_position(minted.next_cursor) == {Fx.id(:x2), dt_us(:x2)}

      replayed =
        list!(denied_user, world.schema, %{page_size: 200, cursor: minted.next_cursor})

      assert ids(replayed) == [Fx.id(:a2), Fx.id(:a1)]
      assert replayed.next_cursor == nil

      # identical to a never-existing tuple at the same position in the world without X
      baseline =
        list!(Ecto.UUID.generate(), world_without.schema, %{
          page_size: 200,
          cursor: Fx.craft_cursor(Fx.id(:x2), Fx.inserted_at(:x2))
        })

      assert ids(baseline) == ids(replayed)
      assert baseline.next_cursor == nil
    end
  end

  # -- T-5: crafted cursor naming a denied row == cursor naming a random tuple -

  describe "T-5 -- a crafted cursor naming a denied row reveals nothing" do
    test "items and next_cursor null-ness/position equal a cursor naming an unknown id at the same timestamp" do
      world = tenant!(:with_x)
      :ok = Fx.restrict!(world.schema, @denied)
      caller = Fx.insert_user!(world.schema).id

      for denied_key <- [:x1, :x3], page_size <- [1, 2, 200] do
        named =
          list!(caller, world.schema, %{
            page_size: page_size,
            cursor: Fx.craft_cursor(Fx.id(denied_key), Fx.inserted_at(denied_key))
          })

        unknown =
          list!(caller, world.schema, %{
            page_size: page_size,
            cursor: Fx.craft_cursor(@unknown_id, Fx.inserted_at(denied_key))
          })

        label = {denied_key, page_size}
        assert {label, ids(named)} == {label, ids(unknown)}
        assert {label, named.next_cursor == nil} == {label, unknown.next_cursor == nil}

        assert {label, Fx.cursor_position(named.next_cursor)} ==
                 {label, Fx.cursor_position(unknown.next_cursor)}

        refute Enum.any?(ids(named), &(&1 in denied_ids()))
      end
    end
  end

  # -- T-9: equal database work -------------------------------------------------

  describe "T-9 -- one statement regardless of denial (INV-5)" do
    test "a list with denied rows issues exactly as many statements as the same list in a world without them" do
      with_x = tenant!(:with_x)
      without_x = tenant!(:without_x)
      :ok = Fx.restrict!(with_x.schema, @denied)

      denied_user = Fx.insert_user!(with_x.schema).id
      granted_user = Fx.insert_user!(with_x.schema).id
      :ok = Fx.grant!(with_x.schema, granted_user, @denied)
      bystander = Fx.insert_user!(without_x.schema).id

      filters = %{page_size: 3}

      # warm-up: the first call in a tenant may touch caches; the measured calls are pairs
      _ = list!(denied_user, with_x.schema, filters)
      _ = list!(bystander, without_x.schema, filters)

      {denied_page, denied_count} =
        QueryCount.count_statements(fn -> list!(denied_user, with_x.schema, filters) end)

      {absent_page, absent_count} =
        QueryCount.count_statements(fn -> list!(bystander, without_x.schema, filters) end)

      {granted_page, granted_count} =
        QueryCount.count_statements(fn -> list!(granted_user, with_x.schema, filters) end)

      assert ids(denied_page) == ids(absent_page)
      assert granted_page.items != []
      assert denied_count >= 1
      assert {denied_count, granted_count} == {absent_count, absent_count}
    end
  end

  # -- T-12: tenant prefix gate, both directions ---------------------------------

  describe "T-12 -- the denial subquery resolves in the caller's tenant schema (blocking gate)" do
    test "(a) a restriction in tenant A hides the type in A and does not hide it in B" do
      tenant_a = tenant!(:with_x)
      tenant_b = tenant!(:with_x)
      :ok = Fx.restrict!(tenant_a.schema, @denied)
      caller = Fx.insert_user!(tenant_a.schema).id

      in_a = list!(caller, tenant_a.schema, %{page_size: 200})
      in_b = list!(caller, tenant_b.schema, %{page_size: 200})

      assert ids(in_a) == Fx.ids(:without_x)
      assert ids(in_b) == Fx.ids(:with_x)
    end

    test "(b) a restriction only in tenant B must NOT hide the type in A" do
      tenant_a = tenant!(:with_x)
      tenant_b = tenant!(:with_x)
      :ok = Fx.restrict!(tenant_b.schema, @denied)
      caller = Fx.insert_user!(tenant_a.schema).id

      in_a = list!(caller, tenant_a.schema, %{page_size: 200})
      in_b = list!(caller, tenant_b.schema, %{page_size: 200})

      assert ids(in_a) == Fx.ids(:with_x)
      assert ids(in_b) == Fx.ids(:without_x)
    end
  end

  # -- T-13: rule inputs ----------------------------------------------------------

  describe "T-13 -- only a restriction on the row's own name and the caller's own grant change visibility" do
    test "restriction on another name, another user's grant, or a grant for another type change nothing" do
      world = tenant!(:with_x)
      caller = Fx.insert_user!(world.schema).id
      other_user = Fx.insert_user!(world.schema).id

      # a restriction for a name no fixture row has: everything stays visible
      :ok = Fx.restrict!(world.schema, "zzz_ent")
      assert ids(list!(caller, world.schema, %{page_size: 200})) == Fx.ids(:with_x)

      # restriction on x_ent: its versions disappear
      :ok = Fx.restrict!(world.schema, @denied)
      assert ids(list!(caller, world.schema, %{page_size: 200})) == Fx.ids(:without_x)

      # ANOTHER user's grant on x_ent does not lift the denial
      :ok = Fx.grant!(world.schema, other_user, @denied)
      assert ids(list!(caller, world.schema, %{page_size: 200})) == Fx.ids(:without_x)

      # the caller's grant for a DIFFERENT type does not lift it either
      :ok = Fx.restrict!(world.schema, "b_ent")
      :ok = Fx.grant!(world.schema, caller, "b_ent")
      assert ids(list!(caller, world.schema, %{page_size: 200})) == Fx.ids(:without_x)

      # the caller's own grant on x_ent does
      :ok = Fx.grant!(world.schema, caller, @denied)
      assert ids(list!(caller, world.schema, %{page_size: 200})) == Fx.ids(:with_x)
    end
  end

  # -- T-14: parity ---------------------------------------------------------------

  describe "T-14 -- the list, authorized?/3 and denied_types/3 apply one rule" do
    test "agree for unrestricted, restricted+no grant (duplicate-name versions), restricted+granted, grant for another user only, grant for a different type, and absent names" do
      world = tenant!(:with_x)
      user = Fx.insert_user!(world.schema).id
      other_user = Fx.insert_user!(world.schema).id
      probe = ["a_ent", "b_ent", "x_ent", "ghost_ent"]

      # step 1: x_ent (4 versions) restricted, no grant at all
      :ok = Fx.restrict!(world.schema, "x_ent")
      assert_parity!(world, user, probe, ["a_ent", "b_ent"])

      # step 2: b_ent restricted but the user holds its grant; the grant is for a type
      # DIFFERENT from x_ent, so x_ent stays denied
      :ok = Fx.restrict!(world.schema, "b_ent")
      :ok = Fx.grant!(world.schema, user, "b_ent")
      assert_parity!(world, user, probe, ["a_ent", "b_ent"])

      # step 3: a_ent restricted and only ANOTHER user holds its grant
      :ok = Fx.restrict!(world.schema, "a_ent")
      :ok = Fx.grant!(world.schema, other_user, "a_ent")
      assert_parity!(world, user, probe, ["b_ent"])
    end
  end

  defp assert_parity!(world, user, probe, expected_visible) do
    page = list!(user, world.schema, %{page_size: 200})
    listed = page |> names() |> MapSet.new()
    assert MapSet.equal?(listed, MapSet.new(expected_visible))

    assert {:ok, denied} = TypeAccess.denied_types(user, probe, world.schema)

    present = MapSet.new(Fx.names(:with_x))

    for name <- probe do
      assert {:ok, decision} = TypeAccess.authorized?(user, name, world.schema)
      allowed? = decision == :allowed

      assert {name, allowed?} == {name, not MapSet.member?(denied, name)}

      if MapSet.member?(present, name) do
        assert {name, allowed?} == {name, MapSet.member?(listed, name)}
      end
    end
  end

  # -- T-15: /2 removed, fail closed ----------------------------------------------

  describe "T-15 -- no unscoped sibling; a non-binary viewer fails closed" do
    test "list_definitions/2 is not exported and visible_to/2 / list_definitions/3 reject non-binary user ids" do
      assert Code.ensure_loaded?(Definitions)
      refute function_exported?(Definitions, :list_definitions, 2)
      assert function_exported?(Definitions, :list_definitions, 3)

      world = tenant!(:with_x)

      for bad <- [nil, :someone, 42] do
        assert_raise FunctionClauseError, fn ->
          apply(Definitions, :list_definitions, [bad, %{}, world.schema])
        end

        assert_raise FunctionClauseError, fn -> apply(TypeAccess, :visible_to, [bad, :def]) end
      end

      assert_raise FunctionClauseError, fn ->
        apply(TypeAccess, :visible_to, [Ecto.UUID.generate(), "def"])
      end
    end

    test "list_definitions/3 with an unrestricted user returns every version, newest first (migrated AC5 contract)" do
      world = tenant!(:with_x)
      page = list!(Ecto.UUID.generate(), world.schema, %{page_size: 200})
      assert ids(page) == Fx.ids(:with_x)
      assert page.next_cursor == nil
    end
  end

  defp denied_ids, do: for(key <- [:x0, :x1, :x2, :x3], do: Fx.id(key))

  defp dt_us(key), do: DateTime.to_unix(Fx.inserted_at(key), :microsecond)
end
