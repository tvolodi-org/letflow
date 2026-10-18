defmodule Letflow.Entities.ExternalRef do
  @moduledoc """
  Pure parser/validator for the master `external_ref` `{system, id}` pair (GH #2659 / REQ-505,
  decision 0057 D1; design `lib/letflow/design/gh2659-external-ref-idempotent-import.md` §2.3).

  No database access and no side effects.

    * Exactly the keys `"system"` and `"id"`, both strings; an unknown key, a non-object, or a
      missing key is `{:error, :external_ref_invalid}`.
    * `system`: 1..64 bytes, `[a-z0-9][a-z0-9._-]*` (lower-case slug). Never case-folded: a
      mixed-case system is rejected, not normalised.
    * `id`: 1..255 bytes, valid UTF-8, no NUL, not all whitespace. Compared byte-exact (no trim,
      no fold). A numeric source id is sent as a string.

  The error carries no detail (no echo of the offending value).
  """

  @system_max_bytes 64
  @id_max_bytes 255
  @system_pattern ~r/\A[a-z0-9][a-z0-9._-]*\z/

  @type t :: %{system: String.t(), id: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :external_ref_invalid}
  def parse(%{"system" => system, "id" => id} = ref)
      when map_size(ref) == 2 and is_binary(system) and is_binary(id) do
    if valid_system?(system) and valid_id?(id) do
      {:ok, %{system: system, id: id}}
    else
      {:error, :external_ref_invalid}
    end
  end

  def parse(_other), do: {:error, :external_ref_invalid}

  defp valid_system?(system),
    do: byte_size(system) in 1..@system_max_bytes and Regex.match?(@system_pattern, system)

  defp valid_id?(id) do
    byte_size(id) in 1..@id_max_bytes and String.valid?(id) and
      not String.contains?(id, <<0>>) and String.trim(id) != ""
  end
end
