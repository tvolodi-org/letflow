defmodule Letflow.TenantProvisioning.ColumnPromotionTest do
  @moduledoc """
  Integration tests for REQ-297's promotion executor -- the nine
  `Letflow.TenantProvisioning` functions REQ-295 specified
  (`register_column_promotion/4`, `run_column_promotion/1`,
  `run_column_promotion_for_all_tenants/1`, `retry_failed_column_promotion/1`,
  `backfill_column_promotion/1`, `activate_column_promotion/1`,
  `suspend_column_promotion/2`, `column_promotion_query_eligible?/3`,
  `column_promotion_dual_write?/3`), plus the table-lifecycle and dual-write
  wiring this requirement adds. See
  `lib/letflow/design/req297-entity-promotion-executor.md` §12 for the
  test-coverage plan each `describe` block below maps to.

  Uses `Letflow.DataCase` (real Postgres), `async: false` -- every test
  provisions at least one real tenant schema and runs real DDL against it.
  Self-contained: provisions its own tenant schema(s) and tears them down
  via `on_exit/1`, mirroring `test/letflow/entities/records_test.exs`'s own
  hand-rolled tenant-fixture pattern.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file wraps provisioning in
  # SandboxAutoMode.provision!/2 and needs its own on_exit to force :auto mode
  # back on before the drop/delete cleanup and restore :manual afterward (the
  # ISS-0580 leak fix) -- TenantFixture's own default teardown does not do that
  # composition, so it stays disabled and this file's pre-existing on_exit is
  # kept untouched, matching category A's documented pattern. The extra
  # EventTypes.seed!/1 call after provisioning is this file's own
  # category-B step, likewise kept unchanged.
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req297-column-promotion",
          display_name: "REQ-297 Column Promotion Test Tenant",
          teardown: false
        )

      on_exit(fn ->
        # ISS-0580 rework: this callback runs AFTER the test process (and thus
        # SandboxAutoMode.provision!/2's own restore-to-:manual-plus-checkout,
        # scoped to that now-gone process) is gone -- so it must not assume
        # :manual mode still has a connection checked out for THIS (OnExitHandler)
        # process. Force :auto mode first so the DROP SCHEMA/delete_all cleanup
        # below always gets a real, checked-in connection regardless of what mode
        # the test process left the pool in. Mirrors role_registry_test.exs's own
        # on_exit/1 handling of this exact hazard.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))

        # REVIEWER fix (ISS-0580): restore :manual after cleanup -- leaving the
        # force-:auto above unrestored would reopen this exact leak, once per
        # test in this file instead of once ever. No checkout needed (same
        # reasoning as SandboxAutoMode.exit_auto_mode!/1's own doc: this
        # OnExitHandler process is not going to issue another Repo call).
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      assert {:ok, _seed_result} = EventTypes.seed!(schema_name)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
  end

  defp definition_fields(overrides) do
    Map.merge(
      %{
        name: "invoice",
        display_name: "Invoice",
        fields: [
          %{name: "amount", type: :string, queried: true},
          %{name: "notes", type: :string}
        ]
      },
      Map.new(overrides)
    )
  end

  defp create_active_definition!(schema, overrides \\ %{}) do
    definition = definition_fields(overrides)

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
      entity_type: "invoice",
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  defp fetch_information_schema_column(schema, table_name, column_name) do
    query = """
    SELECT data_type FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
    """

    case Repo.query!(query, [schema, table_name, column_name]) do
      %Postgrex.Result{rows: []} -> nil
      %Postgrex.Result{rows: [[data_type]]} -> data_type
    end
  end

  defp entity_table_row(schema, table_name, record_id, column_name) do
    sql =
      "SELECT \"#{column_name}\" FROM \"#{schema}\".\"#{table_name}\" WHERE record_id = ($1::text)::uuid"

    case Repo.query!(sql, [record_id]) do
      %Postgrex.Result{rows: [[value]]} -> value
      %Postgrex.Result{rows: []} -> :no_row
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- DDL applied to every tenant `list_registrations/0` returns.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- DDL applied to every tenant, verified directly against Postgres" do
    test "register_column_promotion/4 with :all + run_column_promotion/1 lands the column in both tenant schemas" do
      %{tenant_id: tenant_a, schema_name: schema_a} = provisioned_tenant()
      %{tenant_id: tenant_b, schema_name: schema_b} = provisioned_tenant()

      create_active_definition!(schema_a)
      create_active_definition!(schema_b)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      assert {:ok, rows} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 :all
               )

      # :all resolves via an unscoped `list_registrations/0` (production-correct
      # behavior -- see tenant_provisioning.ex's own @doc), so under a real-commit,
      # concurrently-scheduled test suite it may legitimately also resolve tenants
      # this test did not provision (ISS-0580's documented residual :auto-mode
      # window). Assert containment, not exact-set-equality (ISS-0716).
      tenant_ids_registered = Enum.map(rows, & &1.tenant_id)
      assert tenant_a in tenant_ids_registered
      assert tenant_b in tenant_ids_registered

      # Scope the DDL-execution loop to this test's own two rows -- iterating an
      # unrelated, concurrently-leaked tenant's row could fail for a reason having
      # nothing to do with AC1 (e.g. no active "invoice" definition there), and
      # would mutate a row this test has no business advancing (ISS-0716).
      rows_for_this_test = Enum.filter(rows, &(&1.tenant_id in [tenant_a, tenant_b]))
      assert length(rows_for_this_test) == 2

      for row <- rows_for_this_test do
        assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
                 TenantProvisioning.run_column_promotion(row.id)
      end

      # Queried directly against Postgres, NOT inferred from the executor's
      # own return value (AC1's own explicit requirement).
      assert fetch_information_schema_column(schema_a, table_name, "amount") == "text"
      assert fetch_information_schema_column(schema_b, table_name, "amount") == "text"
    end
  end

  # ---------------------------------------------------------------------------------
  # Additional coverage (design doc §12, beyond the seven ACs): table
  # creation on first use carries the FULL current promoted-column set, not
  # just the one attribute triggering this promotion.
  # ---------------------------------------------------------------------------------

  describe "table creation on first use" do
    test "the freshly-created per-entity-type table carries every currently-queried field, not just the promoted one" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema,
        fields: [
          %{name: "amount", type: :string, queried: true},
          %{name: "customer_ref", type: :string, queried: true},
          %{name: "notes", type: :string}
        ]
      )

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      refute TenantProvisioning.entity_table_exists?(schema, table_name)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert TenantProvisioning.entity_table_exists?(schema, table_name)
      # "customer_ref" was never individually promoted via a ColumnPromotion
      # row -- it is present purely because table creation carries the
      # FULL current promoted-column set (design doc §6 step 2).
      assert fetch_information_schema_column(schema, table_name, "amount") == "text"
      assert fetch_information_schema_column(schema, table_name, "customer_ref") == "text"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- per-tenant partial failure: one tenant's DDL fails, the other
  # still succeeds, and the failed tenant is marked ddl_failed.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- per-tenant partial failure (not cross-tenant atomic)" do
    test "one tenant's pre-existing column-type collision fails only that tenant's row" do
      %{tenant_id: tenant_a, schema_name: schema_a} = provisioned_tenant()
      %{tenant_id: tenant_b, schema_name: schema_b} = provisioned_tenant()

      create_active_definition!(schema_a)
      create_active_definition!(schema_b)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      assert {:ok, rows} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_a, tenant_b]
               )

      row_a = Enum.find(rows, &(&1.tenant_id == tenant_a))
      row_b = Enum.find(rows, &(&1.tenant_id == tenant_b))

      # Pre-create tenant B's table AND a same-named column with a
      # CONFLICTING type, simulating a pre-existing collision (AC2's own
      # named scenario) -- done via a throwaway promotion of a different
      # attribute first, so ensure_entity_table/2 creates the table, then a
      # manual ALTER to plant the conflicting "amount" column ourselves.
      Repo.query!("""
      CREATE TABLE "#{schema_b}"."#{table_name}" (
        id uuid PRIMARY KEY,
        record_id uuid NOT NULL UNIQUE,
        field_values jsonb NOT NULL DEFAULT '{}'::jsonb,
        deleted boolean NOT NULL DEFAULT false,
        entity_def_version bytea,
        last_event_global_seq bigint NOT NULL,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        amount bigint
      )
      """)

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row_a.id)

      assert {:error, {:column_type_conflict, "bigint", "text"}} =
               TenantProvisioning.run_column_promotion(row_b.id)

      # Tenant A succeeded; tenant B is marked ddl_failed -- no shared
      # transaction across tenants.
      assert %ColumnPromotion{status: "ddl_applied"} = Repo.get!(ColumnPromotion, row_a.id)
      failed_row = Repo.get!(ColumnPromotion, row_b.id)
      assert failed_row.status == "ddl_failed"
      assert failed_row.last_error =~ "column type conflict"

      # Tenant B's column type is unchanged (never coerced).
      assert fetch_information_schema_column(schema_b, table_name, "amount") == "bigint"
      assert fetch_information_schema_column(schema_a, table_name, "amount") == "text"
    end

    test "run_column_promotion_for_all_tenants/1 does not abort on the first failure" do
      %{tenant_id: tenant_a, schema_name: schema_a} = provisioned_tenant()
      %{tenant_id: tenant_b, schema_name: schema_b} = provisioned_tenant()

      create_active_definition!(schema_a)
      create_active_definition!(schema_b)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      assert {:ok, _rows} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_a, tenant_b]
               )

      # Force tenant B's table into existence with a conflicting column
      # first, via a throwaway direct promotion path identical to the test
      # above.
      TenantProvisioning.run_column_promotion(
        Repo.get_by!(ColumnPromotion,
          tenant_id: tenant_a,
          entity_type: "invoice",
          attribute: "amount"
        ).id
      )

      Repo.query!("""
      CREATE TABLE "#{schema_b}"."#{table_name}" (
        id uuid PRIMARY KEY,
        record_id uuid NOT NULL UNIQUE,
        field_values jsonb NOT NULL DEFAULT '{}'::jsonb,
        deleted boolean NOT NULL DEFAULT false,
        entity_def_version bytea,
        last_event_global_seq bigint NOT NULL,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        amount bigint
      )
      """)

      # Re-register a second attribute for BOTH tenants so
      # run_column_promotion_for_all_tenants/1 has fresh "pending" rows to
      # fan out over (the "amount" row for tenant_a is already ddl_applied
      # from the manual run above, not pending).
      assert {:ok, _second_rows} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "notes",
                 %{pg_type: "text", nullable: true},
                 [tenant_a, tenant_b]
               )

      result = TenantProvisioning.run_column_promotion_for_all_tenants({"invoice", "notes"})

      assert length(result.ok) == 2
      assert result.failed == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- backfill mechanism (replay via rebuild_projection/2, proven by
  # invocation, not merely correctness) + not-yet-backfilled read behavior.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- backfill mechanism is a replay through rebuild_projection/2" do
    test "backfill_column_promotion/1 actually invokes Projector.rebuild_projection/2" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      record = create_record!(schema, %{"amount" => "100", "notes" => "first"})

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      # Genuine invocation proof via Ecto's own built-in query telemetry
      # (`[:letflow, :repo, :query]`, already emitted for every query this
      # app issues -- no mocking framework, and no reliance on
      # `:erlang.trace/3` call-tracing, which this sandboxed environment
      # does not deliver messages for, confirmed empirically). The specific
      # `DELETE FROM "<schema>"."<entity_table>"` statement asserted below
      # is issued by exactly one place in this entire diff --
      # `write_entity_table_snapshots/4`, private to
      # `Letflow.Entities.Record.Projector`, reachable only through
      # `rebuild_projection/2` -- so observing it is direct proof
      # `rebuild_projection/2` ran, not merely that the column ends up
      # correct (which this implementation has no other mechanism to
      # achieve, but this test proves it rather than assuming it).
      test_pid = self()
      handler_id = "req297-backfill-invocation-#{System.unique_integer([:positive])}"
      delete_marker = "DELETE FROM \"#{schema}\".\"#{table_name}\""

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if String.starts_with?(query, delete_marker) do
            send(test_pid, :entity_table_delete_issued)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(row.id)

      assert_received :entity_table_delete_issued

      :telemetry.detach(handler_id)

      assert entity_table_row(schema, table_name, record.record_id, "amount") == "100"
    end

    test "a not-yet-backfilled record: Latest.field_values is already correct while the new column is still NULL" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # "notes" is present in field_values from day one, but not yet
      # promoted -- the realistic shape of "promote an existing JSON field."
      record_1 = create_record!(schema, %{"amount" => "10", "notes" => "alpha"})
      record_2 = create_record!(schema, %{"amount" => "20", "notes" => "beta"})

      # First promotion ("amount") creates the table and, since it is the
      # table's very first creation, auto-backfills via
      # ensure_entity_table/2's own rebuild_projection/2 call.
      assert {:ok, [amount_row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, _} = TenantProvisioning.run_column_promotion(amount_row.id)

      # A field is only ever promoted after its entity-definition edit marks
      # it queried: true (an unfiled HTTP/admin surface's job, per this
      # requirement's own scope fence -- modeled here directly) --
      # DDL.promoted_columns/1 (the write path's column set) reads that flag
      # off the CURRENT active definition, not off ColumnPromotion rows.
      create_active_definition!(schema,
        fields: [
          %{name: "amount", type: :string, queried: true},
          %{name: "notes", type: :string, queried: true}
        ]
      )

      # Second promotion ("notes") -- the table already exists, so
      # ensure_entity_table/2 is a no-op this time: ADD COLUMN alone leaves
      # pre-existing rows NULL until backfill_column_promotion/1 runs.
      assert {:ok, [notes_row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "notes",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(notes_row.id)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      # Not-yet-backfilled: the per-entity-type table's "notes" column is
      # still NULL for the pre-existing rows.
      assert entity_table_row(schema, table_name, record_1.record_id, "notes") == nil
      assert entity_table_row(schema, table_name, record_2.record_id, "notes") == nil

      # Meanwhile entity_record_latest's field_values already has the
      # correct value -- dual-write's field_values side, present from the
      # moment the record was written, unaffected by promotion state.
      assert {:ok, latest_1} =
               Letflow.Entities.Record.Latest.get(record_1.record_id, "invoice", schema)

      assert latest_1.field_values["notes"] == "alpha"

      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(notes_row.id)

      assert entity_table_row(schema, table_name, record_1.record_id, "notes") == "alpha"
      assert entity_table_row(schema, table_name, record_2.record_id, "notes") == "beta"
    end

    test "a write landing mid-backfill-window (status ddl_applied) is dual-written into the entity table" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert TenantProvisioning.column_promotion_dual_write?(tenant_id, "invoice", "amount")

      record = create_record!(schema, %{"amount" => "live-write", "notes" => "n"})

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      assert entity_table_row(schema, table_name, record.record_id, "amount") == "live-write"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- type-conflict rejection: a promotion whose target column would
  # conflict with an already-promoted column's type is rejected, not
  # coerced or ignored.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- type-conflict rejection" do
    test "a second promotion colliding on the same physical column_name with a different type is rejected" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      # "amount" is typed :integer here (-> "bigint" via
      # DDL.field_type_to_pg_type/1) so the freshly-created per-entity-type
      # table's own "amount" column (built from the CURRENT definition,
      # design doc §6 step 2) matches the "bigint" pg_type requested below
      # -- not a mismatch that would itself trip the additive-only check on
      # this promotion's own first run.
      create_active_definition!(schema,
        fields: [
          %{name: "amount", type: :integer, queried: true},
          %{name: "notes", type: :string}
        ]
      )

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "bigint", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(row.id)

      assert {:ok, %ColumnPromotion{status: "active"}} =
               TenantProvisioning.activate_column_promotion(row.id)

      # A second, distinct promotion for a DIFFERENT attribute that
      # happens to target the SAME physical column_name ("amount") with a
      # conflicting pg_type -- constructed directly against the schema
      # (register_column_promotion/4's own contract fixes column_name to
      # equal attribute; a corrective re-promotion under a divergent
      # column_name, per req295 §1's own note, is not exercised by
      # register_column_promotion/4 itself).
      colliding_attrs = %{
        tenant_id: tenant_id,
        entity_type: "invoice",
        attribute: "amount_alt",
        column_name: "amount",
        pg_type: "text",
        status: "pending",
        query_eligible: false
      }

      assert {:ok, colliding_row} =
               Repo.insert(ColumnPromotion.changeset(%ColumnPromotion{}, colliding_attrs))

      assert {:error, {:column_type_conflict, "bigint", "text"}} =
               TenantProvisioning.run_column_promotion(colliding_row.id)

      assert %ColumnPromotion{status: "ddl_failed"} = Repo.get!(ColumnPromotion, colliding_row.id)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      # Never coerced -- the physical column is still bigint.
      assert fetch_information_schema_column(schema, table_name, "amount") == "bigint"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- no code path drops or narrows a column.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- no DROP COLUMN / narrowing ALTER COLUMN anywhere in the executor's diff" do
    test "grep across every file this requirement touches finds zero hits" do
      files = [
        "lib/letflow/tenant_provisioning.ex",
        "lib/letflow/tenant_provisioning/column_promotion.ex",
        "lib/letflow/entities/records.ex",
        "lib/letflow/entities/record/projector.ex"
      ]

      pattern = ~r/DROP COLUMN|ALTER COLUMN.*TYPE/i

      hits =
        for file <- files,
            {contents, line} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(pattern, contents) do
          {file, line, contents}
        end

      assert hits == [],
             "found DROP COLUMN / narrowing ALTER COLUMN occurrences: #{inspect(hits)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- moduledoc citation.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- moduledoc citation" do
    test "Letflow.TenantProvisioning's moduledoc cites both 0024 and req297's design and names all four sub-answers" do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.TenantProvisioning)

      assert moduledoc =~ "0024-entity-promotion-ddl-execution.md"
      assert moduledoc =~ "req297-entity-promotion-executor.md"
      assert moduledoc =~ "mechanism"
      assert moduledoc =~ "Partial-failure"
      assert moduledoc =~ "Backfill"
      assert moduledoc =~ "Rollback"
    end

    test "ColumnPromotion's moduledoc cites both 0024 and req295's design and names all four sub-answers" do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.TenantProvisioning.ColumnPromotion)

      assert moduledoc =~ "0024-entity-promotion-ddl-execution.md"
      assert moduledoc =~ "req295-entity-promotion-ddl-execution.md"
      assert moduledoc =~ "mechanism"
      assert moduledoc =~ "partial-failure"
      assert moduledoc =~ "backfill"
      assert moduledoc =~ "rollback"
    end
  end

  # ---------------------------------------------------------------------------------
  # Suspend/reactivate cycle (design doc §12's own additional coverage item).
  # ---------------------------------------------------------------------------------

  describe "suspend/reactivate cycle" do
    test "suspend_column_promotion/2 flips query_eligible to false while status stays active, then a corrective backfill/activate cycle re-enables it" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(row.id)

      assert {:ok, %ColumnPromotion{status: "active", query_eligible: true}} =
               TenantProvisioning.activate_column_promotion(row.id)

      assert TenantProvisioning.column_promotion_query_eligible?(tenant_id, "invoice", "amount")

      assert {:ok, %ColumnPromotion{status: "active", query_eligible: false} = suspended} =
               TenantProvisioning.suspend_column_promotion(
                 row.id,
                 "defect found in backfilled data"
               )

      refute TenantProvisioning.column_promotion_query_eligible?(tenant_id, "invoice", "amount")
      # dual-write is false once active/suspended -- suspend never restarts it.
      refute TenantProvisioning.column_promotion_dual_write?(tenant_id, "invoice", "amount")
      assert suspended.suspend_reason == "defect found in backfilled data"

      # Corrective backfill re-run, then re-activation -- 0024 §4's
      # repeatable active -> backfilling -> backfilled -> active cycle.
      # backfill_column_promotion/1 requires ddl_applied/backfilling, so the
      # row's status is force-reset to ddl_applied here to model "found a
      # defect, want to re-run backfill" without inventing a new public
      # transition this requirement does not own.
      assert {:ok, reset} =
               Repo.update(ColumnPromotion.changeset(suspended, %{status: "ddl_applied"}))

      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(reset.id)

      assert {:ok, %ColumnPromotion{status: "active", query_eligible: true}} =
               TenantProvisioning.activate_column_promotion(reset.id)

      assert TenantProvisioning.column_promotion_query_eligible?(tenant_id, "invoice", "amount")
    end
  end

  # ---------------------------------------------------------------------------------
  # retry_failed_column_promotion/1
  # ---------------------------------------------------------------------------------

  describe "retry_failed_column_promotion/1" do
    test "retries a ddl_failed row and succeeds once the conflicting column is gone" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      Repo.query!("""
      CREATE TABLE "#{schema}"."#{table_name}" (
        id uuid PRIMARY KEY,
        record_id uuid NOT NULL UNIQUE,
        field_values jsonb NOT NULL DEFAULT '{}'::jsonb,
        deleted boolean NOT NULL DEFAULT false,
        entity_def_version bytea,
        last_event_global_seq bigint NOT NULL,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        amount bigint
      )
      """)

      assert {:error, {:column_type_conflict, "bigint", "text"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert %ColumnPromotion{status: "ddl_failed"} = Repo.get!(ColumnPromotion, row.id)

      Repo.query!("ALTER TABLE \"#{schema}\".\"#{table_name}\" DROP COLUMN amount")

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.retry_failed_column_promotion(row.id)

      assert fetch_information_schema_column(schema, table_name, "amount") == "text"
    end

    test "returns :not_ddl_failed for a row that isn't ddl_failed" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:error, :not_ddl_failed} = TenantProvisioning.retry_failed_column_promotion(row.id)
    end

    test "returns :promotion_not_found for an unknown promotion_id" do
      assert {:error, :promotion_not_found} =
               TenantProvisioning.run_column_promotion(Ecto.UUID.generate())

      assert {:error, :promotion_not_found} =
               TenantProvisioning.retry_failed_column_promotion(Ecto.UUID.generate())

      assert {:error, :promotion_not_found} =
               TenantProvisioning.backfill_column_promotion(Ecto.UUID.generate())

      assert {:error, :promotion_not_found} =
               TenantProvisioning.activate_column_promotion(Ecto.UUID.generate())

      assert {:error, :promotion_not_found} =
               TenantProvisioning.suspend_column_promotion(Ecto.UUID.generate(), "x")
    end
  end

  # ---------------------------------------------------------------------------------
  # column_promotion_query_eligible?/3 and column_promotion_dual_write?/3
  # for the "no row at all" case.
  # ---------------------------------------------------------------------------------

  describe "read-side accessors -- no ColumnPromotion row at all" do
    test "both return false for an attribute that has never been promoted" do
      %{tenant_id: tenant_id} = provisioned_tenant()

      refute TenantProvisioning.column_promotion_query_eligible?(tenant_id, "invoice", "amount")
      refute TenantProvisioning.column_promotion_dual_write?(tenant_id, "invoice", "amount")
    end
  end

  # ---------------------------------------------------------------------------------
  # field_type_to_pg_type/1 reuse sanity check -- callers are expected to
  # derive column_spec.pg_type from DDL.field_type_to_pg_type/1.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # REQ-301 -- execute_add_column/3's defensive re-validation of generated_as.
  # See lib/letflow/design/req301-localized-text-field-type.md §4.3.
  # ---------------------------------------------------------------------------------

  describe "REQ-301 -- execute_add_column/3's defensive re-validation of generated_as" do
    test "a stored ColumnPromotion row with a malformed generated_as is rejected as ddl_failed, never applied" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      malicious_generated_as =
        "field_values->'amount'->>'kk'; DROP TABLE entity_column_promotions; --"

      # Constructed directly (bypassing register_column_promotion/4, which
      # does not itself validate generated_as's shape) to model "a stored
      # row somehow holds an unsafe value" -- exactly the scenario
      # execute_add_column/3's own re-validation guard exists for.
      attrs = %{
        tenant_id: tenant_id,
        entity_type: "invoice",
        attribute: "amount_kk",
        column_name: "amount_kk",
        pg_type: "text",
        generated_as: malicious_generated_as,
        status: "pending",
        query_eligible: false
      }

      assert {:ok, row} = Repo.insert(ColumnPromotion.changeset(%ColumnPromotion{}, attrs))

      assert {:error, {:ddl_failed, %ArgumentError{} = exception}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert Exception.message(exception) =~ "invalid generated_as"

      failed_row = Repo.get!(ColumnPromotion, row.id)
      assert failed_row.status == "ddl_failed"
      assert failed_row.last_error =~ "invalid generated_as"

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      assert fetch_information_schema_column(schema, table_name, "amount_kk") == nil
    end

    test "a nil generated_as (an ordinary promotion) is unaffected by the re-validation guard" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert row.generated_as == nil

      assert {:ok, %ColumnPromotion{status: "ddl_applied", generated_as: nil}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      assert fetch_information_schema_column(schema, table_name, "amount") == "text"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-301 -- a well-formed generated_as, applied via the ALTER TABLE path
  # (register_column_promotion/4 + run_column_promotion/1, not CREATE TABLE),
  # actually computes its value from a real row's field_values.
  # ---------------------------------------------------------------------------------

  describe "REQ-301 -- generated_as applies as GENERATED ALWAYS AS ... STORED via ALTER TABLE" do
    test "a locale-derived generated column added via ALTER TABLE computes from field_values" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")

      # First promotion ("amount", ordinary) creates the per-entity-type
      # table via ensure_entity_table/2.
      assert {:ok, [amount_row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(amount_row.id)

      generated_as_expr = ~s{field_values->'amount'->>'kk'}

      assert {:ok, [locale_row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount_kk",
                 %{pg_type: "text", nullable: true, generated_as: generated_as_expr},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied", generated_as: ^generated_as_expr}} =
               TenantProvisioning.run_column_promotion(locale_row.id)

      assert fetch_information_schema_column(schema, table_name, "amount_kk") == "text"

      # Insert a row directly via raw SQL -- bypassing
      # Letflow.Entities.Records/Record.Validator, which has no
      # field_subschema/1 clause for :localized_text yet (a pre-existing gap
      # outside this requirement's own scope, not exercised here) -- purely
      # to prove the GENERATED ALWAYS AS expression itself actually computes
      # from field_values, not merely that the column exists.
      record_id = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO "#{schema}"."#{table_name}"
          (id, record_id, field_values, deleted, last_event_global_seq, inserted_at, updated_at)
        VALUES
          (($1::text)::uuid, ($2::text)::uuid, ($3::text)::jsonb, false, 1, now(), now())
        """,
        [Ecto.UUID.generate(), record_id, Jason.encode!(%{"amount" => %{"kk" => "on bes"}})]
      )

      assert entity_table_row(schema, table_name, record_id, "amount_kk") == "on bes"
    end
  end

  describe "DDL.field_type_to_pg_type/1 reuse" do
    test "the caller-supplied pg_type in register_column_promotion/4 round-trips exactly as given" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      field = %{name: "amount", type: :decimal, decimal_precision: 10, decimal_scale: 2}
      assert {:ok, pg_type} = DDL.field_type_to_pg_type(field)
      assert pg_type == "numeric(10, 2)"

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: pg_type, nullable: true},
                 [tenant_id]
               )

      assert row.pg_type == "numeric(10, 2)"
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0623 -- `definition.indexes` actually emits CREATE INDEX against the
  # real per-tenant table, verified via pg_indexes (schema-qualified), not
  # merely against generated DDL text. See
  # lib/letflow/design/iss0623-entity-index-ddl-emission.md §9.3.
  # ---------------------------------------------------------------------------------

  defp fetch_tenant_pg_indexes(schema, table_name) do
    Repo.query!(
      "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
      [schema, table_name]
    ).rows
    |> Map.new(fn [indexname, indexdef] -> {indexname, indexdef} end)
  end

  describe "ISS-0623 -- definition.indexes emits real CREATE INDEX statements in the tenant schema" do
    test "run_column_promotion/1's table creation emits every declared index_def, unique flag included" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema,
        fields: [
          %{name: "amount", type: :string, queried: true},
          %{name: "code", type: :string, queried: true}
        ],
        indexes: [
          %{name: "idx_invoice_amount", fields: ["amount"]},
          %{name: "uq_invoice_code_idx", fields: ["code"], unique: true}
        ]
      )

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      refute TenantProvisioning.entity_table_exists?(schema, table_name)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert TenantProvisioning.entity_table_exists?(schema, table_name)

      indexes = fetch_tenant_pg_indexes(schema, table_name)

      assert Map.has_key?(indexes, "idx_invoice_amount")
      refute indexes["idx_invoice_amount"] =~ "CREATE UNIQUE INDEX"

      assert Map.has_key?(indexes, "uq_invoice_code_idx")
      assert indexes["uq_invoice_code_idx"] =~ "CREATE UNIQUE INDEX"
    end

    test "a cross-entity-type index-name collision surfaces as a real, unswallowed ddl_failed error -- never a silent rename or silent success" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema,
        fields: [%{name: "amount", type: :string, queried: true}],
        indexes: [%{name: "idx_shared_name", fields: ["amount"]}]
      )

      assert {:ok, invoice_table} = TenantProvisioning.table_name_for_entity_type("invoice")

      assert {:ok, [invoice_row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(invoice_row.id)

      assert Map.has_key?(fetch_tenant_pg_indexes(schema, invoice_table), "idx_shared_name")

      # A second, distinct entity type in the SAME tenant schema, declaring
      # an index_def with the identical name.
      second_definition = %{
        name: "receipt",
        display_name: "Receipt",
        fields: [%{name: "total", type: :string, queried: true}],
        indexes: [%{name: "idx_shared_name", fields: ["total"]}]
      }

      assert {:ok, entity_definition} =
               Definitions.create_definition(
                 %{definition: second_definition, created_by: Ecto.UUID.generate()},
                 schema
               )

      assert {:ok, _activated} =
               Definitions.activate_definition(
                 entity_definition.name,
                 Ecto.UUID.generate(),
                 "go-live",
                 schema
               )

      assert {:ok, receipt_table} = TenantProvisioning.table_name_for_entity_type("receipt")
      refute TenantProvisioning.entity_table_exists?(schema, receipt_table)

      assert {:ok, [receipt_row]} =
               TenantProvisioning.register_column_promotion(
                 "receipt",
                 "total",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:error, {:ddl_failed, %Postgrex.Error{postgres: %{code: :duplicate_table}}}} =
               TenantProvisioning.run_column_promotion(receipt_row.id)

      # No partial/renamed table left behind -- the whole transaction
      # (CREATE TABLE + its indexes) rolled back per the design's §2
      # atomicity argument.
      refute TenantProvisioning.entity_table_exists?(schema, receipt_table)

      # The first entity type's index is untouched: still exactly one
      # pg_indexes row named "idx_shared_name" in this schema, on the
      # invoice table -- never silently renamed, never silently duplicated.
      assert Map.has_key?(fetch_tenant_pg_indexes(schema, invoice_table), "idx_shared_name")

      all_schema_indexes =
        Repo.query!("SELECT indexname FROM pg_indexes WHERE schemaname = $1", [schema]).rows
        |> List.flatten()

      assert Enum.count(all_schema_indexes, &(&1 == "idx_shared_name")) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0777 -- register_column_promotion/4's own identifier-format check
  # (the defence-in-depth layer, independent of start_rollout/3's own
  # check -- see lib/letflow/design/iss-0777-entity-type-identifier-validation.md
  # §2/§4.2 and test/specs/ISS-0777.md). Called directly here, not via
  # MigrationRollout, so this layer is proven to work on its own.
  # ---------------------------------------------------------------------------------

  describe "ISS-0777 -- register_column_promotion/4 rejects an invalid identifier before any write" do
    test "an invalid entity_type returns {:error, :invalid_entity_type} immediately, with zero ColumnPromotion rows written, no transaction side effect" do
      entity_type = "pl-rollout-95a456dd"
      attribute = "sku"

      count_before =
        Repo.aggregate(from(cp in ColumnPromotion, where: cp.entity_type == ^entity_type), :count)

      assert TenantProvisioning.register_column_promotion(
               entity_type,
               attribute,
               %{pg_type: "text", nullable: true},
               :all
             ) == {:error, :invalid_entity_type}

      count_after =
        Repo.aggregate(from(cp in ColumnPromotion, where: cp.entity_type == ^entity_type), :count)

      assert count_after == count_before
      assert count_after == 0
    end

    test "an invalid attribute (valid entity_type) returns {:error, :invalid_attribute} immediately, with zero rows written" do
      entity_type = "invoice"
      attribute = "some-attr"

      count_before =
        Repo.aggregate(
          from(cp in ColumnPromotion,
            where: cp.entity_type == ^entity_type and cp.attribute == ^attribute
          ),
          :count
        )

      assert TenantProvisioning.register_column_promotion(
               entity_type,
               attribute,
               %{pg_type: "text", nullable: true},
               :all
             ) == {:error, :invalid_attribute}

      count_after =
        Repo.aggregate(
          from(cp in ColumnPromotion,
            where: cp.entity_type == ^entity_type and cp.attribute == ^attribute
          ),
          :count
        )

      assert count_after == count_before
      assert count_after == 0
    end

    test "entity_type is checked before attribute -- both invalid reports :invalid_entity_type, deterministically" do
      assert TenantProvisioning.register_column_promotion(
               "bad-entity",
               "bad-attr",
               %{pg_type: "text", nullable: true},
               :all
             ) == {:error, :invalid_entity_type}
    end

    test "no regression: register_column_promotion/4's own AC1 happy path (real, Validator-checked entity_type/attribute) still succeeds unchanged" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert row.entity_type == "invoice"
      assert row.attribute == "amount"
      assert row.status == "pending"
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2635 -- execute_add_column's pg_type / column_name / generated_as re-validation
  # must be end-anchored (\z): a stored value with a trailing newline used to pass `$`.
  # ---------------------------------------------------------------------------------

  describe "GH #2635 -- execute_add_column re-validation refuses a trailing newline" do
    defp insert_promotion!(tenant_id, overrides) do
      attrs =
        Map.merge(
          %{
            tenant_id: tenant_id,
            entity_type: "invoice",
            attribute: "amount_n",
            column_name: "amount_n",
            pg_type: "text",
            generated_as: nil,
            status: "pending",
            query_eligible: false
          },
          overrides
        )

      assert {:ok, row} = Repo.insert(ColumnPromotion.changeset(%ColumnPromotion{}, attrs))
      row
    end

    test "a numeric pg_type with a trailing newline is rejected as ddl_failed, never applied" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      row = insert_promotion!(tenant_id, %{pg_type: "numeric(10,2)
"})

      assert {:error, {:ddl_failed, %ArgumentError{} = exception}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert Exception.message(exception) =~ "invalid pg_type"
      assert Repo.get!(ColumnPromotion, row.id).status == "ddl_failed"
    end

    test "a well-formed numeric pg_type is still applied" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      row = insert_promotion!(tenant_id, %{pg_type: "numeric(10,2)"})

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)
    end

    test "a generated_as with a trailing newline is rejected as ddl_failed, never applied" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      row =
        insert_promotion!(tenant_id, %{
          attribute: "amount_kk",
          column_name: "amount_kk",
          generated_as: "field_values->'amount'->>'kk'
"
        })

      assert {:error, {:ddl_failed, %ArgumentError{} = exception}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert Exception.message(exception) =~ "invalid generated_as"
    end

    test "a column_name with a trailing newline is rejected as ddl_failed, never applied" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)
      row = insert_promotion!(tenant_id, %{column_name: "amount_n
"})

      assert {:error, {:ddl_failed, %ArgumentError{} = exception}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert Exception.message(exception) =~ "invalid column_name"
    end
  end

  describe "GH #2852 -- column_promotions_for_table_write/2 returns a deterministic order" do
    test "rows come back ordered by attribute regardless of insertion order, tenant filter intact" do
      %{tenant_id: tenant_id} = provisioned_tenant()
      %{tenant_id: other_tenant_id} = provisioned_tenant()

      for {attribute, tid, status} <- [
            {"zeta", tenant_id, "active"},
            {"mid", tenant_id, "ddl_applied"},
            {"alpha", tenant_id, "backfilled"},
            {"pending_one", tenant_id, "pending"},
            {"other_tenant_attr", other_tenant_id, "active"}
          ] do
        assert {:ok, _} =
                 Repo.insert(
                   ColumnPromotion.changeset(%ColumnPromotion{}, %{
                     tenant_id: tid,
                     entity_type: "invoice",
                     attribute: attribute,
                     column_name: attribute,
                     pg_type: "text",
                     status: status
                   })
                 )
      end

      # The (tenant_id, entity_type, attribute) unique index would otherwise hand
      # the rows back in attribute order by planner luck; force a heap scan so
      # the unordered query returns insertion order, as it can in production.
      Repo.query!("SET LOCAL enable_indexscan = off")
      Repo.query!("SET LOCAL enable_bitmapscan = off")

      rows = TenantProvisioning.column_promotions_for_table_write(tenant_id, "invoice")

      assert Enum.map(rows, & &1.attribute) == ["alpha", "mid", "zeta"]
    end
  end
end
