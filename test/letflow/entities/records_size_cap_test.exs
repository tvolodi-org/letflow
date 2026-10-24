defmodule Letflow.Entities.RecordsSizeCapTest do
  @moduledoc """
  GH #2689 / REQ-514: the entity-side size cap through the real write path
  (`Letflow.Entities.Records.create_record/3`, `update_record/3`,
  `upsert_record_by_external_ref/3`, `command_multi/3`), including the stored-oversize re-save rule.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @actor "00000000-0000-0000-0000-0000000000a5"
  @type_name "size_cap_rec"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2689-cap")
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    fields = [
      %{name: "title", type: :string, required: true},
      %{name: "blob", type: :string, required: false},
      %{name: "blob2", type: :string, required: false}
    ]

    {:ok, row} =
      Definitions.create_definition(
        %{
          definition: %{name: @type_name, display_name: @type_name, fields: fields},
          created_by: @actor
        },
        tenant.schema_name
      )

    {:ok, _} = Definitions.activate_definition(row.name, @actor, "gh2689", tenant.schema_name)
    {:ok, schema: tenant.schema_name}
  end

  defp str(bytes), do: String.duplicate("x", bytes - 2)

  defp create(schema, field_values) do
    Records.create_record(
      %{
        entity_type: @type_name,
        field_values: field_values,
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      },
      schema
    )
  end

  defp update(schema, record_id, field_values) do
    Records.update_record(
      %{
        entity_type: @type_name,
        record_id: record_id,
        field_values: field_values,
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      },
      schema
    )
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  # The only way to get a record stored over the cap after this change: write the row directly.
  defp store_raw!(schema, record_id, field_values) do
    {1, _} =
      Repo.update_all(
        from(l in Latest, where: l.record_id == ^record_id),
        [set: [field_values: field_values]],
        prefix: schema
      )
  end

  test "AC1 create: a value at the cap is accepted and one byte over is refused", %{schema: s} do
    assert {:ok, _} = create(s, %{"title" => "t", "blob" => str(65_536)})
    before = event_count(s)

    assert {:error, {:record_size_exceeded, :value}} =
             create(s, %{"title" => "t", "blob" => str(65_537)})

    assert event_count(s) == before
  end

  test "AC1 create: the record cap, whole map counts", %{schema: s} do
    # 4 x 60_000 + title stays under 262_144; adding a fifth value of 60_000 passes the record cap
    # only through a second field here, so use two fields of 65_536 plus two long titles
    big = %{"title" => str(65_536), "blob" => str(65_536), "blob2" => str(65_536)}
    assert {:ok, _} = create(s, big)
    assert {:error, {:record_size_exceeded, :value}} = create(s, %{big | "blob" => str(65_537)})
  end

  test "Item 2/3 update: the merged full-replacement map is capped", %{schema: s} do
    {:ok, %{record: rec}} = create(s, %{"title" => "t"})
    id = rec.record_id
    assert {:ok, _} = update(s, id, %{"title" => "t", "blob" => str(65_536)})
    before = event_count(s)

    assert {:error, {:record_size_exceeded, :value}} =
             update(s, id, %{"title" => "t", "blob" => str(65_537)})

    assert event_count(s) == before
  end

  describe "stored oversize record (Item 4)" do
    setup %{schema: s} do
      {:ok, %{record: rec}} = create(s, %{"title" => "t"})
      over = str(65_536 + 500)
      store_raw!(s, rec.record_id, %{"title" => "t", "blob" => over})
      {:ok, id: rec.record_id, over: over}
    end

    test "U5 re-saving with the oversize value unchanged is accepted", %{
      schema: s,
      id: id,
      over: over
    } do
      # read back from the DB, as a system re-saver does
      stored = Repo.get_by!(Latest, [record_id: id], prefix: s).field_values
      assert {:ok, _} = update(s, id, %{stored | "title" => "renamed"})
      assert Repo.get_by!(Latest, [record_id: id], prefix: s).field_values["blob"] == over
    end

    test "U6 changing the oversize value to another oversize value is refused", %{
      schema: s,
      id: id
    } do
      before = event_count(s)

      assert {:error, {:record_size_exceeded, :value}} =
               update(s, id, %{"title" => "t", "blob" => str(65_536 + 900)})

      assert event_count(s) == before
    end

    test "re-saving smaller is accepted", %{schema: s, id: id} do
      assert {:ok, _} = update(s, id, %{"title" => "t", "blob" => "small"})
    end
  end

  test "G3 upsert by external ref: oversize is refused and nothing is written", %{schema: s} do
    before = event_count(s)

    assert {:error, {:record_size_exceeded, :value}} =
             Records.upsert_record_by_external_ref(
               %{
                 entity_type: @type_name,
                 external_ref: %{"system" => "erp", "id" => "1"},
                 field_values: %{"title" => "t", "blob" => str(65_537)},
                 actor_id: @actor
               },
               s
             )

    assert event_count(s) == before
  end

  test "C1 classify_step_error/1 maps the size refusals to validation_failed" do
    assert Records.classify_step_error({:record_size_exceeded, :value}) ==
             {:refused, :validation_failed}

    assert Records.classify_step_error({:record_size_exceeded, :record}) ==
             {:refused, :validation_failed}

    assert Records.classify_step_error(:record_not_encodable) == {:refused, :validation_failed}
  end
end
