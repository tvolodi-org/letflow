defmodule Letflow.Ledger.Policy do
  @moduledoc """
  REQ-684 / GH #3698 (decision 0073, note 14.4): the behaviour of a module's posting policy and the
  ONLY `Letflow.*` module a policy file may call. A policy is pure module code that turns a posting
  command into a declarative posting at build time:

      @callback declare(posting_command, registration) :: {:ok, declarative_posting} | {:error, {code, details}}

  Everything here is pure, total and free of I/O (no read, no write, no process, no clock): a
  function never raises on any term and answers `{:error, :invalid}` instead. The static
  allowlist that keeps policy files to this module and a short list of stdlib modules is
  `mix letflow.check_boundaries` (`policy_violations/1`). Core re-validates everything a policy
  returns, so these constructors are conveniences, not trust.

    * `decimal/2` - the canonical decimal grammar (`-?(0|[1-9][0-9]*)(.d{1,scale})?`: no exponent,
      no leading zeros, no `+`, no spaces); a value with more fraction digits than `scale` is
      refused, never rounded. Only text is accepted: a float or an integer is `:invalid`.
    * `uuid/1`, `token/2` - format checks; `token` allows `[a-z0-9._:-]` and a byte cap.
    * `leg/1`, `posting/1` - constructors with a closed key set; unknown keys are dropped.

  Inside the Rule 7 scope (`lib/letflow/ledger/**`): domain-neutral words only.
  """

  @typedoc "The raw command a handler passes to `HandlerWrites.post/3`."
  @type posting_command :: map()

  @typedoc "A leg as the policy declares it (core adds `leg_no`)."
  @type declared_leg :: %{
          required(:k) => [String.t()],
          required(:quantity) => Decimal.t(),
          required(:unit_ref) => String.t(),
          optional(:attrs) => map(),
          optional(:document_line_id) => String.t() | nil
        }

  @typedoc "The declarative posting `declare/2` returns."
  @type declarative_posting :: %{
          required(:ledger_id) => String.t(),
          required(:cause) => String.t(),
          required(:legs) => [declared_leg()],
          optional(atom()) => term()
        }

  @callback declare(posting_command(), registration :: map()) ::
              {:ok, declarative_posting()} | {:error, {code :: atom(), details :: map()}}

  @decimal ~r/\A-?(0|[1-9][0-9]*)(\.[0-9]+)?\z/
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @token ~r/\A[a-z0-9._:-]+\z/

  @leg_keys [:k, :quantity, :unit_ref, :attrs, :document_line_id]

  @posting_keys [
    :ledger_id,
    :cause,
    :legs,
    :reason_code,
    :document_type,
    :document_id,
    :related_document_id,
    :correlation_id,
    :scope_ref,
    :reverses_entry_id
  ]

  @doc "Parses canonical decimal text with at most `scale` fraction digits. Never rounds."
  @spec decimal(term(), 0..9) :: {:ok, Decimal.t()} | {:error, :invalid}
  def decimal(text, scale) when is_binary(text) and is_integer(scale) and scale in 0..9 do
    with true <- byte_size(text) <= 64 and Regex.match?(@decimal, text),
         true <- fraction_digits(text) <= scale,
         {%Decimal{} = value, ""} <- Decimal.parse(text) do
      {:ok, value}
    else
      _ -> {:error, :invalid}
    end
  end

  def decimal(_text, _scale), do: {:error, :invalid}

  defp fraction_digits(text) do
    case String.split(text, ".", parts: 2) do
      [_whole, fraction] -> byte_size(fraction)
      [_whole] -> 0
    end
  end

  @doc "Canonical uuid text, returned in lowercase."
  @spec uuid(term()) :: {:ok, String.t()} | {:error, :invalid}
  def uuid(text) when is_binary(text) do
    if byte_size(text) == 36 and Regex.match?(@uuid, text),
      do: {:ok, String.downcase(text)},
      else: {:error, :invalid}
  end

  def uuid(_other), do: {:error, :invalid}

  @doc "A token of `[a-z0-9._:-]` with 1..`max_bytes` bytes."
  @spec token(term(), pos_integer()) :: {:ok, String.t()} | {:error, :invalid}
  def token(text, max_bytes) when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(text) in 1..max_bytes and Regex.match?(@token, text),
      do: {:ok, text},
      else: {:error, :invalid}
  end

  def token(_text, _max_bytes), do: {:error, :invalid}

  @doc "A leg from a map: only the closed key set is kept, unknown keys are dropped."
  @spec leg(map()) :: declared_leg()
  def leg(fields) when is_map(fields), do: Map.take(fields, @leg_keys)

  @doc "A declarative posting from a map: only the closed key set is kept."
  @spec posting(map()) :: declarative_posting()
  def posting(fields) when is_map(fields), do: Map.take(fields, @posting_keys)
end
