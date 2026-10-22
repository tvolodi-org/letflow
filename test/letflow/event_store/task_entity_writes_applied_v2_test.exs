defmodule Letflow.EventStore.TaskEntityWritesAppliedV2Test do
  @moduledoc """
  GH #2590 / REQ-501 PR R4a (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  4.11, F-1, N-1; section 11 row "Event schema v2"): the platform seed of
  `TASK_ENTITY_WRITES_APPLIED` is bumped IN PLACE from `schema_version: 1` to `2`. v2 is v1's
  closed line-item schema plus three keys (all or none, GH #2671) (`handler_module`, `handler_name`,
  `write_ordinal`) that name the module handler that produced a line.

    * a fresh tenant holds exactly one row for the type, at version 2;
    * every v1 payload is also a valid v2 payload (stored v1 events still validate), the
      handler keys are accepted, and an unknown line key is still refused;
    * REPLAY TWICE: a replay of a fresh tenant is a no-op (no
      `:schema_version_not_monotonic`), and so is a second replay after the upgrade;
    * an EXISTING tenant that lacks v2 (seeded at v1) gains v2 on replay and keeps v1, the
      highest version wins for validation, and a second replay is again a no-op;
    * the seed holds a single entry for the type (a v1 entry kept beside v2 would fail the
      replay of a tenant already at v2).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @applied "TASK_ENTITY_WRITES_APPLIED"

  defp rows(schema) do
    EventType
    |> where([t], t.name == ^@applied)
    |> select([t], t.schema_version)
    |> order_by([t], asc: t.schema_version)
    |> Repo.all(prefix: schema)
  end

  defp line(extra \\ %{}) do
    Map.merge(
      %{
        "line_index" => 0,
        "entity_type" => "invoice",
        "record_id" => Ecto.UUID.generate(),
        "event_global_seq" => 42
      },
      extra
    )
  end

  defp payload(lines) do
    %{
      "node_id" => "task_1",
      "task_id" => Ecto.UUID.generate(),
      "dispatch_id" => nil,
      "lines_hash" => String.duplicate("a", 64),
      "lines" => lines
    }
  end

  defp validate(payload, tenant_id),
    do: Registry.validate_payload(@applied, Jason.encode!(payload), tenant_id)

  # The v1 schema, as it was seeded before R4a: the seeded v2 row without the three handler keys.
  defp v1_attrs(schema) do
    v2 = Repo.one!(from(t in EventType, where: t.name == ^@applied), prefix: schema)

    item_path = ["properties", "lines", "items", "properties"]

    v1_schema =
      update_in(
        v2.json_schema,
        item_path,
        &Map.drop(&1, ["handler_module", "handler_name", "write_ordinal", "dependentRequired"])
      )

    %{
      name: @applied,
      schema_version: 1,
      description: v2.description,
      json_schema: v1_schema
    }
  end

  test "a fresh tenant has exactly one row, at version 2 (the seed holds a single entry)" do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-v2-fresh")
    assert rows(schema) == [2]
  end

  describe "v2 payloads" do
    setup do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-v2-pay")
      %{tenant_id: tenant_id}
    end

    test "every v1 payload is also valid; the handler keys are accepted", %{tenant_id: tenant_id} do
      assert :ok = validate(payload([line()]), tenant_id)
      assert :ok = validate(payload([]), tenant_id)

      handler_line =
        line(%{
          "handler_module" => "fixture_ledger",
          "handler_name" => "post_entry",
          "write_ordinal" => 2
        })

      assert :ok = validate(payload([line(), handler_line]), tenant_id)
    end

    test "the handler keys come together: a lone key is refused, the full triple and none pass",
         %{tenant_id: tenant_id} do
      triple = %{
        "handler_module" => "fixture_ledger",
        "handler_name" => "post_entry",
        "write_ordinal" => 1
      }

      assert :ok = validate(payload([line(triple)]), tenant_id)
      assert :ok = validate(payload([line()]), tenant_id)

      assert {:error, {:payload_validation_failed, [_ | _] = failures}} =
               validate(payload([line(%{"handler_module" => "fixture_ledger"})]), tenant_id)

      assert Enum.all?(failures, &(&1.constraint == "required"))
      assert length(failures) == 2

      for key <- Map.keys(triple) do
        assert {:error, {:payload_validation_failed, [_ | _]}} =
                 validate(payload([line(Map.take(triple, [key]))]), tenant_id)

        assert {:error, {:payload_validation_failed, [_ | _]}} =
                 validate(payload([line(Map.delete(triple, key))]), tenant_id)
      end
    end

    test "an unknown line key is still refused; the handler keys are typed", %{
      tenant_id: tenant_id
    } do
      assert {:error, {:payload_validation_failed, [%{constraint: "additionalProperties"}]}} =
               validate(payload([line(%{"value" => "secret"})]), tenant_id)

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(payload([line(%{"write_ordinal" => 0})]), tenant_id)

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(payload([line(%{"handler_name" => 5})]), tenant_id)

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate(payload([line(%{"handler_module" => nil})]), tenant_id)
    end
  end

  describe "replay" do
    test "replaying a fresh tenant twice is a no-op" do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-v2-twice")

      assert rows(schema) == [2]
      assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
      assert rows(schema) == [2]
      assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
      assert rows(schema) == [2]
    end

    test "an existing tenant seeded at v1 gains v2 on replay, keeps v1, and replays again" do
      %{tenant_id: tenant_id, schema_name: schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-v2-old")

      # the tenant as it was provisioned BEFORE R4a: only the v1 row
      v1 = v1_attrs(schema)
      {1, _} = Repo.delete_all(from(t in EventType, where: t.name == ^@applied), prefix: schema)
      assert {:ok, _} = Registry.register_type(v1, tenant_id)
      assert rows(schema) == [1]

      handler_line =
        line(%{
          "handler_module" => "fixture_ledger",
          "handler_name" => "post_entry",
          "write_ordinal" => 1
        })

      # at v1 the handler keys are refused (the defect the bump closes)
      assert {:error, {:payload_validation_failed, failures}} =
               validate(payload([handler_line]), tenant_id)

      assert length(failures) == 3
      assert Enum.all?(failures, &(&1.constraint == "additionalProperties"))

      # ... the replay reaches this tenant: v2 is inserted beside v1 (version > max)
      assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
      assert rows(schema) == [1, 2]
      assert :ok = validate(payload([handler_line]), tenant_id)
      assert :ok = validate(payload([line()]), tenant_id)

      # the second replay is a no-op: no :schema_version_not_monotonic, no extra row
      assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
      assert rows(schema) == [1, 2]
    end
  end
end
