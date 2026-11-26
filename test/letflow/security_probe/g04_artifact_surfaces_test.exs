defmodule Letflow.SecurityProbe.G04ArtifactSurfacesTest do
  @moduledoc """
  G-04, artifact surfaces (design cases C-30..C-33; surfaces S8 UAT run artifacts and
  S14 shell script output). No database.

  C-30..C-32: this file writes `cases.json` from the ONE Elixir canary generator, runs
  `scripts/uat/tests/test_g04_canary.py` (the Python side plants and writes, it never
  detects), then scans every file under the run directories (S8) for each canary.
  C-33: every tracked `*.sh` that invokes `curl` is DERIVED from the tree
  (`git ls-files '*.sh'`), run with a PATH stub `curl` that exits 22 and env canaries
  for every `*_URL`/`*_TOKEN` name the script reads; its stdout, stderr and any file it
  wrote under a temp HOME are scanned (S14). Every derived script needs a row in
  `test/fixtures/security_probes/g04/shell_invocations.txt`; a derived script with no
  row, or a row whose script is gone, fails the probe.

  Non-vacuity: seeded S8 and S14 cases plant a canary through the same collectors.
  Class table: `docs/security-probes/G-04.md`.
  """

  use ExUnit.Case, async: false

  @moduletag :security_probe
  @moduletag :unit
  @moduletag probe_cost_s: 4

  alias Letflow.SecurityProbe.G04Canary, as: G

  @exceptions Path.expand("../../fixtures/security_probes/g04/exceptions.txt", __DIR__)
  @invocations Path.expand("../../fixtures/security_probes/g04/shell_invocations.txt", __DIR__)
  @root Path.expand("../../..", __DIR__)

  setup do
    {:ok, rows} = G.load_exceptions(@exceptions)
    tmp = Path.join(System.tmp_dir!(), "g04-art-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, rows: rows, tmp: tmp}
  end

  # --- collectors ------------------------------------------------------------------

  # Every regular file below `dir`, dotfiles included (a plain walk: this file reads
  # temp directories, not a source tree, so it carries no recursive glob).
  defp files_under(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn n ->
          path = Path.join(dir, n)
          if File.dir?(path), do: files_under(path), else: [path]
        end)

      _ ->
        []
    end
  end

  # S8: every file under a run directory, read recursively (zip/PDF handled by the scan).
  defp run_artifacts(dir) do
    for path <- files_under(dir) do
      {"S8", Path.relative_to(path, dir), "any", File.read!(path)}
    end
  end

  # S14: stdout+stderr of a script run and every file it wrote under its temp HOME.
  defp shell_items(label, output, home) do
    [{"S14", "#{label} output", "any", output}] ++
      for path <- files_under(home) do
        {"S14", "#{label} file #{Path.relative_to(path, home)}", "any", File.read!(path)}
      end
  end

  defp verdict(items, canaries, rows) do
    G.verdict_cases(items, canaries, rows)
  end

  defp assert_clean(v) do
    assert v.unlisted == [], "G-04 leak(s): #{inspect(v.unlisted, pretty: true)}"
    assert v.stale == [], "stale baseline row(s): #{inspect(v.stale)}"
  end

  # --- seeded failing cases (non-vacuity) --------------------------------------------

  describe "seeded: a canary written straight into each surface is caught" do
    test "S8: a run artifact (plain, percent-encoded, in a nested zip member)", ctx do
      c = G.new("SEED-S8", :email)
      dir = Path.join(ctx.tmp, "seed-run")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "run.jsonl"),
        ~s({"error":"no mail to #{URI.encode_www_form(c.value)}"})
      )

      {:ok, {_, zip}} = :zip.create(~c"a.zip", [{~c"inner.txt", c.value}], [:memory])
      File.write!(Path.join(dir, "attach.zip"), zip)

      hits = G.scan(run_artifacts(dir), c)
      assert Enum.sort(Enum.map(hits, & &1.locator)) == ["attach.zip", "run.jsonl"]
      assert length(G.verdict(hits, ctx.rows).unlisted) == 2
    end

    test "S14: stderr of a script and a file it wrote under HOME", ctx do
      c = G.new("SEED-S14", :credential_url, port: 1)
      home = Path.join(ctx.tmp, "seed-home")
      File.mkdir_p!(home)
      File.write!(Path.join(home, ".curl_log"), c.value)
      hits = G.scan(shell_items("seed", "curl: (22) " <> c.value, home), c)
      assert Enum.sort(Enum.map(hits, & &1.locator)) == ["seed file .curl_log", "seed output"]
    end
  end

  # --- C-30..C-32: the UAT runner through the Python fake -----------------------------

  test "C-30/C-31/C-32: the runner's artifacts hold no canary", ctx do
    c30 = G.new("C-30", :email)
    c31 = G.new("C-31", :credential_url, port: 1)
    c32e = G.new("C-32", :email, salt: "email")
    c32n = G.new("C-32", :name)

    cases = %{
      "C-30" => %{"email" => c30.value},
      "C-31" => %{"credential_url" => c31.value},
      "C-32" => %{"email" => c32e.value, "name" => c32n.value}
    }

    cases_file = Path.join(ctx.tmp, "cases.json")
    out = Path.join(ctx.tmp, "out")
    File.mkdir_p!(out)
    File.write!(cases_file, Jason.encode!(cases))

    {log, code} =
      System.cmd(
        "python3",
        [
          "-I",
          "-B",
          "-m",
          "unittest",
          "discover",
          "-s",
          "scripts/uat/tests",
          "-p",
          "test_g04_canary.py"
        ],
        cd: @root,
        env: [{"G04_CASES", cases_file}, {"G04_OUT", out}],
        stderr_to_stdout: true
      )

    assert code == 0, "the Python side failed: #{log}"

    for id <- ["C-30", "C-31", "C-32"] do
      assert File.regular?(Path.join([out, id, "run.jsonl"])), "no run directory for #{id}"
    end

    # non-vacuity: the inventory is not empty, and each case wrote a log
    all = for id <- ["C-30", "C-31", "C-32"], item <- run_artifacts(Path.join(out, id)), do: item
    assert length(all) >= 6

    v = verdict(all, [c30, c31, c32e, c32n], ctx.rows)
    assert_clean(v)
    # E-07 excuses the evidence line that names the record (name only)
    assert Enum.all?(v.excused, &(&1.kind == :name and &1.case_id == "C-32"))
  end

  # --- C-33: every shell script that invokes curl --------------------------------------

  defp derived_scripts do
    {out, 0} = System.cmd("git", ["ls-files", "*.sh"], cd: @root)

    out
    |> String.split("\n", trim: true)
    |> Enum.filter(fn rel ->
      File.read!(Path.join(@root, rel)) =~ ~r/(^|[^A-Za-z_])curl[[:space:]]/m
    end)
    |> Enum.sort()
  end

  defp invocation_rows do
    @invocations
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
    |> Map.new(fn line ->
      [script, argv, mode] = line |> String.split("|") |> Enum.map(&String.trim/1)
      {script, %{argv: String.split(argv, " ", trim: true), mode: mode}}
    end)
  end

  test "C-33: the derived shell scripts are all classified (no row missing, none stale)" do
    derived = derived_scripts()
    rows = invocation_rows()

    assert length(derived) >= 20,
           "the derivation found #{length(derived)} scripts: it looks vacuous"

    assert derived -- Map.keys(rows) == [],
           "unclassified script(s): #{inspect(derived -- Map.keys(rows))}"

    assert Map.keys(rows) -- derived == [], "stale row(s): #{inspect(Map.keys(rows) -- derived)}"
  end

  test "C-33: each runnable script, run with a failing curl stub and env canaries, leaks nothing",
       ctx do
    stub = Path.join(ctx.tmp, "bin")
    File.mkdir_p!(stub)
    curl_log = Path.join(ctx.tmp, "curl.log")

    File.write!(Path.join(stub, "curl"), """
    #!/bin/sh
    echo "curl called" >> "#{curl_log}"
    echo "curl: (22) The requested URL returned error: 500" >&2
    exit 22
    """)

    File.chmod!(Path.join(stub, "curl"), 0o755)
    rows = invocation_rows()
    runnable = for {script, %{mode: "run"} = r} <- rows, do: {script, r}
    assert runnable != [], "no runnable script: C-33 would be vacuous"

    reached =
      for {script, r} <- Enum.sort(runnable), reduce: 0 do
        reached ->
          src = File.read!(Path.join(@root, script))

          names =
            Regex.scan(~r/\$\{?([A-Z][A-Z0-9_]*(?:URL|TOKEN))\b/, src, capture: :all_but_first)
            |> List.flatten()
            |> Enum.uniq()

          id = "C-33/" <> script
          url = G.new(id, :credential_url, port: 1)
          tok = G.new(id, :token, salt: "token")
          Process.put(:g04_canaries, [url, tok | Process.get(:g04_canaries, [])])

          env =
            for n <- names do
              {n, if(String.ends_with?(n, "TOKEN"), do: tok.value, else: url.value)}
            end

          home = Path.join(ctx.tmp, "home-" <> Base.url_encode64(script, padding: false))
          File.mkdir_p!(home)
          File.rm(curl_log)

          {output, _code} =
            System.cmd("timeout", ["5", "bash", Path.join(@root, script) | r.argv],
              cd: @root,
              env:
                env ++
                  [
                    {"HOME", home},
                    {"TMPDIR", home},
                    {"PATH", stub <> ":" <> System.get_env("PATH")}
                  ],
              stderr_to_stdout: true
            )

          items = shell_items(script, output, home)
          Process.put(:g04_items, items ++ Process.get(:g04_items, []))
          if File.exists?(curl_log), do: reached + 1, else: reached
      end

    # one canary pair per script (case id `C-33/<script>`): a baseline row names its script
    assert_clean(verdict(Process.get(:g04_items, []), Process.get(:g04_canaries, []), ctx.rows))

    # non-vacuity: a script that never reaches curl proves nothing; some must
    assert reached >= 1, "no runnable script reached curl: the stub proved nothing"
  end
end
