defmodule Letflow.TenantHosts do
  @moduledoc """
  Company-host registration for existing tenants (T-2184).

  This global identity registry has one host per tenant. Writes lock the tenant
  and registry rows, then append tenant and platform audit entries atomically.
  Purged tenants keep their hosts reserved. Platform authority is enforced by
  the caller; the context requires audit attribution and a registered schema.
  """

  import Ecto.Query
  require Logger

  alias Letflow.{Audit, Identity, Repo, TenantProvisioning}
  alias Letflow.Identity.{OnboardingRecord, Tenant}
  alias Letflow.TenantProvisioner.{Config, Request}

  @type write_opts :: [
          actor_id: Ecto.UUID.t(),
          platform_prefix: String.t(),
          trace_id: String.t() | nil
        ]

  @spec normalize(term()) :: {:ok, String.t()} | {:error, atom()}
  def normalize(raw) when is_binary(raw) do
    if byte_size(raw) > 300 or not String.valid?(raw) do
      {:error, :invalid_hostname}
    else
      host = raw |> String.trim() |> String.downcase()

      cond do
        host == "" ->
          {:error, :required}

        Tenant.reserved_slug?(hd(String.split(host, ".", parts: 2))) ->
          {:error, :reserved_hostname}

        true ->
          case Request.hostname(host, Config.allowed_hostname_suffixes()) do
            {:ok, host} -> {:ok, host}
            {:error, _} -> {:error, :invalid_hostname}
          end
      end
    end
  end

  def normalize(_raw), do: {:error, :required}

  @doc "Whether a normalized host is held, including legacy padded/case variants."
  @spec taken?(String.t(), Ecto.UUID.t() | nil) :: boolean()
  def taken?(host, except_tenant_id) do
    query = from(r in OnboardingRecord, where: fragment("lower(btrim(?))", r.hostname) == ^host)

    query =
      if except_tenant_id,
        do: from(r in query, where: r.tenant_id != ^except_tenant_id),
        else: query

    Repo.exists?(query)
  end

  @spec set_host(Ecto.UUID.t(), term(), write_opts()) ::
          {:ok, :created | :changed | :unchanged, OnboardingRecord.t()} | {:error, atom()}
  def set_host(tenant_id, raw, opts) do
    with {:ok, host} <- normalize(raw) do
      write(tenant_id, opts, fn tenant, prefix, rows ->
        if taken?(host, tenant.id), do: Repo.rollback(:hostname_taken)

        case rows do
          [%{hostname: ^host} = record] ->
            {:unchanged, record}

          [] ->
            record =
              save(
                OnboardingRecord.insert_changeset(%OnboardingRecord{}, %{
                  tenant_id: tenant.id,
                  slug: tenant.slug,
                  hostname: host
                }),
                :insert
              )

            audit!(tenant.id, prefix, opts, "set", nil, host, record.id, :created)
            {:created, record}

          [old] ->
            record = save(OnboardingRecord.hostname_changeset(old, %{hostname: host}), :update)
            audit!(tenant.id, prefix, opts, "set", old.hostname, host, record.id, :changed)
            {:changed, record}

          _multiple ->
            Repo.rollback(:ambiguous_host)
        end
      end)
      |> case do
        {:ok, {outcome, record}} -> {:ok, outcome, record}
        error -> error
      end
    end
  end

  @spec remove_host(Ecto.UUID.t(), write_opts()) ::
          {:ok, :removed | :unchanged} | {:error, atom()}
  def remove_host(tenant_id, opts) do
    write(tenant_id, opts, fn tenant, prefix, rows ->
      case rows do
        [] ->
          :unchanged

        _ ->
          ids = Enum.map(rows, & &1.id)
          Repo.delete_all(from(r in OnboardingRecord, where: r.id in ^ids))
          before = rows |> Enum.map(& &1.hostname) |> Enum.sort()
          audit!(tenant.id, prefix, opts, "removed", before, nil, nil, :removed)
          :removed
      end
    end)
  end

  defp write(tenant_id, opts, fun) do
    if is_binary(opts[:actor_id]) and is_binary(opts[:platform_prefix]) do
      Repo.transaction(fn ->
        tenant = Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE"))
        if is_nil(tenant), do: Repo.rollback(:not_found)
        if Identity.tenant_purged?(tenant.id), do: Repo.rollback(:tenant_purged)
        registration = Repo.get_by(TenantProvisioning.Registration, tenant_id: tenant.id)
        if is_nil(registration), do: Repo.rollback(:not_provisioned)

        rows =
          Repo.all(
            from(r in OnboardingRecord, where: r.tenant_id == ^tenant.id, lock: "FOR UPDATE")
          )

        fun.(tenant, registration.schema_name, rows)
      end)
    else
      {:error, :audit_failed}
    end
  rescue
    exception ->
      Logger.error(
        "tenant host write failed (tenant_id=#{inspect(tenant_id)}, exception=#{inspect(exception.__struct__)})"
      )

      {:error, :internal}
  catch
    :exit, reason ->
      Logger.error(
        "tenant host write failed (tenant_id=#{inspect(tenant_id)}, exit=#{inspect(exit_tag(reason))})"
      )

      {:error, :internal}
  end

  defp exit_tag(reason) when is_atom(reason), do: reason
  defp exit_tag({tag, _}) when is_atom(tag), do: tag
  defp exit_tag(_), do: :other

  defp save(changeset, operation) do
    case apply(Repo, operation, [changeset]) do
      {:ok, record} ->
        record

      {:error, changeset} ->
        if Enum.any?(changeset.errors, fn {field, {_message, metadata}} ->
             field == :hostname and metadata[:constraint] == :unique
           end), do: Repo.rollback(:hostname_taken), else: Repo.rollback(:internal)
    end
  end

  defp audit!(id, prefix, opts, action, before, host, onboarding_id, outcome) do
    tenant_attrs = %{
      actor_id: nil,
      action: "tenant.hostname." <> action,
      resource_type: "tenant",
      resource_id: id,
      trace_id: nil,
      before_state: nil,
      after_state: %{"hostname" => host, "actor_class" => "platform_operator"}
    }

    platform_after = %{"tenant_id" => id, "hostname" => host}

    platform_after =
      if action == "set",
        do:
          Map.merge(platform_after, %{
            "onboarding_id" => onboarding_id,
            "outcome" => Atom.to_string(outcome)
          }),
        else: platform_after

    platform_attrs = %{
      actor_id: opts[:actor_id],
      action: "platform.tenant_hostname." <> action,
      resource_type: "tenant",
      resource_id: id,
      trace_id: opts[:trace_id],
      before_state: %{"hostname" => before},
      after_state: platform_after
    }

    for {attrs, chain} <- [{tenant_attrs, prefix}, {platform_attrs, opts[:platform_prefix]}] do
      case Audit.insert_entry(Repo, attrs, chain) do
        {:ok, _} -> :ok
        {:error, _} -> Repo.rollback(:audit_failed)
      end
    end
  end
end
