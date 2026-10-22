defmodule Letflow.Scripts.HmacSecret.Backfill do
  @moduledoc """
  GH 2534 7b-1 / GH #2567: the core of the script-input HMAC key backfill, shared by
  `mix letflow.backfill_script_hmac_secrets` and `Letflow.Release.backfill_script_hmac_secrets/1`
  (a release has no Mix, so the core lives in the Letflow namespace, not in a Mix task).

  Never prints or halts, and never returns a key or an exception text (INV-4).
  """

  alias Letflow.Scripts.HmacSecret

  @doc """
  Ensures the key for each of `registrations` (anything carrying `tenant_id`). Returns
  `{created, already_present, failed_tenant_ids}`.
  """
  @spec run([%{required(:tenant_id) => Ecto.UUID.t()}]) ::
          {non_neg_integer(), non_neg_integer(), [Ecto.UUID.t()]}
  def run(registrations) do
    {created, present, failed} =
      Enum.reduce(registrations, {0, 0, []}, fn %{tenant_id: tenant_id}, {c, p, f} ->
        cond do
          HmacSecret.exists?(tenant_id) -> {c, p + 1, f}
          ensure(tenant_id) == :ok -> {c + 1, p, f}
          true -> {c, p, [tenant_id | f]}
        end
      end)

    {created, present, Enum.reverse(failed)}
  end

  # A tenant whose secret cannot be written (unknown tenant, missing master key) is a counted
  # failure, never a raise that aborts the others; no exception text is kept (INV-4, INV-8).
  defp ensure(tenant_id) do
    HmacSecret.ensure(%{id: tenant_id})
  rescue
    _exception -> :error
  end
end
