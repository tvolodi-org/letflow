defmodule Letflow.Identity.TenantAdminMigration do
  @moduledoc """
  REQ-447 (design `lib/letflow/design/req447-tenant-admin-role.md` section 3.8):
  the idempotent, forward-only conversion of every NON-platform tenant from the
  legacy `PLATFORM_ADMIN` role to `TENANT_ADMIN`.

  REQ-447 PR 2 is merged: a stored or claimed `PLATFORM_ADMIN` outside the platform
  tenant is no longer honoured at all (dropped at role resolution, rejected on
  write). This tool stays because every other environment that still holds legacy
  `PLATFORM_ADMIN` members or tokens in non-platform tenants must be migrated to
  `TENANT_ADMIN` or those holders silently lose their administration.

  For each tenant registered in `Letflow.TenantProvisioning.list_registrations/0`
  except the pinned platform tenant, in ONE `Letflow.Repo.transaction/1` per
  tenant (a failing tenant rolls back completely and the sweep continues):

    1. ensure the `TENANT_ADMIN` group and its `:platform_role` binding;
    2. only while a `:platform_role` binding named `PLATFORM_ADMIN` exists, copy
       every member of the group that binding points to into the `TENANT_ADMIN`
       binding's group (user ids only; a group without a binding confers nothing,
       which is what stops a second run promoting a later addition to the inert
       legacy group);
    3. delete the `PLATFORM_ADMIN` binding (the legacy group and its members stay);
    4. rewrite every `api_tokens` row whose `roles` contain `PLATFORM_ADMIN` to
       `TENANT_ADMIN` (de-duplicated, order kept) through
       `Letflow.Identity.ApiToken.roles_rewrite_changeset/2`, which casts only
       `roles`, so the plaintext token keeps working.

  Audit entries (actor nil, same transaction): `role_binding.removed`,
  `group_member.copied` (user id only), `token.roles_migrated` (roles only).

  `run/1` never writes unless the platform-tenant pin is verified (UUID pin, the
  pinned tenant registered, `platform_tenant_slug` and `expected_realm_id` equal
  to the pinned tenant's slug and `idp_realm_id`, the pinned tenant holds at least
  one `PLATFORM_ADMIN` member). `dry_run: true` is read queries only (no write, no
  rolled-back transaction) and never refuses: it returns `would_refuse`. In a dry
  run the slug and realm options are checked only when supplied.

  Every exception and exit is rescued and mapped to an atom tag; no exception
  message, struct or user attribute reaches the report, stdout or stderr (INV-2,
  INV-4). The logger records only the exception MODULE and the tenant id.
  Callable on a deployed container through the release `rpc` (no Mix); see
  `lib/letflow/design/req447-infra-realm-mapping.md` section 8.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.ScopeEnforcement
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @legacy "PLATFORM_ADMIN"
  @target "TENANT_ADMIN"

  @reason_tags [
    :role_name_taken_by_routing_role,
    :platform_admin_name_is_routing_role,
    :tenant_schema_missing,
    :unexpected_error
  ]

  @type refusal_tag ::
          :platform_tenant_not_configured
          | :platform_tenant_not_registered
          | :platform_tenant_slug_required
          | :platform_tenant_slug_mismatch
          | :platform_tenant_realm_required
          | :platform_tenant_realm_mismatch
          | :platform_tenant_has_no_operator
          | :unexpected_error

  # One source: the type is built from @reason_tags (a union of its atoms).
  @type reason_tag :: unquote(Enum.reduce(Enum.reverse(@reason_tags), &{:|, [], [&1, &2]}))

  @type tenant_report :: %{
          tenant_id: String.t(),
          slug: String.t(),
          idp_realm_id: String.t() | nil,
          tenant_admin_binding_created: boolean(),
          members_copied: non_neg_integer(),
          platform_admin_binding_removed: boolean(),
          tokens_rewritten: non_neg_integer(),
          tenant_admin_member_count_after: non_neg_integer(),
          rows: :written | :skipped_enforced
        }

  @type preconditions :: %{
          pin_configured: boolean(),
          realm_matches_expected: boolean() | nil,
          pin_is_uuid: boolean(),
          registered: boolean(),
          pinned_slug: String.t() | nil,
          pinned_idp_realm_id: String.t() | nil,
          operator_count: non_neg_integer()
        }

  @type report :: %{
          dry_run: boolean(),
          platform_tenant_id: String.t(),
          migrated: [tenant_report()],
          unchanged: [String.t()],
          failed: [%{tenant_id: String.t(), schema_name: String.t(), reason: reason_tag()}],
          platform_tenant_binding_ensured: boolean(),
          preconditions: preconditions(),
          would_refuse: [refusal_tag()]
        }

  @type tenant_state :: %{
          tenant_id: String.t(),
          slug: String.t(),
          platform_tenant?: boolean(),
          platform_admin_binding?: boolean(),
          tenant_admin_binding?: boolean(),
          tenant_admin_member_count: non_neg_integer(),
          platform_admin_group_member_count: non_neg_integer(),
          tokens_with_platform_admin: non_neg_integer()
        }

  @typep plan :: %{
           ta: TenantRole.t() | nil,
           pa: TenantRole.t() | nil,
           target_count: non_neg_integer(),
           to_copy: [Ecto.UUID.t()],
           tokens: [ApiToken.t()]
         }

  @doc """
  Runs the migration. Options: `dry_run` (boolean, default `false`; only an exact
  `true` is a dry run), `platform_tenant_slug`, `expected_realm_id`.

  Returns `{:ok, report()}` or `{:error, {:precondition_failed, tag}}` (never in a
  dry run, except for the `:unexpected_error` tag when something raised).
  """
  @spec run(
          opts :: [
            dry_run: boolean(),
            platform_tenant_slug: String.t() | nil,
            expected_realm_id: String.t() | nil
          ]
        ) :: {:ok, report()} | {:error, {:precondition_failed, refusal_tag()}}
  def run(opts \\ []) when is_list(opts) do
    # GH 2547 (design 2.5): one generated trace id per run ties every audit row of
    # the sweep to its log lines; the caller's own trace id is restored afterwards.
    Letflow.Obs.Logger.with_trace(fn ->
      guarded(fn -> do_run(opts) end, {:error, {:precondition_failed, :unexpected_error}})
    end)
  end

  @doc """
  Read-only verification for the runbook: the pin flag and, per registered tenant
  (the platform tenant included), ids, slugs, booleans and counts only.
  """
  @spec verify() ::
          {:ok, %{pin_configured: boolean(), tenants: [tenant_state()]}}
          | {:error, :unexpected_error}
  def verify do
    guarded(&do_verify/0, {:error, :unexpected_error})
  end

  # --- run ------------------------------------------------------------------

  defp do_run(opts) do
    dry? = Keyword.get(opts, :dry_run, false) == true
    pre = preconditions(opts)
    refusals = refusals(pre, opts, dry?)

    if not dry? and refusals != [] do
      {:error, {:precondition_failed, hd(refusals)}}
    else
      {:ok, sweep(pre, dry?, if(dry?, do: refusals, else: []))}
    end
  end

  defp sweep(pre, dry?, would_refuse) do
    regs =
      Enum.reject(TenantProvisioning.list_registrations(), fn %Registration{tenant_id: id} ->
        PlatformTenant.platform_tenant?(id)
      end)

    info = tenant_info(Enum.map(regs, & &1.tenant_id))

    results = Enum.map(regs, &process_tenant(&1, Map.get(info, &1.tenant_id), dry?))

    %{
      dry_run: dry?,
      platform_tenant_id: PlatformTenant.configured_id() || "",
      migrated: for({:migrated, rep} <- results, do: rep),
      unchanged: for({:unchanged, id} <- results, do: id),
      failed: for({:failed, f} <- results, do: f),
      platform_tenant_binding_ensured: platform_binding_ensured?(pre),
      preconditions: public_preconditions(pre),
      would_refuse: would_refuse
    }
  end

  defp process_tenant(%Registration{tenant_id: tid, schema_name: schema}, nil, _dry?) do
    {:failed, %{tenant_id: tid, schema_name: schema, reason: :unexpected_error}}
  end

  defp process_tenant(%Registration{tenant_id: tid, schema_name: schema}, {slug, realm}, dry?) do
    result =
      if dry?,
        do: dry_tenant(schema, tid, slug, realm),
        else: real_tenant(schema, tid, slug, realm)

    case result do
      {:ok, rep} -> if unchanged?(rep), do: {:unchanged, tid}, else: {:migrated, rep}
      {:error, tag} -> {:failed, %{tenant_id: tid, schema_name: schema, reason: tag}}
    end
  rescue
    exception ->
      Logger.warning(
        "tenant_admin_migration tenant=#{tid} exception=#{inspect(exception.__struct__)}"
      )

      {:failed, %{tenant_id: tid, schema_name: schema, reason: classify_exception(exception)}}
  catch
    kind, _reason ->
      Logger.warning("tenant_admin_migration tenant=#{tid} #{kind}")
      {:failed, %{tenant_id: tid, schema_name: schema, reason: :unexpected_error}}
  end

  defp unchanged?(rep) do
    # REQ-519: a tenant skipped because enforcement is `on` is always reported.
    rep.rows != :skipped_enforced and not rep.tenant_admin_binding_created and
      not rep.platform_admin_binding_removed and rep.tokens_rewritten == 0
  end

  defp classify_exception(%Postgrex.Error{postgres: %{code: :undefined_table}}),
    do: :tenant_schema_missing

  defp classify_exception(_other), do: :unexpected_error

  # --- per tenant: reads (shared by dry run and real run) ---------------------

  @spec plan(String.t()) :: {:ok, plan()} | {:error, reason_tag()}
  defp plan(schema) do
    rows =
      from(t in TenantRole, where: t.name in [@legacy, @target])
      |> Repo.all(prefix: schema)

    ta = Enum.find(rows, &(&1.name == @target))
    pa = Enum.find(rows, &(&1.name == @legacy))

    cond do
      match?(%TenantRole{kind: :process_routing_role}, ta) ->
        {:error, :role_name_taken_by_routing_role}

      match?(%TenantRole{kind: :process_routing_role}, pa) ->
        {:error, :platform_admin_name_is_routing_role}

      true ->
        target = if ta, do: member_ids(schema, ta.group_id), else: []
        source = if pa, do: member_ids(schema, pa.group_id), else: []

        tokens =
          from(t in ApiToken,
            where: fragment("'PLATFORM_ADMIN' = ANY(?)", t.roles),
            order_by: t.id
          )
          |> Repo.all(prefix: schema)

        {:ok,
         %{
           ta: ta,
           pa: pa,
           target_count: length(target),
           to_copy: source -- target,
           tokens: tokens
         }}
    end
  end

  defp member_ids(schema, group_id) do
    from(m in GroupMember, where: m.group_id == ^group_id, select: m.user_id, order_by: m.user_id)
    |> Repo.all(prefix: schema)
  end

  defp dry_tenant(schema, tid, slug, realm) do
    # REQ-519: a dry run reads the mode without a lock (a snapshot) and never raises for it.
    if match?({:ok, :on}, ScopeEnforcement.get_mode(tid)) do
      {:ok, skipped_report(tid, slug, realm)}
    else
      dry_plan(schema, tid, slug, realm)
    end
  end

  defp dry_plan(schema, tid, slug, realm) do
    with {:ok, plan} <- plan(schema) do
      {:ok,
       %{
         rows: :written,
         tenant_id: tid,
         slug: slug,
         idp_realm_id: realm,
         tenant_admin_binding_created: is_nil(plan.ta),
         members_copied: length(plan.to_copy),
         platform_admin_binding_removed: not is_nil(plan.pa),
         tokens_rewritten: length(plan.tokens),
         tenant_admin_member_count_after: plan.target_count + length(plan.to_copy)
       }}
    end
  end

  # --- per tenant: writes -----------------------------------------------------

  defp real_tenant(schema, tid, slug, realm) do
    result =
      Repo.transaction(fn ->
        # GH 2547 (design 6.6): the tenant admin lock before any read or row lock.
        Identity.lock_tenant_admins!(schema)

        # REQ-519 2e-a (S-1, design 3.6): a bulk membership copy in an enforced tenant is an
        # unreviewed grant of the group's scope, so the whole one-shot plan is skipped (the
        # legacy binding removal and token rewrite with it) and the tenant is reported.
        case ScopeEnforcement.mode_under_lock!(schema) do
          :on ->
            Logger.info("binding_row_skipped reason=enforced writer=tenant_admin_migration")
            skipped_report(tid, slug, realm)

          _off_or_shadow ->
            case plan(schema) do
              {:error, tag} -> Repo.rollback(tag)
              {:ok, plan} -> apply_plan(plan, schema, tid, slug, realm)
            end
        end
      end)

    case result do
      {:ok, rep} -> {:ok, rep}
      {:error, tag} when tag in @reason_tags -> {:error, tag}
      {:error, _other} -> {:error, :unexpected_error}
    end
  end

  defp skipped_report(tid, slug, realm) do
    %{
      tenant_id: tid,
      slug: slug,
      idp_realm_id: realm,
      tenant_admin_binding_created: false,
      members_copied: 0,
      platform_admin_binding_removed: false,
      tokens_rewritten: 0,
      tenant_admin_member_count_after: 0,
      rows: :skipped_enforced
    }
  end

  defp apply_plan(plan, schema, tid, slug, realm) do
    ta_group_id = ensure_binding(plan.ta, schema)
    copy_members(plan, ta_group_id, schema)
    remove_legacy_binding(plan.pa, schema)
    rewrite_tokens(plan.tokens, schema)

    %{
      rows: :written,
      tenant_id: tid,
      slug: slug,
      idp_realm_id: realm,
      tenant_admin_binding_created: is_nil(plan.ta),
      members_copied: length(plan.to_copy),
      platform_admin_binding_removed: not is_nil(plan.pa),
      tokens_rewritten: length(plan.tokens),
      tenant_admin_member_count_after: length(member_ids(schema, ta_group_id))
    }
  end

  # An existing binding keeps its group_id: the copy targets that group, whatever
  # it is called.
  # REQ-497 W5 (b): repair-only, inserts a grant row only for a binding with none.
  defp ensure_binding(%TenantRole{group_id: group_id} = ta, schema) do
    # Unreachable in an `on` tenant through real_tenant/4 (skipped); a direct caller gets
    # the NO-ROW answer, which is not an error here.
    _ = RoleScopeGrants.reconcile_binding!(ta, ta, schema)
    group_id
  end

  # GH 2547 (design 3.7): a TENANT_ADMIN group that already has members makes this a
  # grant-relevant binding write, audited by upsert_role/4 in this same transaction.
  defp ensure_binding(nil, schema) do
    audit_context = %{
      actor_id: nil,
      trace_id: AuditContext.current_trace_id(),
      source: "tenant_admin_migration"
    }

    with {:ok, %Group{id: group_id}} <-
           RoleRegistry.get_or_create_group_by_name(@target, prefix: schema),
         {:ok, %TenantRole{}} <-
           RoleRegistry.upsert_role(@target, :platform_role, group_id,
             prefix: schema,
             audit_context: audit_context
           ) do
      group_id
    else
      _error -> Repo.rollback(:unexpected_error)
    end
  end

  defp copy_members(%{pa: nil}, _ta_group_id, _schema), do: :ok
  defp copy_members(%{to_copy: []}, _ta_group_id, _schema), do: :ok

  defp copy_members(%{to_copy: user_ids}, ta_group_id, schema) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    rows = Enum.map(user_ids, &%{group_id: ta_group_id, user_id: &1, inserted_at: now})

    Repo.insert_all(GroupMember, rows,
      prefix: schema,
      on_conflict: :nothing,
      conflict_target: [:group_id, :user_id]
    )

    Enum.each(user_ids, fn user_id ->
      audit!(schema, "group_member.copied", "group_member", user_id, nil, %{"user_id" => user_id})
    end)
  end

  defp remove_legacy_binding(nil, _schema), do: :ok

  defp remove_legacy_binding(%TenantRole{id: id} = pa, schema) do
    Repo.delete_all(from(t in TenantRole, where: t.id == ^id), prefix: schema)
    # REQ-497 W5 (c): the binding's grant rows go with it, before its audit entry.
    # Removal never widens: always `:ok`, in every mode.
    :ok = RoleScopeGrants.reconcile_binding!(pa, nil, schema)

    audit!(schema, "role_binding.removed", "tenant_role", id, %{"name" => @legacy}, nil)
  end

  defp rewrite_tokens(tokens, schema) do
    Enum.each(tokens, fn %ApiToken{id: id, roles: roles} = token ->
      new_roles = rewrite_roles(roles)

      case Repo.update(ApiToken.roles_rewrite_changeset(token, new_roles), prefix: schema) do
        {:ok, _token} -> :ok
        {:error, _changeset} -> Repo.rollback(:unexpected_error)
      end

      audit!(
        schema,
        "token.roles_migrated",
        "api_token",
        id,
        %{"roles" => roles},
        %{"roles" => new_roles}
      )
    end)
  end

  @spec rewrite_roles([String.t()]) :: [String.t()]
  defp rewrite_roles(roles) do
    roles
    |> Enum.map(fn role -> if role == @legacy, do: @target, else: role end)
    |> Enum.uniq()
  end

  defp audit!(schema, action, resource_type, resource_id, before_state, after_state) do
    attrs = %{
      actor_id: nil,
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      before_state: before_state,
      after_state: after_state,
      # GH 2547: the run's generated trace id (run/1's with_trace/1).
      trace_id: AuditContext.current_trace_id()
    }

    case Audit.insert_entry(Repo, attrs, schema) do
      {:ok, _entry} -> :ok
      _error -> Repo.rollback(:unexpected_error)
    end
  end

  # --- preconditions ----------------------------------------------------------

  defp preconditions(opts) do
    pin = PlatformTenant.configured_id()
    pin_is_uuid = PlatformTenant.uuid?(pin)

    base = %{
      pin_configured: not is_nil(pin),
      realm_matches_expected: nil,
      pin_is_uuid: pin_is_uuid,
      registered: false,
      pinned_slug: nil,
      pinned_idp_realm_id: nil,
      operator_count: 0,
      pinned_schema: nil
    }

    pre =
      if pin_is_uuid do
        registration = Repo.get_by(Registration, tenant_id: pin)

        case {registration, Repo.get(Tenant, pin)} do
          {%Registration{schema_name: schema}, %Tenant{} = tenant} ->
            %{
              base
              | registered: true,
                pinned_slug: tenant.slug,
                pinned_idp_realm_id: tenant.idp_realm_id,
                operator_count: members_of_binding(schema, @legacy),
                pinned_schema: schema
            }

          _unregistered ->
            base
        end
      else
        base
      end

    expected = Keyword.get(opts, :expected_realm_id)

    if is_binary(expected) do
      %{pre | realm_matches_expected: expected == pre.pinned_idp_realm_id}
    else
      pre
    end
  end

  defp public_preconditions(pre), do: Map.delete(pre, :pinned_schema)

  defp refusals(pre, opts, dry?) do
    cond do
      not pre.pin_is_uuid ->
        [:platform_tenant_not_configured]

      not pre.registered ->
        [:platform_tenant_not_registered]

      true ->
        slug_refusal(Keyword.get(opts, :platform_tenant_slug), pre.pinned_slug, dry?) ++
          realm_refusal(Keyword.get(opts, :expected_realm_id), pre.pinned_idp_realm_id, dry?) ++
          if(pre.operator_count >= 1, do: [], else: [:platform_tenant_has_no_operator])
    end
  end

  defp slug_refusal(nil, _pinned, true), do: []
  defp slug_refusal(nil, _pinned, false), do: [:platform_tenant_slug_required]
  defp slug_refusal(given, pinned, _dry?) when given == pinned, do: []
  defp slug_refusal(_given, _pinned, _dry?), do: [:platform_tenant_slug_mismatch]

  defp realm_refusal(nil, _pinned, true), do: []
  defp realm_refusal(nil, _pinned, false), do: [:platform_tenant_realm_required]
  defp realm_refusal(given, pinned, _dry?) when given == pinned and not is_nil(pinned), do: []
  defp realm_refusal(_given, _pinned, _dry?), do: [:platform_tenant_realm_mismatch]

  defp platform_binding_ensured?(%{pinned_schema: nil}), do: false

  defp platform_binding_ensured?(%{pinned_schema: schema}) do
    Repo.exists?(
      from(t in TenantRole, where: t.name == ^@target and t.kind == :platform_role),
      prefix: schema
    )
  end

  # --- shared reads -------------------------------------------------------------

  defp tenant_info(tenant_ids) do
    from(t in Tenant, where: t.id in ^tenant_ids, select: {t.id, t.slug, t.idp_realm_id})
    |> Repo.all()
    |> Map.new(fn {id, slug, realm} -> {id, {slug, realm}} end)
  end

  defp members_of_binding(schema, name) do
    from(m in GroupMember,
      join: r in TenantRole,
      on: r.group_id == m.group_id,
      where: r.name == ^name and r.kind == :platform_role,
      select: count(m.user_id)
    )
    |> Repo.one(prefix: schema)
  end

  defp binding?(schema, name) do
    Repo.exists?(from(t in TenantRole, where: t.name == ^name and t.kind == :platform_role),
      prefix: schema
    )
  end

  # --- verify -------------------------------------------------------------------

  defp do_verify do
    regs = TenantProvisioning.list_registrations()
    info = tenant_info(Enum.map(regs, & &1.tenant_id))

    tenants =
      Enum.map(regs, fn %Registration{tenant_id: tid, schema_name: schema} ->
        {slug, _realm} = Map.get(info, tid, {"", nil})

        %{
          tenant_id: tid,
          slug: slug,
          platform_tenant?: PlatformTenant.platform_tenant?(tid),
          platform_admin_binding?: binding?(schema, @legacy),
          tenant_admin_binding?: binding?(schema, @target),
          tenant_admin_member_count: members_of_binding(schema, @target),
          platform_admin_group_member_count: members_of_binding(schema, @legacy),
          tokens_with_platform_admin:
            from(t in ApiToken,
              where: fragment("'PLATFORM_ADMIN' = ANY(?)", t.roles),
              select: count(t.id)
            )
            |> Repo.one(prefix: schema)
        }
      end)

    {:ok, %{pin_configured: not is_nil(PlatformTenant.configured_id()), tenants: tenants}}
  end

  # --- exception containment ------------------------------------------------------

  defp guarded(fun, fallback) do
    fun.()
  rescue
    exception ->
      Logger.warning("tenant_admin_migration exception=#{inspect(exception.__struct__)}")
      fallback
  catch
    kind, _reason ->
      Logger.warning("tenant_admin_migration #{kind}")
      fallback
  end
end
