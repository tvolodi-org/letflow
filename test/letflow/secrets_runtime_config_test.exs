defmodule Letflow.SecretsRuntimeConfigTest do
  @moduledoc """
  Tests for REQ-190 AC6 -- `LETFLOW_SECRETS_MASTER_KEY` missing, malformed or
  trivially-guessable fails application boot, per
  `docs/migration/decisions/0016-secrets-storage-backend.md` §B and
  `lib/letflow/design/req190-secrets-core.md` §2 (ISS-0987 for the weak-key cases).
  Implementation: `config/runtime.exs`.

  ## How: the real `config/runtime.exs`, evaluated in-process (GH #2609)

  Every check except one is exercised with
  `Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)` inside this
  already-running test VM -- the same mechanism `mail_runtime_config_test.exs` uses.
  That evaluates the very file a booting node evaluates, with the same `config_env()`
  (`:dev`), including its `raise`s: a boot-time refusal surfaces here as an exception
  from the call, a successful boot as the returned config keyword list. Nothing is
  extracted, refactored or re-implemented, so this still tests the design as written
  in `config/runtime.exs`, not a copy of it. The modules `runtime.exs` calls
  (`Letflow.Plugs.ClientIp`, `Letflow.LoginDirectory`, `Letflow.Identity.Tenant`, the
  mail config parser, ...) are plain functions already compiled into this VM; no
  booted dev node, application or database is needed.

  `env: :dev` rather than `:test` keeps the semantics of the old `MIX_ENV=dev`
  subprocess: `config/test.exs` injects fallback values when the variables are
  absent, but `Config.Reader` reads only `runtime.exs` here, so no fallback applies
  and the truly-absent case is observable.

  The previous version of this file spawned a `MIX_ENV=dev` `mix run` per case. In CI
  the dev build is not compiled, so the child paid a full cold dev compile inside
  ExUnit's 60 s per-test timeout and timed out under load whenever a PR touched config
  (the all-zeros case on PR #2571, then the all-0xFF case on PR #2607; GH #2609).

  ## Environment handling -- why `async: false`

  `runtime.exs` reads the OS environment (`System.get_env/1`), which is global to the
  whole VM, not to the test process. Each test sets exactly the variables in
  `@managed` (explicitly set or explicitly deleted, never inherited), and an `on_exit`
  restores every one of them to its value from before the test. Because the OS
  environment is shared, no other test may run concurrently with this module, hence
  `async: false`. Optional variables (`LOG_LEVEL`, `LETFLOW_TRUSTED_PROXIES`, mail,
  platform tenant, ...) are deleted so an ambient value on a CI host cannot make
  evaluation raise for an unrelated reason. Every case that targets the master key also
  sets a valid, distinct login-directory pepper pair so that the later REQ-435 pepper
  checks cannot mask the result (ISS-0987: without it an all-0xFF key raised on
  "pepper is missing" and the test passed before the fix for the wrong reason). The
  master-key checks run before the pepper checks, so a refusal here is always the
  master-key one, which the assertions confirm by message.

  `runtime.exs` prints a platform-tenant warning to stderr outside `:test`; it is
  captured (and also checked for an echoed key value).

  INV-4: every refusal must name the variable and never echo the key value -- checked
  on the exception message and on the fully formatted exception (stack trace included).

  ## The one real boot-path smoke test

  `Config.Reader` proves what `runtime.exs` does; it does not prove the file is actually
  wired into boot. One test therefore still spawns a real `mix run` and asserts it
  exits non-zero with the "trivially-guessable" refusal for an all-0xFF key. It runs
  under `MIX_ENV=test` -- the build the running suite has already compiled -- so the
  child only loads `.beam` files and never pays a cold compile. `MIX_TEST_PARTITION`
  and `MIX_BUILD_PATH` are deliberately INHERITED, not nil'd: under
  `scripts/test_parallel.sh` `MIX_BUILD_PATH` points at this partition's warm
  `_build/test-partition-N`, and nil'ing it would send the child to a possibly cold
  `_build/test`. (The old `MIX_ENV=dev` children had to nil both only because
  `config/dev.exs`'s ISS-0015 guard refuses `MIX_TEST_PARTITION` under dev; that guard
  does not apply to `MIX_ENV=test`.) `config/test.exs` injects a master key only when
  none is set, so the explicit all-0xFF value reaches `runtime.exs` unchanged. The
  explicit `@tag timeout: 180_000` is a backstop only.

  Pitfall kept from the subprocess era: an empty string passed through
  `System.cmd/3`'s `env:` arrives in the child indistinguishable from an absent
  variable on this host, so subprocess cases must use non-empty values. (In-process,
  `System.put_env/2` keeps `""` distinct, but no case here relies on that.)
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 2]

  @master "LETFLOW_SECRETS_MASTER_KEY"

  # Every variable a case controls: set or deleted per case, restored on exit.
  @managed ~w(LETFLOW_SECRETS_MASTER_KEY LETFLOW_LOGIN_DIRECTORY_PEPPER
              LETFLOW_LOGIN_DIRECTORY_PEPPER_ID LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS
              LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION
              LOG_LEVEL LETFLOW_TRUSTED_PROXIES LETFLOW_LOGIN_DISCOVERY_ENABLED
              LETFLOW_LOGIN_DISCOVERY_MODE LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS
              LETFLOW_MAIL_ADAPTER LETFLOW_PLATFORM_TENANT_ID LETFLOW_BUILD_SHA)

  @marker "booted_past_config"
  @pepper String.duplicate("ab", 32)

  setup do
    originals = Map.new(@managed, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, original} <- originals do
        if original, do: System.put_env(name, original), else: System.delete_env(name)
      end
    end)

    :ok
  end

  # Applies `vars` (name -> value | nil) over a baseline of a valid distinct pepper pair
  # with every other managed variable deleted, then evaluates the real
  # config/runtime.exs under config_env() == :dev.
  # -> {{:ok, config} | {:raised, message, formatted}, captured_stderr}
  defp evaluate(vars) do
    baseline =
      Map.merge(Map.new(@managed, &{&1, nil}), %{
        "LETFLOW_LOGIN_DIRECTORY_PEPPER" => @pepper,
        "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID" => "p1"
      })

    for {name, value} <- Map.merge(baseline, vars) do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end

    with_io(:stderr, fn ->
      try do
        {:ok, Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)}
      rescue
        exception ->
          {:raised, Exception.message(exception),
           Exception.format(:error, exception, __STACKTRACE__)}
      end
    end)
  end

  defp assert_refused(key_hex, fragment) do
    {result, stderr} = evaluate(%{@master => key_hex})

    assert {:raised, message, formatted} = result,
           "expected config/runtime.exs to raise, it returned: #{inspect(result)}"

    assert message =~ @master
    assert message =~ fragment

    if key_hex do
      # INV-4: the refusal names the variable, never echoes the key value.
      refute message =~ key_hex
      refute formatted =~ key_hex
      refute stderr =~ key_hex
    end

    message
  end

  test "LETFLOW_SECRETS_MASTER_KEY unset fails boot with a clear 'is missing' error" do
    assert_refused(nil, "is missing")
  end

  test "LETFLOW_SECRETS_MASTER_KEY set to a malformed value fails boot with a clear 'is malformed' error" do
    assert_refused("not-64-hex-characters-at-all", "is malformed")
  end

  test "ISS-0987: all-zeros LETFLOW_SECRETS_MASTER_KEY is refused as trivially-guessable" do
    assert_refused(String.duplicate("0", 64), "trivially-guessable")
  end

  test "ISS-0987: all-0xFF LETFLOW_SECRETS_MASTER_KEY is refused as trivially-guessable" do
    assert_refused(String.duplicate("f", 64), "trivially-guessable")
  end

  test "ISS-0987: a valid non-trivial LETFLOW_SECRETS_MASTER_KEY boots past config" do
    key = "0123456789abcdef" |> String.duplicate(4) |> String.reverse()
    refute key == @pepper

    {result, stderr} = evaluate(%{@master => key})

    assert {:ok, config} = result,
           "expected config/runtime.exs to evaluate, got: #{inspect(result)}"

    assert Keyword.keyword?(config)
    assert config[:letflow][:secrets_master_key] == Base.decode16!(key, case: :lower)
    refute stderr =~ "trivially-guessable"
    refute stderr =~ key
  end

  # The single real boot-path check (see moduledoc): runtime.exs is wired into boot.
  @tag :slow
  @tag timeout: 180_000
  test "boot path: mix run exits non-zero with the 'trivially-guessable' refusal for an all-0xFF key" do
    key_hex = String.duplicate("f", 64)

    env = [
      {@master, key_hex},
      {"LETFLOW_LOGIN_DIRECTORY_PEPPER", @pepper},
      {"LETFLOW_LOGIN_DIRECTORY_PEPPER_ID", "p1"},
      {"MIX_ENV", "test"}
    ]

    {output, exit_status} =
      System.cmd("mix", ["run", "--no-start", "-e", "IO.puts(:#{@marker})"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    refute exit_status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    assert output =~ "trivially-guessable"
    assert output =~ @master
    refute output =~ @marker
    # INV-4, on the real boot output.
    refute output =~ key_hex
  end
end
