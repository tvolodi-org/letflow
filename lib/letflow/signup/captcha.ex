defmodule Letflow.Signup.Captcha do
  @moduledoc """
  T-1620 (TA-SL3): the captcha verification hook of the public sign-up. **No vendor is implemented**
  (owner question Q3 is open): the setting `captcha_adapter` is `nil` (off) everywhere, and
  `LETFLOW_SIGNUP_CAPTCHA` accepts only unset/`off`. An adapter is a module implementing this behaviour; tests
  inject a fake through the application env.

  `verify/3` fails closed (INV-8): an adapter that answers `:unavailable`, raises or exits makes the sign-up
  answer `503`, never "accepted". The token is passed through and never logged or stored (INV-4).
  """

  @max_token 4_096

  @callback verify(token :: String.t() | nil, :inet.ip_address()) ::
              :ok | {:error, :failed | :unavailable}

  @doc "True when an adapter is configured (the SPA must then show the widget)."
  @spec required?(map()) :: boolean()
  def required?(cfg),
    do: is_atom(Map.get(cfg, :captcha_adapter)) and Map.get(cfg, :captcha_adapter) != nil

  @doc "`:ok` (also when off), `{:error, :captcha_failed}` or `{:error, :unavailable}`."
  @spec check(map(), map(), :inet.ip_address()) :: :ok | {:error, :captcha_failed | :unavailable}
  def check(cfg, params, client_ip) do
    case Map.get(cfg, :captcha_adapter) do
      nil -> :ok
      adapter -> call(adapter, token(params), client_ip)
    end
  end

  defp token(params) do
    case Map.get(params, "captcha_token") do
      t when is_binary(t) and byte_size(t) in 1..@max_token -> t
      _other -> nil
    end
  end

  defp call(adapter, token, ip) do
    case adapter.verify(token, ip) do
      :ok -> :ok
      {:error, :failed} -> {:error, :captcha_failed}
      _unavailable_or_unknown -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end
