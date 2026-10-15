defmodule Letflow.LoginDirectoryRuntimeConfigTest do
  @moduledoc """
  REQ-435 / 0043 D-C -- the boot-check matrix of `config/runtime.exs` for the four
  login-directory variables (`LETFLOW_LOGIN_DIRECTORY_PEPPER`, `_PEPPER_ID`,
  `_PEPPER_PREVIOUS`, `_PEPPER_PREVIOUS_ID`); design
  `lib/letflow/design/req434-email-first-login-directory.md` §2.2 and §15.1
  item 5. See `test/specs/REQ-435.md`.

  Same technique and for the same reason as `secrets_runtime_config_test.exs`
  (GH #2609): the real `config/runtime.exs` is evaluated in-process with
  `Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)`, so a
  boot-time `raise` is an exception from that call and a successful boot is the
  returned config keyword list. `env: :dev` because `config/test.exs` injects
  fallback values for the pepper and the key id when they are unset; it is not read
  here, so every "absent" case stays observable. This replaces one `MIX_ENV=dev`
  `mix run` child per case, which paid a cold dev compile inside ExUnit's per-test
  timeout in CI. The real boot-path wiring of `runtime.exs` is proved by the single
  subprocess smoke test in `secrets_runtime_config_test.exs`.

  The OS environment is process-global, hence `async: false`: every variable in
  `@managed` is explicitly set or deleted in every case (never inherited), and an
  `on_exit` restores each to its value from before the test. Optional variables
  (`LOG_LEVEL`, `LETFLOW_TRUSTED_PROXIES`, mail, platform tenant, ...) are deleted so an
  ambient host value cannot make evaluation raise for an unrelated reason.

  Every non-fixed pepper is generated at run time; no secret-shaped literal is
  written in this file (the no-secret guard scans `test/` too). Each failing case
  asserts a raise, a message naming the offending variable, and that NO value that was
  supplied appears in the message, the formatted exception (stack trace included) or
  captured stderr (INV-4).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 2]

  @pepper "LETFLOW_LOGIN_DIRECTORY_PEPPER"
  @pepper_id "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID"
  @previous "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS"
  @previous_id "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID"
  @master "LETFLOW_SECRETS_MASTER_KEY"

  # Every variable a case controls: set or deleted per case, restored on exit.
  @managed [@master, @pepper, @pepper_id, @previous, @previous_id] ++
             ~w(LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION LOG_LEVEL LETFLOW_TRUSTED_PROXIES
                LETFLOW_LOGIN_DISCOVERY_ENABLED LETFLOW_LOGIN_DISCOVERY_MODE
                LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS LETFLOW_MAIL_ADAPTER
                LETFLOW_PLATFORM_TENANT_ID LETFLOW_BUILD_SHA)

  setup do
    originals = Map.new(@managed, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, original} <- originals do
        if original, do: System.put_env(name, original), else: System.delete_env(name)
      end
    end)

    :ok
  end

  defp hex32, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  # Evaluates the real config/runtime.exs under config_env() == :dev with a fully
  # controlled environment. `overrides` is a map of variable name -> value | nil,
  # applied over a valid baseline (fresh master key, fresh current pepper, id "cur-1",
  # no previous pair, every optional managed variable deleted).
  defp boot(overrides) do
    baseline =
      Map.merge(Map.new(@managed, &{&1, nil}), %{
        @master => hex32(),
        @pepper => hex32(),
        @pepper_id => "cur-1"
      })

    for {name, value} <- Map.merge(baseline, overrides) do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end

    {result, stderr} =
      with_io(:stderr, fn ->
        try do
          {:ok, Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)}
        rescue
          exception ->
            {:raised, Exception.message(exception),
             Exception.format(:error, exception, __STACKTRACE__)}
        end
      end)

    supplied = for {_name, value} <- overrides, is_binary(value), do: value
    %{result: result, stderr: stderr, supplied: supplied}
  end

  defp assert_boot_fails(overrides, variable, fragment) do
    %{result: result, stderr: stderr, supplied: supplied} = boot(overrides)

    assert {:raised, message, formatted} = result,
           "expected config/runtime.exs to raise, it returned: #{inspect(result)}"

    assert message =~ variable, "message must name #{variable}:
#{message}"
    assert message =~ fragment, "message must contain #{inspect(fragment)}:
#{message}"

    for value <- supplied, String.trim(value) != "", text <- [message, formatted, stderr] do
      refute text =~ String.trim(value), "output must not echo a supplied value"
    end

    :ok
  end

  defp keys!(overrides) do
    %{result: result} = boot(overrides)

    assert {:ok, config} = result,
           "expected config/runtime.exs to evaluate, got: #{inspect(result)}"

    Keyword.fetch!(config[:letflow], :login_directory_keys)
  end

  describe "required current pair" do
    test "absent pepper fails with 'is missing'" do
      assert_boot_fails(%{@pepper => nil}, @pepper, "is missing")
    end

    test "absent key id fails with 'is missing'" do
      assert_boot_fails(%{@pepper_id => nil}, @pepper_id, "is missing")
    end
  end

  describe "key id format [a-z0-9_-]{1,32}" do
    for {label, bad} <- [
          {"uppercase", "LEAKYIDUPPER"},
          {"33 characters", String.duplicate("a", 33)},
          {"a space", "has space-leakyid"},
          {"a dot", "dot.leakyid"},
          {"a trailing newline", "leakyid-nl\n"}
        ] do
      test "malformed key id (#{label}) fails with 'is malformed'" do
        assert_boot_fails(%{@pepper_id => unquote(bad)}, @pepper_id, "is malformed")
      end
    end
  end

  describe "pepper value checks" do
    test "not 64 hex characters (non-hex text) fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => "not-hex-leaky-pepper-value"}, @pepper, "is malformed")
    end

    test "63 hex characters fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => binary_part(hex32(), 0, 63)}, @pepper, "is malformed")
    end

    test "65 hex characters fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => hex32() <> "a"}, @pepper, "is malformed")
    end

    test "uppercase hex fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => String.upcase(hex32())}, @pepper, "is malformed")
    end

    test "all-zero fails as trivially guessable" do
      assert_boot_fails(%{@pepper => String.duplicate("0", 64)}, @pepper, "trivially-guessable")
    end

    test "all-0xFF fails as trivially guessable" do
      assert_boot_fails(%{@pepper => String.duplicate("f", 64)}, @pepper, "trivially-guessable")
    end

    test "equal to the secrets master key fails as 'a distinct secret'" do
      shared = hex32()

      assert_boot_fails(
        %{@pepper => shared, @master => shared},
        @pepper,
        "distinct secret"
      )
    end
  end

  describe "previous pair (rotation)" do
    test "previous pepper without its id fails: both or neither" do
      assert_boot_fails(%{@previous => hex32()}, @previous, "set together")
    end

    test "previous id without its pepper fails: both or neither" do
      assert_boot_fails(%{@previous_id => "prev-1"}, @previous_id, "set together")
    end

    test "previous pepper equal to the current pepper fails" do
      same = hex32()

      assert_boot_fails(
        %{@pepper => same, @previous => same, @previous_id => "prev-1"},
        @previous,
        "must differ"
      )
    end

    test "previous id equal to the current id fails" do
      assert_boot_fails(
        %{@previous => hex32(), @previous_id => "cur-1"},
        @previous_id,
        "must differ"
      )
    end

    test "previous pepper failing the hex check fails" do
      assert_boot_fails(
        %{@previous => "leaky-previous-not-hex", @previous_id => "prev-1"},
        @previous,
        "is malformed"
      )
    end

    test "previous pepper all-zero fails as trivially guessable" do
      assert_boot_fails(
        %{@previous => String.duplicate("0", 64), @previous_id => "prev-1"},
        @previous,
        "trivially-guessable"
      )
    end

    test "previous pepper equal to the master key fails" do
      shared = hex32()

      assert_boot_fails(
        %{@previous => shared, @previous_id => "prev-1", @master => shared},
        @previous,
        "distinct secret"
      )
    end

    test "malformed previous id fails" do
      assert_boot_fails(
        %{@previous => hex32(), @previous_id => "PREV-LEAKY"},
        @previous_id,
        "is malformed"
      )
    end
  end

  describe "valid configurations boot" do
    test "current only: boots with previous: nil" do
      keys = keys!(%{})

      assert keys[:current].id == "cur-1"
      assert keys[:previous] == nil
    end

    test "current plus previous: boots and both ids are in the config" do
      keys = keys!(%{@previous => hex32(), @previous_id => "prev-1"})

      assert keys[:current].id == "cur-1"
      assert keys[:previous].id == "prev-1"
    end

    test "a whitespace-only previous pair counts as unset (D19)" do
      keys = keys!(%{@previous => "   ", @previous_id => "  "})

      assert keys[:previous] == nil
    end
  end
end
