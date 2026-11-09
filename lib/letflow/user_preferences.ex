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

  `ui.layout` is the remembered screen layout (side nav state, pane percentages, collapsed panes,
  column widths): one JSON document passed as a string of at most 8192 bytes. The server stores
  and returns the sanitized canonical JSON string (`sanitize_layout/1`, the twin of `LFPrefs.sanitize`
  in the design repo's `demo.js`, same cases as `core/tools/test_prefs.js`). Deliberate differences:
  numbers only (JS also coerces strings and booleans); when a cap (40 screens, 12 splits, 24 tables,
  40 columns) is hit the lexicographically first keys survive, as decoded maps keep no object order;
  an integral float counts as an integer in `collapsed`. `ui.layout` has no tenant default.
  A screen may also carry `linesMode` (T-1448), the remembered entry mode of the lines editor: exactly
  `"grid"` or `"form"`, anything else is dropped.

  `notifications.email` is `"on"` (default when absent) or `"off"` (T-1571): the user's opt-out of the
  e-mail copy of the notification bell, which the tenant switch `notifications.email_copy` enables.

  ## Rules

  `put/3` merges: each listed key is upserted, `nil` deletes the key (reset), unlisted keys are
  untouched. All-or-nothing: one bad key or value refuses the request and writes nothing. Limits:
  at most 8 keys per request, at most 256 bytes of JSON per value (8192 bytes for `ui.layout`). One audit entry per changed
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

  @max_layout_bytes 8192
  @screen_id ~r/\A[a-z0-9.-]{1,48}\z/
  @split_id ~r/\A[a-z0-9-]{1,24}\z/

  @keys %{
    "notifications.email" => {:enum, ["on", "off"]},
    "ui.document_layout" => {:enum, ["row", "tabs"]},
    "ui.layout" => :layout
  }

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

  @layout_key "ui.document_layout"
  @tenant_layout_key "ui.document_layout_default"

  @doc """
  The tenant defaults as `%{key => value}`: the tenant setting when it holds an allowed value,
  else `"row"` (a garbage stored value never raises).
  """
  @spec tenant_defaults(term()) :: %{String.t() => String.t()}
  def tenant_defaults(tenant_settings) do
    value = if is_map(tenant_settings), do: Map.get(tenant_settings, @tenant_layout_key)
    %{@layout_key => if(valid_layout?(value), do: value, else: "row")}
  end

  @doc """
  The effective preferences of one user: the stored user value when valid, else the tenant
  default, else `"row"`.
  """
  @spec effective(String.t(), String.t(), term()) :: %{String.t() => String.t()}
  def effective(prefix, user_id, tenant_settings) do
    stored = Map.get(list(prefix, user_id), @layout_key)
    defaults = tenant_defaults(tenant_settings)
    %{@layout_key => if(valid_layout?(stored), do: stored, else: defaults[@layout_key])}
  end

  defp valid_layout?(v), do: is_binary(v) and v in allowed_values(@layout_key)

  @doc """
  True when the user opted out of the e-mail copy (`notifications.email` = `"off"`). Any failure
  counts as opted out: a mail to a person is not sent on doubt.
  """
  @spec email_opt_out?(String.t(), term()) :: boolean()
  def email_opt_out?(prefix, user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> Map.get(list(prefix, id), "notifications.email") == "off"
      :error -> true
    end
  rescue
    _ -> true
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
    with {:ok, prefs} <- check(prefs) do
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
      map_size(prefs) > @max_keys ->
        too_large()

      true ->
        Enum.reduce_while(prefs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case check_pair(key, value) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, key, v)}}
            {:error, _} = err -> {:halt, err}
          end
        end)
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
        {:ok, nil}

      Map.fetch!(@keys, key) == :layout ->
        check_layout(key, value)

      byte_size(Jason.encode!(value)) > @max_value_bytes ->
        too_large()

      valid_value?(Map.fetch!(@keys, key), value) ->
        {:ok, value}

      true ->
        invalid("invalid value for preference key: #{key}")
    end
  end

  # `ui.layout`: a JSON string; the stored value is its sanitized canonical form.
  defp check_layout(key, value) do
    cond do
      not is_binary(value) -> invalid("invalid value for preference key: #{key}")
      byte_size(value) > @max_layout_bytes -> too_large()
      true -> decode_layout(key, value)
    end
  end

  defp decode_layout(key, text) do
    case safe_decode(text) do
      {:ok, term} -> {:ok, Jason.encode!(sanitize_layout(term))}
      :error -> invalid("invalid value for preference key: #{key}")
    end
  end

  defp safe_decode(text) do
    case Jason.decode(text) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  The Elixir twin of `LFPrefs.sanitize`: any term in, the canonical layout map out
  (`%{"v" => 1, "shell" => ..., "screens" => ...}`), unknown keys dropped, numbers clamped and
  rounded, caps applied, and `screens` emptied when the result exceeds 8192 bytes of JSON.
  """
  @spec sanitize_layout(term()) :: map()
  def sanitize_layout(doc) do
    out = %{"v" => 1, "shell" => %{"sidenav" => %{}}, "screens" => %{}}

    out =
      if is_map(doc) do
        out
        |> Map.put("shell", %{
          "sidenav" => sanitize_sidenav(get_in_map(doc, ["shell", "sidenav"]))
        })
        |> Map.put("screens", sanitize_screens(Map.get(doc, "screens")))
      else
        out
      end

    if byte_size(Jason.encode!(out)) > @max_layout_bytes,
      do: Map.put(out, "screens", %{}),
      else: out
  end

  defp get_in_map(m, [k | rest]) do
    case m do
      %{^k => v} when rest == [] -> v
      %{^k => v} -> get_in_map(v, rest)
      _ -> nil
    end
  end

  defp sanitize_sidenav(sn) when is_map(sn) do
    sn
    |> Map.take(["collapsed", "w"])
    |> Enum.reduce(%{}, fn
      {"collapsed", c}, acc when is_boolean(c) -> Map.put(acc, "collapsed", c)
      {"w", w}, acc -> if n = num(w, 160, 420), do: Map.put(acc, "w", floor(n + 0.5)), else: acc
      _, acc -> acc
    end)
  end

  defp sanitize_sidenav(_), do: %{}

  defp first_keys(o, n) when is_map(o), do: o |> Map.keys() |> Enum.sort() |> Enum.take(n)
  defp first_keys(_, _), do: []

  defp sanitize_screens(screens) do
    for sid <- first_keys(screens, 40),
        Regex.match?(@screen_id, sid),
        s = screens[sid],
        is_map(s),
        r = sanitize_screen(s),
        map_size(r) > 0,
        into: %{},
        do: {sid, r}
  end

  defp sanitize_screen(s) do
    panes =
      for k <- first_keys(s["panes"], 12),
          Regex.match?(@split_id, k),
          is_list(s["panes"][k]),
          a = s["panes"][k] |> Enum.take(12) |> Enum.map(&pane/1),
          Enum.any?(a, &(&1 != nil)),
          into: %{},
          do: {k, a}

    collapsed =
      for k <- first_keys(s["collapsed"], 12),
          Regex.match?(@split_id, k),
          is_list(s["collapsed"][k]),
          a = s["collapsed"][k] |> Enum.take(12) |> Enum.flat_map(&collapsed_index/1),
          a != [],
          into: %{},
          do: {k, a}

    cols =
      for t <- first_keys(s["cols"], 24),
          Regex.match?(@split_id, t),
          c = sanitize_cols(s["cols"][t]),
          map_size(c) > 0,
          into: %{},
          do: {t, c}

    base =
      [{"panes", panes}, {"collapsed", collapsed}, {"cols", cols}]
      |> Enum.reject(fn {_, v} -> map_size(v) == 0 end)
      |> Map.new()

    # T-1448: the remembered entry mode of the lines editor, exactly "grid" or "form".
    case s["linesMode"] do
      m when m in ["grid", "form"] -> Map.put(base, "linesMode", m)
      _ -> base
    end
  end

  defp sanitize_cols(cs) do
    for cid <- first_keys(cs, 40),
        Regex.match?(@split_id, cid),
        v = num(cs[cid], 3, 80),
        into: %{},
        do: {cid, v}
  end

  defp pane(nil), do: nil
  defp pane(x), do: num(x, 5, 85)

  defp collapsed_index(x) when is_integer(x) and x >= 0 and x < 12, do: [x]
  defp collapsed_index(x) when is_float(x) and x >= 0 and x < 12 and x == trunc(x), do: [trunc(x)]
  defp collapsed_index(_), do: []

  # Clamp first, then round to 0.1 (lo/hi are multiples of 0.1, so this equals the JS order and
  # cannot overflow on huge input). Integral results are emitted as integers.
  defp num(v, lo, hi) when is_number(v) do
    x = min(hi * 1.0, max(lo * 1.0, v))
    r = floor(x * 10 + 0.5) / 10
    if r == trunc(r), do: trunc(r), else: r
  end

  defp num(_, _, _), do: nil

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
