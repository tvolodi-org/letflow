defmodule Letflow.Scripts.UatPreflightDeployedShaTest do
  @moduledoc """
  GH #3044 regression: `scripts/uat_preflight.sh`'s `deployed_sha` check must report OK when the
  deployed build differs from the expected SHA only in non-runtime paths (docs/, test/, handoffs/,
  .github/, scripts/uat_*, *.md, web test files, and a mix.exs change confined to the
  `test_ignore_filters` entry). Any runtime path (lib/, deploy/, config/, web/ sources, ...) keeps
  the GAP. An unknown deployed SHA, or a git failure, never reports OK.

  Each test builds a throwaway git repo with two commits (deployed, expected) and a copy of the
  real script inside it, so the script's REPO_ROOT (its parent directory) is that repo. A local
  stub HTTP server answers `GET /health` with `{"sha": ...}`. Needs bash + python + git; on
  Windows set `UAT_PF_BASH` to git-bash, same as the sibling `uat_preflight_*_test.exs` files.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/uat_preflight.sh", __DIR__)
  @unknown_sha "1234567890abcdef1234567890abcdef12345678"

  @mix_exs_base """
  defmodule Letflow.MixProject do
    use Mix.Project

    def project do
      [
        app: :letflow,
        version: "0.1.0",
        elixirc_paths: elixirc_paths(Mix.env()),
        deps: deps(),
        test_ignore_filters: [
          ~r{test/support/},
          ~r{test/legacy/}
        ]
      ]
    end

    defp elixirc_paths(_), do: ["lib"]
    defp deps, do: []
  end
  """

  # The #3044 shape: no test_ignore_filters entry on the deployed side.
  @mix_exs_no_filters """
  defmodule Letflow.MixProject do
    use Mix.Project

    def project do
      [
        app: :letflow,
        version: "0.1.0",
        elixirc_paths: elixirc_paths(Mix.env()),
        deps: deps()
      ]
    end

    defp elixirc_paths(_), do: ["lib"]
    defp deps, do: []
  end
  """

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp git!(dir, args) do
    {out, status} =
      System.cmd(
        "git",
        [
          "-C",
          dir,
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.com",
          "-c",
          "commit.gpgsign=false" | args
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    String.trim(out)
  end

  # `files` maps repo-relative paths to contents; a nil content deletes the path.
  # Returns the full SHA of the new commit.
  defp commit(dir, files, message) do
    Enum.each(files, fn
      {path, nil} ->
        File.rm!(Path.join(dir, path))

      {path, content} ->
        File.mkdir_p!(Path.dirname(Path.join(dir, path)))
        File.write!(Path.join(dir, path), content)
    end)

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  # Builds the repo: the base commit (the deployed build) and the next commit, given by
  # `changes`, which is the expected build. Returns {deployed_sha, expected_sha}.
  defp build_repo(tmp, changes, base_mix_exs \\ @mix_exs_base) do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, "scripts"))
    File.cp!(@script, Path.join(repo, "scripts/uat_preflight.sh"))
    git!(repo, ["init", "-q"])

    base = %{
      "mix.exs" => base_mix_exs,
      "lib/app.ex" => "defmodule App do\nend\n",
      "lib/rename_me.ex" => "defmodule RenameMe do\nend\n",
      "docs/guide.md" => "# guide\n",
      "deploy/Dockerfile" => "FROM elixir\n",
      "config/config.exs" => "import Config\n",
      "web/src/app.tsx" => "export const app = 1;\n",
      "test/app_test.exs" => "defmodule AppTest do\nend\n",
      "scripts/uat_seed.sh" => "#!/bin/bash\n",
      "README.md" => "# readme\n"
    }

    deployed = commit(repo, base, "deployed")
    expected = commit(repo, changes, "expected")
    {deployed, expected}
  end

  # Serves `GET /health` with `{"sha": sha}` and 404 for everything else.
  defp start_stub(sha) do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    pid = spawn_link(fn -> accept_loop(lsock, sha) end)

    on_exit(fn ->
      :gen_tcp.close(lsock)
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(lsock, sha) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn(fn -> serve(sock, sha) end)
        accept_loop(lsock, sha)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, sha) do
    request = read_request(sock, "")

    {status, body} =
      if String.starts_with?(request, "GET /health"),
        do: {"200 OK", ~s({"sha": "#{sha}"})},
        else: {"404 Not Found", ""}

    :gen_tcp.send(
      sock,
      "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
    )

    :gen_tcp.close(sock)
  end

  defp read_request(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> read_request(sock, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  # Runs the copied script in `tmp/repo` against a stub that reports `deployed_sha_reported`
  # as the deployed build, expecting `expected_sha`. Returns the deployed_sha report line.
  defp run_deployed_sha(tmp, deployed_sha_reported, expected_sha) do
    scen_dir = Path.join(tmp, "scenarios/swiftroute")
    File.mkdir_p!(scen_dir)

    File.write!(Path.join(scen_dir, "t.yaml"), """
    id: t
    company_id: swiftroute
    actors:
      dispatcher: actor-swiftroute-lena
    """)

    cred = Path.join(tmp, "cred.sh")
    File.write!(cred, "#!/bin/bash\nexit 0\n")
    base = start_stub(deployed_sha_reported)

    script = Path.join([tmp, "repo", "scripts", "uat_preflight.sh"])

    {out, _} =
      System.cmd(
        launcher(),
        [
          script,
          "--base-url",
          base,
          "--environment",
          "qa",
          "--credential-source",
          cred,
          "--credential-protocol",
          "qa-uat-env",
          "--scenarios",
          Path.join(tmp, "scenarios"),
          "--sha",
          expected_sha,
          "--idp-url",
          base,
          "--out",
          Path.join(tmp, "out.json")
        ],
        stderr_to_stdout: true
      )

    assert out =~ "UAT PREFLIGHT  environment=qa",
           "preflight script did not reach its report (launcher=#{inspect(launcher())}). " <>
             "First 500 chars of output: #{String.slice(out, 0, 500)}. " <>
             "Set UAT_PF_BASH to a real bash (git-bash on Windows)."

    # The GLOBAL CHECKS table row: "deployed_sha  <STATUS>  <reason>". OK rows only appear there.
    out
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "deployed_sha "))
    |> String.trim()
  end

  defp status(line), do: line |> String.split() |> Enum.at(1)

  test "docs, test, handoffs, .github, scripts/uat_* and *.md changes only: OK", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{
        "docs/guide.md" => "# guide, revised\n",
        "test/app_test.exs" => "defmodule AppTest do\n  use ExUnit.Case\nend\n",
        "handoffs/h-1.md" => "# handoff\n",
        ".github/workflows/ci.yml" => "name: ci\n",
        "scripts/uat_seed.sh" => "#!/bin/bash\necho seed\n",
        "README.md" => "# readme, revised\n",
        "web/src/app.test.tsx" => "test('x', () => {});\n"
      })

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "OK"

    assert line =~
             "deployed #{String.slice(deployed, 0, 12)}, expected #{String.slice(expected, 0, 12)}, no runtime diff"
  end

  test "a UAT seed script under scripts/ is non-runtime: OK (GH #3044 shape)", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{"scripts/seed_uat_email_verified.sh" => "#!/bin/bash\necho seed\n"})

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "OK"
  end

  test "any other script under scripts/ is runtime: GAP", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{"scripts/deploy_qa.sh" => "#!/bin/bash\necho deploy\n"})

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "GAP"
    assert line =~ "first runtime path scripts/deploy_qa.sh"
  end

  test "a lib/ change is a runtime diff: GAP names the first runtime path", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{
        "docs/guide.md" => "# guide, revised\n",
        "lib/app.ex" => "defmodule App do\n  def x, do: 1\nend\n"
      })

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "GAP"
    assert line =~ "first runtime path lib/app.ex"
  end

  test "a deploy/Dockerfile-only change is a runtime diff: GAP", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{"deploy/Dockerfile" => "FROM elixir:1.20\n"})

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "GAP"
    assert line =~ "first runtime path deploy/Dockerfile"
  end

  test "a mix.exs change confined to test_ignore_filters is non-runtime: OK", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{
        "mix.exs" =>
          String.replace(
            @mix_exs_base,
            "~r{test/legacy/}\n",
            "~r{test/legacy/},\n        ~r{test/fixtures/}\n"
          )
      })

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "OK"
    assert line =~ "no runtime diff"
  end

  test "a mix.exs change that adds a test_ignore_filters entry with its comment is non-runtime: OK " <>
         "(GH #3044 shape)",
       %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(
        tmp,
        %{
          "mix.exs" =>
            String.replace(
              @mix_exs_no_filters,
              "      deps: deps()\n",
              "      # Shared fixtures are loaded by Code.require_file/2, not test files.\n" <>
                "      test_ignore_filters: [~r/_fixture\\.exs$/],\n" <>
                "      deps: deps()\n"
            )
        },
        @mix_exs_no_filters
      )

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "OK"
    assert line =~ "no runtime diff"
  end

  test "a mix.exs change outside test_ignore_filters is runtime: GAP", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{
        "mix.exs" =>
          String.replace(
            @mix_exs_base,
            ~s(version: "0.1.0"),
            ~s(version: "0.2.0")
          )
      })

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "GAP"
    assert line =~ "first runtime path mix.exs"
  end

  test "a mix.exs change that also edits test_ignore_filters is still runtime: GAP", %{
    tmp_dir: tmp
  } do
    {deployed, expected} =
      build_repo(tmp, %{
        "mix.exs" =>
          @mix_exs_base
          |> String.replace(
            "~r{test/legacy/}\n",
            "~r{test/legacy/},\n        ~r{test/fixtures/}\n"
          )
          |> String.replace("deps: deps()", "deps: [{:jason, \"~> 1.4\"}]")
      })

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "GAP"
    assert line =~ "first runtime path mix.exs"
  end

  test "a rename out of lib/ is still a runtime diff: GAP (rename detection off)", %{tmp_dir: tmp} do
    {deployed, expected} =
      build_repo(tmp, %{
        "lib/rename_me.ex" => nil,
        "docs/rename_me.md" => "defmodule RenameMe do\nend\n"
      })

    line = run_deployed_sha(tmp, deployed, expected)

    assert status(line) == "GAP"
    assert line =~ "first runtime path lib/rename_me.ex"
  end

  test "a deployed SHA unknown to the local git is never OK", %{tmp_dir: tmp} do
    {_deployed, expected} = build_repo(tmp, %{"docs/guide.md" => "# guide, revised\n"})

    line = run_deployed_sha(tmp, @unknown_sha, expected)

    assert status(line) in ["GAP", "UNKNOWN"]
  end

  test "an exact match is OK without a diff", %{tmp_dir: tmp} do
    {_deployed, expected} =
      build_repo(tmp, %{"lib/app.ex" => "defmodule App do\n  def x, do: 1\nend\n"})

    line = run_deployed_sha(tmp, expected, expected)

    assert status(line) == "OK"
    assert line =~ "deployed #{String.slice(expected, 0, 12)} == origin/main"
  end
end
