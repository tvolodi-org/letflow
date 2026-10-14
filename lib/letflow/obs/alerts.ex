defmodule Letflow.Obs.Alerts do
  @moduledoc """
  Threshold detection with edge-triggered firing and retry/backoff delivery
  for alerting hooks (OBS-06, REQ-201).

  ## Alerting hooks vs. webhook subscriptions — distinct mechanisms

  Alerting hooks (this module) and webhook subscriptions (REQ-181/183) are
  **two distinct mechanisms that must never be merged**, even though both
  POST JSON to a configured URL with retry/backoff. The distinctions are
  load-bearing:

  | Property | Alerting hooks (REQ-201) | Webhook subscriptions (REQ-181/183) |
  |---|---|---|
  | Audience | Platform operator diagnostics | Tenant-facing event delivery |
  | Configuration | Application config — no API, no route | Tenant API (`POST /webhooks/subscriptions`) |
  | Triggers | Fixed set of five: `instance_error_stuck`, `dlq_depth_threshold`, `scheduler_lag_threshold`, `webhook_subscription_paused`, `script_hmac_secret_missing` (GH 2534 7c, fired by the script dispatcher, not by `run_detection/2`) | Any domain event type |
  | Signing | None (optional `auth_secret_ref` via REQ-190) | HMAC-SHA256 `X-Letflow-Signature` mandatory |
  | Auto-pause | No | Yes — `consecutive_failures >= 5` → PAUSED |
  | Delivery failure terminal action | Log via REQ-193 and drop | Land in `dlq_entries` |
  | DLQ landing | **Never** | Yes |

  ## No DLQ landing for exhausted alert delivery

  Exhausted alert hook delivery (all retry attempts failed) logs one
  error-level entry via `Letflow.Obs.Logger` and drops the payload. No
  `dlq_entries` row is written, per OBS-06's explicit design
  (design doc §0.1). Any future change making alert delivery land in the
  DLQ requires a new requirement and REVIEWER sign-off.

  ## No route or controller

  Alert hooks are configured through application config
  (`config :letflow, :alert_hooks, [...]`), not through any API. No route
  file, no controller, and no Plug module is added or modified by this
  module.

  ## No new periodic process, but one new dispatch-only child (ISS-0429)

  Detection still runs on REQ-186's existing `Letflow.Scheduler.Poller` tick
  cadence via `run_detection/2` — this module still owns no ticker of its
  own. As of ISS-0429 (design
  `lib/letflow/design/iss0429-async-alert-hook-delivery.md`), `fire_hooks/4`
  dispatches each hook's `deliver_with_retry/4` call (HTTP POST + its own
  internal retry/backoff loop) as a fire-and-forget task under a new,
  dedicated `Letflow.Obs.Alerts.TaskSupervisor` child of
  `Letflow.Application`, instead of running it synchronously on the
  Poller's own process. This keeps the Poller's `handle_info(:tick, _)`
  from blocking on a slow or unreachable hook endpoint's retry/backoff
  schedule — see ISS-0429 for the full incident. `check_and_record_emission/4`
  is unaffected: it still runs synchronously, on the calling process,
  committed before any dispatch decision.

  ## OQ-1 resolution (auth_secret_ref namespace)

  `Letflow.Secrets.resolve/2` requires `[tenant_id: uuid]` in opts; the
  namespace is embedded in the reference string itself
  (`sec://tenant/<slug>/alert_hook/<name>`). `"alert_hook"` matches
  `~r/^[a-z0-9_-]+$/` and is a valid namespace. To resolve, the tenant_id
  is derived from the reference's own slug via
  `Letflow.Identity.get_tenant_by_slug/1`. Resolution failure omits the
  Authorization header (logged at warning level).

  ## OQ-2 resolution (Letflow.Dlq.count_entries/1)

  `Letflow.Dlq.count_entries/2` was added to `Letflow.Dlq` as a read-only
  aggregate following the existing `opts :: [prefix: String.t()]` pattern.

  ## OQ-3 resolution (paused subscription query window)

  `paused_at >= state.last_tick_started_at` is used. If
  `last_tick_started_at` is nil (first tick), the paused-subscription check
  is skipped entirely.

  ## OQ-4 resolution (no application.ex change) — superseded by ISS-0429

  `Letflow.Obs.Alerts` still has no process of its own: `run_detection/2`
  remains a pure function called from the Poller's tick, and this module
  still defines no `start_link/1` or `child_spec/1`. This no longer means
  `application.ex` is unchanged, though: ISS-0429 added one child,
  `{Task.Supervisor, name: Letflow.Obs.Alerts.TaskSupervisor}`, purely to
  isolate `deliver_with_retry/4`'s HTTP delivery work from the Poller's own
  process (see "No new periodic process, but one new dispatch-only child"
  above). That supervisor owns no state and makes no decisions of its own —
  it exists only so `fire_hooks/4` has somewhere supervised to dispatch a
  detached delivery task, the same pattern this codebase's other six
  domain-scoped `Task.Supervisor` children already follow.
  """

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Dlq
  alias Letflow.Identity
  alias Letflow.Obs.AlertHookEmissionState
  alias Letflow.Obs.AlertTriggerState
  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.Webhooks.Subscription

  # ---------------------------------------------------------------------------
  # Config structs
  # ---------------------------------------------------------------------------

  defmodule RetryPolicy do
    @moduledoc "Retry/backoff policy for one alert hook's delivery attempts."

    @enforce_keys [:max_attempts, :base_backoff_ms, :max_backoff_ms, :multiplier]
    defstruct max_attempts: 3,
              base_backoff_ms: 1_000,
              max_backoff_ms: 30_000,
              multiplier: 2.0

    @type t :: %__MODULE__{
            max_attempts: pos_integer(),
            base_backoff_ms: pos_integer(),
            max_backoff_ms: pos_integer(),
            multiplier: float()
          }
  end

  defmodule AlertHookConfig do
    @moduledoc "Per-hook delivery configuration loaded from application config."

    @enforce_keys [:hook_id, :enabled, :destination_url, :timeout_ms, :retry_policy]
    defstruct hook_id: nil,
              enabled: true,
              destination_url: nil,
              timeout_ms: 5_000,
              auth_secret_ref: nil,
              retry_policy: nil

    @type t :: %__MODULE__{
            hook_id: String.t(),
            enabled: boolean(),
            destination_url: String.t(),
            timeout_ms: pos_integer(),
            auth_secret_ref: String.t() | nil,
            retry_policy: RetryPolicy.t()
          }
  end

  defmodule AlertThresholds do
    @moduledoc "Threshold values for the four trigger types."

    @enforce_keys [:error_stuck_minutes, :dlq_depth_threshold, :scheduler_lag_ms]
    defstruct error_stuck_minutes: 10,
              dlq_depth_threshold: 100,
              scheduler_lag_ms: 15_000

    @type t :: %__MODULE__{
            error_stuck_minutes: pos_integer(),
            dlq_depth_threshold: pos_integer(),
            scheduler_lag_ms: pos_integer()
          }
  end

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type tick_context :: %{
          dlq_count: non_neg_integer(),
          observed_lag_ms: non_neg_integer() | nil,
          stuck_instances: [stuck_instance()],
          recently_paused_subs: [paused_subscription()]
        }

  @type stuck_instance :: %{
          instance_id: Ecto.UUID.t(),
          error_reason: String.t(),
          stuck_minutes: non_neg_integer()
        }

  @type paused_subscription :: %{
          subscription_id: Ecto.UUID.t()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Entry point called once per tenant schema per Poller tick. Reads config
  fresh from `Application.get_env(:letflow, :alert_hooks)` on every call.
  Never raises — all errors are caught internally and logged via
  `Letflow.Obs.Logger`.
  """
  @spec run_detection(tenant_schema :: String.t(), tick_context :: tick_context()) :: :ok
  def run_detection(tenant_schema, tick_context) do
    cfg = Application.get_env(:letflow, :alert_hooks, [])

    unless Keyword.get(cfg, :enabled, false) do
      :ok
    else
      do_run_detection(tenant_schema, tick_context, cfg)
    end
  rescue
    err ->
      Logger.error("alert detection crashed",
        component: "alert_detection",
        tenant_schema: tenant_schema,
        error: inspect(err)
      )

      :ok
  end

  # ---------------------------------------------------------------------------
  # Internal detection
  # ---------------------------------------------------------------------------

  defp do_run_detection(tenant_schema, tick_context, cfg) do
    thresholds = build_thresholds(cfg)
    hooks = build_hooks(cfg)

    evaluate_dlq_depth(
      tenant_schema,
      tick_context.dlq_count,
      thresholds.dlq_depth_threshold,
      hooks
    )

    evaluate_scheduler_lag(
      tenant_schema,
      tick_context.observed_lag_ms,
      thresholds.scheduler_lag_ms,
      hooks
    )

    Enum.each(tick_context.stuck_instances, fn inst ->
      evaluate_stuck_instance(tenant_schema, inst, thresholds.error_stuck_minutes, hooks)
    end)

    Enum.each(tick_context.recently_paused_subs, fn sub ->
      evaluate_paused_subscription(tenant_schema, sub, hooks)
    end)

    :ok
  end

  defp evaluate_dlq_depth(tenant_schema, depth, threshold, hooks) do
    trigger_key = "dlq_depth_threshold"
    evaluate_trigger(trigger_key, depth, threshold, hooks, tenant_schema, nil)
  end

  defp evaluate_scheduler_lag(_tenant_schema, nil, _threshold, _hooks), do: :ok

  defp evaluate_scheduler_lag(tenant_schema, observed_lag_ms, threshold, hooks) do
    trigger_key = "scheduler_lag_threshold"
    evaluate_trigger(trigger_key, observed_lag_ms, threshold, hooks, tenant_schema, nil)
  end

  defp evaluate_stuck_instance(tenant_schema, inst, threshold_minutes, hooks) do
    trigger_key = "instance_error_stuck:#{inst.instance_id}"

    payload = %{
      "trigger" => "instance_error_stuck",
      "fired_at" => format_datetime(DateTime.utc_now()),
      "instance_id" => inst.instance_id,
      "error_reason" => inst.error_reason,
      "stuck_duration_minutes" => inst.stuck_minutes
    }

    # Design §5 maps "stuck_minutes >= threshold_minutes" to "sample > threshold".
    # Pass (threshold_minutes - 1) so that stuck_minutes >= threshold_minutes
    # satisfies the evaluate_trigger fire condition (sample > effective_threshold).
    effective_threshold = max(threshold_minutes - 1, 0)

    evaluate_trigger(
      trigger_key,
      inst.stuck_minutes,
      effective_threshold,
      hooks,
      tenant_schema,
      inst.instance_id,
      payload
    )
  end

  defp evaluate_paused_subscription(tenant_schema, sub, hooks) do
    trigger_key = "webhook_subscription_paused:#{sub.subscription_id}"
    # paused subscription is always "above threshold" (binary event: paused or not)
    # Sample value of 1 represents "paused"; threshold of 0 means any paused sub fires
    evaluate_trigger(trigger_key, 1, 0, hooks, tenant_schema, sub.subscription_id)
  end

  # Core edge-triggered state machine. Uses ARMED/FIRED states per design §5.
  # `correlation_id` is the subject UUID for per-instance/per-subscription triggers, nil for aggregates.
  defp evaluate_trigger(
         trigger_key,
         sample,
         threshold,
         hooks,
         tenant_schema,
         correlation_id,
         payload \\ nil
       ) do
    now = DateTime.utc_now()
    state = load_trigger_state(trigger_key, tenant_schema)

    if state.is_armed do
      if sample > threshold do
        # ARMED + above threshold → fire and disarm
        fired_payload = payload || build_default_payload(trigger_key, sample, threshold, now)
        fire_hooks(hooks, trigger_key, fired_payload, tenant_schema)

        upsert_trigger_state(
          %{
            trigger_key: trigger_key,
            is_armed: false,
            last_sample_value: sample,
            last_fired_at: now,
            last_correlation_id: correlation_id,
            updated_at: now
          },
          tenant_schema
        )
      end

      # ARMED + at/below threshold → no action
    else
      if sample <= threshold do
        # FIRED + back below threshold → re-arm. ISS-0558: also clears every
        # `alert_hook_emission_state` row for this trigger_key (across all
        # hooks, past or present configuration -- see design §4) so a later
        # firing cycle with a coincidentally-identical `emitted_key` is not
        # silently swallowed by check_and_record_emission/4's dedup match.
        # Both writes commit atomically via one Ecto.Multi/transaction.
        rearm_and_clear_emissions(
          %{
            trigger_key: trigger_key,
            is_armed: true,
            last_sample_value: sample,
            last_fired_at: state.last_fired_at,
            last_correlation_id: state.last_correlation_id,
            updated_at: now
          },
          trigger_key,
          tenant_schema
        )
      else
        # FIRED + still above threshold → update sample only (no re-fire)
        upsert_trigger_state(
          %{
            trigger_key: trigger_key,
            is_armed: false,
            last_sample_value: sample,
            last_fired_at: state.last_fired_at,
            last_correlation_id: state.last_correlation_id,
            updated_at: now
          },
          tenant_schema
        )
      end
    end
  end

  defp build_default_payload("dlq_depth_threshold", sample, threshold, now) do
    %{
      "trigger" => "dlq_depth_threshold",
      "fired_at" => format_datetime(now),
      "current_depth" => sample,
      "threshold" => threshold
    }
  end

  defp build_default_payload("scheduler_lag_threshold", sample, threshold, now) do
    %{
      "trigger" => "scheduler_lag_threshold",
      "fired_at" => format_datetime(now),
      "observed_lag_ms" => sample,
      "threshold_ms" => threshold
    }
  end

  defp build_default_payload(
         "webhook_subscription_paused:" <> subscription_id,
         _sample,
         _threshold,
         now
       ) do
    %{
      "trigger" => "webhook_subscription_paused",
      "fired_at" => format_datetime(now),
      "subscription_id" => subscription_id
    }
  end

  defp build_default_payload(_trigger_key, _sample, _threshold, _now), do: %{}

  # ---------------------------------------------------------------------------
  # State management
  # ---------------------------------------------------------------------------

  @spec load_trigger_state(String.t(), String.t()) :: AlertTriggerState.t()
  defp load_trigger_state(trigger_key, tenant_schema) do
    case Repo.get(AlertTriggerState, trigger_key, prefix: tenant_schema) do
      nil ->
        # Default: ARMED, no prior firing
        %AlertTriggerState{
          trigger_key: trigger_key,
          is_armed: true,
          last_sample_value: 0,
          last_fired_at: nil,
          last_correlation_id: nil,
          updated_at: DateTime.utc_now()
        }

      existing ->
        existing
    end
  end

  defp upsert_trigger_state(attrs, tenant_schema) do
    %AlertTriggerState{}
    |> struct(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: [:trigger_key],
      prefix: tenant_schema
    )
  end

  # ISS-0558 fix: the FIRED->ARMED re-arm branch's write. Deletes every
  # `alert_hook_emission_state` row for this trigger_key (no hook_id filter --
  # design §4: a hook disabled during the firing cycle and later re-enabled
  # must not inherit a stale dedup row) and upserts the trigger state, both in
  # one Ecto.Multi/transaction so no observer can see one write without the
  # other (design §2).
  @spec rearm_and_clear_emissions(
          attrs :: map(),
          trigger_key :: String.t(),
          tenant_schema :: String.t()
        ) ::
          {:ok, term()} | {:error, term(), term(), map()}
  defp rearm_and_clear_emissions(attrs, trigger_key, tenant_schema) do
    emission_query =
      from(e in AlertHookEmissionState, where: e.trigger_key == ^trigger_key)

    Multi.new()
    |> Multi.delete_all(:clear_emissions, emission_query, prefix: tenant_schema)
    |> Multi.insert(
      :trigger_state,
      struct(%AlertTriggerState{}, attrs),
      on_conflict: :replace_all,
      conflict_target: [:trigger_key],
      prefix: tenant_schema
    )
    |> Repo.transaction()
  end

  # ---------------------------------------------------------------------------
  # Hook delivery
  # ---------------------------------------------------------------------------

  @spec fire_hooks(
          hooks :: [AlertHookConfig.t()],
          trigger_key :: String.t(),
          payload :: map(),
          tenant_schema :: String.t()
        ) :: :ok
  defp fire_hooks(hooks, trigger_key, payload, tenant_schema) do
    Enum.each(hooks, fn hook ->
      if hook.enabled do
        emitted_key = build_emitted_key(trigger_key, payload)

        case check_and_record_emission(hook.hook_id, trigger_key, emitted_key, tenant_schema) do
          :already_emitted ->
            :ok

          :ok ->
            # ISS-0429: fire-and-forget dispatch, not `async_nolink` + `handle_info`
            # correlation -- see this module's moduledoc and the design doc's §3 for
            # why. Nothing reads deliver_with_retry/4's return value (never did, even
            # when called synchronously); Task.Supervisor.start_child/2's own return
            # value is discarded too -- a start_child/2 failure is a Task.Supervisor
            # machinery failure, not an alert-delivery failure. Crash observability for
            # an unanticipated raise inside deliver_with_retry/4 comes from
            # Task.Supervisor's own supervised-task crash-report/logging path, not from
            # anything this call site needs to add.
            Task.Supervisor.start_child(Letflow.Obs.Alerts.TaskSupervisor, fn ->
              deliver_with_retry(hook, payload, trigger_key, 1)
            end)
        end
      end
    end)
  end

  # Returns :ok to proceed or :already_emitted to skip
  defp check_and_record_emission(hook_id, trigger_key, emitted_key, tenant_schema) do
    case Repo.get_by(AlertHookEmissionState, [hook_id: hook_id, trigger_key: trigger_key],
           prefix: tenant_schema
         ) do
      %AlertHookEmissionState{last_emitted_key: ^emitted_key} ->
        :already_emitted

      _ ->
        now = DateTime.utc_now()

        %AlertHookEmissionState{}
        |> struct(%{
          hook_id: hook_id,
          trigger_key: trigger_key,
          last_emitted_key: emitted_key,
          updated_at: now
        })
        |> Repo.insert(
          on_conflict: :replace_all,
          conflict_target: [:hook_id, :trigger_key],
          prefix: tenant_schema
        )

        :ok
    end
  end

  defp build_emitted_key("instance_error_stuck:" <> instance_id, payload) do
    reason_hash =
      :crypto.hash(:md5, Map.get(payload, "error_reason", "")) |> Base.encode16(case: :lower)

    "#{instance_id}:#{reason_hash}"
  end

  defp build_emitted_key("dlq_depth_threshold", payload) do
    "depth:#{Map.get(payload, "current_depth", 0)}"
  end

  defp build_emitted_key("scheduler_lag_threshold", payload) do
    "lag:#{Map.get(payload, "observed_lag_ms", 0)}"
  end

  defp build_emitted_key("webhook_subscription_paused:" <> subscription_id, _payload) do
    subscription_id
  end

  defp build_emitted_key(_trigger_key, _payload), do: "unknown"

  @spec deliver_with_retry(AlertHookConfig.t(), map(), String.t(), pos_integer()) ::
          :ok | {:error, :exhausted}
  defp deliver_with_retry(hook, payload, trigger_key, attempt) do
    policy = hook.retry_policy
    json_body = Jason.encode!(payload)

    auth_header = resolve_auth_header(hook.auth_secret_ref)
    headers = build_headers(auth_header)
    request = {String.to_charlist(hook.destination_url), headers, ~c"application/json", json_body}

    result =
      case :httpc.request(:post, request, [{:timeout, hook.timeout_ms}], []) do
        {:ok, {{_ver, status, _reason}, _headers, _body}} when status >= 200 and status < 300 ->
          :ok

        {:ok, {{_ver, status, _reason}, _headers, resp_body}} ->
          body_snippet = resp_body |> to_string() |> String.slice(0, 200)
          {:error, "HTTP #{status}: #{body_snippet}"}

        {:error, reason} ->
          {:error, "transport error: #{inspect(reason)}"}
      end

    case result do
      :ok ->
        :ok

      {:error, last_error} when attempt >= policy.max_attempts ->
        Logger.error("alert delivery exhausted",
          component: "alert_delivery",
          hook_id: hook.hook_id,
          trigger_key: trigger_key,
          attempt_count: attempt,
          last_error: last_error
        )

        {:error, :exhausted}

      {:error, _last_error} ->
        delay_ms = backoff_delay(attempt, policy)
        Process.sleep(delay_ms)
        deliver_with_retry(hook, payload, trigger_key, attempt + 1)
    end
  end

  # delay(attempt) = min(base × multiplier^(attempt-1), max), 0-indexed retry
  defp backoff_delay(attempt, %RetryPolicy{
         base_backoff_ms: base,
         multiplier: multiplier,
         max_backoff_ms: max_ms
       }) do
    raw = trunc(base * :math.pow(multiplier, attempt - 1))
    min(raw, max_ms)
  end

  defp build_headers(nil) do
    [{~c"content-type", ~c"application/json"}]
  end

  defp build_headers(bearer_token) do
    [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", String.to_charlist("Bearer #{bearer_token}")}
    ]
  end

  # Resolve auth_secret_ref via Letflow.Secrets.resolve/2. The namespace
  # "alert_hook" is embedded in the reference; the tenant_id is derived from
  # the reference's own slug via Identity.get_tenant_by_slug/1. On any
  # failure, returns nil (no Authorization header) and logs a warning.
  @reference_slug_pattern ~r{^sec://tenant/([^/]+)/}

  defp resolve_auth_header(nil), do: nil

  defp resolve_auth_header(ref) do
    with [_, slug] <- Regex.run(@reference_slug_pattern, ref),
         {:ok, %{id: tenant_id}} <- Identity.get_tenant_by_slug(slug),
         {:ok, %{plaintext: plaintext}} <-
           Secrets.resolve(ref, tenant_id: tenant_id, consumer: :generic) do
      plaintext
    else
      _ ->
        Logger.warning(
          "alert hook auth_secret_ref resolution failed, sending without Authorization",
          component: "alert_delivery",
          ref: ref
        )

        nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Config building helpers
  # ---------------------------------------------------------------------------

  defp build_thresholds(cfg) do
    t = Keyword.get(cfg, :thresholds, [])

    %AlertThresholds{
      error_stuck_minutes: Keyword.get(t, :error_stuck_minutes, 10),
      dlq_depth_threshold: Keyword.get(t, :dlq_depth_threshold, 100),
      scheduler_lag_ms: Keyword.get(t, :scheduler_lag_ms, 15_000)
    }
  end

  defp build_hooks(cfg) do
    cfg
    |> Keyword.get(:hooks, [])
    |> Enum.map(fn h ->
      rp_kw = Keyword.get(h, :retry_policy, [])

      retry_policy = %RetryPolicy{
        max_attempts: Keyword.get(rp_kw, :max_attempts, 3),
        base_backoff_ms: Keyword.get(rp_kw, :base_backoff_ms, 1_000),
        max_backoff_ms: Keyword.get(rp_kw, :max_backoff_ms, 30_000),
        multiplier: Keyword.get(rp_kw, :multiplier, 2.0)
      }

      %AlertHookConfig{
        hook_id: Keyword.fetch!(h, :hook_id),
        enabled: Keyword.get(h, :enabled, true),
        destination_url: Keyword.fetch!(h, :destination_url),
        timeout_ms: Keyword.get(h, :timeout_ms, 5_000),
        auth_secret_ref: Keyword.get(h, :auth_secret_ref, nil),
        retry_policy: retry_policy
      }
    end)
  end

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  # ---------------------------------------------------------------------------
  # GH 2534 PR 7c-1: the fifth trigger, script_hmac_secret_missing (design
  # lib/letflow/design/gh2534-7c-script-handler.md 7.3, C15). Called ONLY by
  # Letflow.Engine.ScriptTaskDispatcher. Edge-triggered through the same
  # alert_trigger_state row machinery as the four detection triggers above:
  # ARMED -> one error line (+ hooks when alert_hooks is enabled) -> FIRED;
  # FIRED -> nothing; clear_ re-arms (a no-op when already armed). The payload
  # and the log carry only the trigger name and the tenant schema. Never raises.
  # ---------------------------------------------------------------------------

  @script_hmac_trigger "script_hmac_secret_missing"

  @doc """
  A run found the tenant's script HMAC key missing: fires the edge-triggered operator alert
  once (log line, plus the alert hooks when enabled) and disarms it until
  `clear_script_hmac_secret_missing/1`. Never raises.
  """
  @spec notify_script_hmac_secret_missing(tenant_schema :: String.t()) :: :ok
  def notify_script_hmac_secret_missing(tenant_schema) when is_binary(tenant_schema) do
    state = load_trigger_state(@script_hmac_trigger, tenant_schema)

    if state.is_armed do
      now = DateTime.utc_now()

      Logger.error("script HMAC secret missing",
        component: "script_task",
        tenant_schema: tenant_schema,
        trigger: @script_hmac_trigger
      )

      cfg = Application.get_env(:letflow, :alert_hooks, [])

      if Keyword.get(cfg, :enabled, false) do
        fire_hooks(
          build_hooks(cfg),
          @script_hmac_trigger,
          %{"trigger" => @script_hmac_trigger, "tenant_schema" => tenant_schema},
          tenant_schema
        )
      end

      upsert_trigger_state(
        %{
          trigger_key: @script_hmac_trigger,
          is_armed: false,
          last_sample_value: 1,
          last_fired_at: now,
          last_correlation_id: nil,
          updated_at: now
        },
        tenant_schema
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "A run found the key: re-arms the trigger (a no-op when already armed). Never raises."
  @spec clear_script_hmac_secret_missing(tenant_schema :: String.t()) :: :ok
  def clear_script_hmac_secret_missing(tenant_schema) when is_binary(tenant_schema) do
    state = load_trigger_state(@script_hmac_trigger, tenant_schema)

    unless state.is_armed do
      rearm_and_clear_emissions(
        %{
          trigger_key: @script_hmac_trigger,
          is_armed: true,
          last_sample_value: 0,
          last_fired_at: state.last_fired_at,
          last_correlation_id: nil,
          updated_at: DateTime.utc_now()
        },
        @script_hmac_trigger,
        tenant_schema
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Scheduler integration helpers (called from Letflow.Scheduler.Poller)
  # ---------------------------------------------------------------------------

  @doc """
  Builds the `tick_context` for one tenant schema and calls `run_detection/2`.
  Called from `Letflow.Scheduler.Poller.maybe_run_alert_detection/2`.

  Reads thresholds from `Application.get_env(:letflow, :alert_hooks)` fresh.
  Queries DLQ count, stuck ERROR instances, and recently-paused subscriptions
  in the given schema. Errors in any one query degrade gracefully.
  """
  @spec build_context_and_detect(
          tenant_schema :: String.t(),
          observed_lag_ms :: non_neg_integer() | nil,
          last_tick_started_at :: DateTime.t() | nil
        ) :: :ok
  def build_context_and_detect(tenant_schema, observed_lag_ms, last_tick_started_at) do
    cfg = Application.get_env(:letflow, :alert_hooks, [])
    thresholds = build_thresholds(cfg)

    dlq_count = safe_dlq_count(tenant_schema)
    stuck = safe_stuck_instances(tenant_schema, thresholds.error_stuck_minutes)
    paused = safe_recently_paused_subs(tenant_schema, last_tick_started_at)

    ctx = %{
      dlq_count: dlq_count,
      observed_lag_ms: observed_lag_ms,
      stuck_instances: stuck,
      recently_paused_subs: paused
    }

    run_detection(tenant_schema, ctx)
  end

  defp safe_dlq_count(tenant_schema) do
    Dlq.count_entries(prefix: tenant_schema)
  rescue
    _ -> 0
  end

  defp safe_stuck_instances(tenant_schema, threshold_minutes) do
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    from(i in "instance_projections",
      where: i.status == "ERROR" and i.updated_at <= ^cutoff,
      select: %{
        instance_id: i.id,
        error_reason: fragment("coalesce(?, '')", i.error_reason),
        stuck_minutes:
          fragment(
            "floor(extract(epoch from (now() - ?)) / 60)::bigint",
            i.updated_at
          )
      }
    )
    |> Repo.all(prefix: tenant_schema)
    |> Enum.map(fn row ->
      %{
        instance_id: to_string(row.instance_id),
        error_reason: row.error_reason || "",
        stuck_minutes: row.stuck_minutes || 0
      }
    end)
  rescue
    _ -> []
  end

  defp safe_recently_paused_subs(_tenant_schema, nil), do: []

  defp safe_recently_paused_subs(tenant_schema, last_tick_started_at) do
    from(s in Subscription,
      where:
        s.status == :PAUSED and not is_nil(s.paused_at) and s.paused_at >= ^last_tick_started_at,
      select: %{subscription_id: s.id}
    )
    |> Repo.all(prefix: tenant_schema)
    |> Enum.map(fn row ->
      %{subscription_id: to_string(row.subscription_id)}
    end)
  rescue
    _ -> []
  end
end
