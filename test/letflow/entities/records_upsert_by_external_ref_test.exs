defmodule Letflow.Entities.RecordsUpsertByExternalRefTest do
  @moduledoc """
  GH #2659 / REQ-505 PR-2 (design `lib/letflow/design/gh2659-external-ref-idempotent-import.md`
  sections 3, 4, 5.3.1, 9 and 10; decisions 0057, 0060, 0061): the DOMAIN half of the idempotent
  upsert -- `Letflow.Entities.Records.upsert_record_by_external_ref/2,3`.

    * T1 (domain): same ref twice -> `created` then `unchanged` (no event, version untouched);
      a changed value -> `updated` with one UPDATED event that carries no ref; an `append_only`
      type: identical -> `unchanged`, different -> `entity_append_only`; a soft-deleted ref ->
      `external_ref_record_deleted`, nothing appended.
    * T3: two systems with the same id are two records; the same pair in two entity types too.
    * T5: concurrent upserts of one ref leave ONE record. Forced overlap through
      `Letflow.LockOrderHelpers` (a third connection holds the type's sequence row; the loser of
      the unique index converges); the update branch loses on the version check and retries;
      retry exhaustion (a trigger that always raises the index's unique violation) ends in
      `external_ref_contention` after exactly 3 attempts and never echoes the ref.
    * T6: the same triple in two tenants is two records, one per schema.
    * T7 (module caller): `Owner` authority writes a managed type, `:tenant` is refused; a
      caller-chosen idempotency key replays as `unchanged` / `idempotency_key_reuse`; a 255 byte
      id with the derived-key shape is accepted.
    * T11: strict decimals compare after normalisation (`"12.5"` then `"12.50"` is `unchanged`).

  Real Postgres, real commits and several connections: `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @actor "00000000-0000-0000-0000-0000000000a5"
  @index "entity_record_latest_external_ref_idx"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-ups")
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    H.attach_error_handler(__MODULE__)
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp seed_type!(schema, name, fields \\ nil, extra \\ %{}) do
    fields = fields || [%{name: "customer_name", type: :string, required: true}]

    {:ok, row} =
      Definitions.create_definition(
        %{
          definition: Map.merge(%{name: name, display_name: name, fields: fields}, extra),
          created_by: @actor
        },
        schema
      )

    {:ok, _} = Definitions.activate_definition(row.name, @actor, "gh2659", schema)
    :ok
  end

  defp ref(system, id), do: %{"system" => system, "id" => id}

  defp attrs(type, system, id, field_values, overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: type,
        external_ref: ref(system, id),
        field_values: field_values,
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp name(value), do: %{"customer_name" => value}

  defp events(schema), do: Repo.all(from(e in Event, order_by: e.global_seq), prefix: schema)

  defp rows(schema), do: Repo.all(from(l in Latest, order_by: l.inserted_at), prefix: schema)

  defp event_types(schema), do: Enum.map(events(schema), & &1.event_type)

  # ---- T1 (domain) ---------------------------------------------------------------------------

  describe "T1: created / unchanged / updated" do
    test "the same ref twice: created, then unchanged with no event and no version bump", %{
      schema: schema
    } do
      seed_type!(schema, "customer")

      assert {:ok, %{outcome: :created, is_duplicate: false, record: created}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "42", name("Acme")),
                 schema
               )

      assert created.external_system == "sap"
      assert created.external_id == "42"
      assert [%Event{event_type: "ENTITY_RECORD_CREATED", payload: payload}] = events(schema)
      assert payload["external_ref"] == %{"system" => "sap", "id" => "42"}

      assert {:ok, %{outcome: :unchanged, is_duplicate: false, record: same}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "42", name("Acme")),
                 schema
               )

      assert same.record_id == created.record_id
      assert same.last_event_global_seq == created.last_event_global_seq
      assert same.entity_def_version == created.entity_def_version
      assert length(events(schema)) == 1
      assert [%Latest{record_id: id}] = rows(schema)
      assert id == created.record_id
    end

    test "a changed value is updated: one UPDATED event without the ref, still one row", %{
      schema: schema
    } do
      seed_type!(schema, "customer")

      {:ok, %{record: created}} =
        Records.upsert_record_by_external_ref(
          attrs("customer", "sap", "42", name("Acme")),
          schema
        )

      assert {:ok, %{outcome: :updated, is_duplicate: false, record: updated}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "42", name("Acme 2")),
                 schema
               )

      assert updated.record_id == created.record_id
      assert updated.field_values == name("Acme 2")
      assert updated.last_event_global_seq > created.last_event_global_seq
      assert updated.external_system == "sap" and updated.external_id == "42"
      assert event_types(schema) == ["ENTITY_RECORD_CREATED", "ENTITY_RECORD_UPDATED"]
      refute Map.has_key?(Enum.at(events(schema), 1).payload, "external_ref")
      assert length(rows(schema)) == 1
    end

    test "append_only: identical re-run is unchanged, a differing value is refused", %{
      schema: schema
    } do
      seed_type!(schema, "ledger", nil, %{append_only: true})

      assert {:ok, %{outcome: :created}} =
               Records.upsert_record_by_external_ref(
                 attrs("ledger", "sap", "1", name("A")),
                 schema
               )

      assert {:ok, %{outcome: :unchanged}} =
               Records.upsert_record_by_external_ref(
                 attrs("ledger", "sap", "1", name("A")),
                 schema
               )

      assert {:error, {:entity_append_only, "ledger"}} =
               Records.upsert_record_by_external_ref(
                 attrs("ledger", "sap", "1", name("B")),
                 schema
               )

      assert length(events(schema)) == 1
    end

    test "a soft-deleted ref is refused with a constant error and nothing is appended", %{
      schema: schema
    } do
      seed_type!(schema, "customer")

      {:ok, %{record: created}} =
        Records.upsert_record_by_external_ref(
          attrs("customer", "sap", "42", name("Acme")),
          schema
        )

      {:ok, _} =
        Records.delete_record(
          %{
            entity_type: "customer",
            record_id: created.record_id,
            actor_id: @actor,
            idempotency_key: Ecto.UUID.generate()
          },
          schema
        )

      before = length(events(schema))

      assert {:error, {:external_ref_record_deleted, %{system: "sap", id: "42"}}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "42", name("Acme 3")),
                 schema
               )

      assert length(events(schema)) == before
      assert [%Latest{deleted: true}] = rows(schema)
    end

    test "refusals before any write: bad ref, unknown type, invalid payload, reserved input", %{
      schema: schema
    } do
      seed_type!(schema, "customer")

      for bad <- [
            nil,
            %{},
            %{system: "sap", id: "1"},
            %{"system" => "SAP", "id" => "1"},
            %{"system" => "sap", "id" => ""},
            %{"system" => "sap", "id" => "1", "x" => 1},
            %{"system" => "sap", "id" => 1}
          ] do
        assert {:error, :external_ref_invalid} =
                 Records.upsert_record_by_external_ref(
                   Map.put(attrs("customer", "sap", "1", name("A")), :external_ref, bad),
                   schema
                 )
      end

      assert {:error, :external_ref_invalid} =
               Records.upsert_record_by_external_ref(
                 Map.delete(attrs("customer", "sap", "1", name("A")), :external_ref),
                 schema
               )

      assert {:error, {:definition_not_found, "nope"}} =
               Records.upsert_record_by_external_ref(attrs("nope", "sap", "1", name("A")), schema)

      assert {:error, {:record_payload_invalid, _}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "1", %{"customer_name" => 5}),
                 schema
               )

      assert {:error, :reserved_attribute} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "1", name("A"), %{metadata: %{}}),
                 schema
               )

      assert {:error, :reserved_idempotency_key} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "1", name("A"), %{idempotency_key: "sys:step:x"}),
                 schema
               )

      assert events(schema) == []
      assert rows(schema) == []
    end
  end

  # ---- T3 ------------------------------------------------------------------------------------

  describe "T3: scope of a reference" do
    test "two systems with the same id are two independent records", %{schema: schema} do
      seed_type!(schema, "customer")

      assert {:ok, %{outcome: :created, record: a}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "1c", "42", name("One C")),
                 schema
               )

      assert {:ok, %{outcome: :created, record: b}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "42", name("Sap")),
                 schema
               )

      refute a.record_id == b.record_id

      assert {:ok, %{outcome: :updated, record: a2}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "1c", "42", name("One C 2")),
                 schema
               )

      assert a2.record_id == a.record_id

      assert {:ok, %Latest{field_values: %{"customer_name" => "Sap"}}} =
               Latest.get(b.record_id, "customer", schema)
    end

    test "the same pair in two entity types is two records", %{schema: schema} do
      seed_type!(schema, "customer")
      seed_type!(schema, "partner")

      assert {:ok, %{outcome: :created, record: a}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "7", name("A")),
                 schema
               )

      assert {:ok, %{outcome: :created, record: b}} =
               Records.upsert_record_by_external_ref(
                 attrs("partner", "sap", "7", name("A")),
                 schema
               )

      refute a.record_id == b.record_id
      assert length(rows(schema)) == 2
    end
  end

  # ---- T5 ------------------------------------------------------------------------------------

  describe "T5: concurrency" do
    test "forced overlap on create: the unique index arbitrates, the loser converges", %{
      schema: schema
    } do
      seed_type!(schema, "customer")
      # one record so the type's sequence row exists to be held
      {:ok, _} =
        Records.upsert_record_by_external_ref(attrs("customer", "sap", "seed", name("S")), schema)

      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)

      %{first: first, second: second} =
        H.forced_overlap(
          schema,
          {:sequence, instance_id},
          fn ->
            Records.upsert_record_by_external_ref(
              attrs("customer", "sap", "race", name("first")),
              schema
            )
          end,
          fn ->
            Records.upsert_record_by_external_ref(
              attrs("customer", "sap", "race", name("second")),
              schema
            )
          end
        )

      assert {:ok, %{outcome: :created, record: winner}} = first
      assert {:ok, %{outcome: :updated, record: loser}} = second
      assert winner.record_id == loser.record_id

      assert [%Latest{field_values: %{"customer_name" => "second"}}] =
               Enum.filter(rows(schema), &(&1.external_id == "race"))

      assert Enum.count(rows(schema), &(&1.external_id == "race")) == 1
    end

    test "forced overlap on create with equal values: the loser is unchanged", %{schema: schema} do
      seed_type!(schema, "customer")

      {:ok, _} =
        Records.upsert_record_by_external_ref(attrs("customer", "sap", "seed", name("S")), schema)

      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)
      before = length(events(schema))

      run = fn ->
        Records.upsert_record_by_external_ref(
          attrs("customer", "sap", "same", name("same")),
          schema
        )
      end

      %{first: first, second: second} =
        H.forced_overlap(schema, {:sequence, instance_id}, run, run)

      assert {:ok, %{outcome: :created}} = first
      assert {:ok, %{outcome: :unchanged}} = second
      assert length(events(schema)) == before + 1
    end

    test "forced overlap on update: the version check loses once, the retry converges", %{
      schema: schema
    } do
      seed_type!(schema, "customer")

      {:ok, %{record: created}} =
        Records.upsert_record_by_external_ref(attrs("customer", "sap", "9", name("v0")), schema)

      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)

      %{first: first, second: second} =
        H.forced_overlap(
          schema,
          {:sequence, instance_id},
          fn ->
            Records.upsert_record_by_external_ref(
              attrs("customer", "sap", "9", name("v1")),
              schema
            )
          end,
          fn ->
            Records.upsert_record_by_external_ref(
              attrs("customer", "sap", "9", name("v2")),
              schema
            )
          end
        )

      assert {:ok, %{outcome: :updated, record: r1}} = first
      assert {:ok, %{outcome: :updated, record: r2}} = second
      assert r1.record_id == created.record_id and r2.record_id == created.record_id

      assert event_types(schema) == [
               "ENTITY_RECORD_CREATED",
               "ENTITY_RECORD_UPDATED",
               "ENTITY_RECORD_UPDATED"
             ]

      assert [%Latest{field_values: %{"customer_name" => "v2"}}] = rows(schema)
    end

    test "two workers import the same ref set: exactly one row per ref, no error", %{
      schema: schema
    } do
      seed_type!(schema, "customer")
      refs = for n <- 1..4, do: "r#{n}"

      worker = fn tag ->
        Task.async(fn ->
          for id <- refs do
            Records.upsert_record_by_external_ref(
              attrs("customer", "sap", id, name("w#{tag}")),
              schema
            )
          end
        end)
      end

      results = [worker.(1), worker.(2)] |> Enum.flat_map(&Task.await(&1, H.await_ms()))

      assert Enum.all?(
               results,
               &match?({:ok, %{outcome: o}} when o in [:created, :updated, :unchanged], &1)
             )

      assert Enum.count(results, &match?({:ok, %{outcome: :created}}, &1)) == 4
      assert length(rows(schema)) == 4
      assert rows(schema) |> Enum.map(& &1.external_id) |> Enum.sort() == Enum.sort(refs)
      refute_receive {:deadlock_detected, _}, 0
    end

    test "retry exhaustion: 3 attempts, then a constant contention error that echoes nothing", %{
      schema: schema
    } do
      seed_type!(schema, "customer")

      Repo.query!("""
      CREATE FUNCTION "#{schema}".gh2659_always_conflict() RETURNS trigger AS $$
      BEGIN
        RAISE unique_violation USING CONSTRAINT = '#{@index}', MESSAGE = 'forced';
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER gh2659_always_conflict BEFORE INSERT ON "#{schema}".entity_record_latest
      FOR EACH ROW EXECUTE FUNCTION "#{schema}".gh2659_always_conflict()
      """)

      handler = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _m, %{query: query}, pid ->
          if is_binary(query) and query =~ ~s(INSERT INTO "#{schema}"."entity_record_latest"),
            do: send(pid, :insert_attempt)
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :external_ref_contention} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "secret-id", name("A")),
                 schema
               )

      for _ <- 1..3, do: assert_received(:insert_attempt)
      refute_received :insert_attempt
      assert events(schema) == []
      assert rows(schema) == []
    end
  end

  # ---- T6 ------------------------------------------------------------------------------------

  describe "T6: tenant isolation" do
    test "the same triple in two tenants is two records; a lookup never crosses", %{schema: a} do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-ups-b")
      b = other.schema_name
      {:ok, _} = EventTypes.seed!(b)
      seed_type!(a, "customer")
      seed_type!(b, "customer")

      assert {:ok, %{outcome: :created, record: ra}} =
               Records.upsert_record_by_external_ref(attrs("customer", "sap", "42", name("A")), a)

      assert {:ok, %{outcome: :created, record: rb}} =
               Records.upsert_record_by_external_ref(attrs("customer", "sap", "42", name("B")), b)

      refute ra.record_id == rb.record_id

      assert {:ok, %{outcome: :updated}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", "42", name("A2")),
                 a
               )

      assert [%Latest{field_values: %{"customer_name" => "B"}}] = rows(b)
      assert {:error, :not_found} = Latest.get_by_external_ref("customer", "sap", "nope", b)
    end
  end

  # ---- T7 ------------------------------------------------------------------------------------

  describe "T7: caller-chosen idempotency key (module handler)" do
    test "replay of a create with the same key: unchanged; after an intervening change: reuse", %{
      schema: schema
    } do
      seed_type!(schema, "customer")
      key = Ecto.UUID.generate()
      a = attrs("customer", "sap", "42", name("Acme"), %{idempotency_key: key})

      assert {:ok, %{outcome: :created, record: created}} =
               Records.upsert_record_by_external_ref(a, schema)

      assert {:ok, %{outcome: :unchanged, is_duplicate: false}} =
               Records.upsert_record_by_external_ref(a, schema)

      {:ok, _} =
        Records.update_record(
          %{
            entity_type: "customer",
            record_id: created.record_id,
            field_values: name("Changed elsewhere"),
            actor_id: @actor,
            idempotency_key: Ecto.UUID.generate()
          },
          schema
        )

      before = length(events(schema))

      assert {:error, :idempotency_key_reuse} = Records.upsert_record_by_external_ref(a, schema)
      assert length(events(schema)) == before
    end

    test "a 255 byte id with the derived-key shape (128 bytes, far under 255) is accepted and re-runs unchanged",
         %{
           schema: schema
         } do
      seed_type!(schema, "customer")
      id = String.duplicate("x", 255)
      digest = :crypto.hash(:sha256, "sap" <> <<0>> <> id) |> Base.encode16(case: :lower)
      key = "entities-record-import:" <> Ecto.UUID.generate() <> ":ext:" <> digest
      assert byte_size(key) == 128

      assert {:ok, %{outcome: :created, record: record}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", id, name("Long"), %{idempotency_key: key}),
                 schema
               )

      assert record.external_id == id

      assert {:ok, %{outcome: :unchanged}} =
               Records.upsert_record_by_external_ref(
                 attrs("customer", "sap", id, name("Long")),
                 schema
               )
    end
  end

  describe "T7: Owner authority on a managed type" do
    setup %{schema: schema, tenant_id: tenant_id} do
      on_exit(fn ->
        Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      end)

      {:ok, _} =
        Installs.install("fixture_managed", Ecto.UUID.generate(),
          prefix: schema,
          rationale: "GH #2659 upsert test install"
        )

      {:ok, owner: ManagedTypes.owner_for!(FixtureManaged)}
    end

    test "Owner writes a managed type; :tenant (the /2 default too) is refused", %{
      schema: schema,
      owner: owner
    } do
      a = attrs("org_site", "sap", "S1", %{"name" => "Site"})

      assert {:error, :entity_type_managed} = Records.upsert_record_by_external_ref(a, schema)

      assert {:error, :entity_type_managed} =
               Records.upsert_record_by_external_ref(a, schema, :tenant)

      assert events(schema) == []

      assert {:ok, %{outcome: :created}} = Records.upsert_record_by_external_ref(a, schema, owner)

      assert {:ok, %{outcome: :unchanged}} =
               Records.upsert_record_by_external_ref(a, schema, owner)

      assert {:ok, %{outcome: :updated}} =
               Records.upsert_record_by_external_ref(
                 attrs("org_site", "sap", "S1", %{"name" => "Site 2"}),
                 schema,
                 owner
               )
    end
  end

  # ---- T11 -----------------------------------------------------------------------------------

  describe "T11: decimals compare after normalisation" do
    test "12.5 then 12.50 is unchanged; 12.51 is updated", %{schema: schema} do
      seed_type!(schema, "widget", [
        %{
          name: "qty",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: true
        }
      ])

      assert {:ok, %{outcome: :created, record: record}} =
               Records.upsert_record_by_external_ref(
                 attrs("widget", "sap", "1", %{"qty" => "12.5"}),
                 schema
               )

      assert record.field_values == %{"qty" => "12.50"}

      assert {:ok, %{outcome: :unchanged}} =
               Records.upsert_record_by_external_ref(
                 attrs("widget", "sap", "1", %{"qty" => "12.50"}),
                 schema
               )

      assert {:ok, %{outcome: :unchanged}} =
               Records.upsert_record_by_external_ref(
                 attrs("widget", "sap", "1", %{"qty" => "12.5"}),
                 schema
               )

      assert {:ok, %{outcome: :updated, record: updated}} =
               Records.upsert_record_by_external_ref(
                 attrs("widget", "sap", "1", %{"qty" => "12.51"}),
                 schema
               )

      assert updated.field_values == %{"qty" => "12.51"}
      assert length(events(schema)) == 2
    end
  end
end
