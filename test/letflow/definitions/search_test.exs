defmodule Letflow.Definitions.SearchTest do
  @moduledoc """
  Tests for REQ-042's `Letflow.Definitions.search/2`. See `test/specs/REQ-042.md` for
  the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. `process_definitions` is a
  per-tenant-schema table (REQ-027), so this file follows
  `test/letflow/definitions/store_test.exs`'s established fixture pattern exactly
  (`provisioned_tenant/1` + Sandbox `:auto` mode + manual `on_exit/1` schema drop,
  `async: false` for the whole module) rather than inventing a new one.

  AC6 (the moduledoc's no-new-migration/PD-10 statement) needs no database at all and
  lives in `test/letflow/definitions_test.exs` instead, alongside that file's existing
  `normalized_moduledoc/1`-based doc-content checks for REQ-030/REQ-041 -- see this
  module's spec doc for why.

  ## Fixture isolation note (AC1's literal `"invoice"` name)

  Every test provisions its own fresh tenant schema (`provisioned_tenant/1`), so AC1's
  requirement for a definition literally named `"invoice"` causes no cross-test
  collision -- no other test in this suite, or any other file, shares that tenant
  schema. Every other identifier (`version`, `created_by`, and any name not literally
  mandated by an acceptance criterion) uses `unique_name/1`
  (`System.unique_integer/1`-suffixed) or a fresh `Ecto.UUID.generate()`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(_context \\ %{}) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req042",
      display_name: "REQ-042 Test Tenant"
    )
  end

  defp unique_name(prefix \\ "req042-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Minimal structurally-valid graph, same shape as store_test.exs's valid_graph/0.
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
  # AC1: "search/1 with query \"invoice\" returns a definition named exactly
  # \"invoice\" ranked above one named \"invoice-approval\" (partial name match),
  # which in turn ranks above one matched only via its description containing
  # \"invoice\"."
  # ---------------------------------------------------------------------------------

  describe "search/2 (AC1) -- ranking order: exact name > partial name > description-only" do
    test "exact name match (rank 3.0) ranks above partial name match (rank 2.0), which ranks above description-only match (rank 1.0)" do
      %{schema_name: schema_name} = provisioned_tenant()

      exact = create!(schema_name, %{name: "invoice", version: "1.0.0"})
      partial = create!(schema_name, %{name: "invoice-approval", version: "1.0.0"})

      description_only =
        create!(schema_name, %{
          name: unique_name("expense-report"),
          version: "1.0.0",
          description: "Handles invoice reconciliation for procurement"
        })

      assert {:ok, results} = Definitions.search("invoice", prefix: schema_name)

      rank_by_id = Map.new(results, fn %{definition: d, rank: r} -> {d.id, r} end)

      assert rank_by_id[exact.id] == 3.0
      assert rank_by_id[partial.id] == 2.0
      assert rank_by_id[description_only.id] == 1.0

      ids_in_order = Enum.map(results, & &1.definition.id)
      exact_idx = Enum.find_index(ids_in_order, &(&1 == exact.id))
      partial_idx = Enum.find_index(ids_in_order, &(&1 == partial.id))
      description_idx = Enum.find_index(ids_in_order, &(&1 == description_only.id))

      assert exact_idx < partial_idx,
             "exact name match must rank above partial name match in the returned order"

      assert partial_idx < description_idx,
             "partial name match must rank above description-only match in the returned order"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: "search/1 with an empty query string returns a QueryEmpty-equivalent error,
  # not an empty result list."
  # ---------------------------------------------------------------------------------

  describe "search/2 (AC2) -- empty query is a distinct error, not an empty list" do
    test "an empty query string returns {:error, :query_empty}" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert Definitions.search("", prefix: schema_name) == {:error, :query_empty}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: "search/1 with a query longer than 512 characters returns a
  # QueryTooLong-equivalent error."
  # ---------------------------------------------------------------------------------

  describe "search/2 (AC3) -- a query over 512 bytes is a distinct error from the empty-query error" do
    test "a 513-byte query returns {:error, :query_too_long}, distinct from :query_empty" do
      %{schema_name: schema_name} = provisioned_tenant()

      too_long_query = String.duplicate("a", 513)

      result = Definitions.search(too_long_query, prefix: schema_name)

      assert result == {:error, :query_too_long}
      refute result == {:error, :query_empty}
    end

    test "a query of exactly 512 bytes does not error (boundary: > 512, not >= 512)" do
      %{schema_name: schema_name} = provisioned_tenant()

      boundary_query = String.duplicate("a", 512)

      assert {:ok, _results} = Definitions.search(boundary_query, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4: "search/1 against a query with no matching name or description anywhere
  # returns an empty list, not an error."
  # ---------------------------------------------------------------------------------

  describe "search/2 (AC4) -- no matching name or description anywhere returns an empty list, not an error" do
    test "a query matching nothing returns {:ok, []}" do
      %{schema_name: schema_name} = provisioned_tenant()

      create!(schema_name, %{name: unique_name("onboarding-flow")})

      create!(schema_name, %{
        name: unique_name("expense-report"),
        description: "reimbursement workflow"
      })

      no_match_query = "nonexistent-term-#{System.unique_integer([:positive, :monotonic])}"

      assert Definitions.search(no_match_query, prefix: schema_name) == {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5: "search/1 respects limit (default 20) and offset for pagination,
  # demonstrated with more matching rows than fit in one page across two successive
  # calls."
  # ---------------------------------------------------------------------------------

  describe "search/2 (AC5) -- limit/offset paginate the ranked result" do
    test "default limit (20): 25 matching rows split into a 20-row page and a 5-row page, disjoint, covering every row" do
      %{schema_name: schema_name} = provisioned_tenant()

      token = "paginate-default-#{System.unique_integer([:positive, :monotonic])}"

      created_ids =
        for i <- 1..25 do
          create!(schema_name, %{name: "#{token}-item-#{i}"}).id
        end
        |> MapSet.new()

      assert {:ok, page1} = Definitions.search(token, prefix: schema_name)
      assert {:ok, page2} = Definitions.search(token, prefix: schema_name, offset: 20)

      assert length(page1) == 20
      assert length(page2) == 5

      page1_ids = MapSet.new(page1, & &1.definition.id)
      page2_ids = MapSet.new(page2, & &1.definition.id)

      assert MapSet.disjoint?(page1_ids, page2_ids),
             "the default-limit page and the offset-20 page must not overlap"

      assert MapSet.union(page1_ids, page2_ids) == created_ids,
             "the two successive pages together must cover every matching row exactly once"
    end

    test "explicit limit (10): 15 matching rows split into two 10/5-row pages via explicit :limit and :offset, disjoint, covering every row" do
      %{schema_name: schema_name} = provisioned_tenant()

      token = "paginate-explicit-#{System.unique_integer([:positive, :monotonic])}"

      created_ids =
        for i <- 1..15 do
          create!(schema_name, %{name: "#{token}-item-#{i}"}).id
        end
        |> MapSet.new()

      assert {:ok, page1} = Definitions.search(token, prefix: schema_name, limit: 10, offset: 0)
      assert {:ok, page2} = Definitions.search(token, prefix: schema_name, limit: 10, offset: 10)

      assert length(page1) == 10
      assert length(page2) == 5

      page1_ids = MapSet.new(page1, & &1.definition.id)
      page2_ids = MapSet.new(page2, & &1.definition.id)

      assert MapSet.disjoint?(page1_ids, page2_ids),
             "a caller-supplied :limit must actually partition results, not just the default"

      assert MapSet.union(page1_ids, page2_ids) == created_ids,
             "the two explicit-limit pages together must cover every matching row exactly once"
    end
  end
end
