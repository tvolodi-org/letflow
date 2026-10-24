defmodule Letflow.Entities.QueryTest do
  @moduledoc """
  Integration tests for `Letflow.Entities.Query.Types`,
  `Letflow.Entities.Query.Allowlist`, and `Letflow.Entities.Query.Compiler`
  (REQ-230) -- the closed operator/direction enums, the per-tenant field
  allowlist (with its typed-column-vs-JSONB-key shadowing precedence), and
  the parameterised SQL compiler. See
  `lib/letflow/design/req230-entity-query-dsl-compiler.md` for the design
  this file verifies, and REQ-230's own `docs/requirements.yaml` entry for
  the authoritative 7 acceptance criteria this file's `describe` blocks are
  grouped by.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/definitions_test.exs`/`records_test.exs`'s own
  hand-rolled tenant-fixture pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Repo
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req230-query",
        display_name: "REQ-230 Entity Query Test Tenant"
      )

    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp valid_definition(overrides) do
    Map.merge(
      %{
        name: "customer",
        display_name: "Customer",
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true},
          %{name: "age", type: :integer, queried: true},
          %{
            name: "balance",
            type: :decimal,
            queried: true,
            decimal_precision: 10,
            decimal_scale: 2
          }
        ]
      },
      overrides
    )
  end

  defp create_active_definition!(schema, overrides \\ %{}) do
    definition = valid_definition(overrides)

    assert {:ok, entity_definition} =
             Letflow.ManagedTypesSupport.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  defp create_record!(schema, field_values) do
    attrs = %{
      entity_type: "customer",
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- an operator outside the closed enum is rejected before reaching
  # the compiler, with a specific error naming the unrecognised operator.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- closed operator/direction enums (Types)" do
    test "parse_filter_op/1 accepts every documented operator string" do
      for {raw, expected} <- [
            {"eq", :eq},
            {"neq", :neq},
            {"gt", :gt},
            {"gte", :gte},
            {"lt", :lt},
            {"lte", :lte},
            {"in", :in},
            {"not_in", :not_in},
            {"contains", :contains},
            {"starts_with", :starts_with},
            {"is_null", :is_null},
            {"is_not_null", :is_not_null}
          ] do
        assert Types.parse_filter_op(raw) == {:ok, expected}
      end
    end

    test "parse_filter_op/1 rejects an operator outside the closed enum, naming it exactly" do
      assert Types.parse_filter_op("DROP TABLE") ==
               {:error, {:unknown_operator, "DROP TABLE"}}

      assert Types.parse_filter_op("regex_match") ==
               {:error, {:unknown_operator, "regex_match"}}
    end

    test "parse_sort_dir/1 accepts :asc/:desc and rejects anything else, naming it exactly" do
      assert Types.parse_sort_dir("asc") == {:ok, :asc}
      assert Types.parse_sort_dir("desc") == {:ok, :desc}

      assert Types.parse_sort_dir("sideways") ==
               {:error, {:unknown_sort_dir, "sideways"}}
    end

    test "an unrecognised operator never reaches the compiler -- caught entirely at the Types layer" do
      # The unrecognised string is never even wrapped into a filter_clause();
      # the caller (a future router) is expected to call parse_filter_op/1
      # first and only proceed to compile/2 on {:ok, _} -- demonstrated here
      # by parse_filter_op/1 itself being the rejection point.
      raw = "'; DROP TABLE entity_record_latest; --"
      assert {:error, {:unknown_operator, ^raw}} = Types.parse_filter_op(raw)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- a field name absent from the allowlist is rejected before
  # reaching the compiler.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- field allowlist rejection (Allowlist, Compiler)" do
    test "resolve_field/2 rejects a plausible-looking but non-existent field name" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert Allowlist.resolve_field(allowlist, "customer_email_address") ==
               {:error, {:field_not_allowed, "customer_email_address"}}
    end

    test "compile/2 rejects a filter clause naming a non-existent field, before ever building a query" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      request = %{
        entity_type: "customer",
        filters: [%{field: "customer_email_address", op: :eq, value: "a@b.com"}]
      }

      assert Compiler.compile(request, schema, :all) ==
               {:error, {:field_not_allowed, "customer_email_address"}}
    end

    test "compile/2 rejects a sort clause naming a non-existent field" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      request = %{entity_type: "customer", sort: [%{field: "not_a_real_field", dir: :asc}]}

      assert Compiler.compile(request, schema, :all) ==
               {:error, {:field_not_allowed, "not_a_real_field"}}
    end

    test "compile/2 rejects an unknown entity_type before ever loading fields" do
      %{schema_name: schema} = provisioned_tenant()

      request = %{entity_type: "does-not-exist", filters: []}

      assert Compiler.compile(request, schema, :all) == {:error, :entity_type_not_found}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- typed-column-vs-JSONB-key shadowing precedence: a field name
  # present both as a typed column and (theoretically) as a JSONB key
  # resolves to the typed column.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- typed-column-wins shadowing precedence" do
    test "moduledoc states the precedence rule explicitly" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Allowlist)

      assert moduledoc =~ "typed column"
      assert moduledoc =~ "takes precedence"
    end

    test "a field named 'deleted', also declared as a queried:true JSONB field, resolves to the typed column" do
      %{schema_name: schema} = provisioned_tenant()

      # A tenant's entity definition author declares a field literally named
      # "deleted" (shadowing the structural entity_record_latest.deleted
      # column) and marks it queried: true.
      create_active_definition!(schema, %{
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true},
          %{name: "deleted", type: :string, queried: true}
        ]
      })

      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert {:ok, resolved} = Allowlist.resolve_field(allowlist, "deleted")
      # Typed-column wins: source is :typed_column and type is :boolean (the
      # real entity_record_latest.deleted column's type), NOT :json_field/:string
      # (what the tenant's own definition declared).
      assert resolved.source == :typed_column
      assert resolved.type == :boolean
    end

    test "every structural typed-column name is present on every entity type's allowlist" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      for name <- Map.keys(Allowlist.typed_columns()) do
        assert {:ok, %{source: :typed_column}} = Allowlist.resolve_field(allowlist, name)
      end
    end

    test "a queried:true JSONB field with no colliding typed-column name resolves as :json_field" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, allowlist} = Allowlist.load("customer", schema)
      assert {:ok, resolved} = Allowlist.resolve_field(allowlist, "customer_name")
      assert resolved.source == :json_field
      assert resolved.type == :string
    end

    test "a field NOT marked queried: true is invisible to the allowlist" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true},
          %{name: "internal_notes", type: :string, queried: false}
        ]
      })

      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert Allowlist.resolve_field(allowlist, "internal_notes") ==
               {:error, {:field_not_allowed, "internal_notes"}}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- every caller-supplied filter VALUE is bound as a positional
  # parameter, never string-interpolated into SQL text -- demonstrated
  # against a REAL running Postgres database with a genuine SQL-metacharacter
  # payload.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- SQL-injection-payload values are treated as inert data (real Postgres execution)" do
    test "a string-field filter value containing a SQL-metacharacter payload matches zero rows, and the table survives untouched" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Acme", "age" => 42, "balance" => 10.50})
      create_record!(schema, %{"customer_name" => "Widgets Inc", "age" => 7, "balance" => 1.00})

      assert Repo.aggregate(Latest, :count, prefix: schema) == 2

      payload = "'; DROP TABLE entity_record_latest; --"

      request = %{
        entity_type: "customer",
        filters: [%{field: "customer_name", op: :eq, value: payload}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      # Execute the compiled query against the real tenant schema.
      results = Repo.all(query, prefix: schema)

      # The payload matched no legitimate row (inert data, not executed SQL).
      assert results == []

      # CRITICAL: the table still exists and still has both rows -- if the
      # payload had been executed as SQL (a real injection), the DROP TABLE
      # would have succeeded and this aggregate would raise
      # Postgrex.Error (undefined_table) instead of returning 2.
      assert Repo.aggregate(Latest, :count, prefix: schema) == 2
    end

    test "a :contains filter value containing a quote and wildcard characters is inert data, not a pattern-injection" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Acme", "age" => 42, "balance" => 10.50})

      payload = "%' OR '1'='1"

      request = %{
        entity_type: "customer",
        filters: [%{field: "customer_name", op: :contains, value: payload}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)
      results = Repo.all(query, prefix: schema)

      # If the payload's "OR '1'='1" fragment had been executed as SQL, every
      # row would match; instead it's inert data, matching nothing.
      assert results == []
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "a numeric JSONB field (:decimal) filter with an injection-shaped string value errors cleanly or matches nothing, never executes as SQL" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Acme", "age" => 42, "balance" => 10.50})

      payload = "1; DROP TABLE entity_record_latest; --"

      request = %{
        entity_type: "customer",
        filters: [%{field: "balance", op: :eq, value: payload}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      # The value is bound as a genuine positional parameter throughout --
      # confirmed here by the fact that it NEVER reaches Postgres as SQL
      # text at all: Postgrex's own numeric-parameter encoder rejects this
      # non-numeric string client-side (a clean `FunctionClauseError`, from
      # `Postgrex.Extensions.Numeric`'s encoder, not any kind of SQL parse
      # error), before a single byte of the query is sent over the wire.
      # Either that clean encode-time rejection, a clean Postgrex.Error, or
      # zero matching rows is acceptable per AC4's own wording ("treated as
      # inert data ... or errors cleanly") -- the table must survive either
      # way. `schema` is bound *before* this try/rescue (not inside its `do`
      # block) so it stays in scope in the `rescue` clause too.
      try do
        assert Repo.all(query, prefix: schema) == []
      rescue
        error in [Postgrex.Error, Ecto.QueryError, FunctionClauseError] -> assert error
      end

      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "the JSONB key name itself is bound as a parameter, not interpolated -- an allowlisted field name with no special characters compiles and runs" do
      # This subsystem's own design goes further than AC4's literal wording
      # (which names only the comparison value): the resolved field name is
      # also `^`-bound, never spliced into the fragment text. Demonstrated
      # indirectly here -- every allowlisted field name reaching the
      # compiler is proven safe by construction (Allowlist.load/2 only ever
      # enumerates finite, tenant-authored names), so this test asserts the
      # ordinary case still compiles/executes correctly end-to-end.
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Acme", "age" => 42, "balance" => 10.50})

      request = %{
        entity_type: "customer",
        filters: [%{field: "customer_name", op: :eq, value: "Acme"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      assert [%Latest{field_values: %{"customer_name" => "Acme"}}] =
               Repo.all(query, prefix: schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- SECURITY-REVIEWER's own hard gate; this describe block gives it
  # concrete material (structural coverage of INV-1/6/7/8), not a
  # self-certification.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- material for SECURITY-REVIEWER's gate" do
    test "compile/2 never raises on realistically-malformed caller input (INV-8) -- full error taxonomy" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # value_arity_mismatch -- :eq requires a value.
      assert {:error, {:value_arity_mismatch, :eq}} =
               Compiler.compile(
                 %{entity_type: "customer", filters: [%{field: "customer_name", op: :eq}]},
                 schema,
                 :all
               )

      # value_arity_mismatch -- :is_null forbids a value.
      assert {:error, {:value_arity_mismatch, :is_null}} =
               Compiler.compile(
                 %{
                   entity_type: "customer",
                   filters: [%{field: "customer_name", op: :is_null, value: "x"}]
                 },
                 schema,
                 :all
               )

      # invalid_in_value -- :in requires a list.
      assert {:error, {:invalid_in_value, "age"}} =
               Compiler.compile(
                 %{entity_type: "customer", filters: [%{field: "age", op: :in, value: 42}]},
                 schema,
                 :all
               )

      # operator_not_valid_for_type -- :contains against a non-string field.
      assert {:error, {:operator_not_valid_for_type, :contains, :integer}} =
               Compiler.compile(
                 %{
                   entity_type: "customer",
                   filters: [%{field: "age", op: :contains, value: "4"}]
                 },
                 schema,
                 :all
               )

      # invalid_schema_name -- a malformed prefix.
      assert {:error, :invalid_schema_name} =
               Compiler.compile(
                 %{entity_type: "customer", filters: []},
                 "not-a-real-schema",
                 :all
               )
    end

    test "no query is ever built against another tenant's schema (INV-1) -- compile/2 requires an explicit prefix" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      create_active_definition!(schema_a)
      create_active_definition!(schema_b)

      create_record!(schema_a, %{"customer_name" => "TenantA-Only", "age" => 1, "balance" => 1})

      request = %{
        entity_type: "customer",
        filters: [%{field: "customer_name", op: :eq, value: "TenantA-Only"}]
      }

      assert {:ok, query_a} = Compiler.compile(request, schema_a, :all)
      assert {:ok, query_b} = Compiler.compile(request, schema_b, :all)

      assert length(Repo.all(query_a, prefix: schema_a)) == 1
      # The same request compiled/executed under tenant B's own schema finds
      # nothing -- tenant B's schema has no such row, and there is no way
      # for query_b to reach tenant A's data.
      assert Repo.all(query_b, prefix: schema_b) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- no route/controller added or modified (structural -- verified via
  # `git diff --stat` in this requirement's handoff, not by a runnable test;
  # this test only pins that this module namespace stays outside any web/
  # router path so a future accidental addition is caught).
  # ---------------------------------------------------------------------------------

  describe "AC6 -- no route/controller in this subsystem" do
    test "Query.{Types,Allowlist,Compiler} are plain library modules -- none is a Plug/route/controller" do
      for module <- [Types, Allowlist, Compiler] do
        refute function_exported?(module, :init, 1) and function_exported?(module, :call, 2)
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Additional compiler coverage -- typed-column filters/sorts, JSONB
  # filters/sorts across field types, and :in/:not_in against a JSONB field
  # (design §9 open question 2).
  # ---------------------------------------------------------------------------------

  describe "typed-column filter/sort compilation" do
    test "filtering by the typed :deleted column excludes deleted records" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      %{record_id: record_id} =
        create_record!(schema, %{"customer_name" => "Acme", "age" => 42, "balance" => 1})

      assert {:ok, %{record: _deleted}} =
               Records.delete_record(
                 %{
                   entity_type: "customer",
                   record_id: record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      request = %{entity_type: "customer", filters: [%{field: "deleted", op: :eq, value: false}]}
      assert {:ok, query} = Compiler.compile(request, schema, :all)
      assert Repo.all(query, prefix: schema) == []

      request2 = %{entity_type: "customer", filters: [%{field: "deleted", op: :eq, value: true}]}
      assert {:ok, query2} = Compiler.compile(request2, schema, :all)
      assert length(Repo.all(query2, prefix: schema)) == 1
    end

    test "sorting by a typed column (inserted_at) orders results" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "First", "age" => 1, "balance" => 1})
      create_record!(schema, %{"customer_name" => "Second", "age" => 2, "balance" => 2})

      request = %{entity_type: "customer", sort: [%{field: "inserted_at", dir: :desc}]}
      assert {:ok, query} = Compiler.compile(request, schema, :all)

      [first, second] = Repo.all(query, prefix: schema)
      assert first.field_values["customer_name"] == "Second"
      assert second.field_values["customer_name"] == "First"
    end
  end

  describe "JSONB filter/sort compilation across field types" do
    test "filtering by an integer JSONB field with :gt casts numerically" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Young", "age" => 5, "balance" => 1})
      create_record!(schema, %{"customer_name" => "Old", "age" => 99, "balance" => 1})

      request = %{entity_type: "customer", filters: [%{field: "age", op: :gt, value: 10}]}
      assert {:ok, query} = Compiler.compile(request, schema, :all)

      assert [%Latest{field_values: %{"customer_name" => "Old"}}] =
               Repo.all(query, prefix: schema)
    end

    test "filtering by :in against a JSONB string field" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Acme", "age" => 1, "balance" => 1})
      create_record!(schema, %{"customer_name" => "Widgets", "age" => 2, "balance" => 1})
      create_record!(schema, %{"customer_name" => "Other", "age" => 3, "balance" => 1})

      request = %{
        entity_type: "customer",
        filters: [%{field: "customer_name", op: :in, value: ["Acme", "Widgets"]}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)
      results = Repo.all(query, prefix: schema)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.field_values["customer_name"] in ["Acme", "Widgets"]))
    end

    test "sorting by a decimal JSONB field casts numerically, not lexicographically" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "A", "age" => 1, "balance" => 9.00})
      create_record!(schema, %{"customer_name" => "B", "age" => 1, "balance" => 10.00})
      create_record!(schema, %{"customer_name" => "C", "age" => 1, "balance" => 2.00})

      request = %{entity_type: "customer", sort: [%{field: "balance", dir: :asc}]}
      assert {:ok, query} = Compiler.compile(request, schema, :all)

      names = query |> Repo.all(prefix: schema) |> Enum.map(& &1.field_values["customer_name"])
      # Numeric order: 2.00 < 9.00 < 10.00. A lexicographic (text) sort would
      # have put "10.00" before "2.00" and "9.00".
      assert names == ["C", "A", "B"]
    end

    test "an empty filters/sort request is a plain unfiltered read" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Acme", "age" => 1, "balance" => 1})

      assert {:ok, query} = Compiler.compile(%{entity_type: "customer"}, schema, :all)
      assert length(Repo.all(query, prefix: schema)) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-299 -- Allowlist.typed_columns/2, the per-entity-type promoted-column
  # accessor. See lib/letflow/design/req299-allowlist-per-entity-type.md.
  # Deliberately does NOT touch load/2's own AC3 coverage above (the
  # shadowing-precedence tests in "AC3 -- typed-column-wins shadowing
  # precedence" are re-confirmed as-is, unmodified, by this same file already
  # running -- load/2's behavior is unchanged per REWORK ITERATION 1, so no
  # new AC3 test is added here).
  # ---------------------------------------------------------------------------------

  describe "REQ-299 AC1/AC2/AC4 -- typed_columns/2 per-entity-type promoted columns" do
    # Raw, atom-keyed definition maps -- the exact shape both
    # create_active_definition!/2 (via Definitions.create_definition/2, which
    # persists them as definition_json) and DDL.promoted_columns/1 (which
    # consumes a Definition.t()-shaped map directly, no JSON round-trip)
    # accept. Kept as plain maps here (not passed through JSON encode/decode)
    # so the AC2 test below can feed the *same* fixture value to
    # DDL.promoted_columns/1 that Allowlist.typed_columns/2 independently
    # re-derives after its own JSON round-trip -- proving agreement between
    # two different code paths, not two hand-copied lists.
    defp order_definition_fields do
      [
        %{
          name: "total_amount",
          type: :decimal,
          queried: true,
          decimal_precision: 10,
          decimal_scale: 2
        },
        %{name: "customer_id", type: :string, queried: false}
      ]
    end

    defp order_definition_foreign_keys do
      [%{name: "fk_customer", field: "customer_id", references_entity: "customer"}]
    end

    defp tag_definition_fields do
      [%{name: "label", type: :string, required: true, queried: false}]
    end

    test "AC1: typed_columns/2's promoted-column key sets differ across two entity-type fixtures with different promoted columns" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "order",
        fields: order_definition_fields(),
        foreign_keys: order_definition_foreign_keys()
      })

      create_active_definition!(schema, %{name: "tag", fields: tag_definition_fields()})

      assert {:ok, order_columns} = Allowlist.typed_columns("order", schema)
      assert {:ok, tag_columns} = Allowlist.typed_columns("tag", schema)

      order_keys = MapSet.new(Map.keys(order_columns))
      tag_keys = MapSet.new(Map.keys(tag_columns))

      # If typed_columns/2 ignored entity_type and returned a global set (the
      # bug this test exists to catch), order_keys and tag_keys would be
      # identical. They must differ by exactly "order"'s two promoted names.
      refute order_keys == tag_keys

      assert MapSet.difference(order_keys, tag_keys) ==
               MapSet.new(["total_amount", "customer_id"])
    end

    test "AC2: typed_columns/2's promoted names agree exactly with DDL.promoted_columns/1's own enumeration for the same definition" do
      %{schema_name: schema} = provisioned_tenant()

      raw_definition = %{
        fields: order_definition_fields(),
        foreign_keys: order_definition_foreign_keys()
      }

      create_active_definition!(schema, %{
        name: "order",
        fields: raw_definition.fields,
        foreign_keys: raw_definition.foreign_keys
      })

      assert {:ok, order_columns} = Allowlist.typed_columns("order", schema)

      structural_names = MapSet.new(Map.keys(Allowlist.typed_columns()))

      promoted_names_from_allowlist =
        MapSet.new(Map.keys(order_columns)) |> MapSet.difference(structural_names)

      # DDL.promoted_columns/1 called directly here, against the very same
      # raw definition -- not a second, independently-hand-maintained list.
      promoted_names_from_ddl =
        raw_definition |> DDL.promoted_columns() |> MapSet.new(& &1.name)

      assert promoted_names_from_allowlist == promoted_names_from_ddl
      assert promoted_names_from_allowlist == MapSet.new(["total_amount", "customer_id"])
    end

    test "AC4: typed_columns/2 includes a queried:true field AND an FK-derived field for 'order', and neither for 'tag' (design doc §1.2.1 fixture pair)" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "order",
        fields: order_definition_fields(),
        foreign_keys: order_definition_foreign_keys()
      })

      create_active_definition!(schema, %{name: "tag", fields: tag_definition_fields()})

      assert {:ok, order_columns} = Allowlist.typed_columns("order", schema)
      assert {:ok, tag_columns} = Allowlist.typed_columns("tag", schema)

      structural = Map.keys(Allowlist.typed_columns())

      # "order": both promoted triggers present, alongside the structural 7.
      assert "total_amount" in Map.keys(order_columns)
      assert "customer_id" in Map.keys(order_columns)
      assert Enum.all?(structural, &(&1 in Map.keys(order_columns)))

      # "tag": neither trigger fires -- exactly the structural 7, no more.
      assert MapSet.new(Map.keys(tag_columns)) == MapSet.new(structural)
      refute "total_amount" in Map.keys(tag_columns)
      refute "customer_id" in Map.keys(tag_columns)
    end

    test "typed_columns/2 propagates {:error, :entity_type_not_found} for an unknown entity type" do
      %{schema_name: schema} = provisioned_tenant()

      assert Allowlist.typed_columns("does-not-exist", schema) ==
               {:error, :entity_type_not_found}
    end

    test "typed_columns/2 propagates {:error, :invalid_schema_name} for a non-provisioned schema" do
      assert Allowlist.typed_columns("order", "not_a_real_schema__") ==
               {:error, :invalid_schema_name}
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-301 AC5 (amended/narrowed) -- a :localized_text field's per-locale
  # generated columns are exposed via typed_columns/2, never the base field
  # name; and load/2 never allowlists the base name either, per §4.6's fix.
  # See lib/letflow/design/req301-localized-text-field-type.md §4.6/§5.
  # ---------------------------------------------------------------------------------

  describe "REQ-301 AC5 -- typed_columns/2 exposes per-locale generated columns, never the base name" do
    test "typed_columns/2 for an entity type with a queried:true :localized_text field returns exactly the per-locale columns, typed :string, not the base field name" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question",
        fields: [
          %{
            name: "stem",
            type: :localized_text,
            locales: ["kk", "ru"],
            queried: true
          }
        ]
      })

      assert {:ok, columns} = Allowlist.typed_columns("question", schema)

      structural = Map.keys(Allowlist.typed_columns())
      promoted_names = Map.keys(columns) -- structural

      assert MapSet.new(promoted_names) == MapSet.new(["stem_kk", "stem_ru"])
      assert columns["stem_kk"] == :string
      assert columns["stem_ru"] == :string
      refute Map.has_key?(columns, "stem")
    end

    test "typed_columns/2 exposes locale columns for :fulltext exactly the same way (still :string, not a tsvector-flavored type)" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question",
        fields: [
          %{
            name: "stem",
            type: :localized_text,
            locales: ["kk"],
            queried: true,
            search_strategy: :fulltext
          }
        ]
      })

      assert {:ok, columns} = Allowlist.typed_columns("question", schema)
      assert columns["stem_kk"] == :string
      refute Map.has_key?(columns, "stem")
    end

    test "load/2 does not crash and does not allowlist the base :localized_text field name under its own bare name" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk", "ru"], queried: true}
        ]
      })

      # Before the §4.6 fix, this same fixture would allowlist "stem" as a
      # :json_field entry that crashes Compiler.json_cast_dynamic/2's
      # FunctionClauseError the moment it is resolved -- this asserts load/2
      # itself never produces that entry in the first place.
      assert {:ok, allowlist} = Allowlist.load("question", schema)
      refute Map.has_key?(allowlist, "stem")

      assert Allowlist.resolve_field(allowlist, "stem") ==
               {:error, {:field_not_allowed, "stem"}}
    end

    test "a :localized_text field NOT queried: true is absent from both typed_columns/2 and load/2" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question",
        fields: [%{name: "stem", type: :localized_text, locales: ["kk", "ru"]}]
      })

      assert {:ok, columns} = Allowlist.typed_columns("question", schema)
      structural = Map.keys(Allowlist.typed_columns())
      assert MapSet.new(Map.keys(columns)) == MapSet.new(structural)

      assert {:ok, allowlist} = Allowlist.load("question", schema)
      refute Map.has_key?(allowlist, "stem")
      refute Map.has_key?(allowlist, "stem_kk")
    end
  end
end
