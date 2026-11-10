defmodule Letflow.BackupStatus do
  @moduledoc """
  Freshness line of the database backup jobs, for the platform operator (T-1607, BA batch 4
  item 2). Reads the status files that `scripts/backup/*` write
  (`$BACKUP_ROOT/status/<job>.json`, contract in `scripts/backup/README.md`, "Status file").

  The directory is `config :letflow, :backup_status_dir` (env `LETFLOW_BACKUP_STATUS_DIR`,
  read in `config/runtime.exs`): the web process may not see `BACKUP_ROOT`, so the operator
  mounts the status directory read-only or leaves it unset. Unset means
  `%{configured: false, jobs: []}`.

  Only the four fixed file names `dump|base|prune|restore_test` + `.json` are read; no part of a
  request reaches a path. A file must be a regular file (a symlink is refused, checked with
  `File.lstat/1`) of at most 4 KB, and decode to a JSON object with an `ok` boolean and a
  parseable `ts`; anything else is `"unreadable"`. Only `job`, `state`, `ts` and `age_seconds`
  are returned: `detail`, `env` and paths never leave this module.

  ## Staleness thresholds (a design decision of T-1607, not configurable)

  Derived from the schedules `docs/runbooks/backup-restore.md` documents: `dump` 30 hours
  (daily timer plus 6 hours slack), `base` 8 days (weekly plus a day), `restore_test` 8 days
  (the runbook's own number for the weekly drill). `prune` has no documented schedule and so
  no threshold. `BACKUP_MAX_AGE_HOURS` is `restore_test.sh`'s own knob and is not used here.
  A host with a different cadence relies on infra's own polling of the files; this line is an
  operator hint only.

  States: `"ok"`, `"failed"` (job reported `ok: false`), `"stale"` (ok but older than the
  threshold), `"missing"` (no file), `"unreadable"`.
  """

  @jobs ~w(dump base prune restore_test)
  @max_bytes 4096
  @hour 3600
  @thresholds %{
    "dump" => 30 * @hour,
    "base" => 8 * 24 * @hour,
    "restore_test" => 8 * 24 * @hour
  }

  @type job_line :: %{
          job: String.t(),
          state: String.t(),
          ts: String.t() | nil,
          age_seconds: non_neg_integer() | nil
        }

  @doc "Reads the configured status directory."
  @spec read(keyword()) :: %{configured: boolean(), jobs: [job_line()]}
  def read(opts \\ []) do
    dir = Keyword.get(opts, :dir, Application.get_env(:letflow, :backup_status_dir))
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case dir do
      dir when is_binary(dir) and dir != "" ->
        %{configured: true, jobs: Enum.map(@jobs, &job_line(dir, &1, now))}

      _unset ->
        %{configured: false, jobs: []}
    end
  end

  defp job_line(dir, job, now) do
    path = Path.join(dir, job <> ".json")

    case File.lstat(path) do
      {:error, :enoent} ->
        line(job, "missing")

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
        parse(path, job, now)

      _other ->
        line(job, "unreadable")
    end
  end

  defp parse(path, job, now) do
    with {:ok, body} <- File.read(path),
         true <- byte_size(body) <= @max_bytes,
         {:ok, %{"ok" => ok, "ts" => ts}} when is_boolean(ok) and is_binary(ts) <-
           Jason.decode(body),
         {:ok, at, _offset} <- DateTime.from_iso8601(ts) do
      age = max(DateTime.diff(now, at, :second), 0)
      %{job: job, state: state(job, ok, age), ts: DateTime.to_iso8601(at), age_seconds: age}
    else
      _bad -> line(job, "unreadable")
    end
  end

  defp state(_job, false, _age), do: "failed"

  defp state(job, true, age) do
    case Map.fetch(@thresholds, job) do
      {:ok, limit} when age > limit -> "stale"
      _within_or_none -> "ok"
    end
  end

  defp line(job, state), do: %{job: job, state: state, ts: nil, age_seconds: nil}
end
