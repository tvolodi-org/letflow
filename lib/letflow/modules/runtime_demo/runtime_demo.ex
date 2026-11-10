defmodule Letflow.Modules.RuntimeDemo do
  @moduledoc """
  T-1641 (UAT decision B5#10): a tiny demo module `runtime_demo` that exists only so the runtime-update
  gates (decision 0055 D5 skew gate, D9 rollback) can be driven through the product's routes on QA.
  It holds no data: no entity types, no pack, no steps, no migrations, no tenant data access.

  ## Test and QA only

  The module is NOT in `config :letflow, :modules`. `config/config.exs` puts it in `:demo_modules` only when
  the build runs with `LETFLOW_INCLUDE_RUNTIME_DEMO=true` (the Docker build argument that only
  `deploy/redeploy-qa.sh` passes); `config/test.exs` lists it for CI. A default or production build
  therefore has no catalogue entry, no route mount and no install for it.

  ## Releases

  One build holds one manifest, so the "released versions" are selected at boot by
  `LETFLOW_RUNTIME_DEMO_RELEASE` (read in `config/runtime.exs` through `parse_release/1`), no second build:

  | release | version | min_upgradable_from | min_data_version |
  |---|---|---|---|
  | `0.1.0` (default) | 0.1.0 | 0.1.0 | 0.1.0 |
  | `0.2.0` | 0.2.0 | 0.1.0 | 0.1.0 |
  | `0.3.0` | 0.3.0 | 0.1.0 | 0.3.0 |

  Three are needed because "rollback succeeds" and "rollback is below the minimum" are opposite answers of
  one `min_data_version`, so they need different declared minimums. The runbook is
  `docs/runbooks/runtime-demo-module.md`.
  """

  @behaviour Letflow.Modules.Module

  @releases ["0.1.0", "0.2.0", "0.3.0"]

  @doc "The selectable release versions."
  @spec releases() :: [String.t()]
  def releases, do: @releases

  @doc """
  Parses `LETFLOW_RUNTIME_DEMO_RELEASE`: unset or blank is `"0.1.0"`, exactly one of `releases/0` is
  itself, anything else raises with a fixed message that does not echo the value.
  """
  @spec parse_release(String.t() | nil) :: String.t()
  def parse_release(nil), do: "0.1.0"

  def parse_release(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        "0.1.0"

      release when release in @releases ->
        release

      _other ->
        raise "environment variable LETFLOW_RUNTIME_DEMO_RELEASE must be one of 0.1.0, 0.2.0, 0.3.0. " <>
                "The value is not echoed."
    end
  end

  @impl true
  def manifest do
    version = Application.get_env(:letflow, :runtime_demo_release, "0.1.0")

    %{
      id: "runtime_demo",
      version: version,
      min_upgradable_from: "0.1.0",
      min_data_version: if(version == "0.3.0", do: "0.3.0", else: "0.1.0"),
      depends_on: [],
      pack: nil,
      permissions: [:RuntimeDemoRead],
      role_grants: %{},
      required_roles: [],
      settings_schema: nil,
      route_policies: [{"GET", "/ping", :RuntimeDemoRead}]
    }
  end

  @impl true
  def router, do: Letflow.Modules.RuntimeDemo.Router
end
