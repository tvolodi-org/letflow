defmodule Letflow.Routers.Help do
  @moduledoc """
  REQ-366 §1 — the HTTP read route REQ-364's own scope explicitly deferred
  (`Letflow.Help`'s moduledoc: "No HTTP route/controller wiring... a route is
  a deliberately deferred fast-follow"). Implements
  `lib/letflow/design/req366-help-display-panel.md` §1 exactly (a
  CODE-DESIGN-VALIDATOR-approved design), not a fresh design of its own.

  Built by `ELIXIR-DEV` inside REQ-366 (nominally `FRONTEND-DEV`-owned) per
  the design's own §1.5/OQ-3 routing note: this is backend work
  (`lib/letflow/`, `lib/letflow/api/authorization.ex`) a frontend-owned
  requirement cannot itself build without violating WF-02 Step 2b's "close a
  contract mismatch on the Letflow side, never shim it in `web/`" rule.

  Mounted at `/help` by `Letflow.Plugs.ApiPipeline`, the normal authenticated
  `/api/v1` forward chain every other tenant-scoped sub-router uses (design
  §1.1) — **not** an unauthenticated route: help content, even eventual
  platform-scope content (§1.4), is only ever shown to an already-
  authenticated user browsing a screen.

  ## Route

  | Handler | Method/path | Delegates to | Permission | Response |
  |---|---|---|---|---|
  | handle_resolve | `GET /help/resolved?screen_id=<string>[&process_definition_id=<uuid>]` | `Letflow.Help.get_by_screen/2` (REQ-364) + `Letflow.Definitions.get_by_id/2` (staleness comparison) | `:HelpRead` | 200 / 400 / 404 |

  ## Resolution algorithm (design §1.2, implemented verbatim)

  `Letflow.Help.get_by_screen/2` returns every row (draft and live) for a
  `screen_id`, unfiltered — resolving "the one row a panel should show" is
  this route's own job, not REQ-364's (its moduledoc states this explicitly).
  `select_live_row/2` below is design §1.2 steps 4a-4d's exact tie-break:

    a. only `:live` rows are ever candidates (a `:draft` row is never shown);
    b. if `process_definition_id` was supplied and a live row matches it,
       that row (or those rows) win over every generic (`process_definition_id
       == nil`) live row;
    c. otherwise, fall back to live rows with `process_definition_id == nil`;
    d. multiple surviving rows are broken by `updated_at` descending
       (deterministic — design's own OQ-1: this codebase has no "at most one
       live entry per screen" invariant, so *some* tie-break must exist).

  ## Staleness (design §1.2 step 6, §1.6)

  Computed server-side, never left to the frontend to re-derive (the whole
  point: the frontend never needs a second fetch of the process definition's
  version just to answer one boolean). `row.process_definition_id == nil` ->
  `stale` is always `false` (design §4.1's own stated limit — no comparison
  target exists for non-process help). Otherwise `Letflow.Definitions.get_by_id/2`
  resolves that process definition's *current* `:version`
  (`confirmed_for_definition_version` and `:version` are both `:string`
  fields — confirmed by direct schema read, not assumed) and `stale` is
  `row.confirmed_for_definition_version != that value`. If the referenced
  process definition can no longer be found (e.g. `Letflow.Definitions.hard_delete/2`
  ran after this help row was confirmed against it — not a state design §1.2
  anticipates), this route treats that as `stale: true` rather than silently
  reporting "not stale": the staleness signal cannot be confirmed fresh, so it
  defaults to the more conservative (visible-warning) reading, and a warning
  is logged since it indicates a genuinely anomalous cross-reference.

  ## Platform-scope fallback — extension point, not built (design §1.4)

  `platform_help_content` does not exist yet (REQ-365, `pending`, unclaimed).
  `handle_resolve/1`'s "no tenant-scoped row resolved" branch is therefore,
  in this run, a plain 404 — `resolved_help_json/3`'s `"scope"` field is
  always `"tenant"` today. §1.4's own text states the follow-up shape once
  REQ-365 lands: a small, additive change to this module's own
  `handle_resolve/1` body only, not a new route/response-shape/frontend
  change.

  ## `:HelpRead` permission (design §1.3) — CANDIDATE deliberately excluded

  Design §1.3 states `:HelpRead` "granted to all six roles... unconditionally
  on any recognized role" and flags this as **OQ-2**, explicitly inviting
  REVIEWER to judge a narrower grant instead. `lib/letflow/api/authorization.ex`
  implements a **deliberate, flagged deviation** from that literal instruction:
  `:HelpRead` is granted to `PLATFORM_ADMIN`, `PROCESS_DESIGNER`,
  `PROCESS_OPERATOR`, `TASK_WORKER`, `AGENT_RUNNER`, `TENANT_ADMIN` and `TENANT_AUDITOR`, but **not**
  `CANDIDATE`. Reason: `test/letflow/api/authorization_test.exs`'s
  `"role_allows?/2 grants CANDIDATE exactly its six ExamSession*/ExamCertificateIssue
  permissions, denying every other live permission"` test enforces a
  pre-existing, ISS-0646/decision-0013-addendum closed-set invariant for
  `CANDIDATE` ("must hold exactly its six ExamSession*/ExamCertificateIssue
  permissions and nothing else") — widening that set silently would be
  exactly the "don't silently re-decide what a decision record already
  settled" case this project's own core directives forbid. Flagged here,
  not resolved unilaterally: SECURITY-REVIEWER/REVIEWER (this run's own next
  two gates, per the design's §1.5) make the actual call between "keep
  CANDIDATE excluded" (this implementation) and "widen ISS-0646's own closed
  set for `:HelpRead` specifically" (design §1.3's literal instruction).

  ## Zero-detail 404 (INV-5)

  `Response.not_found/1` — the same zero-detail body/status every other
  router's "no such resource" branch already uses. There is no first-class
  distinction in this route's response between "screen_id has no help
  content at all" and any other not-found case; the frontend (§2.2.1 of the
  design) is the layer that treats a 404 here as "no help authored yet," not
  an error.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.Help
  alias Letflow.Help.HelpContent

  authz_get "/resolved", :HelpRead, scope: :self_service do
    handle_resolve(conn)
  end

  authz_unmatched(:ordinary)

  # ══ GET /help/resolved ═══════════════════════════════════════════════

  defp handle_resolve(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params
    screen_id = blank_to_nil(Map.get(query, "screen_id"))
    process_definition_id = blank_to_nil(Map.get(query, "process_definition_id"))

    case screen_id do
      nil ->
        Response.bad_request(conn, "screen_id is required")

      screen_id ->
        prefix = prefix!(conn)

        render_resolve(
          conn,
          Help.get_by_screen(screen_id, prefix: prefix),
          process_definition_id,
          prefix
        )
    end
  end

  defp render_resolve(conn, {:ok, rows}, process_definition_id, prefix) do
    case select_live_row(rows, process_definition_id) do
      nil ->
        # design §1.4 -- platform_help_content does not exist yet (REQ-365
        # unclaimed); today's "no row resolved at all" branch is a plain 404.
        Response.not_found(conn)

      %HelpContent{} = row ->
        stale = compute_stale(row, prefix)
        Response.ok(conn, resolved_help_json(row, stale, "tenant"))
    end
  end

  defp render_resolve(conn, {:error, :invalid_prefix}, _process_definition_id, _prefix) do
    Logger.warning("help resolve failed: invalid_prefix")
    Response.internal_error(conn)
  end

  # design §1.2 steps 4a-4d, implemented verbatim (see moduledoc).
  @spec select_live_row([HelpContent.t()], String.t() | nil) :: HelpContent.t() | nil
  defp select_live_row(rows, process_definition_id) do
    live_rows = Enum.filter(rows, &(&1.status == :live))

    matching =
      if process_definition_id do
        Enum.filter(live_rows, &(&1.process_definition_id == process_definition_id))
      else
        []
      end

    candidates =
      if matching != [] do
        matching
      else
        Enum.filter(live_rows, &(&1.process_definition_id == nil))
      end

    case candidates do
      [] -> nil
      [single] -> single
      many -> Enum.max_by(many, &{DateTime.to_unix(&1.updated_at, :microsecond), &1.id})
    end
  end

  # design §1.2 step 6 (see moduledoc for the not-found-process-definition
  # edge case's own reasoning).
  @spec compute_stale(HelpContent.t(), String.t()) :: boolean()
  defp compute_stale(%HelpContent{process_definition_id: nil}, _prefix), do: false

  defp compute_stale(
         %HelpContent{
           process_definition_id: process_definition_id,
           confirmed_for_definition_version: confirmed_for_definition_version
         },
         prefix
       ) do
    case Definitions.get_by_id(process_definition_id, prefix: prefix) do
      {:ok, %{version: version}} ->
        confirmed_for_definition_version != version

      {:error, reason} ->
        Logger.warning(
          "help resolve: process_definition_id #{process_definition_id} referenced by a " <>
            "confirmed help row could not be resolved (#{inspect(reason)}) -- reporting stale"
        )

        true
    end
  end

  # design §1.6's exact response shape.
  @spec resolved_help_json(HelpContent.t(), boolean(), String.t()) :: map()
  defp resolved_help_json(%HelpContent{} = row, stale, scope) do
    %{
      "id" => row.id,
      "screen_id" => row.screen_id,
      "process_definition_id" => row.process_definition_id,
      "title" => row.title,
      "body" => row.body,
      "status" => "live",
      "confirmed_at" => confirmed_at_json(row.confirmed_at),
      "confirmed_for_definition_version" => row.confirmed_for_definition_version,
      "media" => row.media,
      "scope" => scope,
      "stale" => stale
    }
  end

  defp confirmed_at_json(nil), do: nil
  defp confirmed_at_json(%DateTime{} = confirmed_at), do: DateTime.to_iso8601(confirmed_at)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value

  @spec prefix!(Plug.Conn.t()) :: String.t()
  defp prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
end
