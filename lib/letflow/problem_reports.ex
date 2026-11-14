defmodule Letflow.ProblemReports do
  @moduledoc """
  T-1948 (maintenance slice 1, `docs/design/platform-maintenance.md`): "Report a problem". A signed-in
  user, after saying yes on screen, copies a cut-down, redacted record into the platform company.

  ## Decisions

    * D1: rows live in `problem_reports`, written ONLY in the platform company's schema
      (`Letflow.PlatformTenant.platform_prefix/0`, from server configuration, never from the request).
      The table exists empty in every other schema, so customer text stays behind a schema prefix (INV-1).
    * D3: reporter facts (user, name, company, roles, permissions, version, trace id) come from the server.
      Identifiers in the body are ignored (INV-10).
    * D4: `consent` must be the JSON boolean `true`; anything else writes nothing.
    * D5: `Letflow.ProblemReports.Capture` is a whitelist with caps, then a text mask.
    * D7: one audit entry `problem_report.sent` in the REPORTER's own company, in the same transaction,
      holding the number and the sent field names, never the text. The customer's auditor can see that
      data left the company.
    * D8: at most 10 reports per user per rolling hour (counted in the platform table).

  The export (`list_after/3`) feeds the PM handoff; the owner inbox and `list_mine/2` read
  status for the owner and the reporter respectively. Decisions are row-locked and audited without
  text (D9); bell/mail status is best effort after commit (D10). Nothing logs text, context or names.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.BuildInfo
  alias Letflow.Identity
  alias Letflow.PlatformTenant
  alias Letflow.ProblemReports.Capture
  alias Letflow.ProblemReports.Report
  alias Letflow.Repo

  @throttle_per_hour 10
  @default_settle_seconds 30
  @max_trace_id 64

  @type submit_result ::
          {:ok, %{id: String.t(), number: String.t(), received_at: DateTime.t()}}
          | {:error,
             :consent_required | {:invalid, String.t()} | :throttled | :unavailable | :internal}

  @doc """
  Stores one report. `auth_context` supplies the reporter's ids; `caller_prefix` is the reporter's own
  company schema. Options: `roles:` and `permissions:` (string lists computed by the router, as
  `/me/access` does), `trace_id:`, `now:` (tests).
  """
  @spec submit(map(), String.t(), term(), keyword()) :: submit_result()
  def submit(auth_context, caller_prefix, body, opts \\ [])
      when is_map(auth_context) and is_binary(caller_prefix) do
    with :ok <- check_consent(body),
         {:ok, parsed} <- Capture.parse(body),
         {:ok, platform_prefix} <- platform_prefix(),
         {:ok, platform_tenant_id} <- platform_tenant_id(platform_prefix),
         now = Keyword.get(opts, :now, DateTime.utc_now()),
         :ok <- check_throttle(platform_prefix, auth_context.user_id, now) do
      insert(auth_context, caller_prefix, platform_prefix, platform_tenant_id, parsed, now, opts)
    end
  end

  defp check_consent(%{"consent" => true}), do: :ok
  defp check_consent(_other), do: {:error, :consent_required}

  defp platform_prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :unavailable}
    end
  end

  defp platform_tenant_id(prefix) do
    case Letflow.TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :unavailable}
    end
  end

  defp check_throttle(platform_prefix, user_id, now) do
    since = DateTime.add(now, -3600, :second)

    count =
      Repo.aggregate(
        from(r in Report, where: r.reporter_user_id == ^user_id and r.inserted_at > ^since),
        :count,
        prefix: platform_prefix
      )

    if count >= @throttle_per_hour, do: {:error, :throttled}, else: :ok
  end

  # The columns are varchar(200); an over-long display name must not make every report fail.
  defp clip_name(name) when is_binary(name), do: String.slice(name, 0, 200)
  defp clip_name(other), do: other

  defp insert(auth_context, caller_prefix, platform_prefix, platform_tenant_id, parsed, now, opts) do
    tenant_name =
      case Identity.get_tenant(auth_context.tenant_id) do
        {:ok, tenant} -> tenant.display_name
        _ -> nil
      end

    user_name =
      case Identity.get_user(auth_context.user_id, prefix: caller_prefix) do
        {:ok, user} -> user.display_name
        _ -> nil
      end

    report = %Report{
      tenant_id: platform_tenant_id,
      reporter_tenant_id: auth_context.tenant_id,
      reporter_tenant_name: clip_name(tenant_name),
      reporter_user_id: auth_context.user_id,
      reporter_name: clip_name(user_name),
      reporter_roles: Keyword.get(opts, :roles, []),
      reporter_permissions: Keyword.get(opts, :permissions, []),
      text: parsed.text,
      context: parsed.context,
      server_version: BuildInfo.sha(),
      trace_id: trace_id(Keyword.get(opts, :trace_id)),
      consented_at: now,
      inserted_at: now
    }

    multi =
      Multi.new()
      |> Multi.insert(:report, report, prefix: platform_prefix)
      |> Multi.run(:audit, fn repo, %{report: stored} ->
        Audit.insert_entry(
          repo,
          %{
            actor_id: auth_context.user_id,
            action: "problem_report.sent",
            resource_type: "problem_report",
            resource_id: number(stored),
            before_state: nil,
            after_state: %{
              "number" => number(stored),
              "sent_fields" => parsed.context |> Map.keys() |> Kernel.++(["text"]) |> Enum.sort(),
              "to" => "platform_company"
            }
          },
          caller_prefix
        )
      end)

    case Repo.transaction(multi) do
      {:ok, %{report: stored}} ->
        Letflow.ProblemReports.Status.notify(stored, :received)
        {:ok, %{id: stored.id, number: number(stored), received_at: stored.consented_at}}

      {:error, _step, _reason, _changes} ->
        {:error, :internal}
    end
  rescue
    error ->
      # INV-4 / INV-8: the exception module only; a message could carry the report text.
      Logger.error("problem report submit failed: #{inspect(error.__struct__)}")
      {:error, :internal}
  end

  defp trace_id(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, @max_trace_id)

  defp trace_id(_other), do: nil

  @doc "The number shown to the user and the export cursor: `SR-<seq>`."
  @spec number(Report.t()) :: String.t()
  def number(%Report{seq: seq}), do: "SR-" <> Integer.to_string(seq)

  @doc """
  The export read: reports with `seq > after_seq`, oldest first, at most `limit`, held back while younger
  than `settle_seconds` (default 30). `seq` is taken at insert, before commit, so
  without the window a higher seq could commit first and a poller would skip the lower one for good.
  Plain maps built by hand (INV-2); the reporter's e-mail is never part of them.
  """
  @spec list_after(non_neg_integer(), 1..100, keyword()) ::
          {:ok, %{reports: [map()], next_after: non_neg_integer()}} | {:error, :unavailable}
  def list_after(after_seq, limit, opts \\ [])
      when is_integer(after_seq) and after_seq >= 0 and limit in 1..100 do
    with {:ok, prefix} <- platform_prefix() do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      settle = Keyword.get(opts, :settle_seconds, @default_settle_seconds)
      cutoff = DateTime.add(now, -settle, :second)

      rows =
        Repo.all(
          from(r in Report,
            where: r.seq > ^after_seq and r.inserted_at <= ^cutoff,
            order_by: [asc: r.seq],
            limit: ^limit
          ),
          prefix: prefix
        )

      next_after = rows |> List.last() |> then(&if(&1, do: &1.seq, else: after_seq))
      {:ok, %{reports: Enum.map(rows, &export_map/1), next_after: next_after}}
    end
  end

  @doc "The reporter's newest 50 reports, filtering BOTH company and user ids from auth context."
  def list_mine(tenant_id, user_id) do
    with {:ok, prefix} <- platform_prefix() do
      rows =
        Repo.all(
          from(r in Report,
            where: r.reporter_tenant_id == ^tenant_id and r.reporter_user_id == ^user_id,
            order_by: [desc: r.seq],
            limit: 51
          ),
          prefix: prefix
        )

      {:ok,
       %{"reports" => Enum.map(Enum.take(rows, 50), &own_map/1), "has_more" => length(rows) > 50}}
    end
  rescue
    _ -> {:error, :internal}
  end

  defp own_map(r) do
    question = r.status == "in_work" and r.last_action == "ask"

    %{
      "id" => r.id,
      "number" => number(r),
      "status" => r.status,
      "question" => question,
      "reply_text" =>
        if(question or r.status in ~w(answered fixed not_done), do: r.reply_text, else: nil),
      "text" => r.text,
      "received_at" => r.consented_at,
      "decided_at" => r.decided_at
    }
  end

  defp export_map(%Report{} = report) do
    %{
      "number" => number(report),
      "received_at" => DateTime.to_iso8601(report.consented_at),
      "reporter" => %{
        "tenant_id" => report.reporter_tenant_id,
        "tenant_name" => report.reporter_tenant_name,
        "user_id" => report.reporter_user_id,
        "name" => report.reporter_name,
        "roles" => report.reporter_roles,
        "permissions" => report.reporter_permissions
      },
      "text" => report.text,
      "context" => report.context,
      "server_version" => report.server_version,
      "trace_id" => report.trace_id
    }
  end
end
