defmodule Letflow.Identity.RoleBackfill do
  @moduledoc """
  ISS-0886: one-time-per-tenant remediation for tenants provisioned before
  ISS-0778 shipped (2026-09-22) and therefore never got the platform-role
  `Group`+`TenantRole` bindings (`Letflow.Api.Authorization.roles/0`) that
  `Letflow.TenantOnboarding.provision_and_migrate/1` now seeds automatically
  at tenant-creation time. Without those rows, every non-admin OIDC user on
  such a tenant reads `roles: []` from `Letflow.Identity.list_effective_role_names/2`
  and gets 403 everywhere — see `docs/issues/ISS-0886.yaml` for the full
  root-cause writeup, `lib/letflow/design/iss0886-role-backfill-preexisting-tenants.md`
  for the design this module implements exactly (§2.1).

  `run/0` iterates every tenant schema via
  `Letflow.TenantProvisioning.list_registrations/0` (the same registry
  `Letflow.TenantProvisioning.replay_all_pending/0` sweeps) and calls
  `Letflow.Identity.RoleRegistry.seed_default_platform_role_groups/1`
  (completely unmodified — its own `get_or_create_group_by_name/2`/
  `upsert_role/4` upsert semantics are already idempotent, design §1) once per
  tenant. Sequential `Enum.reduce_while/3`, deliberately NOT
  `Task.async_stream/3` — REQ-045's "row-lock arbitration over per-unit
  concurrent processes" decision, the same rationale
  `Letflow.TenantProvisioning.replay_all_pending/0`'s own moduledoc cites for
  the identical shape.

  Before seeding each tenant, this module reads how many platform-role
  `tenant_role` rows that tenant already held (a read-only classification
  query, not a new write path) so the accumulated result can tell an operator
  which tenants were genuinely affected (`:seeded`, missed a seedable role
  before this call) from which were already fully seeded (`:unchanged`,
  a true no-op write) — design §2.1 step 2, resolving the design's OQ-2 in
  favor of keeping the split: the issue's own `fix_direction` implies
  operators want to know which tenants changed, to narrow what needs
  re-verifying after a QA run.

  A hard failure on one tenant halts the sweep immediately
  (`{:error, {:backfill_failed, tenant_id, reason}}`) rather than silently
  skipping it — every `{:error, _}` `seed_default_platform_role_groups/1` can
  return is a genuine failure needing operator attention, unlike
  `Letflow.TenantProvisioning.Backfill.run/1`'s own third `:skipped` bucket
  for its legitimate "duplicate version" case, which has no analogue here
  (design §2.1 step 2). No rollback of tenants already processed before the
  halt — matches `seed_default_platform_role_groups/1`'s own documented
  no-compensating-rollback precedent (design §7 INV-BF4); a retried `run/0`
  call converges the remaining tenants via idempotency (INV-BF3).

  ## Deviation from the design doc, flagged for REVIEWER (not silently forced)

  Design §2.1 step 2 only pattern-matches `seed_default_platform_role_groups/1`'s
  `{:ok, _}` / `{:error, reason}` return shapes. Empirically confirmed (ad hoc
  probe against a real Postgres tenant schema, dropped mid-run): that function
  does **not** itself guard against its tenant schema having vanished the way
  `Letflow.EventStore.Registry.register_type/2` does (which returns
  `{:error, :tenant_schema_missing}` — the exact case
  `Letflow.TenantProvisioning.Backfill.run/1` pattern-matches on) — it instead
  lets the underlying `Postgrex.Error` (`undefined_table`) propagate as a raised
  exception. Implemented as designed, `process_registration/2` below would
  crash this sweep instead of halting cleanly with an actionable tenant_id on
  exactly the ISS-0343-shaped race `replay_all_pending/0` itself defends
  against one function away in the very module this design cites as its
  sequential-loop precedent. This module therefore adds the identical
  `try/rescue` `replay_all_pending/0` already uses for this exact scenario,
  converting an unexpected exception into the same
  `{:error, {:backfill_failed, tenant_id, reason}}` shape a genuine
  `seed_default_platform_role_groups/1` error return produces — no new
  abstraction, no behavior change to `RoleRegistry` itself, just the one
  missing safety net this design's own cited precedent already establishes as
  this codebase's convention for a cross-tenant sweep.

  No `Repo.transaction/1` wrapping the whole sweep — each tenant's own
  `seed_default_platform_role_groups/1` call is already internally
  transactional per `upsert_role/4`; holding one DB connection/transaction
  open across every tenant schema for the sweep's full duration is a shape
  this codebase consistently avoids elsewhere (neither
  `replay_all_pending/0` nor `Letflow.TenantProvisioning.Backfill.run/1` wrap
  their outer loop in a transaction either).

  Writes only `groups`/`tenant_role` rows, in whichever tenant schema it is
  currently processing (design §7 INV-BF1) — never a `group_members` row
  (INV-BF2): seeding a role binding does not by itself grant any existing
  user membership in it. A backfilled tenant's existing users still need
  their next login (`Letflow.Identity.sync_role_claims_from_token/3`) or an
  explicit `Letflow.Identity.add_group_member/3` call to actually gain a
  grant.

  GH 2558: the reset never re-opens an explicit revocation. The next IdP sync withholds a group
  whose revocation is in force (`Letflow.Identity.RoleRevocations`), so a user an admin removed
  from TENANT_ADMIN does not regain it, while still receiving newly seeded roles. The
  `role_claims_sync.reset` audit row lists those users in `revocation_honored_user_ids`.

  GH 2572 (closes GH 2547 FU-1): each tenant's seed, marker reset and audit row run in ONE
  transaction (`backfill_tenant/2`). If the reset or its audit fails, the seed rolls back with
  it, so the tenant is never left seeded-but-unreset: a re-run classifies it `:seeded` again and
  completes it. Nothing is recorded per tenant outside that transaction.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.RoleRevocations
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @doc """
  Sweeps every tenant registered in `Letflow.TenantProvisioning.list_registrations/0`,
  seeding the platform-role bindings (REQ-448: eight roles, `PLATFORM_ADMIN` only in the
  platform tenant) for each via
  `Letflow.Identity.RoleRegistry.seed_default_platform_role_groups_report/1`.

  Each tenant is one transaction (`backfill_tenant/2`): the seed, and for a tenant this call
  genuinely seeds (`:seeded`, per `classify/4`'s existing "missed a role of
  `RoleRegistry.seedable_role_names/1` before this call" test) the bulk reset of
  `role_claims_synced_at` to `nil` for every user row in that tenant's own schema
  (`reset_role_claims_sync_markers/2`, ISS-0910, audited by GH 2547), commit or roll back
  together (GH 2572). `:unchanged` tenants are never touched by the reset (design §0/§7 INV-BF5).

  `opts[:report]`, when given, is called once per tenant as the sweep reaches it, with
  `{tenant_id, :unchanged}`, `{tenant_id, {:seeded, markers_reset}}` or
  `{tenant_id, {:failed, reason_class}}` (see `reason_class/1`; no user data). The mix task
  prints these lines.

  Returns `{:ok, %{seeded: [tenant_id], unchanged: [tenant_id], role_claims_markers_reset: count}}`
  on success — `seeded`/`unchanged` in the same order `list_registrations/0`
  returned them (design §2.1 step 3), `role_claims_markers_reset` the sum
  across every `:seeded` tenant of that tenant's own reset row count (design
  §5) — or the halted `{:error, {:backfill_failed, tenant_id, reason}}` from
  the first tenant that fails. A halted run is safe to re-run: the failed tenant was rolled
  back, and every tenant before it is already complete.
  """
  @spec run(opts :: [report: (term() -> any())]) ::
          {:ok,
           %{
             seeded: [Ecto.UUID.t()],
             unchanged: [Ecto.UUID.t()],
             role_claims_markers_reset: non_neg_integer(),
             skipped_enforced: [Ecto.UUID.t()]
           }}
          | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
  def run(opts \\ []) do
    report = Keyword.get(opts, :report, fn _outcome -> :ok end)

    # GH 2547 (design 2.5): one generated trace id per run, shared by every
    # `role_claims_sync.reset` audit row of the sweep and its log lines.
    Letflow.Obs.Logger.with_trace(fn ->
      TenantProvisioning.list_registrations()
      |> Enum.reduce_while(
        {:ok, %{seeded: [], unchanged: [], role_claims_markers_reset: 0, skipped_enforced: []}},
        fn registration, {:ok, acc} ->
          process_registration(registration, acc, report)
        end
      )
      |> finalize()
    end)
  end

  @doc """
  T-0934: read-only detection. For every registered tenant (or `opts[:registrations]`), the
  names of `RoleRegistry.seedable_role_names/1` that have no `:platform_role` row in the
  tenant's schema. Returns `{:ok, [%{tenant_id, schema_name, missing: [name]}]}` listing only
  tenants with a gap, or `{:error, :check_failed}` when a tenant schema
  cannot be read. Writes nothing; `run/1` is the heal.
  """
  @spec missing_role_groups(keyword()) ::
          {:ok, [%{tenant_id: Ecto.UUID.t(), schema_name: String.t(), missing: [String.t()]}]}
          | {:error, :check_failed}
  def missing_role_groups(opts \\ []) do
    registrations =
      Keyword.get_lazy(opts, :registrations, &TenantProvisioning.list_registrations/0)

    Enum.reduce_while(registrations, {:ok, []}, fn %{tenant_id: tenant_id, schema_name: schema},
                                                   {:ok, acc} ->
      held = held_platform_role_names(schema)

      case Enum.reject(RoleRegistry.seedable_role_names(schema), &(&1 in held)) do
        [] ->
          {:cont, {:ok, acc}}

        missing ->
          {:cont, {:ok, acc ++ [%{tenant_id: tenant_id, schema_name: schema, missing: missing}]}}
      end
    end)
  rescue
    _exception -> {:error, :check_failed}
  end

  @spec process_registration(Registration.t(), map(), (term() -> any())) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {:backfill_failed, Ecto.UUID.t(), term()}}}
  defp process_registration(
         %Registration{tenant_id: tenant_id, schema_name: schema_name},
         acc,
         report
       ) do
    case backfill_tenant(tenant_id, schema_name) do
      {:ok, outcome} ->
        report.({tenant_id, report_outcome(outcome)})
        {:cont, {:ok, record(acc, tenant_id, outcome)}}

      {:error, reason} ->
        report.({tenant_id, {:failed, reason_class(reason)}})
        {:halt, {:error, {:backfill_failed, tenant_id, reason}}}
    end
  end

  # GH 2572: the seed, the marker reset and its audit row are ONE transaction per tenant. A
  # failure at any step takes the seed back with it, so a tenant is never left seeded but
  # unreset: a returned error rolls back via Repo.rollback/1, and a raise rolls back as Ecto
  # re-raises it into the rescue below. A re-run then starts from the same state and classifies
  # the tenant :seeded again. Nothing is written outside this transaction.
  @spec backfill_tenant(Ecto.UUID.t(), String.t()) ::
          {:ok,
           %{
             status: :seeded | :unchanged,
             markers_reset: non_neg_integer(),
             skipped: [String.t()]
           }}
          | {:error, term()}
  defp backfill_tenant(tenant_id, schema_name) do
    Repo.transaction(
      fn ->
        held_platform_role_names_before = held_platform_role_names(schema_name)

        with {:ok, %{skipped_enforced: skipped}} <-
               RoleRegistry.seed_default_platform_role_groups_report(prefix: schema_name),
             {:ok, outcome} <-
               classify(tenant_id, schema_name, held_platform_role_names_before, skipped) do
          outcome
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      prefix: schema_name
    )
  rescue
    # See this module's moduledoc "Deviation from the design doc" section --
    # mirrors Letflow.TenantProvisioning.replay_all_pending/0's identical
    # try/rescue for the same "tenant schema vanished mid-sweep" case, which
    # seed_default_platform_role_groups/1 (unlike Registry.register_type/2)
    # does not itself guard against.
    exception -> {:error, {:unexpected_exception, exception}}
  end

  defp record(acc, tenant_id, %{status: status, markers_reset: reset_count, skipped: skipped}) do
    acc = note_skipped_enforced(acc, tenant_id, skipped)

    case status do
      :seeded ->
        %{
          acc
          | seeded: [tenant_id | acc.seeded],
            role_claims_markers_reset: acc.role_claims_markers_reset + reset_count
        }

      :unchanged ->
        %{acc | unchanged: [tenant_id | acc.unchanged]}
    end
  end

  defp report_outcome(%{status: :seeded, markers_reset: reset_count}), do: {:seeded, reset_count}
  defp report_outcome(%{status: :unchanged}), do: :unchanged

  @doc """
  The class of a `run/0` failure reason, safe to print: the exception module of an unexpected
  exception, or the tag of the reason. Never the message, which can carry tenant data.
  """
  @spec reason_class(term()) :: atom()
  def reason_class({:unexpected_exception, %{__struct__: module}}), do: module
  def reason_class({:audit_failed, _reason}), do: :audit_failed
  def reason_class({tag, _detail}) when is_atom(tag), do: tag
  def reason_class(reason) when is_atom(reason), do: reason
  def reason_class(_reason), do: :unknown

  # REQ-519 2e-a (S-1): a tenant stored `on` gets a missing binding WITHOUT a grant row; it is
  # listed (once) so the sweep result shows it. The sweep itself carries on.
  defp note_skipped_enforced(acc, _tenant_id, []), do: acc

  defp note_skipped_enforced(acc, tenant_id, _names),
    do: %{acc | skipped_enforced: [tenant_id | acc.skipped_enforced]}

  # Only a genuinely `:seeded` tenant (missed a role of
  # RoleRegistry.seedable_role_names/1 before this call) gets its users'
  # role_claims_synced_at markers reset -- design §2 shape (a): the gate stays visible here,
  # at the same call site, rather than hidden inside reset_role_claims_sync_markers/2 itself.
  @spec classify(Ecto.UUID.t(), String.t(), [String.t()], [String.t()]) ::
          {:ok, map()} | {:error, {:audit_failed, term()}}
  defp classify(tenant_id, schema_name, held_platform_role_names_before, skipped) do
    # REQ-447: no hard-coded count; PLATFORM_ADMIN is only seedable in the
    # platform tenant, so the entitled set differs per tenant.
    missing? =
      Enum.any?(RoleRegistry.seedable_role_names(schema_name), fn name ->
        name not in held_platform_role_names_before
      end)

    if missing? do
      with {:ok, reset_count} <- reset_role_claims_sync_markers(schema_name, tenant_id) do
        {:ok, %{status: :seeded, markers_reset: reset_count, skipped: skipped}}
      end
    else
      {:ok, %{status: :unchanged, markers_reset: 0, skipped: skipped}}
    end
  end

  @spec held_platform_role_names(String.t()) :: [String.t()]
  defp held_platform_role_names(schema_name) do
    from(t in TenantRole, where: t.kind == :platform_role, select: t.name)
    |> Repo.all(prefix: schema_name)
  end

  # ISS-0910: bulk-clears role_claims_synced_at for every user in this tenant's own schema.
  # "Every user with a membership in tenant X" is exactly "every row of tenant X's own `users`
  # table" -- users carries no tenant_id column (Decision 0006 D1/D2); the tenant's own Postgres
  # schema is the entire scoping mechanism, so no `where` clause is needed (design §0/§1).
  # Naturally idempotent at the SQL level (design §3): re-nulling an already-nil column is a no-op.
  #
  # GH 2547 (design 3.8): the reset re-opens the one-time IdP sync, which can re-grant a
  # TENANT_ADMIN membership an admin removed, so it is audited: one `role_claims_sync.reset` row
  # per tenant (one operator act; per-user rows would take the chain lock once per user).
  #
  # GH 2572: runs inside backfill_tenant/2's transaction, not its own. An `{:error, _}` return
  # is rolled back by the caller; a raise (a non-raising audit failure is returned, a raising one
  # is not) propagates the same way. Either way the markers and the seed are unchanged.
  @spec reset_role_claims_sync_markers(schema_name :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, {:audit_failed, term()}}
  defp reset_role_claims_sync_markers(schema_name, tenant_id) do
    with_marker =
      from(u in User,
        where: not is_nil(u.role_claims_synced_at),
        select: u.id,
        order_by: u.id
      )
      |> Repo.all(prefix: schema_name)

    {reset_count, reset_ids} =
      Repo.update_all(from(u in User, select: u.id), [set: [role_claims_synced_at: nil]],
        prefix: schema_name
      )

    reset_ids = Enum.sort(reset_ids)

    # GH 2558: informational only. The reset set is unchanged (every user re-syncs, so newly
    # seeded roles still arrive); the next sync withholds a group whose explicit revocation
    # is in force, so these users do not regain it.
    honored_ids =
      reset_ids
      |> RoleRevocations.users_with_revocation(schema_name)
      |> Enum.sort()

    attrs = %{
      actor_id: nil,
      action: "role_claims_sync.reset",
      resource_type: "tenant",
      resource_id: tenant_id,
      trace_id: AuditContext.current_trace_id(),
      before_state: %{"users_with_marker" => with_marker, "count" => length(with_marker)},
      after_state: %{
        "reset_user_ids" => reset_ids,
        "reset_count" => reset_count,
        "revocation_honored_user_ids" => honored_ids,
        "revocation_honored_count" => length(honored_ids),
        "source" => "role_backfill",
        "effect" => "next_login_resyncs_idp_role_claims"
      }
    }

    case Audit.insert_entry(Repo, attrs, schema_name) do
      {:ok, _entry} -> {:ok, reset_count}
      {:error, reason} -> {:error, {:audit_failed, reason}}
    end
  end

  @spec finalize({:ok, map()} | {:error, term()}) ::
          {:ok,
           %{
             seeded: [Ecto.UUID.t()],
             unchanged: [Ecto.UUID.t()],
             role_claims_markers_reset: non_neg_integer()
           }}
          | {:error, term()}
  defp finalize({:ok, %{seeded: seeded, unchanged: unchanged} = acc}) do
    {:ok,
     %{
       acc
       | seeded: Enum.reverse(seeded),
         unchanged: Enum.reverse(unchanged),
         skipped_enforced: Enum.reverse(acc.skipped_enforced)
     }}
  end

  defp finalize({:error, _reason} = error), do: error
end
