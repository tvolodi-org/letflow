defmodule Mix.Tasks.Letflow.CheckQueueReconciliation do
  @shortdoc "Reconciles docs/requirements.yaml + docs/issues/*.yaml against the live letflow-queue"

  @moduledoc """
  **TRANSITION-ONLY (ISS-1073 / GH #2430).** The work board
  (`docs/agents/protocols/WORK_BOARD.md`) replaces letflow-queue. While
  `docs/status/work_board_cutover.yaml` says `cutover: false` this task works
  exactly as described below. Once it says `cutover: true` the task prints
  `SKIPPED` and exits `0` without any network call, and **this module and
  its test are deleted in the cutover PR** (the queue service is then
  stopped by infra; there is nothing left to reconcile against). Nothing in
  this module may be extended.

  Implements ISS-0848 AC2: a check that flags drift between what
  `docs/requirements.yaml`/`docs/issues/*.yaml` claim (yaml `status:`) and
  what letflow-queue actually reports for the same task (`GET /tasks`
  `status`), plus dangling references to queue tasks that no longer exist.

  Full design: `lib/letflow/design/iss0848-queue-reconciliation-check.md`.

  ## Deliberately NOT wired into `mix letflow.check`

  Every existing `letflow.check_*` task is a pure, hermetic, no-network scan
  (see `Mix.Tasks.Letflow.CheckRequirementsRegistration`'s own moduledoc).
  This task makes exactly one network call (`GET
  https://queue-test.ai-dala.com/tasks`) and requires `$QUEUE_AUTH_TOKEN`, a
  documented local-dev convenience that is not guaranteed on every host or
  CI runner (`docs/agents/protocols/TASK_QUEUE.md`). Folding it into the
  `letflow.check` alias would make the project's only CI gate flaky (or
  permanently red) on any host without that token or without egress to the
  queue service. It is run directly instead -- by ORCH at session start, or
  on demand -- never as part of the CI/local gate sequence. See the design
  doc section 1 for the full reasoning, including why a silent
  "skip-inside-the-alias-when-no-token" shape was considered and rejected.

  ## Behaviour when `$QUEUE_AUTH_TOKEN` is unavailable

  Prints `SKIPPED -- no $QUEUE_AUTH_TOKEN (checked shell env and ./.env)` and
  exits `0`. This is a standalone task never wired into any gate, so a soft
  skip is safe: nothing downstream treats "skipped" as "passed a gate"
  because there is no gate here.

  ## Usage

      mix letflow.check_queue_reconciliation

  Exits `0` iff no findings; `Mix.raise/1` otherwise, naming every finding
  (kind, source id, queue task id, reason).
  """

  use Mix.Task

  alias Mix.Letflow.WorkBoardCutover
  alias Mix.Tasks.Letflow.CheckIssueRefs
  alias Mix.Tasks.Letflow.CheckRequirementsRegistration

  @requirements_file "docs/requirements.yaml"
  @issues_dir "docs/issues"
  @queue_tasks_url "https://queue-test.ai-dala.com/tasks"
  @env_file ".env"
  @http_timeout_ms 15_000

  @queue_ref_line_re ~r/^queue_ref:\s*(.*?)\s*$/
  @id_line_re ~r/^id:\s*(.*?)\s*$/
  @status_line_re ~r/^status:\s*(.*?)\s*$/
  @queue_ref_ok_re ~r/^Q-([1-9]\d*)$/

  @type yaml_status :: String.t()
  @type queue_status :: String.t()
  @type source_kind :: :requirement | :issue

  @type source_ref :: %{
          kind: source_kind(),
          id: String.t(),
          yaml_status: yaml_status(),
          queue_task_id: pos_integer()
        }

  @type queue_task :: %{
          id: pos_integer(),
          status: queue_status(),
          title: String.t() | nil
        }

  @type finding ::
          %{
            kind: :status_mismatch,
            source: source_ref(),
            queue_status: queue_status(),
            reason: String.t()
          }
          | %{kind: :dangling_queue_ref, source: source_ref()}
          | %{kind: :unrecognized_yaml_status, source: source_ref(), reason: String.t()}

  @type report :: %{
          sources_checked: non_neg_integer(),
          queue_tasks_seen: non_neg_integer(),
          findings: [finding()]
        }

  # -- Mix.Task entry point -------------------------------------------------

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    if WorkBoardCutover.cutover?() do
      Mix.shell().info(
        "SKIPPED -- work board cutover is live (docs/status/work_board_cutover.yaml); " <>
          "the queue is retired. Delete this task and its test."
      )

      :ok
    else
      case resolve_queue_auth_token() do
        :none ->
          Mix.shell().info("SKIPPED -- no $QUEUE_AUTH_TOKEN (checked shell env and ./.env)")

          :ok

        {:ok, token} ->
          run_with_token(token)
      end
    end
  end

  @spec run_with_token(String.t()) :: :ok
  defp run_with_token(token) do
    requirement_sources = requirement_sources()
    issue_sources = issue_sources()
    sources = requirement_sources ++ issue_sources

    queue_tasks = fetch_queue_tasks(token)

    report = reconcile(sources, queue_tasks)

    report |> render() |> IO.write()

    if report.findings == [] do
      :ok
    else
      Mix.raise(
        "mix letflow.check_queue_reconciliation: FAILED -- " <>
          "#{length(report.findings)} finding(s):\n" <>
          Enum.map_join(report.findings, "\n", &format_finding/1)
      )
    end
  end

  @spec requirement_sources() :: [source_ref()]
  defp requirement_sources do
    content =
      case File.read(@requirements_file) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Mix.raise(
            "mix letflow.check_queue_reconciliation: could not read " <>
              "#{@requirements_file}: #{inspect(reason)}"
          )
      end

    content
    |> CheckRequirementsRegistration.scan()
    |> Map.fetch!(:entries)
    |> Enum.filter(fn e -> e.state == :registered and is_integer(e.impl_order) end)
    |> Enum.map(fn e ->
      %{
        kind: :requirement,
        id: e.id,
        yaml_status: e.status || "",
        queue_task_id: e.impl_order
      }
    end)
  end

  @spec issue_sources() :: [source_ref()]
  defp issue_sources do
    @issues_dir
    |> CheckIssueRefs.issue_files()
    |> Enum.flat_map(fn path ->
      case parse_issue_file(File.read!(path), path) do
        :unregistered ->
          []

        {:error, reason} ->
          Mix.raise("mix letflow.check_queue_reconciliation: #{path}: #{reason}")

        %{} = source_ref ->
          [source_ref]
      end
    end)
  end

  # -- pure core ------------------------------------------------------------

  @doc """
  Extracts `id:`, `status:`, `queue_ref:` (column-0 fields, same convention
  as `Mix.Tasks.Letflow.CheckIssueRefs`) from one issue file's content.

  Pure -- takes content and path, not a path to read itself, so hermetic
  fixture strings can be passed directly.
  """
  @spec parse_issue_file(String.t(), String.t()) ::
          source_ref() | :unregistered | {:error, String.t()}
  def parse_issue_file(content, path) when is_binary(content) and is_binary(path) do
    lines = String.split(content, ~r/\r?\n/)

    id = Enum.find_value(lines, &capture(&1, @id_line_re))
    status = Enum.find_value(lines, &capture(&1, @status_line_re))
    queue_ref = Enum.find_value(lines, &capture(&1, @queue_ref_line_re))

    cond do
      id == nil ->
        {:error, "declares no `id` field"}

      status == nil ->
        {:error, "declares no `status` field"}

      queue_ref == nil or queue_ref == "null" ->
        :unregistered

      true ->
        case Regex.run(@queue_ref_ok_re, queue_ref) do
          [_, n] ->
            %{
              kind: :issue,
              id: id,
              yaml_status: status,
              queue_task_id: String.to_integer(n)
            }

          nil ->
            {:error, "`queue_ref: #{queue_ref}` is not a well-formed `Q-<n>`"}
        end
    end
  end

  # NOTE (ISS-0848 fix, REVIEWER finding): must NOT trim leading whitespace
  # before matching `re` -- every `*_line_re` is anchored with `^` precisely
  # so an indented line (e.g. inside a folded `description: >`/`resolution: >`
  # block) can never match a top-level field. Trimming leading whitespace
  # first defeats that anchor and lets prose-that-happens-to-start-with-a-
  # field-name-after-trimming shadow the real field later in the file. Only
  # trailing whitespace (and a trailing inline `# comment`) is stripped here;
  # mirrors `Mix.Tasks.Letflow.CheckIssueRefs.capture/2`'s same fix.
  @spec capture(String.t(), Regex.t()) :: String.t() | nil
  defp capture(line, re) do
    line = line |> String.split("#", parts: 2) |> hd() |> String.trim_trailing()

    case Regex.run(re, line) do
      [_, val] -> val |> String.trim() |> String.trim("\"")
      nil -> nil
    end
  end

  @doc """
  Compares already-parsed `sources` against an already-fetched `queue_tasks`
  list. Pure -- no file reads, no HTTP -- so it is directly fixture-testable.

  **AMENDMENT (§3.3b):** the compatibility mapping consulted is now dispatched
  on `source.kind` -- a `:requirement` source consults §3.3's table, an
  `:issue` source consults §3.3b's table. A `yaml_status` value neither table
  recognizes (for the source's kind) is its own `:unrecognized_yaml_status`
  finding, never folded into `:status_mismatch`.
  """
  @spec reconcile([source_ref()], [queue_task()]) :: report()
  def reconcile(sources, queue_tasks) do
    tasks_by_id = Map.new(queue_tasks, fn t -> {t.id, t} end)

    findings =
      Enum.flat_map(sources, fn source ->
        case Map.fetch(tasks_by_id, source.queue_task_id) do
          :error ->
            [%{kind: :dangling_queue_ref, source: source}]

          {:ok, task} ->
            case compatible_queue_statuses(source.kind, source.yaml_status) do
              nil ->
                [
                  %{
                    kind: :unrecognized_yaml_status,
                    source: source,
                    reason:
                      "no #{source.kind} mapping recognizes yaml status " <>
                        "#{inspect(source.yaml_status)}"
                  }
                ]

              compatible ->
                if task.status in compatible do
                  []
                else
                  [
                    %{
                      kind: :status_mismatch,
                      source: source,
                      queue_status: task.status,
                      reason:
                        "yaml status #{inspect(source.yaml_status)} maps to queue " <>
                          "{#{Enum.join(compatible, ", ")}}; queue task #{task.id} reports " <>
                          "#{inspect(task.status)}"
                    }
                  ]
                end
            end
        end
      end)

    %{
      sources_checked: length(sources),
      queue_tasks_seen: length(queue_tasks),
      findings: findings
    }
  end

  @doc """
  The yaml-status <-> queue-status compatibility mapping, dispatched by
  `source_kind()`. Every mapping direction not explicitly listed here is a
  mismatch -- no everything-else-is-fine branch. `kind` must be given because
  the two vocabularies are separate tables (§3.3 for `:requirement`, §3.3b for
  `:issue`) -- the same spelling can mean different things (or nothing at all)
  depending on which source kind it came from.
  """
  @spec status_compatible?(source_kind(), yaml_status(), queue_status()) :: boolean()
  def status_compatible?(kind, yaml_status, queue_status) do
    case compatible_queue_statuses(kind, yaml_status) do
      nil -> false
      compatible -> queue_status in compatible
    end
  end

  # -- §3.3: requirement-vocabulary mapping (unchanged from the original design)
  @spec compatible_queue_statuses(source_kind(), yaml_status()) :: [queue_status()] | nil
  defp compatible_queue_statuses(:requirement, "done"), do: ["done", "blocked"]
  defp compatible_queue_statuses(:requirement, "in_progress"), do: ["open", "blocked"]
  defp compatible_queue_statuses(:requirement, "pending"), do: ["open"]
  defp compatible_queue_statuses(:requirement, "blocked"), do: ["blocked", "open"]
  defp compatible_queue_statuses(:requirement, "cancelled"), do: ["open", "blocked", "done"]
  defp compatible_queue_statuses(:requirement, _unrecognized), do: nil

  # -- §3.3b (AMENDMENT): issue-vocabulary mapping, separate table
  defp compatible_queue_statuses(:issue, "open"), do: ["open"]
  defp compatible_queue_statuses(:issue, "in_progress"), do: ["open", "blocked"]
  defp compatible_queue_statuses(:issue, "resolved"), do: ["done", "blocked"]
  # instrumented/no_defect: NEVER "done" -- ISSUE_QUEUE.md's explicit rule
  # ("Release the queue task with release_lock(status: "blocked"), not "done"").
  defp compatible_queue_statuses(:issue, "instrumented"), do: ["blocked"]
  defp compatible_queue_statuses(:issue, "no_defect"), do: ["blocked"]
  # AMENDMENT (ISS-0870, 2026-09-27): 6 further legitimate terminal issue-status
  # values, confirmed case-by-case against real files (not typos -- each is a
  # genuinely distinct terminal disposition already in use across dozens of
  # docs/issues/*.yaml records) rather than assumed. All five "closed for a
  # reason other than a shipped fix" spellings map the same as "resolved":
  # a queue release of "done" best-effort-closes the linked GitHub issue,
  # which is the correct outcome for each of these (the issue is settled,
  # not awaiting further work), same as a plain "resolved". "reopened" is
  # the mirror of "open" -- an issue explicitly un-terminaled after a prior
  # resolution attempt didn't hold; it must NOT be treated as done/blocked
  # or a genuinely-still-broken record would report itself reconciled.
  defp compatible_queue_statuses(:issue, "done"), do: ["done", "blocked"]
  defp compatible_queue_statuses(:issue, "resolved_via_duplicate"), do: ["done", "blocked"]
  defp compatible_queue_statuses(:issue, "closed_not_applicable"), do: ["done", "blocked"]
  defp compatible_queue_statuses(:issue, "resolved_not_applicable"), do: ["done", "blocked"]
  defp compatible_queue_statuses(:issue, "declined"), do: ["done", "blocked"]
  defp compatible_queue_statuses(:issue, "reopened"), do: ["open"]
  # Remaining undocumented legacy values (fixed, duplicate) deliberately NOT
  # mapped -- not seen on any live record as of this amendment, still an open
  # question for whoever next encounters one. They fall through to
  # :unrecognized_yaml_status.
  defp compatible_queue_statuses(:issue, _unrecognized), do: nil

  # -- I/O: token resolution -------------------------------------------------

  @doc """
  Resolves `$QUEUE_AUTH_TOKEN`: shell env first, then a `QUEUE_AUTH_TOKEN=`
  line in `./.env` (read directly off disk -- this task must not assume
  `.env` has been loaded into the OS environment by anything else), per
  `docs/agents/protocols/TASK_QUEUE.md`'s documented convention.
  """
  @spec resolve_queue_auth_token() :: {:ok, String.t()} | :none
  def resolve_queue_auth_token do
    case System.get_env("QUEUE_AUTH_TOKEN") do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        resolve_from_env_file()
    end
  end

  @spec resolve_from_env_file() :: {:ok, String.t()} | :none
  defp resolve_from_env_file do
    case File.read(@env_file) do
      {:ok, content} ->
        content
        |> String.split(~r/\r?\n/)
        |> Enum.find_value(:none, fn line ->
          case Regex.run(~r/^QUEUE_AUTH_TOKEN=(.*)$/, String.trim(line)) do
            [_, token] when token != "" -> {:ok, String.trim(token)}
            _ -> nil
          end
        end)

      {:error, _reason} ->
        :none
    end
  end

  # -- I/O: the only network call in this module ----------------------------

  @doc """
  `GET /tasks` against the live queue. Mirrors `Letflow.Webhooks`'
  `do_dispatch_http/3`'s own use of `:httpc` -- no new HTTP client
  dependency. Reads the task list from the `"tasks"` key (confirmed via
  REQ-222's own acceptance criterion and empirical observation -- NOT
  `"data"`). Hard `Mix.raise` on non-2xx, JSON-decode failure, or a response
  missing the `"tasks"` key.
  """
  @spec fetch_queue_tasks(String.t()) :: [queue_task()]
  def fetch_queue_tasks(token) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer #{token}")}
    ]

    request = {String.to_charlist(@queue_tasks_url), headers}

    case :httpc.request(:get, request, [{:timeout, @http_timeout_ms}], []) do
      {:ok, {{_http_version, status_code, _reason_phrase}, _resp_headers, resp_body}}
      when status_code >= 200 and status_code < 300 ->
        decode_tasks_response(to_string(resp_body))

      {:ok, {{_http_version, status_code, _reason_phrase}, _resp_headers, resp_body}} ->
        Mix.raise(
          "mix letflow.check_queue_reconciliation: GET #{@queue_tasks_url} " <>
            "returned HTTP #{status_code}: #{String.slice(to_string(resp_body), 0, 500)}"
        )

      {:error, reason} ->
        Mix.raise(
          "mix letflow.check_queue_reconciliation: GET #{@queue_tasks_url} " <>
            "transport error: #{inspect(reason)}"
        )
    end
  end

  @spec decode_tasks_response(String.t()) :: [queue_task()]
  defp decode_tasks_response(body) do
    decoded =
      try do
        Jason.decode!(body)
      rescue
        e ->
          Mix.raise(
            "mix letflow.check_queue_reconciliation: JSON decode failed: #{Exception.message(e)}"
          )
      end

    case decoded do
      %{"tasks" => tasks} when is_list(tasks) ->
        Enum.map(tasks, &decode_task/1)

      _ ->
        Mix.raise(
          "mix letflow.check_queue_reconciliation: GET /tasks response missing a " <>
            "`\"tasks\"` list key: #{String.slice(body, 0, 500)}"
        )
    end
  end

  # A task object missing `"id"` or `"status"` is the same class of problem as
  # the list missing `"tasks"` entirely -- an unexpected response shape -- so
  # it gets the same `Mix.raise` treatment instead of a raw `KeyError`.
  @spec decode_task(map()) :: queue_task()
  defp decode_task(t) when is_map(t) do
    case {Map.fetch(t, "id"), Map.fetch(t, "status")} do
      {{:ok, id}, {:ok, status}} ->
        %{id: id, status: status, title: Map.get(t, "title")}

      _ ->
        Mix.raise(
          "mix letflow.check_queue_reconciliation: GET /tasks response contains a " <>
            "task object missing `\"id\"` or `\"status\"`: #{inspect(t)}"
        )
    end
  end

  defp decode_task(t) do
    Mix.raise(
      "mix letflow.check_queue_reconciliation: GET /tasks response contains a " <>
        "non-object task entry: #{inspect(t)}"
    )
  end

  # -- rendering -------------------------------------------------------------

  @spec render(report()) :: iodata()
  defp render(report) do
    rule = String.duplicate("=", 72)

    [
      rule,
      "\n",
      "mix letflow.check_queue_reconciliation\n",
      rule,
      "\n",
      "sources checked: #{report.sources_checked}\n",
      "queue tasks seen: #{report.queue_tasks_seen}\n",
      "findings: #{length(report.findings)}\n",
      render_findings(report.findings),
      rule,
      "\n"
    ]
  end

  @spec render_findings([finding()]) :: iodata()
  defp render_findings([]), do: ["OK -- no mismatches or dangling refs.\n"]

  defp render_findings(findings) do
    ["FINDINGS:\n", Enum.map(findings, fn f -> ["  ", format_finding(f), "\n"] end)]
  end

  @spec format_finding(finding()) :: String.t()
  defp format_finding(%{kind: :status_mismatch, source: source, reason: reason}) do
    "[status_mismatch] #{source_label(source)} -> queue task " <>
      "#{source.queue_task_id}: #{reason}"
  end

  defp format_finding(%{kind: :dangling_queue_ref, source: source}) do
    "[dangling_queue_ref] #{source_label(source)} -> queue task " <>
      "#{source.queue_task_id} does not exist"
  end

  defp format_finding(%{kind: :unrecognized_yaml_status, source: source, reason: reason}) do
    "[unrecognized_yaml_status] #{source_label(source)} -> queue task " <>
      "#{source.queue_task_id}: #{reason}"
  end

  @spec source_label(source_ref()) :: String.t()
  defp source_label(%{kind: kind, id: id, yaml_status: yaml_status}) do
    "#{kind} #{id} (yaml status #{inspect(yaml_status)})"
  end
end
