defmodule Letflow.Scripts.OssAuditTest do
  @moduledoc """
  T-1597: `scripts/oss_audit/` is a read-only scanner of the tracked tree and the full git history.
  Every test runs the real script on a throw-away git repository in `tmp_dir`. Fake secrets are built
  by concatenation at run time, so no secret-shaped literal sits in this file (the repo's own guards
  scan it, and the scanner excludes it by path).

  Needs bash, git and python3.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/oss_audit/oss_audit.sh")
  @scanner Path.join(@root, "scripts/oss_audit/scanner.py")
  @rules Path.join(@root, "scripts/oss_audit/rules.py")
  @report Path.expand("docs/open-source/audit-report.md", @root)

  # fake values, mixed characters, built at run time
  defp aws_key, do: "AKIA" <> "Q7ZX2MWBN4HD5TRK"
  defp pw_value, do: "Zq8vR2mT" <> "n4XwK9pL"
  defp gh_token, do: "ghp_" <> String.duplicate("aB3dE5gH7j", 4)
  defp ant_key, do: "sk-ant-" <> "api03Kd82nQwz71LmXv9RtYu4HbGf5"
  defp jwt, do: "eyJ" <> "hbGciOiJIUzI1" <> ".eyJ" <> "zdWIiOiIxMjM0NTY3" <> ".sIgNaTuRe12"
  defp pem, do: "-----BEGIN " <> "RSA PRIVATE KEY-----"

  defp git(dir, args, opts \\ []) do
    {out, code} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false"] ++
          args,
        [cd: dir, stderr_to_stdout: true] ++ opts
      )

    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    String.trim(out)
  end

  defp new_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "main"])
    repo
  end

  defp commit_file(repo, rel, content, msg \\ "c") do
    path = Path.join(repo, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", msg])
    git(repo, ["rev-parse", "HEAD"])
  end

  defp run(repo, args \\ [], env \\ []) do
    {out, code} =
      System.cmd("bash", [@script, "--repo", repo] ++ args,
        stderr_to_stdout: false,
        env: env
      )

    {out, code}
  end

  defp rows(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "PARTIAL"))
    |> Enum.map(fn l ->
      [scope, path, commit, rule, sev, hint, seen, in_head] = String.split(l, "\t")

      %{
        scope: scope,
        path: path,
        commit: commit,
        rule: rule,
        sev: sev,
        hint: hint,
        seen: seen,
        in_head: in_head
      }
    end)
  end

  defp has_rule?(out, rule, path),
    do: Enum.any?(rows(out), &(&1.rule == rule and &1.path == path))

  # ---- O1

  test "O1 scanner and rules import only the standard library" do
    code = """
    import ast, sys
    bad = []
    for p in sys.argv[1:]:
        for n in ast.walk(ast.parse(open(p).read())):
            names = []
            if isinstance(n, ast.Import): names = [a.name for a in n.names]
            if isinstance(n, ast.ImportFrom) and n.level == 0: names = [n.module]
            for m in names:
                if m.split('.')[0] not in sys.stdlib_module_names and m != 'rules': bad.append(m)
    print(','.join(bad))
    """

    {out, 0} = System.cmd("python3", ["-I", "-c", code, @scanner, @rules])
    assert String.trim(out) == ""
  end

  # ---- O2 / O3

  test "O2 tree scan finds a tracked secret-shaped file with its path", %{tmp_dir: dir} do
    repo = new_repo(dir)
    commit_file(repo, "conf/cloud.txt", "key " <> aws_key() <> "\n")
    {out, 0} = run(repo, ["--tree"])

    assert [%{scope: "tree", path: "conf/cloud.txt", rule: "S02", sev: "C", commit: "HEAD"}] =
             rows(out)

    assert out =~ "# coverage\tCOMPLETE"
  end

  test "O3 history finds a secret deleted on a side branch, in_head=no", %{tmp_dir: dir} do
    repo = new_repo(dir)
    commit_file(repo, "a.txt", "one\n")
    git(repo, ["checkout", "-q", "-b", "side"])
    sha = commit_file(repo, "leak.txt", "token " <> gh_token() <> "\n")
    commit_file(repo, "leak.txt", "clean\n")
    git(repo, ["checkout", "-q", "main"])

    {out, 0} = run(repo)
    hit = Enum.find(rows(out), &(&1.rule == "S09"))
    assert %{scope: "history", path: "leak.txt", in_head: "no"} = hit
    assert hit.commit == String.slice(sha, 0, 12)
    assert out =~ "COMPLETE"
  end

  # ---- O4 / O4b deadline

  test "O4 a zero budget ends partial with exit 3", %{tmp_dir: dir} do
    repo = new_repo(dir)
    commit_file(repo, "a.txt", "one\n")
    {out, code} = run(repo, ["--budget-seconds", "0"])
    assert code == 3
    assert out =~ "PARTIAL"
    refute out =~ "COMPLETE"
  end

  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not (stat |> String.split(") ") |> List.last() |> String.starts_with?("Z"))
      _ -> false
    end
  end

  defp wait_dead(pid, tries \\ 30) do
    cond do
      not alive?(pid) -> true
      tries == 0 -> false
      true -> Process.sleep(100) && wait_dead(pid, tries - 1)
    end
  end

  test "O4b a stalled git producer is killed with its child and the run ends partial", %{
    tmp_dir: dir
  } do
    repo = new_repo(dir)
    commit_file(repo, "a.txt", "one\n")
    shim = Path.join(dir, "git_shim.sh")
    pids = Path.join(dir, "pids")
    File.mkdir_p!(pids)

    File.write!(shim, """
    #!/usr/bin/env bash
    case " $* " in
      *" log "*) ;;
      *) exec git "$@" ;;
    esac
    echo "C 0123456789012345678901234567890123456789 1 "
    sleep 60 &
    echo $! > #{pids}/sleep.pid
    echo $$ > #{pids}/shim.pid
    wait
    """)

    File.chmod!(shim, 0o755)
    t0 = System.monotonic_time(:second)
    {out, code} = run(repo, ["--history", "--budget-seconds", "2"], [{"OSS_AUDIT_GIT", shim}])
    assert System.monotonic_time(:second) - t0 < 15
    assert code == 3
    assert out =~ "PARTIAL"

    for f <- ["shim.pid", "sleep.pid"] do
      pid = pids |> Path.join(f) |> File.read!() |> String.trim()
      assert wait_dead(pid), "#{f} #{pid} still alive"
    end
  end

  # ---- O5 / O6 masking

  test "O5 output never contains the secret nor an e-mail local part", %{tmp_dir: dir} do
    repo = new_repo(dir)

    fixtures = [
      {"k.env", "PRIVATE_X=1\n" <> pem() <> "\n", nil},
      {"aws.txt", aws_key() <> "\n", aws_key()},
      {"kc.env", "KEYCLOAK_ADMIN_" <> "PASSWORD=" <> pw_value() <> "\n", pw_value()},
      {"ant.txt", ant_key() <> "\n", ant_key()},
      {"gh.txt", gh_token() <> "\n", gh_token()},
      {"db.txt", "postgres://app:" <> pw_value() <> "@db.corp-internal.net/x\n", pw_value()},
      {"pw.env", "DB_PASSWORD=" <> pw_value() <> "\n", pw_value()},
      {"jwt.txt", jwt() <> "\n", jwt()}
    ]

    for {f, c, _} <- fixtures, do: commit_file(repo, f, c)
    commit_file(repo, "mail.md", "contact jane.roe" <> "@acme-corp.org today\n")
    {out, 0} = run(repo)

    for {_f, _c, v} <- fixtures, v != nil do
      for i <- 0..(String.length(v) - 5) do
        refute String.contains?(out, String.slice(v, i, 5)),
               "5 chars of a value leaked: offset #{i}"
      end
    end

    refute out =~ "jane.roe"
    assert out =~ "email:acme-corp.org"
    assert Enum.all?(rows(out), &(String.length(&1.hint) <= 30))
    refute out =~ ~r/\tid=/
  end

  test "O6 a rule that raises is counted by id and never echoes the line" do
    code = """
    import sys
    sys.path.insert(0, sys.argv[1])
    import scanner as S, rules as R
    class Boom:
        def finditer(self, line): raise ValueError(line)
    R.RULES[0]['rx'] = Boom()
    line = 'LINE_WITH_MARKER_' + 'XYZZY private key'
    list(S.scan_text(line, set(), False))
    print(dict(S.STATE['rule_errors']))
    """

    {out, 0} = System.cmd("python3", ["-I", "-c", code, Path.dirname(@scanner)])
    assert out =~ "S01"
    refute out =~ "XYZZY"
  end

  # ---- O7 / O8 rules

  test "O7 one fixture line per rule fires that rule", %{tmp_dir: dir} do
    repo = new_repo(dir)

    fixtures = [
      {"S01", "a.txt", pem()},
      {"S02", "b.txt", aws_key()},
      {"S03", "c.txt", "AIza" <> String.duplicate("Ab3dE5gH7j", 3) <> "Ab3dE"},
      {"S04", "d.txt", "AccountKey=" <> "Qm9vZm9vYmFyMTIzNDU2Nzg5"},
      {"S05", "e.env", "HCLOUD_" <> "TOKEN=" <> pw_value()},
      {"S06", "f.env", "CLOUDFLARE_API_" <> "TOKEN=" <> pw_value()},
      {"S07", "g.env", "KEYCLOAK_ADMIN_" <> "PASSWORD=" <> pw_value()},
      {"S08", "h.txt", ant_key()},
      {"S09", "i.txt", gh_token()},
      {"S10", "j.txt", "xox" <> "b-123456789012-abcdefghij"},
      {"S11", "k.txt", jwt()},
      {"S12", "l.txt", "postgres://app:" <> pw_value() <> "@db.corp-internal.net/x"},
      {"S13", "m.env", "APP_SECRET_KEY=" <> pw_value()},
      {"P01", "n.md", "write to jane.roe" <> "@acme-corp.org"},
      {"P02", "o.md", "call +7 701 123 45 67"},
      {"I01", "p.md", "server at 46.4.5.6 now"},
      {"I03", "q.md", "see demo.letflow.ai-dala.com"},
      {"N01", "r.md", "the Qoimeks pilot"}
    ]

    for {_r, f, c} <- fixtures, do: commit_file(repo, f, c <> "\n")
    {out, 0} = run(repo, ["--tree"])

    for {r, f, _c} <- fixtures do
      assert has_rule?(out, r, f), "rule #{r} did not fire on #{f}"
    end
  end

  test "O8 placeholders, reserved domains, loopback and versions are not findings", %{
    tmp_dir: dir
  } do
    repo = new_repo(dir)

    commit_file(
      repo,
      "neg.env",
      """
      DB_PASSWORD=changeme
      API_TOKEN=${SOME_VAR}
      SECRET_KEY_BASE=
      mail=someone@example.com
      host=127.0.0.1
      gem=v1.2.3.4
      lan=10.0.0.1
      """
    )

    {out, 0} = run(repo, ["--tree"])
    assert rows(out) == []
    {out2, 0} = run(repo, ["--tree", "--include-noise"])
    assert [%{rule: "I02"}] = rows(out2)
  end

  # ---- O9 read-only and repeatable

  test "O9 two runs give identical output and leave the repository untouched", %{tmp_dir: dir} do
    repo = new_repo(dir)
    commit_file(repo, "a.txt", aws_key() <> "\n")
    before = {git(repo, ["status", "--porcelain"]), git(repo, ["rev-list", "--all"])}
    {o1, 0} = run(repo)
    {o2, 0} = run(repo)
    assert o1 == o2
    assert before == {git(repo, ["status", "--porcelain"]), git(repo, ["rev-list", "--all"])}
  end

  # ---- O10 the report

  test "O10 the report exists, has its sections and holds no secret-shaped value" do
    text = File.read!(@report)

    for n <- 1..9 do
      assert text =~ ~r/^## #{n}\. /m, "section #{n} missing"
    end

    assert text =~ "AUTHENTIC CREDENTIAL EXPOSED IN PUBLIC REPO:"
    assert text =~ "LIVENESS: not tested"
    {out, code} = System.cmd("python3", ["-I", @scanner, "--check-file", @report])
    assert code == 0, "report holds a secret-shaped value: #{out}"
  end

  # ---- O11 no mutating git verb

  test "O11 every git subcommand the scanner runs is a read-only one" do
    src = File.read!(@scanner)

    verbs =
      Regex.scan(~r/"-C",\s*(?:root|a\.repo),\s*"([a-z-]+)"/, src)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()

    assert verbs != []
    assert verbs -- ~w(log ls-files rev-parse rev-list for-each-ref cat-file) == []

    for f <- [@scanner, @rules, @script] do
      refute File.read!(f) =~ ~r/filter-repo|filter-branch|git push|update-ref/,
             "#{f} names a history-changing command"
    end
  end

  # ---- O12 sqlite

  test "O12 a secret in a SQLite column is found in history under file#table.column", %{
    tmp_dir: dir
  } do
    repo = new_repo(dir)

    build = """
    import sqlite3, sys
    path, value = sys.argv[1], sys.argv[2]
    c = sqlite3.connect(path)
    c.execute('create table t (c text)')
    if value: c.execute('insert into t values (?)', ('k=' + value,))
    c.commit(); c.close()
    """

    db = Path.join(repo, "state/team.db")
    File.mkdir_p!(Path.dirname(db))
    {_, 0} = System.cmd("python3", ["-I", "-c", build, db, aws_key()])
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "db with key"])
    File.rm!(db)
    {_, 0} = System.cmd("python3", ["-I", "-c", build, db, ""])
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "db clean"])

    {out, 0} = run(repo)
    hit = Enum.find(rows(out), &(&1.rule == "S02"))
    assert %{scope: "history", path: "state/team.db#t.c", in_head: "no"} = hit
    refute out =~ String.slice(aws_key(), 4, 8)
    assert out =~ "sqlite_audited=3"
  end

  # ---- O13 evil merge, O14 rename plus edit

  test "O13 a secret that only a merge resolution introduces is found at the merge", %{
    tmp_dir: dir
  } do
    repo = new_repo(dir)
    commit_file(repo, "f.txt", "base\n")
    git(repo, ["checkout", "-q", "-b", "side"])
    commit_file(repo, "g.txt", "side\n")
    git(repo, ["checkout", "-q", "main"])
    commit_file(repo, "h.txt", "main\n")
    git(repo, ["merge", "--no-commit", "--no-ff", "side"])
    File.write!(Path.join(repo, "f.txt"), "base\nkey " <> aws_key() <> "\n")
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "evil merge"])
    merge = git(repo, ["rev-parse", "HEAD"])
    commit_file(repo, "f.txt", "base\n")

    {out, 0} = run(repo)
    hit = Enum.find(rows(out), &(&1.rule == "S02" and &1.scope == "history"))
    assert hit.path == "f.txt"
    assert hit.commit == String.slice(merge, 0, 12)
    assert hit.in_head == "no"
  end

  test "O14 an edit made together with a rename is found under the new path", %{tmp_dir: dir} do
    repo = new_repo(dir)
    body = Enum.map_join(1..30, "\n", &"line number #{&1} of the file") <> "\n"
    commit_file(repo, "old.txt", body)
    git(repo, ["mv", "old.txt", "new.txt"])
    File.write!(Path.join(repo, "new.txt"), body <> "key " <> aws_key() <> "\n")
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "rename and edit"])
    commit_file(repo, "new.txt", body)

    {out, 0} = run(repo)
    assert has_rule?(out, "S02", "new.txt")
  end

  # ---- C3 coverage proof on a real small history

  test "C3 distinct commits scanned equal rev-list --all --count, merges included", %{
    tmp_dir: dir
  } do
    repo = new_repo(dir)
    commit_file(repo, "a.txt", "a\n")
    git(repo, ["checkout", "-q", "-b", "side"])
    commit_file(repo, "b.txt", "b\n")
    git(repo, ["checkout", "-q", "main"])
    commit_file(repo, "c.txt", "c\n")
    git(repo, ["merge", "-q", "--no-ff", "-m", "m", "side"])
    count = git(repo, ["rev-list", "--all", "--count"])
    {out, 0} = run(repo)
    assert out =~ "commits_scanned=#{count} rev_list_all_count=#{count}"
  end

  # ---- O15 CI routing

  test "O15 the scanner, rules and report are inputs of the backend gate" do
    gate = Path.join(@root, "scripts/ci_changed_paths.sh")

    for p <- [
          "scripts/oss_audit/scanner.py",
          "scripts/oss_audit/rules.py",
          "docs/open-source/audit-report.md"
        ] do
      {out, 0} = System.cmd("bash", ["-c", "printf '%s\\n' \"$1\" | bash \"$2\"", "x", p, gate])
      assert out =~ "backend=true", "#{p} does not trigger the backend gate"
    end
  end
end
