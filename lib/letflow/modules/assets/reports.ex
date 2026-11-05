defmodule Letflow.Modules.Assets.Reports do
  @moduledoc """
  The saved report shipped with module `assets` (GH #3894 follow-up, plan key E2b; spec
  `docs/assets/government-lists.md` section 3): **Asset list**, kind `report` over `assets_card`,
  detail columns and a sort by `inventory_number`, no filter.

  A report needs a non-empty `aggregates`; the summary is the minimum legal one, a `count` without
  `group_by`. The spec's sums by kind wait for `queried` on the money fields (a definition change not
  made here). The stock list needs a joined report the builder does not have and is not shipped.

  The view is created through `Letflow.Entities.Views.create/3` from `Letflow.Modules.Assets.on_install/3`,
  inside the install transaction, as the installer. A replay of the report is the ordinary scoped
  `POST /query`, so a scoped reader sees only its units; the row stores no record value.

  `ensure_asset_list/2` checks for the row first: `Views.create` nests its own transaction and a
  unique-index violation would poison the install transaction, so a duplicate is never inserted.
  Uninstall keeps `entity_views`, hence a reinstall finds the row and leaves it (edits survive).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Views
  alias Letflow.Entities.Views.View
  alias Letflow.Repo

  @entity_type "assets_card"
  @name "Asset list"

  @doc "The request body (string keys) of the shipped report."
  @spec asset_list_body() :: map()
  def asset_list_body do
    %{
      "kind" => "report",
      "entity_type" => @entity_type,
      "name" => @name,
      "columns" => [
        "inventory_number",
        "name",
        "kind",
        "org_unit_id",
        "acquisition_date",
        "acquisition_cost",
        "accumulated_depreciation",
        "book_value",
        "depreciation_as_of"
      ],
      "sort" => [%{"field" => "inventory_number", "dir" => "asc"}],
      "aggregates" => [%{"fn" => "count"}]
    }
  end

  @doc """
  Creates the report in the tenant schema `prefix` unless a view of that name exists on `assets_card`.
  Any failure (including a type access denial of the installer) is returned, so the install rolls back.
  """
  @spec ensure_asset_list(String.t(), String.t()) :: :ok | {:error, {:report_seed_failed, term()}}
  def ensure_asset_list(prefix, actor_id) when is_binary(prefix) do
    exists? =
      Repo.exists?(
        from(v in View, where: v.entity_type == ^@entity_type and v.name == ^@name),
        prefix: prefix
      )

    if exists? do
      :ok
    else
      case Views.create(prefix, actor_id, asset_list_body()) do
        {:ok, _view} -> :ok
        {:error, reason} -> {:error, {:report_seed_failed, reason}}
      end
    end
  end
end
