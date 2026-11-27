defmodule Letflow.PlatformFunctions.CreationCompensation do
  @moduledoc """
  T-3233 (analysis `docs/analysis-orphan-tenant-schemas-2026-11-28.md`, task text (a)): the
  COMPENSATION of a failed tenant registration chain.

  The chain `tenant.create -> tenant.provision -> tenant.record_lifecycle -> tenant.record_onboarding
  -> ...` commits each step on its own, so a terminal failure of `tenant.provision`,
  `tenant.record_lifecycle` or `tenant.record_onboarding` (a taken hostname, a refused write, a crash
  that used up the attempt cap) used to leave a tenant with a schema and a `tenant_schemas` row but no
  lifecycle or onboarding rows, for ever. Chosen remedy: option (1) of the task, a compensation on the
  terminal failure of one of those three steps. (Option (2), one transaction, is impossible: the
  provision replays DDL migrations, which cannot sit in one outer transaction.)

  The dispatcher calls `on_given_up/2` after it has written `given_up` for a step. It does the
  following, and nothing else:

    1. the step is one of the three above (every other step keeps the old rule: a failure later in the
       chain leaves a complete tenant that a repeat of the chain finishes);
    2. the tenant is read from the OUTPUT of the same instance's advanced `tenant.create` step, never
       from an input a person can set;
    3. the instance itself CREATED that tenant: the tenant row is not older than that dispatch row, and
       no other instance's `tenant.create` row names the same tenant earlier. A `tenant.create` that
       adopted an existing slug (a replay, `TenantCreate`'s moduledoc) fails this proof and the
       tenant is left alone;
    4. `Letflow.TenantPurge.compensate_creation/1` undoes it: the only code that drops a schema (this
       module never issues a DROP), refusing the platform tenant.

  It never raises (INV-8): a failed compensation is logged as the tenant id and a code, never a
  message, and the dispatcher's answer does not change. A manual retry of a compensated step then
  fails with `platform_call_tenant_purged` (a purge is final), as designed.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.TenantPurge

  @steps ["tenant.provision", "tenant.record_lifecycle", "tenant.record_onboarding"]

  @doc "The steps whose terminal failure compensates."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc """
  Called by the dispatcher after a step of the platform tenant became `given_up`. Always `:ok`.
  """
  @spec on_given_up(map(), String.t()) :: :ok
  def on_given_up(%{function_name: name, instance_id: instance_id}, prefix)
      when name in @steps and is_binary(instance_id) and is_binary(prefix) do
    with {:ok, tenant_id} <- created_tenant(instance_id, prefix),
         {:ok, _outcome} <- TenantPurge.compensate_creation(tenant_id) do
      :ok
    else
      {:error, :not_created_by_instance} ->
        :ok

      other ->
        Logger.error("creation compensation not done (instance_id=#{instance_id}, #{tag(other)})")
        :ok
    end
  rescue
    exception ->
      Logger.error("creation compensation raised (exception=#{inspect(exception.__struct__)})")

      :ok
  end

  def on_given_up(_dispatch, _prefix), do: :ok

  # The tenant of `tenant.create` of THIS instance, when this instance created it.
  defp created_tenant(instance_id, prefix) do
    create_row =
      Repo.one(
        from(d in StepDispatch,
          where:
            d.instance_id == ^instance_id and d.function_name == "tenant.create" and
              d.status == :advanced,
          limit: 1
        ),
        prefix: prefix
      )

    with %StepDispatch{outputs: %{"tenant_id" => raw}} = row <- create_row,
         {:ok, tenant_id} <- Ecto.UUID.cast(raw),
         %Tenant{} = tenant <- Repo.get(Tenant, tenant_id),
         true <- tenant_newer_than?(tenant, row),
         false <- earlier_create?(tenant_id, row, prefix) do
      {:ok, tenant_id}
    else
      _other -> {:error, :not_created_by_instance}
    end
  end

  # The tenant row was written by the body of the dispatch row, so it is not older than the row.
  defp tenant_newer_than?(%Tenant{inserted_at: inserted}, %StepDispatch{created_at: armed}) do
    inserted |> DateTime.from_naive!("Etc/UTC") |> DateTime.compare(armed) != :lt
  end

  # Another instance's `tenant.create` that already named this tenant means this one adopted it.
  defp earlier_create?(tenant_id, row, prefix) do
    Repo.exists?(
      from(d in StepDispatch,
        where:
          d.function_name == "tenant.create" and d.id != ^row.id and d.status == :advanced and
            d.created_at < ^row.created_at and
            fragment("?->>'tenant_id' = ?", d.outputs, ^tenant_id)
      ),
      prefix: prefix
    )
  end

  defp tag({:error, reason}) when is_atom(reason), do: "reason=#{reason}"
  defp tag(_other), do: "reason=other"
end
