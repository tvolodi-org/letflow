defmodule Letflow.Scripts.QaUpgradeChainFake do
  @moduledoc false
  # Fake tenant API: an Agent holds per-"tenant/module" state. Module "stock" is behind (safe),
  # "assets" is behind with a class B row, the rest are current. The test seeds the Agent.
  @behaviour Plug
  import Plug.Conn

  def init(o), do: o
  def agent, do: :qa_chain_fake

  def call(conn, _) do
    {:ok, raw, conn} = read_body(conn)
    [slug | _] = get_req_header(conn, "x-tenant-slug") ++ ["?"]

    Agent.update(
      agent(),
      &Map.update!(&1, :log, fn l -> [{conn.method, conn.request_path, raw, slug} | l] end)
    )

    route(conn, conn.method, conn.path_info, slug)
  end

  defp json(conn, status, map),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))

  defp route(conn, "GET", ["api", "v1", "me", "modules"], _slug) do
    mods = Agent.get(agent(), & &1.modules)
    json(conn, 200, %{installed_modules: for(m <- Map.keys(mods), do: %{module_id: m})})
  end

  defp route(conn, "POST", ["api", "v1", "tenant", "modules", m, "upgrade", "plan"], _slug) do
    state = Agent.get(agent(), &Map.fetch!(&1.modules, m))

    case state do
      :current ->
        json(conn, 200, %{up_to_date: true, from_version: "2", to_version: "2"})

      s ->
        json(conn, 200, %{
          up_to_date: false,
          from_version: "1",
          to_version: "2",
          upgrade_path_available: true,
          plan_hash: "h",
          entity_types: [%{name: "x", class: if(s == :destructive, do: "B", else: "A")}]
        })
    end
  end

  defp route(conn, "POST", ["api", "v1", "tenant", "modules", m, "upgrade"], _slug) do
    Agent.update(agent(), &put_in(&1, [:modules, m], :current))
    json(conn, 200, %{ok: true})
  end

  defp route(conn, _, _, _), do: json(conn, 404, %{})
end

defmodule Letflow.Scripts.QaUpgradeChainTest do
  @moduledoc """
  T-2746: `scripts/qa_upgrade_chain.sh` against a fake tenant API (a Bandit listener, the script as a `bash`
  subprocess): Q1 a safe plan is applied and a second run changes nothing; Q2 a class B plan is refused, nothing is
  applied for it, the step fails with the one-line reason and the "behind" count; Q3 `ack_destructive` is never sent;
  Q4 a non-QA host is refused; Q5 cd.yml runs the chain after the deploy only.
  """
  use ExUnit.Case, async: false

  @script "scripts/qa_upgrade_chain.sh"
  @agent Letflow.Scripts.QaUpgradeChainFake.agent()

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)

    start_supervised!(%{
      id: :agent,
      start: {Agent, :start_link, [fn -> %{modules: %{}, log: []} end, [name: @agent]]}
    })

    pid = start_supervised!({Bandit, plug: Letflow.Scripts.QaUpgradeChainFake, port: 0})
    {:ok, {_a, port}} = ThousandIsland.listener_info(pid)
    file = Path.join(System.tmp_dir!(), "qa-tenants-#{System.unique_integer([:positive])}.txt")
    File.write!(file, "# c\nqoimeks-qa2\n\nsss-rehearsal2 # x\n")
    on_exit(fn -> File.rm(file) end)
    {:ok, port: port, tfile: file}
  end

  defp set(mods), do: Agent.update(@agent, &%{&1 | modules: mods, log: []})
  defp log, do: Agent.get(@agent, &Enum.reverse(&1.log))

  defp run(c, extra \\ []) do
    System.cmd("bash", [@script],
      env:
        [
          {"BASE_URL", "http://127.0.0.1:#{c.port}"},
          {"ACCESS_TOKEN", "t"},
          {"TENANTS_FILE", c.tfile}
        ] ++ extra,
      stderr_to_stdout: true
    )
  end

  test "Q1 safe chain applies, second run changes nothing", c do
    set(%{"org" => :current, "stock" => :behind})
    {out, rc} = run(c)
    assert rc == 0, out
    assert out =~ "applied "
    assert out =~ "QA tenants behind the build: 0"
    # the fake keeps state per module (not per tenant): the second tenant finds it current
    assert Enum.any?(
             log(),
             &match?({"POST", "/api/v1/tenant/modules/stock/upgrade", _, "qoimeks-qa2"}, &1)
           )

    set(%{"org" => :current, "stock" => :current})
    {out2, rc2} = run(c)
    assert rc2 == 0, out2
    refute Enum.any?(log(), fn {_, p, _, _} -> String.ends_with?(p, "/upgrade") end)
    assert out2 =~ "QA tenants behind the build: 0"
  end

  test "Q2 and Q3 destructive plan fails the step, applies nothing, never acks", c do
    set(%{"org" => :current, "assets" => :destructive})
    {out, rc} = run(c)
    assert rc == 1, out
    assert out =~ "REFUSED qoimeks-qa2/assets: 1 -> 2 needs an administrator acknowledgement"
    assert out =~ "QA tenants behind the build: 2"
    refute Enum.any?(log(), fn {_, p, _, _} -> String.ends_with?(p, "assets/upgrade") end)
    refute Enum.any?(log(), fn {_, _, body, _} -> body =~ "ack_destructive" end)
  end

  test "Q4 a non-QA host is refused before any request", c do
    {out, rc} = run(c, [{"BASE_URL", "https://app.example.org"}])
    assert rc == 2
    assert out =~ "not a QA host"
  end

  test "Q5 cd.yml runs the chain after the deploy, the tenant file keeps retired ones out" do
    cd = File.read!(".github/workflows/cd.yml")
    assert cd =~ "scripts/qa_upgrade_chain.sh"
    {deploy, _} = :binary.match(cd, "redeploy-qa.sh")
    {chain, _} = :binary.match(cd, "scripts/qa_upgrade_chain.sh")
    assert chain > deploy
    tenants = File.read!("deploy/qa-upgrade-tenants.txt")
    lines = tenants |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "#"))
    for t <- ~w(qoimeks-qa2 sss-rehearsal2), do: assert(t in lines)
    for t <- ~w(sss-rehearsal qoimeks-qa qoimeks-client1-qa), do: refute(t in lines)
  end
end
