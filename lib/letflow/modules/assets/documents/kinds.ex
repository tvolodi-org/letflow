defmodule Letflow.Modules.Assets.Documents.Kinds do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10): the closed table of asset document kinds. Pure: no database, no
  clock. Mirrors `Letflow.Modules.Stock.Documents.Kinds` (module `assets` cannot call `stock`, boundary
  Rule 4, so the structure is copied for one kind and C11 adds rows). Each entry says which header
  record type, line record type, process definition, ledger cause, number prefix and offline
  `device_id` a kind uses, and which header keys it accepts.

  `side/2` is the ONE place that maps the header of a kind to the `to` side of its lines
  (`%{org_unit, location, material_responsible, actual_user}`); the master checks, the posting command
  and the binding check all call it, so they cannot disagree. The commission has a `to` side only.
  """

  @table [
    %{
      kind: "commission",
      type_key: "assets_commission",
      line_type: "assets_commission_line",
      definition: "assets_commission",
      cause: "commission",
      prefix: "ACM",
      device_id: "assets-commission",
      header_keys:
        ~w(org_unit_id location_id material_responsible_id actual_user_id event_time note),
      required: ~w(org_unit_id material_responsible_id event_time),
      id_keys: ~w(org_unit_id location_id material_responsible_id actual_user_id),
      completion_node: "post"
    }
  ]

  @type spec :: %{
          kind: String.t(),
          type_key: String.t(),
          line_type: String.t(),
          definition: String.t(),
          cause: String.t(),
          prefix: String.t(),
          device_id: String.t(),
          header_keys: [String.t()],
          required: [String.t()],
          id_keys: [String.t()],
          completion_node: String.t()
        }

  @doc "Every spec, in the order of the closed kind set."
  @spec all() :: [spec()]
  def all, do: @table

  @doc "The closed set of kind names."
  @spec kinds() :: [String.t()]
  def kinds, do: Enum.map(@table, & &1.kind)

  @doc "The header record type keys (also the document type keys) of all kinds."
  @spec type_keys() :: [String.t()]
  def type_keys, do: Enum.map(@table, & &1.type_key)

  @doc "The process definition names of all kinds."
  @spec definition_names() :: [String.t()]
  def definition_names, do: Enum.map(@table, & &1.definition)

  @doc "The spec of `kind`, or `nil`."
  @spec get(term()) :: spec() | nil
  def get(kind), do: Enum.find(@table, &(&1.kind == kind))

  @doc "The spec whose header record type / document type is `type_key`, or `nil`."
  @spec by_type_key(term()) :: spec() | nil
  def by_type_key(type_key), do: Enum.find(@table, &(&1.type_key == type_key))

  # The atoms come from this closed table at compile time, never from input.
  @atoms @table
         |> Enum.flat_map(& &1.header_keys)
         |> Enum.uniq()
         |> Map.new(&{&1, String.to_atom(&1)})

  @doc "The view (atom-key) map of a header field map `fv` (string keys), keys of `spec.header_keys`."
  @spec view_fields(spec(), map()) :: map()
  def view_fields(spec, fv) do
    Map.new(spec.header_keys, fn key -> {Map.fetch!(@atoms, key), Map.get(fv, key)} end)
  end

  @doc "The string-key header map of a document view (inverse of `view_fields/2`)."
  @spec header_of(spec(), map()) :: map()
  def header_of(spec, view) do
    Map.new(spec.header_keys, fn key -> {key, Map.get(view, Map.fetch!(@atoms, key))} end)
  end

  @doc """
  The `to` side of every line of a document of `spec`, from the header field map `header` (string
  keys). A missing optional field is `nil`.
  """
  @spec side(spec(), map()) :: %{
          org_unit: term(),
          location: term(),
          material_responsible: term(),
          actual_user: term()
        }
  def side(%{kind: "commission"}, header) do
    %{
      org_unit: Map.get(header, "org_unit_id"),
      location: Map.get(header, "location_id"),
      material_responsible: Map.get(header, "material_responsible_id"),
      actual_user: Map.get(header, "actual_user_id")
    }
  end
end
