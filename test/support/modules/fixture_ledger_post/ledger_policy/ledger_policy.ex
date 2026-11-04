defmodule Letflow.Modules.FixtureLedgerPost.LedgerPolicy do
  @moduledoc """
  The posting policy of `Letflow.Modules.FixtureLedgerPost` (REQ-684). Pure: it builds a
  declarative posting from an atom-keyed command through `Letflow.Ledger.Policy` only, so the
  allowlist scan of `mix letflow.check_boundaries` (`policy_violations/1`) accepts it.

  A command is `%{ledger_id, cause, legs: [%{k: [text], quantity: "decimal text", unit_ref: token}]}`;
  a bad leg gives `{:error, {:invalid_posting, %{leg_no: n, reason: reason}}}`.
  """

  @behaviour Letflow.Ledger.Policy

  alias Letflow.Ledger.Policy

  # Test hooks (build-time failure paths of REQ-685): the policy misbehaves on request.
  @impl Letflow.Ledger.Policy
  def declare(%{explode: :raise}, _registration), do: raise("secret-policy-text")
  def declare(%{explode: :exit}, _registration), do: exit(:secret_policy_text)
  def declare(%{explode: :throw}, _registration), do: throw(:secret_policy_text)
  def declare(%{explode: :other_code}, _registration), do: {:error, {:other_code, %{}}}
  def declare(%{explode: :not_a_tuple}, _registration), do: :nope
  def declare(%{explode: :bad_reason}, _registration), do: invalid(2, :weird_reason)

  def declare(%{ledger_id: ledger_id, cause: cause, legs: legs} = command, _registration)
      when is_list(legs) do
    with {:ok, built} <- build_legs(legs) do
      header =
        Map.take(command, [
          :reason_code,
          :document_type,
          :document_id,
          :related_document_id,
          :scope_ref,
          :reverses_entry_id
        ])

      {:ok, Policy.posting(Map.merge(header, %{ledger_id: ledger_id, cause: cause, legs: built}))}
    end
  end

  def declare(_command, _registration), do: invalid(nil, :posting_shape)

  defp build_legs(legs) do
    legs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {leg, number}, {:ok, acc} ->
      case build_leg(leg) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        {:error, reason} -> {:halt, invalid(number, reason)}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_leg(%{k: k, quantity: quantity, unit_ref: unit} = leg) when is_list(k) do
    with {:ok, amount} <- tag(Policy.decimal(quantity, 9), :quantity_invalid),
         {:ok, unit_ref} <- tag(Policy.token(unit, 32), :unit_invalid) do
      {:ok, Policy.leg(Map.merge(leg, %{k: k, quantity: amount, unit_ref: unit_ref}))}
    end
  end

  defp build_leg(_leg), do: {:error, :posting_shape}

  defp tag({:ok, value}, _reason), do: {:ok, value}
  defp tag({:error, _}, reason), do: {:error, reason}

  defp invalid(leg_no, reason),
    do: {:error, {:invalid_posting, %{leg_no: leg_no, reason: reason}}}
end
