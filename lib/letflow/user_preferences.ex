defmodule Letflow.UserPreferences do
  @moduledoc """
  Per-user preferences store (T-1389, decisions D-100/D-101): a small whitelist of keys, each with
  a validated value, stored per tenant schema per user id in `user_preferences`.

  A plain transactional context (the same shape as `Letflow.Labels`): `Multi` plus
  `Audit.append_multi/4`, the tenant `prefix` on every query (INV-1). The user id comes from the
  caller's auth context only; no function here reads another user's rows for a caller.

  ## Whitelist

  `ui.document_layout` is `"row"` (default) or `"tabs"`. The list mirrors the web registry
  `LFDocLayout` and must change with it. An unset key is simply absent: the client applies its
  default (later the tenant default).

  ## Rules

  `put/3` merges: each listed key is upserted, `nil` deletes the key (reset), unlisted keys are
  untouched. All-or-nothing: one bad key or value refuses the request and writes nothing. Limits:
  at most 8 keys per request, at most 256 bytes of JSON per value. One audit entry per changed
  key (`user_preferences.set` / `user_preferences.reset`), none for a no-op.

  `value` is stored as `%{"v" => value}`; the wrapper never leaves this module (reads, the
  response and the audit state show the plain value).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Repo
  alias Letflow.UserPreferences.Preference

  @max_keys 8
  @max_value_bytes 256
  @key_pattern ~r/\A[a-z][a-z0-9_.]*\z/

  @keys %{"ui.document_layout" => {:enum, ["row", "tabs"]}}

  @doc "The whitelisted keys."
  @spec keys() :: [String.t()]
  def keys, do: @keys |> Map.keys() |> Enum.sort()

  @doc "The allowed values of an enum key (`[]` for an unknown key)."
  @spec allowed_values(String.t()) :: [String.t()]
  def allowed_values(key) do
    case Map.get(@keys, key) do
      {:enum, values} -> values
      _ -> []
    end
  end

  @doc "The stored preferences of one user as `%{key => value}` (only stored keys, whitelisted ones)."
  @spec list(String.t(), String.t()) :: %{optional(String.t()) => term()}
  def list(prefix, user_id) do
    from(p in Preference,
      where: p.user_id == ^user_id and p.key in ^keys(),
      select: {p.key, p.value}
    )
    |> Repo.all(prefix: prefix)
    |> Map.new(fn {key, wrapped} -> {key, unwrap(wrapped)} end)
  end

  @doc """
  Merges `prefs` (`%{key => value | nil}`) into the user's preferences. Returns the full resulting
  map, `{:error, {:invalid, detail}}` with a fixed 422 text, or `{:error, reason}` on a database failure.
  """
  @spec put(String.t(), String.t(), term()) ::
          {:ok, %{optional(String.t()) => term()}}
          | {:error, {:invalid, String.t()} | term()}
  def put(prefix, user_id, prefs) do
    with :ok <- check(prefs) do
      multi =
        prefs
        |> Enum.sort()
        |> Enum.reduce(Multi.new(), fn {key, value}, acc ->
          change(acc, prefix, user_id, key, value)
        end)

      case Repo.transaction(multi) do
        {:ok, _} -> {:ok, list(prefix, user_id)}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # ── validation ────────────────────────────────────────────────────────────

  defp check(prefs) when is_map(prefs) and map_size(prefs) > 0 do
    cond do
      map_size(prefs) > @max_keys -> too_large()
      true -> Enum.find_value(prefs, :ok, fn {key, value} -> check_pair(key, value) end)
    end
  end

  defp check(_prefs), do: invalid("preferences must be a non-empty object")

  defp check_pair(key, value) do
    cond do
      not (is_binary(key) and byte_size(key) <= 64 and Regex.match?(@key_pattern, key)) ->
        invalid("invalid preference key")

      not Map.has_key?(@keys, key) ->
        invalid("unknown preference key: #{key}")

      value == nil ->
        nil

      byte_size(Jason.encode!(value)) > @max_value_bytes ->
        too_large()

      valid_value?(Map.fetch!(@keys, key), value) ->
        nil

      true ->
        invalid("invalid value for preference key: #{key}")
    end
  end

  defp valid_value?({:enum, values}, value), do: is_binary(value) and value in values

  defp invalid(detail), do: {:error, {:invalid, detail}}
  defp too_large, do: invalid("preferences too large")

  # ── writes ────────────────────────────────────────────────────────────────

  defp change(multi, prefix, user_id, key, value) do
    Multi.run(multi, {:pref, key}, fn _repo, _changes ->
      before = current(prefix, user_id, key)
      apply_change(prefix, user_id, key, before, value)
    end)
  end

  defp apply_change(_prefix, _user_id, _key, nil, nil), do: {:ok, :unchanged}
  defp apply_change(_prefix, _user_id, _key, {:ok, same}, same), do: {:ok, :unchanged}

  defp apply_change(prefix, user_id, key, before, nil) do
    from(p in Preference, where: p.user_id == ^user_id and p.key == ^key)
    |> Repo.delete_all(prefix: prefix)

    audit(prefix, user_id, "user_preferences.reset", key, before, nil)
  end

  defp apply_change(prefix, user_id, key, before, value) do
    Repo.insert!(
      %Preference{
        user_id: user_id,
        key: key,
        value: %{"v" => value},
        updated_at: DateTime.utc_now()
      },
      prefix: prefix,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:user_id, :key]
    )

    audit(prefix, user_id, "user_preferences.set", key, before, {:ok, value})
  end

  defp current(prefix, user_id, key) do
    from(p in Preference, where: p.user_id == ^user_id and p.key == ^key, select: p.value)
    |> Repo.one(prefix: prefix)
    |> case do
      nil -> nil
      wrapped -> {:ok, unwrap(wrapped)}
    end
  end

  defp audit(prefix, user_id, action, key, before, after_value) do
    Audit.insert_entry(
      Repo,
      %{
        actor_id: user_id,
        action: action,
        resource_type: "user_preference",
        resource_id: "#{user_id}:#{key}",
        before_state: state(before),
        after_state: state(after_value)
      },
      prefix
    )
  end

  defp state(nil), do: nil
  defp state({:ok, value}), do: %{"value" => value}

  defp unwrap(%{"v" => value}), do: value
end
