defmodule Letflow.Modules.ManifestHash do
  @moduledoc """
  A deterministic digest of the part of a module manifest that decides what a
  module's registered write handlers may do (GH #2590 / REQ-501 R1, design
  `lib/letflow/design/gh2590-req501-module-write-handlers.md` section 4.1).

  Pure: a function of the manifest map alone (no clock, no environment, no
  state). `compute/1` is called per use; the manifest is a small map, so no
  cache (no ETS, no `:persistent_term`; REQ-045 spirit) is kept.

  ## Hashed surface

  `id`, `version`, the sorted `manages_entity_types`, and per write handler
  (sorted by `name`) `name`, `inspect(module)`, the function name, the sorted
  unique `targets` and `args`. It does NOT cover permissions, routes,
  settings, pack content or handler CODE: a change of handler behaviour
  without a manifest change is not detected, so the discipline is to bump
  `:version` whenever handler code changes.

  **A matching hash is NOT proof of behaviour.** Equal hashes mean "the same declared
  surface", nothing about what a handler (or a permission, route or setting) does. Do not
  treat a stamp comparison as a behavioural guarantee (security review F3 of R1).

  ## Canonical form

  Same algorithm as `Letflow.Definitions.PromotionDigest`'s canonicalisation:
  object keys sorted, arrays keep order, atoms by `Atom.to_string/1`, tuples as
  lists; then `Jason.encode!/1`, SHA-256, lowercase hex (64 chars). R1 computes
  the value; R2 records it (`tenant_modules.manifest_hash` and the owner stamp of the pack's
  process definitions); comparing it is R3 onwards.
  """

  alias Letflow.Modules.Module

  @doc "Lowercase hex SHA-256 over the canonical JSON of the manifest's hashed surface."
  @spec compute(Module.manifest()) :: String.t()
  def compute(manifest) when is_map(manifest) do
    manifest
    |> surface()
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp surface(manifest) do
    %{
      "id" => Map.get(manifest, :id),
      "version" => Map.get(manifest, :version),
      "manages_entity_types" => manifest |> Map.get(:manages_entity_types, []) |> sorted_list(),
      "write_handlers" =>
        manifest
        |> Map.get(:write_handlers, [])
        |> handler_list()
        |> Enum.map(&handler_surface/1)
        |> Enum.sort_by(fn %{"name" => name} -> inspect(name) end)
    }
  end

  defp handler_list(handlers) when is_list(handlers), do: handlers
  defp handler_list(_other), do: []

  defp handler_surface(%{} = handler) do
    {module, fun} =
      case Map.get(handler, :function) do
        {m, f} -> {m, f}
        other -> {other, nil}
      end

    %{
      "name" => Map.get(handler, :name),
      "module" => inspect(module),
      "function" => fun,
      "targets" => handler |> Map.get(:targets, []) |> sorted_list() |> Enum.uniq(),
      "args" => Map.get(handler, :args, %{})
    }
  end

  defp handler_surface(other), do: %{"name" => inspect(other)}

  defp sorted_list(list) when is_list(list), do: Enum.sort(list)
  defp sorted_list(other), do: other

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key_string(key), canonicalize(val)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> canonicalize()

  defp canonicalize(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp canonicalize(value), do: value

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)
end
