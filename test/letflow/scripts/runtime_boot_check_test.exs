defmodule Letflow.Scripts.RuntimeBootCheckTest do
  @moduledoc """
  GH 2534 PR 7c-1 SECURITY note (design `lib/letflow/design/gh2534-7c-script-handler.md` 5.1):
  every 7b/7c script test seam is honoured only while `:scripts_test_hooks` is true, so the
  application refuses to start in `:prod` with it set.
  """

  use ExUnit.Case, async: true

  alias Letflow.Scripts.Runtime

  test "boot_check/2 refuses the test hooks only in :prod" do
    assert Runtime.boot_check(:prod, true) == {:error, :scripts_test_hooks_in_prod}
    assert Runtime.boot_check(:prod, false) == :ok
    assert Runtime.boot_check(:prod, nil) == :ok
    assert Runtime.boot_check(:test, true) == :ok
    assert Runtime.boot_check(:dev, true) == :ok
    assert Runtime.boot_check(nil, true) == :ok
  end

  test "the build environment is configured, and the guard is wired into Letflow.Application" do
    assert Application.get_env(:letflow, :config_env) == :test
    source = File.read!("lib/letflow/application.ex")
    assert source =~ "Letflow.Scripts.Runtime.boot_check("
    assert source =~ "Application.get_env(:letflow, :config_env)"
    assert source =~ "raise"
  end
end
