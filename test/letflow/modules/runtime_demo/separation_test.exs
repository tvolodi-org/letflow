defmodule Letflow.Modules.RuntimeDemo.SeparationTest do
  @moduledoc """
  T-1641: the demo module is in the catalogue only for tests and the QA build. Reads config/config.exs for
  the production env with the build variable unset and set, and the build definitions under deploy/.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Modules.Catalog

  @var "LETFLOW_INCLUDE_RUNTIME_DEMO"

  setup do
    old = System.get_env(@var)

    on_exit(fn ->
      if old, do: System.put_env(@var, old), else: System.delete_env(@var)
    end)
  end

  defp read(env), do: Config.Reader.read!("config/config.exs", env: env)[:letflow]

  test "S1: production config with the variable unset has no demo module and the 9 real modules" do
    System.delete_env(@var)
    cfg = read(:prod)
    assert cfg[:demo_modules] == []
    assert length(cfg[:modules]) == 9
    refute Letflow.Modules.RuntimeDemo in cfg[:modules]
  end

  test "S2: only the exact value true includes it" do
    System.put_env(@var, "true")
    assert read(:prod)[:demo_modules] == [Letflow.Modules.RuntimeDemo]
    assert read(:prod)[:modules] |> length() == 9

    for v <- ["false", "1", "TRUE", ""] do
      System.put_env(@var, v)
      assert read(:prod)[:demo_modules] == [], "value #{inspect(v)}"
    end
  end

  test "S3: the Dockerfile defaults the argument to false before COPY lib; only redeploy-qa passes true" do
    docker = File.read!("deploy/Dockerfile")
    assert docker =~ "ARG #{@var}=false"
    {arg_at, _} = :binary.match(docker, "ARG #{@var}")
    {copy_at, _} = :binary.match(docker, "COPY lib lib")
    assert arg_at < copy_at

    assert File.read!("deploy/redeploy-qa.sh") =~ "--build-arg #{@var}=true"

    others =
      (Path.wildcard("deploy/**/*") ++ Path.wildcard(".github/workflows/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&(&1 in ["deploy/Dockerfile", "deploy/redeploy-qa.sh"]))
      |> Enum.filter(&(File.read!(&1) =~ @var))

    assert others == []
  end

  test "S4: in the test env the catalogue lists it once" do
    assert Catalog.fetch("runtime_demo") == {:ok, Letflow.Modules.RuntimeDemo}
    assert Enum.count(Catalog.entry_modules(), &(&1 == Letflow.Modules.RuntimeDemo)) == 1
  end
end
