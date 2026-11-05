defmodule Letflow.Modules.Stock.Documents.Kinds do
  @moduledoc """
  REQ-721 / GH #3770 (assets phase B, P37): the closed table of stock document kinds. Pure: no
  database, no clock. Each entry says which header record type, line record type, process
  definition, ledger cause, number prefix and offline `device_id` a kind uses, and which header
  keys it accepts. `Documents`, `Posting`, `Checks` and `Shape` read this table instead of
  hard-coding the receipt.

  `sides/2` is the ONE place that maps the header fields of a kind to the `from` and `to` side of
  its lines (a side is `%{org_unit, location, responsible}`). The sides-equal check, the master
  checks, the posting command and the binding check all call it, so they cannot disagree:

  * `receipt`: no `from` side; `to` = `org_unit_id`, `location_id`, `responsible_id`.
  * `transfer`, `hand_over`: `from` = `org_unit_id`, `from_location_id`, `from_responsible_id`;
    `to` = `to_org_unit_id`, `to_location_id`, `to_responsible_id`.
  * `issue`, `write_off` (REQ-715): no `to` side; `from` = `org_unit_id`, `location_id`,
    `responsible_id` (the legs are negative; `reason_code` and `reason_text` are header fields).
  * `return`: `from` = `from_org_unit_id`, `from_location_id`, `from_responsible_id`;
    `to` = `org_unit_id`, `to_location_id`, `to_responsible_id` (the unit the stock goes back to
    files the document).

  Each kind has its own `device_id`: the offline idempotency triple `(device_id, client_seq)` must not
  collide across kinds, because each document type numbers on its own.
  Assumptions, owner may change at GATE B: prefixes `TRF`, `HOV`, `RET`, `ISS`, `WOF`.
  """

  alias Letflow.Modules.Stock.Documents.OpeningShape
  alias Letflow.Modules.Stock.Documents.Shape

  @receipt_keys ~w(org_unit_id location_id responsible_id event_time counterparty_id note supplier_document_ref received_on)
  @issue_keys ~w(org_unit_id location_id responsible_id event_time note reason_text)
  @write_off_keys @issue_keys ++ ["reason_code"]
  @two_side_common ~w(org_unit_id event_time note from_location_id from_responsible_id)
  @transfer_keys @two_side_common ++ ~w(to_org_unit_id to_location_id to_responsible_id)
  @return_keys @two_side_common ++ ~w(from_org_unit_id to_location_id to_responsible_id)

  @opening_keys ~w(org_unit_id note external_ref_system external_ref_id)

  @table [
    %{
      kind: "receipt",
      type_key: "stock_receipt",
      line_type: "stock_receipt_line",
      definition: "stock_receipt",
      cause: "receipt",
      prefix: "RCP",
      device_id: "stock-receipt",
      header_keys: @receipt_keys,
      required: ~w(org_unit_id location_id responsible_id event_time),
      id_keys: ~w(org_unit_id location_id responsible_id counterparty_id),
      two_sided?: false,
      completion_node: "post"
    },
    %{
      kind: "issue",
      type_key: "stock_issue",
      line_type: "stock_issue_line",
      definition: "stock_issue",
      cause: "issue",
      prefix: "ISS",
      device_id: "stock-issue",
      header_keys: @issue_keys,
      required: ~w(org_unit_id location_id responsible_id event_time),
      id_keys: ~w(org_unit_id location_id responsible_id),
      two_sided?: false,
      completion_node: "post"
    },
    %{
      kind: "write_off",
      type_key: "stock_writeoff",
      line_type: "stock_writeoff_line",
      definition: "stock_writeoff",
      cause: "write_off",
      prefix: "WOF",
      device_id: "stock-writeoff",
      header_keys: @write_off_keys,
      required: ~w(org_unit_id location_id responsible_id event_time reason_code),
      id_keys: ~w(org_unit_id location_id responsible_id),
      two_sided?: false,
      completion_node: "post"
    },
    %{
      kind: "transfer",
      type_key: "stock_transfer",
      line_type: "stock_transfer_line",
      definition: "stock_transfer",
      cause: "transfer",
      prefix: "TRF",
      device_id: "stock-transfer",
      header_keys: @transfer_keys,
      required: List.delete(@transfer_keys, "note"),
      id_keys: List.delete(List.delete(@transfer_keys, "note"), "event_time"),
      two_sided?: true,
      completion_node: "post"
    },
    %{
      kind: "hand_over",
      type_key: "stock_handover",
      line_type: "stock_handover_line",
      definition: "stock_handover",
      cause: "hand_over",
      prefix: "HOV",
      device_id: "stock-handover",
      header_keys: @transfer_keys,
      required: List.delete(@transfer_keys, "note"),
      id_keys: List.delete(List.delete(@transfer_keys, "note"), "event_time"),
      two_sided?: true,
      completion_node: "post"
    },
    %{
      kind: "return",
      type_key: "stock_return",
      line_type: "stock_return_line",
      definition: "stock_return",
      cause: "return",
      prefix: "RET",
      device_id: "stock-return",
      header_keys: @return_keys,
      required: List.delete(@return_keys, "note"),
      id_keys: List.delete(List.delete(@return_keys, "note"), "event_time"),
      two_sided?: true,
      completion_node: "post"
    },
    %{
      kind: "opening",
      type_key: "stock_opening",
      line_type: "stock_opening_line",
      definition: "stock_opening",
      cause: "opening",
      prefix: "OPN",
      device_id: nil,
      header_keys: @opening_keys,
      required: ~w(org_unit_id),
      id_keys: ~w(org_unit_id),
      two_sided?: false,
      completion_node: "approve"
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
          two_sided?: boolean(),
          completion_node: String.t()
        }
  @type side :: %{org_unit: term(), location: term(), responsible: term()}

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

  @withdrawable ~w(issue write_off transfer hand_over return)

  @doc """
  True for the kinds whose posting the ledger can refuse for stock (negative or zero-sum legs): an
  issued, unposted document of such a kind may be cancelled while its `post` task is pending (T-1375).
  """
  @spec withdrawable?(term()) :: boolean()
  def withdrawable?(kind), do: kind in @withdrawable

  @doc "The spec of `kind`, or `nil`."
  @spec get(term()) :: spec() | nil
  def get(kind), do: Enum.find(@table, &(&1.kind == kind))

  @doc """
  Parses a save or replace body; `mode` is `:create` or `{:replace, kind}`. `opening` goes to
  `Letflow.Modules.Stock.Documents.OpeningShape` (REQ-725), every other kind to
  `Letflow.Modules.Stock.Documents.Shape` (which answers `unknown_kind` for a kind it does not know).
  """
  @spec parse(term(), :create | {:replace, String.t()}) ::
          {:ok, map()} | {:error, {String.t(), map()}}
  def parse(%{"kind" => "opening"} = body, :create), do: OpeningShape.parse(body, :create)
  def parse(body, {:replace, "opening"}), do: OpeningShape.parse(body, {:replace, "opening"})
  def parse(body, mode), do: Shape.parse(body, mode)

  @doc "The spec whose header record type / document type is `type_key`, or `nil`."
  @spec by_type_key(term()) :: spec() | nil
  def by_type_key(type_key), do: Enum.find(@table, &(&1.type_key == type_key))

  @atoms @table
         |> Enum.flat_map(& &1.header_keys)
         |> Enum.uniq()
         |> Map.new(&{&1, String.to_atom(&1)})

  @doc """
  The view (atom-key) map of a header field map `fv` (string keys): the keys of `spec.header_keys`
  that are not part of the common view keys, in the view of `Letflow.Modules.Stock.Documents`.
  The atoms come from the closed table above, never from input.
  """
  @spec view_fields(spec(), map()) :: map()
  def view_fields(spec, fv) do
    Map.new(spec.header_keys, fn key -> {Map.fetch!(@atoms, key), Map.get(fv, key)} end)
  end

  @doc """
  The string-key header map of a document view (inverse of `view_fields/2`), for `sides/2`.
  """
  @spec header_of(spec(), map()) :: map()
  def header_of(spec, view) do
    Map.new(spec.header_keys, fn key -> {key, Map.get(view, Map.fetch!(@atoms, key))} end)
  end

  @doc """
  `{from, to}` for the header field map `header` (string keys) of `spec`. `from` is `nil` for the
  receipt, `to` is `nil` for an issue and a write-off. A missing field is `nil` in the side.
  """
  @spec sides(spec(), map()) :: {side() | nil, side() | nil}
  def sides(%{kind: "opening"}, _header), do: {nil, nil}

  def sides(%{kind: "receipt"}, header) do
    {nil, side(header, "org_unit_id", "location_id", "responsible_id")}
  end

  def sides(%{kind: kind}, header) when kind in ["issue", "write_off"] do
    {side(header, "org_unit_id", "location_id", "responsible_id"), nil}
  end

  def sides(%{kind: kind}, header) when kind in ["transfer", "hand_over"] do
    {side(header, "org_unit_id", "from_location_id", "from_responsible_id"),
     side(header, "to_org_unit_id", "to_location_id", "to_responsible_id")}
  end

  def sides(%{kind: "return"}, header) do
    {side(header, "from_org_unit_id", "from_location_id", "from_responsible_id"),
     side(header, "org_unit_id", "to_location_id", "to_responsible_id")}
  end

  defp side(header, unit, location, responsible) do
    %{
      org_unit: Map.get(header, unit),
      location: Map.get(header, location),
      responsible: Map.get(header, responsible)
    }
  end
end
