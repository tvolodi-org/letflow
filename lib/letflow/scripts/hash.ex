defmodule Letflow.Scripts.Hash do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D6): the sha256 that binds a script version's content,
  extending `Letflow.Engine.Lua.Manifest.compute_hash/2`'s length-prefixed framing to cover
  version, hook kind, manifest, stored test cases and source. Design section 2.

  `canon/1` is the canonical JSON of `Letflow.Repository.Canonicaliser` (sorted keys,
  integer-valued floats as integers), so a value that went through a jsonb round-trip hashes
  the same as the value that was written. The registry always hashes the row AS RELOADED from
  the database.
  """

  alias Letflow.Repository.Canonicaliser

  @domain "letflow-script-v1"

  @spec compute(String.t(), pos_integer(), String.t(), map(), list(), String.t()) :: String.t()
  def compute(key, version, hook_kind, manifest, test_cases, source)
      when is_binary(key) and is_integer(version) and is_binary(hook_kind) and is_binary(source) do
    framed =
      lp(@domain) <>
        lp(key) <>
        lp(Integer.to_string(version)) <>
        lp(hook_kind) <>
        lp(canon(manifest)) <>
        lp(canon(test_cases)) <>
        lp(source)

    :sha256 |> :crypto.hash(framed) |> Base.encode16(case: :lower)
  end

  @doc "Canonical JSON bytes of `value` (the `{:error, _}` branch cannot occur on encoder output)."
  @spec canon(term()) :: binary()
  def canon(value) do
    {:ok, canonical} =
      Canonicaliser.canonicalize_content("application/json", Jason.encode!(value))

    canonical
  end

  defp lp(bytes) when is_binary(bytes), do: <<byte_size(bytes)::32>> <> bytes
end
