defmodule Letflow.Modules.RuntimeDemo.ReleaseTest do
  @moduledoc "T-1641: the three selectable releases of the QA-only demo module and the boot setting parser."

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Modules.RuntimeDemo

  setup do
    old = Application.get_env(:letflow, :runtime_demo_release)

    on_exit(fn ->
      if old,
        do: Application.put_env(:letflow, :runtime_demo_release, old),
        else: Application.delete_env(:letflow, :runtime_demo_release)
    end)
  end

  defp release(version) do
    Application.put_env(:letflow, :runtime_demo_release, version)
    RuntimeDemo.manifest()
  end

  test "declares: each release has its literal version window and min_data_version" do
    assert %{version: "0.1.0", min_upgradable_from: "0.1.0", min_data_version: "0.1.0"} =
             release("0.1.0")

    assert %{version: "0.2.0", min_upgradable_from: "0.1.0", min_data_version: "0.1.0"} =
             release("0.2.0")

    assert %{version: "0.3.0", min_upgradable_from: "0.1.0", min_data_version: "0.3.0"} =
             release("0.3.0")
  end

  test "each release has its own manifest hash (no rebuild between releases)" do
    hashes =
      for v <- RuntimeDemo.releases() do
        Application.put_env(:letflow, :runtime_demo_release, v)
        {:ok, hash} = Letflow.Modules.Catalog.manifest_hash("runtime_demo")
        hash
      end

    assert length(Enum.uniq(hashes)) == 3
  end

  test "parse_release: unset and blank are 0.1.0, the three strings pass" do
    assert RuntimeDemo.parse_release(nil) == "0.1.0"
    assert RuntimeDemo.parse_release("") == "0.1.0"
    assert RuntimeDemo.parse_release("  ") == "0.1.0"
    for v <- ["0.1.0", "0.2.0", "0.3.0"], do: assert(RuntimeDemo.parse_release(v) == v)
  end

  test "parse_release: anything else raises without echoing the value" do
    error = assert_raise RuntimeError, fn -> RuntimeDemo.parse_release("9.9.9-secret") end
    refute error.message =~ "9.9.9"
    assert error.message =~ "LETFLOW_RUNTIME_DEMO_RELEASE"
  end
end
