defmodule Letflow.Scripts.BackupScriptsTest do
  @moduledoc """
  T-1568 -- `scripts/backup/*.sh` against the team's PostgreSQL container (dev hosts have no
  psql/pg_dump, so every client call goes through `PG_EXEC="docker exec -i <container>"`, the same
  prefix infra uses). The source is a small synthetic database with the table names the manifest
  reads; it is created and dropped per test. The test FAILS, it does not skip, when no container
  is found. IDs follow design.md section 8 (B = backup, R = restore test, W = status, D = docs).

  Not run in CI (stated, not hidden): the positive `backup.sh base` path (needs a server with
  `archive_mode=on`; only the refusal is tested, B4) and the HTTP boot of the release (the smoke is
  `Letflow.Release.RestoreSmoke`, tested in `test/letflow/release/restore_smoke_test.exs`).
  """

  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag timeout: 240_000

  import Bitwise

  @root Path.expand("../..", __DIR__)
  @dir Path.join(@root, "scripts/backup")
  @scripts ~w(backup.sh prune.sh restore_test.sh wal_archive.sh lib.sh)
  @fixture_sql """
  create table tenants(id int);
  create table tenant_schemas(schema_name text);
  insert into tenants values (1);
  insert into tenant_schemas values ('tenant_a');
  create schema tenant_a;
  create table tenant_a.events(id int);
  create table tenant_a.events_archive(id int);
  create table tenant_a.ledger_entry(id int);
  create table tenant_a.ledger_leg(ledger_id text, unit_ref text, quantity numeric(30,9));
  create table tenant_a.ledger_balance(ledger_id text, unit_ref text, on_hand numeric(30,9));
  create table tenant_a.tenant_modules(module_id text, version text);
  insert into tenant_a.events values (1), (2);
  insert into tenant_a.ledger_leg values ('L1','pcs',5), ('L1','pcs',-2);
  insert into tenant_a.ledger_balance values ('L1','pcs',3);
  insert into tenant_a.tenant_modules values ('stock','1.0.0');
  """

  setup %{tmp_dir: tmp} do
    container = container!()
    n = System.unique_integer([:positive])
    part = System.get_env("MIX_TEST_PARTITION") || "0"
    src = "bkt_#{part}_#{n}_src"
    other = "bkt_#{part}_#{n}_oth"
    for db <- [src, other], do: psql!(container, "postgres", "CREATE DATABASE #{db}")
    psql_file!(container, src, @fixture_sql)
    psql_file!(container, other, "create table x(id int); insert into x values (1);")

    on_exit(fn ->
      for db <- [src, other],
          do: psql(container, "postgres", "DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
    end)

    root = Path.join(tmp, "bk")

    env = [
      {"BACKUP_ENV", "tst"},
      {"BACKUP_ROOT", root},
      {"BACKUP_DATABASES", "#{src} #{other}"},
      {"PG_EXEC", "docker exec -i -e PGUSER=letflow #{container}"},
      {"RESTORE_TARGET", "existing"},
      {"RESTORE_SMOKE_CMD", "true"}
    ]

    {:ok, container: container, src: src, other: other, root: root, env: env}
  end

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp container! do
    {out, 0} =
      System.cmd("docker", ["ps", "--filter", "name=letflow-team", "--format", "{{.Names}}"])

    case out |> String.split("\n", trim: true) |> Enum.find(&(&1 =~ "postgres")) do
      nil ->
        flunk(
          "no letflow-team postgres container is running (docker compose -p letflow-team up -d postgres)"
        )

      name ->
        name
    end
  end

  defp psql(container, db, sql) do
    System.cmd(
      "docker",
      ["exec", "-i", "-e", "PGUSER=letflow", container, "psql", "-X", "-At", "-d", db, "-c", sql],
      stderr_to_stdout: true
    )
  end

  defp psql!(container, db, sql) do
    {out, 0} = psql(container, db, sql)
    String.trim(out)
  end

  defp psql_file!(container, db, sql) do
    file = Path.join(System.tmp_dir!(), "bkt_fixture_#{System.unique_integer([:positive])}.sql")
    File.write!(file, sql)

    {out, code} =
      System.cmd(
        "bash",
        [
          "-c",
          ~s(docker exec -i -e PGUSER=letflow "$1" psql -X -q -d "$2" -v ON_ERROR_STOP=1 < "$3"),
          "_",
          container,
          db,
          file
        ],
        stderr_to_stdout: true
      )

    File.rm!(file)
    assert code == 0, out
  end

  # The first entry of a key wins inside `env` (callers prepend overrides); `extra` wins over both.
  defp build_env(env, extra),
    do: env |> Enum.reverse() |> Map.new() |> Map.merge(Map.new(extra)) |> Map.to_list()

  defp put_env(env, key, value), do: List.keystore(env, key, 0, {key, value})

  # Runs a script with the env; returns {stdout, exit_code}. stderr is dropped.
  defp run(env, script, args \\ [], extra \\ []) do
    System.cmd("bash", ["-c", ~s(exec "$@" 2>/dev/null), "_", Path.join(@dir, script) | args],
      env: build_env(env, extra),
      stderr_to_stdout: false
    )
  end

  defp run_err(env, script, args \\ [], extra \\ []) do
    System.cmd("bash", [Path.join(@dir, script) | args],
      env: build_env(env, extra),
      stderr_to_stdout: true
    )
  end

  defp dump!(env), do: {_, 0} = run(env, "backup.sh", ["dump"], [{"BACKUP_PRUNE", "0"}])

  defp set_dir(root, db) do
    [stamp] =
      root |> Path.join("dump/#{db}") |> File.ls!() |> Enum.filter(&(&1 =~ ~r/^\d{8}T\d{6}Z$/))

    Path.join(root, "dump/#{db}/#{stamp}")
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  defp status(root, job),
    do: root |> Path.join("status/#{job}.json") |> File.read!() |> Jason.decode!()

  defp stamp_ago(days, secs \\ 0) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400 - secs)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp db_exists?(container, db),
    do:
      psql!(container, "postgres", "select count(*) from pg_database where datname = '#{db}'") ==
        "1"

  defp scratch_dbs(container),
    do:
      psql!(
        container,
        "postgres",
        "select count(*) from pg_database where datname like 'restore_test_%'"
      )

  # ── B: backup script set ───────────────────────────────────────────────────────────────────

  describe "backup.sh dump" do
    test "B1 one set per database, sha256, manifest, LATEST, private modes", %{
      root: root,
      env: env,
      src: src,
      other: other
    } do
      dump!(env)
      s = set_dir(root, src)
      o = set_dir(root, other)

      for {dir, db} <- [{s, src}, {o, other}] do
        assert File.exists?(Path.join(dir, "#{db}.dump"))
        assert File.read!(Path.join(dir, "#{db}.dump.sha256")) =~ "#{db}.dump"
        assert mode(Path.join(dir, "#{db}.dump")) == 0o600
        assert mode(dir) == 0o700
        assert {:ok, _} = File.read_link(Path.join(Path.dirname(dir), "LATEST"))
      end

      manifest = File.read!(Path.join(s, "manifest.txt"))
      assert manifest =~ "source_db=#{src}"
      assert manifest =~ "public.tenants=1"
      assert manifest =~ "tenant_a.events=2"
      assert manifest =~ "tenant_a.ledger_replay_diff=0"
      # only the Letflow database gets a manifest, and it holds counts and digests only
      refute File.exists?(Path.join(o, "manifest.txt"))
      assert mode(root) == 0o700
      assert status(root, "dump")["ok"] == true
    end

    test "B2 gpg: only .gpg lands on disk, it decrypts to a custom-format dump and restores",
         %{root: root, env: env, src: src} do
      home = Path.join(System.tmp_dir!(), "bkgpg#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      File.chmod!(home, 0o700)

      on_exit(fn ->
        System.cmd("gpgconf", ["--homedir", home, "--kill", "all"], stderr_to_stdout: true)
        File.rm_rf!(home)
      end)

      gpg_env = [{"GNUPGHOME", home}]

      {_, 0} =
        System.cmd(
          "gpg",
          ~w(--batch --passphrase  --pinentry-mode loopback --quick-generate-key bk-test@example.invalid default default never),
          env: gpg_env,
          stderr_to_stdout: true
        )

      env =
        [{"BACKUP_ENCRYPT", "gpg"}, {"BACKUP_GPG_RECIPIENT", "bk-test@example.invalid"} | env] ++
          gpg_env

      dump!(env)
      dir = set_dir(root, src)
      assert File.exists?(Path.join(dir, "#{src}.dump.gpg"))
      refute File.exists?(Path.join(dir, "#{src}.dump"))

      {plain, 0} =
        System.cmd(
          "gpg",
          [
            "--batch",
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--decrypt",
            Path.join(dir, "#{src}.dump.gpg")
          ],
          env: gpg_env,
          stderr_to_stdout: false
        )

      assert String.starts_with?(plain, "PGDMP")
      {line, code} = run(env, "restore_test.sh", [], [{"RESTORE_GPG_HOME", home}])
      assert code == 0, line
      assert line =~ ~r/^restore_test PASS /

      {_, code} =
        run([{"BACKUP_GPG_RECIPIENT", "nobody@example.invalid"} | env], "backup.sh", ["dump"])

      assert code == 5
    end

    test "W1 a failed dump exits 3 and still leaves a status file with ok false", %{
      root: root,
      env: env
    } do
      {_, code} = run([{"BACKUP_DATABASES", "bkt_no_such_db"} | env], "backup.sh", ["dump"])
      assert code == 3
      st = status(root, "dump")
      assert st["ok"] == false and st["exit"] == 3 and st["job"] == "dump"
      assert st["detail"] =~ "dump_failed"
      # no half set and no temp status file is left behind
      assert Path.wildcard(Path.join(root, "dump/*/.tmp-*")) == []
      assert Path.wildcard(Path.join(root, "status/.*.json.*")) == []
    end

    test "W1 bad input exits 2 before any request; usage error too", %{env: env} do
      assert {_, 2} = run([{"BACKUP_DATABASES", "a;drop"} | env], "backup.sh", ["dump"])
      assert {_, 2} = run([{"BACKUP_ENV", "../x"} | env], "backup.sh", ["dump"])
      assert {_, 2} = run(env, "backup.sh", ["nonsense"])
      assert {_, 2} = run([{"BACKUP_ENCRYPT", "gpg"} | env], "backup.sh", ["dump"])
    end
  end

  describe "backup.sh base and wal_archive.sh" do
    test "B4 base refuses with exit 4 while archive_mode is off", %{
      root: root,
      env: env,
      container: c,
      src: src
    } do
      assert psql!(c, src, "show archive_mode") == "off"
      {_, code} = run(env, "backup.sh", ["base"])
      assert code == 4
      assert status(root, "base")["detail"] =~ "archive_mode_off"
      assert Path.wildcard(Path.join(root, "base/*")) == []
    end

    test "B3 wal_archive copies, is idempotent, refuses a different file with the same name", %{
      tmp_dir: tmp
    } do
      dest = Path.join(tmp, "wal")
      src = Path.join(tmp, "seg")
      File.write!(src, "segment-one")
      name = "000000010000000000000007"
      env = [{"WAL_ARCHIVE_DIR", dest}]

      assert {_, 0} = run(env, "wal_archive.sh", [src, name])
      assert File.read!(Path.join(dest, name)) == "segment-one"
      assert mode(Path.join(dest, name)) == 0o600
      assert {_, 0} = run(env, "wal_archive.sh", [src, name])

      File.write!(src, "segment-two")
      assert {_, 1} = run(env, "wal_archive.sh", [src, name])
      assert File.read!(Path.join(dest, name)) == "segment-one"
      assert Path.wildcard(Path.join(dest, ".*.tmp.*")) == []
      assert {_, 2} = run(env, "wal_archive.sh", [src, "../evil"])
      assert {_, 2} = run(env, "wal_archive.sh", [])
    end
  end

  describe "prune.sh" do
    setup %{root: root, env: env} do
      db = "pdb"
      File.mkdir_p!(Path.join(root, "dump/#{db}"))
      env = [{"BACKUP_DATABASES", db} | env]
      {:ok, db: db, env: env}
    end

    defp make_sets(root, db, ages) do
      for age <- ages do
        stamp = stamp_ago(age)
        File.mkdir_p!(Path.join(root, "dump/#{db}/#{stamp}"))
        stamp
      end
    end

    test "B5 keeps DUMP_KEEP_MIN newest old sets; a symlink is not followed; dry-run deletes nothing",
         %{root: root, env: env, db: db, tmp_dir: tmp} do
      sets = make_sets(root, db, 20..29)
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep.txt"), "x")
      File.ln_s!(outside, Path.join(root, "dump/#{db}/20200101T000000Z"))

      {out, 0} = run_err(env, "prune.sh", ["--dry-run"])
      assert out =~ "would delete"
      assert length(File.ls!(Path.join(root, "dump/#{db}"))) == 11

      {_, 0} = run_err(env, "prune.sh")
      left = root |> Path.join("dump/#{db}") |> File.ls!() |> Enum.filter(&(&1 in sets))
      assert length(left) == 7
      assert Enum.sort(left) == sets |> Enum.sort() |> Enum.take(-7)
      assert File.exists?(Path.join(outside, "keep.txt"))
      assert File.exists?(Path.join(root, "dump/#{db}/20200101T000000Z"))
    end

    test "B5 the newest verified set survives; young sets are never touched", %{
      root: root,
      env: env,
      db: db
    } do
      old = make_sets(root, db, 20..29)
      oldest = Enum.min(old)
      File.write!(Path.join(root, "dump/#{db}/#{oldest}/VERIFIED"), "ok")
      young = make_sets(root, db, [1])
      {_, 0} = run_err(env, "prune.sh")
      left = root |> Path.join("dump/#{db}") |> File.ls!()
      assert oldest in left
      assert hd(young) in left
      # 1 young + 7 min counts the young one: 6 more old ones are kept, plus the verified one
      assert length(left) == 8
    end

    test "B5 WAL older than the oldest kept base's start segment goes; none without a base", %{
      root: root,
      env: env
    } do
      wal = Path.join(root, "wal")
      File.mkdir_p!(wal)
      old_seg = "000000010000000000000001"
      new_seg = "000000010000000000000009"
      ancient = DateTime.utc_now() |> DateTime.add(-40 * 86_400) |> DateTime.to_unix()

      for seg <- [old_seg, new_seg] do
        File.write!(Path.join(wal, seg), "w")
        File.touch!(Path.join(wal, seg), ancient)
      end

      {_, 0} = run_err(env, "prune.sh")
      assert File.exists?(Path.join(wal, old_seg)), "no base backup: nothing is deleted"

      base = Path.join(root, "base/#{stamp_ago(2)}")
      File.mkdir_p!(base)
      File.write!(Path.join(base, "base.info"), "start_wal=000000010000000000000005\n")
      {_, 0} = run_err(env, "prune.sh")
      refute File.exists?(Path.join(wal, old_seg))
      assert File.exists?(Path.join(wal, new_seg))
    end

    test "B5 retention file: only KEY=number lines; code is refused", %{
      root: root,
      env: env,
      tmp_dir: tmp
    } do
      bad = Path.join(tmp, "bad.conf")
      File.write!(bad, "DUMP_KEEP_DAYS=3; touch #{tmp}/pwned\n")
      assert {_, 2} = run(env, "prune.sh", [], [{"RETENTION_FILE", bad}])
      refute File.exists?(Path.join(tmp, "pwned"))
      File.write!(bad, "DUMP_KEEP_DAYS=3\nDUMP_KEEP_MIN=1\n")
      make_sets(root, "pdb", 10..12)
      {_, 0} = run_err(env, "prune.sh", [], [{"RETENTION_FILE", bad}])
      assert length(File.ls!(Path.join(root, "dump/pdb"))) == 1
    end
  end

  test "B6 static: no set -x, no inline password, every env name is documented" do
    files = for f <- @scripts, do: {f, File.read!(Path.join(@dir, f))}

    for {f, src} <- files do
      refute src =~ ~r/^\s*set\s+-[a-z]*x/m, "#{f} traces"
      refute src =~ ~r/PGPASSWORD=\S/, "#{f} sets a password literal"
    end

    readme = File.read!(Path.join(@dir, "README.md"))
    runbook = File.read!(Path.join(@root, "docs/runbooks/backup-restore.md"))

    names =
      files
      |> Enum.flat_map(fn {_f, src} ->
        Regex.scan(
          ~r/\$\{?((?:BACKUP|RESTORE|RETENTION|WAL)_[A-Z_]+|PG_EXEC|LETFLOW_DATABASE|RELEASE_BIN)\b/,
          src
        )
      end)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    assert names != []

    for n <- names do
      assert readme =~ n, "#{n} is not in scripts/backup/README.md"
      assert runbook =~ n, "#{n} is not in docs/runbooks/backup-restore.md"
    end

    # the retention policy file is parsed, never sourced
    refute File.read!(Path.join(@dir, "lib.sh")) =~
             ~r/^\s*(\.|source)\s+"?\$\{?(file|RETENTION_FILE)/m
  end

  # ── R: restore test ────────────────────────────────────────────────────────────────────────

  describe "restore_test.sh" do
    test "R1 happy path: exit 0, exactly one stdout line, scratch gone, source intact, set verified",
         %{root: root, env: env, container: c, src: src} do
      dump!(env)
      {out, code} = run(env, "restore_test.sh")
      assert code == 0, out
      assert [line] = String.split(out, "\n", trim: true)

      assert line =~
               ~r/^restore_test PASS env=tst db=#{src} set=\d{8}T\d{6}Z tenants=1 ledger_pairs=1 replay_diff=0 modules=ok smoke=ok seconds=\d+$/

      assert scratch_dbs(c) == "0"
      assert db_exists?(c, src)
      assert File.exists?(Path.join(set_dir(root, src), "VERIFIED"))
      st = status(root, "restore_test")
      assert st["ok"] == true and st["detail"] =~ "PASS"
    end

    test "R9 container target: a throwaway container is started and removed", %{
      env: env,
      src: src
    } do
      dump!(env)
      env = put_env(env, "RESTORE_TARGET", "container")
      {before, 0} = System.cmd("docker", ["ps", "-q", "--filter", "ancestor=postgres:16"])

      {out, code} =
        run(env, "restore_test.sh", [], [{"RESTORE_SMOKE_CMD", ~s(test -n "$DATABASE_URL")}])

      assert code == 0, out
      assert out =~ "restore_test PASS env=tst db=#{src}"
      {after_run, 0} = System.cmd("docker", ["ps", "-q", "--filter", "ancestor=postgres:16"])
      # no container of ours is left running (siblings may start theirs: only ours must be gone)
      assert Enum.all?(String.split(after_run), &(&1 in String.split(before)))
    end

    test "R2 a tampered manifest count: exit 1 and the line names the key", %{
      root: root,
      env: env,
      src: src
    } do
      dump!(env)
      tamper(root, src, "tenant_a.events=2", "tenant_a.events=5")
      {out, code} = run(env, "restore_test.sh")
      assert code == 1

      assert out =~
               ~r/^restore_test FAIL step=content exit=1 detail=manifest_differs:tenant_a\.events/

      assert [_] = String.split(out, "\n", trim: true)
    end

    test "R3 an unbalanced ledger in the backup fails on the replay check", %{
      root: root,
      env: env,
      container: c,
      src: src
    } do
      psql!(c, src, "update tenant_a.ledger_balance set on_hand = 99")
      dump!(env)
      {out, code} = run(env, "restore_test.sh")
      assert code == 1
      assert out =~ "replay_diff_nonzero:1"
      assert File.exists?(set_dir(root, src))
      refute File.exists?(Path.join(set_dir(root, src), "VERIFIED"))
    end

    test "R4 a changed module version fails on the modules digest", %{
      root: root,
      env: env,
      src: src
    } do
      dump!(env)

      [line] =
        File.read!(Path.join(set_dir(root, src), "manifest.txt"))
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "tenant_a.modules="))

      tamper(root, src, line, "tenant_a.modules=00000000000000000000000000000000")
      {out, code} = run(env, "restore_test.sh")
      assert code == 1
      assert out =~ "tenant_a.modules"
    end

    test "R5 a flipped byte in the dump is exit 4", %{root: root, env: env, src: src} do
      dump!(env)
      file = Path.join(set_dir(root, src), "#{src}.dump")
      bin = File.read!(file)
      mid = div(byte_size(bin), 2)
      <<a::binary-size(^mid), b, rest::binary>> = bin
      File.write!(file, <<a::binary, bxor(b, 1), rest::binary>>)
      {out, code} = run(env, "restore_test.sh")
      assert code == 4
      assert out =~ "step=checksum exit=4"
    end

    test "R6 a set older than BACKUP_MAX_AGE_HOURS is exit 3; no set is exit 3", %{
      root: root,
      env: env,
      src: src
    } do
      {out, 3} = run(env, "restore_test.sh")
      assert out =~ "no_backup"
      dump!(env)
      old = Path.join(root, "dump/#{src}/#{stamp_ago(3)}")
      File.rename!(set_dir(root, src), old)
      {out, code} = run(env, "restore_test.sh", ["--set", old])
      assert code == 3
      assert out =~ "no_fresh_backup"
      {_, 0} = run(env, "restore_test.sh", ["--set", old], [{"BACKUP_MAX_AGE_HOURS", "100"}])
    end

    test "R7 smoke: failing command is exit 6; skip needs an explicit allow; unset is exit 6", %{
      env: env
    } do
      dump!(env)
      {out, code} = run(env, "restore_test.sh", [], [{"RESTORE_SMOKE_CMD", "false"}])
      assert code == 6
      assert out =~ "step=smoke exit=6 detail=smoke_failed"

      env_skip = List.keydelete(env, "RESTORE_SMOKE_CMD", 0)
      {out, code} = run(env_skip, "restore_test.sh", [], [{"RESTORE_SMOKE", "skip"}])
      assert code == 6
      assert out =~ "smoke_skipped_not_allowed"

      {out, code} =
        run(env_skip, "restore_test.sh", [], [
          {"RESTORE_SMOKE", "skip"},
          {"RESTORE_ALLOW_NO_SMOKE", "1"}
        ])

      assert code == 0
      assert out =~ "smoke=skipped"

      {out, code} = run(env_skip, "restore_test.sh")
      assert code == 6
      assert out =~ "smoke_not_configured"
    end

    test "R8 never touches the source: bad target is exit 2, scratch dropped after a failure, source intact",
         %{env: env, container: c, src: src, root: root} do
      dump!(env)
      {_, 2} = run(env, "restore_test.sh", [], [{"RESTORE_TARGET", "source"}])
      {_, 6} = run(env, "restore_test.sh", [], [{"RESTORE_SMOKE_CMD", "false"}])
      assert scratch_dbs(c) == "0"
      assert db_exists?(c, src)
      assert psql!(c, src, "select count(*) from tenant_a.events") == "2"
      assert File.dir?(root)
    end
  end

  defp tamper(root, db, from, to) do
    path = Path.join(set_dir(root, db), "manifest.txt")
    File.write!(path, path |> File.read!() |> String.replace(from, to))
  end

  # ── D: documents ───────────────────────────────────────────────────────────────────────────

  @headings [
    "Status and scope",
    "What is backed up",
    "Targets (proposed, owner to accept)",
    "Schedule and layout",
    "Interface for infra",
    "Restore the whole database",
    "Restore a single tenant (schema-per-tenant)",
    "Restore Keycloak",
    "Point-in-time recovery (WAL mode)",
    "Drill checklist",
    "Open owner questions"
  ]

  describe "runbook and README" do
    setup do
      {:ok, runbook: File.read!(Path.join(@root, "docs/runbooks/backup-restore.md"))}
    end

    test "D1 the eleven headings in order, and the required content", %{runbook: rb} do
      found =
        Regex.scan(~r/^## (?:\d+\.\s*)?(.+)$/m, rb) |> Enum.map(&Enum.at(&1, 1))

      assert found == @headings

      for needle <- [
            "A purge does not erase backups or replicas",
            "LETFLOW_SECRETS_MASTER_KEY",
            "RPO",
            "RTO",
            "point of no return",
            "tenant_",
            "Keycloak",
            "restore_test.sh",
            "status/restore_test.json"
          ] do
        assert rb =~ needle, "runbook lacks #{inspect(needle)}"
      end
    end

    test "D1 relative links resolve to files in the repo", %{runbook: rb} do
      base = Path.join(@root, "docs/runbooks")

      for [_, target] <- Regex.scan(~r/\]\((?!https?:|#|mailto:)([^)#\s]+)/, rb) do
        assert File.exists?(Path.expand(target, base)), "broken link #{target}"
      end
    end

    test "W1 the systemd units in the runbook: oneshot, weekly drill on Sunday, env from a file",
         %{runbook: rb} do
      units = Regex.scan(~r/```ini\n(.*?)```/s, rb) |> Enum.map(&Enum.at(&1, 1))
      assert length(units) >= 3
      joined = Enum.join(units, "\n")
      assert joined =~ "Type=oneshot"
      assert joined =~ "OnCalendar=Sun"
      assert joined =~ "EnvironmentFile="
      refute joined =~ ~r/Environment=.*(PASSWORD|KEY)=/
    end

    test "D2 README exit-code table equals the script headers" do
      readme = File.read!(Path.join(@dir, "README.md"))

      for script <- ~w(backup.sh prune.sh restore_test.sh wal_archive.sh) do
        src = File.read!(Path.join(@dir, script))

        [_, header] =
          Regex.run(~r/# Exit codes?:(.*?)(?:\n# Status|\n# The source|\nset -e)/s, src)

        in_header =
          (Regex.scan(~r/^\s*(\d)\s/, header) ++ Regex.scan(~r/;\s*(?:#\s*)?(\d)\s/, header))
          |> Enum.map(&Enum.at(&1, 1))
          |> Enum.uniq()
          |> Enum.sort()

        [_, row] = Regex.run(~r/\|\s*`#{Regex.escape(script)}`\s*\|\s*`([0-9 ]+)`/, readme)

        assert row |> String.split() |> Enum.sort() == in_header,
               "#{script}: README table differs from header"
      end
    end
  end
end
