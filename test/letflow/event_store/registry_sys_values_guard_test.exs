defmodule Letflow.EventStore.RegistrySysValuesGuardTest do
  @moduledoc """
  GH #2621 (design `lib/letflow/design/gh2621-sys-value-types.md` D-2, D-9, D-10): the code
  guard `Registry.validate_payload/3` runs for `INSTANCE_SYS_VARIABLES_SET` after the schema
  step, through all three append entry points. No `schema_version` bump, no seed change.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture

  @sys "INSTANCE_SYS_VARIABLES_SET"

  setup do
    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2621-guard")

    %{tenant_id: tenant_id, schema: schema}
  end

  defp payload(values),
    do: %{"node_id" => "t1", "cause" => "entity_writes", "values" => values}

  defp validate(values, tenant_id),
    do: Registry.validate_payload(@sys, Jason.encode!(payload(values)), tenant_id)

  defp failures({:error, {:payload_validation_failed, failures}}), do: failures

  defp attrs(instance_id) do
    %{
      instance_id: instance_id,
      event_type: @sys,
      payload: Jason.encode!(payload(%{"_sys.r" => "not-a-uuid"})),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: "gh2621-#{System.unique_integer([:positive])}"
    }
  end

  defp row_counts(schema) do
    {Repo.aggregate(Event, :count, prefix: schema),
     Repo.aggregate(IdempotencyRecord, :count, prefix: schema)}
  end

  test "the registered schema_version and the seed row are unchanged (no bump)", %{schema: schema} do
    assert [{@sys, 1}] =
             Repo.all(
               from(t in EventType,
                 where: t.name == ^@sys,
                 select: {t.name, t.schema_version}
               ),
               prefix: schema
             )
  end

  test "a valid id/seq pair is accepted", %{tenant_id: tenant_id} do
    assert :ok = validate(%{"_sys.r" => Ecto.UUID.generate(), "_sys.r.seq" => 7}, tenant_id)
  end

  test "exactly 40 keys is accepted, 41 is refused with one count failure", %{tenant_id: t} do
    ok =
      Enum.reduce(0..19, %{}, fn i, acc ->
        acc |> Map.put("_sys.l#{i}", Ecto.UUID.generate()) |> Map.put("_sys.l#{i}.seq", i)
      end)

    assert map_size(ok) == 40
    assert :ok = validate(ok, t)

    over = Map.put(ok, "_sys.extra", Ecto.UUID.generate())

    assert [%{constraint: "sys_values_count", field_path: "/values", actual: nil}] =
             failures(validate(over, t))

    # 41 invalid keys: still only the count failure (the per-pair pass is skipped).
    all_bad = Map.new(0..40, fn i -> {"bad#{i}", -1} end)
    assert [%{constraint: "sys_values_count"}] = failures(validate(all_bad, t))
  end

  test "unknown key shapes are sys_key_shape, actual nil", %{tenant_id: t} do
    for key <- ["extra", "_sys.a.b", "_sys"] do
      assert [%{constraint: "sys_key_shape", field_path: path, actual: nil}] =
               failures(validate(%{key => Ecto.UUID.generate()}, t))

      assert path == "/values/" <> key
    end
  end

  test "bad value types are sys_value_type, actual nil", %{tenant_id: t} do
    uuid = Ecto.UUID.generate()

    for values <- [
          %{"_sys.r" => "not-a-uuid"},
          %{"_sys.r" => String.upcase(uuid)},
          %{"_sys.r" => 7},
          %{"_sys.r.seq" => -1},
          %{"_sys.r.seq" => 7.5},
          %{"_sys.r.seq" => "7"}
        ] do
      assert [%{constraint: "sys_value_type", actual: nil}] = failures(validate(values, t))
    end
  end

  test "a key with / and ~ is RFC 6901 escaped in the field path", %{tenant_id: t} do
    assert [%{field_path: "/values/a~1b~0c"}] = failures(validate(%{"a/b~c" => 1}, t))
  end

  test "another event type is not guarded", %{tenant_id: t} do
    assert {:error, {:payload_validation_failed, fs}} =
             Registry.validate_payload("TASK_ENTITY_WRITES_APPLIED", Jason.encode!(%{}), t)

    refute Enum.any?(fs, &(&1.constraint in ["sys_key_shape", "sys_value_type"]))
  end

  describe "all three append entry points refuse and write nothing" do
    test "append/2", %{schema: schema} do
      before = row_counts(schema)

      assert {:error, {:payload_validation_failed, [%{constraint: "sys_value_type"}]}} =
               EventStore.append(attrs(Ecto.UUID.generate()), prefix: schema)

      assert row_counts(schema) == before
    end

    test "append_platform_event/2", %{schema: schema} do
      before = row_counts(schema)

      assert {:error, {:payload_validation_failed, [%{constraint: "sys_value_type"}]}} =
               EventStore.append_platform_event(attrs(EventStore.platform_instance_id()),
                 prefix: schema
               )

      assert row_counts(schema) == before
    end

    test "append_multi/3", %{schema: schema} do
      before = row_counts(schema)

      assert {:error, {:payload_validation_failed, [%{constraint: "sys_value_type"}]}} =
               EventStore.append_multi(Multi.new(), attrs(Ecto.UUID.generate()), prefix: schema)

      assert row_counts(schema) == before
    end
  end
end
