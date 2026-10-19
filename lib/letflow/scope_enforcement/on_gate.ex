defmodule Letflow.ScopeEnforcement.OnGate do
  @moduledoc """
  The six facts the `shadow -> on` flip must satisfy (REQ-519 2f-a, GH #2535, AC 9 and 10;
  design `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 4.4, SEC rulings
  C-4, S-4 and S-5 of
  `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-04-security-reviewer-design.json`).

  `evaluate/3` is a set of PLAIN READS (no lock of its own, no write, no audit). Inside
  `Letflow.ScopeEnforcement.flip/4` it runs after the tenant admin lock (A), the `tenants` row
  (T) and the scope-tree table lock (S), so it sees the flip transaction's locks; the
  integrity endpoint (`GET /integrity`, via `ScopeEnforcement.integrity/1`) calls it with NO lock,
  a labelled snapshot. The flip evaluates it for a target `on` (`shadow -> on` only, REQ-519
  2f-b); the wire shapes below are the ONE serialisation shared by the audit entries, the 409
  refusal body and the integrity endpoint.

  Facts, in read order; ALL six are evaluated every time so a refusal names every failure:

    1. `bindings_without_row` -- T9, `RoleScopeGrants.bindings_without_row_count/1`, fails when > 0.
    2. `org_inconsistent` -- `ScopeNodePaths.Consistency.check/1`, fails unless status `:ok`
       (a read error counts as `:unavailable`, which fails).
    3. `tokens_exceed_owner` -- `TokenPreconditions.exceeding_owner_count/1`, fails when > 0
       (tokens of a flagged service-principal owner STILL count).
    4. `zero_tenant_wide_admins` -- `Letflow.Identity.count_interactive_explicit_tenant_wide_admins/1`
       (SEC C-4: active, interactive, explicit; no token owner, no flagged service principal),
       fails when = 0. The flip route is interactive-only, so a tenant with no such admin
       could not be switched off through the API.
    5. `scoped_approvers_without_task_scope` -- `Letflow.Identity.ScopedApprovers.count/1`
       `approvers`, fails when > 0 (removed only by the requirement that ships a writer for
       `tasks.scope_node_id`). The count of scoped task workers who are not approvers is
       INFORMATIONAL and never blocks.
    6. `shadow_evidence_insufficient` -- `Letflow.ScopeEnforcement.ShadowWindow.evaluate/3`.

  A raise anywhere propagates (INV-8): inside the flip it rolls the transaction back, no flag
  change, answered as a server fault and NOT recorded as a refusal. The report holds counts,
  enums and booleans only: no id, no name, no token data (INV-2).
  """

  alias Letflow.Identity
  alias Letflow.Identity.ScopedApprovers
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.ShadowWindow

  @type on_precondition ::
          :bindings_without_row
          | :org_inconsistent
          | :tokens_exceed_owner
          | :zero_tenant_wide_admins
          | :scoped_approvers_without_task_scope
          | :shadow_evidence_insufficient

  @type report :: %{
          bindings_without_row: non_neg_integer(),
          org_consistency: :ok | :inconsistent | :unavailable,
          tokens_exceeding_owner: non_neg_integer(),
          explicit_tenant_wide_admins: non_neg_integer(),
          scoped_approvers: non_neg_integer(),
          scoped_task_workers_without_task_scope: non_neg_integer(),
          evidence: ShadowWindow.report()
        }

  @doc """
  The audit shape of a report (design 4.1, 4.3): string keys, counts, enums and booleans only
  (no id, no timestamp of a person, no token data). `"preconditions"` holds the six counts;
  `"evidence"` the six would-deny counts, the request total, the days without requests, the
  per-criterion booleans and `evidence_scope`.
  """
  @spec audit_state(report()) :: %{String.t() => map()}
  def audit_state(report) do
    %{
      "preconditions" => counts_with_task_workers(report),
      "evidence" => evidence_state(report.evidence)
    }
  end

  @doc """
  The five blocking counts as a string-keyed map (`bindings_without_row`, `org_consistency`,
  `tokens_exceeding_owner`, `explicit_tenant_wide_admins`, `scoped_approvers`), read from an
  `t:report/0` or from the `counts` of the integrity snapshot.
  """
  @spec counts_state(map()) :: %{String.t() => term()}
  def counts_state(counts) do
    %{
      "bindings_without_row" => counts.bindings_without_row,
      "org_consistency" => Atom.to_string(counts.org_consistency),
      "tokens_exceeding_owner" => counts.tokens_exceeding_owner,
      "explicit_tenant_wide_admins" => counts.explicit_tenant_wide_admins,
      "scoped_approvers" => counts.scoped_approvers
    }
  end

  @doc """
  `counts_state/1` plus the informational `scoped_task_workers_without_task_scope` of a full
  `t:report/0` (the audit `"preconditions"` map and the 409 `report`).
  """
  @spec counts_with_task_workers(report()) :: %{String.t() => term()}
  def counts_with_task_workers(report) do
    Map.put(
      counts_state(report),
      "scoped_task_workers_without_task_scope",
      report.scoped_task_workers_without_task_scope
    )
  end

  @doc """
  The evidence summary as a string-keyed map: the six would-deny counts, `requests`,
  `days_without_requests`, the per-criterion booleans and `evidence_scope`. The window dates
  and `shadow_since` are NOT in it (the audit never stored them); callers that show them add
  them.
  """
  @spec evidence_state(ShadowWindow.report()) :: %{String.t() => term()}
  def evidence_state(evidence) do
    %{
      "would_deny" =>
        Map.new(evidence.would_deny, fn {reason, count} -> {Atom.to_string(reason), count} end),
      "requests" => evidence.requests,
      "days_without_requests" => evidence.days_without_requests,
      "criteria" =>
        Map.new(evidence.criteria, fn {name, met?} -> {Atom.to_string(name), met?} end),
      "evidence_scope" => evidence.evidence_scope
    }
  end

  @doc """
  Evaluates the six facts for the tenant at the instant `now`. Returns the report and the
  failing fact codes, in read order (empty when the gate is satisfied).
  """
  @spec evaluate(tenant_id :: Ecto.UUID.t(), prefix :: String.t(), now :: DateTime.t()) ::
          {report(), failed :: [on_precondition()]}
  def evaluate(tenant_id, prefix, %DateTime{} = now) when is_binary(prefix) do
    facts = ScopeEnforcement.preconditions(prefix)
    admins = Identity.count_interactive_explicit_tenant_wide_admins(prefix)
    approvers = ScopedApprovers.count(prefix)
    {evidence, evidence_ok?} = ShadowWindow.evaluate(tenant_id, prefix, now)

    report = %{
      bindings_without_row: facts.bindings_without_row,
      org_consistency: facts.org_consistency,
      tokens_exceeding_owner: facts.tokens_exceeding_owner,
      explicit_tenant_wide_admins: admins,
      scoped_approvers: approvers.approvers,
      scoped_task_workers_without_task_scope: approvers.task_workers_not_approvers,
      evidence: evidence
    }

    failed =
      [
        {:bindings_without_row, report.bindings_without_row > 0},
        {:org_inconsistent, report.org_consistency != :ok},
        {:tokens_exceed_owner, report.tokens_exceeding_owner > 0},
        {:zero_tenant_wide_admins, report.explicit_tenant_wide_admins == 0},
        {:scoped_approvers_without_task_scope, report.scoped_approvers > 0},
        {:shadow_evidence_insufficient, not evidence_ok?}
      ]
      |> Enum.filter(fn {_code, failed?} -> failed? end)
      |> Enum.map(fn {code, _failed?} -> code end)

    {report, failed}
  end
end
