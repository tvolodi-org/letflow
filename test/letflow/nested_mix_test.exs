defmodule Letflow.NestedMixTest do
  @moduledoc """
  GH #2630: a nested `mix` child that starts the app must open a 4-slot pool, not inherit the
  partition's `TEST_POOL_SIZE` (20 on CI). `async: false`: mutates this VM's environment.
  """

  use ExUnit.Case, async: false

  alias Letflow.Test.NestedMix

  @spawn_sites [
    "test/mix/tasks/letflow.login_directory_tasks_test.exs",
    "test/mix/tasks/letflow.migrate_tenant_admins_test.exs"
  ]

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

  test "every app-starting spawn site goes through NestedMix.cmd, not bare System.cmd" do
    for site <- @spawn_sites do
      src = File.read!(Path.expand("../../" <> site, __DIR__))
      assert src =~ "Letflow.Test.NestedMix.cmd(", "#{site} must cap the child's pool"
      refute src =~ ~r/System\.cmd\(\s*(mix|"mix")/, "#{site} spawns mix with a bare System.cmd"
    end
  end

  test "executor_test's nested mix test uses the same cap constant" do
    src = File.read!(Path.expand("engine/lua/executor_test.exs", __DIR__))
    assert src =~ ~S|{"TEST_POOL_SIZE", Integer.to_string(Letflow.Test.NestedMix.pool_size())}|
  end
end
