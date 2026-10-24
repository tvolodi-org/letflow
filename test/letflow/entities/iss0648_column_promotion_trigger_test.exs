defmodule Letflow.Entities.ISS0648ColumnPromotionTriggerTest do
  @moduledoc """
  Regression coverage for ISS-0648 (`docs/issues/ISS-0648.yaml`, BLOCKER):
  pack-installed (and hand-authored) entity types' declared unique
  constraints compiled correctly into DDL (REQ-298), but nothing ever ran
  that DDL for a normally-activated entity type -- so the constraint the
  definition document declared was never actually enforced. See
  `lib/letflow/design/iss0648-pack-install-column-promotion-trigger.md` for
  the fix design this file proves against its own "Acceptance criteria for
  the following ELIXIR-DEV implementation turn" list (11 items).

  Uses `Letflow.DataCase` (real Postgres), `async: false` -- every test
  provisions at least one real tenant schema and activates a real entity
  definition, triggering real DDL. Self-contained: provisions its own
  tenant schema(s), mirroring
  `test/letflow/tenant_provisioning/column_promotion_test.exs`'s and
  `test/letflow/tenant_provisioning/constraint_fk_activation_test.exs`'s own
  hand-rolled tenant-fixture pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Records
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
        slug_prefix: "iss0648-column-promotion-trigger",
        display_name: "ISS-0648 Column Promotion Trigger Test Tenant",
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

  # GH #2581 / GH #2680 slice 3: `tag`, `question` and the other exam names are reserved on a tenant
  # without the exam module, so the first version is planted (the same bypass as the exam fixtures),
  # then activated by the caller.
  defp create_definition!(schema, definition) do
    Letflow.ManagedTypesSupport.plant_legacy_definition!(schema, definition)
  end

  defp activate!(schema, name) do
    Definitions.activate_definition(name, Ecto.UUID.generate(), "go-live", schema)
  end

  defp create_active_definition!(schema, definition) do
    create_definition!(schema, definition)
    assert {:ok, activated} = activate!(schema, Map.fetch!(definition, :name))
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

  defp column_promotion_row(tenant_id, entity_type, attribute) do
    Repo.get_by(ColumnPromotion,
      tenant_id: tenant_id,
      entity_type: entity_type,
      attribute: attribute
    )
  end

  # Real "tag" entity definition -- verbatim shape of
  # priv/packs/bilimbaga/entity_definitions/tag.json (AC2's own literal ask).
  defp tag_definition(overrides \\ %{}) do
    Map.merge(
      %{
        name: "tag",
        display_name: "Tag",
        fields: [%{name: "name", type: :string, queried: true, required: true}],
        constraints: [%{name: "uq_tag_name", type: :unique, fields: ["name"]}]
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- real "tag" entity definition, real entity_tag table with a real
  # UNIQUE constraint, ISS-0648's own empirical repro re-run and now
  # expected to fail correctly.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- the real tag entity definition, ISS-0648's own empirical repro" do
    test "activation creates entity_tag with a real UNIQUE(name); the second duplicate create_record/2 call errors" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, tag_definition())

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("tag")
      assert TenantProvisioning.entity_table_exists?(schema, table_name)

      assert %ColumnPromotion{status: "ddl_applied"} =
               column_promotion_row(tenant_id, "tag", "name")

      # ISS-0648's own empirical proof, re-run: two create_record/2 calls
      # with identical field_values. Before this fix both returned
      # {:ok, ...} with is_duplicate: false and distinct record_ids -- now
      # the second must error.
      first = create_record!(schema, "tag", %{"name" => "duplicate-test"})
      assert first.field_values["name"] == "duplicate-test"

      # REVIEWER finding (re-verifying REQ-336 AC4): the second duplicate
      # write must surface as the SAME {:record_payload_invalid, violations}
      # shape the inner field-validation check already produces -- never a
      # raw %Postgrex.Error{} / bare {:error, reason} that would only ever
      # map to a 500 at the router. See
      # lib/letflow/entities/records.ex's `unique_violation_from_constraint/2`.
      assert {:error, {:record_payload_invalid, [violation]}} =
               Records.create_record(
                 %{
                   entity_type: "tag",
                   field_values: %{"name" => "duplicate-test"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert %Letflow.Entities.Definition.Validator.Violation{
               rule: :unique,
               path: ["name"],
               message: "name has already been taken"
             } = violation
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- a many-to-many join-shaped entity type (composite UNIQUE over two
  # promoted attributes), duplicate-pair rejection actually reachable
  # through activation. Mirrors question_tag/exam_question_rule_tag's
  # promoted-columns-plus-composite-constraint shape (design doc §4) without
  # requiring their `fk_def` target tables (question/exam_question_rule/tag)
  # to be separately provisioned first -- the composite UNIQUE enforcement
  # this criterion is about does not depend on the pair also being FKs.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- a many-to-many join entity type, composite-key duplicate-pair rejection" do
    test "activation creates the join table with a real composite UNIQUE; the second duplicate pair errors" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "question_tag",
        display_name: "Question Tag",
        fields: [
          %{name: "question_id", type: :string, queried: true, required: true},
          %{name: "tag_id", type: :string, queried: true, required: true}
        ],
        constraints: [
          %{
            name: "uq_question_tag_question_id_tag_id",
            type: :unique,
            fields: ["question_id", "tag_id"]
          }
        ]
      })

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("question_tag")
      assert TenantProvisioning.entity_table_exists?(schema, table_name)

      question_id = Ecto.UUID.generate()
      tag_id = Ecto.UUID.generate()

      create_record!(schema, "question_tag", %{"question_id" => question_id, "tag_id" => tag_id})

      # Composite constraint (REQ-336/REQ-340 scope) -- the same
      # `{:record_payload_invalid, violations}` translation must generalize
      # to a multi-column `path`, not just the single-column `tag` case
      # above.
      assert {:error, {:record_payload_invalid, [violation]}} =
               Records.create_record(
                 %{
                   entity_type: "question_tag",
                   field_values: %{"question_id" => question_id, "tag_id" => tag_id},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert %Letflow.Entities.Definition.Validator.Violation{
               rule: :unique,
               path: ["question_id", "tag_id"]
             } = violation

      # A DIFFERENT pair must still be accepted -- only the exact duplicate
      # pair is rejected.
      create_record!(schema, "question_tag", %{
        "question_id" => question_id,
        "tag_id" => Ecto.UUID.generate()
      })
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- only constrained attributes are registered; a queried:true field
  # with no constraint gets no ColumnPromotion row.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- only constraint_def.fields attributes are registered for promotion" do
    test "a queried:true field with no constraint gets no ColumnPromotion row" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "tag_with_extra",
        display_name: "Tag With Extra",
        fields: [
          %{name: "name", type: :string, queried: true, required: true},
          %{name: "notes", type: :string, queried: true}
        ],
        constraints: [%{name: "uq_tag_with_extra_name", type: :unique, fields: ["name"]}]
      })

      assert %ColumnPromotion{} = column_promotion_row(tenant_id, "tag_with_extra", "name")
      refute column_promotion_row(tenant_id, "tag_with_extra", "notes")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- promotions registered by this fix are driven through
  # run_column_promotion/1 only, landing at "ddl_applied", never
  # "backfilled"/"active".
  # ---------------------------------------------------------------------------------

  describe "AC5 -- promotions this fix registers stop at ddl_applied" do
    test "the ColumnPromotion row's status is ddl_applied after activation, never backfilled/active" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, tag_definition())

      assert %ColumnPromotion{status: "ddl_applied"} =
               column_promotion_row(tenant_id, "tag", "name")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- idempotency: re-activating the same entity type does not raise,
  # does not error, and does not double-register.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- re-activation is idempotent" do
    test "activating the same entity type twice does not raise/error and leaves exactly one ColumnPromotion row" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, tag_definition())

      # Re-activate the SAME already-active version -- activate_definition/4
      # itself must still return {:ok, _}, not raise.
      assert {:ok, _reactivated} = activate!(schema, "tag")

      rows =
        Repo.all(
          from(cp in ColumnPromotion,
            where:
              cp.tenant_id == ^tenant_id and cp.entity_type == "tag" and cp.attribute == "name"
          )
        )

      assert length(rows) == 1
      assert %ColumnPromotion{status: "ddl_applied"} = hd(rows)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1/AC7/AC8 -- pre-existing dirty data: the Projector.rebuild_projection/2
  # raise is rescued into {:error, {:ddl_failed, exception}} -- never a raised
  # exception escaping run_column_promotion/1 (AC7's own literal wording) --
  # and activate_definition/4 itself still returns {:ok, _}, loudly logged
  # (AC1/AC8), exercising ensure_column_promotions/2's own internals
  # genuinely failing, not a mock.
  #
  # EMPIRICAL FINDING, flagged for REVIEWER (found while writing this test,
  # not asserted by the design doc's own §6 narrative): the ColumnPromotion
  # row does NOT reach status "ddl_failed" for THIS failure mode -- it stays
  # "pending", last_error nil. Root cause, confirmed via SQL trace: a real
  # raised Postgrex unique-violation from inside
  # Projector.rebuild_projection/2's own NESTED Repo.transaction/1 leaves the
  # underlying Postgres transaction genuinely aborted (Ecto does not open a
  # SAVEPOINT for an ordinary nested Repo.transaction/1 call outside sandbox
  # :manual mode -- confirmed empirically, no SAVEPOINT statement is ever
  # issued), so `create_and_populate_entity_table/3`'s own rescue (this
  # fix's companion change) catches the exception on an ALREADY-ABORTED
  # connection. `do_run_column_promotion/2`'s `else` branch then calls
  # `mark_ddl_failed_and_return/3`, whose own UPDATE also fails (still the
  # aborted connection) and hits ITS OWN pre-existing rescue clause
  # (tenant_provisioning.ex, documented inline as an "ISS-0623 finding,
  # flagged for REVIEWER" -- a structural gap that already predates this
  # fix, reachable by ANY {:ddl_failed, exception} path whose exception is a
  # genuine raised Postgres error) -- which calls Repo.rollback/1, discarding
  # the "ddl_failed" write and leaving the row exactly as
  # register_column_promotion/4 first inserted it ("pending"). This is NOT a
  # defect introduced by this fix's own companion rescue (that rescue does
  # its job correctly -- no exception escapes run_column_promotion/1, which
  # still correctly returns {:error, {:ddl_failed, exception}}); it is an
  # ALREADY-DOCUMENTED, pre-existing limitation of the shared
  # mark_ddl_failed_and_return/3 helper that ISS-0648's own design doc (§6)
  # did not ask this fix to also close, and closing it here would be
  # undocumented scope expansion into a separately-flagged, higher-risk
  # shared helper. Asserted against below as the actual (not the design
  # doc's assumed) persisted outcome; see this test file's completion report
  # for the same finding surfaced to REVIEWER.
  # ---------------------------------------------------------------------------------

  describe "AC1/AC7/AC8 -- pre-existing duplicate data degrades activation gracefully, loudly" do
    test "backfilling real pre-existing duplicates never raises out of activation; run_column_promotion/1 returns {:error, {:ddl_failed, _}}, logged" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      # Create the entity type INACTIVE first (no trigger runs pre-activation),
      # then write two duplicate records against it BEFORE any constraint
      # exists -- exactly ISS-0648's own "tenant already has real duplicate
      # records" scenario (design doc §6). Records.create_record/2 only ever
      # resolves the ACTIVE definition, so activate once with no constraint,
      # write the duplicates, then activate a second version that adds the
      # constraint -- this is the realistic path: the constraint is added
      # to an already-populated entity type.
      create_active_definition!(schema, %{
        name: "tag",
        display_name: "Tag",
        fields: [%{name: "name", type: :string, queried: true, required: true}]
      })

      create_record!(schema, "tag", %{"name" => "dup"})
      create_record!(schema, "tag", %{"name" => "dup"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          create_definition!(schema, tag_definition())
          assert {:ok, %{status: :active}} = activate!(schema, "tag")
        end)

      assert log =~ "ensure_column_promotions/2"
      assert log =~ "ddl_failed"

      # See this describe block's own comment above: the row lands back at
      # "pending" (register_column_promotion/4's own initial status),
      # last_error nil -- a pre-existing, separately-flagged
      # mark_ddl_failed_and_return/3 limitation, not a regression from this
      # fix's own companion rescue.
      assert %ColumnPromotion{status: "pending", last_error: nil} =
               column_promotion_row(tenant_id, "tag", "name")

      # Direct re-invocation of run_column_promotion/1 against the same
      # (still-dirty) row reproduces the same {:error, {:ddl_failed, _}}
      # shape -- AC7's own literal wording ("run_column_promotion/1 ...
      # returns {:error, {:ddl_failed, _}} ... not a raised exception
      # escaping the test") -- proving the exception genuinely never
      # escapes, independent of the persisted-status finding above.
      row = column_promotion_row(tenant_id, "tag", "name")
      assert {:error, {:ddl_failed, _exception}} = TenantProvisioning.run_column_promotion(row.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- single-tenant scoping: register_column_promotion/4 is called with
  # tenant_ids: [tenant_id] for the ONE activating tenant only, never :all.
  # Proven as a real, observable effect (not code inspection): activating
  # the same constrained entity type in TWO independently-provisioned
  # tenants must leave tenant A's activation with zero effect on tenant B --
  # no ColumnPromotion row, no entity table, no enforcement -- until tenant
  # B independently activates its own copy.
  # ---------------------------------------------------------------------------------

  describe "AC9 -- single-tenant scoping, never tenant_ids: :all" do
    test "activating tag in tenant A registers/promotes only for tenant A, not tenant B" do
      %{tenant_id: tenant_a_id, schema_name: schema_a} = provisioned_tenant()
      %{tenant_id: tenant_b_id, schema_name: schema_b} = provisioned_tenant()

      create_active_definition!(schema_a, tag_definition())

      # Tenant A: real ColumnPromotion row, real table, ddl_applied.
      assert %ColumnPromotion{status: "ddl_applied"} =
               column_promotion_row(tenant_a_id, "tag", "name")

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("tag")
      assert TenantProvisioning.entity_table_exists?(schema_a, table_name)

      # Tenant B never activated "tag" -- no cross-tenant fan-out. If
      # register_column_promotion/4 were ever called with tenant_ids: :all,
      # this row would exist for tenant B too.
      refute column_promotion_row(tenant_b_id, "tag", "name")
      refute TenantProvisioning.entity_table_exists?(schema_b, table_name)

      # Tenant B's own "tag" entity definition does not even exist yet --
      # activation is per-tenant metadata too, confirming the isolation is
      # not merely "no promotion row" but "no effect of any kind."
      assert {:error, :not_found} = Definitions.get_definition_by_name("tag", schema_b)

      # Now tenant B activates its own "tag" independently -- this must
      # succeed on its own, proving isolation runs both ways (A's prior
      # activation neither blocked nor pre-registered anything for B).
      create_active_definition!(schema_b, tag_definition())

      assert %ColumnPromotion{status: "ddl_applied"} =
               column_promotion_row(tenant_b_id, "tag", "name")

      assert TenantProvisioning.entity_table_exists?(schema_b, table_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC11 -- blast radius: every one of the design doc's own 9 entity types
  # (§4 table) gets real ColumnPromotion coverage, not just tag/question_tag
  # (covered above) and session_question (covered separately in
  # test/letflow/exam/session_test.exs's AC12 block). This covers the
  # remaining 6: exam_manual_question, exam_question_rule,
  # exam_question_rule_tag, exam_section, session_answer,
  # session_question_score -- each a composite two-field UNIQUE, exercised
  # with plain (non-fk_def) fields matching the AC3 join-entity precedent
  # above, so no FK-target table needs separate provisioning first (the
  # composite UNIQUE enforcement under test does not depend on the fields
  # also being FKs).
  # ---------------------------------------------------------------------------------

  describe "AC11 -- blast radius: the remaining 6 entity types from the design's §4 table" do
    for {entity_type, constraint_name, [field_a, field_b]} <- [
          {"exam_manual_question", "uq_exam_manual_question_rule_id_question_id",
           ["rule_id", "question_id"]},
          {"exam_question_rule", "uq_exam_question_rule_exam_id_sort_order",
           ["exam_id", "sort_order"]},
          {"exam_question_rule_tag", "uq_exam_question_rule_tag_rule_id_tag_id",
           ["rule_id", "tag_id"]},
          {"exam_section", "uq_exam_section_exam_id_sort_order", ["exam_id", "sort_order"]},
          {"session_answer", "uq_session_answer_session_id_question_id",
           ["session_id", "question_id"]},
          {"session_question_score", "uq_session_question_score_session_id_question_id",
           ["session_id", "question_id"]}
        ] do
      test "#{entity_type}: activation promotes both #{Enum.join([field_a, field_b], "/")} columns to ddl_applied and rejects a duplicate pair" do
        entity_type = unquote(entity_type)
        constraint_name = unquote(constraint_name)
        field_a = unquote(field_a)
        field_b = unquote(field_b)

        %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

        # Some of these names are reserved by the exam module (GH #2581), so the
        # tenant create path refuses them; plant the type as a pre-existing
        # definition -- this test is about activation's column promotion.
        definition = %{
          name: entity_type,
          display_name: entity_type,
          fields: [
            %{name: field_a, type: :string, queried: true, required: true},
            %{name: field_b, type: :string, queried: true, required: true}
          ],
          constraints: [
            %{name: constraint_name, type: :unique, fields: [field_a, field_b]}
          ]
        }

        Letflow.ManagedTypesSupport.plant_legacy_definition!(schema, definition)
        assert {:ok, _activated} = activate!(schema, entity_type)

        assert %ColumnPromotion{status: "ddl_applied"} =
                 column_promotion_row(tenant_id, entity_type, field_a)

        assert %ColumnPromotion{status: "ddl_applied"} =
                 column_promotion_row(tenant_id, entity_type, field_b)

        assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type(entity_type)
        assert TenantProvisioning.entity_table_exists?(schema, table_name)

        value_a = Ecto.UUID.generate()
        value_b = Ecto.UUID.generate()

        create_record!(schema, entity_type, %{field_a => value_a, field_b => value_b})

        assert {:error, _reason} =
                 Records.create_record(
                   %{
                     entity_type: entity_type,
                     field_values: %{field_a => value_a, field_b => value_b},
                     actor_id: Ecto.UUID.generate(),
                     idempotency_key: Ecto.UUID.generate()
                   },
                   schema
                 )
      end
    end
  end
end
