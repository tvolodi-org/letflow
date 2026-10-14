defmodule Letflow.Engine.ScriptTaskDispatcher.RunRecord do
  @moduledoc """
  GH 2534 PR 7c-1 (decision 0053 D9): the allowlist constructor of the `SCRIPT_RUN_RECORDED`
  payload (design `lib/letflow/design/gh2534-7c-script-handler.md` section 7.1, C12, C13).

  `build/1` reads ONLY the listed `run_facts` fields and the dispatch row's `id, node_id,
  attempt, script_key, script_version, script_sha256, triggering_user_id`. The record holds no
  input value, no output value, no fail `details`, no print buffer and no source: the input is
  represented only by its HMAC and the secret's `key_id`. Pure.
  """

  @keys ~w(dispatch_id node_id attempt script_key script_version script_sha256 phase outcome
           detail fail_code input_hmac input_hmac_key_version duration_us instructions_used
           heap_words input_dropped principal triggering_user_id)

  @doc "The exact key set of every record (section 7.1)."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The `SCRIPT_RUN_RECORDED` payload for one terminal attempt."
  @spec build(Letflow.Engine.ScriptTaskDispatcher.run_facts()) ::
          Letflow.Engine.ScriptTaskDispatcher.run_record()
  def build(%{row: row, phase: phase, outcome: outcome} = facts) do
    {key_version, hex} =
      case Map.get(facts, :hmac) do
        {key_version, hex} when is_integer(key_version) and is_binary(hex) -> {key_version, hex}
        _none -> {nil, nil}
      end

    stats = Map.get(facts, :stats) || %{}

    %{
      "dispatch_id" => row.id,
      "node_id" => row.node_id,
      "attempt" => row.attempt,
      "script_key" => row.script_key,
      "script_version" => row.script_version,
      "script_sha256" => row.script_sha256,
      "phase" => Atom.to_string(phase),
      "outcome" => Atom.to_string(outcome),
      "detail" => code_string(Map.get(facts, :detail)),
      "fail_code" => fail_code(Map.get(facts, :fail_code)),
      "input_hmac" => hex,
      "input_hmac_key_version" => key_version,
      "duration_us" => integer_or_nil(Map.get(stats, :duration_us)),
      "instructions_used" => integer_or_nil(Map.get(stats, :instructions_used)),
      "heap_words" => integer_or_nil(Map.get(stats, :heap_words)),
      "input_dropped" => integer_or_nil(Map.get(stats, :input_dropped)),
      "principal" => "script:#{row.script_key}@#{row.script_version}",
      "triggering_user_id" => row.triggering_user_id
    }
  end

  defp code_string(nil), do: nil
  defp code_string(code) when is_atom(code), do: Atom.to_string(code)

  # A fail code is a manifest code (`^[a-z][a-z0-9_]{0,63}$`, validated by the runtime against
  # `fail_codes`); anything else is never recorded.
  defp fail_code(code) when is_binary(code) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, code), do: code, else: nil
  end

  defp fail_code(_code), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil
end
