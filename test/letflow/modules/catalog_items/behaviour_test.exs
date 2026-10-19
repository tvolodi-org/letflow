Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.BehaviourTest do
  @moduledoc """
  GH #2664 / REQ-507 AC1 and AC3 (spec `test/specs/GH-2664.md`, tests U-*, E-*, D-*, K-*):
  owner-path uniqueness, external_ref NULL semantics, idempotency and the `kind` enum of the
  two catalog types, on a real provisioned tenant with the real installed module.
  """

  use Letflow.DataCase, async: false

  import Letflow.CatalogItemsFixture

  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Modules.CatalogItems

  @types ["catalog_uom", "catalog_item"]

  setup do
    {:ok, installed_tenant!("gh2664-beh")}
  end

  defp ref(system, id), do: %{"external_ref_system" => system, "external_ref_id" => id}

  describe "AC1: uniqueness is refused by the database" do
    for type <- @types do
      test "U-#{type}: a second record with an existing code is a :unique violation on code",
           %{schema: schema} do
        type = unquote(type)
        assert {:ok, %{record: first}} = create(schema, type, values(type, "DUP", %{}))

        # Different name so only the code can collide.
        second = values(type, "DUP", %{"name" => "another"})

        assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: ["code"]}]}} =
                 create(schema, type, second)

        # A different code is accepted: the refusal is about the code, not the type.
        assert {:ok, %{record: other}} = create(schema, type, values(type, "OTHER", %{}))
        assert other.record_id != first.record_id
      end

      test "E-#{type}-null: two rows with both external_ref fields NULL are accepted",
           %{schema: schema} do
        type = unquote(type)
        assert {:ok, %{record: a}} = create(schema, type, values(type, "N-1", %{}))
        assert {:ok, %{record: b}} = create(schema, type, values(type, "N-2", %{}))
        assert a.record_id != b.record_id
        refute Map.has_key?(a.field_values, "external_ref_system")
      end

      test "E-#{type}-pair: a duplicate non-NULL pair is a :unique violation on the pair",
           %{schema: schema} do
        type = unquote(type)
        assert {:ok, _} = create(schema, type, values(type, "P-1", ref("1c", "42")))

        # Different code, so only the external_ref pair can collide.
        assert {:error,
                {:record_payload_invalid,
                 [%Violation{rule: :unique, path: ["external_ref_system", "external_ref_id"]}]}} =
                 create(schema, type, values(type, "P-2", ref("1c", "42")))

        # Same id in another system, and another id in the same system, are different pairs.
        assert {:ok, _} = create(schema, type, values(type, "P-3", ref("sap", "42")))
        assert {:ok, _} = create(schema, type, values(type, "P-4", ref("1c", "43")))
      end
    end
  end

  describe "AC1: idempotency on the owner path" do
    defp attrs(type, code, actor, key) do
      %{
        entity_type: type,
        field_values: values(type, code, %{}),
        actor_id: actor,
        idempotency_key: key
      }
    end

    for type <- @types do
      test "D-01-#{type}: same key and payload is a duplicate with the same record and sequence",
           %{schema: schema} do
        type = unquote(type)
        a = attrs(type, "IDEM", Ecto.UUID.generate(), Ecto.UUID.generate())

        assert {:ok, %{record: first, is_duplicate: false}} =
                 Records.create_record(a, schema, owner())

        assert {:ok, %{record: again, is_duplicate: true}} =
                 Records.create_record(a, schema, owner())

        assert again.record_id == first.record_id
        assert again.last_event_global_seq == first.last_event_global_seq
        assert is_integer(first.last_event_global_seq)

        # Exactly one record exists: the replay stored nothing.
        assert {:ok, %{"code" => "IDEM"}} = CatalogItems.lookup(schema, first.record_id)
      end
    end

    test "D-02: same key with a different payload and actor is :idempotency_key_reuse",
         %{schema: schema} do
      key = Ecto.UUID.generate()
      assert {:ok, _} = create(schema, "catalog_item", values("catalog_item", "K1", %{}), key)

      assert {:error, :idempotency_key_reuse} =
               create(schema, "catalog_item", values("catalog_item", "K2", %{}), key)

      # The refused payload was not stored: its code is still free.
      assert {:ok, _} = create(schema, "catalog_item", values("catalog_item", "K2", %{}))
    end

    test "D-03: same actor and key with a different payload is :idempotency_key_reuse",
         %{schema: schema} do
      actor = Ecto.UUID.generate()
      key = Ecto.UUID.generate()

      assert {:ok, _} =
               Records.create_record(attrs("catalog_uom", "D3A", actor, key), schema, owner())

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(attrs("catalog_uom", "D3B", actor, key), schema, owner())

      assert {:ok, _} = create(schema, "catalog_uom", values("catalog_uom", "D3B", %{}))
    end

    test "D-04: same key and payload from a different actor is :idempotency_key_reuse",
         %{schema: schema} do
      key = Ecto.UUID.generate()

      assert {:ok, %{record: first}} =
               Records.create_record(
                 attrs("catalog_uom", "D4A", Ecto.UUID.generate(), key),
                 schema,
                 owner()
               )

      assert {:error, :idempotency_key_reuse} =
               Records.create_record(
                 attrs("catalog_uom", "D4A", Ecto.UUID.generate(), key),
                 schema,
                 owner()
               )

      assert {:ok, %{"code" => "D4A"}} = CatalogItems.lookup(schema, first.record_id)
    end
  end

  describe "AC3: kind is required and only material or service" do
    test "K-01: kind missing is refused naming the kind field", %{schema: schema} do
      vals = Map.delete(values("catalog_item", "KM", %{}), "kind")

      assert {:error, {:record_payload_invalid, violations}} =
               create(schema, "catalog_item", vals)

      assert [%ValidationFailure{field_path: "/kind", constraint: "required"}] = violations
    end

    test "K-02: kind \"other\" is refused naming the kind field", %{schema: schema} do
      vals = values("catalog_item", "KO", %{"kind" => "other"})

      assert {:error, {:record_payload_invalid, violations}} =
               create(schema, "catalog_item", vals)

      assert [%ValidationFailure{field_path: "/kind", constraint: "enum", actual: "other"}] =
               violations
    end

    test "K-03: material and service are accepted (the refusals are about the value)",
         %{schema: schema} do
      assert {:ok, _} = create(schema, "catalog_item", values("catalog_item", "KA", %{}))

      assert {:ok, _} =
               create(
                 schema,
                 "catalog_item",
                 values("catalog_item", "KB", %{"kind" => "service"})
               )
    end

    test "K-04: a refused kind stores nothing: the code stays free", %{schema: schema} do
      assert {:error, _} =
               create(schema, "catalog_item", values("catalog_item", "KF", %{"kind" => "other"}))

      assert {:ok, _} = create(schema, "catalog_item", values("catalog_item", "KF", %{}))
    end
  end
end
