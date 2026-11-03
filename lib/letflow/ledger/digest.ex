defmodule Letflow.Ledger.Digest do
  @moduledoc """
  REQ-621 / GH #3469 part A: the pure hash functions of the ledger (note gh2657 section 5.1).
  No query, no clock, no randomness: the same input gives the same lowercase hex SHA-256.

  ## Canonical encoding

  * A record is a list of fields joined by the unit separator `0x1F`; records are joined by the
    record separator `0x1E`. Field values hold no control character (the database CHECKs and the
    validation refuse them), `attrs` is JSON where control characters are escaped, so the
    separators are unambiguous.
  * A null field is the single character `~`. Text is taken as is. Integers are decimal text.
  * Timestamps are UTC `YYYY-MM-DDTHH:MM:SS.ffffffZ` (always six fractional digits).
  * A quantity is text at scale 9 (`1.500000000`, `-6.000000000`), never in exponent form.
  * `attrs`, the command and the registration are key-sorted JSON (maps recursively sorted).
  * `entry_digest` covers the header columns in table order (except `entry_digest` and
    `chain_hash`), then the legs in `leg_no` order, each as one record.
  * `chain_hash(previous, entry_digest)` is the SHA-256 of `previous <> 0x1E <> entry_digest`
    (`previous` is `""` for the first entry of a ledger).
  """

  @us <<0x1F>>
  @rs <<0x1E>>

  @header_fields ~w(id ledger_id posting_seq cause sign_rule reverses_entry_id reason_code
                    document_type document_id related_document_id actor_id subject_id correlation_id
                    bpm_instance_id bpm_task_id bpm_definition_id bpm_node_id bpm_definition_version
                    event_time posting_time client_op_id origin_key payload_hash registration_hash
                    device_id client_seq client_event_time scope_ref leg_count)a

  @leg_fields ~w(leg_no k1 k2 k3 k4 k5 k6 k7 k8 quantity unit_ref attrs document_line_id
                 quantity_scale quantity_original original_unit_ref original_scale
                 conversion_factor conversion_basis rounding_mode reference_quantity tolerance_abs
                 tolerance_state exception_ref)a

  @doc "The header columns the entry digest covers, in order."
  @spec header_fields() :: [atom()]
  def header_fields, do: @header_fields

  @doc "The leg columns the entry digest covers, in order."
  @spec leg_fields() :: [atom()]
  def leg_fields, do: @leg_fields

  @doc "SHA-256 (lowercase hex) of the header map and the legs (maps, in `leg_no` order)."
  @spec entry_digest(map(), [map()]) :: String.t()
  def entry_digest(header, legs) when is_map(header) and is_list(legs) do
    header_record = record(header, @header_fields)
    leg_records = Enum.map(legs, &record(&1, @leg_fields))

    sha([header_record | leg_records] |> Enum.join(@rs))
  end

  @doc "The chain hash of an entry given the previous chain hash (`\"\"` for the first entry)."
  @spec chain_hash(String.t(), String.t()) :: String.t()
  def chain_hash(previous, entry_digest) when is_binary(previous) and is_binary(entry_digest),
    do: sha(previous <> @rs <> entry_digest)

  @doc "SHA-256 of the canonical JSON of the raw command plus the subject id."
  @spec payload_hash(map(), String.t()) :: String.t()
  def payload_hash(command, subject_id) when is_map(command) and is_binary(subject_id),
    do: sha(canonical_json(command) <> @rs <> subject_id)

  @doc "SHA-256 of the canonical JSON of the registration data."
  @spec registration_hash(map()) :: String.t()
  def registration_hash(registration) when is_map(registration),
    do: sha(canonical_json(registration))

  @doc "Key-sorted JSON text of plain data."
  @spec canonical_json(term()) :: String.t()
  def canonical_json(term), do: term |> sort_keys() |> Jason.encode!()

  @doc "Quantity as text at scale 9, never in exponent form."
  @spec quantity_text(Decimal.t()) :: String.t()
  def quantity_text(%Decimal{} = q) do
    text = q |> Decimal.round(9) |> Decimal.to_string(:normal)

    case String.split(text, ".") do
      [int] -> int <> "." <> String.duplicate("0", 9)
      [int, frac] -> int <> "." <> String.pad_trailing(frac, 9, "0")
    end
  end

  @doc "UTC timestamp text with six fractional digits."
  @spec time_text(DateTime.t()) :: String.t()
  def time_text(%DateTime{} = dt) do
    dt = dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond)
    {us, _} = dt.microsecond
    base = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")
    base <> "." <> String.pad_leading(Integer.to_string(us), 6, "0") <> "Z"
  end

  defp record(map, fields), do: fields |> Enum.map(&field(Map.get(map, &1))) |> Enum.join(@us)

  defp field(nil), do: "~"
  defp field(%Decimal{} = d), do: quantity_text(d)
  defp field(%DateTime{} = dt), do: time_text(dt)
  defp field(value) when is_integer(value), do: Integer.to_string(value)
  defp field(value) when is_binary(value), do: value
  defp field(value) when is_map(value) or is_list(value), do: canonical_json(value)

  defp sort_keys(%Decimal{} = d), do: d
  defp sort_keys(%DateTime{} = d), do: d

  defp sort_keys(%{} = map) do
    values =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
      |> Enum.sort_by(&elem(&1, 0))

    %Jason.OrderedObject{values: values}
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other

  defp sha(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
