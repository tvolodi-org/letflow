defmodule Letflow.Engine.VariableLabelsTenantScopeTest do
  @moduledoc """
  Decision 0062 R2 (GH #2616 part 1), INV-1/INV-6: `instance_projections.variable_labels` is a
  tenant-scoped column. T-2 it exists in every tenant schema (jsonb, NOT NULL, default `{}`) and
  not in `public`, labels written in one tenant are not readable through another tenant's
  prefix, a tenant that lacks the column gets it through `replay_migrations/1` with every
  existing row reading `{}`, and the replay is idempotent. T-3 a projection inserted without the
  field loads as `%{}` and `update_changeset/2` casts it.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_022_200_001
  @module Letflow.Repo.Migrations.AddVariableLabelsToInstanceProjections

  defp column(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT data_type, is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'instance_projections' " <>
          "AND column_name = 'variable_labels'",
        [schema]
      )

    rows
  end

  defp insert!(schema, attrs \\ %{}) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(
      Map.merge(
        %{
          instance_id: Ecto.UUID.generate(),
          status: :active,
          last_event_seq: 0,
          definition_id: Ecto.UUID.generate()
        },
        attrs
      )
    )
    |> Repo.insert!(prefix: schema)
  end

  test "T-2: registered in the tenant-scoped manifest" do
    assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
  end

  test "T-2: the column is in each tenant schema (jsonb, NOT NULL, default '{}') and not in public" do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-scope-a")
    b = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-scope-b")

    for t <- [a, b] do
      assert [["jsonb", "NO", default]] = column(t.schema_name)
      assert default =~ "'{}'"
    end

    assert column("public") == []
  end

  test "T-2: labels written for an instance of tenant A are read only with A's prefix" do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-iso-a")
    b = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-iso-b")

    labels = %{"x" => ["customer.salary"]}
    row = insert!(a.schema_name, %{variables: %{"x" => 1}, variable_labels: labels})

    assert Repo.get(InstanceProjection, row.instance_id, prefix: a.schema_name).variable_labels ==
             labels

    assert Repo.get(InstanceProjection, row.instance_id, prefix: b.schema_name) == nil

    # a same-id row in B carries its own (empty) labels, never A's
    other = insert!(b.schema_name, %{instance_id: row.instance_id})

    assert Repo.get(InstanceProjection, other.instance_id, prefix: b.schema_name).variable_labels ==
             %{}

    assert Repo.get(InstanceProjection, row.instance_id, prefix: a.schema_name).variable_labels ==
             labels
  end

  test "T-2: a tenant without the column gets it on replay; existing rows read {}; replay is idempotent" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-replay")
    schema = t.schema_name
    existing = insert!(schema, %{variables: %{"x" => 1}})

    Repo.query!(~s(ALTER TABLE "#{schema}"."instance_projections" DROP COLUMN variable_labels))
    Repo.query!(~s(DELETE FROM "#{schema}"."schema_migrations" WHERE version = $1), [@version])
    assert column(schema) == []

    assert {:ok, applied} = TenantProvisioning.replay_migrations(t.tenant_id)
    assert @version in applied
    assert [["jsonb", "NO", _default]] = column(schema)

    assert Repo.get(InstanceProjection, existing.instance_id, prefix: schema).variable_labels ==
             %{}

    assert {:ok, again} = TenantProvisioning.replay_migrations(t.tenant_id)
    refute @version in again
    assert [["jsonb", "NO", _default]] = column(schema)
  end

  test "T-3: a projection inserted without variable_labels loads as %{} and the update casts it" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-default")
    row = insert!(t.schema_name)

    loaded = Repo.get!(InstanceProjection, row.instance_id, prefix: t.schema_name)
    assert loaded.variable_labels == %{}

    labels = %{"y" => ["customer.ssn"]}

    {:ok, updated} =
      loaded
      |> InstanceProjection.update_changeset(%{
        status: :active,
        last_event_seq: 1,
        variable_labels: labels
      })
      |> Repo.update(prefix: t.schema_name)

    assert updated.variable_labels == labels

    assert Repo.get!(InstanceProjection, row.instance_id, prefix: t.schema_name).variable_labels ==
             labels
  end
end
