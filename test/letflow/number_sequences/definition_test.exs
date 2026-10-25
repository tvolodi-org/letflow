defmodule Letflow.NumberSequences.DefinitionTest do
  @moduledoc """
  REQ-541 / GH #3160 criteria 2 and 9 (D1..D11): `NumberSequences.create_definition/2` stores the
  format of one bound entity type in the tenant schema and refuses everything else with no write.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.NumberSequences
  alias Letflow.NumberSequences.Counter
  alias Letflow.NumberSequences.Definition
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    base = Fx.committed_tenant_case!("gh3160-def")

    on_exit(fn ->
      Fx.drop_committed_tenant!(base.tenant.tenant_id)
      SandboxAutoMode.exit_auto_mode!(Repo)
    end)

    Fx.define_type!(base.schema, "ns_order", %{append_only: false})
    %{base: base}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{key: "order_no", entity_type: "ns_order", prefix: "ORD", padding: 6, period: "year"},
      overrides
    )
  end

  defp definitions(schema), do: Repo.all(Definition, prefix: schema)

  test "D1 stores key, prefix, padding, period and the tenant", %{base: base} do
    assert {:ok, %Definition{} = d} = NumberSequences.create_definition(attrs(), base.schema)

    assert {d.key, d.entity_type, d.prefix, d.padding, d.period} ==
             {"order_no", "ns_order", "ORD", 6, "year"}

    assert d.tenant_id == base.tenant.tenant_id
    assert [%Definition{id: id}] = definitions(base.schema)
    assert id == d.id
  end

  test "D1b atoms are accepted for the period", %{base: base} do
    assert {:ok, %Definition{period: "none"}} =
             NumberSequences.create_definition(attrs(%{period: :none}), base.schema)
  end

  test "D2 a managed type is refused", %{base: base} do
    :ok = Fx.install_managed_fixture!(base.schema)

    assert {:error, :entity_type_managed} =
             NumberSequences.create_definition(attrs(%{entity_type: "fxm_ledger"}), base.schema)

    assert definitions(base.schema) == []
  end

  test "D3 an append_only type is refused", %{base: base} do
    Fx.define_type!(base.schema, "ns_log", %{})

    assert {:error, {:entity_append_only, "ns_log"}} =
             NumberSequences.create_definition(attrs(%{entity_type: "ns_log"}), base.schema)

    assert definitions(base.schema) == []
  end

  test "D4 an unknown type is refused", %{base: base} do
    assert {:error, {:entity_type_not_found, "ns_nope"}} =
             NumberSequences.create_definition(attrs(%{entity_type: "ns_nope"}), base.schema)
  end

  test "D5 a duplicate key is refused", %{base: base} do
    Fx.define_type!(base.schema, "ns_other", %{append_only: false})
    assert {:ok, _} = NumberSequences.create_definition(attrs(), base.schema)

    assert {:error, %Ecto.Changeset{}} =
             NumberSequences.create_definition(attrs(%{entity_type: "ns_other"}), base.schema)

    assert length(definitions(base.schema)) == 1
  end

  test "D6 a second definition on the same type is refused", %{base: base} do
    assert {:ok, _} = NumberSequences.create_definition(attrs(), base.schema)

    assert {:error, %Ecto.Changeset{}} =
             NumberSequences.create_definition(attrs(%{key: "other"}), base.schema)

    assert length(definitions(base.schema)) == 1
  end

  for {label, prefix} <- [empty: "", long: "ABCDEFGHI", dash: "A-B"] do
    test "D7 invalid number prefix #{label}", %{base: base} do
      assert {:error, %Ecto.Changeset{}} =
               NumberSequences.create_definition(attrs(%{prefix: unquote(prefix)}), base.schema)

      assert definitions(base.schema) == []
    end
  end

  for padding <- [0, 13] do
    test "D8 padding #{padding} is refused", %{base: base} do
      assert {:error, %Ecto.Changeset{}} =
               NumberSequences.create_definition(attrs(%{padding: unquote(padding)}), base.schema)

      assert definitions(base.schema) == []
    end
  end

  test "D9 a bad period is refused", %{base: base} do
    assert {:error, %Ecto.Changeset{}} =
             NumberSequences.create_definition(attrs(%{period: "month"}), base.schema)

    assert definitions(base.schema) == []
  end

  test "D10 a tenant_id in attrs does not change the row's tenant", %{base: base} do
    other = Ecto.UUID.generate()
    assert {:ok, d} = NumberSequences.create_definition(attrs(%{tenant_id: other}), base.schema)
    assert d.tenant_id == base.tenant.tenant_id
    assert Repo.all(Counter, prefix: base.schema) == []
  end

  describe "create_definition_audited/3 (REQ-575 criteria 8, 9)" do
    defp actor, do: %{user_id: Ecto.UUID.generate(), credential: :session}
    defp audits(schema), do: Repo.all(Audit.Entry, prefix: schema)

    test "A1 stores the definition and one audit entry", %{base: base} do
      actor = actor()

      assert {:ok, %Definition{} = d} =
               NumberSequences.create_definition_audited(attrs(), actor, base.schema)

      assert {d.key, d.entity_type, d.prefix, d.padding, d.period} ==
               {"order_no", "ns_order", "ORD", 6, "year"}

      assert d.tenant_id == base.tenant.tenant_id
      assert [%Definition{id: id}] = definitions(base.schema)
      assert id == d.id

      assert [entry] = Enum.filter(audits(base.schema), &(&1.resource_id == d.id))
      assert entry.action == "number_sequence_definition.create"
      assert entry.resource_type == "number_sequence_definition"
      assert entry.actor_id == actor.user_id
      after_state = entry.after_state
      assert after_state["id"] == d.id
      assert after_state["key"] == "order_no"
      assert after_state["entity_type"] == "ns_order"
    end

    test "A2 an audit failure stores no definition and does not raise", %{base: base} do
      Repo.query!(~s(DROP TABLE "#{base.schema}".audit_entries))

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               NumberSequences.create_definition_audited(attrs(), actor(), base.schema)

      assert definitions(base.schema) == []
    end

    test "A3 refusals write no audit entry and match create_definition/2", %{base: base} do
      :ok = Fx.install_managed_fixture!(base.schema)
      Fx.define_type!(base.schema, "ns_log", %{})
      Fx.define_type!(base.schema, "ns_other", %{append_only: false})
      before_count = length(audits(base.schema))

      cases = [
        attrs(%{padding: 0}),
        attrs(%{entity_type: "fxm_ledger"}),
        attrs(%{entity_type: "ns_log"}),
        attrs(%{entity_type: "ns_nope"})
      ]

      for a <- cases do
        expected = NumberSequences.create_definition(a, base.schema)
        assert {:error, _} = expected
        got = NumberSequences.create_definition_audited(a, actor(), base.schema)

        case expected do
          {:error, %Ecto.Changeset{} = cs} ->
            assert {:error, %Ecto.Changeset{errors: errors}} = got
            assert errors == cs.errors

          other ->
            assert got == other
        end
      end

      assert {:ok, _} = NumberSequences.create_definition_audited(attrs(), actor(), base.schema)
      after_first = length(audits(base.schema))
      assert after_first == before_count + 1

      assert {:error, %Ecto.Changeset{}} =
               NumberSequences.create_definition_audited(
                 attrs(%{entity_type: "ns_other"}),
                 actor(),
                 base.schema
               )

      assert {:error, %Ecto.Changeset{}} =
               NumberSequences.create_definition_audited(
                 attrs(%{key: "other"}),
                 actor(),
                 base.schema
               )

      assert length(audits(base.schema)) == after_first
      assert length(definitions(base.schema)) == 1
    end

    test "A4 a tenant_id in attrs is ignored", %{base: base} do
      other = Ecto.UUID.generate()

      assert {:ok, d} =
               NumberSequences.create_definition_audited(
                 attrs(%{tenant_id: other}),
                 actor(),
                 base.schema
               )

      assert d.tenant_id == base.tenant.tenant_id
    end

    test "A6 every transaction and Multi insert carries the tenant prefix" do
      source = File.read!("lib/letflow/number_sequences.ex")

      for call <- ["Multi.insert(:definition", "Repo.transaction(multi"] do
        [_, rest] = String.split(source, call, parts: 2)
        assert rest |> String.slice(0, 120) =~ "prefix: schema_prefix"
      end
    end
  end

  test "D11 a definition row is never updated or deleted", %{base: base} do
    assert {:ok, d} = NumberSequences.create_definition(attrs(), base.schema)
    id = Ecto.UUID.dump!(d.id)
    table = ~s("#{base.schema}".number_sequence_definitions)

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("UPDATE #{table} SET padding = 3 WHERE id = $1", [id])

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM #{table} WHERE id = $1", [id])
  end
end
