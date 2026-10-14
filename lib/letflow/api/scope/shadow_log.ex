defmodule Letflow.Api.Scope.ShadowLog do
  @moduledoc """
  One sampled log line per shadow-mode would-deny (REQ-497 PR 1b, 0051 Rollout 3; design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 4.3).

  ## Line shape

      scope_shadow_would_deny method=GET route=/api/v1/... policy=UsersManage permission=UsersGroupsRolesManage reason=no_grant_rows credential=oidc caller=<16hex> tenant=<16hex>

  plus `" suppressed=<n>"` when `n > 0` lines were withheld by sampling for the same slot.

  ## INV-4

  Built ONLY from `Letflow.Api.AuthzDenyLog`'s public sanitisers (`method_token/1`,
  `route_pattern/1`, `policy_token/1`, `hash_id/3`, `subkey/0`), a permission atom name, the
  reason atom and the credential atom. Never the raw path, params, body, headers, token,
  e-mail, raw ids, role names, node ids or record contents.

  ## Sampling

  At most one line per `{policy, caller hash, tenant hash}` slot per window
  (`:scope_shadow_log_window_s`, default 60 seconds, `0` disables sampling), with its own
  pair of 4096-slot `:atomics` arrays under the persistent_term key
  `{Letflow.Api.Scope.ShadowLog, :sampler}`: the same mechanics as `AuthzDenyLog`.
  Fail-open: a broken sampler emits.
  """

  require Logger

  alias Letflow.Api.AuthzDenyLog

  @slots 4096
  @default_window 60
  @sampler_key {__MODULE__, :sampler}
  @credentials [:oidc, :api_token]

  @doc """
  Emits (subject to sampling) one line for a would-deny. Returns `:ok`. The caller
  (`Letflow.Api.Scope.Shadow.observe/3`) catches any failure.
  """
  @spec log_would_deny(
          Plug.Conn.t(),
          policy_key :: atom(),
          permission :: atom(),
          reason :: atom()
        ) :: :ok
  def log_would_deny(conn, policy_key, permission, reason) do
    ctx = Map.get(conn.assigns, :auth_context) || %{}
    sub = AuthzDenyLog.subkey()
    caller = AuthzDenyLog.hash_id(:user, Map.get(ctx, :user_id), sub)
    tenant = AuthzDenyLog.hash_id(:tenant, Map.get(ctx, :tenant_id), sub)

    case sample(policy_key, caller, tenant) do
      :suppress ->
        :ok

      {:emit, n} ->
        base =
          "scope_shadow_would_deny method=#{AuthzDenyLog.method_token(conn.method)}" <>
            " route=#{AuthzDenyLog.route_pattern(conn)}" <>
            " policy=#{AuthzDenyLog.policy_token(policy_key)}" <>
            " permission=#{AuthzDenyLog.policy_token(permission)}" <>
            " reason=#{AuthzDenyLog.policy_token(reason)}" <>
            " credential=#{credential_token(Map.get(ctx, :credential))}" <>
            " caller=#{caller} tenant=#{tenant}"

        Logger.warning(if n > 0, do: base <> " suppressed=#{n}", else: base)
    end
  end

  defp credential_token(credential) when credential in @credentials,
    do: Atom.to_string(credential)

  defp credential_token(_other), do: "none"

  # --- sampling (AuthzDenyLog's mechanics, own state) ------------------------

  defp sample(policy_key, caller, tenant) do
    do_sample(policy_key, caller, tenant)
  rescue
    _ -> {:emit, 0}
  catch
    _kind, _reason -> {:emit, 0}
  end

  defp do_sample(policy_key, caller, tenant) do
    case window() do
      0 ->
        {:emit, 0}

      window ->
        {last_ref, supp_ref} = sampler()
        slot = :erlang.phash2({policy_key, caller, tenant}, @slots) + 1
        now = System.system_time(:second)
        last = :atomics.get(last_ref, slot)

        if last == 0 or now < last or now - last >= window do
          case :atomics.compare_exchange(last_ref, slot, last, now) do
            :ok -> {:emit, :atomics.exchange(supp_ref, slot, 0)}
            _lost -> suppress(supp_ref, slot)
          end
        else
          suppress(supp_ref, slot)
        end
    end
  end

  defp suppress(supp_ref, slot) do
    :atomics.add(supp_ref, slot, 1)
    :suppress
  end

  defp window do
    case Application.get_env(:letflow, :scope_shadow_log_window_s, @default_window) do
      w when is_integer(w) and w >= 0 -> w
      _invalid -> @default_window
    end
  end

  defp sampler do
    case :persistent_term.get(@sampler_key, nil) do
      nil ->
        pair = {:atomics.new(@slots, signed: true), :atomics.new(@slots, signed: true)}
        :persistent_term.put(@sampler_key, pair)
        pair

      pair ->
        pair
    end
  end

  @doc false
  # TEST ONLY: zero the sampler.
  @spec reset() :: :ok
  def reset do
    case :persistent_term.get(@sampler_key, nil) do
      {last, supp} ->
        Enum.each(1..@slots, fn i ->
          :atomics.put(last, i, 0)
          :atomics.put(supp, i, 0)
        end)

      _ ->
        :ok
    end

    :ok
  end
end
