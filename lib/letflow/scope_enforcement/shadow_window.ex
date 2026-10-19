defmodule Letflow.ScopeEnforcement.ShadowWindow do
  @moduledoc """
  The shadow-evidence criterion of the `on` flip gate (REQ-519 2f-a, GH #2535, AC 11 and 12;
  design `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 4.6, SEC rulings
  S-4 and S-5 of
  `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-04-security-reviewer-design.json`).

  `evaluate/3` reads PERSISTED evidence only (`Letflow.Api.Scope.ShadowEvidence.counts_by_day/3`,
  ONE grouped query) and the audit chain (`Letflow.Audit.latest_matching/4`). It takes no lock
  and writes nothing. Reached today through `Letflow.ScopeEnforcement.integrity/1` (the lock-free
  `on_gate` block of `GET /integrity`); `Letflow.ScopeEnforcement.flip/4`
  also evaluates it for a target `on`, which `parse_mode/1` does not yet accept (REQ-519 2f-b).

  ## Criteria (all five must hold)

    * `duration` (a): T0 is the timestamp of the latest `scope.enforcement_enabled` or
      `scope.enforcement_disabled` entry of the tenant whose `after_state["mode"]` is
      `"shadow"` (from the audit chain, never a request field); `now - T0 >= min_days` days,
      measured on timestamps. No such entry (or the latest transition left `shadow`) fails
      closed.
    * `requests` (b): the persisted `requests` over the window are at least `min_requests`,
      AND `every_day_has_requests`: `requests > 0` on EACH date of the window.
    * `no_blocking_would_deny` (c): the window sum of the blocking reasons (`no_grant_rows`,
      `grants_unavailable`) is zero. The other four reasons are reported and never block.
    * `configuration`: `min_days <= retention_days`; otherwise no window can ever hold a row
      for its oldest day and the gate would refuse forever without saying why.

  The window is `date(now) - min_days` through `date(now)` INCLUSIVE (`min_days + 1` UTC
  dates); both end dates are partial days counted in full (a date shared with an earlier
  shadow period counts in full: conservative for (c), at most one extra partial date for (b)).

  ## Thresholds (SEC S-5)

  Application env only, never a request field or an `attrs` key: `:scope_shadow_min_days`
  (default 7), `:scope_shadow_min_requests` (default 100), `:scope_shadow_retention_days`
  (default 90), the defaults being the module attributes below (ONE place; no config copy). A
  value that is not an integer, or is below 1, is replaced by the DEFAULT
  (stricter or equal), never by the floor. Only
  `config/test.exs` may lower them; `config/prod.exs` and `config/runtime.exs` never set them.

  ## Limits

  Shadow evaluates only `:tenant_wide` and admin-plane routes. A crash loses at most one flush
  interval of counts (stricter for (b), more lenient for (c) by that amount). The flip request
  itself counts as a shadow request, and request counts include every authorized request of
  any principal, so criterion (b) is an operator-safety control, not an adversarial one. A
  tenant with a day of zero traffic in the window (a weekend) cannot pass.

  ## Statement of scope (AC 12)

  `scope_sentence/0` is the sentence `docs/roles.md` must contain verbatim; `evidence_scope/0`
  is the constant carried by every report.
  """

  alias Letflow.Api.Scope.ShadowEvidence
  alias Letflow.Audit
  alias Letflow.ScopeEnforcement

  @default_min_days 7
  @default_min_requests 100
  @default_retention_days 90
  @blocking_reasons [:no_grant_rows, :grants_unavailable]
  @evidence_scope "tenant_wide_and_admin_plane_routes_only"
  @scope_sentence "The shadow period proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence, writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow."

  @type thresholds :: %{
          min_days: pos_integer(),
          min_requests: pos_integer(),
          retention_days: pos_integer()
        }
  @type criteria :: %{
          duration: boolean(),
          requests: boolean(),
          every_day_has_requests: boolean(),
          no_blocking_would_deny: boolean(),
          configuration: boolean()
        }
  @type report :: %{
          shadow_since: DateTime.t() | nil,
          window_from: Date.t(),
          window_to: Date.t(),
          requests: non_neg_integer(),
          days_without_requests: non_neg_integer(),
          would_deny: %{ShadowEvidence.metric() => non_neg_integer()},
          criteria: criteria(),
          evidence_scope: String.t()
        }

  @doc "The effective thresholds (see the moduledoc: invalid values fall back to the default)."
  @spec thresholds() :: thresholds()
  def thresholds do
    %{
      min_days: env_int(:scope_shadow_min_days, @default_min_days),
      min_requests: env_int(:scope_shadow_min_requests, @default_min_requests),
      retention_days: env_int(:scope_shadow_retention_days, @default_retention_days)
    }
  end

  defp env_int(key, default) do
    case Application.get_env(:letflow, key, default) do
      value when is_integer(value) and value >= 1 -> value
      _invalid -> default
    end
  end

  @doc "The constant `\"tenant_wide_and_admin_plane_routes_only\"` (AC 12)."
  @spec evidence_scope() :: String.t()
  def evidence_scope, do: @evidence_scope

  @doc "The AC 12 sentence that `docs/roles.md` must contain verbatim."
  @spec scope_sentence() :: String.t()
  def scope_sentence, do: @scope_sentence

  @doc """
  Best-effort synchronous flush of the in-memory shadow counters (SEC S-4: flush before the
  flip, so a 30 second flush lag cannot make "requests today" read zero). Never raises; a
  failed flush can only make the gate stricter. Call it OUTSIDE the flip transaction.
  """
  @spec flush_evidence() :: :ok
  def flush_evidence do
    _ = ShadowEvidence.flush()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Evaluates the five criteria for the tenant at one instant `now` (UTC). Returns the report
  and whether ALL criteria hold. Raises on a database error (the caller refuses or rolls back,
  INV-8).
  """
  @spec evaluate(tenant_id :: Ecto.UUID.t(), prefix :: String.t(), now :: DateTime.t()) ::
          {report(), satisfied? :: boolean()}
  def evaluate(tenant_id, prefix, %DateTime{} = now) when is_binary(prefix) do
    %{min_days: min_days, min_requests: min_requests, retention_days: retention_days} =
      thresholds()

    shadow_since = shadow_since(tenant_id, prefix)
    today = now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
    window_from = Date.add(today, -min_days)
    by_day = ShadowEvidence.counts_by_day(prefix, window_from, today)
    dates = Date.range(window_from, today)

    request_days = Enum.map(dates, fn date -> day_count(by_day, date, :requests) end)
    requests = Enum.sum(request_days)
    days_without_requests = Enum.count(request_days, &(&1 == 0))

    would_deny =
      Map.new(ShadowEvidence.reasons(), fn reason ->
        {reason, dates |> Enum.map(&day_count(by_day, &1, reason)) |> Enum.sum()}
      end)

    criteria = %{
      duration:
        shadow_since != nil and DateTime.diff(now, shadow_since, :second) >= min_days * 86_400,
      requests: requests >= min_requests,
      every_day_has_requests: days_without_requests == 0,
      no_blocking_would_deny: Enum.all?(@blocking_reasons, &(Map.fetch!(would_deny, &1) == 0)),
      configuration: min_days <= retention_days
    }

    report = %{
      shadow_since: shadow_since,
      window_from: window_from,
      window_to: today,
      requests: requests,
      days_without_requests: days_without_requests,
      would_deny: would_deny,
      criteria: criteria,
      evidence_scope: @evidence_scope
    }

    {report, criteria |> Map.values() |> Enum.all?()}
  end

  # T0: the latest enabled/disabled entry of the tenant, only when it entered `shadow`.
  defp shadow_since(tenant_id, prefix) do
    entry =
      Audit.latest_matching(
        prefix,
        ScopeEnforcement.flip_resource_type(),
        tenant_id,
        ScopeEnforcement.flip_actions()
      )

    case entry do
      %{after_state: %{"mode" => "shadow"}, timestamp: %DateTime{} = timestamp} -> timestamp
      _none_or_other -> nil
    end
  end

  defp day_count(by_day, date, metric) do
    by_day |> Map.get(date, %{}) |> Map.get(metric, 0)
  end
end
