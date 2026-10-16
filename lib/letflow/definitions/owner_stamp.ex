defmodule Letflow.Definitions.OwnerStamp do
  @moduledoc """
  The module ownership stamp of a process definition version (GH #2590 / REQ-501 PR R2,
  decision 0054 D6, design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  4.2, D-R.8).

  A stamped row records WHICH module shipped it (`owner_module`, `owner_module_version`),
  under which manifest (`owner_manifest_hash`, the value
  `Letflow.Modules.Catalog.manifest_hash/1` answered at install) and with which body
  (`owner_body_hash`, `graph_hash/1` of the graph as stamped). The stamp exists only on a row
  inserted by `Letflow.Definitions.create_owned/3` from a module install; nothing in this
  module writes anything.

  ## What a stamp proves (and does not)

  The manifest hash covers the manifest's DECLARED surface only (`Letflow.Modules.ManifestHash`:
  id, version, managed types, write-handler registrations). It excludes handler code,
  permissions and settings, so a matching hash is NOT proof of what a handler does: the
  discipline is to bump the module `version` whenever handler behaviour changes.

  ## `graph_hash/1`: ONE input form (design 4.2, F-9)

  The hash is defined over the JSON-NORMALISED form of the graph: the value a JSONB column
  returns. The stamp is computed BEFORE the insert, from the graph in the create attrs, and
  written in the same INSERT; at run time the pinned snapshot's graph (a copy of the row's
  JSONB value) is passed to the same function. For the two to agree on every input the
  function normalises exactly the places where JSONB round-trips a term to a different
  Elixir value than `Jason.decode!(Jason.encode!(term))`:

    * atoms and atom keys become strings (JSON encoding);
    * key order is irrelevant (canonical form sorts object keys; JSONB reorders them);
    * a float whose shortest encoding carries a positive exponent (`1.0e20`, `1.5e16`) is
      stored by Postgres `numeric` with no fractional scale and read back as an INTEGER, so
      it is normalised to that integer by decimal digit shifting (never by float
      arithmetic);
    * `-0.0` reads back as `0.0`.

  Plain floats (`1.0`, `0.1`) round-trip unchanged. It deliberately does NOT use
  `Letflow.Repository.Canonicaliser` (numeric-normalising: `1` and `1.0` equal), and `1` and
  `1.0` hash differently here, as they do in a JSONB column's text form.

  The canonical form itself (sorted object keys, arrays keep order, then `Jason.encode!/1`,
  SHA-256, lowercase hex) is the algorithm of `Letflow.Definitions.PromotionDigest`.
  """

  # The owner is matched as a plain map, never as an `%Owner{}` literal: the Owner struct is
  # built and pattern-matched in `managed_types.ex` only (scan `managed_types_callers_test`).
  alias Letflow.Entities.ManagedTypes

  @type t :: %{
          module_id: String.t(),
          module_version: String.t(),
          manifest_hash: String.t(),
          body_hash: String.t()
        }

  @doc """
  Lowercase hex SHA-256 over the canonical JSON of the JSON-normalised `graph_map` (see the
  moduledoc for the one input form).
  """
  @spec graph_hash(graph_map :: map()) :: String.t()
  def graph_hash(graph_map) when is_map(graph_map) do
    graph_map
    |> Jason.encode!()
    |> Jason.decode!()
    |> normalise()
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The four-field stamp a row carries, or `:none` when any of its four columns is NULL (the
  database CHECK makes "some but not all" unrepresentable; this is the fail-closed read).
  """
  @spec from_row(row :: map()) :: {:ok, t()} | :none
  def from_row(%{
        owner_module: module_id,
        owner_module_version: version,
        owner_manifest_hash: m_hash,
        owner_body_hash: body_hash
      })
      when is_binary(module_id) and is_binary(version) and is_binary(m_hash) and
             is_binary(body_hash) do
    {:ok,
     %{
       module_id: module_id,
       module_version: version,
       manifest_hash: m_hash,
       body_hash: body_hash
     }}
  end

  def from_row(_row), do: :none

  @doc """
  The stamp `owner` gives a version whose graph is `graph_map`, or `:none` for an owner that
  carries no version/manifest hash (built by something other than
  `Letflow.Entities.ManagedTypes.module_owner/1`). Pure; computed BEFORE the insert.
  """
  @spec for_owner(owner :: ManagedTypes.Owner.t(), graph_map :: map()) :: {:ok, t()} | :none
  def for_owner(owner, graph_map) when is_map(graph_map) do
    # Only a genuine `%Owner{}` stamps: a plain map or a foreign struct with the same keys
    # is `:none` (`ManagedTypes.owner?/1`).
    with true <- ManagedTypes.owner?(owner),
         %{module_id: module_id, version: version, manifest_hash: m_hash}
         when is_binary(module_id) and is_binary(version) and is_binary(m_hash) <- owner do
      {:ok,
       %{
         module_id: module_id,
         module_version: version,
         manifest_hash: m_hash,
         body_hash: graph_hash(graph_map)
       }}
    else
      _not_a_stamping_owner -> :none
    end
  end

  def for_owner(_owner, _graph_map), do: :none

  # ── JSONB round-trip normalisation ────────────────────────────────────────

  defp normalise(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {key, normalise(val)} end)

  defp normalise(value) when is_list(value), do: Enum.map(value, &normalise/1)
  defp normalise(value) when is_float(value), do: normalise_float(value)
  defp normalise(value), do: value

  defp normalise_float(value) do
    encoded = Jason.encode!(value)

    with [_, sign, int, frac, exponent] <-
           Regex.run(~r/\A(-?)(\d+)\.(\d+)e\+?(\d+)\z/, encoded),
         exponent = String.to_integer(exponent),
         true <- exponent >= String.length(frac) do
      # int.frac * 10^exponent has no fractional part left: Postgres numeric reads it back
      # as this integer. Decimal digit shifting, never float arithmetic.
      String.to_integer(
        sign <> int <> frac <> String.duplicate("0", exponent - String.length(frac))
      )
    else
      _stays_a_float -> if value == 0.0, do: 0.0, else: value
    end
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key, canonicalize(val)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value
end
