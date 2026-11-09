defmodule Letflow.UserNotifications do
  @moduledoc """
  In-app notification list for the bell (T-1561): a per-user, per-tenant list with read/unread.
  It is NOT the mail log (`Letflow.Notifications`, `notification_deliveries`) and never calls a
  mail adapter.

  A plain context like `Letflow.UserPreferences`: the tenant `prefix` is on every query (INV-1)
  and the user id comes only from the caller's auth context, so no function reads another
  user's rows for a caller. Notifications are derived data, not a business fact: no audit entry.

  ## Kinds

  The closed list is `@kinds` in code only (the `kind` column has no CHECK). Today only
  `task_assigned` has a producer (`Letflow.Tasks`, after a committed (re)assignment). A later
  producer task appends its atom here and to the web map; no migration is needed.

  ## Rules

  `notify/6` is best effort and never raises (INV-8); an unknown kind or a non-UUID id writes
  nothing and returns `:ok`. It keeps the newest 200 rows per user. `mark_read/3` and
  `mark_all_read/2` touch only the caller's own unread rows: an id of someone else's row or an
  unknown id is counted 0, indistinguishable from each other (INV-5).
  """

  import Ecto.Query

  require Logger

  alias Letflow.Repo
  alias Letflow.UserNotifications.Notification

  @kinds ~w(task_assigned)
  @cap_per_user 200
  @max_limit 100
  @default_limit 50
  @max_ids 100
  @max_title 200

  @doc "The closed list of notification kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Stores one notification. Best effort: never raises, always `:ok`."
  @spec notify(String.t(), String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok
  def notify(prefix, tenant_id, user_id, kind, ref_id, title) do
    with true <- kind in @kinds,
         {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, user_id} <- Ecto.UUID.cast(user_id),
         {:ok, ref_id} <- cast_ref(ref_id) do
      Repo.insert!(
        %Notification{
          tenant_id: tenant_id,
          user_id: user_id,
          kind: kind,
          ref_id: ref_id,
          title: clean_title(title)
        },
        prefix: prefix
      )

      prune(prefix, user_id)
      :ok
    else
      _ ->
        Logger.warning("user_notifications: not stored")
        :ok
    end
  rescue
    _exception ->
      Logger.warning("user_notifications: not stored")
      :ok
  catch
    _kind, _reason ->
      Logger.warning("user_notifications: not stored")
      :ok
  end

  @doc "The caller's newest notifications (limit clamped to 1..100) and ALL their unread count."
  @spec list(String.t(), String.t(), term()) :: %{items: [map()], unread_count: non_neg_integer()}
  def list(prefix, user_id, limit \\ @default_limit) do
    rows =
      from(n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^clamp(limit)
      )
      |> Repo.all(prefix: prefix)

    %{items: Enum.map(rows, &to_map/1), unread_count: unread_count(prefix, user_id)}
  end

  @doc "Marks the caller's own listed unread rows read; returns how many changed."
  @spec mark_read(String.t(), String.t(), term()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_ids}
  def mark_read(prefix, user_id, ids) when is_list(ids) and length(ids) <= @max_ids do
    casted = Enum.map(ids, &Ecto.UUID.cast/1)

    if ids != [] and Enum.all?(casted, &match?({:ok, _}, &1)) do
      uuids = Enum.map(casted, fn {:ok, u} -> u end)

      {n, _} =
        from(n in Notification,
          where: n.user_id == ^user_id and is_nil(n.read_at) and n.id in ^uuids
        )
        |> Repo.update_all([set: [read_at: DateTime.utc_now()]], prefix: prefix)

      {:ok, n}
    else
      {:error, :invalid_ids}
    end
  end

  def mark_read(_prefix, _user_id, _ids), do: {:error, :invalid_ids}

  @doc "Marks all the caller's unread rows read."
  @spec mark_all_read(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def mark_all_read(prefix, user_id) do
    {n, _} =
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all([set: [read_at: DateTime.utc_now()]], prefix: prefix)

    {:ok, n}
  end

  @doc "How many unread rows the caller has."
  @spec unread_count(String.t(), String.t()) :: non_neg_integer()
  def unread_count(prefix, user_id) do
    from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
    |> Repo.aggregate(:count, prefix: prefix)
  end

  defp to_map(n) do
    %{
      "id" => n.id,
      "kind" => n.kind,
      "ref_id" => n.ref_id,
      "title" => n.title,
      "read" => not is_nil(n.read_at),
      "inserted_at" => DateTime.to_iso8601(n.inserted_at)
    }
  end

  defp prune(prefix, user_id) do
    older =
      from(n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        offset: ^@cap_per_user,
        select: n.id
      )

    from(n in Notification, where: n.id in subquery(older))
    |> Repo.delete_all(prefix: prefix)
  end

  defp cast_ref(nil), do: {:ok, nil}
  defp cast_ref(ref), do: Ecto.UUID.cast(ref)

  defp clean_title(title) when is_binary(title), do: String.slice(title, 0, @max_title)
  defp clean_title(_other), do: ""

  defp clamp(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  defp clamp(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> clamp(n)
      _ -> @default_limit
    end
  end

  defp clamp(_limit), do: @default_limit
end
