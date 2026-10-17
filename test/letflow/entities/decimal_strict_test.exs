defmodule Letflow.Entities.DecimalStrictTest do
  @moduledoc """
  GH #2654 PR-1 (design `lib/letflow/design/gh2654-decimal-exact-strings.md`, decision 0060):
  the database-backed half of `decimal_strict` --

    * write normalisation through `create_record/3`, `update_record/3` and
      `command_multi/3` (F8: stored, event, response and fingerprint carry the
      NORMALISED map; T1, T2, T7, T8);
    * the non-strict regression proof (R1, R3);
    * the activation immutability gate (F1, A1, A1b, B2) and its non-strict bypass;
    * the write-side `:recheck_definition` in `append_command/4` (A1c), driven
      deterministically: a Repo telemetry handler activates a new version inside the
      writer's own transaction right after the sequence lock, so the recheck must
      refuse (no timing, no second connection).

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.EventStore.Event
  alias Letflow.Repository.Activation
  alias Letflow.TenantFixture

  @actor "00000000-0000-0000-0000-0000000000a3"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2654-strict")
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    {:ok, schema: tenant.schema_name}
  end

  defp qty_field(overrides \\ %{}) do
    Map.merge(
      %{
        name: "qty",
        type: :decimal,
        decimal_precision: 10,
        decimal_scale: 2,
        decimal_strict: true
      },
      overrides
    )
  end

  defp title_field, do: %{name: "title", type: :string}

  defp create_def!(schema, name, fields) do
    {:ok, row} =
      Definitions.create_definition(
        %{definition: %{name: name, display_name: name, fields: fields}, created_by: @actor},
        schema
      )

    row
  end

  defp activate!(schema, name) do
    {:ok, row} = Definitions.activate_definition(name, @actor, "gh2654", schema)
    row
  end

  defp seed_type!(schema, name, fields) do
    create_def!(schema, name, fields)
    activate!(schema, name)
  end

  defp attrs(type, field_values, overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: type,
        field_values: field_values,
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp events(schema), do: Repo.all(from(e in Event, order_by: e.global_seq), prefix: schema)

  describe "strict write normalisation (T1, T2, F8, T7)" do
    test "create stores, appends and returns the SAME normalised map", %{schema: schema} do
      seed_type!(schema, "widget", [qty_field()])

      assert {:ok, %{record: record, is_duplicate: false}} =
               Records.create_record(attrs("widget", %{"qty" => "2.5"}), schema)

      assert record.field_values == %{"qty" => "2.50"}

      assert [%Latest{field_values: %{"qty" => "2.50"}}] = Repo.all(Latest, prefix: schema)
      assert [%Event{payload: payload}] = events(schema)
      assert payload["field_values"] == %{"qty" => "2.50"}

      assert {:ok, %Latest{field_values: %{"qty" => "2.50"}}} =
               Latest.get(record.record_id, "widget", schema)
    end

    test "a JSON integer is stored as a padded string; every float is refused (T2)", %{
      schema: schema
    } do
      seed_type!(schema, "widget", [qty_field()])

      assert {:ok, %{record: %{field_values: %{"qty" => "3.00"}}}} =
               Records.create_record(attrs("widget", %{"qty" => 3}), schema)

      for float <- [2.5, 3.0, 1.0e3, 0.30000000000000004] do
        assert {:error, {:record_payload_invalid, [%{field_path: "/qty", constraint: "type"}]}} =
                 Records.create_record(attrs("widget", %{"qty" => float}), schema)
      end

      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
      assert length(events(schema)) == 1
    end

    test "scale and precision are refused with the constraint name, nothing is appended", %{
      schema: schema
    } do
      seed_type!(schema, "widget", [qty_field()])

      assert {:error, {:record_payload_invalid, [%{field_path: "/qty", constraint: "scale"}]}} =
               Records.create_record(attrs("widget", %{"qty" => "2.505"}), schema)

      assert {:error, {:record_payload_invalid, [%{field_path: "/qty", constraint: "precision"}]}} =
               Records.create_record(attrs("widget", %{"qty" => "123456789.12"}), schema)

      assert events(schema) == []
    end

    test "an idempotent retry with a different spelling of the same value is a duplicate (T7)", %{
      schema: schema
    } do
      seed_type!(schema, "widget", [qty_field()])
      key = Ecto.UUID.generate()

      assert {:ok, %{record: first, is_duplicate: false}} =
               Records.create_record(
                 attrs("widget", %{"qty" => "2.5"}, %{idempotency_key: key}),
                 schema
               )

      assert {:ok, %{record: again, is_duplicate: true}} =
               Records.create_record(
                 attrs("widget", %{"qty" => "2.500"}, %{idempotency_key: key}),
                 schema
               )

      assert again.record_id == first.record_id
      assert length(events(schema)) == 1
    end

    test "update normalises too and round-trips the stored form (U1)", %{schema: schema} do
      seed_type!(schema, "widget", [qty_field(), title_field()])

      {:ok, %{record: record}} =
        Records.create_record(attrs("widget", %{"qty" => "1", "title" => "a"}), schema)

      assert {:ok, %{record: updated}} =
               Records.update_record(
                 attrs("widget", %{"qty" => "7.1", "title" => "a"}, %{record_id: record.record_id}),
                 schema
               )

      assert updated.field_values == %{"qty" => "7.10", "title" => "a"}

      # the raw stored field_values re-enter the strict path and change nothing
      assert {:ok, %{record: echoed}} =
               Records.update_record(
                 attrs("widget", updated.field_values, %{record_id: record.record_id}),
                 schema
               )

      assert echoed.field_values == updated.field_values
    end

    test "min/max/non_negative are exact on strings (T9)", %{schema: schema} do
      seed_type!(schema, "widget", [qty_field(%{min: "0.10", max: "99.99"})])

      assert {:ok, _} = Records.create_record(attrs("widget", %{"qty" => "0.10"}), schema)
      assert {:ok, _} = Records.create_record(attrs("widget", %{"qty" => "99.99"}), schema)

      assert {:error, {:record_payload_invalid, [%{constraint: "minimum"}]}} =
               Records.create_record(attrs("widget", %{"qty" => "0.09"}), schema)

      assert {:error, {:record_payload_invalid, [%{constraint: "maximum"}]}} =
               Records.create_record(attrs("widget", %{"qty" => "100.00"}), schema)
    end

    test "command_multi normalises the line's field_values (T8)", %{schema: schema} do
      seed_type!(schema, "widget", [qty_field(), title_field()])
      {:ok, _} = EntityTypeInstance.get_or_create("widget", schema)

      source =
        struct!(StepSource, %{
          kind: "process_step",
          instance_id: Ecto.UUID.generate(),
          task_id: Ecto.UUID.generate(),
          node_id: "n1",
          definition_id: Ecto.UUID.generate(),
          definition_version: "1",
          line_index: 0,
          activator_id: Ecto.UUID.generate()
        })

      command = fn qty ->
        %{
          kind: :create,
          entity_type: "widget",
          field_values: %{"qty" => qty},
          actor_id: @actor,
          source: source
        }
      end

      assert {:ok, multi} = Records.command_multi(command.("4.5"), schema, :tenant)
      assert {:ok, changes} = Repo.transaction(multi)

      assert %Latest{field_values: %{"qty" => "4.50"}} =
               changes[{:line, 0, :upsert_record_latest}]

      assert {:error, {:record_payload_invalid, [%{constraint: "type"}]}} =
               Records.command_multi(command.(4.5), schema, :tenant)
    end
  end

  describe "non-strict decimal fields are unchanged (R1, R3)" do
    test "an exam-shaped decimal(5,2) with a computed float round-trips as the same float", %{
      schema: schema
    } do
      seed_type!(schema, "score", [
        %{name: "score_pct", type: :decimal, decimal_precision: 5, decimal_scale: 2}
      ])

      assert {:ok, %{record: record}} =
               Records.create_record(attrs("score", %{"score_pct" => 66.6666}), schema)

      assert record.field_values == %{"score_pct" => 66.6666}

      assert {:ok, %Latest{field_values: %{"score_pct" => 66.6666}}} =
               Latest.get(record.record_id, "score", schema)

      # legacy: more fractional digits than the scale still pass, strings are still refused
      assert {:ok, _} = Records.create_record(attrs("score", %{"score_pct" => 2.505}), schema)

      assert {:error, {:record_payload_invalid, [%{constraint: "type"}]}} =
               Records.create_record(attrs("score", %{"score_pct" => "2.50"}), schema)
    end

    test "an explicit decimal_strict: false behaves exactly like an absent key", %{schema: schema} do
      seed_type!(schema, "score", [
        %{
          name: "v",
          type: :decimal,
          decimal_precision: 5,
          decimal_scale: 2,
          decimal_strict: false
        }
      ])

      assert {:ok, %{record: %{field_values: %{"v" => 1.5}}}} =
               Records.create_record(attrs("score", %{"v" => 1.5}), schema)
    end
  end

  describe "activation gate (F1, A1, A1b)" do
    defp flip_fields(strict?), do: [qty_field(%{decimal_strict: strict?}), title_field()]

    test "false -> true with a record is refused with the field names; the old version stays active (A1, A1b)",
         %{schema: schema} do
      old = seed_type!(schema, "widget", flip_fields(false))
      {:ok, _} = Records.create_record(attrs("widget", %{"qty" => 1.5}), schema)
      new = create_def!(schema, "widget", flip_fields(true))

      assert {:error, {:decimal_strict_change, ["qty"]}} =
               Definitions.activate_definition("widget", @actor, "flip", schema)

      # A1b: nothing committed
      assert {:ok, %EntityDefinition{id: old_id}} =
               Definitions.get_active_definition_by_name("widget", schema)

      assert old_id == old.id

      assert %{old.id => :active, new.id => :inactive} ==
               Map.new(
                 Repo.all(from(d in EntityDefinition, where: d.name == "widget"), prefix: schema),
                 &{&1.id, &1.status}
               )

      assert {:ok, %{version_id: version_id}} = Activation.resolve(:entity, "widget", schema)
      assert version_id == old.artifact_version_id
    end

    test "true -> false with a record is refused too", %{schema: schema} do
      seed_type!(schema, "widget", flip_fields(true))
      {:ok, _} = Records.create_record(attrs("widget", %{"qty" => "1.5"}), schema)
      create_def!(schema, "widget", flip_fields(false))

      assert {:error, {:decimal_strict_change, ["qty"]}} =
               Definitions.activate_definition("widget", @actor, "flip", schema)
    end

    test "a soft-deleted record still counts", %{schema: schema} do
      seed_type!(schema, "widget", flip_fields(false))
      {:ok, %{record: record}} = Records.create_record(attrs("widget", %{"qty" => 1}), schema)

      assert {:ok, _} =
               Records.delete_record(
                 %{
                   entity_type: "widget",
                   record_id: record.record_id,
                   actor_id: @actor,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      create_def!(schema, "widget", flip_fields(true))

      assert {:error, {:decimal_strict_change, ["qty"]}} =
               Definitions.activate_definition("widget", @actor, "flip", schema)
    end

    test "either direction is allowed on an empty type; a first activation is never refused", %{
      schema: schema
    } do
      seed_type!(schema, "widget", flip_fields(false))
      create_def!(schema, "widget", flip_fields(true))
      assert %EntityDefinition{} = activate!(schema, "widget")
      create_def!(schema, "widget", flip_fields(false) ++ [%{name: "note", type: :string}])
      assert %EntityDefinition{} = activate!(schema, "widget")

      seed_type!(schema, "fresh", flip_fields(true))

      assert {:ok, %EntityDefinition{}} =
               Definitions.get_active_definition_by_name("fresh", schema)
    end

    test "removing or retyping a strict field is a difference; a non-strict decimal change is not",
         %{
           schema: schema
         } do
      seed_type!(schema, "widget", [
        qty_field(),
        %{name: "other", type: :decimal, decimal_precision: 5, decimal_scale: 1},
        title_field()
      ])

      {:ok, _} = Records.create_record(attrs("widget", %{"qty" => "1"}), schema)

      create_def!(schema, "widget", [
        %{name: "other", type: :decimal, decimal_precision: 5, decimal_scale: 1},
        title_field()
      ])

      assert {:error, {:decimal_strict_change, ["qty"]}} =
               Definitions.activate_definition("widget", @actor, "removed", schema)

      create_def!(schema, "widget", [%{name: "qty", type: :string}, title_field()])

      assert {:error, {:decimal_strict_change, ["qty"]}} =
               Definitions.activate_definition("widget", @actor, "retyped", schema)

      # dropping the NON-strict decimal while the strict one stays is fine, with records present
      create_def!(schema, "widget", [qty_field(), title_field()])

      assert {:ok, %EntityDefinition{}} =
               Definitions.activate_definition("widget", @actor, "ok", schema)
    end

    test "a type with no decimal_strict key anywhere takes the old path: no instance row is inserted (A1c)",
         %{
           schema: schema
         } do
      seed_type!(schema, "plain", [title_field()])
      assert {:error, :not_found} = EntityTypeInstance.fetch_instance_id("plain", schema)

      # ... while a strict key in play takes the type's lock, which needs the instance row
      seed_type!(schema, "gated", [qty_field()])
      assert {:ok, _instance_id} = EntityTypeInstance.fetch_instance_id("gated", schema)
    end

    test "existing activation error shapes pass through the gated path unchanged (B2)", %{
      schema: schema
    } do
      assert {:error, :not_found} = Definitions.activate_definition("ghost", @actor, "x", schema)

      assert {:error, :invalid_schema_name} =
               Definitions.activate_definition("w", @actor, "x", "not a schema")
    end
  end

  describe "write-side :recheck_definition in append_command/4 (A1c)" do
    @handler "gh2654-recheck"

    # After the writer's type-sequence-lock statement, activate a NEW version inside the
    # writer's own transaction (same process, same connection), so the recheck must see
    # a pointer that no longer names the definition the write validated against.
    defp activate_after_sequence_lock!(schema, name) do
      parent = self()
      once = :atomics.new(1, [])

      :telemetry.attach(
        @handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent and String.contains?(query, "\"instance_sequence\" AS") and
               String.contains?(query, "FOR UPDATE") and :atomics.add_get(once, 1, 1) == 1 do
            {:ok, _} = Definitions.activate_definition(name, @actor, "concurrent", schema)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(@handler) end)
    end

    test "create validated before an activation and committing after it returns {:definition_changed, type}",
         %{schema: schema} do
      seed_type!(schema, "widget", [title_field()])
      create_def!(schema, "widget", [title_field(), %{name: "extra", type: :string}])
      activate_after_sequence_lock!(schema, "widget")

      assert {:error, {:definition_changed, "widget"}} =
               Records.create_record(attrs("widget", %{"title" => "x"}), schema)

      :telemetry.detach(@handler)
      assert Repo.aggregate(Latest, :count, prefix: schema) == 0
      assert events(schema) == []

      # retry is safe: it re-resolves and re-validates
      assert {:ok, %{is_duplicate: false}} =
               Records.create_record(attrs("widget", %{"title" => "x"}), schema)
    end

    test "update and delete are rechecked too", %{schema: schema} do
      seed_type!(schema, "widget", [title_field()])
      {:ok, %{record: record}} = Records.create_record(attrs("widget", %{"title" => "x"}), schema)
      create_def!(schema, "widget", [title_field(), %{name: "extra", type: :string}])
      activate_after_sequence_lock!(schema, "widget")

      assert {:error, {:definition_changed, "widget"}} =
               Records.update_record(
                 attrs("widget", %{"title" => "y"}, %{record_id: record.record_id}),
                 schema
               )

      :telemetry.detach(@handler)

      create_def!(schema, "widget", [
        title_field(),
        %{name: "extra", type: :string},
        %{name: "more", type: :string}
      ])

      activate_after_sequence_lock!(schema, "widget")

      assert {:error, {:definition_changed, "widget"}} =
               Records.delete_record(
                 %{
                   entity_type: "widget",
                   record_id: record.record_id,
                   actor_id: @actor,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )
    end
  end
end
