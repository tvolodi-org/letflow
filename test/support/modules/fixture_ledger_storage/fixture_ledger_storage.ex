defmodule Letflow.Modules.FixtureLedgerStorage do
  @moduledoc """
  Test-only entry module (REQ-711 / GH #3751, decision 0073 A6): one ledger registration `main` with
  two fixed ledger ids, `fixture_ledger_storage` and `fixture_ledger_storage:b`, so install and
  reactivate have partitions to create. Own four permission atoms (no role is granted any), no pack,
  no router, a policy in `ledger_policy/` (Catalog rule 18 wants the policy module name to start with
  the entry module name). `on_install/2` fails when the `:fixture_ledger_storage_fail` application
  flag is true (the test sets and clears it). Registered only in `config/test.exs`, last in the list.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_ledger_storage",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [:FxlsPost, :FxlsReverse, :FxlsRead, :FxlsReconcile],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [],
    ledger: %{
      "main" => %{
        ledger_ids: {:fixed, ["fixture_ledger_storage", "fixture_ledger_storage:b"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false}
        },
        key_bounds: [%{when_slot_nonempty: "k2", max_on_hand: "1"}],
        permissions: %{
          post: :FxlsPost,
          reverse: :FxlsReverse,
          read: :FxlsRead,
          reconcile: :FxlsReconcile
        },
        scope_slot: nil,
        max_event_lateness_hours: 96,
        policy: {Letflow.Modules.FixtureLedgerStorage.LedgerPolicy, :declare}
      }
    }
  )

  @doc false
  def on_install(_prefix, _settings) do
    if Application.get_env(:letflow, :fixture_ledger_storage_fail) == true,
      do: {:error, :boom},
      else: :ok
  end
end
