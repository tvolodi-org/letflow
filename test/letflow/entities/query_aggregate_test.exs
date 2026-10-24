defmodule Letflow.Entities.QueryAggregateTest do
  @moduledoc """
  Tests for `Letflow.Entities.Query.Compiler.compile_aggregate/2` (REQ-315),
  written by ELIXIR-DEV per
  `lib/letflow/design/req312-query-aggregation.md` §1/§2. Exercises
  `compile_aggregate/2` directly (not through the HTTP route -- that surface
  is covered by `test/letflow/routers/entities_aggregate_test.exs`, including
  the §4 INV-2 field-restriction check, which lives entirely in the router,
  not here).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Records
  alias Letflow.Repo
  alias Letflow.TenantFixture

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp ctx do
    ctx =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req315-aggregate",
        display_name: "REQ-315 Aggregate Compiler Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(ctx.schema_name)
    ctx
  end

  defp seed_widget_definition!(ctx) do
    document = %{
      name: "widget",
      display_name: "Widget",
      fields: [
        %{name: "title", type: :string, queried: true},
        %{name: "category", type: :string, queried: true},
        %{name: "quantity", type: :integer, queried: true},
        %{name: "price", type: :decimal, queried: true, decimal_precision: 10, decimal_scale: 2}
      ]
    }

    {:ok, entity_definition} =
      Letflow.ManagedTypesSupport.create_definition(
        %{definition: document, created_by: Ecto.UUID.generate()},
        ctx.schema_name
      )

    {:ok, _activated} =
      Definitions.activate_definition(
        entity_definition.name,
        Ecto.UUID.generate(),
        "req315 go-live",
        ctx.schema_name
      )

    :ok
  end

  defp seed_record!(ctx, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "widget",
          field_values: field_values,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp run(request, prefix) do
    {:ok, query} = Compiler.compile_aggregate(request, prefix, :all)
    Repo.all(query, prefix: prefix)
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- each of :count/:sum/:avg/:min/:max produces the correct value
  # against seeded records, including zero-matching-rows behaviour.
  # ═══════════════════════════════════════════════════════════════════════

  describe "aggregate functions against seeded records" do
    test "count over three records returns 3" do
      ctx = ctx()
      seed_widget_definition!(ctx)
      seed_record!(ctx, %{"title" => "a", "quantity" => 1})
      seed_record!(ctx, %{"title" => "b", "quantity" => 2})
      seed_record!(ctx, %{"title" => "c", "quantity" => 3})

      request = %{entity_type: "widget", aggregates: [%{fn: :count}]}
      assert [%{"agg__count_none" => 3}] = run(request, ctx.schema_name)
    end

    test "count over zero matching rows returns 0, not nil" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :count}]}
      assert [%{"agg__count_none" => 0}] = run(request, ctx.schema_name)
    end

    test "sum over an integer field returns the correct total" do
      ctx = ctx()
      seed_widget_definition!(ctx)
      seed_record!(ctx, %{"title" => "a", "quantity" => 5})
      seed_record!(ctx, %{"title" => "b", "quantity" => 7})

      request = %{entity_type: "widget", aggregates: [%{fn: :sum, field: "quantity"}]}
      assert [%{"agg__sum_quantity" => sum}] = run(request, ctx.schema_name)
      # SUM over a Postgres bigint (this JSON field's ::bigint cast) returns
      # NUMERIC per the SQL standard (overflow avoidance), which Postgrex
      # decodes as a %Decimal{}, not a plain integer -- real Postgres
      # behavior, not a bug to work around.
      assert Decimal.compare(Decimal.new("#{sum}"), Decimal.new("12")) == :eq
    end

    test "sum over zero matching rows returns nil, not 0" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :sum, field: "quantity"}]}
      assert [%{"agg__sum_quantity" => nil}] = run(request, ctx.schema_name)
    end

    test "avg over zero matching rows returns nil, not 0" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :avg, field: "quantity"}]}
      assert [%{"agg__avg_quantity" => nil}] = run(request, ctx.schema_name)
    end

    test "avg over an integer field returns the correct average" do
      ctx = ctx()
      seed_widget_definition!(ctx)
      seed_record!(ctx, %{"title" => "a", "quantity" => 4})
      seed_record!(ctx, %{"title" => "b", "quantity" => 6})

      request = %{entity_type: "widget", aggregates: [%{fn: :avg, field: "quantity"}]}
      assert [%{"agg__avg_quantity" => avg}] = run(request, ctx.schema_name)
      assert Decimal.compare(Decimal.new("#{avg}"), Decimal.new("5")) == :eq
    end

    test "min/max over a decimal field return the correct boundary values" do
      ctx = ctx()
      seed_widget_definition!(ctx)
      seed_record!(ctx, %{"title" => "a", "price" => 9.99})
      seed_record!(ctx, %{"title" => "b", "price" => 3.50})
      seed_record!(ctx, %{"title" => "c", "price" => 27.00})

      min_request = %{entity_type: "widget", aggregates: [%{fn: :min, field: "price"}]}
      max_request = %{entity_type: "widget", aggregates: [%{fn: :max, field: "price"}]}

      assert [%{"agg__min_price" => min_val}] = run(min_request, ctx.schema_name)
      assert [%{"agg__max_price" => max_val}] = run(max_request, ctx.schema_name)

      assert Decimal.compare(Decimal.new("#{min_val}"), Decimal.new("3.50")) == :eq
      assert Decimal.compare(Decimal.new("#{max_val}"), Decimal.new("27.00")) == :eq
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- a group_by request returns one result entry per distinct
  # grouping-key combination, each carrying a group map keyed by the
  # group_by field name.
  # ═══════════════════════════════════════════════════════════════════════

  describe "group_by" do
    test "one entry per distinct grouping key, each carrying that key's value" do
      ctx = ctx()
      seed_widget_definition!(ctx)
      seed_record!(ctx, %{"title" => "a", "category" => "tools", "quantity" => 1})
      seed_record!(ctx, %{"title" => "b", "category" => "tools", "quantity" => 2})
      seed_record!(ctx, %{"title" => "c", "category" => "parts", "quantity" => 10})

      request = %{
        entity_type: "widget",
        aggregates: [%{fn: :count}],
        group_by: [%{field: "category"}]
      }

      rows = run(request, ctx.schema_name) |> Enum.sort_by(& &1["group__category"])

      assert [
               %{"group__category" => "parts", "agg__count_none" => 1},
               %{"group__category" => "tools", "agg__count_none" => 2}
             ] = rows
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- INV-7: group_by/aggregate target fields absent from the allowlist
  # return {:field_not_allowed, _}.
  # ═══════════════════════════════════════════════════════════════════════

  describe "INV-7 -- field resolution goes through the existing allowlist" do
    test "an aggregate target field absent from the allowlist is rejected" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :sum, field: "not_a_real_field"}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:field_not_allowed, "not_a_real_field"}}
    end

    test "a group_by field absent from the allowlist is rejected" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{
        entity_type: "widget",
        aggregates: [%{fn: :count}],
        group_by: [%{field: "not_a_real_field"}]
      }

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:field_not_allowed, "not_a_real_field"}}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- arity/type checks: sum/avg over the wrong field type,
  # sum/avg/min/max naming no field, count naming a field anyway.
  # ═══════════════════════════════════════════════════════════════════════

  describe "arity and field-type checks" do
    test "sum over a :string field returns 422-shaped {:aggregate_type_not_valid, ...}" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :sum, field: "title"}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:aggregate_type_not_valid, :sum, :string}}
    end

    test "sum naming no field returns {:aggregate_field_required, :sum}" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :sum}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:aggregate_field_required, :sum}}
    end

    test "avg naming no field returns {:aggregate_field_required, :avg}" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :avg}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:aggregate_field_required, :avg}}
    end

    test "min naming no field returns {:aggregate_field_required, :min}" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :min}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:aggregate_field_required, :min}}
    end

    test "max naming no field returns {:aggregate_field_required, :max}" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :max}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:aggregate_field_required, :max}}
    end

    test "count naming a field anyway returns {:aggregate_field_not_allowed, :count}" do
      ctx = ctx()
      seed_widget_definition!(ctx)

      request = %{entity_type: "widget", aggregates: [%{fn: :count, field: "quantity"}]}

      assert Compiler.compile_aggregate(request, ctx.schema_name, :all) ==
               {:error, {:aggregate_field_not_allowed, :count}}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # git diff / grep-verified non-regression: compile/2 itself is untouched
  # (spot-checked here at the test level too -- the real proof is the
  # `git diff` grep the requirement's own acceptance criteria call for).
  # ═══════════════════════════════════════════════════════════════════════

  describe "compile/2 non-regression" do
    test "an ordinary compile/2 request against the same fixture still works unchanged" do
      ctx = ctx()
      seed_widget_definition!(ctx)
      seed_record!(ctx, %{"title" => "a", "quantity" => 1})

      request = %{entity_type: "widget", filters: [], sort: [], join: []}
      assert {:ok, query} = Compiler.compile(request, ctx.schema_name, :all)
      assert [%Letflow.Entities.Record.Latest{}] = Repo.all(query, prefix: ctx.schema_name)
    end
  end
end
