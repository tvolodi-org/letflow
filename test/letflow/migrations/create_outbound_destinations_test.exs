defmodule Letflow.CreateOutboundDestinationsTest do
  @moduledoc """
  T-2597 (pilot gap G14): the tenant-scoped OUTBOUND ALLOW-LIST -- the table
  that holds the channels a tenant may use to reach outside itself and the
  destinations it may reach.

  The list is DENY BY DEFAULT, so the table starts empty for every tenant.

  Test ids MG-OD-1..MG-OD-3.
  """

  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateOutboundDestinations

  @version 20_261_124_100_002

  defp q(schema, sql, params), do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  defp insert_row(schema, tenant_id, channel, destination) do
    q(
      schema,
      """
      INSERT INTO S.outbound_destinations (id, tenant_id, channel, destination, inserted_by, inserted_at)
      VALUES (gen_random_uuid(), $1, $2, $3, gen_random_uuid(), now())
      """,
      [Ecto.UUID.dump!(tenant_id), channel, destination]
    )
  end

  test "MG-OD-1 registered last, down and up on a fresh tenant, the table exists after up" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2597-mig")
    schema = fx.schema_name

    assert {@version, CreateOutboundDestinations} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -1)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateOutboundDestinations,
               prefix: schema,
               log: false
             )

    assert {:error, _} = q(schema, "SELECT 1 FROM S.outbound_destinations", [])

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateOutboundDestinations,
               prefix: schema,
               log: false
             )

    assert {:ok, _} = q(schema, "SELECT 1 FROM S.outbound_destinations", [])
  end

  test "MG-OD-2 the list starts empty and the two partial indexes keep it a set" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2597-mig-idx")
    schema = fx.schema_name

    assert {:ok, %{rows: [[0]]}} = q(schema, "SELECT count(*) FROM S.outbound_destinations", [])

    # the CHANNEL row (the door) and a DESTINATION row (one address on that
    # channel) are two different entries: they coexist
    assert {:ok, _} = insert_row(schema, fx.tenant_id, "email", nil)
    assert {:ok, _} = insert_row(schema, fx.tenant_id, "email", "example.test")

    # a second door for the same channel is refused
    assert {:error, _} = insert_row(schema, fx.tenant_id, "email", nil)

    # the same destination twice is refused
    assert {:error, _} = insert_row(schema, fx.tenant_id, "email", "example.test")

    # another channel and another destination are separate entries
    assert {:ok, _} = insert_row(schema, fx.tenant_id, "file", nil)
    assert {:ok, _} = insert_row(schema, fx.tenant_id, "http", "example.test")

    # an unknown channel is refused by the check constraint
    assert {:error, _} = insert_row(schema, fx.tenant_id, "carrier-pigeon", nil)
  end

  test "MG-OD-3 outbound_destinations in expected_tenant_tables" do
    assert "outbound_destinations" in TenantFixture.expected_tenant_tables()
  end

  test "MG-OD-4 the migration lists the hosts of an already-active definition (grandfathering)" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2597-mig-gf")
    schema = fx.schema_name

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateOutboundDestinations,
               prefix: schema,
               log: false
             )

    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => "https://api.example.com/hook"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }

    definition =
      %Letflow.Definitions.ProcessDefinition{}
      |> Ecto.Changeset.change(%{
        name: "mg-gf",
        version: "1",
        status: :active,
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema)

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateOutboundDestinations,
               prefix: schema,
               log: false
             )

    assert {:ok, %{rows: rows}} =
             q(
               schema,
               "SELECT channel, destination, definition_id, reason FROM S.outbound_destinations ORDER BY destination NULLS FIRST",
               []
             )

    id = Ecto.UUID.dump!(definition.id)

    assert [
             ["http", nil, ^id, "grandfathered by G14"],
             ["http", "api.example.com", ^id, "grandfathered by G14"]
           ] = rows
  end
end
