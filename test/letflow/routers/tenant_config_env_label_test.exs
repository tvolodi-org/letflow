defmodule Letflow.Routers.TenantConfigEnvLabelTest do
  @moduledoc """
  T-1494: `LETFLOW_ENV_LABEL` is an instance-global display label served as `env_label` by
  `GET /api/tenant-config`. Unset -> no key. The env var is global, so not async.
  """

  use Letflow.DataCase, async: false

  import Plug.Test

  @router_opts Letflow.Router.init([])
  @var "LETFLOW_ENV_LABEL"

  setup do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    System.delete_env(@var)
    :ok
  end

  defp body(path) do
    conn = Letflow.Router.call(conn(:get, path), @router_opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "B1: unset -> no env_label key" do
    refute Map.has_key?(body("/api/tenant-config"), "env_label")
  end

  test "B2: empty and blank -> empty string" do
    for v <- ["", "   "] do
      System.put_env(@var, v)
      assert body("/api/tenant-config")["env_label"] == ""
    end
  end

  test "B3: text is trimmed" do
    System.put_env(@var, "  STAGING ")
    assert body("/api/tenant-config")["env_label"] == "STAGING"
  end

  test "B4: over-long text is cut to 40 characters" do
    System.put_env(@var, String.duplicate("x", 100))
    assert body("/api/tenant-config")["env_label"] == String.duplicate("x", 40)
  end

  test "B5: same value for default, unknown realm and host branches" do
    System.put_env(@var, "DEMO")
    a = body("/api/tenant-config")
    b = body("/api/tenant-config?realm=no-such-realm-t1494")
    c = body("/api/tenant-config?host=example.test")
    assert a["env_label"] == "DEMO" and b["env_label"] == "DEMO" and c["env_label"] == "DEMO"
    assert a == b and b == c
  end
end
