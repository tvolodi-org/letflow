defmodule Letflow.Entities.ExternalRef do
  @moduledoc """
  Pure parser/validator for the master `external_ref` `{system, id}` pair (GH #2659 / REQ-505,
  decision 0057 D1; design `lib/letflow/design/gh2659-external-ref-idempotent-import.md` §2.3).

  No database access and no side effects.

    * Exactly the keys `"system"` and `"id"`, both strings; an unknown key, a non-object, or a
      missing key is `{:error, :external_ref_invalid}`.
    * `system`: 1..64 bytes, `[a-z0-9][a-z0-9._-]*` (lower-case slug). Never case-folded: a
      mixed-case system is rejected, not normalised.
    * `id`: 1..255 bytes, valid UTF-8, no control (`\\p{Cc}`, which includes NUL, tab and
      newline) and no format (`\\p{Cf}`, for example zero-width and bidi marks) characters, not
      all whitespace (Unicode whitespace such as U+00A0 and U+3000 counts as whitespace).
      Compared byte-exact (no trim, no fold): an ordinary interior or surrounding space is kept.
      A numeric source id is sent as a string.

  The error carries no detail (no echo of the offending value).

  The design (section 2.3) says "no NUL"; rejecting the wider control/format classes is a
  deliberate tightening (an id with an invisible character cannot be told apart by eye from
  another id and is almost certainly a bad export). The registered event schema v2 bounds the
  same fields by character count (`maxLength` counts characters, this parser counts bytes, so
  the parser is the stricter) and its `pattern` keyword is inert in the platform's JSON Schema
  subset. This parser is the real gate, and the projector re-parses a stored `external_ref` so
  a stream that bypassed it fails the rebuild explicitly.

  ## Evolution rule (durable)

  `Projector` rebuild re-parses every stored CREATED `external_ref` with THIS parser, including
  events written years ago. The parser may therefore only be LOOSENED for history. Tightening it
  (a narrower system slug, a shorter limit, a new forbidden class) would make old, valid events
  fail every rebuild; a tightening needs a NEW event schema version (v3) and a parse that is
  chosen by the event's schema version. `test/letflow/entities/external_ref_test.exs` holds a
  frozen corpus of values that were valid at PR-1 and must stay valid.

  ## Trade-off: format characters

  Rejecting `\\p{Cf}` also rejects the zero-width (non-)joiners U+200C and U+200D, which some
  scripts (for example Persian, Indic scripts) use inside legitimate words. An id from such a
  source must be sent without them. This was accepted over allowing invisible characters that
  make two ids indistinguishable by eye.
  """

  @system_max_bytes 64
  @id_max_bytes 255
  @system_pattern ~r/\A[a-z0-9][a-z0-9._-]*\z/
  @forbidden_id_chars ~r/[\p{Cc}\p{Cf}]/u

  @enforce_keys [:system, :id]
  defstruct [:system, :id]

  @typedoc "A validated pair: both halves are set, a half-set pair has no representation."
  @type t :: %__MODULE__{system: String.t(), id: String.t()}

  @typedoc "The validator's plain-map result (see `parse/1`)."
  @type parsed :: %{system: String.t(), id: String.t()}

  @type columns :: %{external_system: String.t() | nil, external_id: String.t() | nil}

  # ---- the one conversion point: payload <-> struct <-> columns ----

  @doc """
  Wire map (`%{"system" => _, "id" => _}`) to a validated `%ExternalRef{}`. Production callers
  use this; `parse/1` is the validator underneath and keeps its plain-map result.
  """
  @spec from_payload(term()) :: {:ok, t()} | {:error, :external_ref_invalid}
  def from_payload(payload) do
    with {:ok, %{system: system, id: id}} <- parse(payload) do
      {:ok, %__MODULE__{system: system, id: id}}
    end
  end

  @doc "Struct to the wire map; byte-identical to the pair the event payload has always carried."
  @spec to_payload(t()) :: %{String.t() => String.t()}
  def to_payload(%__MODULE__{system: system, id: id}), do: %{"system" => system, "id" => id}

  @doc "Struct (or nil) to the two `entity_record_latest` columns; always both keys, set together."
  @spec to_columns(t() | nil) :: columns()
  def to_columns(nil), do: %{external_system: nil, external_id: nil}

  def to_columns(%__MODULE__{system: system, id: id}),
    do: %{external_system: system, external_id: id}

  @doc """
  The two stored columns to a value: nil/nil is `{:ok, nil}`, both binaries are validated, and a
  half-set pair is refused (`{:error, :external_ref_invalid}`) before it can reach the database.
  """
  @spec from_columns(String.t() | nil, String.t() | nil) ::
          {:ok, t() | nil} | {:error, :external_ref_invalid}
  def from_columns(nil, nil), do: {:ok, nil}

  def from_columns(system, id) when is_binary(system) and is_binary(id),
    do: from_payload(%{"system" => system, "id" => id})

  def from_columns(_system, _id), do: {:error, :external_ref_invalid}

  @doc """
  Validator with a plain-map result (`{:ok, %{system:, id:}}`). Kept for its existing contract
  (GH #2659 tests compare it with `==` to a plain map); production code goes through
  `from_payload/1`.
  """
  @spec parse(term()) :: {:ok, parsed()} | {:error, :external_ref_invalid}
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
      not Regex.match?(@forbidden_id_chars, id) and String.trim(id) != ""
  end
end
