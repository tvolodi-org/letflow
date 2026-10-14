defmodule Letflow.Modules.FixtureFkPack do
  @moduledoc """
  Test-only entry module (GH 2531, decision 0052 D2/D3/D7). Its pack
  (`priv/module_fixtures/fk_pair.json`) holds two entity definitions, `fkp_parent`
  and `fkp_child`, the child with a foreign key to the parent. Its `on_install/3`
  activates and promotes both, in FK-DAG order, through
  `Letflow.Modules.EntityActivation.activate_and_promote/3`.

  It ALSO exports `on_install/2`, which only records that it was called: 0052 D3
  says a module exporting both arities runs ONLY `on_install/3`, and the test reads
  the record to pin that. Both callbacks record into the calling process's
  dictionary (install runs in the caller's process), so tests stay async-safe.

  Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  @dag_order ["fkp_parent", "fkp_child"]

  @impl true
  defmanifest(
    id: "fixture_fk_pack",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/fk_pair.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: []
  )

  @doc "The FK-DAG order this fixture activates and promotes in."
  def dag_order, do: @dag_order

  @impl true
  def on_install(_prefix, _settings) do
    Process.put({__MODULE__, :on_install_2_called}, true)
    :ok
  end

  @impl true
  def on_install(prefix, _settings, ctx) do
    Process.put({__MODULE__, :on_install_3_ctx}, ctx)
    EntityActivation.activate_and_promote(prefix, ctx, @dag_order)
  end
end

defmodule Letflow.Modules.FixtureFkPackFailing do
  @moduledoc """
  Test-only entry module (GH 2531, decision 0052 D7(b)): the same pack as
  `Letflow.Modules.FixtureFkPack`, whose `on_install/3` activates and promotes both
  types (so the definitions, tables and `REFERENCES` constraints exist inside the
  install transaction) and THEN fails. The test asserts that nothing survives the
  rollback. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  @impl true
  defmanifest(
    id: "fixture_fk_pack_failing",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/fk_pair.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: []
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    case EntityActivation.activate_and_promote(prefix, ctx, ["fkp_parent", "fkp_child"]) do
      :ok ->
        Process.put({__MODULE__, :promoted_before_failure}, true)
        {:error, :forced_after_promotion}

      {:error, _reason} = error ->
        error
    end
  end
end

defmodule Letflow.Modules.FixtureCtxRecorder do
  @moduledoc """
  Test-only entry module (GH 2531, decision 0052 D3): no pack; its `on_install/3`
  only records the `ctx` it received in the calling process's dictionary, so a
  solution-install test can show that ONE rationale reaches every module of the
  solution (`priv/solutions/fixture-activation-bundle.json`, together with
  `Letflow.Modules.FixtureFkPack`). Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_ctx_recorder",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: []
  )

  @impl true
  def on_install(_prefix, _settings, ctx) do
    Process.put({__MODULE__, :ctx}, ctx)
    :ok
  end
end
