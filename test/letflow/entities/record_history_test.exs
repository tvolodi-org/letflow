defmodule Letflow.Entities.RecordHistoryTest do
  @moduledoc """
  REQ-516 S2 (GH #2701), C1: `Letflow.Entities.RecordHistory` reads one record's events from its
  type's synthetic instance, oldest first, with the payload resolved, and decides visibility
  before any page is read. The HTTP route is tested in
  `test/letflow/routers/req516_record_history_routes_test.exs`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.RecordHistory
  alias Letflow.Support.RecordHistoryFixture, as: R

  @type_name "case_file"

  setup do
    t = R.tenant!("req516-context")
    record_id = R.record!(t, %{"title" => "case", "secret" => "s3"})
    :ok = R.update!(t, record_id, %{"title" => "case", "secret" => "s4"})
    other_id = R.record!(t, %{"title" => "other", "secret" => "x1"})
    %{t: t, record_id: record_id, other_id: other_id}
  end

  describe "events_page/5" do
    test "returns the create and the update of the record, oldest first, payload resolved", %{
      t: t,
      record_id: record_id
    } do
      assert {:ok, [created, updated]} =
               RecordHistory.events_page(t.schema_name, @type_name, record_id, nil, 10)

      assert created.event_type == "ENTITY_RECORD_CREATED"
      assert updated.event_type == "ENTITY_RECORD_UPDATED"
      assert created.sequence_number < updated.sequence_number
      assert created.payload["field_values"]["secret"] == "s3"
      assert updated.payload["field_values"]["secret"] == "s4"
      assert created.payload["record_id"] == record_id
    end

    test "event_id and actor_id come back as UUID strings, not raw bytes", %{
      t: t,
      record_id: record_id
    } do
      assert {:ok, [created | _]} =
               RecordHistory.events_page(t.schema_name, @type_name, record_id, nil, 10)

      assert {:ok, _} = Ecto.UUID.cast(created.event_id)
      assert created.actor_id == t.author.id
    end

    test "after_seq returns only the rows above it", %{t: t, record_id: record_id} do
      {:ok, [created, updated]} =
        RecordHistory.events_page(t.schema_name, @type_name, record_id, nil, 10)

      assert {:ok, [only_update]} =
               RecordHistory.events_page(
                 t.schema_name,
                 @type_name,
                 record_id,
                 created.sequence_number,
                 10
               )

      assert only_update.event_id == updated.event_id
    end

    test "limit caps the rows", %{t: t, record_id: record_id} do
      assert {:ok, [created]} =
               RecordHistory.events_page(t.schema_name, @type_name, record_id, nil, 1)

      assert created.event_type == "ENTITY_RECORD_CREATED"
    end

    test "another record's events are not returned", %{
      t: t,
      record_id: record_id,
      other_id: other
    } do
      assert {:ok, rows} = RecordHistory.events_page(t.schema_name, @type_name, other, nil, 10)
      assert length(rows) == 1
      refute Enum.any?(rows, &(&1.payload["record_id"] == record_id))
    end

    test "an unknown entity type has no synthetic instance: not_found", %{t: t, record_id: id} do
      assert {:error, :not_found} =
               RecordHistory.events_page(t.schema_name, "no_such_type", id, nil, 10)
    end
  end

  describe "visible?/5" do
    test "an existing record is visible to the unscoped caller", %{
      t: t,
      record_id: record_id
    } do
      assert :ok = RecordHistory.visible?(t.author.id, @type_name, record_id, :all, t.schema_name)
    end

    test "an absent record is not_found for the unscoped caller", %{t: t} do
      assert :not_found =
               RecordHistory.visible?(
                 t.author.id,
                 @type_name,
                 Ecto.UUID.generate(),
                 :all,
                 t.schema_name
               )
    end

    test "scope :none is not_found with no lookup, even for an existing record", %{
      t: t,
      record_id: record_id
    } do
      assert :not_found =
               RecordHistory.visible?(t.author.id, @type_name, record_id, :none, t.schema_name)
    end

    test "an undeclared type is not_found for a scoped caller, whether or not the record exists",
         %{t: t, record_id: record_id} do
      # No module declares `case_file` a scope type, so the scoped branch answers :undeclared.
      assert :not_found =
               RecordHistory.visible?(
                 t.author.id,
                 @type_name,
                 record_id,
                 {:nodes, ["node-a"]},
                 t.schema_name
               )
    end
  end
end
