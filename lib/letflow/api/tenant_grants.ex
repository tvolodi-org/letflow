defmodule Letflow.Api.TenantGrants do
  @moduledoc """
  T-1570 (D-097, owner decision 2026-11-09): the per-tenant, add-only role grant overlay. A tenant's
  STOREKEEPER may hold `AssetsRead` and `AssetsPost` when the tenant's own `assets` module row
  (`tenant_modules.settings["storekeeper_grants"]`) lists them.

  `Letflow.Api.Authorization` stays pure: it takes the overlay as an explicit input value
  (`AccessContext.role_overlay`, `role_allows?/3`, `has_permission_in_scope?/4`) and clamps it to the
  closed `Authorization.grantable/0`. This module is the only reader and writer of the data, at the
  request edge. The tenant is `prefix` only (INV-1), never a request field. A missing, uninstalled or
  unreadable row, or a stored value outside the closed list, reads as no grant (fail closed).

  Module upgrades never write the key (the manifest `role_grants` stays empty), so an upgrade cannot
  widen or narrow a tenant. Existing tenants have no key and stay off until switched on; tenants that
  install `assets` after this change get the default (`default_storekeeper/0`) from `Assets.on_install/3`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Audit
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  require Logger

  @module_id "assets"
  @key "storekeeper_grants"

  @doc "The grants a new tenant gets: read and post (not reverse, reconcile or card write)."
  @spec default_storekeeper() :: [String.t()]
  def default_storekeeper, do: ["AssetsRead", "AssetsPost"]

  @doc "The overlay of the tenant schema `prefix`; `%{}` (baseline) on any doubt."
  @spec load(String.t()) :: Authorization.role_overlay()
  def load(prefix) when is_binary(prefix) do
    case fetch_row(prefix) do
      %TenantModule{settings: settings} -> overlay_from_settings(settings)
      _ -> %{}
    end
  rescue
    error ->
      Logger.error("tenant_grants_load_failed kind=#{inspect(error.__struct__)}")
      %{}
  end

  def load(_other), do: %{}

  @doc "`load/1` only when a granted role is among `roles` (saves a query per request for everyone else)."
  @spec load_for([atom()], String.t()) :: Authorization.role_overlay()
  def load_for(roles, prefix) when is_list(roles) do
    if Enum.any?(roles, &Map.has_key?(Authorization.grantable(), &1)), do: load(prefix), else: %{}
  end

  @doc "Builds the overlay from a settings map (strings to atoms through `grantable/0` only)."
  @spec overlay_from_settings(term()) :: Authorization.role_overlay()
  def overlay_from_settings(%{@key => list}) when is_list(list) do
    allowed = Map.fetch!(Authorization.grantable(), :STOREKEEPER)
    atoms = for a <- allowed, Atom.to_string(a) in list, do: a
    Authorization.sanitize_overlay(%{STOREKEEPER: atoms})
  end

  def overlay_from_settings(_), do: %{}

  @doc "The stored storekeeper grants as strings, in `grantable/0` order."
  @spec storekeeper(Authorization.role_overlay()) :: [String.t()]
  def storekeeper(overlay),
    do: overlay |> Map.get(:STOREKEEPER, []) |> Enum.map(&Atom.to_string/1)

  @doc """
  Replaces the storekeeper list (strings) in the tenant's assets settings, keeping every other
  settings key, and appends an audit entry in the same transaction.
  """
  @spec put_storekeeper(String.t(), [String.t()], map()) ::
          {:ok, [String.t()]} | {:error, :not_installed | :invalid_grants | term()}
  def put_storekeeper(prefix, list, actor) when is_binary(prefix) and is_list(list) do
    allowed = Enum.map(Map.fetch!(Authorization.grantable(), :STOREKEEPER), &Atom.to_string/1)

    if Enum.all?(list, &(&1 in allowed)) do
      normalised = Enum.filter(allowed, &(&1 in list))
      do_put(prefix, normalised, actor)
    else
      {:error, :invalid_grants}
    end
  end

  def put_storekeeper(_prefix, _list, _actor), do: {:error, :invalid_grants}

  defp do_put(prefix, normalised, actor) do
    Repo.transaction(fn ->
      row =
        case Repo.one(
               from(t in TenantModule,
                 where: t.module_id == ^@module_id and t.status == :active,
                 lock: "FOR UPDATE"
               ),
               prefix: prefix
             ) do
          nil -> Repo.rollback(:not_installed)
          row -> row
        end

      before = storekeeper(overlay_from_settings(row.settings))

      case Installs.put_settings(@module_id, Map.put(row.settings || %{}, @key, normalised),
             prefix: prefix
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      attrs = %{
        actor_id: actor.user_id,
        action: "tenant.role_grants_changed",
        resource_type: "tenant_role_grants",
        resource_id: @module_id,
        before_state: %{"storekeeper" => before},
        after_state: %{
          "storekeeper" => normalised,
          "credential" => Map.get(actor, :credential),
          "trace_id" => Map.get(actor, :trace_id)
        },
        trace_id: Map.get(actor, :trace_id)
      }

      case Audit.insert_entry(Repo, attrs, prefix) do
        {:ok, _} -> normalised
        {:error, reason} -> Repo.rollback({:audit_failed, reason})
      end
    end)
  end

  @doc """
  Seeds the default into a freshly installed tenant row (called by `Assets.on_install/3` when the
  settings carry no key). Never overwrites an existing key.
  """
  @spec seed_default(String.t()) :: :ok | {:error, term()}
  def seed_default(prefix) when is_binary(prefix) do
    case fetch_row(prefix) do
      %TenantModule{settings: settings} = row ->
        settings = settings || %{}

        if Map.has_key?(settings, @key) do
          :ok
        else
          row
          |> TenantModule.settings_changeset(%{
            settings: Map.put(settings, @key, default_storekeeper())
          })
          |> Repo.update(prefix: prefix)
          |> case do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      nil ->
        :ok
    end
  end

  defp fetch_row(prefix),
    do: Repo.get_by(TenantModule, [module_id: @module_id, status: :active], prefix: prefix)
end
