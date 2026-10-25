defmodule Letflow.TenantProvisioner do
  @moduledoc """
  REQ-572 / GH #3252 / decision 0072 (QA only): the context behind the `/admin/v1` provisioner
  routes (`Letflow.Routers.AdminV1`). It makes, reads and moves the lifecycle of a tenant for the
  portfolio front door, with a credential that is bound to no tenant and no user.

  ## Idempotency by the caller's tenant id (D3)

  `create/1` takes the caller's `tenant_id` as `tenants.id`, the slug is `t-` + its 32 hex digits, and
  the whole call runs under a per-tenant session advisory lock, so two concurrent creates of one id are
  serialised (the second sees the first's finished work and answers `:existing`). Every step is
  repeatable: a failure after the tenant commit answers `:internal`, and a repeat with the same
  `tenant_id` completes the missing steps. A replay of a complete tenant writes nothing and ignores
  every body field except `tenant_id`.

  The lock is a SESSION lock (`pg_advisory_lock`), not a row lock: provisioning replays DDL
  migrations, which cannot sit inside one outer transaction, and a row lock held across DDL is not
  an option. The lock is per tenant, so other tenants are not blocked.

  ## What is never done

  No `auth_context` is built, no tenant data is read, no role or credential is created (P4, P5, P7).
  Every raise or exit is rescued at the boundary, logged as exception class plus tenant id only
  (INV-4, INV-8), and answers `{:error, :internal}`. DELETE and purge are a later slice: the
  `purged_at` column exists and is only READ here.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Oidc.RealmProbe
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantLifecycle
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioner.Request
  alias Letflow.TenantProvisioning

  @type create_result ::
          {:ok, :created | :existing, map()}
          | {:error, {:invalid, String.t()} | :conflict | :internal}

  @doc """
  Creates the tenant of an already-validated request (`Request.parse/1`), or completes/replays it.
  `{:ok, :created, body}` when this call inserted the tenant row, `{:ok, :existing, body}` for a
  replay; the two bodies are identical.
  """
  @spec create(Request.t()) :: create_result()
  def create(%{tenant_id: tenant_id} = request) do
    with {:ok, platform_prefix} <- platform_prefix(),
         {:ok, server_url} <- server_url() do
      with_lock(tenant_id, fn -> do_create(request, platform_prefix, server_url) end)
    end
  end

  @doc """
  The read model of `GET /admin/v1/tenants/:id`: exactly `tenant_id`, `status`, `tier`,
  `created_at`, `expires_at`, `purged_at`. `{:error, :not_found}` for an unknown id, a non-UUID, and a
  tenant without a lifecycle row alike. A purged tenant still answers (`purged_at` set).
  """
  @spec get(term()) :: {:ok, map()} | {:error, :not_found}
  def get(raw_id) do
    with {:ok, id} <- cast_id(raw_id),
         %Lifecycle{} = row <- Repo.get(Lifecycle, id) do
      {:ok,
       %{
         tenant_id: row.tenant_id,
         status: row.lifecycle,
         tier: row.tier,
         created_at: iso(row.inserted_at),
         expires_at: iso(row.expires_at),
         purged_at: iso(row.purged_at)
       }}
    else
      _unknown -> {:error, :not_found}
    end
  end

  @transitions %{
    suspend: %{"active" => {:to, "suspended"}, "suspended" => :noop},
    resume: %{"suspended" => {:to, "active"}, "active" => :noop},
    expire: %{"active" => {:to, "expired"}, "suspended" => {:to, "expired"}, "expired" => :noop}
  }

  @doc """
  Moves a provisioned tenant's lifecycle: `:suspend`, `:resume` or `:expire` (decision 0072 D4
  table). `{:ok, %{tenant_id, status}}`; `{:error, :not_found}` for an unknown or non-provisioned
  id; `{:error, :conflict}` for a move the table refuses (and for the platform tenant).
  """
  @spec transition(term(), :suspend | :resume | :expire) ::
          {:ok, map()} | {:error, :not_found | :conflict | :internal}
  def transition(raw_id, action) when action in [:suspend, :resume, :expire] do
    with {:ok, id} <- cast_id(raw_id),
         {:ok, platform_prefix} <- platform_prefix() do
      with_lock(id, fn -> do_transition(id, action, platform_prefix) end)
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "True when `raw_id` is a provisioned tenant (has a lifecycle row). Used for DELETE's 409."
  @spec provisioned?(term()) :: boolean()
  def provisioned?(raw_id) do
    case cast_id(raw_id) do
      {:ok, id} -> Repo.exists?(from(l in Lifecycle, where: l.tenant_id == ^id))
      :error -> false
    end
  end

  # ── create ──────────────────────────────────────────────────────────────

  defp do_create(request, platform_prefix, server_url) do
    tenant = Repo.get(Tenant, request.tenant_id)
    lifecycle = Repo.get(Lifecycle, request.tenant_id)

    case {tenant, lifecycle} do
      {%Tenant{}, nil} ->
        {:error, :conflict}

      {nil, nil} ->
        insert_new(request, platform_prefix, server_url)

      {%Tenant{}, %Lifecycle{lifecycle: "active"}} ->
        complete(request, tenant, lifecycle, platform_prefix, server_url, :existing)

      {%Tenant{}, %Lifecycle{}} ->
        # Suspended or expired before the grant or the bind finished: resume, then repeat.
        {:error, :conflict}
    end
  end

  defp insert_new(request, platform_prefix, server_url) do
    with :ok <- probe_realm(request.idp_realm_id),
         :ok <- not_taken(request) do
      attrs = %{
        id: request.tenant_id,
        slug: Request.slug(request.tenant_id),
        display_name: request.name
      }

      case insert_tenant_and_lifecycle(attrs, request) do
        {:ok, tenant, lifecycle} ->
          complete(request, tenant, lifecycle, platform_prefix, server_url, :created)

        {:error, :exists} ->
          {:error, :conflict}
      end
    end
  end

  defp insert_tenant_and_lifecycle(attrs, request) do
    Repo.transaction(fn ->
      with {:ok, tenant} <- Identity.create_provisioned_tenant(attrs),
           {:ok, lifecycle} <-
             Repo.insert(
               struct(Lifecycle, %{
                 tenant_id: tenant.id,
                 lifecycle: "active",
                 tier: request.tier,
                 language: request.language,
                 expires_at: request.expires_at
               })
             ) do
        {tenant, lifecycle}
      else
        {:error, :exists} -> Repo.rollback(:exists)
        {:error, _changeset} -> Repo.rollback(:exists)
      end
    end)
    |> case do
      {:ok, {tenant, lifecycle}} -> {:ok, tenant, lifecycle}
      {:error, :exists} -> {:error, :exists}
    end
  end

  defp complete(request, tenant, lifecycle, platform_prefix, server_url, outcome) do
    with {:ok, tenant} <- ensure_provisioned(tenant),
         {:ok, record} <- ensure_onboarding(tenant, request),
         :ok <- ensure_grant(tenant, lifecycle, request, platform_prefix),
         :ok <- ensure_realm(tenant, request, platform_prefix) do
      {:ok, outcome,
       %{
         tenant_id: tenant.id,
         status: "active",
         server_url: server_url,
         handover: %{login_url: "https://" <> record.hostname}
       }}
    end
  end

  defp ensure_provisioned(%Tenant{status: :active} = tenant), do: {:ok, tenant}

  defp ensure_provisioned(%Tenant{id: id}) do
    case TenantOnboarding.provision_and_migrate(id) do
      {:ok, _registration} -> {:ok, Repo.get!(Tenant, id)}
      {:error, _reason} -> {:error, :internal}
    end
  end

  defp ensure_onboarding(tenant, request) do
    case Repo.get_by(OnboardingRecord, tenant_id: tenant.id) do
      %OnboardingRecord{} = record ->
        {:ok, record}

      nil ->
        case Identity.create_onboarding(%{
               tenant_id: tenant.id,
               slug: tenant.slug,
               hostname: request.hostname
             }) do
          {:ok, record} -> {:ok, record}
          {:error, :duplicate_hostname} -> {:error, :conflict}
          {:error, _other} -> {:error, :internal}
        end
    end
  end

  defp ensure_grant(_tenant, %Lifecycle{owner_grant_stored: true}, _request, _platform_prefix),
    do: :ok

  defp ensure_grant(tenant, lifecycle, request, platform_prefix) do
    with {:ok, prefix} <- TenantProvisioning.schema_name_for_tenant(tenant.id),
         stored when stored in [:ok, :duplicate] <- store_grant(request, prefix, platform_prefix),
         {:ok, _row} <-
           lifecycle |> Ecto.Changeset.change(owner_grant_stored: true) |> Repo.update() do
      :ok
    else
      _failure ->
        Logger.error(
          "provisioner: pending administrator grant not stored (tenant_id=#{inspect(tenant.id)})"
        )

        {:error, :internal}
    end
  end

  defp store_grant(request, prefix, platform_prefix) do
    case PendingAdminGrants.create_provisioned(request.email_key,
           prefix: prefix,
           platform_prefix: platform_prefix
         ) do
      {:ok, _grant} -> :ok
      {:error, :duplicate} -> :duplicate
      {:error, _other} -> :failed
    end
  end

  defp ensure_realm(%Tenant{idp_realm_id: realm}, _request, _platform_prefix)
       when is_binary(realm),
       do: :ok

  defp ensure_realm(tenant, request, platform_prefix) do
    with :ok <- probe_realm(request.idp_realm_id) do
      case Identity.bind_provisioned_realm(tenant.id, request.idp_realm_id,
             platform_prefix: platform_prefix
           ) do
        {:ok, _tenant} -> :ok
        {:error, :realm_already_bound} -> :ok
        {:error, :duplicate_realm} -> {:error, :conflict}
        {:error, _other} -> {:error, :internal}
      end
    end
  end

  defp probe_realm(realm) do
    case RealmProbe.verify(realm) do
      :ok -> :ok
      {:error, :not_found} -> {:error, {:invalid, "idp_realm_id"}}
      {:error, :unreachable} -> {:error, :internal}
    end
  end

  defp not_taken(request) do
    cond do
      match?({:ok, _}, Identity.get_onboarding_by_hostname(request.hostname)) ->
        {:error, :conflict}

      match?({:ok, _}, Identity.resolve_tenant_by_realm(request.idp_realm_id)) ->
        {:error, :conflict}

      true ->
        :ok
    end
  end

  # ── transitions ─────────────────────────────────────────────────────────

  defp do_transition(id, action, platform_prefix) do
    case Repo.get(Lifecycle, id) do
      nil ->
        {:error, :not_found}

      %Lifecycle{lifecycle: from, purged_at: purged_at} = row ->
        case {purged_at, @transitions |> Map.fetch!(action) |> Map.get(from)} do
          {nil, :noop} -> {:ok, %{tenant_id: id, status: from}}
          {nil, {:to, to}} -> apply_transition(row, from, to, platform_prefix)
          {_purged, _} -> {:error, :conflict}
        end
    end
  end

  defp apply_transition(row, from, to, platform_prefix) do
    tenant = Repo.get!(Tenant, row.tenant_id)

    result =
      Repo.transaction(fn ->
        with :ok <- set_tenant_status(tenant, to),
             {:ok, _row} <- row |> Ecto.Changeset.change(lifecycle: to) |> Repo.update(),
             {:ok, _entry} <- audit_change(row.tenant_id, from, to, platform_prefix) do
          :ok
        else
          {:error, :platform_tenant_protected} -> Repo.rollback(:conflict)
          _failure -> Repo.rollback(:internal)
        end
      end)

    case result do
      {:ok, :ok} ->
        if from == "active" and to != "active", do: TenantLifecycle.release_runtime(tenant)
        {:ok, %{tenant_id: row.tenant_id, status: to}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Suspended -> expired keeps the tenant inactive: nothing to change on the tenants row.
  defp set_tenant_status(%Tenant{status: :inactive}, to) when to != "active", do: :ok

  defp set_tenant_status(%Tenant{slug: slug}, "active") do
    case Identity.reactivate_tenant(slug) do
      {:ok, _tenant} -> :ok
      _failure -> {:error, :status}
    end
  end

  defp set_tenant_status(%Tenant{slug: slug}, _deactivated) do
    case Identity.deactivate_tenant(slug) do
      {:ok, _tenant} -> :ok
      {:error, :platform_tenant_protected} = refused -> refused
      _failure -> {:error, :status}
    end
  end

  defp audit_change(tenant_id, from, to, platform_prefix) do
    Letflow.Audit.insert_entry(
      Repo,
      %{
        actor_id: nil,
        action: "platform.tenant_lifecycle.changed",
        resource_type: "tenant",
        resource_id: tenant_id,
        trace_id: nil,
        before_state: nil,
        after_state: %{"tenant_id" => tenant_id, "from" => from, "to" => to}
      },
      platform_prefix
    )
  end

  # ── plumbing ────────────────────────────────────────────────────────────

  defp platform_prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :internal}
    end
  end

  defp server_url do
    case Application.get_env(:letflow, :provisioner_public_base_url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _unset -> {:error, :internal}
    end
  end

  defp cast_id(raw) when is_binary(raw), do: Ecto.UUID.cast(raw)
  defp cast_id(_raw), do: :error

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # The whole call runs under a per-tenant session advisory lock. Any raise or exit is rescued here
  # (fixed log line: exception class and tenant id only) and answers :internal.
  defp with_lock(tenant_id, fun) do
    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock(hashtextextended($1, 0))", [tenant_id])

      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [tenant_id])
      end
    end)
  rescue
    exception ->
      Logger.error(
        "provisioner call failed (tenant_id=#{inspect(tenant_id)}, exception=#{inspect(exception.__struct__)})"
      )

      {:error, :internal}
  catch
    :exit, reason ->
      Logger.error(
        "provisioner call failed (tenant_id=#{inspect(tenant_id)}, exit=#{inspect(exit_tag(reason))})"
      )

      {:error, :internal}
  end

  defp exit_tag({tag, _detail}) when is_atom(tag), do: tag
  defp exit_tag(tag) when is_atom(tag), do: tag
  defp exit_tag(_other), do: :other
end
