defmodule Letflow.Entities.RecordsTriggerKeyTest do
  @moduledoc """
  REQ-628 slice T-4 part A / GH #3507 criterion 5: the `record_trigger:` idempotency-key family is
  reserved for the trigger worker. Test ids follow the design: E1-E3 (the single-command entry
  points), E4 (a request's body key never equals a worker key), E7 (the server-prefix pins).
  `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Records
  alias Letflow.Idempotency
  alias Letflow.RecordTriggerRunFixture, as: R

  @lineage %{depth: 0, chain: []}

  setup do
    schema = R.tenant!("r628k")
    id = R.record!(schema, R.type_a(), %{"label" => "L1", "note" => "N1"})
    {:ok, schema: schema, id: id}
  end

  defp attrs(key, extra \\ %{}),
    do:
      Map.merge(
        %{
          entity_type: R.type_a(),
          field_values: %{"label" => "new"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: key
        },
        extra
      )

  describe "E1: refused without a lineage, before any write" do
    test "create, update, upsert and delete", %{schema: s, id: id} do
      key = "record_trigger:#{Ecto.UUID.generate()}:0"
      upd = attrs(key, %{record_id: id})
      ups = attrs(key, %{external_ref: %{"system" => "erp", "id" => "1"}})
      before = R.count(s, R.type_a())

      assert Records.create_record(attrs(key), s) == {:error, :reserved_idempotency_key}
      assert Records.create_record(attrs(key), s, :tenant) == {:error, :reserved_idempotency_key}

      assert Records.create_record(attrs(key), s, :tenant, trigger_lineage: nil) ==
               {:error, :reserved_idempotency_key}

      assert Records.update_record(upd, s) == {:error, :reserved_idempotency_key}
      assert Records.update_record(upd, s, :tenant) == {:error, :reserved_idempotency_key}

      assert Records.update_record(upd, s, :tenant, trigger_lineage: nil) ==
               {:error, :reserved_idempotency_key}

      assert Records.upsert_record_by_external_ref(ups, s) == {:error, :reserved_idempotency_key}

      assert Records.upsert_record_by_external_ref(ups, s, :tenant, trigger_lineage: nil) ==
               {:error, :reserved_idempotency_key}

      assert Records.delete_record(
               %{
                 entity_type: R.type_a(),
                 record_id: id,
                 idempotency_key: key,
                 actor_id: upd.actor_id
               },
               s
             ) == {:error, :reserved_idempotency_key}

      assert R.count(s, R.type_a()) == before
      assert R.fields(s, R.type_a(), id)["label"] == "L1"
    end
  end

  describe "E2: accepted with a lineage" do
    test "create, update and upsert", %{schema: s, id: id} do
      key = "record_trigger:#{Ecto.UUID.generate()}:"

      assert {:ok, %{is_duplicate: false}} =
               Records.create_record(attrs(key <> "0"), s, :tenant, trigger_lineage: @lineage)

      assert {:ok, %{is_duplicate: false}} =
               Records.update_record(
                 attrs(key <> "1", %{record_id: id, field_values: %{"label" => "u"}}),
                 s,
                 :tenant,
                 trigger_lineage: @lineage
               )

      assert {:ok, %{outcome: :created}} =
               Records.upsert_record_by_external_ref(
                 attrs(key <> "2", %{external_ref: %{"system" => "erp", "id" => "1"}}),
                 s,
                 :tenant,
                 trigger_lineage: @lineage
               )
    end
  end

  describe "E3: the neighbours" do
    test "sys:step: is still refused; record_trigger without a colon is a plain key", %{
      schema: s
    } do
      assert Records.create_record(attrs("sys:step:x"), s, :tenant, trigger_lineage: @lineage) ==
               {:error, :reserved_idempotency_key}

      assert {:ok, _} = Records.create_record(attrs("record_trigger"), s, :tenant)
    end
  end

  describe "E4: a request's body key" do
    test "is stored under the caller family, so it never equals a worker key" do
      actor = Ecto.UUID.generate()

      assert {:ok, %{key: key}} =
               Idempotency.from_body(%{"idempotency_key" => "record_trigger:x:0"}, :rec, actor)

      assert key == "client:rec:#{actor}:record_trigger:x:0"
    end
  end

  describe "E7: server-prefix pins" do
    test "record_trigger: is a server prefix" do
      assert "record_trigger:" in Idempotency.server_prefixes()
    end
  end
end
