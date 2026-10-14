defmodule Letflow.Routers.NoTenantWasmRegistrationTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC19 (decision 0053; design `lib/letflow/design/gh2534-7c-script-handler.md`
  section 14): no tenant route can register a WASM plugin -- a source scan over
  `lib/letflow/routers/` and `lib/letflow/plugs/` finds no registration call.
  """

  use ExUnit.Case, async: true

  @forbidden [
    "PluginRegistry.register_plugin_handler",
    "Wasm.ModuleRegistry.register",
    "ModuleVersionRegistry.register_version"
  ]

  test "source scan" do
    sources =
      Path.wildcard("lib/letflow/routers/**/*.ex") ++ Path.wildcard("lib/letflow/plugs/**/*.ex")

    # guard against a vacuous scan (wrong working directory)
    assert "lib/letflow/routers/script_rules.ex" in sources
    assert Enum.any?(sources, &String.starts_with?(&1, "lib/letflow/plugs/"))

    offenders =
      for path <- sources, needle <- @forbidden, File.read!(path) =~ needle, do: {path, needle}

    assert offenders == []
  end
end
