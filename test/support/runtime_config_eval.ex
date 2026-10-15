defmodule Letflow.Test.RuntimeConfigEval do
  @moduledoc """
  Evaluates the real `config/runtime.exs` in-process (GH #2609 / #2611), so a runtime-config
  test does not spawn a `MIX_ENV=dev` `mix run` per case and never pays a cold
  `_build/dev` compile inside ExUnit's per-test timeout.

  The mechanism is the one `secrets_runtime_config_test.exs`,
  `login_directory_runtime_config_test.exs` and `mail_runtime_config_test.exs` use inline:
  `Config.Reader.read!("config/runtime.exs", env: env, target: :host)` inside the running
  test VM. That evaluates the very file a booting node evaluates, with the given
  `config_env()`, including its `raise`s: a boot-time refusal is an exception from the
  call, a successful boot is the returned config keyword list. Nothing in
  `config/runtime.exs` is copied or re-implemented.

  ## Environment

  `runtime.exs` reads the OS environment, which is global to the VM, so a module using this
  helper must be `async: false` and call `isolate_env/0` from its `setup`: it snapshots every
  variable in `runtime_vars/0` and restores each one in `on_exit`.

  `evaluate/2` applies explicit inputs: every variable in `runtime_vars/0` that the caller
  does not pass is DELETED for the evaluation, never inherited from the host or from
  `config/test.exs`'s `System.put_env/2` fallbacks. A caller that targets a check late in
  the file passes a valid master key and pepper pair (`valid_base/0`) so an earlier
  refusal cannot mask the case under test.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  # Every variable config/runtime.exs reads (System.get_env/1,2), in file order. Keep in
  # sync with config/runtime.exs; a variable missing here would be inherited by a case.
  @runtime_vars ~w(LETFLOW_SECRETS_MASTER_KEY
                   LETFLOW_LOGIN_DIRECTORY_PEPPER LETFLOW_LOGIN_DIRECTORY_PEPPER_ID
                   LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID
                   LOG_LEVEL LETFLOW_TRUSTED_PROXIES LETFLOW_LOGIN_DISCOVERY_ENABLED
                   LETFLOW_LOGIN_DISCOVERY_MODE LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS
                   LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST LETFLOW_SMTP_PORT LETFLOW_SMTP_TLS
                   LETFLOW_MAIL_FROM LETFLOW_PUBLIC_BASE_URL LETFLOW_MAIL_TIMEOUT_MS
                   LETFLOW_SMTP_USERNAME LETFLOW_SMTP_PASSWORD LETFLOW_PLATFORM_TENANT_ID
                   LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION LETFLOW_BUILD_SHA
                   DATABASE_URL POOL_SIZE RESERVED_HEADROOM PORT CORS_ALLOWED_ORIGINS
                   OIDC_KEYCLOAK_BASE_URL OIDC_ISSUER OIDC_CLIENT_ID)

  @doc "Every OS environment variable `config/runtime.exs` reads."
  @spec runtime_vars() :: [String.t()]
  def runtime_vars, do: @runtime_vars

  @doc """
  Snapshots every variable in `runtime_vars/0` (plus `MIX_TEST_PARTITION`, which
  `merged/2` touches) and restores each in `on_exit`. Call from `setup`.
  """
  @spec isolate_env() :: :ok
  def isolate_env do
    names = ["MIX_TEST_PARTITION" | @runtime_vars]
    originals = Map.new(names, &{&1, System.get_env(&1)})
    on_exit(fn -> apply_env(originals) end)
    :ok
  end

  @doc "A fresh, valid master key and a distinct valid current pepper pair."
  @spec valid_base() :: %{String.t() => String.t()}
  def valid_base do
    %{
      "LETFLOW_SECRETS_MASTER_KEY" => hex32(),
      "LETFLOW_LOGIN_DIRECTORY_PEPPER" => hex32(),
      "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID" => "cur-1"
    }
  end

  @doc "64 lowercase hex characters from 32 random bytes."
  @spec hex32() :: String.t()
  def hex32, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  @doc """
  Sets exactly `vars` (name => value | nil) over a fully deleted `runtime_vars/0` and
  evaluates `config/runtime.exs` under `config_env() == env`, capturing standard error.

  Returns `{{:ok, config} | {:raised, message, formatted}, stderr}`; `formatted` is the
  formatted exception including its stack trace.
  """
  @spec evaluate(%{String.t() => String.t() | nil}, atom()) ::
          {{:ok, keyword()} | {:raised, String.t(), String.t()}, String.t()}
  def evaluate(vars, env \\ :dev) do
    @runtime_vars
    |> Map.new(&{&1, nil})
    |> Map.merge(vars)
    |> apply_env()

    ExUnit.CaptureIO.with_io(:stderr, fn ->
      try do
        {:ok, Config.Reader.read!("config/runtime.exs", env: env, target: :host)}
      rescue
        exception ->
          {:raised, Exception.message(exception),
           Exception.format(:error, exception, __STACKTRACE__)}
      end
    end)
  end

  @doc """
  The config the application would see: `config/config.exs` (with its `env` file) merged
  with the `runtime.exs` result, runtime winning, as Mix applies them. `MIX_TEST_PARTITION`
  is removed while reading, because `config/dev.exs` refuses it (ISS-0015).
  """
  @spec merged(keyword(), atom()) :: keyword()
  def merged(runtime_config, env \\ :dev) do
    saved = System.get_env("MIX_TEST_PARTITION")
    System.delete_env("MIX_TEST_PARTITION")

    try do
      "config/config.exs"
      |> Config.Reader.read!(env: env, target: :host)
      |> Config.Reader.merge(runtime_config)
    after
      if saved, do: System.put_env("MIX_TEST_PARTITION", saved)
    end
  end

  defp apply_env(vars) do
    for {name, value} <- vars do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end

    :ok
  end
end
