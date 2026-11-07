defmodule Letflow.Modules.Assets.Documents.Kinds do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10): the closed table of asset document kinds. Pure: no database, no
  clock. Mirrors `Letflow.Modules.Stock.Documents.Kinds` (module `assets` cannot call `stock`, boundary
  Rule 4, so the structure is copied for one kind and C11 adds rows). Each entry says which header
  record type, line record type, process definition, ledger cause, number prefix and offline
  `device_id` a kind uses, and which header keys it accepts.

  `sides/2` is the ONE place that maps the header of a kind to the `{from, to}` sides of its lines
  (`%{org_unit, location, material_responsible, actual_user}` or `nil`); the master checks, the posting
  command and the binding check all call it, so they cannot disagree. The commission has a `to` side
  only, the write off a `from` side only, the change and the hand over both (GH #3889 / REQ-753, C11).
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
    },
    %{
      kind: "change",
      type_key: "assets_change",
      line_type: "assets_change_line",
      definition: "assets_change",
      cause: "change",
      prefix: "ACH",
      device_id: "assets-change",
      header_keys:
        ~w(org_unit_id location_id from_material_responsible_id from_actual_user_id to_material_responsible_id to_actual_user_id event_time note),
      required:
        ~w(org_unit_id event_time from_material_responsible_id to_material_responsible_id),
      id_keys:
        ~w(org_unit_id location_id from_material_responsible_id from_actual_user_id to_material_responsible_id to_actual_user_id),
      completion_node: "post"
    },
    %{
      kind: "handover",
      type_key: "assets_handover",
      line_type: "assets_handover_line",
      definition: "assets_handover",
      cause: "handover",
      prefix: "AHO",
      device_id: "assets-handover",
      header_keys:
        ~w(org_unit_id from_location_id from_material_responsible_id from_actual_user_id to_org_unit_id to_location_id to_material_responsible_id to_actual_user_id event_time note),
      required:
        ~w(org_unit_id event_time from_material_responsible_id to_org_unit_id to_material_responsible_id),
      id_keys:
        ~w(org_unit_id from_location_id from_material_responsible_id from_actual_user_id to_org_unit_id to_location_id to_material_responsible_id to_actual_user_id),
      completion_node: "post"
    },
    %{
      kind: "writeoff",
      type_key: "assets_writeoff",
      line_type: "assets_writeoff_line",
      definition: "assets_writeoff",
      cause: "writeoff",
      prefix: "AWO",
      device_id: "assets-writeoff",
      header_keys:
        ~w(org_unit_id location_id material_responsible_id actual_user_id reason_code reason_text event_time note),
      required: ~w(org_unit_id event_time material_responsible_id reason_code),
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

  @type side :: %{
          org_unit: term(),
          location: term(),
          material_responsible: term(),
          actual_user: term()
        }

  @doc """
  The `{from, to}` sides of every line of a document of `spec`, from the header field map `header`
  (string keys). A side a kind does not have is `nil`; a missing optional field is `nil`.
  """
  @spec sides(spec(), map()) :: {side() | nil, side() | nil}
  def sides(%{kind: "commission"}, header) do
    {nil, side(header, "org_unit_id", "location_id", "material_responsible_id", "actual_user_id")}
  end

  def sides(%{kind: "change"}, header) do
    {side(
       header,
       "org_unit_id",
       "location_id",
       "from_material_responsible_id",
       "from_actual_user_id"
     ),
     side(header, "org_unit_id", "location_id", "to_material_responsible_id", "to_actual_user_id")}
  end

  def sides(%{kind: "handover"}, header) do
    {side(
       header,
       "org_unit_id",
       "from_location_id",
       "from_material_responsible_id",
       "from_actual_user_id"
     ),
     side(
       header,
       "to_org_unit_id",
       "to_location_id",
       "to_material_responsible_id",
       "to_actual_user_id"
     )}
  end

  def sides(%{kind: "writeoff"}, header) do
    {side(header, "org_unit_id", "location_id", "material_responsible_id", "actual_user_id"), nil}
  end

  @doc """
  The header key behind each slot of the `:from` / `:to` side of `spec` (for the `"field"` extra of a
  refusal): `%{org_unit: key, location: key, material_responsible: key, actual_user: key}`.
  """
  @spec side_fields(spec(), :from | :to) :: %{atom() => String.t()}
  def side_fields(%{kind: "change"}, :from),
    do:
      fields("org_unit_id", "location_id", "from_material_responsible_id", "from_actual_user_id")

  def side_fields(%{kind: "change"}, :to),
    do: fields("org_unit_id", "location_id", "to_material_responsible_id", "to_actual_user_id")

  def side_fields(%{kind: "handover"}, :from),
    do:
      fields(
        "org_unit_id",
        "from_location_id",
        "from_material_responsible_id",
        "from_actual_user_id"
      )

  def side_fields(%{kind: "handover"}, :to),
    do:
      fields(
        "to_org_unit_id",
        "to_location_id",
        "to_material_responsible_id",
        "to_actual_user_id"
      )

  def side_fields(%{kind: "writeoff"}, :from),
    do: fields("org_unit_id", "location_id", "material_responsible_id", "actual_user_id")

  def side_fields(%{kind: "commission"}, :to),
    do: fields("org_unit_id", "location_id", "material_responsible_id", "actual_user_id")

  defp side(header, unit, location, responsible, user) do
    %{
      org_unit: Map.get(header, unit),
      location: Map.get(header, location),
      material_responsible: Map.get(header, responsible),
      actual_user: Map.get(header, user)
    }
  end

  defp fields(unit, location, responsible, user),
    do: %{
      org_unit: unit,
      location: location,
      material_responsible: responsible,
      actual_user: user
    }
end
