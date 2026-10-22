defmodule Letflow.Entities.QueryCursorFieldGrantsTest do
  @moduledoc """
  Tests for `Letflow.Entities.Query.Cursor` and
  `Letflow.Entities.Query.FieldGrants` (REQ-231) -- the generalized
  keyset-pagination cursor codec and the per-user, per-field redaction
  loader. See `lib/letflow/design/req231-entity-query-cursor-field-grants.md`
  for the design this file verifies, and REQ-231's own
  `docs/requirements.yaml` entry for the authoritative 5 acceptance
  criteria this file's `describe` blocks are grouped by.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked
  database. Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/query_test.exs`'s own hand-rolled tenant-fixture
  pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file's own on_exit also deletes its
  # domain-specific ColumnPromotion rows before the Tenant row (needed:
  # entity_column_promotions.tenant_id has on_delete: :nothing, so it must
  # be cleared before Tenant is deleted or the standard fixture teardown's
  # own Tenant delete would violate the FK).
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req231-cursor-fg",
        display_name: "REQ-231 Cursor/FieldGrants Test Tenant",
        teardown: false
      )

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

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
          %{name: "ssn", type: :string, queried: true}
        ]
      },
      overrides
    )
  end

  defp create_active_definition!(schema, overrides \\ %{}) do
    definition = valid_definition(overrides)

    assert {:ok, entity_definition} =
             Definitions.create_definition(
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

  # Same as create_record!/2 but for an arbitrary entity_type (ISS-0600's
  # "promoted_customer" fixture, not the "customer" this file's other
  # tests use) -- mirrors query_joins_test.exs's own create_record!/3.
  defp create_record_for!(schema, entity_type, field_values) do
    attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  defp create_user!(schema, username) do
    assert {:ok, user} =
             Identity.create_user(
               %{
                 "username" => username,
                 "display_name" => username,
                 "email" => "#{username}@example.test"
               },
               prefix: schema,
               login_directory: :skip
             )

    user
  end

  defp insert_field_restriction!(schema, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp insert_user_grant!(schema, user_id, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- a query result set larger than one page returns a next_cursor,
  # and passing that cursor back returns the next distinct page with no
  # repeated or skipped records. Exercised against a GENERIC (multi-field,
  # non-default) sort clause, not the trivial `inserted_at desc, id desc`
  # shape, to prove the codec genuinely generalizes (REQ-230's compiler
  # accepts any allowlisted field/fields).
  # ---------------------------------------------------------------------------------

  describe "AC1 -- keyset pagination over a generic sort clause (Cursor)" do
    test "next_cursor round-trips through every page with no repeated or skipped records" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # Two customers named "Alice" and "Bob"; multiple ages under "Alice" to
      # exercise the tiebreak between the two sort fields themselves (not
      # just the trailing id tiebreak).
      fixtures = [
        {"Alice", 30},
        {"Alice", 25},
        {"Alice", 20},
        {"Bob", 40},
        {"Bob", 10}
      ]

      for {name, age} <- fixtures do
        create_record!(schema, %{"customer_name" => name, "age" => age})
      end

      # A genuine multi-field, caller-chosen sort: customer_name asc, age
      # desc -- not REQ-067's fixed inserted_at/id shape.
      request = %{
        entity_type: "customer",
        sort: [
          %{field: "customer_name", dir: :asc},
          %{field: "age", dir: :desc}
        ]
      }

      assert {:ok, compiled_query} = Compiler.compile(request, schema, :all)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      expected_order = [
        {"Alice", 30},
        {"Alice", 25},
        {"Alice", 20},
        {"Bob", 40},
        {"Bob", 10}
      ]

      {all_items, pages_seen} =
        paginate_all(request, compiled_query, allowlist, schema, page_size: 2)

      # 3 pages of size 2, 2, 1 for 5 total records.
      assert pages_seen == 3

      actual_order =
        Enum.map(all_items, fn item ->
          {Map.fetch!(item.field_values, "customer_name"), Map.fetch!(item.field_values, "age")}
        end)

      assert actual_order == expected_order

      # No repeated or skipped records.
      ids = Enum.map(all_items, & &1.id)
      assert length(ids) == length(fixtures)
      assert length(Enum.uniq(ids)) == length(fixtures)
    end

    test "a page smaller than page_size returns no next_cursor" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Solo", "age" => 1})

      request = %{entity_type: "customer", sort: [%{field: "age", dir: :asc}]}

      assert {:ok, compiled_query} = Compiler.compile(request, schema, :all)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert {:ok, page} =
               Cursor.paginate(request, compiled_query, allowlist, %{page_size: 10}, schema)

      assert length(page.items) == 1
      assert page.next_cursor == nil
    end

    test "resending a cursor with a different sort shape than the one that minted it is rejected" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      for age <- [1, 2, 3] do
        create_record!(schema, %{"customer_name" => "X", "age" => age})
      end

      mint_request = %{
        entity_type: "customer",
        sort: [%{field: "customer_name", dir: :asc}, %{field: "age", dir: :asc}]
      }

      assert {:ok, compiled_query} = Compiler.compile(mint_request, schema, :all)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert {:ok, page} =
               Cursor.paginate(mint_request, compiled_query, allowlist, %{page_size: 1}, schema)

      refute is_nil(page.next_cursor)

      # Resend with only one sort field -- arity no longer matches.
      resume_request = %{entity_type: "customer", sort: [%{field: "age", dir: :asc}]}
      assert {:ok, compiled_query2} = Compiler.compile(resume_request, schema, :all)

      assert Cursor.paginate(
               resume_request,
               compiled_query2,
               allowlist,
               %{page_size: 1, cursor: page.next_cursor},
               schema
             ) == {:error, :resume_key_arity_mismatch}
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0522 (site 2) -- Cursor.paginate/5's id-tiebreaker component must be
  # validated as a real UUID before it reaches maybe_dump/2's unconditional
  # Ecto.UUID.dump!/1, returning {:error, :invalid_cursor} for a malformed
  # component instead of letting an ArgumentError raise. See
  # lib/letflow/design/iss0522-cursor-uuid-cast-guard.md §6 (esp. §6.6) and
  # test/specs/ISS-0522.md's "Site 2" section for the acceptance criteria
  # this describe block covers. Mirrors this issue's own site-1 coverage in
  # test/letflow/entities/definitions_test.exs.
  # ---------------------------------------------------------------------------------

  describe "ISS-0522 (site 2) -- malformed id-component cast guard (Cursor.paginate/5)" do
    setup do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      for age <- [10, 20] do
        create_record!(schema, %{"customer_name" => "Guard", "age" => age})
      end

      request = %{entity_type: "customer", sort: [%{field: "age", dir: :asc}]}
      assert {:ok, compiled_query} = Compiler.compile(request, schema, :all)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist}
    end

    # Mints a cursor by hand -- the same "EQ:<mint_time_us>:<resume_key_json>"
    # shape Cursor.build_next_cursor/2 itself produces -- with an
    # attacker/caller-controlled id component, exactly as a real
    # network-facing request body would carry it.
    defp raw_cursor_with_id(sort_values, id_value) do
      resume_key_json = Jason.encode!(sort_values ++ [id_value])
      mint_time_us = System.system_time(:microsecond)

      Cursor.cursor_prefix()
      |> Pagination.build_raw_cursor(mint_time_us, resume_key_json)
      |> Pagination.encode_cursor()
    end

    test "a non-UUID id component returns {:error, :invalid_cursor}, not a raise",
         %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist} do
      encoded = raw_cursor_with_id([15], "not-a-uuid")

      assert Cursor.paginate(
               request,
               compiled_query,
               allowlist,
               %{page_size: 10, cursor: encoded},
               schema
             ) == {:error, :invalid_cursor}
    end

    test "a UUID-length id component with invalid hex/hyphen content is still rejected",
         %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist} do
      # 36 characters, hyphens in the right positions -- proves
      # Ecto.UUID.cast/1's real validation gates this, not a bare length check.
      bogus_uuid_shaped = "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
      assert String.length(bogus_uuid_shaped) == 36

      encoded = raw_cursor_with_id([15], bogus_uuid_shaped)

      assert Cursor.paginate(
               request,
               compiled_query,
               allowlist,
               %{page_size: 10, cursor: encoded},
               schema
             ) == {:error, :invalid_cursor}
    end

    test "non-regression: a valid, system-minted cursor (real UUID id component) still paginates cleanly",
         %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist} do
      assert {:ok, first_page} =
               Cursor.paginate(
                 request,
                 compiled_query,
                 allowlist,
                 %{page_size: 1},
                 schema
               )

      assert [%{field_values: %{"age" => 10}}] = first_page.items
      refute is_nil(first_page.next_cursor)

      assert {:ok, second_page} =
               Cursor.paginate(
                 request,
                 compiled_query,
                 allowlist,
                 %{page_size: 1, cursor: first_page.next_cursor},
                 schema
               )

      assert [%{field_values: %{"age" => 20}}] = second_page.items
      assert second_page.next_cursor == nil
    end
  end

  defp paginate_all(request, compiled_query, allowlist, schema, page_size: page_size) do
    do_paginate_all(request, compiled_query, allowlist, schema, page_size, nil, [], 0)
  end

  defp do_paginate_all(request, compiled_query, allowlist, schema, page_size, cursor, acc, pages) do
    opts = %{page_size: page_size, cursor: cursor}

    assert {:ok, page} = Cursor.paginate(request, compiled_query, allowlist, opts, schema)

    acc = acc ++ page.items
    pages = pages + 1

    case page.next_cursor do
      nil ->
        {acc, pages}

      next ->
        do_paginate_all(request, compiled_query, allowlist, schema, page_size, next, acc, pages)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- a user holding a field-level restriction has that field redacted
  # (not the whole row), while a user without that restriction sees the
  # field populated. Two explicit tests, per the requirement's own text.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- per-field, per-user redaction (FieldGrants)" do
    setup do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      record =
        create_record!(schema, %{
          "customer_name" => "Alice",
          "age" => 30,
          "ssn" => "123-45-6789"
        })

      # "ssn" is restricted by default for everyone on this entity type.
      insert_field_restriction!(schema, "customer", "ssn")

      %{schema: schema, record: record}
    end

    test "a user with no matching grant has the restricted field redacted, key retained",
         %{schema: schema, record: record} do
      user_without_grant = create_user!(schema, "no-grant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user_without_grant.id, "customer", schema)

      redacted = FieldGrants.redact_field_values(record.field_values, restriction_set)

      assert Map.has_key?(redacted, "ssn")
      assert redacted["ssn"] == FieldGrants.redacted_sentinel()
      assert redacted["ssn"] == :__field_redacted__
      # Unrestricted fields pass through unchanged.
      assert redacted["customer_name"] == "Alice"
      assert redacted["age"] == 30
    end

    test "a user holding an explicit grant sees the restricted field populated",
         %{schema: schema, record: record} do
      user_with_grant = create_user!(schema, "granted-user")
      insert_user_grant!(schema, user_with_grant.id, "customer", "ssn")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user_with_grant.id, "customer", schema)

      redacted = FieldGrants.redact_field_values(record.field_values, restriction_set)

      assert redacted["ssn"] == "123-45-6789"
      assert redacted["customer_name"] == "Alice"
      assert redacted["age"] == 30
    end

    test "redact_page/2 redacts every item's field_values while preserving next_cursor/count",
         %{schema: schema, record: record} do
      user_without_grant = create_user!(schema, "page-no-grant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user_without_grant.id, "customer", schema)

      page = Letflow.Api.Pagination.page_response([record], "some-next-cursor")
      redacted_page = FieldGrants.redact_page(page, restriction_set)

      assert redacted_page.next_cursor == "some-next-cursor"
      assert redacted_page.count == 1
      [item] = redacted_page.items
      assert item.field_values["ssn"] == :__field_redacted__
    end

    test "an entity type with zero restricted fields yields an empty restriction set, never an error",
         %{schema: schema} do
      user = create_user!(schema, "irrelevant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user.id, "does-not-exist-entity-type", schema)

      assert MapSet.size(restriction_set) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0600 -- redact_page/2 (via redact_item/2) crashed with
  # FunctionClauseError on a promoted per-type-table row (a bare
  # Compiler.entity_row() map), since redact_item/2 previously only matched
  # a %Latest{} struct. See
  # lib/letflow/design/iss0600-field-grants-per-type-table-row-shape.md.
  # promote_and_create_table!/5 below is copied verbatim (not imported --
  # it's `defp` in query_joins_test.exs) from
  # test/letflow/entities/query_joins_test.exs:112-135, matching this
  # codebase's convention of duplicating small test helpers across files.
  # ---------------------------------------------------------------------------------

  defp promote_and_create_table!(schema, tenant_id, entity_type, attribute, pg_type, opts \\ []) do
    references_entity = Keyword.get(opts, :references_entity)

    column_spec =
      if references_entity do
        %{pg_type: pg_type, nullable: true, references_entity: references_entity}
      else
        %{pg_type: pg_type, nullable: true}
      end

    assert {:ok, [row]} =
             TenantProvisioning.register_column_promotion(
               entity_type,
               attribute,
               column_spec,
               [tenant_id]
             )

    assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
             TenantProvisioning.run_column_promotion(row.id)

    assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type(entity_type)
    table_name
  end

  describe "promoted per-type-table row shape (ISS-0600)" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "promoted_customer",
        display_name: "Promoted Customer",
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true},
          %{name: "age", type: :integer, queried: true},
          %{name: "ssn", type: :string, queried: true}
        ]
      })

      promote_and_create_table!(schema, tenant_id, "promoted_customer", "customer_name", "text")

      record =
        create_record_for!(schema, "promoted_customer", %{
          "customer_name" => "Alice",
          "age" => 30,
          "ssn" => "123-45-6789"
        })

      insert_field_restriction!(schema, "promoted_customer", "ssn")

      %{schema: schema, record: record}
    end

    test "redact_page/2 accepts a promoted per-type-table row (entity_row() map shape) and redacts it identically to the %Latest{} path",
         %{schema: schema} do
      assert {:ok, query} = Compiler.compile(%{entity_type: "promoted_customer"}, schema, :all)

      assert [%{field_values: %{"ssn" => "123-45-6789"}} = row] = Repo.all(query, prefix: schema)
      refute match?(%Latest{}, row)

      page = Pagination.page_response([row], "some-next-cursor")

      user_without_grant = create_user!(schema, "promoted-no-grant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(
                 user_without_grant.id,
                 "promoted_customer",
                 schema
               )

      redacted_page = FieldGrants.redact_page(page, restriction_set)

      assert redacted_page.next_cursor == "some-next-cursor"
      assert redacted_page.count == 1
      [item] = redacted_page.items
      assert item.field_values["ssn"] == FieldGrants.redacted_sentinel()
      assert item.field_values["customer_name"] == "Alice"
      assert item.field_values["age"] == 30
    end

    test "a user holding an explicit grant sees the field populated, promoted-table shape",
         %{schema: schema} do
      assert {:ok, query} = Compiler.compile(%{entity_type: "promoted_customer"}, schema, :all)
      assert [row] = Repo.all(query, prefix: schema)

      page = Pagination.page_response([row], "some-next-cursor")

      grant_user = create_user!(schema, "promoted-granted-user")
      insert_user_grant!(schema, grant_user.id, "promoted_customer", "ssn")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(grant_user.id, "promoted_customer", schema)

      redacted_page = FieldGrants.redact_page(page, restriction_set)

      [item] = redacted_page.items
      assert item.field_values["ssn"] == "123-45-6789"
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0651 -- Cursor.build_next_cursor/2 and read_sort_value/2 crashed
  # with FunctionClauseError on a promoted per-type-table row (a bare
  # Compiler.entity_row() map), since both previously only matched a
  # %Latest{} struct -- the same shape gap ISS-0600 already fixed for
  # FieldGrants.redact_item/2 above. This block proves keyset pagination
  # over MULTIPLE pages against a real promoted per-type table: distinct,
  # correctly-ordered, non-overlapping pages, and a correct "no more
  # pages" signal at the end -- not merely "does not crash".
  #
  # Sorts by "age" only, which resolves `source: :json_field` -- the
  # `read_sort_value/2` clause that previously had no bare-map fallback
  # and is this issue's actual crash site. NOT "customer_name" even
  # though this describe block's own setup promotes it: sorting by a
  # genuinely promoted (non-structural) `:typed_column` field is a
  # SEPARATE, pre-existing bug this test discovered while writing it --
  # `resolved_sort_term/2`'s `:typed_column` clause (cursor.ex ~line 209)
  # resolves the column atom via `Allowlist.typed_columns/0` (the fixed
  # structural-7 table only), which does not contain a promoted business
  # column name like "customer_name" and raises `KeyError`. That bug is
  # outside ISS-0651's own scope (which names only `build_next_cursor/2`
  # and `read_sort_value/2`) -- flagged separately below and left
  # unfixed here rather than silently folded into this change.
  #
  # For this same reason "age" cannot simply be declared alongside
  # "customer_name" from the start either: `DDL.promoted_columns/1`
  # promotes EVERY `queried: true` field of the definition active at
  # table-creation time in one shot, so a single-version definition with
  # both fields queried would give "age" a real physical column too,
  # making it resolve `:typed_column` and hit the very bug this test is
  # trying to route around. Instead this uses 0023's own
  # additive-declare-then-promote sequence (also `Allowlist.load/2`'s own
  # documented scenario): v1 declares only "customer_name" (queried) and
  # is promoted, creating the table with just that one physical column;
  # v2 then adds "age" (queried) WITHOUT ever registering/running a
  # column promotion for it, so it stays `source: :json_field`, backed by
  # the per-type table's own `field_values` jsonb catch-all column.
  # ---------------------------------------------------------------------------------

  describe "ISS-0651 -- keyset pagination against a promoted per-type-table entity type" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "promoted_pager",
        display_name: "Promoted Pager",
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true}
        ]
      })

      promote_and_create_table!(schema, tenant_id, "promoted_pager", "customer_name", "text")

      # v2: additive declare of "age", never promoted -- stays json_field.
      assert {:ok, _entity_definition} =
               Definitions.create_definition(
                 %{
                   definition: %{
                     name: "promoted_pager",
                     display_name: "Promoted Pager",
                     fields: [
                       %{name: "customer_name", type: :string, required: true, queried: true},
                       %{name: "age", type: :integer, queried: true}
                     ]
                   },
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:ok, %{status: :active}} =
               Definitions.activate_definition(
                 "promoted_pager",
                 Ecto.UUID.generate(),
                 "go-live-v2",
                 schema
               )

      %{schema: schema}
    end

    test "next_cursor round-trips through every page with no repeated or skipped records, promoted-table shape",
         %{schema: schema} do
      fixtures = [
        {"Eve", 1},
        {"Dave", 2},
        {"Carol", 3},
        {"Bob", 4},
        {"Alice", 5}
      ]

      for {name, age} <- fixtures do
        create_record_for!(schema, "promoted_pager", %{"customer_name" => name, "age" => age})
      end

      request = %{
        entity_type: "promoted_pager",
        sort: [%{field: "age", dir: :asc}]
      }

      assert {:ok, compiled_query} = Compiler.compile(request, schema, :all)
      assert {:ok, allowlist} = Allowlist.load("promoted_pager", schema)

      # Confirm the setup produced the shape this test needs: "age"
      # resolves :json_field (the read_sort_value/2 clause this fix
      # touches), not :typed_column.
      assert %{source: :json_field} = Map.fetch!(allowlist, "age")

      # Confirm this really is the promoted, bare-map entity_row() shape,
      # not %Latest{} -- otherwise this test would not exercise ISS-0651
      # at all.
      assert [%{field_values: _} = sample_row | _] = Repo.all(compiled_query, prefix: schema)
      refute match?(%Latest{}, sample_row)

      expected_order = [
        {"Eve", 1},
        {"Dave", 2},
        {"Carol", 3},
        {"Bob", 4},
        {"Alice", 5}
      ]

      opts1 = %{page_size: 2, cursor: nil}
      assert {:ok, page1} = Cursor.paginate(request, compiled_query, allowlist, opts1, schema)

      assert length(page1.items) == 2
      refute is_nil(page1.next_cursor)

      opts2 = %{page_size: 2, cursor: page1.next_cursor}
      assert {:ok, page2} = Cursor.paginate(request, compiled_query, allowlist, opts2, schema)

      assert length(page2.items) == 2
      refute is_nil(page2.next_cursor)

      opts3 = %{page_size: 2, cursor: page2.next_cursor}
      assert {:ok, page3} = Cursor.paginate(request, compiled_query, allowlist, opts3, schema)

      assert length(page3.items) == 1
      assert page3.next_cursor == nil

      pages = [page1, page2, page3]

      # Every item is the promoted entity_row() map shape, never %Latest{}.
      for page <- pages, item <- page.items do
        refute match?(%Latest{}, item)
        assert Map.has_key?(item, :record_id)
      end

      # Page 1 and page 2 (and 3) are distinct, non-overlapping records --
      # the acceptance bar this test exists to satisfy, not just
      # "does not crash".
      record_ids = Enum.flat_map(pages, fn page -> Enum.map(page.items, & &1.record_id) end)
      assert length(record_ids) == length(fixtures)
      assert length(Enum.uniq(record_ids)) == length(fixtures)

      actual_order =
        pages
        |> Enum.flat_map(& &1.items)
        |> Enum.map(fn item ->
          {Map.fetch!(item.field_values, "customer_name"), Map.fetch!(item.field_values, "age")}
        end)

      assert actual_order == expected_order
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0653 -- Cursor.resolved_sort_term/2's :typed_column clause resolved
  # a sort column atom via Allowlist.typed_columns/0 (the fixed
  # structural-7 table only), raising KeyError the moment a caller sorted
  # by a genuinely promoted business column (e.g. "customer_name" once
  # promoted, per this describe block's own fixture below) -- the third
  # function in this module with the same "not generalized for a promoted
  # per-type-table entity type" defect class ISS-0651/ISS-0652 already
  # found twice. read_sort_value/2's :typed_column clause had the identical
  # gap one step downstream (it would only ever be reached once
  # resolved_sort_term/2 stopped crashing first): the promoted column's own
  # value is never selected onto entity_row() by
  # Compiler.select_entity_row/1 (fixed structural-7 projection only), so
  # it is read back out of field_values instead -- the same underlying
  # data, since DDL.promoted_columns/1 emits every ordinary promoted column
  # as `GENERATED ALWAYS AS (...) STORED` computed FROM field_values.
  #
  # Unlike ISS-0651's own regression test (which had to sort by "age", a
  # :json_field, specifically to dodge this exact bug), this sorts by
  # "customer_name" -- promoted to a REAL physical `text` column by this
  # describe block's own setup -- so `Allowlist.load/2` resolves it
  # `source: :typed_column`, the precise shape that used to raise
  # KeyError. Proves correctness across THREE pages (not merely
  # "does not crash"): distinct, correctly-ordered, non-overlapping pages,
  # and a correct "no more pages" signal at the end.
  # ---------------------------------------------------------------------------------

  describe "ISS-0653 -- keyset pagination sorted by a promoted business column" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "promoted_sorter",
        display_name: "Promoted Sorter",
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true}
        ]
      })

      promote_and_create_table!(schema, tenant_id, "promoted_sorter", "customer_name", "text")

      %{schema: schema}
    end

    test "sorting by the promoted column's typed/generated-column form works correctly across at least two pages",
         %{schema: schema} do
      fixtures = ["Eve", "Dave", "Carol", "Bob", "Alice"]

      for name <- fixtures do
        create_record_for!(schema, "promoted_sorter", %{"customer_name" => name})
      end

      request = %{
        entity_type: "promoted_sorter",
        sort: [%{field: "customer_name", dir: :asc}]
      }

      assert {:ok, compiled_query} = Compiler.compile(request, schema, :all)
      assert {:ok, allowlist} = Allowlist.load("promoted_sorter", schema)

      # Confirm the setup produced the shape this test needs: "customer_name"
      # resolves :typed_column via its REAL, promoted physical column, not
      # :json_field -- otherwise this test would not exercise ISS-0653 at
      # all.
      assert %{source: :typed_column} = Map.fetch!(allowlist, "customer_name")

      assert [%{field_values: _} = sample_row | _] = Repo.all(compiled_query, prefix: schema)
      refute match?(%Latest{}, sample_row)

      expected_order = Enum.sort(fixtures)

      opts1 = %{page_size: 2, cursor: nil}

      assert {:ok, page1} =
               Cursor.paginate(request, compiled_query, allowlist, opts1, schema)

      assert length(page1.items) == 2
      refute is_nil(page1.next_cursor)

      opts2 = %{page_size: 2, cursor: page1.next_cursor}

      assert {:ok, page2} =
               Cursor.paginate(request, compiled_query, allowlist, opts2, schema)

      assert length(page2.items) == 2
      refute is_nil(page2.next_cursor)

      opts3 = %{page_size: 2, cursor: page2.next_cursor}

      assert {:ok, page3} =
               Cursor.paginate(request, compiled_query, allowlist, opts3, schema)

      assert length(page3.items) == 1
      assert page3.next_cursor == nil

      pages = [page1, page2, page3]

      for page <- pages, item <- page.items do
        refute match?(%Latest{}, item)
        assert Map.has_key?(item, :record_id)
      end

      # Distinct, non-overlapping records across all pages -- not just
      # "does not crash".
      record_ids = Enum.flat_map(pages, fn page -> Enum.map(page.items, & &1.record_id) end)
      assert length(record_ids) == length(fixtures)
      assert length(Enum.uniq(record_ids)) == length(fixtures)

      actual_order =
        pages
        |> Enum.flat_map(& &1.items)
        |> Enum.map(fn item -> Map.fetch!(item.field_values, "customer_name") end)

      assert actual_order == expected_order
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- no route or controller file added or modified by this
  # requirement. Structural check, RE-DERIVED 2026-09-11 because the
  # feature it was waiting for landed.
  #
  # As originally written this block asserted the NEGATIVE: that no file
  # under lib/letflow/routers/ mentions Query.Cursor or Query.FieldGrants
  # at all. That was never REQ-231's actual acceptance criterion. AC4 reads
  # "no route or controller file is added or modified, confirmed by
  # git diff --stat scoped to THIS REQUIREMENT'S COMMITS" -- a scope
  # constraint on one requirement's own diff, not a standing ban on ever
  # wiring the query subsystem up. REQ-231's description says the same
  # thing in prose ("NOT IN THIS REQUIREMENT: ... no route or controller --
  # same deferral as REQ-230"), and REQ-230 names the reason for the
  # deferral: the router row "remains deferred per the same 'no consumer
  # contract' reasoning REQ-225/REQ-226 already state." Deferred, not
  # forbidden. The tree-wide grep was a convenient point-in-time PROXY for
  # "the wiring hasn't happened yet," valid only for as long as that
  # remained true.
  #
  # It stopped being true with REQ-311. REQ-309/310/311 close what the S10
  # stage file called gap 1 -- a query subsystem nothing routed to --
  # and REQ-311's POST /entities/query handler composes exactly these
  # modules by design: lib/letflow/routers/entities.ex aliases Compiler,
  # Cursor and FieldGrants and its run_query/4 chains
  # Compiler.compile/2 -> Allowlist.load/2 -> Cursor.paginate/5 ->
  # FieldGrants redaction, the sequence specified in
  # lib/letflow/design/req308-entity-http-surface.md §1's route table.
  # Left as-is, the old assertion asserted the ABSENCE of a feature that
  # had just been correctly built.
  #
  # What survives re-derivation is the part of the original intent that is
  # still load-bearing and still falsifiable: these modules are query
  # INTERNALS with exactly ONE sanctioned consumer. A second router
  # reaching into Cursor/FieldGrants directly would be a real regression --
  # duplicated pagination and, worse, a second redaction path that INV-2
  # does not cover. So the assertion is inverted rather than deleted: the
  # set of routers referencing them must be exactly [entities.ex], and
  # that one must use them in the designed composition.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- query internals have exactly one router consumer" do
    setup do
      router_files =
        Path.wildcard(Path.join([File.cwd!(), "lib", "letflow", "routers", "**/*.ex"]))

      # Guard the guard: a broken wildcard would make every assertion below
      # vacuously true.
      assert length(router_files) > 1

      referencing =
        router_files
        |> Enum.filter(fn file ->
          contents = File.read!(file)
          contents =~ "Query.Cursor" or contents =~ "Query.FieldGrants"
        end)
        |> Enum.map(&Path.relative_to(&1, File.cwd!()))
        |> Enum.sort()

      %{router_files: router_files, referencing: referencing}
    end

    # GH #2833 moved the record write handlers into Routers.Entities.RecordWrites. Its only use of
    # Query.FieldGrants is the GH #2784 single-record redaction (`redact_field_values/2` in
    # render_record_command/4), not the query pipeline, so it may alias FieldGrants but never Cursor.
    test "Letflow.Routers.Entities is the ONLY router running the query pipeline (Query.Cursor/Query.FieldGrants)",
         %{referencing: referencing} do
      assert referencing == [
               "lib/letflow/routers/entities.ex",
               "lib/letflow/routers/entities/record_writes.ex"
             ]

      writes = File.read!("lib/letflow/routers/entities/record_writes.ex")
      refute writes =~ "Query.Cursor"
      assert writes =~ "FieldGrants.redact_field_values("
    end

    test "the one consumer composes them in the order design §1 specifies" do
      contents = File.read!(Path.join([File.cwd!(), "lib", "letflow", "routers", "entities.ex"]))

      assert contents =~ "alias Letflow.Entities.Query.Cursor"
      assert contents =~ "alias Letflow.Entities.Query.FieldGrants"

      # Compiler.compile/2 -> Cursor.paginate/5 -> a redaction step, in that
      # order, INSIDE run_query/4's with/1 chain.
      #
      # ⛔ Read the CHAIN, not the file. entities.ex documents itself
      # heavily and names `FieldGrants.redact_page/2` in its own @moduledoc
      # (~line 80) hundreds of lines ABOVE the call site -- a first-match
      # byte-offset comparison over the whole file measures prose order,
      # not composition order, and fails against correct code. (It did:
      # that was this test's own first draft.) Comment lines are stripped
      # for the same reason.
      chain = run_query_chain!(contents)

      access_at = index_of!(chain, "RequestAccess.check(")
      compile_at = index_of!(chain, "Compiler.compile(")
      allowlist_at = index_of!(chain, "Allowlist.load(")
      paginate_at = index_of!(chain, "Cursor.paginate(")
      redact_at = index_of!(chain, "redact(")

      # GH #2700: the type+field gate runs ahead of the compiler and of any SQL;
      # the steps are build, paginate-opts, RequestAccess.check, compile,
      # allowlist, paginate, redact.
      build_at = index_of!(chain, "build_query_request(")
      opts_at = index_of!(chain, "build_paginate_opts(")
      assert build_at < opts_at
      assert opts_at < access_at
      assert access_at < compile_at
      assert compile_at < allowlist_at
      assert allowlist_at < paginate_at
      refute chain =~ "TypeAccess.authorized?(", "the old per-primary TypeAccess step is gone"
      refute chain =~ "guard_row_request"
      assert compile_at < paginate_at
      assert paginate_at < redact_at
    end
  end

  # The code (comments stripped) of run_query/4's `with` chain, from the
  # `with` keyword to its `do`. Fails loudly rather than returning "" --
  # an absent or renamed chain must fail the ordering test, not satisfy it
  # vacuously.
  defp run_query_chain!(contents) do
    code =
      contents
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
      |> Enum.join("\n")

    case Regex.run(~r/defp run_query\(.*?\n\s*with (.*?) do\n/s, code, capture: :all_but_first) do
      [chain] ->
        chain

      nil ->
        flunk(
          "expected lib/letflow/routers/entities.ex to define run_query/4 with a with/1 chain"
        )
    end
  end

  # Byte offset of `needle` in `haystack`, failing loudly rather than
  # returning nil -- an absent call site must fail the ordering test, not
  # silently compare against nil.
  defp index_of!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _len} -> at
      :nomatch -> flunk("expected run_query/4's with chain to contain #{inspect(needle)}")
    end
  end
end
