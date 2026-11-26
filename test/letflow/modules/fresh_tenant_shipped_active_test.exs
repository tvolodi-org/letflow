Code.require_file("assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.FreshTenantShippedActiveTest do
  @moduledoc """
  T-2724 (pilot gap G14): a fresh tenant has an EMPTY outbound allow-list (deny by
  default). Installing the process-shipping modules (assets, maintenance, stock)
  through the real install route must still leave EVERY shipped process definition
  of those packs ACTIVE, with no channel opened beforehand. The expected set is read
  from each `priv/modules/*/pack.json`, not from a literal.

  Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Installs
  alias Letflow.OutboundDestinations

  @modules ~w(assets maintenance stock)

  defp shipped(module_id) do
    "priv/modules/#{module_id}/pack.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("definitions")
    |> Enum.map(& &1["process_key"])
    |> Enum.sort()
  end

  test "FT-1: empty allow-list, install assets + maintenance + stock: every shipped process is ACTIVE" do
    fx = Fx.installed_tenant!("t2724-ship")
    Fx.install_module!(fx.tenant_id, "maintenance")
    schema = fx.schema_name

    # a module's process definitions are created and switched on by the ensure-seeds
    # step (the boot repair / admin request), see Letflow.Modules.EnsureSeeds
    for module_id <- @modules do
      assert {:ok, _report} =
               Installs.ensure_module_seeds(module_id, Ecto.UUID.generate(), "T-2724 test",
                 prefix: schema
               )
    end

    # the premise: nothing was opened
    assert {:ok, []} = OutboundDestinations.list(schema)

    expected = @modules |> Enum.flat_map(&shipped/1) |> Enum.sort()
    assert length(expected) == 18

    active =
      Repo.all(
        from(p in ProcessDefinition, where: p.status == :active, select: p.name),
        prefix: schema
      )
      |> Enum.sort()

    assert expected -- active == []
    assert {:ok, []} = OutboundDestinations.list(schema)
  end
end
