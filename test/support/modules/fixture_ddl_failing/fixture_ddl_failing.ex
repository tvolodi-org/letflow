defmodule Letflow.Modules.FixtureDdlFailing do
  @moduledoc """
  Test-only entry module (GH #2540): the same pack as `Letflow.Modules.FixtureFkPack`,
  whose `on_install/3` activates and promotes both types (so the definitions, tables
  and promotion rows exist inside the install transaction) and THEN runs a DDL
  statement that Postgres rejects, which raises a real `Postgrex.Error` out of the
  install transaction. The tests assert the typed `module_install_ddl_failed` answer
  and that nothing survives the rollback. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation
  alias Letflow.Repo

  @impl true
  defmanifest(
    id: "fixture_ddl_failing",
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
    :ok = EntityActivation.activate_and_promote(prefix, ctx, ["fkp_parent", "fkp_child"])

    Repo.query!(~s(ALTER TABLE "#{prefix}"."no_such_table_gh2540" ADD COLUMN "x" text))
    :ok
  end
end
