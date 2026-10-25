defmodule Letflow.Modules.FixturePoints do
  @moduledoc """
  Test-only entry module (REQ-574 / GH #3256, decision 0071 D9 slice X1): declares one extension
  point, `after_review`, aimed at node `review` of its definition `fx_points_def`. No pack, no
  permissions, no routes. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_points",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    extension_points: [
      %{
        "name" => "after_review",
        "kind" => "script_step",
        "site" => %{
          "definition" => "fx_points_def",
          "node_id" => "review",
          "position" => "after"
        },
        "input" => ["amount"],
        "returns" => %{"approved" => "boolean"}
      }
    ]
  )
end
