defmodule Letflow.Documents.FormTemplate do
  @moduledoc """
  Pure company DOCX validation (decision 0089, S1). Nothing is stored or rendered.

  ZIP budgets apply to real inflated bytes. The sanitizer parses kept XML once;
  the legal-field check reads that same tree. Package.write/1 is the only XML
  writer and wraps every text child as `{:characters, text}` before Saxy encoding:
  plain binary children would otherwise become raw XML (0056 T10).

  Only bare closed-list names are supported. Headers/footers, textboxes and
  non-plain runs cannot contain placeholders. Refusals contain fixed codes and
  structural positions, never company text or unknown names. Totals data names
  belong to S2. Storage and versions: `Letflow.Documents.OfficialFormTemplates` (S4a). Routes and permission:
  S4b (`Letflow.Routers.Documents`); printing belongs to S3.
  """
  alias __MODULE__.{Check, Keys, Package, Sanitizer}

  @codes ~w(unknown_form too_large infected scan_unavailable not_docx zip_too_many_entries
    zip_bad_entry zip_inflated_too_large zip_ratio forbidden_part image_type image_too_large
    macro_enabled xml_unreadable doctype external_relationship unsupported_reference
    field_code tracked_change data_binding malformed_placeholder placeholder_not_plain
    unknown_name missing_legal duplicate_legal missing_data repeat_row column_order total_place)a

  @type refusal :: %{
          code: atom(),
          rule: String.t(),
          place: map() | nil,
          name: String.t() | nil,
          category: atom() | nil
        }
  @type result :: %{bytes: binary(), sha256: String.t(), summary: map()}

  @spec refusal_codes() :: [atom()]
  def refusal_codes, do: @codes

  @spec limits() :: map()
  def limits do
    %{
      compressed: 1_048_576,
      inflated: 10_485_760,
      entries: 200,
      ratio: 100,
      image: 524_288,
      depth: 256,
      name: 64,
      refusals: 100
    }
  end

  @doc "Validates an upload and returns only rewritten, verified bytes and a structure summary."
  @spec check(String.t(), binary(), keyword()) :: {:ok, result()} | {:error, [refusal()]}
  def check(form, bytes, opts \\ []) do
    case Keys.for_form(form) do
      :error ->
        error(:unknown_form, "D3")

      {:ok, keys} ->
        with :ok <- Package.size(bytes),
             :ok <-
               Sanitizer.scan(
                 bytes,
                 "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 opts
               ),
             {:ok, parts} <- Package.read(bytes),
             {:ok, clean} <- Sanitizer.run(parts, opts),
             :ok <- Check.run(clean.occurrences, keys),
             {:ok, output} <- Package.write(clean.parts) do
          counts =
            Enum.frequencies_by(clean.occurrences, fn o ->
              if String.starts_with?(o.name, "legal."), do: :legal, else: :data
            end)

          {:ok,
           %{
             bytes: output,
             sha256: :crypto.hash(:sha256, output) |> Base.encode16(case: :lower),
             summary:
               Map.put(clean.summary, :placeholders, Map.merge(%{legal: 0, data: 0}, counts))
           }}
        end
    end
  end

  @doc false
  def error(code, rule \\ "D4", place \\ nil, name \\ nil, category \\ nil),
    do: {:error, [%{code: code, rule: rule, place: place, name: name, category: category}]}
end
