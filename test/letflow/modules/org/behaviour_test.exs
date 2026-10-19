defmodule Letflow.Modules.Org.BehaviourTest do
  @moduledoc """
  GH #2662 / REQ-506 AC1..AC3 (spec `test/specs/GH-2662.md`, tests U-*, D-*, C-*): database
  uniqueness, owner-path idempotency and optimistic concurrency of the four org types, on a
  real provisioned tenant with the real installed module.
  """

  use Letflow.DataCase, async: false

  import Letflow.OrgFixture

  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Records
  alias Letflow.Modules.Org

  setup do
    {:ok, installed_tenant!("gh2662-beh")}
  end

  defp update_attrs(rec, vals, expected) do
    %{
      entity_type: rec.entity_type,
      record_id: rec.record_id,
      field_values: vals,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      expected_last_event_global_seq: expected
    }
  end

  describe "AC1: uniqueness is refused by the database" do
    for type <- ["org_legal_entity", "org_site", "org_unit"] do
      test "U-#{type}: a second record with an existing code is a :unique violation on code",
           %{schema: schema} do
        type = unquote(type)
        assert {:ok, %{record: first}} = create(schema, type, values(type, "DUP"))

        # Different name so only the code can collide.
        second = values(type, "DUP", %{"name" => "another"})

        assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: ["code"]}]}} =
                 create(schema, type, second)

        # A different code is accepted: the refusal is about the code, not the type.
        assert {:ok, %{record: other}} = create(schema, type, values(type, "OTHER"))
        assert other.record_id != first.record_id
      end
    end

    test "U-membership: the same (user_id, org_unit_id) pair twice is a :unique violation",
         %{schema: schema} do
      type = "org_unit_membership"
      vals = values(type, nil, %{"user_id" => "u-1", "org_unit_id" => "ou-1"})
      assert {:ok, _} = create(schema, type, vals)

      assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: path}]}} =
               create(schema, type, vals)

      assert path == ["user_id", "org_unit_id"]

      # The same user in another unit is fine.
      assert {:ok, _} = create(schema, type, %{vals | "org_unit_id" => "ou-2"})
    end
  end

  describe "AC2: idempotency on the owner path" do
    test "D-01: same key and payload is a duplicate returning the same record and sequence",
         %{schema: schema} do
      attrs = %{
        entity_type: "org_site",
        field_values: values("org_site", "IDEM"),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, %{record: first, is_duplicate: false}} =
               Records.create_record(attrs, schema, owner())

      assert {:ok, %{record: again, is_duplicate: true}} =
               Records.create_record(attrs, schema, owner())

      assert again.record_id == first.record_id
      assert again.last_event_global_seq == first.last_event_global_seq
      assert is_integer(first.last_event_global_seq)
    end

    test "D-02: same key with a different payload is :idempotency_key_reuse and writes nothing",
         %{schema: schema} do
      key = Ecto.UUID.generate()
      assert {:ok, _} = create(schema, "org_site", values("org_site", "K1"), key)

      assert {:error, :idempotency_key_reuse} =
               create(schema, "org_site", values("org_site", "K2"), key)

      # The refused payload was not stored: its code is still free.
      assert {:ok, _} = create(schema, "org_site", values("org_site", "K2"))
    end
  end

  describe "AC2 (key reuse branches, isolated)" do
    defp site_attrs(code, actor, key) do
      %{
        entity_type: "org_site",
        field_values: values("org_site", code),
        actor_id: actor,
        idempotency_key: key
      }
    end

    test "D-03: same actor and key with a different payload is :idempotency_key_reuse",
         %{schema: schema} do
      actor = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      assert {:ok, _} = Records.create_record(site_attrs("D3A", actor, key), schema, owner())

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(site_attrs("D3B", actor, key), schema, owner())

      # Nothing was stored for the refused payload.
      assert {:ok, _} = create(schema, "org_site", values("org_site", "D3B"))
    end

    test "D-04: same key and payload from a different actor is :idempotency_key_reuse",
         %{schema: schema} do
      key = Ecto.UUID.generate()

      assert {:ok, %{record: first}} =
               Records.create_record(
                 site_attrs("D4A", Ecto.UUID.generate(), key),
                 schema,
                 owner()
               )

      # `match_original/3` compares the actor before the payload (records.ex): a different
      # actor is a reuse, never a duplicate that returns the original.
      assert {:error, :idempotency_key_reuse} =
               Records.create_record(
                 site_attrs("D4A", Ecto.UUID.generate(), key),
                 schema,
                 owner()
               )

      assert {:ok, %{"code" => "D4A"}} = Org.lookup(schema, first.record_id)
    end
  end

  describe "AC3: optimistic concurrency" do
    test "C-01: update with the current sequence succeeds and advances it", %{schema: schema} do
      rec = create!(schema, "org_site", values("org_site", "CC1"))
      new_vals = values("org_site", "CC1", %{"name" => "renamed"})

      assert {:ok, %{record: updated}} =
               Records.update_record(
                 update_attrs(rec, new_vals, rec.last_event_global_seq),
                 schema,
                 owner()
               )

      assert updated.field_values["name"] == "renamed"
      assert updated.last_event_global_seq > rec.last_event_global_seq
    end

    test "C-02: update with a stale sequence is :record_version_conflict and changes nothing",
         %{schema: schema} do
      rec = create!(schema, "org_site", values("org_site", "CC2"))

      {:ok, %{record: v2}} =
        Records.update_record(
          update_attrs(
            rec,
            values("org_site", "CC2", %{"name" => "v2"}),
            rec.last_event_global_seq
          ),
          schema,
          owner()
        )

      assert {:error, :record_version_conflict} =
               Records.update_record(
                 update_attrs(
                   rec,
                   values("org_site", "CC2", %{"name" => "stale"}),
                   rec.last_event_global_seq
                 ),
                 schema,
                 owner()
               )

      assert {:ok, %{"name" => "v2"}} = Org.lookup(schema, rec.record_id)
      assert v2.last_event_global_seq > rec.last_event_global_seq
    end

    test "C-03: delete with a stale sequence is refused, with the current one it succeeds",
         %{schema: schema} do
      rec = create!(schema, "org_site", values("org_site", "CC3"))

      {:ok, %{record: v2}} =
        Records.update_record(
          update_attrs(
            rec,
            values("org_site", "CC3", %{"name" => "v2"}),
            rec.last_event_global_seq
          ),
          schema,
          owner()
        )

      delete = fn expected ->
        Records.delete_record(
          %{
            entity_type: "org_site",
            record_id: rec.record_id,
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate(),
            expected_last_event_global_seq: expected
          },
          schema,
          owner()
        )
      end

      assert {:error, :record_version_conflict} = delete.(rec.last_event_global_seq)
      assert {:ok, _} = Org.lookup(schema, rec.record_id)

      assert {:ok, %{record: %{deleted: true}}} = delete.(v2.last_event_global_seq)
      assert {:error, :not_found} = Org.lookup(schema, rec.record_id)
    end
  end
end
