defmodule Letflow.NestedMixTest do
  @moduledoc """
  GH #2630: a nested `mix` child that starts the app must open a 4-slot pool, not inherit the
  partition's `TEST_POOL_SIZE` (20 on CI). `async: false`: mutates this VM's environment.
  """

  use ExUnit.Case, async: false

  alias Letflow.Test.NestedMix

  setup do
    original = System.get_env("TEST_POOL_SIZE")

    on_exit(fn ->
      if original,
        do: System.put_env("TEST_POOL_SIZE", original),
        else: System.delete_env("TEST_POOL_SIZE")
    end)

    :ok
  end

  defp child_pool(opts \\ []) do
    bash = System.find_executable("bash") || flunk("bash is required")
    {out, 0} = NestedMix.cmd(bash, ["-c", ~S{printf '%s/%s' "$TEST_POOL_SIZE" "$KEEP_ME"}], opts)
    out
  end

  test "the cap is 4, the figure the CI reserve (4 partitions x 4 = 16) is built on" do
    assert NestedMix.pool_size() == 4
  end

  test "a child does not inherit the ambient partition pool size" do
    System.put_env("TEST_POOL_SIZE", "20")
    assert child_pool() == "4/"
  end

  test "a caller-supplied TEST_POOL_SIZE is replaced, other env (including unset pairs) is kept" do
    System.put_env("TEST_POOL_SIZE", "20")
    assert child_pool(env: [{"TEST_POOL_SIZE", "99"}, {"KEEP_ME", "yes"}]) == "4/yes"

    env = NestedMix.env([{"MIX_TEST_PARTITION", nil}, {"TEST_POOL_SIZE", "99"}])
    assert env == [{"TEST_POOL_SIZE", "4"}, {"MIX_TEST_PARTITION", nil}]
  end

  # Files whose bare `System.cmd("mix", ...)` children never open a Repo pool.
  @no_pool_children %{
    "test/letflow/admission_runtime_config_test.exs" =>
      "`mix compile` / `mix run --no-start`: no app start",
    "test/letflow/client_ip_runtime_config_test.exs" =>
      "`mix compile` / `mix run --no-start`: no app start",
    "test/letflow/login_discovery/enablement_gate_runtime_test.exs" =>
      "`mix compile` / `mix run --no-start`: no app start",
    "test/letflow/login_discovery_runtime_config_test.exs" =>
      "`mix run --no-start`: no app start",
    "test/letflow/mail_runtime_config_test.exs" => "`mix run --no-start`: no app start",
    "test/letflow/platform_tenant_runtime_config_test.exs" =>
      "`mix run --no-start`: no app start",
    "test/letflow/secrets_runtime_config_test.exs" => "`mix run --no-start`: no app start",
    "test/support/tenant_slug_test.exs" => "`mix run --no-start`: no app start",
    "test/mix/tasks/letflow.check_boundaries_test.exs" =>
      "`mix letflow.check_boundaries` is a static check: no `app.start`/`app.config` in the task"
  }

  @mix_spawn ~r/(Letflow\.Test\.NestedMix|System)\.cmd\(\s*(?:"mix"|mix\b)/
  @mix_lookup ~r/find_executable\("mix"\)/
  @shell_or_port_mix ~r/(?:System\.shell|Port\.open)\([^\n]*\bmix\b/

  # Source reduced to code: heredocs (docs/strings) and whole-line comments dropped.
  defp code(path) do
    path
    |> File.read!()
    |> String.replace(~r/(?:~[a-zA-Z])?"""\R.*?^[ \t]*"""/ms, "")
    |> String.replace(~r/^[ \t]*#.*$/m, "")
  end

  test "every mix-spawning call in test/ is allowlisted (no app start) or goes through NestedMix.cmd" do
    root = Path.expand("../..", __DIR__)
    self_file = Path.relative_to(__ENV__.file, root)

    files =
      (Path.wildcard(Path.join(root, "test/**/*.ex")) ++
         Path.wildcard(Path.join(root, "test/**/*.exs")))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 in [self_file, "test/support/nested_mix.ex"]))

    results =
      for rel <- files, src = code(Path.join(root, rel)), reduce: %{} do
        acc ->
          spawns = Regex.scan(@mix_spawn, src)
          bare = Enum.count(spawns, fn [_, mod] -> mod == "System" end)
          capped = length(spawns) - bare
          lookups = length(Regex.scan(@mix_lookup, src))
          shells = length(Regex.scan(@shell_or_port_mix, src))

          if bare + capped + lookups + shells == 0,
            do: acc,
            else:
              Map.put(acc, rel, %{bare: bare, capped: capped, lookups: lookups, shells: shells})
      end

    # Sanity: the scan sees the known sites, so a regex that matches nothing cannot pass.
    assert results["test/mix/tasks/letflow.login_directory_tasks_test.exs"]
    assert results["test/mix/tasks/letflow.migrate_tenant_admins_test.exs"]
    assert results["test/letflow/engine/lua/executor_test.exs"]
    assert results["test/letflow/mail_runtime_config_test.exs"]

    for {rel, counts} <- results do
      if Map.has_key?(@no_pool_children, rel) do
        assert counts.capped == 0 and counts.shells == 0,
               "#{rel} is allowlisted as pool-free; it must not mix both styles"
      else
        assert counts.shells == 0, "#{rel}: System.shell/Port.open with mix is not allowlisted"

        assert counts.bare == 0,
               "#{rel}: #{counts.bare} bare System.cmd(mix) call(s); use NestedMix.cmd"

        assert counts.capped > 0,
               "#{rel}: finds the mix executable but spawns nothing through NestedMix.cmd"

        assert counts.capped ==
                 length(Regex.scan(~r/NestedMix\.cmd\(/, code(Path.join(root, rel))))
      end
    end

    # Every allowlist entry is real (a stale entry would hide a later regression).
    for {rel, _reason} <- @no_pool_children,
        do: assert(Map.has_key?(results, rel), "stale allowlist: #{rel}")
  end
end
