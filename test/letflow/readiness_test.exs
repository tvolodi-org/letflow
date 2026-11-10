defmodule Letflow.ReadinessTest do
  @moduledoc """
  T-1607: `GET /ready` through the real `Letflow.Router` (no auth header) and `Letflow.Readiness.run/1`.
  Tests R1..R6 of the design's criterion table.
  """

  use Letflow.DataCase, async: false

  import Plug.Test

  alias Letflow.Readiness

  defmodule ProbeOk do
    @behaviour Letflow.Oidc.RealmProbe
    @impl true
    def verify(_realm), do: :ok
  end

  defmodule ProbeDown do
    @behaviour Letflow.Oidc.RealmProbe
    @impl true
    def verify(_realm), do: {:error, :unreachable}
  end

  defmodule ProbeNotFound do
    @behaviour Letflow.Oidc.RealmProbe
    @impl true
    def verify(_realm), do: {:error, :not_found}
  end

  defmodule ProbeCounting do
    @behaviour Letflow.Oidc.RealmProbe
    @impl true
    def verify(_realm) do
      send(:readiness_test_pid, :probed)
      :ok
    end
  end

  setup do
    Readiness.reset_cache()
    old_probe = Application.get_env(:letflow, :oidc_realm_probe)
    old_key = Application.get_env(:letflow, :secrets_master_key)
    Application.put_env(:letflow, :oidc_realm_probe, ProbeOk)

    on_exit(fn ->
      Readiness.reset_cache()
      restore(:oidc_realm_probe, old_probe)
      restore(:secrets_master_key, old_key)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)

  defp get_ready do
    conn = Letflow.Router.call(conn(:get, "/ready"), Letflow.Router.init([]))
    {conn.status, Jason.decode!(conn.resp_body), conn.resp_body}
  end

  test "R1 ready_all_ok: 200 and the four parts are ok, with no auth header" do
    assert {200, body, _raw} = get_ready()
    assert body["status"] == "ready"

    assert body["checks"] == %{
             "database" => "ok",
             "migrations" => "ok",
             "secrets_key" => "ok",
             "identity" => "ok"
           }
  end

  test "R2 a missing secrets key names secrets_key" do
    Application.put_env(:letflow, :secrets_master_key, nil)
    assert {503, body, _raw} = get_ready()
    assert body["status"] == "not_ready"
    assert body["failing"] == ["secrets_key"]
    assert body["checks"]["database"] == "ok"
  end

  test "R3 identity unreachable names identity; not_found still counts as answered" do
    Application.put_env(:letflow, :oidc_realm_probe, ProbeDown)
    assert {503, body, _raw} = get_ready()
    assert body["failing"] == ["identity"]

    Readiness.reset_cache()
    Application.put_env(:letflow, :oidc_realm_probe, ProbeNotFound)
    assert {200, _body, _raw} = get_ready()
  end

  test "R4b the default migrations read takes no table lock and no DDL" do
    assert Readiness.migrations_opts()[:migration_lock] == false
    assert Readiness.migrations_opts()[:skip_table_creation] == true
  end

  test "R3b the whole result is cached between calls" do
    Process.register(self(), :readiness_test_pid)
    Application.put_env(:letflow, :oidc_realm_probe, ProbeCounting)
    first = Readiness.run()
    Readiness.run()
    assert first == Readiness.run()
    assert_received :probed
    refute_received :probed
  end

  test "R3 the identity result is cached: two calls probe once" do
    Process.register(self(), :readiness_test_pid)
    Application.put_env(:letflow, :oidc_realm_probe, ProbeCounting)
    assert %{ready: true} = Readiness.run()
    assert %{ready: true} = Readiness.run()
    assert_received :probed
    refute_received :probed
  end

  test "R4 migrations behind names migrations; the real run is ok" do
    assert %{ready: true} = Readiness.run()
    result = Readiness.run(migrations_fun: fn -> [{:up, 1, "a"}, {:down, 2, "b"}] end)
    assert result.failing == ["migrations"]
    assert Readiness.run(migrations_fun: fn -> :boom end).failing == ["migrations"]
  end

  test "R5 database down names database; a raising or hanging check is a fail" do
    assert Readiness.run(db_fun: fn -> {:error, :down} end).failing == ["database"]
    assert Readiness.run(db_fun: fn -> raise "secret detail" end).failing == ["database"]
    assert Readiness.run(key_fun: fn -> exit(:boom) end).failing == ["secrets_key"]
  end

  @tag timeout: 15_000
  test "R5 a hanging check times out as fail" do
    result = Readiness.run(db_fun: fn -> Process.sleep(:infinity) end)
    assert result.failing == ["database"]
  end

  test "R6 all fail at once lists every part; the body holds only the fixed vocabulary" do
    Application.put_env(:letflow, :oidc_realm_probe, ProbeDown)
    key = Application.get_env(:letflow, :secrets_master_key)
    Application.put_env(:letflow, :secrets_master_key, "short")

    result =
      Readiness.run(
        db_fun: fn -> {:error, %{message: "password=hunter2 host=db.internal"}} end,
        migrations_fun: fn -> [{:down, 1, "x"}] end
      )

    assert result.failing == Readiness.parts()

    Application.put_env(:letflow, :secrets_master_key, nil)
    assert {503, body, raw} = get_ready()
    assert Map.keys(body) |> Enum.sort() == ["checks", "failing", "status"]
    assert body["checks"] |> Map.values() |> Enum.uniq() |> Enum.all?(&(&1 in ["ok", "fail"]))
    refute raw =~ "hunter2"
    refute raw =~ "keycloak"
    refute raw =~ "placeholder"
    if is_binary(key), do: refute(raw =~ Base.encode16(key, case: :lower))
  end

  test "/health is unchanged" do
    conn = Letflow.Router.call(conn(:get, "/health"), Letflow.Router.init([]))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end
end
