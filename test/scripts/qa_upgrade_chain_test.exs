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
    [auth | _] = get_req_header(conn, "authorization") ++ [""]

    Agent.update(
      agent(),
      &Map.update!(&1, :log, fn l -> [{conn.method, conn.request_path, raw, slug} | l] end)
    )

    # like the real auth pipeline: a token is good for ITS tenant only ("Bearer tok-<slug>")
    if auth == "Bearer tok-" <> slug,
      do: route(conn, conn.method, conn.path_info, slug),
      else: json(conn, 401, %{error: "unauthorized", echo: auth})
  end

  defp json(conn, status, map),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))

  defp route(conn, "GET", ["api", "v1", "me", "modules"], slug) do
    mods = Agent.get(agent(), &Map.get(&1.modules, slug, %{}))
    json(conn, 200, %{installed_modules: for(m <- Map.keys(mods), do: %{module_id: m})})
  end

  defp route(conn, "POST", ["api", "v1", "tenant", "modules", m, "upgrade", "plan"], slug) do
    state = Agent.get(agent(), &Map.fetch!(&1.modules[slug], m))

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

  defp route(conn, "POST", ["api", "v1", "tenant", "modules", m, "upgrade"], slug) do
    Agent.update(agent(), &put_in(&1, [:modules, slug, m], :current))
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
    File.write!(file, "# c\nqoimeks-qa2 TOK_A\n\nsss-rehearsal2 TOK_B # x\n")
    on_exit(fn -> File.rm(file) end)
    {:ok, port: port, tfile: file}
  end

  defp both(mods), do: %{"qoimeks-qa2" => mods, "sss-rehearsal2" => mods}
  defp set(mods), do: Agent.update(@agent, &%{&1 | modules: mods, log: []})
  defp log, do: Agent.get(@agent, &Enum.reverse(&1.log))

  defp run(c, extra \\ []) do
    System.cmd("bash", [@script],
      env:
        [
          {"BASE_URL", "http://127.0.0.1:#{c.port}"},
          {"TOK_A", "tok-qoimeks-qa2"},
          {"TOK_B", "tok-sss-rehearsal2"},
          {"TENANTS_FILE", c.tfile}
        ] ++ extra,
      stderr_to_stdout: true
    )
  end

  test "Q1 safe chain applies, second run changes nothing", c do
    set(both(%{"org" => :current, "stock" => :behind}))
    {out, rc} = run(c)
    assert rc == 0, out
    assert out =~ "applied "
    assert out =~ "QA tenants behind the build: 0"
    # state is per tenant: each tenant is upgraded with its own credential, and only itself
    for t <- ~w(qoimeks-qa2 sss-rehearsal2) do
      assert Enum.any?(
               log(),
               &match?({"POST", "/api/v1/tenant/modules/stock/upgrade", _, ^t}, &1)
             )
    end

    assert Agent.get(@agent, & &1.modules) ==
             both(%{"org" => :current, "stock" => :current})

    set(both(%{"org" => :current, "stock" => :current}))
    {out2, rc2} = run(c)
    assert rc2 == 0, out2
    refute Enum.any?(log(), fn {_, p, _, _} -> String.ends_with?(p, "/upgrade") end)
    assert out2 =~ "QA tenants behind the build: 0"
  end

  test "Q2 and Q3 destructive plan fails the step, applies nothing, never acks", c do
    set(both(%{"org" => :current, "assets" => :destructive}))
    {out, rc} = run(c)
    assert rc == 1, out
    assert out =~ "REFUSED qoimeks-qa2/assets: 1 -> 2 needs an administrator acknowledgement"
    assert out =~ "QA tenants behind the build: 2"
    refute Enum.any?(log(), fn {_, p, _, _} -> String.ends_with?(p, "assets/upgrade") end)
    refute Enum.any?(log(), fn {_, _, body, _} -> body =~ "ack_destructive" end)
  end

  test "Q6 each tenant uses its own credential; a missing one sends nothing for that tenant", c do
    set(both(%{"org" => :behind}))
    {out, rc} = run(c, [{"TOK_B", ""}])
    assert rc == 1, out
    assert out =~ "REFUSED sss-rehearsal2: no usable credential in TOK_B (nothing sent)"
    assert out =~ "QA tenants behind the build: 1"
    assert Enum.all?(log(), fn {_, _, _, slug} -> slug == "qoimeks-qa2" end)
    assert Agent.get(@agent, & &1.modules)["sss-rehearsal2"] == %{"org" => :behind}
  end

  test "Q7 tenant A's token with tenant B's slug is a 401 and nothing is written", c do
    set(both(%{"org" => :behind}))
    {out, rc} = run(c, [{"TOK_A", "tok-sss-rehearsal2"}])
    assert rc == 4, out
    assert Agent.get(@agent, & &1.modules)["sss-rehearsal2"] == %{"org" => :behind}
    refute Enum.any?(log(), fn {m, _, _, _} -> m == "POST" end)
  end

  test "Q8 token canary is absent from output on success, request error and refusal paths", c do
    canary = "CANARY-lf_tok_s3cr3t"

    paths = [
      {both(%{"org" => :current, "stock" => :behind}), 0},
      {both(%{"assets" => :destructive}), 1},
      {both(%{"org" => :behind}), 4}
    ]

    for {{mods, rc_expected}, i} <- Enum.with_index(paths) do
      set(mods)

      # the third path: the server rejects the credential (401) and echoes the Authorization header back
      extra =
        if rc_expected == 4,
          do: [{"TOK_A", "tok-x-" <> canary}, {"TOK_B", "tok-y-" <> canary}],
          else: [{"TOK_A", "tok-qoimeks-qa2"}, {"TOK_B", "tok-sss-rehearsal2"}]

      {out, rc} = run(c, extra)
      assert rc == rc_expected, out

      # the credentials actually supplied on THIS path (real tokens on the rc 0/1 paths) never appear
      for {_var, tok} <- extra, tok != "" do
        refute out =~ tok, "path #{i}: #{tok}"
      end

      refute out =~ canary, "path #{i}"
      # what the workflow step copies into the step summary is a subset of this output
      log_file = Path.join(System.tmp_dir!(), "qa_chain_#{i}.log")
      File.write!(log_file, out)
      on_exit(fn -> File.rm(log_file) end)
      {summary, _} = System.cmd("grep", ["-E", "QA tenants behind the build|REFUSED", log_file])
      refute summary =~ canary

      for {_var, tok} <- extra, tok != "" do
        refute summary =~ tok, "summary path #{i}: #{tok}"
        refute File.read!(log_file) =~ "Bearer " <> tok
      end
    end
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
    slugs = for l <- lines, l != "", do: l |> String.split() |> hd()
    for t <- ~w(qoimeks-qa2 sss-rehearsal2), do: assert(t in slugs)
    for t <- ~w(sss-rehearsal qoimeks-qa qoimeks-client1-qa), do: refute(t in slugs)
  end
end
