defmodule Letflow.LoginDiscoveryTest do
  @moduledoc """
  REQ-437 (spec `test/specs/REQ-437.md`): the PURE pieces -- `decide/2` and
  `delivery/2` table tests (every cell names the deployment mode and the tenant
  setting, i.e. the `disclose` flag the lookup folded in), the single mode
  vocabulary (`LoginDirectory.deployment_mode/0`, `parse_deployment_mode/1`,
  `LoginDiscovery.mode/0` delegating), the config surface evaluated from
  `config/config.exs` (shipped defaults, notifier adapter key, `:prod` mount
  default) and the source guards of design s15.3 (no closure-less MFA task start,
  no `lookup_by_email` call in the router, no Repo outside the lookup, and -- since
  REQ-441 -- `mix.exs` adding only `:gen_smtp`).

  `async: false`: tests that swap application env restore it in `on_exit/1`.
  """

  use ExUnit.Case, async: false

  alias Letflow.LoginDirectory
  alias Letflow.LoginDiscovery
  alias Letflow.LoginDiscovery.Dispatch
  alias Letflow.Test.LoginDiscoveryHelpers, as: H

  @notifier Letflow.LoginDiscovery.Notifier

  # What the lookup returns: plain maps with the internal `disclose` flag.
  defp match(slug, disclose), do: %{slug: slug, display_name: "Name #{slug}", disclose: disclose}
  defp ref(slug), do: %{slug: slug, display_name: "Name #{slug}"}

  # ── decide/2 ────────────────────────────────────────────────────────────

  describe "decide/2: deployment :redirect_single" do
    test "one active match, tenant setting redirect_single (disclose true) -> {:match, ref} with `disclose` stripped" do
      assert LoginDiscovery.decide(:redirect_single, {:ok, [match("a", true)]}) ==
               {:match, ref("a")}
    end

    test "one active match, tenant setting uniform (disclose false) -> :neutral" do
      assert LoginDiscovery.decide(:redirect_single, {:ok, [match("a", false)]}) == :neutral
    end

    test "two matches, both disclose true -> :neutral (several matches are never disclosed)" do
      assert LoginDiscovery.decide(:redirect_single, {:ok, [match("a", true), match("b", true)]}) ==
               :neutral
    end

    test "two matches, one redirect_single tenant and one uniform tenant -> :neutral" do
      assert LoginDiscovery.decide(:redirect_single, {:ok, [match("a", true), match("b", false)]}) ==
               :neutral

      assert LoginDiscovery.decide(:redirect_single, {:ok, [match("a", false), match("b", true)]}) ==
               :neutral
    end

    test "no match -> :neutral" do
      assert LoginDiscovery.decide(:redirect_single, {:ok, []}) == :neutral
    end

    test "lookup failure -> :neutral" do
      assert LoginDiscovery.decide(:redirect_single, {:error, :lookup_failed}) == :neutral
    end
  end

  describe "decide/2: deployment :uniform_plus_email (the ceiling forces :neutral whatever the tenant setting)" do
    for disclose <- [true, false] do
      test "one active match, disclose #{disclose} -> :neutral" do
        assert LoginDiscovery.decide(:uniform_plus_email, {:ok, [match("a", unquote(disclose))]}) ==
                 :neutral
      end
    end

    test "several, none and failure -> :neutral" do
      assert LoginDiscovery.decide(
               :uniform_plus_email,
               {:ok, [match("a", true), match("b", true)]}
             ) == :neutral

      assert LoginDiscovery.decide(:uniform_plus_email, {:ok, []}) == :neutral
      assert LoginDiscovery.decide(:uniform_plus_email, {:error, :lookup_failed}) == :neutral
    end
  end

  describe "decide/2: any other mode term is not :redirect_single (defence in depth)" do
    for junk <- [nil, :nonsense, "redirect_single", 1] do
      test "mode #{inspect(junk)} with one disclose-true match -> :neutral" do
        assert LoginDiscovery.decide(unquote(Macro.escape(junk)), {:ok, [match("a", true)]}) ==
                 :neutral
      end
    end
  end

  # ── delivery/2 ──────────────────────────────────────────────────────────

  describe "delivery/2: deployment :redirect_single" do
    test "one match, tenant redirect_single (disclosed by the 200) -> :none" do
      assert LoginDiscovery.delivery(:redirect_single, {:ok, [match("a", true)]}) == :none
    end

    test "one match in a UNIFORM tenant (disclose false) -> {:deliver, [t]} (a list of 1)" do
      assert LoginDiscovery.delivery(:redirect_single, {:ok, [match("a", false)]}) ==
               {:deliver, [ref("a")]}
    end

    test "two matches (mixed tenant settings) -> {:deliver, both}, query order preserved, `disclose` stripped" do
      result = {:ok, [match("b", true), match("a", false), match("c", true)]}

      assert LoginDiscovery.delivery(:redirect_single, result) ==
               {:deliver, [ref("b"), ref("a"), ref("c")]}
    end

    test "no match and lookup failure -> :none" do
      assert LoginDiscovery.delivery(:redirect_single, {:ok, []}) == :none
      assert LoginDiscovery.delivery(:redirect_single, {:error, :lookup_failed}) == :none
    end
  end

  describe "delivery/2: deployment :uniform_plus_email" do
    for disclose <- [true, false] do
      test "one match, disclose #{disclose} -> {:deliver, [t]} (the 200 is forced off, so the list goes by mail)" do
        assert LoginDiscovery.delivery(
                 :uniform_plus_email,
                 {:ok, [match("a", unquote(disclose))]}
               ) ==
                 {:deliver, [ref("a")]}
      end
    end

    test "several -> {:deliver, all}; none and failure -> :none" do
      assert LoginDiscovery.delivery(
               :uniform_plus_email,
               {:ok, [match("a", true), match("b", true)]}
             ) ==
               {:deliver, [ref("a"), ref("b")]}

      assert LoginDiscovery.delivery(:uniform_plus_email, {:ok, []}) == :none
      assert LoginDiscovery.delivery(:uniform_plus_email, {:error, :lookup_failed}) == :none
    end
  end

  test "delivery/2 with a mode that is not :redirect_single behaves like the uniform ceiling" do
    assert LoginDiscovery.delivery(:nonsense, {:ok, [match("a", true)]}) == {:deliver, [ref("a")]}
  end

  test "delivery/2 never hands the notifier a `disclose` key or anything beyond slug and display_name" do
    {:deliver, tenants} =
      LoginDiscovery.delivery(
        :uniform_plus_email,
        {:ok, [Map.put(match("a", true), :tenant_id, "leak-me"), match("b", false)]}
      )

    assert Enum.all?(tenants, &(&1 |> Map.keys() |> Enum.sort() == [:display_name, :slug]))
  end

  test "an unexpected result shape is :none / :neutral, never a crash" do
    assert LoginDiscovery.delivery(:redirect_single, :garbage) == :none
    assert LoginDiscovery.decide(:redirect_single, :garbage) == :neutral
  end

  # ── mode vocabulary: one source ─────────────────────────────────────────

  describe "deployment_mode/0 (the single reader)" do
    test "the shipped default, from the evaluated test env, is :redirect_single" do
      assert LoginDirectory.deployment_mode() == :redirect_single
      assert LoginDiscovery.mode() == :redirect_single
    end

    for {config, expected} <- [
          {:unset, :redirect_single},
          {[], :redirect_single},
          {[mode: nil], :redirect_single},
          {[mode: :redirect_single], :redirect_single},
          {[mode: :uniform_plus_email], :uniform_plus_email},
          {[mode: :nonsense], :uniform_plus_email},
          {[mode: "redirect_single"], :uniform_plus_email},
          {[mode: 1], :uniform_plus_email}
        ] do
      test "config #{inspect(config)} -> #{inspect(expected)}, and mode/0 delegates to it" do
        case unquote(Macro.escape(config)) do
          :unset -> H.delete_env!(Letflow.LoginDiscovery)
          value -> H.put_env!(Letflow.LoginDiscovery, value)
        end

        assert LoginDirectory.deployment_mode() == unquote(expected)
        assert LoginDiscovery.mode() == unquote(expected)
      end
    end

    test "reading the mode logs nothing (D29)" do
      H.put_env!(Letflow.LoginDiscovery, mode: :nonsense)

      # ISS-1038: attributed sink at every level (collector level is :all; the VM logger level is
      # :debug in :test), so another test's event cannot make this "logs nothing" assertion fail.
      {_mode, entries} =
        Letflow.Test.LoggerCollector.capture(
          fn -> LoginDirectory.deployment_mode() end,
          attribute_to: self()
        )

      assert entries == []
    end
  end

  describe "parse_deployment_mode/1 (the ONLY parser of LETFLOW_LOGIN_DISCOVERY_MODE)" do
    for blank <- [nil, "", "   ", "\t", "\n", " \n "] do
      test "#{inspect(blank)} is no override: {:ok, nil}" do
        assert LoginDirectory.parse_deployment_mode(unquote(blank)) == {:ok, nil}
      end
    end

    test "exactly the two vocabulary words (after trim) parse to their atoms" do
      assert LoginDirectory.parse_deployment_mode("redirect_single") == {:ok, :redirect_single}

      assert LoginDirectory.parse_deployment_mode("uniform_plus_email") ==
               {:ok, :uniform_plus_email}

      assert LoginDirectory.parse_deployment_mode("  redirect_single\n") ==
               {:ok, :redirect_single}

      assert LoginDirectory.parse_deployment_mode("\tuniform_plus_email ") ==
               {:ok, :uniform_plus_email}
    end

    for bad <- [
          "Redirect_Single",
          "REDIRECT_SINGLE",
          "Uniform_Plus_Email",
          "uniform",
          "redirect",
          "picker_unauth",
          "redirect_single;",
          "redirect single",
          "uniform_plus_email,redirect_single",
          "true",
          "0"
        ] do
      test "#{inspect(bad)} is {:error, :invalid_mode} (case-sensitive, closed vocabulary)" do
        assert LoginDirectory.parse_deployment_mode(unquote(bad)) == {:error, :invalid_mode}
      end
    end

    test "non-binary terms are invalid" do
      for bad <- [:redirect_single, 5, [], %{}] do
        assert LoginDirectory.parse_deployment_mode(bad) == {:error, :invalid_mode}
      end
    end

    test "the error carries no part of the supplied value and no atom is created from it" do
      value = "leaky-mode-" <> Integer.to_string(System.unique_integer([:positive]))
      result = LoginDirectory.parse_deployment_mode(value)

      assert result == {:error, :invalid_mode}
      refute inspect(result) =~ value
      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end

    test "the parser results are exactly the atoms deployment_mode/0 recognises (one vocabulary)" do
      for word <- ["redirect_single", "uniform_plus_email"] do
        {:ok, atom} = LoginDirectory.parse_deployment_mode(word)
        H.put_env!(Letflow.LoginDiscovery, mode: atom)
        assert LoginDirectory.deployment_mode() == atom
      end
    end
  end

  describe "LoginDiscovery config readers" do
    test "max_body_bytes/0: the shipped bound is 2048; non-positive or non-integer falls back to 2048" do
      assert LoginDiscovery.max_body_bytes() == 2048

      for bad <- [0, -5, "2048", nil, 1.5] do
        H.put_env!(Letflow.LoginDiscovery, mode: :redirect_single, max_body_bytes: bad)
        assert LoginDiscovery.max_body_bytes() == 2048
      end

      H.put_env!(Letflow.LoginDiscovery, mode: :redirect_single, max_body_bytes: 512)
      assert LoginDiscovery.max_body_bytes() == 512
    end

    test "read_timeout/0 defaults to 5000 ms and only accepts a positive integer" do
      assert LoginDiscovery.read_timeout() == 5_000
      H.put_env!(Letflow.LoginDiscovery, read_timeout: 250)
      assert LoginDiscovery.read_timeout() == 250
      H.put_env!(Letflow.LoginDiscovery, read_timeout: 0)
      assert LoginDiscovery.read_timeout() == 5_000
    end
  end

  # ── evaluated config (shipped defaults) ─────────────────────────────────

  describe "evaluated config" do
    test "config/config.exs ships mode :redirect_single, max_body_bytes 2048 and the Noop notifier adapter, in every env" do
      for env <- [:dev, :prod] do
        config = read_config(env)

        assert get_in(config, [:letflow, Letflow.LoginDiscovery]) == [
                 mode: :redirect_single,
                 max_body_bytes: 2048
               ]

        notifier = get_in(config, [:letflow, @notifier])
        assert notifier[:adapter] == Letflow.LoginDiscovery.Notifier.Noop
        assert notifier[:timeout_ms] == 5_000
        assert notifier[:max_concurrent] == 100
      end
    end

    test "the mount's shipped default is OFF in :prod and ON in dev/test, and its env holds only `enabled`" do
      assert get_in(read_config(:prod), [:letflow, Letflow.Routers.LoginDiscovery]) == [
               enabled: false
             ]

      assert get_in(read_config(:dev), [:letflow, Letflow.Routers.LoginDiscovery]) == [
               enabled: true
             ]

      assert get_in(read_config(:test), [:letflow, Letflow.Routers.LoginDiscovery]) == [
               enabled: true
             ]
    end

    test "the mode and body bound live under a key DISTINCT from the mount switch (REQ-439's env shape is untouched)" do
      assert :letflow |> Application.get_env(Letflow.Routers.LoginDiscovery) |> Keyword.keys() ==
               [:enabled]

      assert :letflow
             |> Application.get_env(Letflow.LoginDiscovery)
             |> Keyword.keys()
             |> Enum.sort() ==
               [:max_body_bytes, :mode]
    end

    test "the TEST config selects the test double as the notifier adapter (the key REQ-441 and REQ-444 read)" do
      assert Application.get_env(:letflow, @notifier)[:adapter] ==
               Letflow.LoginDiscoveryNotifierDouble

      assert Dispatch.adapter() == Letflow.LoginDiscoveryNotifierDouble

      assert get_in(read_config(:test), [:letflow, @notifier])[:adapter] ==
               Letflow.LoginDiscoveryNotifierDouble
    end

    test "the notifier behaviour is implemented by both shipped adapters" do
      for module <- [Letflow.LoginDiscovery.Notifier.Noop, Letflow.LoginDiscoveryNotifierDouble] do
        {:module, _} = Code.ensure_loaded(module)
        assert {:deliver_tenant_list, 2} in module.module_info(:exports)

        assert @notifier in (module.module_info(:attributes)
                             |> Keyword.get_values(:behaviour)
                             |> List.flatten())
      end
    end

    test "deploy/.env.example lists LETFLOW_LOGIN_DISCOVERY_MODE as an optional BLANK placeholder" do
      lines = File.read!("deploy/.env.example") |> String.split(~r/\r?\n/)
      assert "LETFLOW_LOGIN_DISCOVERY_MODE=" in lines
    end

    # config/dev.exs refuses a set MIX_TEST_PARTITION (ISS-0015 guard) and CI's partitioned run
    # exports it, so clear it for the duration of the read and restore it afterwards.
    defp read_config(env) do
      saved = System.get_env("MIX_TEST_PARTITION")
      System.delete_env("MIX_TEST_PARTITION")

      try do
        Config.Reader.read!("config/config.exs", env: env, target: :host)
      after
        if saved, do: System.put_env("MIX_TEST_PARTITION", saved)
      end
    end
  end

  # ── source guards (design s15.3, C-4, D27, mix.exs) ─────────────────────

  describe "source guards" do
    @dispatch_dir "lib/letflow/login_discovery"
    @router "lib/letflow/routers/login_discovery.ex"

    test "no start_child/async_nolink/Task.start/spawn in lib/letflow/login_discovery/ takes an MFA or argument list: every task body is a closure" do
      sources = for path <- Path.wildcard(@dispatch_dir <> "/**/*.ex"), do: {path, code(path)}
      refute sources == []

      for {path, src} <- sources do
        refute src =~ ~r/\bTask\.start(_link)?\(/, "#{path}: Task.start*"
        refute src =~ ~r/\bspawn(_link|_monitor)?\(/, "#{path}: spawn*"
        refute src =~ ~r/Task\.(Supervisor\.)?async\(/, "#{path}: linked async"

        calls = Regex.scan(~r/\b(start_child|async_nolink)\(([^)]*)/, src)

        for [_whole, name, args] <- calls do
          assert args =~ ~r/^\s*@?[a-z_]+,\s*(fun|fn)\b/,
                 "#{path}: #{name}(#{String.slice(args, 0, 60)}) is not a (supervisor, closure) call"
        end
      end

      # and the two real call sites are really there (the guard is not vacuous)
      dispatch = code(@dispatch_dir <> "/dispatch.ex")
      assert dispatch =~ "Task.Supervisor.start_child(@supervisor, fun)"
      assert dispatch =~ "Task.Supervisor.async_nolink(@supervisor, fn ->"
    end

    test "the router never calls lookup_by_email (it computes the keys itself and calls lookup_by_keys exactly once)" do
      src = code(@router)
      refute src =~ "lookup_by_email"
      assert length(Regex.scan(~r/LoginDirectory\.lookup_by_keys\(/, src)) == 1
      assert src =~ "LoginDirectory.email_keys("
      assert src =~ "LoginDirectory.sentinel_keys()"
    end

    test "nothing under lib/letflow/login_discovery/ touches the Repo, and the router only via the one lookup" do
      for path <-
            Path.wildcard(@dispatch_dir <> "/**/*.ex") ++
              ["lib/letflow/login_discovery.ex", @router] do
        refute code(path) =~ ~r/\bRepo\b/, "#{path} references Repo"
      end
    end

    test "Letflow.LoginDiscovery defines no mode vocabulary of its own (no list, parser or converter)" do
      src = code("lib/letflow/login_discovery.ex")
      refute src =~ "uniform_plus_email"
      refute src =~ ~r/String\.to_(existing_)?atom/
      refute src =~ ~r/\bdef(p)?\s+(parse|valid|normali[sz]e)/
      assert src =~ "defdelegate mode()"
    end

    test "the router/notifier code never logs an email, key, slug or tenant (only fixed strings)" do
      for path <-
            Path.wildcard(@dispatch_dir <> "/**/*.ex") ++
              [@router, "lib/letflow/login_discovery.ex"] do
        for [_, call] <-
              Regex.scan(~r/Logger\.(?:debug|info|warning|warn|error)\(([^\n]*)\)/, code(path)) do
          assert call =~ ~r/^"[^"#]*"$/, "#{path}: non-fixed log line #{call}"
        end
      end
    end

    # REQ-441 (decision 0045; REVIEWER step 02d finding 6): replaces the REQ-437
    # "mix.exs is untouched" check, which was a git working-tree-state check whose premise
    # (this requirement family never touches mix.exs) is false since REQ-441. The intent --
    # no unreviewed dependency creeps in -- is kept as a CONTENT assertion that does not
    # depend on git state. The fuller footprint checks live in req441_source_guards_test.exs.
    test "mix.exs adds only gen_smtp (REQ-441, decision 0045)" do
      {:ok, ast} = "mix.exs" |> File.read!() |> Code.string_to_quoted()

      {_ast, entries} =
        Macro.prewalk(ast, [], fn
          {:defp, _meta, [{:deps, _, _}, [do: deps]]} = node, acc when is_list(deps) ->
            {node, acc ++ deps}

          node, acc ->
            {node, acc}
        end)

      deps =
        for entry <- entries do
          case entry do
            {name, _requirement} when is_atom(name) -> name
            {:{}, _meta, [name | _rest]} when is_atom(name) -> name
          end
        end

      assert length(deps) > 10, "the deps list was not parsed: #{inspect(deps)}"
      assert :gen_smtp in deps

      for banned <- [:swoosh, :bamboo, :mua, :mail, :finch, :req, :hackney] do
        refute banned in deps, "mix.exs declares #{banned}; decision 0045 chose gen_smtp alone"
      end

      lock = Mix.Dep.Lock.read()
      assert Map.has_key?(lock, :gen_smtp)

      for banned <- [:swoosh, :mua, :mail, :idna] do
        refute Map.has_key?(lock, banned), "mix.lock has a #{banned} entry"
      end
    end

    defp code(path) do
      path
      |> File.read!()
      |> String.replace(~r/"""[\s\S]*?"""/, "")
      |> String.replace(~r/^\s*#.*$/m, "")
    end
  end

  test "M2 delivery keeps hostname but strips internal fields" do
    match = %{
      slug: "acme",
      display_name: "Acme",
      hostname: "acme.ai-letflow.com",
      disclose: true,
      tenant_id: "hidden",
      idp_realm_id: "hidden",
      settings: %{}
    }

    assert {:deliver, [ref]} = LoginDiscovery.delivery(:uniform_plus_email, {:ok, [match]})
    assert ref == Map.take(match, [:slug, :display_name, :hostname])
  end
end
