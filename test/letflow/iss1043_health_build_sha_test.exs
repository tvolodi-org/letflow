defmodule Letflow.Iss1043HealthBuildShaTest do
  @moduledoc """
  ISS-1043 (GH #2384, spec `test/specs/ISS-1043.md`): the public `GET /health` reports
  the git commit SHA the release was built from, as `sha`.

  The chain under test, end to end in this repository:

    1. `deploy/redeploy-qa.sh` / `deploy/redeploy-test.sh` pass
       `--build-arg GIT_SHA="$(git rev-parse HEAD)"` to `docker build` (static check);
    2. `deploy/Dockerfile`'s runtime stage turns it into `ENV LETFLOW_BUILD_SHA` (static);
    3. `config/runtime.exs` normalises `LETFLOW_BUILD_SHA` into `config :letflow, :build_sha`
       (evaluated for real with `Config.Reader`);
    4. `Letflow.Router`'s `GET /health` returns `%{status: "ok", sha: ...}` (Plug.Test).

  `async: false`: tests put `:build_sha` into the global application environment and
  `LETFLOW_BUILD_SHA` into the OS environment; both are restored in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  doctest Letflow.BuildInfo

  @opts Letflow.Router.init([])
  @full_sha "e60c9cb9dd986745644a08244d426457c33423fd"

  defp health do
    conn = conn(:get, "/health") |> Letflow.Router.call(@opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp put_build_sha(value) do
    previous = Application.fetch_env(:letflow, :build_sha)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :build_sha, v)
        :error -> Application.delete_env(:letflow, :build_sha)
      end
    end)

    case value do
      :unset -> Application.delete_env(:letflow, :build_sha)
      v -> Application.put_env(:letflow, :build_sha, v)
    end
  end

  describe "GET /health reports the build SHA" do
    test "sha is the configured build SHA, status is still exactly ok, no other key" do
      put_build_sha(@full_sha)

      assert {200, body} = health()
      assert body == %{"status" => "ok", "sha" => @full_sha}
      assert body |> Map.keys() |> Enum.sort() == ["sha", "status"]
    end

    test "a short (7-hex) SHA is reported as configured" do
      put_build_sha("e60c9cb")
      assert {200, %{"status" => "ok", "sha" => "e60c9cb"}} = health()
    end

    test "sha is JSON null when no build SHA is configured" do
      put_build_sha(:unset)

      assert {200, body} = health()
      assert body == %{"status" => "ok", "sha" => nil}
      # The key is present (null), not dropped, so callers can tell "no SHA" apart
      # from an old build that predates the field.
      assert Map.has_key?(body, "sha")
    end

    test "sha is JSON null when the app env holds a malformed value (re-normalised on read)" do
      put_build_sha("not a sha; DROP TABLE tenants")
      assert {200, %{"status" => "ok", "sha" => nil}} = health()

      put_build_sha(String.upcase(@full_sha))
      assert {200, %{"status" => "ok", "sha" => nil}} = health()
    end
  end

  describe "Letflow.BuildInfo.normalize_sha/1" do
    test "accepts 7..40 lowercase hex characters" do
      assert Letflow.BuildInfo.normalize_sha(@full_sha) == @full_sha
      assert Letflow.BuildInfo.normalize_sha("e60c9cb") == "e60c9cb"

      assert Letflow.BuildInfo.normalize_sha(String.duplicate("a", 40)) ==
               String.duplicate("a", 40)
    end

    test "trims surrounding whitespace (e.g. a trailing newline from a shell)" do
      assert Letflow.BuildInfo.normalize_sha("  #{@full_sha}\n") == @full_sha
      assert Letflow.BuildInfo.normalize_sha("e60c9cb\r\n") == "e60c9cb"
    end

    test "rejects everything else as nil" do
      for bad <- [
            nil,
            "",
            "   ",
            "e60c9c",
            String.duplicate("a", 41),
            String.upcase(@full_sha),
            "E60C9CB",
            "g60c9cb",
            "v1.2.3",
            "e60c9cb-dirty",
            "e60c 9cb",
            "e60c9cb\nfoo",
            "unknown",
            123,
            :e60c9cb,
            ~c"e60c9cb"
          ] do
        assert Letflow.BuildInfo.normalize_sha(bad) == nil, "expected nil for #{inspect(bad)}"
      end
    end
  end

  describe "config/runtime.exs wires LETFLOW_BUILD_SHA into :build_sha" do
    defp read_runtime_build_sha(env_value) do
      previous = System.get_env("LETFLOW_BUILD_SHA")

      try do
        case env_value do
          nil -> System.delete_env("LETFLOW_BUILD_SHA")
          v -> System.put_env("LETFLOW_BUILD_SHA", v)
        end

        "config/runtime.exs"
        |> Config.Reader.read!(env: :test, target: :host)
        |> Keyword.fetch!(:letflow)
        |> Keyword.fetch(:build_sha)
      after
        if previous,
          do: System.put_env("LETFLOW_BUILD_SHA", previous),
          else: System.delete_env("LETFLOW_BUILD_SHA")
      end
    end

    test "a valid SHA is stored as is" do
      assert read_runtime_build_sha(@full_sha) == {:ok, @full_sha}
    end

    test "unset, empty and junk values are stored as nil" do
      assert read_runtime_build_sha(nil) == {:ok, nil}
      assert read_runtime_build_sha("") == {:ok, nil}
      assert read_runtime_build_sha("not-a-sha") == {:ok, nil}
    end
  end

  describe "the build pipeline bakes the SHA in (static file checks)" do
    defp lines(path), do: path |> File.read!() |> String.split(~r/\r?\n/)

    defp active_lines(path),
      do: path |> lines() |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))

    test "deploy/Dockerfile declares ARG GIT_SHA and ENV LETFLOW_BUILD_SHA in the runtime stage" do
      active = active_lines("deploy/Dockerfile")

      runtime_from =
        Enum.find_index(active, &Regex.match?(~r/^FROM\s+\S+\s+AS\s+runtime\s*$/i, &1))

      assert is_integer(runtime_from), "no `FROM ... AS runtime` stage in deploy/Dockerfile"
      runtime_stage = Enum.drop(active, runtime_from + 1)
      # The runtime stage is the last one: no further FROM may follow it.
      refute Enum.any?(runtime_stage, &String.starts_with?(&1, "FROM "))

      arg_at = Enum.find_index(runtime_stage, &Regex.match?(~r/^ARG\s+GIT_SHA(=\S*)?\s*$/, &1))

      env_at =
        Enum.find_index(
          runtime_stage,
          &Regex.match?(~r/^ENV\s+LETFLOW_BUILD_SHA=\$\{GIT_SHA\}\s*$/, &1)
        )

      assert is_integer(arg_at), "ARG GIT_SHA missing from the runtime stage"
      assert is_integer(env_at), "ENV LETFLOW_BUILD_SHA=${GIT_SHA} missing from the runtime stage"
      assert arg_at < env_at

      # Placed after every apt-get RUN, so a new commit does not bust those cached layers.
      last_apt =
        runtime_stage
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} -> line =~ "apt-get" end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.max(fn -> -1 end)

      assert last_apt >= 0
      assert arg_at > last_apt
    end

    for script <- ["deploy/redeploy-qa.sh", "deploy/redeploy-test.sh"] do
      test "#{script} passes the full HEAD SHA as --build-arg GIT_SHA to docker build" do
        builds = unquote(script) |> active_lines() |> Enum.filter(&(&1 =~ ~r/^\s*docker build\b/))

        assert builds != [], "no docker build line in #{unquote(script)}"

        for build <- builds do
          assert build =~ ~S|--build-arg GIT_SHA="$(git rev-parse HEAD)"|,
                 "#{unquote(script)}: #{build}"

          refute build =~ "--short", "the baked SHA must be the full commit"
        end
      end
    end

    test "scripts/uat_preflight.sh probes /health and accepts the `sha` key" do
      src = File.read!("scripts/uat_preflight.sh")
      assert src =~ ~s|cands = [("/health", None)]|
      assert src =~ ~r/for k in \("sha",/
    end
  end
end
