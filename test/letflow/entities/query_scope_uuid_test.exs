defmodule Letflow.Entities.QueryScopeUuidTest do
  @moduledoc """
  REQ-674 / GH #3624 (decision 0051 D6 on a `uuid` scope column): the scope filter of
  `Letflow.Entities.Query.Compiler` (list, aggregate, joined hop) and of
  `Letflow.Entities.ScopedLookup` (by id, reference check) when the declared scope column
  (`scope_node` of the `fixture_scoped` module) is physically `uuid` instead of text.

  The column is altered on the EMPTY tables before seeding, so the test builds the shape phase A
  uses (`org_unit_id` uuid) without a pack of its own. Text columns keep today's SQL (U6, the
  literal was captured from `main` before the change).

  `async: false`: real committed tenants and DDL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.TenantProvisioning

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"

  @text_sql ~S|SELECT e0."record_id"::uuid, e0."field_values", e0."deleted", e0."entity_def_version", e0."last_event_global_seq", e0."inserted_at", e0."updated_at" FROM "entity_scoped_item" AS e0 WHERE ("scope_node" = ANY($1::varchar[]))|

  setup do
    fx = F.provision!("req674-uuid")
    ia1 = F.create!(fx.schema_name, "scoped_item", item("ia1", 1, @a))
    ia2 = F.create!(fx.schema_name, "scoped_item", item("ia2", 2, @a))
    ib = F.create!(fx.schema_name, "scoped_item", item("ib", 4, @b))
    none = F.create!(fx.schema_name, "scoped_item", %{"name" => "none", "amount" => 8})

    F.create!(fx.schema_name, "scoped_child", %{
      "name" => "child-b",
      "scope_node" => @b,
      "item_id" => ia1.record_id
    })

    # Seeded while the column is text (the record writer binds the raw string), then converted.
    alter_to_uuid!(fx, "scoped_item")
    alter_to_uuid!(fx, "scoped_child")

    {:ok, fx: fx, ia1: ia1, ia2: ia2, ib: ib, none: none}
  end

  defp item(name, amount, node),
    do: %{"name" => name, "amount" => amount, "scope_node" => node}

  defp alter_to_uuid!(fx, type) do
    {:ok, table} = TenantProvisioning.table_name_for_entity_type(type)

    Repo.query!(
      ~s(ALTER TABLE "#{fx.schema_name}"."#{table}" ALTER COLUMN scope_node TYPE uuid USING scope_node::uuid)
    )
  end

  defp names(fx, scope) do
    assert {:ok, query} =
             Compiler.compile(%{entity_type: "scoped_item"}, fx.schema_name, scope)

    query
    |> Repo.all(prefix: fx.schema_name)
    |> Enum.map(& &1.field_values["name"])
    |> Enum.sort()
  end

  defp agg(fx, scope) do
    request = %{
      entity_type: "scoped_item",
      aggregates: [%{fn: :count}, %{fn: :sum, field: "amount"}]
    }

    assert {:ok, [row]} = Compiler.run_aggregate(request, fx.schema_name, scope)
    row |> Map.values() |> Enum.map(&to_int/1) |> Enum.sort()
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n), do: n

  test "U1 a scoped list on a uuid column returns only the rows of the set", %{fx: fx} do
    assert names(fx, {:nodes, [@a]}) == ["ia1", "ia2"]
    assert names(fx, {:nodes, [@a, @b]}) == ["ia1", "ia2", "ib"]
    assert names(fx, {:nodes, [String.upcase(@b)]}) == ["ib"]
  end

  test "U2 no matching or non-uuid ids give no rows and no error; :all gives every row",
       %{fx: fx} do
    assert names(fx, :none) == []
    assert names(fx, {:nodes, ["not-a-uuid"]}) == []
    assert names(fx, {:nodes, ["not-a-uuid", "x"]}) == []
    assert names(fx, {:nodes, ["not-a-uuid", @b]}) == ["ib"]
    assert names(fx, :all) == ["ia1", "ia2", "ib", "none"]
  end

  test "U3 an aggregate counts only the rows of the set", %{fx: fx} do
    assert agg(fx, {:nodes, [@a]}) == [2, 3]
    assert agg(fx, {:nodes, [@b]}) == [1, 4]
    assert [0 | _] = agg(fx, {:nodes, ["not-a-uuid"]})
  end

  test "U4 a by-id lookup is visible in the set, and out of scope equals absent",
       %{fx: fx, ia1: ia1} do
    tel = {:req674, :by_id}

    assert {:ok, {:column, "scope_node"}} =
             ScopedLookup.fetch_in_scope(
               "scoped_item",
               ia1.record_id,
               {:nodes, [@a]},
               fx.schema_name,
               tel
             )

    out =
      ScopedLookup.fetch_in_scope(
        "scoped_item",
        ia1.record_id,
        {:nodes, [@b]},
        fx.schema_name,
        tel
      )

    absent =
      ScopedLookup.fetch_in_scope(
        "scoped_item",
        Ecto.UUID.generate(),
        {:nodes, [@b]},
        fx.schema_name,
        tel
      )

    assert out == :not_found
    assert out == absent

    assert :not_found ==
             ScopedLookup.fetch_in_scope(
               "scoped_item",
               ia1.record_id,
               {:nodes, ["not-a-uuid"]},
               fx.schema_name,
               tel
             )
  end

  test "U5 all_in_scope? on a uuid column", %{fx: fx, ia1: ia1, ia2: ia2, ib: ib} do
    ids = [ia1.record_id, ia2.record_id]
    assert ScopedLookup.all_in_scope?("scoped_item", ids, {:nodes, [@a]}, fx.schema_name)
    refute ScopedLookup.all_in_scope?("scoped_item", ids, {:nodes, [@b]}, fx.schema_name)

    refute ScopedLookup.all_in_scope?(
             "scoped_item",
             [ib.record_id | ids],
             {:nodes, [@a]},
             fx.schema_name
           )

    refute ScopedLookup.all_in_scope?(
             "scoped_item",
             ids,
             {:nodes, ["not-a-uuid"]},
             fx.schema_name
           )
  end

  test "U6 a text scope column keeps the SQL of main" do
    fx = F.provision!("req674-text")

    out =
      F.sql_of(Compiler, :compile, %{entity_type: "scoped_item"}, fx.schema_name, {:nodes, ["a"]})

    assert out["sql"] == @text_sql
    assert out["params"] == ~s([["a"]])
  end

  test "U7 entity_column_type reads the type; a missing column is :error", %{fx: fx} do
    {:ok, table} = TenantProvisioning.table_name_for_entity_type("scoped_item")

    assert {:ok, "uuid"} =
             TenantProvisioning.entity_column_type(fx.schema_name, table, "scope_node")

    assert {:ok, "uuid"} =
             TenantProvisioning.entity_column_type(fx.schema_name, table, "record_id")

    assert {:ok, type} = TenantProvisioning.entity_column_type(fx.schema_name, table, "name")
    assert type in ["text", "character varying"]
    assert :error = TenantProvisioning.entity_column_type(fx.schema_name, table, "no_such_col")

    assert :uuid == Compiler.scope_column_kind(fx.schema_name, table, "scope_node")
    assert :text == Compiler.scope_column_kind(fx.schema_name, table, "name")
    assert :missing == Compiler.scope_column_kind(fx.schema_name, table, "no_such_col")
  end

  test "U8 a dropped scope column fails closed", %{fx: fx, ia1: ia1} do
    F.drop_scope_column!(fx, "scoped_item")
    assert names(fx, {:nodes, [@a]}) == []

    assert :not_found ==
             ScopedLookup.fetch_in_scope(
               "scoped_item",
               ia1.record_id,
               {:nodes, [@a]},
               fx.schema_name,
               {:req674, :by_id}
             )

    refute ScopedLookup.all_in_scope?(
             "scoped_item",
             [ia1.record_id],
             {:nodes, [@a]},
             fx.schema_name
           )
  end

  test "U9 a left join on a uuid target column keeps the primary row", %{fx: fx} do
    request = %{
      entity_type: "scoped_item",
      join: [%{entity_type: "scoped_child", fk: "fk_scoped_child_item_id", type: :left}]
    }

    child_of_ia1 = fn nodes ->
      {:ok, query} = Compiler.compile(request, fx.schema_name, {:nodes, nodes})

      [row] =
        query
        |> Repo.all(prefix: fx.schema_name)
        |> Enum.filter(&(&1.primary.field_values["name"] == "ia1"))

      row["scoped_child"]
    end

    # the child sits in node b: out of scope for [a] (NULL target, primary row kept), in for [a, b]
    assert child_of_ia1.([@a]) == nil or is_nil(child_of_ia1.([@a]).record_id)
    assert %{record_id: _} = child_of_ia1.([@a, @b])
  end
end
