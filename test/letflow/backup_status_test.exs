defmodule Letflow.BackupStatusTest do
  @moduledoc "T-1607: `Letflow.BackupStatus` (B1, B2) against files in a tmp dir."

  use ExUnit.Case, async: true

  alias Letflow.BackupStatus

  @now ~U[2026-11-10 12:00:00Z]

  @moduletag :tmp_dir

  defp write_job(dir, job, ok, ts) do
    File.write!(
      Path.join(dir, job <> ".json"),
      Jason.encode!(%{
        job: job,
        env: "qa",
        ts: ts,
        exit: 0,
        ok: ok,
        detail: "secret-ish /opt/backups/x"
      })
    )
  end

  defp ago(seconds), do: @now |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  defp states(dir),
    do: BackupStatus.read(dir: dir, now: @now).jobs |> Map.new(&{&1.job, &1.state})

  test "B2 not configured", _ctx do
    assert BackupStatus.read(dir: nil) == %{configured: false, jobs: []}
    assert BackupStatus.read(dir: "") == %{configured: false, jobs: []}
  end

  test "B1 missing files are missing, fresh ok files ok", %{tmp_dir: dir} do
    write_job(dir, "dump", true, ago(60))

    assert states(dir) == %{
             "dump" => "ok",
             "base" => "missing",
             "prune" => "missing",
             "restore_test" => "missing"
           }

    assert %{configured: true} = BackupStatus.read(dir: dir, now: @now)
  end

  test "B1 failed job", %{tmp_dir: dir} do
    write_job(dir, "dump", false, ago(60))
    assert states(dir)["dump"] == "failed"
  end

  test "B1 thresholds: dump 30 h, base and restore_test 8 d, prune never stale", %{tmp_dir: dir} do
    h = 3600
    write_job(dir, "dump", true, ago(30 * h))
    write_job(dir, "base", true, ago(8 * 24 * h))
    write_job(dir, "restore_test", true, ago(8 * 24 * h))
    write_job(dir, "prune", true, ago(400 * 24 * h))

    assert states(dir) == %{
             "dump" => "ok",
             "base" => "ok",
             "restore_test" => "ok",
             "prune" => "ok"
           }

    write_job(dir, "dump", true, ago(30 * h + 1))
    write_job(dir, "base", true, ago(8 * 24 * h + 1))
    write_job(dir, "restore_test", true, ago(8 * 24 * h + 1))

    assert states(dir) == %{
             "dump" => "stale",
             "base" => "stale",
             "restore_test" => "stale",
             "prune" => "ok"
           }
  end

  test "B1 unreadable: bad json, no ok, bad ts, oversize, symlink", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "dump.json"), "{not json")
    File.write!(Path.join(dir, "base.json"), ~s({"ts":"#{ago(5)}"}))
    File.write!(Path.join(dir, "prune.json"), ~s({"ok":true,"ts":"yesterday"}))
    File.write!(Path.join(dir, "restore_test.json"), String.duplicate("x", 5000))
    assert Map.values(states(dir)) |> Enum.uniq() == ["unreadable"]

    target = Path.join(dir, "elsewhere.txt")
    write_job(dir, "base", true, ago(5))
    File.rename!(Path.join(dir, "base.json"), target)
    File.ln_s!(target, Path.join(dir, "base.json"))
    assert states(dir)["base"] == "unreadable"
  end

  test "B1 returns only job, state, ts, age_seconds; future ts is age 0", %{tmp_dir: dir} do
    write_job(dir, "dump", true, @now |> DateTime.add(500, :second) |> DateTime.to_iso8601())
    line = BackupStatus.read(dir: dir, now: @now).jobs |> Enum.find(&(&1.job == "dump"))
    assert Map.keys(line) |> Enum.sort() == [:age_seconds, :job, :state, :ts]
    assert line.age_seconds == 0
    refute inspect(BackupStatus.read(dir: dir, now: @now)) =~ "secret-ish"
  end
end
