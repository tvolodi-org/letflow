defmodule Letflow.Audit.Reason do
  @moduledoc """
  The one shared rule for a free-text reason that is written to an audit entry
  (REQ-497 PR 1b, design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section
  3.5; extracted unchanged from GH 2524's `RoleRegistry.rebind_role/4`).

  A reason is shown to audit readers, so it must be one plain line: a string, trimmed,
  1..500 codepoints, with no `Cc` (C0, DEL, C1), `Cf` (format/bidi characters such as
  U+200B..U+200F, U+202A..U+202E, U+2066..U+2069, U+FEFF), `Zl` or `Zp` (U+2028, U+2029)
  character, so it cannot visually spoof an audit reader.

  Callers: `Letflow.Identity.RoleRegistry.rebind_role/4` and
  `Letflow.ScopeEnforcement.flip/4`. Pure, never raises.
  """

  @max_codepoints 500
  @forbidden_pattern ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  @doc """
  `{:ok, trimmed}` when `reason` is acceptable (see the moduledoc), else `:error`.
  Codepoints are counted, not graphemes.
  """
  @spec validate(term()) :: {:ok, String.t()} | :error
  def validate(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    if String.valid?(trimmed) and length(String.codepoints(trimmed)) in 1..@max_codepoints and
         not String.match?(trimmed, @forbidden_pattern) do
      {:ok, trimmed}
    else
      :error
    end
  end

  def validate(_reason), do: :error
end
