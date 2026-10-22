defmodule Letflow.Entities.QueryJoinsTest do
  @moduledoc """
  Integration tests for REQ-300 -- joins in `Letflow.Entities.Query.Compiler`
  over promoted FK columns. See `lib/letflow/design/req300-query-joins.md`
  §10 for the test-coverage-to-AC mapping table this file's `describe`
  blocks implement.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked
  database. Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/query_test.exs`/
  `test/letflow/tenant_provisioning/constraint_fk_activation_test.exs`'s own
  hand-rolled tenant-fixture pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Compiler
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
        slug_prefix: "req300-query-joins",
        display_name: "REQ-300 Query Joins Test Tenant",
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

  defp create_active_definition!(schema, definition) do
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

  defp create_record!(schema, entity_type, field_values) do
    attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  # Promotes+runs one attribute for `entity_type`, creating (and, for the
  # very first promotion, backfilling) its per-entity-type table -- the
  # exact REQ-297 mechanism, mirrored from
  # constraint_fk_activation_test.exs's own identically-named helper.
  defp promote_and_create_table!(_schema, tenant_id, entity_type, attribute, pg_type, opts \\ []) do
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

  # Seeds a "question" + "answer_option" entity-type pair, both with real
  # per-type tables, "answer_option" carrying a real fk_def ("question_fk")
  # pointing back at "question" -- the design's own worked example.
  defp seed_question_and_answer_option!(schema, tenant_id) do
    create_active_definition!(schema, %{
      name: "question",
      display_name: "Question",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    promote_and_create_table!(schema, tenant_id, "question", "stem", "text")

    create_active_definition!(schema, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "text", type: :string, queried: true},
        %{name: "question_id", type: :string},
        %{name: "is_correct", type: :boolean, queried: false}
      ],
      foreign_keys: [
        %{name: "question_fk", field: "question_id", references_entity: "question"}
      ]
    })

    promote_and_create_table!(schema, tenant_id, "answer_option", "question_id", "uuid",
      references_entity: "question"
    )

    :ok
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- compiled-query-STRUCTURE test.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- compiled query structure contains a real join" do
    test "compile/2 produces an Ecto.Query.t() whose joins field is a real join/left_join" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_question_and_answer_option!(schema, tenant_id)

      request = %{
        entity_type: "question",
        join: [%{entity_type: "answer_option", fk: "question_fk"}]
      }

      assert {:ok, %Ecto.Query{joins: joins} = query} = Compiler.compile(request, schema, :all)
      assert [%Ecto.Query.JoinExpr{qual: :inner}] = joins

      # A :left join is honored too, structurally.
      left_request =
        put_in(request.join, [
          %{entity_type: "answer_option", fk: "question_fk", type: :left}
        ])

      assert {:ok, %Ecto.Query{joins: [%Ecto.Query.JoinExpr{qual: :left}]}} =
               Compiler.compile(left_request, schema, :all)

      # Sanity: compile/2 never executes the query it returns.
      assert %Ecto.Query{} = query
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- real fixture join, one matching + one non-matching related row.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- real fixture data, matching row returned, non-matching absent" do
    test "joined query returns the answer_option linked to the filtered question only" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_question_and_answer_option!(schema, tenant_id)

      q1 = create_record!(schema, "question", %{"stem" => "2 + 2 = ?"})
      q2 = create_record!(schema, "question", %{"stem" => "3 + 3 = ?"})

      _matching =
        create_record!(schema, "answer_option", %{
          "text" => "4",
          "question_id" => q1.record_id,
          "is_correct" => true
        })

      _non_matching =
        create_record!(schema, "answer_option", %{
          "text" => "6",
          "question_id" => q2.record_id,
          "is_correct" => true
        })

      # Filtered by "stem" (a JSONB/promoted string field), not "record_id"
      # -- Compiler's schemaless per-type-table bindings do not yet dump a
      # raw string value through Ecto.UUID before binding it as a
      # parameter against a genuinely uuid-typed physical column
      # (`record_id`); flagged in this requirement's own completion report
      # as a pre-existing, ACs-untested gap, not something this test needs
      # to exercise.
      request = %{
        entity_type: "question",
        filters: [%{field: "stem", op: :eq, value: "2 + 2 = ?"}],
        join: [%{entity_type: "answer_option", fk: "question_fk"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      assert [row] = Repo.all(query, prefix: schema)
      assert row.primary.field_values["stem"] == "2 + 2 = ?"
      assert row["answer_option"].field_values["text"] == "4"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- many-to-many via `through`, queried as a relation through the
  # join entity.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- many-to-many through a join entity" do
    test "a question's tags are read through question_tags, unrelated tag excluded" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question_m2m",
        display_name: "Question M2M",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "question_m2m", "stem", "text")

      create_active_definition!(schema, %{
        name: "tag_m2m",
        display_name: "Tag M2M",
        fields: [%{name: "label", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "tag_m2m", "label", "text")

      create_active_definition!(schema, %{
        name: "question_tags_m2m",
        display_name: "Question Tags M2M",
        fields: [
          %{name: "question_id", type: :string},
          %{name: "tag_id", type: :string}
        ],
        foreign_keys: [
          %{name: "fk_question", field: "question_id", references_entity: "question_m2m"},
          %{name: "fk_tag", field: "tag_id", references_entity: "tag_m2m"}
        ]
      })

      promote_and_create_table!(schema, tenant_id, "question_tags_m2m", "question_id", "uuid",
        references_entity: "question_m2m"
      )

      promote_and_create_table!(schema, tenant_id, "question_tags_m2m", "tag_id", "uuid",
        references_entity: "tag_m2m"
      )

      q1 = create_record!(schema, "question_m2m", %{"stem" => "linked question"})
      q2 = create_record!(schema, "question_m2m", %{"stem" => "unrelated question"})

      t1 = create_record!(schema, "tag_m2m", %{"label" => "math"})
      t2 = create_record!(schema, "tag_m2m", %{"label" => "unrelated"})

      _linked =
        create_record!(schema, "question_tags_m2m", %{
          "question_id" => q1.record_id,
          "tag_id" => t1.record_id
        })

      _unrelated =
        create_record!(schema, "question_tags_m2m", %{
          "question_id" => q2.record_id,
          "tag_id" => t2.record_id
        })

      # Filtered by "stem" (a JSONB/promoted string field), not "record_id"
      # -- see the AC2 test's own comment for why.
      request = %{
        entity_type: "question_m2m",
        filters: [%{field: "stem", op: :eq, value: "linked question"}],
        join: [%{entity_type: "tag_m2m", through: "question_tags_m2m", fk: "fk_tag"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      # A per-type-table-sourced select casts `record_id` back to a real
      # string via `type/2` in `Compiler`'s select (ISS-0652) -- the row's
      # own `field_values` (always the read-side payload, promoted or not,
      # design §0) is unaffected by this either way.
      assert [row] = Repo.all(query, prefix: schema)
      assert row.primary.field_values["stem"] == "linked question"
      assert row["tag_m2m"].record_id == t1.record_id
      assert row["tag_m2m"].field_values["label"] == "math"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- maximum join depth/width enforced.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- join depth/width bounds" do
    test "a join list wider than 4 is rejected, naming the caller's own count" do
      %{schema_name: schema} = provisioned_tenant()

      joins =
        for i <- 1..5 do
          %{entity_type: "target_#{i}", fk: "fk_#{i}"}
        end

      request = %{entity_type: "question", join: joins}

      assert Compiler.compile(request, schema, :all) == {:error, {:too_many_joins, 5}}
    end

    test "a join_clause carrying its own nested :join key is rejected" do
      %{schema_name: schema} = provisioned_tenant()

      request = %{
        entity_type: "question",
        join: [%{entity_type: "answer_option", fk: "question_fk", join: []}]
      }

      assert Compiler.compile(request, schema, :all) == {:error, :join_depth_exceeded}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- FieldGrants composition: a joined (non-primary) entity's own
  # restriction set governs its own fields.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- FieldGrants composition with a joined read" do
    test "a restricted field on the joined entity stays redacted for a non-grant viewer, visible for a grant-holder" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_question_and_answer_option!(schema, tenant_id)

      q1 = create_record!(schema, "question", %{"stem" => "2 + 2 = ?"})

      create_record!(schema, "answer_option", %{
        "text" => "4",
        "question_id" => q1.record_id,
        "is_correct" => true
      })

      insert_field_restriction!(schema, "answer_option", "is_correct")

      no_grant_user = create_user!(schema, "no-grant-req300")
      grant_user = create_user!(schema, "granted-req300")
      insert_user_grant!(schema, grant_user.id, "answer_option", "is_correct")

      # Filtered by "stem" (a JSONB/promoted string field), not "record_id"
      # -- see the AC2 test's own comment for why.
      request = %{
        entity_type: "question",
        filters: [%{field: "stem", op: :eq, value: "2 + 2 = ?"}],
        join: [%{entity_type: "answer_option", fk: "question_fk"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)
      items = Repo.all(query, prefix: schema)
      page = Letflow.Api.Pagination.page_response(items, nil)

      assert {:ok, primary_set} =
               FieldGrants.load_restrictions(no_grant_user.id, "question", schema)

      assert {:ok, no_grant_set} =
               FieldGrants.load_restrictions(no_grant_user.id, "answer_option", schema)

      assert {:ok, grant_set} =
               FieldGrants.load_restrictions(grant_user.id, "answer_option", schema)

      no_grant_redacted =
        FieldGrants.redact_joined_page(page, %{
          "answer_option" => no_grant_set,
          primary: primary_set
        })

      grant_redacted =
        FieldGrants.redact_joined_page(page, %{"answer_option" => grant_set, primary: primary_set})

      assert [no_grant_row] = no_grant_redacted.items
      assert [grant_row] = grant_redacted.items

      assert no_grant_row["answer_option"].field_values["is_correct"] ==
               FieldGrants.redacted_sentinel()

      assert grant_row["answer_option"].field_values["is_correct"] == true

      # The primary entity's own fields are unaffected either way.
      assert no_grant_row.primary.field_values["stem"] == "2 + 2 = ?"
      assert grant_row.primary.field_values["stem"] == "2 + 2 = ?"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- a join naming a field that is not an fk_def relationship.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- non-fk_def join rejection" do
    test "a join naming an unknown relation is rejected the same way an unallowlisted field is" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      seed_question_and_answer_option!(schema, tenant_id)

      request = %{
        entity_type: "question",
        join: [%{entity_type: "answer_option", fk: "not_a_relation"}]
      }

      assert Compiler.compile(request, schema, :all) ==
               {:error, {:field_not_allowed, "not_a_relation"}}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- Allowlist.load/2 resolves a genuinely-promoted field as
  # :typed_column, real end-to-end pipeline, literal/1-fragment path.
  # ---------------------------------------------------------------------------------

  describe "AC8 -- load/2 repointed at typed_columns/2, real Compiler pipeline" do
    test "a promoted, non-FK field filters via the literal-fragment path once its table exists" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "sku", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "widget", "sku", "text")

      create_record!(schema, "widget", %{"sku" => "ABC-1"})
      create_record!(schema, "widget", %{"sku" => "ZZZ-9"})

      request = %{entity_type: "widget", filters: [%{field: "sku", op: :eq, value: "ABC-1"}]}
      assert {:ok, query} = Compiler.compile(request, schema, :all)

      # Not the ordinary JSONB-extraction fragment ("?->>?") -- the
      # promoted-column literal/1-fragment path instead.
      rendered = inspect(query.wheres)
      refute rendered =~ "->>"
      assert rendered =~ "identifier"

      assert [%{field_values: %{"sku" => "ABC-1"}}] = Repo.all(query, prefix: schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # Regression (rework cycle 1) -- a plain, non-join request against an
  # entity type with no per-type table is completely unchanged.
  # ---------------------------------------------------------------------------------

  describe "regression (rework cycle 1) -- plain query, no per-type table, unaffected" do
    test "a never-promoted entity type's plain filter/sort request compiles to the exact Latest-backed shape" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "customer_req300",
        display_name: "Customer REQ-300",
        fields: [%{name: "customer_name", type: :string, required: true, queried: true}]
      })

      create_record!(schema, "customer_req300", %{"customer_name" => "Acme"})

      request = %{
        entity_type: "customer_req300",
        filters: [%{field: "customer_name", op: :eq, value: "Acme"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)

      assert %Ecto.Query{from: %{source: {"entity_record_latest", Latest}}, joins: []} = query
      assert query.wheres != []

      assert [%Latest{field_values: %{"customer_name" => "Acme"}}] =
               Repo.all(query, prefix: schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # Regression (rework cycle 2) -- table exists, but the declared fk_def's
  # column has not been promoted onto it yet.
  # ---------------------------------------------------------------------------------

  describe "regression (rework cycle 2) -- declared-but-unpromoted relation column" do
    test "a join naming a not-yet-promoted fk column is caught before compiled SQL; the same entity type's plain query on its existing column still works" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "answer_option_rc2",
        display_name: "Answer Option RC2",
        fields: [%{name: "text", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "answer_option_rc2", "text", "text")

      create_active_definition!(schema, %{
        name: "question_rc2",
        display_name: "Question RC2",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      # Additive update: the active definition for "answer_option_rc2" now
      # also declares an fk_def -- but "question_id" has NOT been through
      # register_column_promotion/run_column_promotion, so it never lands
      # on the already-existing per-type table.
      create_active_definition!(schema, %{
        name: "answer_option_rc2",
        display_name: "Answer Option RC2",
        fields: [
          %{name: "text", type: :string, queried: true},
          %{name: "question_id", type: :string}
        ],
        foreign_keys: [
          %{name: "question_fk", field: "question_id", references_entity: "question_rc2"}
        ]
      })

      join_request = %{
        entity_type: "question_rc2",
        join: [%{entity_type: "answer_option_rc2", fk: "question_fk"}]
      }

      assert Compiler.compile(join_request, schema, :all) ==
               {:error, {:relation_column_not_found, "answer_option_rc2", "question_id"}}

      plain_request = %{
        entity_type: "answer_option_rc2",
        filters: [%{field: "text", op: :eq, value: "existing"}]
      }

      assert {:ok, _query} = Compiler.compile(plain_request, schema, :all)
    end
  end

  # ---------------------------------------------------------------------------------
  # Regression (rework cycle 3, SECURITY-REVIEWER-reported) -- the same
  # table-vs-column existence gap rework cycle 2 closed for the join path
  # was still open for the ordinary, non-join filter/sort path: a second,
  # never-promoted field declared on an entity type that already has a
  # per-type table (from a *different* field's promotion) used to be
  # misclassified `source: :typed_column` and crash with an unhandled
  # Postgrex.Error at execution time, instead of falling back to the
  # always-safe `:json_field`/JSONB path it used before any promotion.
  # ---------------------------------------------------------------------------------

  describe "regression (rework cycle 3) -- declared-but-unpromoted field, ordinary non-join filter/sort" do
    test "a plain filter on a not-yet-promoted field falls back to :json_field instead of raising; the promoted field still uses the typed-column path" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "widget_gap",
        display_name: "Widget Gap",
        fields: [%{name: "sku", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "widget_gap", "sku", "text")

      # Additive update: "widget_gap" now also declares "batch_code" as
      # queried: true -- but it has NOT been through
      # register_column_promotion/run_column_promotion, so it never lands
      # as a real column on the already-existing per-type table.
      create_active_definition!(schema, %{
        name: "widget_gap",
        display_name: "Widget Gap",
        fields: [
          %{name: "sku", type: :string, queried: true},
          %{name: "batch_code", type: :string, queried: true}
        ]
      })

      create_record!(schema, "widget_gap", %{"sku" => "SKU-1", "batch_code" => "whatever"})

      batch_code_request = %{
        entity_type: "widget_gap",
        filters: [%{field: "batch_code", op: :eq, value: "whatever"}]
      }

      assert {:ok, batch_code_query} = Compiler.compile(batch_code_request, schema, :all)

      # :json_field fallback -- the ordinary JSONB-extraction fragment
      # ("?->>?"), never the promoted-column literal/1-fragment path, and
      # never a table lacking this column.
      assert inspect(batch_code_query.wheres) =~ "->>"

      assert [%{field_values: %{"batch_code" => "whatever"}}] =
               Repo.all(batch_code_query, prefix: schema)

      sku_request = %{
        entity_type: "widget_gap",
        filters: [%{field: "sku", op: :eq, value: "SKU-1"}]
      }

      assert {:ok, sku_query} = Compiler.compile(sku_request, schema, :all)
      refute inspect(sku_query.wheres) =~ "->>"
      assert inspect(sku_query.wheres) =~ "identifier"

      assert [%{field_values: %{"sku" => "SKU-1"}}] = Repo.all(sku_query, prefix: schema)
    end

    test "a plain sort on a not-yet-promoted field falls back to :json_field instead of raising" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "widget_gap_sort",
        display_name: "Widget Gap Sort",
        fields: [%{name: "sku", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "widget_gap_sort", "sku", "text")

      create_active_definition!(schema, %{
        name: "widget_gap_sort",
        display_name: "Widget Gap Sort",
        fields: [
          %{name: "sku", type: :string, queried: true},
          %{name: "batch_code", type: :string, queried: true}
        ]
      })

      create_record!(schema, "widget_gap_sort", %{"sku" => "SKU-1", "batch_code" => "b"})

      sort_request = %{
        entity_type: "widget_gap_sort",
        sort: [%{field: "batch_code", dir: :asc}]
      }

      assert {:ok, query} = Compiler.compile(sort_request, schema, :all)
      assert [%{field_values: %{"batch_code" => "b"}}] = Repo.all(query, prefix: schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0652 -- `select_entity_row/1` (the PLAIN, non-join per-type-table
  # compile path) must return `record_id` as a real `String.t()`, exactly
  # as `entity_row()`'s own `@type` promises, not the raw 16-byte binary a
  # schemaless `from(table_name)` select would otherwise hand back
  # unloaded. Two independent call sites (`entities.ex`'s
  # `normalise_record_id/1`) had already copy-pasted a local decode
  # workaround around this defect instead of it being fixed at the source
  # -- this proves the source itself is now fixed, so no caller needs to
  # decode anything.
  # ---------------------------------------------------------------------------------

  describe "ISS-0652 regression -- select_entity_row/1 casts record_id to a string" do
    test "a plain (non-join) query against a promoted per-type table returns record_id as a real String.t()" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question",
        display_name: "Question",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "question", "stem", "text")

      question = create_record!(schema, "question", %{"stem" => "2 + 2 = ?"})

      request = %{
        entity_type: "question",
        filters: [%{field: "stem", op: :eq, value: "2 + 2 = ?"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)
      assert [row] = Repo.all(query, prefix: schema)

      # The defect this regression guards: a raw, un-cast uuid column comes
      # back from Postgrex as a 16-byte binary, not a 36-character string --
      # asserting both the type AND the exact value closes that gap.
      assert is_binary(row.record_id)
      assert byte_size(row.record_id) == 36
      assert row.record_id == question.record_id
      assert row.field_values["stem"] == "2 + 2 = ?"
    end
  end
end
