Code.require_file("../stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.MesCore.InstallTest do
  @moduledoc """
  T-1841 (MES M1) I-01..I-03: the empty pack installs once its dependencies are in, is refused
  without them, and a second tenant is untouched. `async: false`: the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule

  @why "test: T-1841"

  setup do
    Fx.setup_auto_mode!()
    fx = Fx.tenant_fixture!()
    on_exit(fn -> Letflow.StockFixture.drop_pack_rows!(fx.tenant_id) end)
    %{fx: fx, s: fx.schema_name}
  end

  defp opts(s), do: [prefix: s, rationale: @why]

  defp installed?(schema) do
    Repo.exists?(from(m in TenantModule, where: m.module_id == "mes_core"), prefix: schema)
  end

  test "I-01: with the four dependencies installed, mes_core installs", ctx do
    for id <- ["org", "catalog_items", "locations", "codes", "stock", "mes_core"] do
      assert {:ok, _} = Installs.install(id, Ecto.UUID.generate(), opts(ctx.s))
    end

    assert installed?(ctx.s)
  end

  test "I-02: without a dependency the install is refused and installs nothing", ctx do
    assert {:error, {:dependency_not_installed, _dep}} =
             Installs.install("mes_core", Ecto.UUID.generate(), opts(ctx.s))

    refute installed?(ctx.s)
  end

  test "I-03: installing in one tenant leaves another without the module", ctx do
    other = Fx.tenant_fixture!()
    on_exit(fn -> Letflow.StockFixture.drop_pack_rows!(other.tenant_id) end)

    for id <- ["org", "catalog_items", "locations", "codes", "stock", "mes_core"] do
      assert {:ok, _} = Installs.install(id, Ecto.UUID.generate(), opts(ctx.s))
    end

    refute installed?(other.schema_name)
  end
end
