defmodule Letflow.Modules.Assets do
  @moduledoc """
  Module `assets` (GH #3894 / REQ-748, decisions 0050 D6, 0051 M4, 0076 R1 and R7, owner decision
  D-097; spec `docs/assets/asset-register.md`): the asset register, first slice, a skeleton.

  Module name: Assets (ru: Учёт активов; kk: Активтерді есепке алу). Record type `assets_card`
  (en: Asset card; ru: Карточка актива; kk: Актив карточкасы). The backend has no localized-name key
  in a manifest or a definition, so the names are stated here; the screens carry them in their own
  message files.

  The one record type `assets_card` is shipped by the pack `priv/modules/assets/pack.json`
  (generated from `priv/modules/assets/entity_definitions/` by
  `priv/modules/assets/generate_pack.exs`). It is a managed type: after install the generic write
  routes answer 403 `entity_type_managed`. Cards are written only by `Letflow.Modules.Assets.Cards`
  through the routes of `Letflow.Modules.Assets.Router` (REQ-750, permission `AssetsCardWrite`, no
  role grants). The module has no ledger yet (REQ-749).

  **Scope declaration** `{:column, "org_unit_id"}`: a scoped reader sees the cards of the org units
  of its grant. The declaration lives only in this compiled manifest; a managed type cannot be
  declared by a tenant (decision 0051 M4), so it cannot be edited later.

  **Shipped report**: install also creates the saved report "Asset list" (`Letflow.Modules.Assets.Reports`,
  spec `docs/assets/government-lists.md` section 3). Installs made before this change do not get it
  (no upgrade runner carries it).

  **Currency** (D-097): the tenant currency is the module setting `currency` (three characters),
  `KZT` when absent. See `currency/1`.

  **Expiry reminder** (C12): the module setting `expiry_reminder_lead_days` (1..3650, no default) is the
  lead time of `Letflow.Modules.Assets.Reminders`; absent means no reminder. See `expiry_lead_days/1`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.Assets.Reports
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @default_currency "KZT"

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types ["assets_card"]

  @impl true
  defmanifest(
    id: "assets",
    version: "0.3.0",
    depends_on: ["locations", "org"],
    pack: "modules/assets/pack.json",
    permissions: [:AssetsCardWrite],
    role_grants: %{},
    required_roles: [],
    settings_schema: %{
      "type" => "object",
      "properties" => %{
        "currency" => %{"type" => "string", "minLength" => 3, "maxLength" => 3},
        "expiry_reminder_lead_days" => %{"type" => "integer", "minimum" => 1, "maximum" => 3650}
      },
      "additionalProperties" => false
    },
    route_policies: [
      {"POST", "/cards", :AssetsCardWrite},
      {"PATCH", "/cards/:id", :AssetsCardWrite},
      {"POST", "/cards/:id/retire", :AssetsCardWrite}
    ],
    manages_entity_types: ["assets_card"],
    scope_declarations: %{"assets_card" => {:column, "org_unit_id"}}
  )

  @impl true
  def router, do: Letflow.Modules.Assets.Router

  @impl true
  def on_install(prefix, _settings, ctx) do
    with :ok <- EntityActivation.activate_and_promote(prefix, ctx, @types) do
      Reports.ensure_asset_list(prefix, ctx.actor_id)
    end
  end

  @doc """
  The tenant currency of the tenant schema `prefix`: the `currency` setting of the active `assets`
  install, `"KZT"` when the setting is absent or the module is not installed (D-097). The tenant
  comes only from `prefix` (INV-1).
  """
  @spec currency(prefix :: String.t()) :: String.t()
  def currency(prefix) when is_binary(prefix) do
    case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix) do
      %TenantModule{settings: %{"currency" => c}} when is_binary(c) and byte_size(c) == 3 -> c
      _ -> @default_currency
    end
  end

  @doc """
  The reminder lead time in days: the `expiry_reminder_lead_days` setting of the active `assets`
  install of `prefix`, `nil` when absent, invalid or the module is not installed (no default).
  """
  @spec expiry_lead_days(prefix :: String.t()) :: pos_integer() | nil
  def expiry_lead_days(prefix) when is_binary(prefix) do
    case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix) do
      %TenantModule{settings: %{"expiry_reminder_lead_days" => d}}
      when is_integer(d) and d >= 1 and d <= 3650 ->
        d

      _ ->
        nil
    end
  end
end
