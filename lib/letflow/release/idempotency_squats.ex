defmodule Letflow.Release.IdempotencySquats do
  @moduledoc """
  GH #2597 -- operator entry points for auditing and remediating pre-#2550 idempotency-key
  squats (design `lib/letflow/design/gh2597-pre-namespace-squat-audit.md`, section 3).

  Call these through the running node: `bin/letflow rpc` (release) or the Mix tasks
  `mix letflow.audit_idempotency_squats` / `mix letflow.remediate_idempotency_squat`
  (dev checkout). `bin/letflow eval` is NOT supported: it does not start `Letflow.Repo`, and
  these functions start nothing. See `docs/runbooks/idempotency-key-squat-audit.md`.

  Both functions print their result with `IO.puts` (rpc forwards stdout) and ALSO return it.
  They never call `System.halt`: a halt inside `rpc` would stop the live node. Only the Mix
  tasks halt, from the returned value.

  The name sits under `Letflow.Release.` without defining `Letflow.Release`, so it cannot
  collide with the wrapper module of GH #2567.

  ## Output (INV-4)

  Ids, keys, event types, timestamps and counts. Never a payload or `field_values`. A key is
  squatter-chosen text, so it is printed through `inspect/1`, which escapes control characters.
  Pass/fail is a `SUMMARY` line (audit) or an `OK`/`ERROR` line (remediation), not an exit status.
  """

  alias Letflow.Idempotency.SquatAudit
  alias Letflow.Idempotency.SquatRemediation
  alias Letflow.TenantProvisioning

  @type audit_summary :: %{
          scanned: non_neg_integer(),
          flagged: non_neg_integer(),
          report_only: non_neg_integer(),
          errored: [Ecto.UUID.t()]
        }

  @doc """
  Read-only audit of every registered tenant. Prints one line per non-clear finding and one
  `TENANT` count line per tenant, then a `SUMMARY` line. A tenant that fails is listed in
  `errored` and the others still run.
  """
  @spec audit() :: {:ok, audit_summary()}
  def audit do
    results = SquatAudit.scan_all()

    summary =
      Enum.reduce(results, %{scanned: 0, flagged: 0, report_only: 0, errored: []}, fn
        {registration, {:ok, %{scanned: scanned, findings: findings}}}, acc ->
          flagged = Enum.count(findings, &(&1.verdict == :flagged))
          report_only = length(findings) - flagged
          Enum.each(findings, &IO.puts(format_finding(&1)))

          IO.puts(
            "TENANT tenant=#{registration.tenant_id} schema=#{registration.schema_name} " <>
              "scanned=#{scanned} flagged=#{flagged} report_only=#{report_only} errored=0"
          )

          %{
            acc
            | scanned: acc.scanned + scanned,
              flagged: acc.flagged + flagged,
              report_only: acc.report_only + report_only
          }

        {registration, {:error, reason}}, acc ->
          IO.puts(
            "TENANT tenant=#{registration.tenant_id} schema=#{registration.schema_name} " <>
              "errored=1 error=#{format_error(reason)}"
          )

          %{acc | errored: acc.errored ++ [registration.tenant_id]}
      end)

    IO.puts(
      "SUMMARY tenants=#{length(results)} scanned=#{summary.scanned} flagged=#{summary.flagged} " <>
        "report_only=#{summary.report_only} errored=#{length(summary.errored)}"
    )

    {:ok, summary}
  end

  @doc """
  Removes the ONE flagged squat row for exact `key` in tenant `tenant_id` (see
  `Letflow.Idempotency.SquatRemediation`). Prints the resolved tenant and schema before acting.
  """
  @spec remediate(tenant_id :: String.t(), key :: String.t(), operator :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def remediate(tenant_id, key, operator) do
    case resolve(tenant_id) do
      {:ok, canonical, schema} ->
        IO.puts("TARGET tenant=#{canonical} schema=#{schema} key=#{inspect(key)}")
        report(SquatRemediation.remediate(canonical, key, operator))

      :error ->
        report({:error, :unknown_tenant})
    end
  end

  @doc "Maps an `audit/0` result to a process exit status (used by the Mix task only)."
  @spec audit_exit_code({:ok, audit_summary()}) :: 0 | 1
  def audit_exit_code({:ok, %{errored: []}}), do: 0
  def audit_exit_code({:ok, %{errored: _}}), do: 1

  @doc "Maps a `remediate/3` result to a process exit status (used by the Mix task only)."
  @spec remediate_exit_code({:ok, map()} | {:error, term()}) :: 0 | 1
  def remediate_exit_code({:ok, _}), do: 0
  def remediate_exit_code({:error, _}), do: 1

  # -------------------------------------------------------------------------

  defp resolve(tenant_id) when is_binary(tenant_id) do
    with {:ok, canonical} <- Ecto.UUID.cast(tenant_id),
         {:ok, schema} <- TenantProvisioning.registered_schema(canonical) do
      {:ok, canonical, schema}
    else
      _ -> :error
    end
  end

  defp resolve(_), do: :error

  defp report({:ok, %{outcome: outcome, key: key}} = ok) do
    IO.puts("OK outcome=#{outcome} key=#{inspect(key)}")
    ok
  end

  defp report({:error, {:not_flagged, finding}} = error) do
    IO.puts("ERROR not_flagged " <> format_finding(finding))
    error
  end

  defp report({:error, reason} = error) do
    IO.puts("ERROR #{format_error(reason)}")
    error
  end

  defp format_finding(f) do
    fields =
      [
        {"tenant", Map.get(f, :tenant_id)},
        {"schema", Map.get(f, :schema)},
        {"verdict", f.verdict},
        {"reason", f.reason},
        {"family", f.family},
        {"key", f.key},
        {"event_type", f.event_type},
        {"stored_actor", f.stored_actor},
        {"expected_actor", f.expected_actor},
        {"target_id", f.target_id},
        {"squat_entity_type", f.squat_entity_type},
        {"squat_record_id", f.squat_record_id},
        {"event_created_at", f.event_created_at},
        {"inserted_at", f.inserted_at}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_value(v)}" end)

    "FLAG " <> fields
  end

  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  # inspect/1 escapes control characters in squatter-chosen text.
  defp format_value(v) when is_binary(v), do: inspect(v)

  # Never prints a Postgrex message (may quote data): the SQLSTATE atom only.
  defp format_error({:query_failed, %Postgrex.Error{postgres: %{code: code}}}),
    do: "query_failed:#{code}"

  defp format_error({:query_failed, _}), do: "query_failed"
  defp format_error({:audit_failed, _}), do: "audit_failed"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(_), do: "error"
end
