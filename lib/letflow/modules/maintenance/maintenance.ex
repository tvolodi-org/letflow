defmodule Letflow.Modules.Maintenance do
  @moduledoc """
  Module `maintenance` (REQ-893, CMMS slice 1 part 1; `docs/cmms/scope-draft.md`): the skeleton of the
  maintenance management module. It declares the two record types (`maintenance_work_request`,
  `maintenance_work_order`, each linked to one asset card by a declarative `asset_card_id`, decision
  0076) and the two document types `maintenance_request` (prefix `WR`) and `maintenance_order`
  (prefix `WO`; year scope, pad 6, as the asset document types). REQ-894 (part 2, version 0.2.0) adds
  the work request routes (`Letflow.Modules.Maintenance.Router`) and the three tenant-scope atoms
  `MaintenanceRequestCreate`, `MaintenanceRead` and `MaintenanceOrderManage`. REQ-895 (part 3, version
  0.3.0) adds the four photo routes of a request (`Letflow.Modules.Maintenance.Photos`, owner kind
  `maintenance_work_request` of `Letflow.Attachments.Owners`), no new atom. REQ-896 (part 4, version 0.4.0) adds the four work order routes
  (`Letflow.Modules.Maintenance.Orders`) and the pack process `maintenance_work_order`, no new atom.
  The manifest has no
  `role_grants`, so the only holders are the two administrator catch-alls (decision 0055 D7). It has
  no handler.

  ## Release flag

  `config :letflow, :maintenance_enabled` is `false` in `config/config.exs` and turned on only by
  `config/test.exs`; `enabled?/0` is its only reader (no environment variable, no `runtime.exs` line).
  While it is false `Letflow.Modules.Installs.install/3` of `"maintenance"` answers
  `{:error, :unknown_module}` before anything is written, so the install route answers the 404 of an
  unknown module id. Turning it on installs nothing anywhere: a tenant administrator installs the
  module per tenant on request, as every module.

  ## Not here

  Screens, any role grant, a seed or a QA
  tenant. The 2000-character limit of `description` and the `urgency` value rules of the writers are
  checked by the writer (REQ-894): the entity type system has no string length bound.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Documents
  alias Letflow.Modules.EntityActivation

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  # The request is first: the order's foreign key needs its table.
  @types ["maintenance_work_request", "maintenance_work_order"]

  @document_types [
    %{
      key: "maintenance_request",
      owner_module: "maintenance",
      numbering_scope: :year,
      number_prefix: "WR",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "maintenance_order",
      owner_module: "maintenance",
      numbering_scope: :year,
      number_prefix: "WO",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    }
  ]

  @doc "The document types this module registers at install."
  @spec document_types() :: [map()]
  def document_types, do: @document_types

  @doc "True when the release flag `:maintenance_enabled` is on (default and production: off)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:letflow, :maintenance_enabled, false) == true

  @impl true
  defmanifest(
    id: "maintenance",
    version: "0.4.0",
    depends_on: ["assets"],
    pack: "modules/maintenance/pack.json",
    permissions: [:MaintenanceRequestCreate, :MaintenanceRead, :MaintenanceOrderManage],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"POST", "/requests", :MaintenanceRequestCreate},
      {"GET", "/requests", :MaintenanceRead},
      {"GET", "/requests/:id", :MaintenanceRead},
      {"POST", "/requests/:id/reject", :MaintenanceOrderManage},
      {"POST", "/requests/:id/photos", :MaintenanceRequestCreate},
      {"GET", "/requests/:id/photos", :MaintenanceRead},
      {"GET", "/requests/:id/photos/:photo_id/original", :MaintenanceRead},
      {"GET", "/requests/:id/photos/:photo_id/thumbnail", :MaintenanceRead},
      {"POST", "/orders", :MaintenanceOrderManage},
      {"GET", "/orders", :MaintenanceRead},
      {"GET", "/orders/:id", :MaintenanceRead},
      {"POST", "/orders/:id/assign", :MaintenanceOrderManage}
    ],
    manages_entity_types: ["maintenance_work_request", "maintenance_work_order"],
    scope_declarations: %{
      "maintenance_work_request" => {:column, "org_unit_id"},
      "maintenance_work_order" => {:column, "org_unit_id"}
    }
  )

  @impl true
  def router, do: Letflow.Modules.Maintenance.Router

  @impl true
  def on_install(prefix, _settings, ctx) do
    with :ok <- EntityActivation.activate_and_promote(prefix, ctx, @types) do
      register_document_types(prefix, ctx)
    end
  end

  defp register_document_types(prefix, ctx) do
    Enum.reduce_while(@document_types, :ok, fn attrs, :ok ->
      case Documents.register_type(prefix, attrs, ctx) do
        {:ok, _type} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
