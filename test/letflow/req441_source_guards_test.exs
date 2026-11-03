defmodule Letflow.Req441SourceGuardsTest do
  @moduledoc """
  REQ-441 AC10 guards (spec `test/specs/REQ-441.md`; design s3.4 M3, s6.2 AC10 row,
  SECURITY-REVIEWER step 02c finding 10): structural facts about the shipped source that
  no behavioural test can prove.

    * `allow_test_cacerts` (the compile-time gate of the TEST-ONLY TLS trust override) is
      set to `true` only in `config/test.exs`; `lib/` reads it with default `false`, the
      override key `tls_cacerts` is referenced only inside the `if @allow_test_cacerts`
      branch, and `lib/` contains no `verify_none` / `verify_fun`;
    * the dependency footprint is exactly `:gen_smtp` (decision 0045): a CONTENT check of
      `mix.exs` and `mix.lock`, independent of git working-tree state;
    * the mail library is named only by `Smtp.Transport`; `:mimemail` is never called
      (it logs the `To` header at debug).

  Pure file reads: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @transport "lib/letflow/login_discovery/notifier/smtp/transport.ex"

  defp code(path) do
    path
    |> File.read!()
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")

  describe "M3: the test-only TLS trust override is physically absent from non-test builds" do
    test "allow_test_cacerts is set to true only in config/test.exs" do
      setters =
        for path <- Enum.uniq(Path.wildcard("config/**/*.exs")),
            code(path) =~ "allow_test_cacerts",
            do: path

      assert setters == ["config/test.exs"]
      assert code("config/test.exs") =~ ~r/allow_test_cacerts:\s*true/

      # and nothing else in the project (mix.exs, rel/, lib/) assigns it
      assert code("mix.exs") |> String.contains?("allow_test_cacerts") == false

      for path <- lib_files() ++ Path.wildcard("rel/**/*"), File.regular?(path) do
        refute code(path) =~ ~r/allow_test_cacerts:\s*true|allow_test_cacerts,\s*true/,
               "#{path} enables the test CA override"
      end
    end

    test "lib/ reads the flag at COMPILE time with default false, in exactly one module" do
      readers =
        for path <- lib_files(), code(path) =~ "allow_test_cacerts", do: path

      assert readers == [@transport]

      assert code(@transport) =~
               ~r/Application\.compile_env\(\s*:letflow,\s*\[Letflow\.LoginDiscovery\.Notifier\.Smtp,\s*:allow_test_cacerts\],\s*false\s*\)/

      refute code(@transport) =~ ~r/Application\.get_env\([^)]*allow_test_cacerts/
    end

    test "tls_cacerts is read only inside the `if @allow_test_cacerts` branch; the other branch is the OS store" do
      users = for path <- lib_files(), code(path) =~ "tls_cacerts", do: path
      assert users == [@transport]

      src = code(@transport)
      [before_branch, rest] = String.split(src, "if @allow_test_cacerts do", parts: 2)
      [enabled, disabled] = String.split(rest, "\n  else\n", parts: 2)

      refute before_branch =~ "tls_cacerts"
      assert enabled =~ "tls_cacerts"
      refute disabled =~ "tls_cacerts"
      assert disabled =~ ":public_key.cacerts_get()"
      # the else-branch is a single clause: the OS store, no environment input at all
      assert length(Regex.scan(~r/defp cacerts/, disabled)) == 1
      refute disabled =~ "Application."
    end

    test "lib/ never expresses verify_none, a verify_fun or an app-env-supplied SNI" do
      for path <- lib_files() do
        src = code(path)
        refute src =~ "verify_none", "#{path} mentions verify_none"
        refute src =~ "verify_fun", "#{path} mentions verify_fun"
      end

      src = code(@transport)
      assert src =~ "verify: :verify_peer"
      assert src =~ "server_name_indication: String.to_charlist(host)"
      assert src =~ "customize_hostname_check"
      assert src =~ ~s(versions: [:"tlsv1.3", :"tlsv1.2"])

      # outside the compile-time-gated branch the transport reads NO application env at all
      [outside_before, after_if] = String.split(src, "if @allow_test_cacerts do", parts: 2)
      [_enabled, outside_after] = String.split(after_if, "
  else
", parts: 2)
      refute outside_before <> outside_after =~ "Application.get_env"
    end

    test "the override accepts a DER list only: the app-env value is matched as a non-empty list" do
      assert code(@transport) =~ "[_ | _] = ders -> ders"
    end
  end

  describe "dependency footprint (decision 0045): mix.exs adds only gen_smtp" do
    @banned_deps ~w(swoosh bamboo mua mail finch req hackney)a
    @banned_lock ~w(swoosh mua mail idna)a

    defp declared_deps do
      {:ok, ast} = "mix.exs" |> File.read!() |> Code.string_to_quoted()

      {_ast, found} =
        Macro.prewalk(ast, [], fn
          {:defp, _meta, [{:deps, _, _}, [do: deps]]} = node, acc when is_list(deps) ->
            {node, acc ++ deps}

          node, acc ->
            {node, acc}
        end)

      for dep <- found do
        case dep do
          {name, _requirement} when is_atom(name) -> name
          {:{}, _meta, [name | _]} when is_atom(name) -> name
          {name, _meta, _args} when is_atom(name) -> name
        end
      end
    end

    # `Mix.Dep.Lock.read/0` is the lock reader Mix itself uses (atom keys); evaluating the
    # file directly would print a "quoted keyword" warning per line.
    defp read_lock, do: Mix.Dep.Lock.read()

    test "mix.exs deps contain :gen_smtp and none of the alternatives" do
      deps = declared_deps()
      assert length(deps) > 10, "the deps list was not parsed: #{inspect(deps)}"
      assert :gen_smtp in deps

      for banned <- @banned_deps do
        refute banned in deps, "mix.exs declares #{banned}; decision 0045 chose gen_smtp alone"
      end
    end

    test "gen_smtp is declared once, with a version requirement, and not as a runtime: false/only: dep" do
      {:ok, ast} = "mix.exs" |> File.read!() |> Code.string_to_quoted()

      {_ast, entries} =
        Macro.prewalk(ast, [], fn
          {:defp, _meta, [{:deps, _, _}, [do: deps]]} = node, acc when is_list(deps) ->
            {node, acc ++ deps}

          node, acc ->
            {node, acc}
        end)

      assert [{:gen_smtp, requirement}] = Enum.filter(entries, &match?({:gen_smtp, _}, &1))
      assert is_binary(requirement)
      assert requirement =~ "1.3"
    end

    test "mix.lock has gen_smtp and ranch and none of swoosh/mua/mail/idna; gen_smtp needs only ranch" do
      lock = read_lock()
      assert is_map(lock)

      assert Map.has_key?(lock, :gen_smtp)
      assert Map.has_key?(lock, :ranch)

      for banned <- @banned_lock do
        refute Map.has_key?(lock, banned), "mix.lock has a #{banned} entry"
      end

      assert {:hex, :gen_smtp, _version, _inner_hash, _managers, requirements, "hexpm", _outer} =
               lock[:gen_smtp]

      assert Enum.map(requirements, &elem(&1, 0)) == [:ranch]
    end

    test "the lock pins gen_smtp by hash (both hashes present)" do
      lock = read_lock()

      {:hex, :gen_smtp, version, inner_hash, _managers, _reqs, "hexpm", outer_hash} =
        lock[:gen_smtp]

      assert version == "1.3.0"
      assert inner_hash =~ ~r/\A[0-9a-f]{64}\z/
      assert outer_hash =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "the mail library is confined to Smtp.Transport" do
    test "only the transport names :gen_smtp / gen_smtp_client, and :mimemail is never used" do
      owners =
        for path <- lib_files(), code(path) =~ ~r/:gen_smtp|gen_smtp_client|:mimemail/, do: path

      assert owners == [@transport]
      refute code(@transport) =~ ":mimemail"
      assert code(@transport) =~ ":gen_smtp_client.send_blocking("
    end

    test "no `use Swoosh.Mailer`, no Swoosh/Bamboo/Mua reference anywhere in lib/ or config/" do
      for path <- lib_files() ++ Path.wildcard("config/**/*.exs") do
        refute code(path) =~ ~r/Swoosh|Bamboo|\bMua\b/, "#{path} references another mail library"
      end
    end

    test "the transport sends with retries 0, no MX lookup and the blocking API" do
      src = code(@transport)
      assert src =~ "retries: 0"
      assert src =~ "no_mx_lookups: true"
      assert src =~ "send_blocking"
      refute src =~ ~r/:gen_smtp_client\.send\(/
    end
  end
end
