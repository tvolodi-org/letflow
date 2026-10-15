defmodule Letflow.MailRuntimeConfigTest do
  @moduledoc """
  REQ-441 AC7 (boot configuration) and AC8 (adapter selection key), spec
  `test/specs/REQ-441.md`; design s3 and s6.2.

  Mechanism (pinned by the design, G2): `config/runtime.exs` is EVALUATED with
  `Config.Reader.read!("config/runtime.exs", env: env, target: :host)` inside this
  Mix-loaded VM, with a controlled OS environment; nothing is applied to the running
  VM, and the returned keyword list is what the assertions read. A boot-time `raise` is
  an exception from that call. For `:prod` the prod-only variables (`DATABASE_URL`) and
  every earlier mandatory variable (master key, login-directory pepper pair) are set so
  the mail block is the thing under test, and a CONTROL case first proves a complete
  valid smtp set boots in `:prod`.

  A few cases additionally run a child `mix run --no-start` (the technique of
  `login_discovery_runtime_config_test.exs`) because the M1 requirement is about what
  reaches real boot OUTPUT (stdout/stderr), and because only a child shows the config as
  the application sees it. Every child runs under `MIX_ENV=test` on the already-compiled
  test build, with `@tag timeout: 180_000` as a backstop; the former `MIX_ENV=dev` child
  (shipped Noop default) is evaluated in-process since GH #2611.

  INV-4: every raise names the variable and never a value; the credential markers are
  built at compile time, set only in the OS environment, and must appear nowhere: not in
  the evaluated config, not in a raised message, not in a formatted exception (stack
  trace included), not in child-VM output.

  `@moduletag :slow`, `async: false` (the OS environment is process-global).
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  alias Letflow.LoginDiscovery.Notifier
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.Test.SmtpHelpers, as: S

  @notifier Notifier
  @smtp Smtp

  # variables every case controls explicitly (never left to inherit)
  @mail_vars ~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST LETFLOW_SMTP_PORT LETFLOW_SMTP_USERNAME
                LETFLOW_SMTP_PASSWORD LETFLOW_SMTP_TLS LETFLOW_MAIL_FROM LETFLOW_PUBLIC_BASE_URL
                LETFLOW_MAIL_TIMEOUT_MS)
  @base_vars ~w(LETFLOW_SECRETS_MASTER_KEY LETFLOW_LOGIN_DIRECTORY_PEPPER
                LETFLOW_LOGIN_DIRECTORY_PEPPER_ID LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS
                LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID LETFLOW_LOGIN_DISCOVERY_ENABLED
                LETFLOW_LOGIN_DISCOVERY_MODE LETFLOW_TRUSTED_PROXIES DATABASE_URL LOG_LEVEL)
  @managed @mail_vars ++ @base_vars

  # values chosen to be distinctive so an echo is detectable
  @host "smtp.relay-req441.example"
  @from "noreply@mail-req441.example"
  @base_url "https://app-req441.example"

  defp hex32, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp base_env do
    [
      {"LETFLOW_SECRETS_MASTER_KEY", hex32()},
      {"LETFLOW_LOGIN_DIRECTORY_PEPPER", hex32()},
      {"LETFLOW_LOGIN_DIRECTORY_PEPPER_ID", "cur-1"},
      {"LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS", nil},
      {"LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID", nil},
      {"LETFLOW_LOGIN_DISCOVERY_ENABLED", nil},
      {"LETFLOW_LOGIN_DISCOVERY_MODE", nil},
      {"LETFLOW_TRUSTED_PROXIES", nil},
      {"DATABASE_URL", "ecto://dummy:dummy@localhost/dummy"},
      {"LOG_LEVEL", nil}
    ]
  end

  defp mail_env(overrides) do
    defaults = [
      {"LETFLOW_MAIL_ADAPTER", "smtp"},
      {"LETFLOW_SMTP_HOST", @host},
      {"LETFLOW_SMTP_PORT", "587"},
      {"LETFLOW_SMTP_USERNAME", S.user()},
      {"LETFLOW_SMTP_PASSWORD", S.pass()},
      {"LETFLOW_SMTP_TLS", nil},
      {"LETFLOW_MAIL_FROM", @from},
      {"LETFLOW_PUBLIC_BASE_URL", @base_url},
      {"LETFLOW_MAIL_TIMEOUT_MS", nil}
    ]

    Enum.map(defaults, fn {name, value} ->
      {name, Keyword.get(overrides, String.to_atom(name), value)}
    end)
  end

  # `overrides` is a keyword keyed by the variable name as an atom (`:LETFLOW_SMTP_HOST`).
  defp complete(overrides), do: mail_env(overrides)

  # Runs `fun` with exactly `vars` applied to the OS environment and every managed variable
  # not listed set to unset; restores the original environment afterwards.
  defp with_env(vars, fun) do
    originals = Map.new(@managed, &{&1, System.get_env(&1)})
    wanted = Map.new(vars)

    try do
      for name <- @managed do
        case Map.get(wanted, name) do
          nil -> System.delete_env(name)
          value -> System.put_env(name, value)
        end
      end

      fun.()
    after
      for {name, original} <- originals do
        case original do
          nil -> System.delete_env(name)
          value -> System.put_env(name, value)
        end
      end
    end
  end

  # -> {:ok, config} | {:raised, message, formatted}
  defp evaluate(env, vars, path \\ "config/runtime.exs") do
    with_env(base_env() ++ vars, fn ->
      try do
        {:ok, Config.Reader.read!(path, env: env, target: :host)}
      rescue
        exception ->
          {:raised, Exception.message(exception),
           Exception.format(:error, exception, __STACKTRACE__)}
      end
    end)
  end

  defp boots!(env, vars) do
    case evaluate(env, vars) do
      {:ok, config} -> config
      {:raised, message, _} -> flunk("expected the config to evaluate, it raised: #{message}")
    end
  end

  defp raises!(env, vars) do
    case evaluate(env, vars) do
      {:raised, message, formatted} -> {message, formatted}
      {:ok, _config} -> flunk("expected a boot-time raise, the config evaluated")
    end
  end

  defp notifier_env(config), do: get_in(config, [:letflow, @notifier])
  defp smtp_env(config), do: get_in(config, [:letflow, @smtp])

  # The raised mail message is a FIXED template: only the variable NAME varies. Asserting the
  # whole text equal to the template is the strongest "no value is echoed" statement, and it
  # is immune to a supplied value that happens to be a substring of the constant keyword
  # list (e.g. `smtp`, `none`).
  defp fixed_message(var) do
    "environment variable #{var} is missing or invalid for the selected mail adapter; the value is not echoed. " <>
      "LETFLOW_MAIL_ADAPTER accepts unset/blank, noop or smtp; " <>
      "LETFLOW_SMTP_TLS accepts unset/blank, starttls, tls or none " <>
      "(none only for a loopback host and never in :prod)."
  end

  # A raised mail message names exactly the failing variable as its subject, is the fixed
  # template, echoes no supplied value and carries no marker (formatted exception and
  # stack trace included). `supplied` are the values that must not appear.
  defp assert_refused(env, vars, var, supplied) do
    {message, formatted} = raises!(env, vars)

    assert message == fixed_message(var), "unexpected message: #{message}"

    # outside the (constant) message text the formatted exception holds only the stack trace
    trace = String.replace(formatted, message, "")

    for value <- supplied ++ [S.user(), S.pass()],
        is_binary(value) and String.trim(value) != "" do
      # short values (a port, "0") legitimately occur in line numbers of the trace; the
      # message itself is already proven to be the fixed template above
      if String.length(value) >= 6 do
        refute trace =~ value, "the formatted exception echoes #{inspect(value)}"
      end

      refute message =~ S.user()
      refute message =~ S.pass()
    end

    :ok
  end

  # ── control ─────────────────────────────────────────────────────────────

  describe "control: the environment used below is valid up to the mail block" do
    test "a COMPLETE valid smtp set evaluates in :prod, with LETFLOW_SMTP_TLS unset" do
      config = boots!(:prod, complete([]))

      assert notifier_env(config) |> Enum.sort() ==
               Enum.sort(adapter: @smtp, timeout_ms: 15_000)

      assert smtp_env(config) |> Enum.sort() ==
               Enum.sort(
                 host: @host,
                 port: 587,
                 tls: :starttls,
                 from: @from,
                 base_url: @base_url,
                 socket_timeout_ms: 3_750
               )
    end

    test "the same prod environment with the adapter UNSET evaluates (so a later raise is the mail one)" do
      assert is_list(boots!(:prod, mail_env(LETFLOW_MAIL_ADAPTER: nil)))
    end
  end

  # ── AC7: LETFLOW_MAIL_ADAPTER ───────────────────────────────────────────

  describe "AC7: LETFLOW_MAIL_ADAPTER" do
    for {label, value} <- [unset: nil, blank: "", spaces: "   ", tab: "\t"],
        env <- [:dev, :test, :prod] do
      test "#{label} (#{env}) writes NOTHING: no notifier key, no Smtp namespace" do
        config = boots!(unquote(env), mail_env(LETFLOW_MAIL_ADAPTER: unquote(value)))

        assert notifier_env(config) == nil
        assert smtp_env(config) == nil
      end
    end

    test "unset keeps the shipped default: Noop in dev (config.exs default merged with runtime.exs)" do
      assert effective_adapter(:dev, mail_env(LETFLOW_MAIL_ADAPTER: nil)) == Noop
    end

    test "unset keeps the test double in the test environment" do
      assert effective_adapter(:test, mail_env(LETFLOW_MAIL_ADAPTER: nil)) ==
               Letflow.LoginDiscoveryNotifierDouble
    end

    for env <- [:dev, :test, :prod] do
      test "noop (#{env}) selects Noop and nothing else" do
        config = boots!(unquote(env), mail_env(LETFLOW_MAIL_ADAPTER: "noop"))
        assert notifier_env(config) == [adapter: Noop]
        assert smtp_env(config) == nil
      end
    end

    test "surrounding whitespace is trimmed: ' smtp ' selects smtp" do
      config = boots!(:prod, mail_env(LETFLOW_MAIL_ADAPTER: "  smtp  "))
      assert notifier_env(config)[:adapter] == @smtp
    end

    for {label, value} <- [
          sentinel: "leaky-adapter-value-7731",
          wrong_case: "SMTP",
          mixed_case: "Noop",
          list: "smtp,noop",
          substring: "smtps",
          other_library: "swoosh"
        ],
        env <- [:dev, :test, :prod] do
      test "unknown value #{label} (#{env}) raises naming the variable without echoing the value" do
        value = unquote(value)
        {message, formatted} = raises!(unquote(env), mail_env(LETFLOW_MAIL_ADAPTER: value))

        assert message == fixed_message("LETFLOW_MAIL_ADAPTER")
        refute String.replace(formatted, message, "") =~ value
        refute message =~ S.pass()
        refute message =~ S.user()
      end
    end
  end

  # ── AC7: smtp selected, required variables ──────────────────────────────

  describe "AC7: smtp selected with a missing required variable" do
    @required ~w(LETFLOW_SMTP_HOST LETFLOW_SMTP_PORT LETFLOW_SMTP_USERNAME LETFLOW_SMTP_PASSWORD
                 LETFLOW_MAIL_FROM LETFLOW_PUBLIC_BASE_URL)

    for var <- @required,
        {label, blank} <- [unset: nil, empty: "", whitespace: "   "],
        env <- [:test, :prod] do
      test "#{var} #{label} (#{env}) raises naming exactly that variable and no value" do
        vars = mail_env([{String.to_atom(unquote(var)), unquote(blank)}])

        supplied =
          for {name, value} <- vars, name != unquote(var), do: value

        assert_refused(unquote(env), vars, unquote(var), supplied)
      end
    end

    test "failure order follows the table: with host AND port missing, the host is reported" do
      vars = mail_env(LETFLOW_SMTP_HOST: nil, LETFLOW_SMTP_PORT: nil)
      {message, _} = raises!(:prod, vars)
      assert message =~ "environment variable LETFLOW_SMTP_HOST is missing or invalid"
    end
  end

  describe "AC7: smtp selected with an invalid value" do
    @invalid [
      {"LETFLOW_SMTP_PORT", "abc"},
      {"LETFLOW_SMTP_PORT", "0"},
      {"LETFLOW_SMTP_PORT", "65536"},
      {"LETFLOW_SMTP_PORT", "587x"},
      {"LETFLOW_SMTP_PORT", "-1"},
      {"LETFLOW_SMTP_HOST", "bad host name"},
      {"LETFLOW_SMTP_HOST", "-leading-hyphen.example"},
      {"LETFLOW_SMTP_HOST", "host_with_underscore.example"},
      {"LETFLOW_MAIL_FROM", "not-an-address"},
      {"LETFLOW_MAIL_FROM", "Name <a@b.example>"},
      {"LETFLOW_MAIL_FROM", "a@b"},
      {"LETFLOW_PUBLIC_BASE_URL", "https://app-req441.example?x=1"},
      {"LETFLOW_PUBLIC_BASE_URL", "https://app-req441.example#frag"},
      {"LETFLOW_PUBLIC_BASE_URL", "https://user:pw@app-req441.example"},
      {"LETFLOW_PUBLIC_BASE_URL", "ftp://app-req441.example"},
      {"LETFLOW_PUBLIC_BASE_URL", "http://app-req441.example"},
      {"LETFLOW_PUBLIC_BASE_URL", "app-req441.example"},
      {"LETFLOW_PUBLIC_BASE_URL", "https://"},
      {"LETFLOW_SMTP_TLS", "ssl"},
      {"LETFLOW_SMTP_TLS", "STARTTLS"},
      {"LETFLOW_SMTP_TLS", "bogus-tls-value-7731"},
      {"LETFLOW_MAIL_TIMEOUT_MS", "1999"},
      {"LETFLOW_MAIL_TIMEOUT_MS", "30001"},
      {"LETFLOW_MAIL_TIMEOUT_MS", "abc"},
      {"LETFLOW_MAIL_TIMEOUT_MS", "15000ms"},
      {"LETFLOW_MAIL_TIMEOUT_MS", "-5"}
    ]

    for {var, value} <- @invalid do
      test "#{var}=#{inspect(value)} (prod) raises naming #{var}, value not echoed" do
        vars = mail_env([{String.to_atom(unquote(var)), unquote(value)}])
        assert_refused(:prod, vars, unquote(var), [unquote(value)])
      end
    end

    test "an IP-literal host with starttls or tls is refused naming the HOST (TLS needs a DNS name for SNI)" do
      for tls <- [nil, "starttls", "tls"], ip <- ["192.0.2.10", "2001:db8::1"] do
        vars = mail_env(LETFLOW_SMTP_HOST: ip, LETFLOW_SMTP_TLS: tls)
        assert_refused(:prod, vars, "LETFLOW_SMTP_HOST", [ip])
      end
    end

    test "http base URL is refused in :prod but accepted outside it" do
      vars = mail_env(LETFLOW_PUBLIC_BASE_URL: "http://localhost:4000")
      assert_refused(:prod, vars, "LETFLOW_PUBLIC_BASE_URL", ["http://localhost:4000"])

      for env <- [:dev, :test] do
        assert smtp_env(boots!(env, vars))[:base_url] == "http://localhost:4000"
      end
    end

    test "the trailing slash of the base URL is stripped (the link is built by concatenation)" do
      config = boots!(:prod, mail_env(LETFLOW_PUBLIC_BASE_URL: @base_url <> "/"))
      assert smtp_env(config)[:base_url] == @base_url
    end
  end

  # ── AC7: TLS mode ───────────────────────────────────────────────────────

  describe "AC7: plaintext (LETFLOW_SMTP_TLS=none)" do
    test "raises in :prod for ANY host, even loopback, naming the TLS variable and echoing nothing" do
      for host <- ["localhost", "127.0.0.1", @host] do
        vars = mail_env(LETFLOW_SMTP_TLS: "none", LETFLOW_SMTP_HOST: host)
        assert_refused(:prod, vars, "LETFLOW_SMTP_TLS", [host])
      end
    end

    test "boots in dev/test for a loopback host only" do
      for env <- [:dev, :test], host <- ["localhost", "127.0.0.1", "127.9.8.7", "::1"] do
        config = boots!(env, mail_env(LETFLOW_SMTP_TLS: "none", LETFLOW_SMTP_HOST: host))
        assert smtp_env(config)[:tls] == :none
        assert smtp_env(config)[:host] == host
      end
    end

    test "raises in dev/test for a non-loopback host (a staging build under another env name can never send AUTH in cleartext)" do
      for env <- [:dev, :test], host <- [@host, "10.0.0.5", "192.0.2.1"] do
        vars = mail_env(LETFLOW_SMTP_TLS: "none", LETFLOW_SMTP_HOST: host)
        assert_refused(env, vars, "LETFLOW_SMTP_TLS", [host])
      end
    end

    test "tls and starttls are accepted in :prod with a DNS-name host" do
      for {value, mode} <- [
            {"tls", :tls},
            {"starttls", :starttls},
            {nil, :starttls},
            {"  tls ", :tls}
          ] do
        config = boots!(:prod, mail_env(LETFLOW_SMTP_TLS: value))
        assert smtp_env(config)[:tls] == mode
      end
    end
  end

  # ── AC7: a complete configuration boots ─────────────────────────────────

  describe "AC7: a complete configuration boots" do
    for env <- [:dev, :test, :prod] do
      test "complete set (#{env}): the adapter, the non-secret settings and the derived socket timeout" do
        config = boots!(unquote(env), complete([]))

        assert notifier_env(config)[:adapter] == @smtp
        assert notifier_env(config)[:timeout_ms] == 15_000
        assert smtp_env(config)[:host] == @host
        assert smtp_env(config)[:port] == 587
        assert smtp_env(config)[:from] == @from
        assert smtp_env(config)[:base_url] == @base_url
        assert smtp_env(config)[:socket_timeout_ms] == 3_750
        # exactly these keys, no more
        assert smtp_env(config) |> Keyword.keys() |> Enum.sort() ==
                 [:base_url, :from, :host, :port, :socket_timeout_ms, :tls]

        assert notifier_env(config) |> Keyword.keys() |> Enum.sort() == [:adapter, :timeout_ms]
      end
    end

    for {value, expected_timeout, expected_socket} <- [
          {"2000", 2_000, 1_000},
          {"8000", 8_000, 2_000},
          {"20000", 20_000, 5_000},
          {"30000", 30_000, 7_500}
        ] do
      test "LETFLOW_MAIL_TIMEOUT_MS=#{value} sets the Dispatch timeout and a derived socket timeout" do
        config = boots!(:prod, mail_env(LETFLOW_MAIL_TIMEOUT_MS: unquote(value)))
        assert notifier_env(config)[:timeout_ms] == unquote(expected_timeout)
        assert smtp_env(config)[:socket_timeout_ms] == unquote(expected_socket)
        assert smtp_env(config)[:socket_timeout_ms] < notifier_env(config)[:timeout_ms]
      end
    end

    test "max_concurrent is untouched by the smtp selection" do
      config = boots!(:prod, complete([]))
      refute Keyword.has_key?(notifier_env(config), :max_concurrent)
    end

    test "the credentials are NOT in the evaluated config (INV-4: presence-validated, never copied)" do
      config = boots!(:prod, complete([]))
      dump = inspect(config, limit: :infinity, printable_limit: :infinity)

      refute dump =~ S.pass()
      refute dump =~ S.user()
      refute dump =~ "password"
      refute dump =~ "username"
    end
  end

  # ── AC8: the selection key ──────────────────────────────────────────────

  describe "AC8: adapter selection key" do
    test "smtp sets `config :letflow, Letflow.LoginDiscovery.Notifier, adapter:` to the Smtp module" do
      config = boots!(:prod, complete([]))

      assert [{:letflow, letflow}] = Enum.filter(config, &match?({:letflow, _}, &1))

      assert Keyword.fetch!(letflow, Letflow.LoginDiscovery.Notifier)[:adapter] ==
               Letflow.LoginDiscovery.Notifier.Smtp
    end

    test "unset leaves the Noop default in dev, asserted from the merged evaluated config" do
      assert effective_adapter(:dev, complete(LETFLOW_MAIL_ADAPTER: nil)) ==
               Letflow.LoginDiscovery.Notifier.Noop
    end

    test "smtp overrides the pre-existing adapter in the merged config (dev and test)" do
      for env <- [:dev, :test] do
        assert effective_adapter(env, complete([])) == Letflow.LoginDiscovery.Notifier.Smtp
      end
    end

    test "the value under the key is a loaded module implementing the notifier port (what REQ-444's gate reads)" do
      config = boots!(:prod, complete([]))
      adapter = notifier_env(config)[:adapter]

      assert adapter == Smtp
      assert Code.ensure_loaded?(adapter)
      assert function_exported?(adapter, :deliver_tenant_list, 2)
      assert Notifier in (adapter.module_info(:attributes)[:behaviour] || [])
    end

    # REQ-444 depends on `mail_adapter` being exactly what the block wrote. The binding is
    # not part of Config.Reader's result, so the evaluated script is extended by one
    # trailing `config` line that records it (a copy in a temp file; the repo file is
    # never modified).
    for {label, vars, expected} <- [
          {"unset", [LETFLOW_MAIL_ADAPTER: nil], nil},
          {"blank", [LETFLOW_MAIL_ADAPTER: "   "], nil},
          {"noop", [LETFLOW_MAIL_ADAPTER: "noop"], Noop},
          {"smtp", [], Smtp}
        ],
        env <- [:dev, :prod] do
      test "the runtime.exs variable `mail_adapter` is #{inspect(expected)} for #{label} (#{env})" do
        {:ok, config} = evaluate_with_probe(unquote(env), complete(unquote(vars)))

        assert get_in(config, [:probe_req441, :mail_adapter]) == unquote(expected)

        # and it equals what the block wrote under the selection key
        written = get_in(config, [:letflow, @notifier, :adapter])
        assert get_in(config, [:probe_req441, :mail_adapter]) == written
      end
    end

    test "the variable keeps its name in the shipped file (REQ-444 reads it)" do
      src = File.read!("config/runtime.exs")
      assert src =~ ~r/^mail_adapter =$/m
      assert src =~ "Letflow.LoginDiscovery.Notifier.Smtp.Config.parse(mail_env, config_env())"
    end
  end

  # ── M1: no secret reaches boot output ───────────────────────────────────

  describe "M1: a forced parse failure with a marker password" do
    test "the marker is absent from the raised message and from the formatted exception with stack trace" do
      vars = mail_env(LETFLOW_SMTP_PORT: "not-a-port", LETFLOW_SMTP_PASSWORD: S.pass())
      {message, formatted} = raises!(:prod, vars)

      assert message =~ "LETFLOW_SMTP_PORT"
      refute message =~ S.pass()
      refute formatted =~ S.pass()
      refute message =~ S.user()
      refute formatted =~ S.user()
    end

    @tag timeout: 180_000
    test "child VM: a failing boot prints the variable name and neither credential marker, on stdout or stderr" do
      {output, status} =
        child_boot(
          "test",
          complete(LETFLOW_SMTP_PORT: "not-a-port", LETFLOW_SMTP_TLS: "starttls")
        )

      refute status == 0, "expected a non-zero exit, got 0:\n#{output}"
      refute output =~ "ADAPTER Letflow"
      assert output =~ "LETFLOW_SMTP_PORT"
      refute output =~ S.pass(), "the password marker reached boot output"
      refute output =~ S.user(), "the username marker reached boot output"
      refute output =~ "not-a-port"
    end

    @tag timeout: 180_000
    test "child VM: an unknown adapter value stops boot without echoing it" do
      {output, status} = child_boot("test", mail_env(LETFLOW_MAIL_ADAPTER: "leaky-adapter-7731"))

      refute status == 0
      assert output =~ "LETFLOW_MAIL_ADAPTER"
      refute output =~ "leaky-adapter-7731"
      refute output =~ S.pass()
    end

    @tag timeout: 180_000
    test "child VM: after a complete boot the application sees the Smtp adapter and NO credential anywhere in its env" do
      {output, status} = child_boot("test", complete([]))

      assert status == 0, "expected exit 0, got #{status}:\n#{output}"
      assert output =~ "ADAPTER Letflow.LoginDiscovery.Notifier.Smtp"
      assert output =~ "TIMEOUT 15000"
      refute output =~ S.pass()
      refute output =~ S.user()
    end

    # In-process since GH #2611 (it was a MIX_ENV=dev child that paid a cold _build/dev
    # compile and timed out on PR #2612): what the old child's probe printed is the adapter
    # in config.exs (+ dev.exs) merged with runtime.exs, which is what effective_adapter/2
    # computes from the same files. The test-environment child cases above stay the real
    # boot-output checks.
    test "dev (in-process, formerly a child VM): nothing set boots and the shipped default adapter is Noop" do
      vars = mail_env(LETFLOW_MAIL_ADAPTER: nil)

      assert is_list(boots!(:dev, vars))
      assert effective_adapter(:dev, vars) == Letflow.LoginDiscovery.Notifier.Noop
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # The adapter the application would end up with: config.exs (+ its env file) merged with
  # the runtime.exs result, runtime winning, exactly as Mix applies them.
  defp effective_adapter(env, vars) do
    saved = System.get_env("MIX_TEST_PARTITION")
    System.delete_env("MIX_TEST_PARTITION")

    try do
      base = Config.Reader.read!("config/config.exs", env: env, target: :host)
      merged = Config.Reader.merge(base, boots!(env, vars))
      get_in(merged, [:letflow, @notifier, :adapter])
    after
      if saved, do: System.put_env("MIX_TEST_PARTITION", saved)
    end
  end

  defp evaluate_with_probe(env, vars) do
    source =
      File.read!("config/runtime.exs") <> "\nconfig :probe_req441, mail_adapter: mail_adapter\n"

    path =
      Path.join(
        System.tmp_dir!(),
        "req441_runtime_probe_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, source)

    try do
      case evaluate(env, vars, path) do
        {:ok, config} -> {:ok, config}
        {:raised, message, _} -> flunk("probe evaluation raised: #{message}")
      end
    after
      File.rm(path)
    end
  end

  @probe ~S|IO.puts("ADAPTER " <> inspect(Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)[:adapter])); IO.puts("TIMEOUT " <> inspect(Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)[:timeout_ms])); IO.puts("ENV " <> inspect(Application.get_all_env(:letflow), limit: :infinity, printable_limit: :infinity))|

  # Child `mix run --no-start` under MIX_ENV=test: config is evaluated, no application and
  # no database started. `System.cmd`'s env MERGES onto this VM's, so every variable under
  # test is explicitly set or nil-ed. MIX_TEST_PARTITION and MIX_BUILD_PATH are INHERITED
  # (GH #2611, as in secrets_runtime_config_test.exs): under scripts/test_parallel.sh
  # MIX_BUILD_PATH is this partition's warm build, so the child only loads .beam files.
  # Only config/dev.exs refuses MIX_TEST_PARTITION, and no child runs under dev any more.
  defp child_boot("test" = mix_env, vars) do
    env =
      [{"MIX_ENV", mix_env}] ++
        Enum.map(@managed, &{&1, nil}) ++
        base_env() ++ vars

    # later entries win: dedupe keeping the last value per name
    env = env |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()

    System.cmd("mix", ["run", "--no-start", "-e", @probe],
      env: env,
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end
end
