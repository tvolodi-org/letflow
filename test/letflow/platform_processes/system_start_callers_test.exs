defmodule Letflow.PlatformProcesses.SystemStartCallersTest do
  @moduledoc """
  V5 (T-2727, pilot gap G17c; `docs/platform-register-tenant-v2.md` section 6.2): the callers pin of the
  system-authority start. `Letflow.PlatformProcesses.SystemStart` and
  `Letflow.PlatformProcesses.start_register_tenant_system/3` may be named ONLY in the files below: the
  struct's own module, the one start function, the engine and the start gate that read the opt, and the
  provisioner (the future caller, route 3 and route 4).

  The scan is token based, so every spelling is caught: an alias at module or file scope (including the
  `{A, B}` form), an `Elixir.`-prefixed name, a capture and a pipe all contain the identifier. A rogue
  fixture goes through the SAME entry point (`offending_files/1`) the real-tree test uses.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag probe_cost_s: 5

  @allowed MapSet.new([
             "lib/letflow/platform_processes/system_start.ex",
             "lib/letflow/platform_processes.ex",
             "lib/letflow/engine.ex",
             "lib/letflow/definitions/start_permission.ex",
             "lib/letflow/tenant_provisioner.ex",
             "lib/letflow/tenant_provisioner/admit.ex"
           ])

  @pattern ~r/\bSystemStart\b|\bstart_register_tenant_system\b/

  # Every file of `files` (a `%{path => source}` map) that names the authority and is not allowed.
  defp offending_files(files) do
    files
    |> Enum.filter(fn {path, source} ->
      not MapSet.member?(@allowed, path) and Regex.match?(@pattern, source)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp tree do
    "lib/**/*.ex" |> Path.wildcard() |> Map.new(&{&1, File.read!(&1)})
  end

  test "the real tree names the system start only in the allowed files" do
    files = tree()
    assert map_size(files) > 500, "the scan must find the tree"
    assert offending_files(files) == []

    # the rule is not vacuous: the allowed files do name it
    for path <- ["lib/letflow/platform_processes/system_start.ex", "lib/letflow/engine.ex"] do
      assert Regex.match?(@pattern, Map.fetch!(files, path))
    end
  end

  test "rogue spellings of a caller are all caught through the same entry point" do
    rogue = %{
      "lib/letflow/rogue_a.ex" =>
        "alias Letflow.PlatformProcesses.SystemStart\nSystemStart.for_route(:x)",
      "lib/letflow/rogue_b.ex" => "alias Letflow.PlatformProcesses.{Definition, SystemStart}",
      "lib/letflow/rogue_c.ex" => "Elixir.Letflow.PlatformProcesses.SystemStart.for_route(:x)",
      "lib/letflow/rogue_d.ex" => "f = &Letflow.PlatformProcesses.start_register_tenant_system/3",
      "lib/letflow/rogue_e.ex" => "req |> PlatformProcesses.start_register_tenant_system(s, [])",
      "lib/letflow/engine.ex" => "SystemStart",
      "lib/letflow/clean.ex" => "System.start_link()"
    }

    assert offending_files(rogue) ==
             Enum.sort(~w(lib/letflow/rogue_a.ex lib/letflow/rogue_b.ex lib/letflow/rogue_c.ex
                          lib/letflow/rogue_d.ex lib/letflow/rogue_e.ex))
  end
end
