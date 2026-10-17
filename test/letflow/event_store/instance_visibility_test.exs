defmodule Letflow.EventStore.InstanceVisibilityTest do
  @moduledoc """
  GH #2702 unit tests for `Letflow.EventStore.InstanceVisibility` (design
  `lib/letflow/design/gh2702-hide-synthetic-instances.md` sections 1 and 6, T7).

  Rows are inserted directly (projection rows and `entity_type_instances` registry
  rows) so every case controls exactly which ids are registered. No restricted value
  is involved; this file only decides which `instance_projections` rows are hidden.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceVisibility
  alias Letflow.TenantFixture

  defp tenant! do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "gh2702-vis",
      display_name: "GH2702 InstanceVisibility Test Tenant"
    )
  end

  defp insert_projection!(prefix, instance_id, definition_id \\ nil) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: definition_id || Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: prefix)
  end

  defp register!(prefix, instance_id) do
    %EntityTypeInstance{}
    |> EntityTypeInstance.insert_changeset(%{
      entity_type: "type_" <> String.replace(Ecto.UUID.generate(), "-", ""),
      instance_id: instance_id
    })
    |> Repo.insert!(prefix: prefix)
  end

  defp visible_ids(prefix) do
    InstanceProjection
    |> InstanceVisibility.exclude_synthetic(prefix)
    |> select([p], p.instance_id)
    |> Repo.all(prefix: prefix)
    |> MapSet.new()
  end

  describe "exclude_synthetic/2" do
    test "removes exactly the rows whose id is registered in entity_type_instances" do
      %{schema_name: prefix} = tenant!()
      synthetic = Ecto.UUID.generate()
      real = Ecto.UUID.generate()

      insert_projection!(prefix, synthetic)
      insert_projection!(prefix, real)
      register!(prefix, synthetic)

      visible = visible_ids(prefix)

      assert {MapSet.member?(visible, synthetic), MapSet.member?(visible, real)} ==
               {false, true}
    end

    test "a REAL projection whose definition_id == instance_id but is not registered stays visible (M3)" do
      %{schema_name: prefix} = tenant!()
      id = Ecto.UUID.generate()
      insert_projection!(prefix, id, id)

      assert MapSet.member?(visible_ids(prefix), id)
    end

    test "a synthetic projection whose definition_id was changed stays hidden (M3)" do
      %{schema_name: prefix} = tenant!()
      id = Ecto.UUID.generate()
      insert_projection!(prefix, id, id)
      register!(prefix, id)

      Repo.update_all(
        from(p in InstanceProjection, where: p.instance_id == ^id),
        [set: [definition_id: Ecto.UUID.generate()]],
        prefix: prefix
      )

      refute MapSet.member?(visible_ids(prefix), id)
    end

    test "composes with a where clause and with limit (the exclusion is a WHERE, not a post-filter)" do
      %{schema_name: prefix} = tenant!()
      synthetic_ids = for _ <- 1..3, do: Ecto.UUID.generate()
      real_ids = for _ <- 1..2, do: Ecto.UUID.generate()

      Enum.each(synthetic_ids ++ real_ids, &insert_projection!(prefix, &1))
      Enum.each(synthetic_ids, &register!(prefix, &1))

      rows =
        InstanceProjection
        |> InstanceVisibility.exclude_synthetic(prefix)
        |> where([p], p.status == :active)
        |> order_by([p], asc: p.instance_id)
        |> limit(2)
        |> select([p], p.instance_id)
        |> Repo.all(prefix: prefix)

      assert Enum.sort(rows) == Enum.sort(real_ids)
    end

    test "reads exactly the prefix passed: registry in tenant A hides a row of tenant B queried with prefix A (M7)" do
      %{schema_name: prefix_a} = tenant!()
      %{schema_name: prefix_b} = tenant!()
      id = Ecto.UUID.generate()

      insert_projection!(prefix_b, id)
      register!(prefix_a, id)

      # The outer query reads tenant B's projections; the predicate is told to read A.
      hidden_by_a =
        InstanceProjection
        |> Ecto.Query.put_query_prefix(prefix_b)
        |> InstanceVisibility.exclude_synthetic(prefix_a)
        |> select([p], p.instance_id)
        |> Repo.all()

      # ...and the ordinary call for tenant B (its registry is empty) leaves the row visible.
      assert {id in hidden_by_a, MapSet.member?(visible_ids(prefix_b), id)} == {false, true}
    end

    test "an id synthetic in tenant A is an ordinary visible instance in tenant B" do
      %{schema_name: prefix_a} = tenant!()
      %{schema_name: prefix_b} = tenant!()
      id = Ecto.UUID.generate()

      insert_projection!(prefix_a, id)
      insert_projection!(prefix_b, id)
      register!(prefix_a, id)

      assert {MapSet.member?(visible_ids(prefix_a), id),
              MapSet.member?(visible_ids(prefix_b), id)} ==
               {false, true}
    end

    test "the generated SQL qualifies entity_type_instances with the tenant schema name" do
      %{schema_name: prefix} = tenant!()

      {sql, _params} =
        InstanceProjection
        |> InstanceVisibility.exclude_synthetic(prefix)
        |> then(&Repo.to_sql(:all, &1))

      assert String.contains?(sql, ~s("#{prefix}"."entity_type_instances"))
      assert String.contains?(sql, "NOT EXISTS")
    end

    test "a non-binary prefix is a FunctionClauseError, never swallowed" do
      assert_raise FunctionClauseError, fn ->
        InstanceVisibility.exclude_synthetic(InstanceProjection, nil)
      end

      assert_raise FunctionClauseError, fn ->
        InstanceVisibility.exclude_synthetic(InstanceProjection, :tenant_schema)
      end
    end
  end

  describe "synthetic?/2" do
    test "true for a registered id, false for an unregistered one, and only ever a boolean" do
      %{schema_name: prefix} = tenant!()
      registered = Ecto.UUID.generate()
      unregistered = Ecto.UUID.generate()
      register!(prefix, registered)

      assert InstanceVisibility.synthetic?(registered, prefix) === true
      assert InstanceVisibility.synthetic?(unregistered, prefix) === false
    end

    test "reads only the passed tenant prefix" do
      %{schema_name: prefix_a} = tenant!()
      %{schema_name: prefix_b} = tenant!()
      id = Ecto.UUID.generate()
      register!(prefix_a, id)

      assert {InstanceVisibility.synthetic?(id, prefix_a),
              InstanceVisibility.synthetic?(id, prefix_b)} ==
               {true, false}
    end

    test "is_binary guards: bad id or prefix is a FunctionClauseError" do
      %{schema_name: prefix} = tenant!()

      for bad_id <- [nil, 123, :atom, "short", String.duplicate("x", 37)] do
        assert_raise FunctionClauseError, fn -> InstanceVisibility.synthetic?(bad_id, prefix) end
      end

      for bad_prefix <- [nil, 1, :prefix] do
        assert_raise FunctionClauseError, fn ->
          InstanceVisibility.synthetic?(Ecto.UUID.generate(), bad_prefix)
        end
      end
    end
  end

  describe "table-name drift guard" do
    test "the registry source string used by the predicate equals EntityTypeInstance.__schema__(:source)" do
      # The module attribute is private; its observable effect is the table name in the SQL.
      {sql, _} =
        InstanceProjection
        |> InstanceVisibility.exclude_synthetic("some_prefix")
        |> then(&Repo.to_sql(:all, &1))

      assert String.contains?(sql, ~s("some_prefix"."#{EntityTypeInstance.__schema__(:source)}"))
      assert EntityTypeInstance.__schema__(:source) == "entity_type_instances"
    end
  end
end
