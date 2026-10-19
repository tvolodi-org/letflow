defmodule Letflow.Entities.RecordsManagedByTest do
  @moduledoc """
  GH #2583 (design `lib/letflow/design/gh2583-records-managed-type-guard.md` Revisions 1-2,
  section 10 T-01..T-09 and T-11; spec `test/specs/GH-2583.md`): `Letflow.Entities.Records`
  itself refuses a `managed_by` entity type unless the caller passes that module's `Owner` naming
  the type, independent of the router guard.

    * T-01/T-02: `:tenant` (explicit `/3` and the `/2` default) is refused on create, update and
      delete of each of the seven managed fixture types, for an existing and an absent record id.
    * T-03: `ManagedTypes.owner_for!(FixtureManaged)` passed straight to the `/3` functions writes.
    * T-04/T-05: an `Owner` of another module, or an `Owner` that does not name the type, is
      refused; `fxm_ledger` (managed AND append-only) answers the managed refusal, not
      `entity_append_only`, to `:tenant`.
    * T-06: the refusal comes before payload validation, the missing-record answer, the
      already-deleted no-op and the version-conflict check.
    * T-07: the unmanaged control `fxm_free` keeps working for every authority.
    * T-08: a value that is neither `:tenant` nor an `%Owner{}` raises `FunctionClauseError`
      before any query.
    * T-09: authority-looking keys inside `attrs` grant nothing.
    * T-11: a refused call issues exactly the definition lookup's queries, nothing more.

  "No write" = no new `ENTITY_RECORD_*` event in the tenant event store and no change to
  `entity_record_latest`. `Owner` structs are forged here on purpose (test bodies are outside the
  caller scan's `lib/` + `test/support/` set, design section 7.1).

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ManagedTypes.Owner
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @actor_id "00000000-0000-0000-0000-000000000000"

  # The seven types fixture_managed's manifest declares; fxm_ledger is also append_only.
  @seven [
    "fxm_legal_entity",
    "fxm_site",
    "fxm_unit",
    "fxm_unit_membership",
    "fxm_item",
    "fxm_uom",
    "fxm_ledger"
  ]
  @six_mutable @seven -- ["fxm_ledger"]

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2583-rec")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    {:ok, _tenant_module} =
      Installs.install("fixture_managed", Ecto.UUID.generate(),
        prefix: tenant.schema_name,
        rationale: "GH #2583 Records guard test install"
      )

    {:ok, schema: tenant.schema_name, owner: ManagedTypes.owner_for!(FixtureManaged)}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp create_attrs(type, field_values) do
    %{
      entity_type: type,
      field_values: field_values,
      actor_id: @actor_id,
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp update_attrs(type, record_id, field_values) do
    %{
      entity_type: type,
      record_id: record_id,
      field_values: field_values,
      actor_id: @actor_id,
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp delete_attrs(type, record_id) do
    %{
      entity_type: type,
      record_id: record_id,
      actor_id: @actor_id,
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp owner_record!(schema, type) do
    {:ok, %{record: record}} =
      FixtureManaged.create_record(type, %{"name" => "seeded by owner"}, schema)

    record
  end

  defp record_event_count(schema) do
    Repo.one!(
      from(e in Event,
        where: like(e.event_type, "ENTITY_RECORD_%"),
        select: count(e.event_id)
      ),
      prefix: schema
    )
  end

  defp latest_snapshot(schema) do
    Repo.all(
      from(l in Latest,
        order_by: l.record_id,
        select: {l.record_id, l.entity_type, l.field_values, l.deleted, l.last_event_global_seq}
      ),
      prefix: schema
    )
  end

  # Runs `fun` and asserts it wrote nothing: no ENTITY_RECORD_* event, no latest-row change.
  defp without_write!(schema, label, fun) do
    events = record_event_count(schema)
    latest = latest_snapshot(schema)
    result = fun.()
    assert record_event_count(schema) == events, "#{label}: an ENTITY_RECORD_* event was appended"
    assert latest_snapshot(schema) == latest, "#{label}: entity_record_latest changed"
    result
  end

  # Each write command with :tenant through BOTH the /2 default and the explicit /3 arity.
  defp tenant_arities(fun_name, attrs, schema) do
    [
      {"#{fun_name}/2", apply(Records, fun_name, [attrs, schema])},
      {"#{fun_name}/3 :tenant", apply(Records, fun_name, [attrs, schema, :tenant])}
    ]
  end

  # ── T-01 / T-02 ─────────────────────────────────────────────────────────────────────────────

  describe "T-01/T-02 (AC2): :tenant is refused on every managed type" do
    test "T-01: create_record with the /2 default and with explicit :tenant -> :entity_type_managed, no write",
         %{schema: schema} do
      for type <- @seven do
        results =
          without_write!(schema, "create #{type}", fn ->
            tenant_arities(:create_record, create_attrs(type, %{"name" => "tenant"}), schema)
          end)

        for {label, result} <- results do
          assert result == {:error, :entity_type_managed}, "#{label} #{type}: #{inspect(result)}"
        end
      end
    end

    test "T-02: update_record and delete_record on an existing and an absent id -> :entity_type_managed, record unchanged",
         %{schema: schema} do
      for type <- @six_mutable do
        record = owner_record!(schema, type)

        for record_id <- [record.record_id, Ecto.UUID.generate()] do
          results =
            without_write!(schema, "update/delete #{type}", fn ->
              tenant_arities(
                :update_record,
                update_attrs(type, record_id, %{"name" => "tenant overwrite"}),
                schema
              ) ++ tenant_arities(:delete_record, delete_attrs(type, record_id), schema)
            end)

          for {label, result} <- results do
            assert result == {:error, :entity_type_managed},
                   "#{label} #{type} #{record_id}: #{inspect(result)}"
          end
        end
      end
    end
  end

  # ── T-03 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-03 (AC2): the owner_for!/1 Owner writes every managed type" do
    test "create, update and delete through the /3 arities succeed; fxm_ledger create succeeds",
         %{schema: schema, owner: owner} do
      for type <- @six_mutable do
        assert {:ok, %{record: created}} =
                 Records.create_record(create_attrs(type, %{"name" => "owner"}), schema, owner)

        assert created.field_values == %{"name" => "owner"}

        assert {:ok, %{record: updated}} =
                 Records.update_record(
                   update_attrs(type, created.record_id, %{"name" => "owner 2"}),
                   schema,
                   owner
                 )

        assert updated.field_values == %{"name" => "owner 2"}

        assert {:ok, %{record: deleted}} =
                 Records.delete_record(delete_attrs(type, created.record_id), schema, owner)

        assert deleted.deleted
      end

      assert {:ok, %{record: ledger}} =
               Records.create_record(
                 create_attrs("fxm_ledger", %{"name" => "entry"}),
                 schema,
                 owner
               )

      assert ledger.field_values == %{"name" => "entry"}
    end
  end

  # ── T-04 / T-05 ─────────────────────────────────────────────────────────────────────────────

  describe "T-04/T-05 (AC2): the wrong Owner is refused" do
    test "T-04: an Owner of another module naming all seven types -> :entity_type_managed, no write",
         %{schema: schema} do
      forged = %Owner{module_id: "other_module", manages: MapSet.new(@seven)}

      for type <- @six_mutable do
        record = owner_record!(schema, type)

        results =
          without_write!(schema, "forged owner #{type}", fn ->
            [
              Records.create_record(create_attrs(type, %{"name" => "x"}), schema, forged),
              Records.update_record(
                update_attrs(type, record.record_id, %{"name" => "x"}),
                schema,
                forged
              ),
              Records.delete_record(delete_attrs(type, record.record_id), schema, forged)
            ]
          end)

        assert results == List.duplicate({:error, :entity_type_managed}, 3), type
      end
    end

    test "T-05: an Owner of the right module that does not name the type -> :entity_type_managed",
         %{schema: schema} do
      narrow = %Owner{module_id: "fixture_managed", manages: MapSet.new(["fxm_site"])}
      record = owner_record!(schema, "fxm_unit")

      results =
        without_write!(schema, "narrow owner fxm_unit", fn ->
          [
            Records.create_record(create_attrs("fxm_unit", %{"name" => "x"}), schema, narrow),
            Records.update_record(
              update_attrs("fxm_unit", record.record_id, %{"name" => "x"}),
              schema,
              narrow
            ),
            Records.delete_record(delete_attrs("fxm_unit", record.record_id), schema, narrow)
          ]
        end)

      assert results == List.duplicate({:error, :entity_type_managed}, 3)

      # Control: the same narrow Owner DOES write the type it names.
      assert {:ok, _} =
               Records.create_record(create_attrs("fxm_site", %{"name" => "x"}), schema, narrow)
    end

    test "T-05: :tenant update/delete on fxm_ledger (managed + append_only) answers the managed refusal first",
         %{schema: schema, owner: owner} do
      ledger = owner_record!(schema, "fxm_ledger")

      results =
        without_write!(schema, "tenant fxm_ledger", fn ->
          tenant_arities(
            :update_record,
            update_attrs("fxm_ledger", ledger.record_id, %{"name" => "rewrite"}),
            schema
          ) ++
            tenant_arities(:delete_record, delete_attrs("fxm_ledger", ledger.record_id), schema)
        end)

      for {label, result} <- results do
        assert result == {:error, :entity_type_managed}, "#{label}: #{inspect(result)}"
      end

      # Control: the owner passes the managed check and reaches the append-only refusal.
      assert {:error, {:entity_append_only, "fxm_ledger"}} =
               Records.update_record(
                 update_attrs("fxm_ledger", ledger.record_id, %{"name" => "rewrite"}),
                 schema,
                 owner
               )
    end
  end

  # ── T-06 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-06 (AC2): the managed refusal comes before every other outcome" do
    test "invalid payload: :tenant -> :entity_type_managed; the owner gets record_payload_invalid",
         %{schema: schema, owner: owner} do
      # `name` is a required string: an integer and a missing key are both invalid.
      for bad <- [%{"name" => 123}, %{}] do
        assert without_write!(schema, "tenant bad payload", fn ->
                 Records.create_record(create_attrs("fxm_unit", bad), schema)
               end) == {:error, :entity_type_managed}

        assert {:error, {:record_payload_invalid, _violations}} =
                 Records.create_record(create_attrs("fxm_unit", bad), schema, owner)
      end
    end

    test "absent record: :tenant -> :entity_type_managed; the owner gets record_not_found",
         %{schema: schema, owner: owner} do
      absent = Ecto.UUID.generate()

      assert Records.update_record(update_attrs("fxm_unit", absent, %{"name" => "x"}), schema) ==
               {:error, :entity_type_managed}

      assert Records.delete_record(delete_attrs("fxm_unit", absent), schema) ==
               {:error, :entity_type_managed}

      assert {:error, {:record_not_found, ^absent}} =
               Records.update_record(
                 update_attrs("fxm_unit", absent, %{"name" => "x"}),
                 schema,
                 owner
               )

      assert {:error, {:record_not_found, ^absent}} =
               Records.delete_record(delete_attrs("fxm_unit", absent), schema, owner)
    end

    test "already deleted: :tenant delete -> :entity_type_managed, not the no-op success",
         %{schema: schema, owner: owner} do
      record = owner_record!(schema, "fxm_unit")

      assert {:ok, _} =
               Records.delete_record(delete_attrs("fxm_unit", record.record_id), schema, owner)

      assert without_write!(schema, "tenant delete deleted", fn ->
               Records.delete_record(delete_attrs("fxm_unit", record.record_id), schema)
             end) == {:error, :entity_type_managed}

      # Control: the owner's repeat delete is the documented no-op success.
      assert {:ok, _} =
               Records.delete_record(delete_attrs("fxm_unit", record.record_id), schema, owner)
    end

    test "stale expected seq: :tenant update -> :entity_type_managed; the owner gets record_version_conflict",
         %{schema: schema, owner: owner} do
      record = owner_record!(schema, "fxm_unit")
      stale = record.last_event_global_seq - 1

      stale_attrs =
        "fxm_unit"
        |> update_attrs(record.record_id, %{"name" => "x"})
        |> Map.put(:expected_last_event_global_seq, stale)

      assert without_write!(schema, "tenant stale update", fn ->
               Records.update_record(stale_attrs, schema)
             end) == {:error, :entity_type_managed}

      assert {:error, :record_version_conflict} =
               Records.update_record(
                 %{stale_attrs | idempotency_key: Ecto.UUID.generate()},
                 schema,
                 owner
               )
    end
  end

  # ── T-07 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-07 (AC2): the unmanaged control fxm_free" do
    test "create/update/delete succeed with the /2 default, explicit :tenant and the Owner",
         %{schema: schema, owner: owner} do
      writers = [
        {"/2", fn fun, attrs -> apply(Records, fun, [attrs, schema]) end},
        {"/3 :tenant", fn fun, attrs -> apply(Records, fun, [attrs, schema, :tenant]) end},
        {"/3 owner", fn fun, attrs -> apply(Records, fun, [attrs, schema, owner]) end}
      ]

      for {label, write} <- writers do
        created = write.(:create_record, create_attrs("fxm_free", %{"name" => "free"}))

        assert {:ok, %{record: %{record_id: record_id}}} = created,
               "#{label}: #{inspect(created)}"

        updated =
          write.(:update_record, update_attrs("fxm_free", record_id, %{"name" => "free 2"}))

        assert {:ok, %{record: %{field_values: %{"name" => "free 2"}}}} = updated,
               "#{label}: #{inspect(updated)}"

        deleted = write.(:delete_record, delete_attrs("fxm_free", record_id))
        assert {:ok, %{record: %{deleted: true}}} = deleted, "#{label}: #{inspect(deleted)}"
      end
    end
  end

  # ── T-08 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-08 (AC2): a bad authority raises before any query" do
    test "a string, a plain map, nil and an unknown atom raise FunctionClauseError on all three /3 functions",
         %{schema: schema} do
      record = owner_record!(schema, "fxm_unit")

      bad_authorities = [
        "fixture_managed",
        %{module_id: "fixture_managed", manages: MapSet.new(@seven)},
        nil,
        :owner
      ]

      calls = [
        {:create_record, create_attrs("fxm_unit", %{"name" => "x"})},
        {:update_record, update_attrs("fxm_unit", record.record_id, %{"name" => "x"})},
        {:delete_record, delete_attrs("fxm_unit", record.record_id)}
      ]

      for bad <- bad_authorities, {fun, attrs} <- calls do
        {_result, queries} =
          without_write!(schema, "#{fun} #{inspect(bad)}", fn ->
            PlatformTenantFixture.capture_repo_queries(fn ->
              assert_raise FunctionClauseError, fn ->
                apply(Records, fun, [attrs, schema, bad])
              end
            end)
          end)

        assert queries == [], "#{fun} with #{inspect(bad)} issued #{length(queries)} queries"
      end
    end
  end

  # ── T-09 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-09 (AC2): request data cannot carry ownership" do
    test "authority/owner/managed_by keys inside attrs are ignored by the /2 arities",
         %{schema: schema, owner: owner} do
      record = owner_record!(schema, "fxm_unit")
      claims = %{authority: owner, owner: owner, managed_by: "fixture_managed"}

      results =
        without_write!(schema, "attrs claims", fn ->
          [
            Records.create_record(
              Map.merge(create_attrs("fxm_unit", %{"name" => "x"}), claims),
              schema
            ),
            Records.update_record(
              Map.merge(update_attrs("fxm_unit", record.record_id, %{"name" => "x"}), claims),
              schema
            ),
            Records.delete_record(
              Map.merge(delete_attrs("fxm_unit", record.record_id), claims),
              schema
            )
          ]
        end)

      assert results == List.duplicate({:error, :entity_type_managed}, 3)
    end
  end

  # ── T-11 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-11 (AC2): a refusal costs no query beyond the definition lookup" do
    test "refused create/update/delete issue exactly the queries of get_active_definition_by_name/2",
         %{schema: schema, owner: owner} do
      record = owner_record!(schema, "fxm_unit")

      # Warm-up so any lazily cached lookup is equally warm for the baseline and the calls.
      {:ok, _} = Definitions.get_active_definition_by_name("fxm_unit", schema)

      {_def, baseline} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Definitions.get_active_definition_by_name("fxm_unit", schema)
        end)

      assert baseline != [], "the capture must see the definition lookup's own queries"
      baseline_sql = Enum.map(baseline, & &1.query)

      refused = [
        {"create",
         fn -> Records.create_record(create_attrs("fxm_unit", %{"name" => "x"}), schema) end},
        {"update",
         fn ->
           Records.update_record(
             update_attrs("fxm_unit", record.record_id, %{"name" => "x"}),
             schema
           )
         end},
        {"delete",
         fn -> Records.delete_record(delete_attrs("fxm_unit", record.record_id), schema) end}
      ]

      for {label, fun} <- refused do
        {result, queries} = PlatformTenantFixture.capture_repo_queries(fun)
        assert result == {:error, :entity_type_managed}, label
        assert Enum.map(queries, & &1.query) == baseline_sql, "#{label} issued extra queries"
      end

      # Non-vacuity: an accepted write issues strictly more queries than the lookup alone.
      {{:ok, _}, accepted} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Records.create_record(create_attrs("fxm_unit", %{"name" => "x"}), schema, owner)
        end)

      assert length(accepted) > length(baseline)
    end
  end
end
