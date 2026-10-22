defmodule Letflow.Definitions.SearchPaginatedTest do
  @moduledoc """
  Tests for `Letflow.Definitions.search_paginated/3` (REQ-081, cursor-paginated sibling
  of `search/2`). Before ISS-0739 this function had zero test coverage (`grep -rn
  "search_paginated" test/` returned nothing) and zero exception handling.

  This file covers both:
  1. The pre-existing happy-path/cursor-pagination gap (§5.1 of
     `lib/letflow/design/iss-0739-search-paginated-exception-hardening.md`), independent
     of the exception-handling fix.
  2. The NEW `try/rescue` clause added by ISS-0739 (§5.2 of that design doc), exercised
     deterministically by dropping the tenant schema's `process_definitions` table
     inside the test's own sandboxed transaction -- the same forced-real-exception
     technique already established in `test/letflow/audit_capture_test.exs` (AC3, line
     ~279, `Repo.query!(~s(DROP TABLE "\#{schema_name}".audit_entries))`). Unlike
     `audit_entries`, `process_definitions` has dependent foreign keys
     (`instance_definition_snapshots`, `variable_schemas`) in a fully-migrated tenant
     schema, so this file's own DROP uses `CASCADE`.

  IMPORTANT per that design doc's §1/§6: this is NOT a fail-then-pass reproduction of
  the original intermittent, unreproduced empty-body HTTP 500 (~440+ direct
  reproduction attempts at the function level produced zero crashes, per ISSUE-FIXER's
  own investigation). The forced-exception test below only proves the new rescue clause
  is reachable and produces the documented `{:error, {:query_failed, %Postgrex.Error{}}}`
  shape -- it is defensive, idiom-matching hardening, not a root-cause regression test.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. `process_definitions` is a per-tenant-schema
  table (REQ-027), so this file follows `search_test.exs`'s established fixture pattern
  exactly (`provisioned_tenant/1` + Sandbox `:auto` mode + manual `on_exit/1` schema
  drop, `async: false`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(_context \\ %{}) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "iss0739",
      display_name: "ISS-0739 Test Tenant"
    )
  end

  defp unique_name(prefix \\ "iss0739-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_attrs(overrides) do
    Map.merge(
      %{
        name: unique_name(),
        version: "1.0.0",
        graph: valid_graph(),
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp create!(schema_name, overrides) do
    assert {:ok, definition} = Definitions.create(create_attrs(overrides), prefix: schema_name)
    definition
  end

  # ---------------------------------------------------------------------------------
  # Happy path -- currently entirely untested, independent of the exception fix.
  # ---------------------------------------------------------------------------------

  describe "search_paginated/3 -- happy path" do
    test "matching query with default page_size returns {:ok, %{items: [...], next_cursor: ...}}, ranked exact name > partial name > description-only" do
      %{schema_name: schema_name} = provisioned_tenant()

      exact = create!(schema_name, %{name: "invoice", version: "1.0.0"})
      partial = create!(schema_name, %{name: "invoice-approval", version: "1.0.0"})

      description_only =
        create!(schema_name, %{
          name: unique_name("expense-report"),
          version: "1.0.0",
          description: "Handles invoice reconciliation for procurement"
        })

      assert {:ok, %{items: items, next_cursor: next_cursor}} =
               Definitions.search_paginated("invoice", %{page_size: 20}, prefix: schema_name)

      assert is_nil(next_cursor)

      ids_in_order = Enum.map(items, & &1.definition.id)
      exact_idx = Enum.find_index(ids_in_order, &(&1 == exact.id))
      partial_idx = Enum.find_index(ids_in_order, &(&1 == partial.id))
      description_idx = Enum.find_index(ids_in_order, &(&1 == description_only.id))

      assert exact_idx < partial_idx
      assert partial_idx < description_idx
    end

    test "cursor pagination: first page followed by next_cursor's second page is a distinct, non-overlapping slice covering every row" do
      %{schema_name: schema_name} = provisioned_tenant()

      token = "paginate-#{System.unique_integer([:positive, :monotonic])}"

      created_ids =
        for i <- 1..15 do
          create!(schema_name, %{name: "#{token}-item-#{i}"}).id
        end
        |> MapSet.new()

      assert {:ok, %{items: page1, next_cursor: cursor1}} =
               Definitions.search_paginated(token, %{page_size: 10}, prefix: schema_name)

      assert length(page1) == 10
      assert is_binary(cursor1)

      assert {:ok, %{items: page2, next_cursor: cursor2}} =
               Definitions.search_paginated(
                 token,
                 %{page_size: 10, cursor: cursor1},
                 prefix: schema_name
               )

      assert length(page2) == 5
      assert is_nil(cursor2)

      page1_ids = MapSet.new(page1, & &1.definition.id)
      page2_ids = MapSet.new(page2, & &1.definition.id)

      assert MapSet.disjoint?(page1_ids, page2_ids)
      assert MapSet.union(page1_ids, page2_ids) == created_ids
    end

    test "empty query returns {:error, :query_empty}" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert Definitions.search_paginated("", %{page_size: 20}, prefix: schema_name) ==
               {:error, :query_empty}
    end

    test "a query over 512 bytes returns {:error, :query_too_long}" do
      %{schema_name: schema_name} = provisioned_tenant()

      too_long_query = String.duplicate("a", 513)

      assert Definitions.search_paginated(too_long_query, %{page_size: 20}, prefix: schema_name) ==
               {:error, :query_too_long}
    end

    test "a malformed cursor returns {:error, :invalid_cursor}" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert Definitions.search_paginated(
               "invoice",
               %{page_size: 20, cursor: "not-a-real-cursor"},
               prefix: schema_name
             ) == {:error, :invalid_cursor}
    end

    test "a cursor minted by a different endpoint returns {:error, :wrong_endpoint}" do
      %{schema_name: schema_name} = provisioned_tenant()

      for i <- 1..2, do: create!(schema_name, %{name: "invoice-#{i}"})

      assert {:ok, %{next_cursor: list_cursor}} =
               Definitions.list_paginated(%{page_size: 1}, prefix: schema_name)

      assert is_binary(list_cursor)

      assert Definitions.search_paginated(
               "invoice",
               %{page_size: 20, cursor: list_cursor},
               prefix: schema_name
             ) == {:error, :wrong_endpoint}
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0739 -- forced-exception path exercising the NEW try/rescue clause.
  #
  # Per the design doc's §1/§6: this is NOT a reproduction of the original
  # unreproduced live 500. It only proves the new rescue clause is reachable.
  # ---------------------------------------------------------------------------------

  describe "search_paginated/3 -- ISS-0739 forced-exception path (new rescue clause)" do
    test "a genuine raised exception during the query is rescued into {:error, {:query_failed, %Postgrex.Error{}}}, never an unhandled crash" do
      %{schema_name: schema_name} = provisioned_tenant()

      create!(schema_name, %{name: "invoice"})

      Repo.query!(~s(DROP TABLE "#{schema_name}".process_definitions CASCADE))

      assert {:error, {:query_failed, %Postgrex.Error{} = exception}} =
               Definitions.search_paginated("invoice", %{page_size: 20}, prefix: schema_name)

      assert exception.postgres.code == :undefined_table
    end
  end
end
