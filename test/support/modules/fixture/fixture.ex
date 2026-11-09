defmodule Letflow.Modules.Fixture do
  @moduledoc """
  Test-only entry module (REQ-400 §4) — registered only in `config/test.exs`
  (`config :letflow, :modules, [Letflow.Modules.Fixture]`), compiled only in
  the `:test` env via `mix.exs`'s existing `elixirc_paths(:test)` (already
  includes `test/support`, no `mix.exs` change needed). REQ-401..404 prove
  the module mechanism against it; REQ-400 itself only defines its shape and
  validates its manifest passes all six rules in
  `Letflow.Modules.Catalog.validate/1` (design §3.2, §8).
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.Fixture.MarkerStore
  alias Letflow.Modules.Fixture.Router

  @impl true
  defmanifest(
    id: "fixture",
    version: "0.1.0",
    min_data_version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [:FixtureRead],
    role_grants: %{TASK_WORKER: [:FixtureRead]},
    required_roles: [],
    settings_schema: %{
      "type" => "object",
      "properties" => %{
        "greeting" => %{"type" => "string"}
      },
      "additionalProperties" => false
    },
    route_policies: [{"GET", "/items/:id", :FixtureRead}]
  )

  @impl true
  def router, do: Router

  @impl true
  def on_install(prefix, settings) do
    MarkerStore.put(prefix, settings)
    :ok
  end
end
