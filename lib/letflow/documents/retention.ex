defmodule Letflow.Documents.Retention do
  @moduledoc """
  Document retention, part (a) of decision 0063 (REQ-508, GH #2675).

  Two functions, both taking the tenant schema name as `prefix` (INV-1):

    * `eligible_version_ids/2` reads which versions a type's retention policy makes
      eligible at an injected `now` (0063 S6). It returns ids only and performs no write;
      executing archive or purge is REQ-509. The result is unbounded on purpose: paging is
      REQ-509's decision.
    * `change_policy/5` writes the three policy columns of one document type and records
      a `document.retention_policy_changed` entry in the tenant audit chain (0063 S4,
      decision 0056 D9) in the same transaction.

  The policy is read live at query time (0063 S3 residual). The hold functions (`Letflow.Documents.Hold`, REQ-536) that set
  `documents.on_hold` belong to REQ-536; this module only reads the flag.

  `change_policy/5` checks no permission or scope: the route `Letflow.Routers.Documents` (REQ-536)
  does both and must stay its only caller (same stance as `Letflow.Audit`).
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentType
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @action "document.retention_policy_changed"
  @retention_froms ~w(issued superseded_or_cancelled)
  @retention_actions ~w(keep archive purge)
  @reason_code_re ~r/^[a-z][a-z0-9_]{0,63}$/

  @type policy :: %{
          retention_period_days: pos_integer() | nil,
          retention_from: String.t(),
          retention_action: String.t()
        }

  @doc """
  Ids of the versions that are eligible for the retention action at `now`.

  Only `superseded` and `cancelled` versions of documents that are not on hold, whose type
  has a period and an action other than `keep`, qualify. The closing time is `cancelled_at`
  for a cancelled version and the `issued_at` of the version named by `superseded_by_version`
  for a superseded one (0063 S1); a superseded version whose successor is not issued has no
  closing time and is not returned. With `retention_from = 'issued'` the version's own
  `issued_at` is used. The boundary is inclusive. Ordered by id.
  """
  @spec eligible_version_ids(String.t(), DateTime.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :invalid_schema_name}
  def eligible_version_ids(prefix, %DateTime{} = now) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(v in DocumentVersion,
          join: d in Document,
          on: d.id == v.document_id,
          join: t in DocumentType,
          on: t.key == d.type_key,
          left_join: n in DocumentVersion,
          on: n.document_id == v.document_id and n.id == v.superseded_by_version,
          where: v.status in [:superseded, :cancelled] and not d.on_hold,
          where:
            not is_nil(t.retention_period_days) and t.retention_action in ["archive", "purge"],
          where:
            fragment(
              "(CASE ? WHEN 'issued' THEN ? ELSE (CASE ?::text WHEN 'cancelled' THEN ? ELSE ? END) END) + make_interval(days => ?) <= ?",
              t.retention_from,
              v.issued_at,
              v.status,
              v.cancelled_at,
              n.issued_at,
              t.retention_period_days,
              type(^now, :utc_datetime_usec)
            ),
          order_by: v.id,
          select: v.id
        )

      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  @doc """
  Changes the retention policy of document type `type_key` and audits it.

  `attrs` holds all three of `:retention_period_days`, `:retention_from` and
  `:retention_action`. Returns `{:ok, %{type_key:, before:, after:, changed:}}`; an unchanged
  policy is a no-op (no UPDATE, no audit entry). Input the function refuses comes back as
  `{:error, {:unprocessable, reason}}` (a caller maps it to 422) before any query, so the
  database CHECK is never the first refusal. `{:error, :not_found}` for an unknown key.
  The UPDATE and the audit entry commit or roll back together.
  """
  @spec change_policy(String.t(), String.t(), map(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, {:unprocessable, atom()}}
          | {:error, :not_found | :invalid_schema_name}
  def change_policy(prefix, type_key, attrs, actor_id, reason_code)
      when is_binary(prefix) and is_binary(type_key) and is_map(attrs) do
    with {:ok, policy} <- validate_policy(attrs),
         :ok <- validate_reason_code(reason_code),
         :ok <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      Repo.transaction(fn ->
        case apply_change(prefix, type_key, policy, actor_id, reason_code) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp apply_change(prefix, type_key, policy, actor_id, reason_code) do
    locked =
      from(t in DocumentType,
        where: t.key == ^type_key,
        lock: "FOR UPDATE",
        select: map(t, [:retention_period_days, :retention_from, :retention_action])
      )
      |> Repo.one(prefix: prefix)

    case locked do
      nil ->
        {:error, :not_found}

      before when before == policy ->
        {:ok, %{type_key: type_key, before: before, after: policy, changed: false}}

      before ->
        from(t in DocumentType, where: t.key == ^type_key)
        |> Repo.update_all([set: Map.to_list(policy)], prefix: prefix)

        entry = %{
          actor_id: actor_id,
          action: @action,
          resource_type: "document_type",
          resource_id: type_key,
          before_state: Map.put(state(before), "type_key", type_key),
          after_state:
            policy
            |> state()
            |> Map.put("type_key", type_key)
            |> Map.put("reason_code", reason_code)
        }

        case Audit.insert_entry(Repo, entry, prefix) do
          {:ok, _entry} ->
            {:ok, %{type_key: type_key, before: before, after: policy, changed: true}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp state(policy), do: Map.new(policy, fn {k, v} -> {Atom.to_string(k), v} end)

  defp validate_policy(%{
         retention_period_days: period,
         retention_from: from,
         retention_action: action
       }) do
    cond do
      not (is_nil(period) or (is_integer(period) and period > 0)) ->
        {:error, {:unprocessable, :invalid_period}}

      from not in @retention_froms ->
        {:error, {:unprocessable, :invalid_retention_from}}

      action not in @retention_actions ->
        {:error, {:unprocessable, :invalid_retention_action}}

      is_nil(period) != (action == "keep") ->
        {:error, {:unprocessable, :period_action_mismatch}}

      true ->
        {:ok, %{retention_period_days: period, retention_from: from, retention_action: action}}
    end
  end

  defp validate_policy(_attrs), do: {:error, {:unprocessable, :invalid_period}}

  defp validate_reason_code(code) when is_binary(code) do
    if Regex.match?(@reason_code_re, code),
      do: :ok,
      else: {:error, {:unprocessable, :invalid_reason_code}}
  end

  defp validate_reason_code(_), do: {:error, {:unprocessable, :invalid_reason_code}}

  defp validate_actor(actor) when is_binary(actor) do
    case Ecto.UUID.cast(actor) do
      {:ok, _} -> :ok
      :error -> {:error, {:unprocessable, :invalid_actor}}
    end
  end

  defp validate_actor(_), do: {:error, {:unprocessable, :invalid_actor}}
end
