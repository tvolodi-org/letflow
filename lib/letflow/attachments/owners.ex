defmodule Letflow.Attachments.Owners do
  @moduledoc """
  Registry of the things that may own attachments (T-2040, photos.md 4). A static map in core keyed
  by owner-kind strings: no module reference, so no boundary edge into `lib/letflow/modules/` and no
  manifest-hash change. Each owner kind is one line; the owner's slice (P4, P5, P6) adds its own.
  T-2043 (P5) adds problem-report screenshots and the optional `retain_days` rule.
  T-2044 (P4a) adds the master-photo kinds `catalog_item`, `catalog_lot` and `location_node`. HTTP
  authorization, authenticated routes and gallery UI are delivered in later P4 slices (P4b–P4e).

  The registry carries only purposes, the per-owner cap, the main-photo rule and optional retention.
  Who may read or write is the caller's check (the owner's router), not the service's.
  """

  @owners %{
    "assets_card" => %{purposes: %{"photo" => %{max: 10, main: true}}},
    "catalog_item" => %{purposes: %{"photo" => %{max: 10, main: true}}},
    "catalog_lot" => %{purposes: %{"photo" => %{max: 10, main: true}}},
    "location_node" => %{purposes: %{"photo" => %{max: 10, main: true}}},
    "problem_report" => %{
      purposes: %{"screenshot" => %{max: 3, main: false, retain_days: 30}}
    }
  }

  @type entry :: %{
          purposes: %{
            optional(String.t()) => %{
              optional(:retain_days) => pos_integer(),
              max: pos_integer(),
              main: boolean()
            }
          }
        }

  @spec fetch(term()) :: {:ok, entry()} | :error
  def fetch(kind) when is_binary(kind), do: Map.fetch(@owners, kind)
  def fetch(_), do: :error

  @spec kinds() :: [String.t()]
  def kinds, do: @owners |> Map.keys() |> Enum.sort()
end
