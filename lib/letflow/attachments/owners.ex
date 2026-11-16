defmodule Letflow.Attachments.Owners do
  @moduledoc """
  Registry of the things that may own attachments (T-2040, photos.md 4). A static map in core keyed
  by owner-kind strings: no module reference, so no boundary edge into `lib/letflow/modules/` and no
  manifest-hash change. Each owner kind is one line; the owner's slice (P4, P5, P6) adds its own.

  The registry carries only purposes, the per-owner cap and the main-photo rule. Who may read or
  write is the caller's check (the owner's router), not the service's.
  """

  @owners %{
    "assets_card" => %{purposes: %{"photo" => %{max: 10, main: true}}}
  }

  @type entry :: %{purposes: %{optional(String.t()) => %{max: pos_integer(), main: boolean()}}}

  @spec fetch(term()) :: {:ok, entry()} | :error
  def fetch(kind) when is_binary(kind), do: Map.fetch(@owners, kind)
  def fetch(_), do: :error

  @spec kinds() :: [String.t()]
  def kinds, do: @owners |> Map.keys() |> Enum.sort()
end
