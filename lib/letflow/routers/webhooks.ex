defmodule Letflow.Routers.Webhooks do
  @moduledoc """
  Webhook subscription sub-router (REQ-182, design
  `lib/letflow/design/req182-webhooks-routes.md`; REQ-184, design
  `lib/letflow/design/req184-webhook-deliveries-route.md`). Mounted at
  `/webhooks` by `Letflow.Plugs.ApiPipeline`, so the full paths under
  `/api/v1` are `GET /api/v1/webhooks/subscriptions`,
  `POST /api/v1/webhooks/subscriptions`,
  `PATCH /api/v1/webhooks/subscriptions/:id`,
  `DELETE /api/v1/webhooks/subscriptions/:id`, and
  `GET /api/v1/webhooks/subscriptions/:id/deliveries`. Route/controller
  layer only, atop REQ-181's already-shipped `Letflow.Webhooks` context
  module (which also now hosts REQ-183's `deliver/3` and REQ-184's
  `list_delivery_attempts/3`) — no change to `Letflow.Webhooks.Subscription`,
  `Letflow.Webhooks.Delivery`, or either migration.

  ## Contract source

  PROVENANCE (historical, not current decision authority):
  R-Co's `webhooks.zig` was **not inspected** while drafting this route
  layer (REQ-182) or the deliveries route added on top of it (REQ-184) — R-Co
  is at a Windows path unreachable from this sandbox, verified absent, not
  assumed covered. The binding contract instead is the already-shipped SPA
  consumer: `web/src/api/dlq.ts`'s `webhooksApi` object (including
  `getDeliveries/2`) and `web/src/types/api.ts`'s `WebhookSubscription` and
  `WebhookDeliveryAttempt` types.

  ## Outbound mapping link (REQ-565 slice 2)

  `PATCH .../subscriptions/:id` also accepts `outbound_mapping_id` (a uuid of an outbound
  integration mapping of the tenant, or `null` to clear). A body that contains the key needs
  `:IntegrationMappingsManage` as well (403 "insufficient permissions" otherwise, checked before
  any database access); a refused id is one 422 for inbound, other-tenant, unknown and malformed ids.

  ## Delivery attempts (REQ-184)

  `GET /api/v1/webhooks/subscriptions/:id/deliveries` reads rows persisted by
  `Letflow.Webhooks.deliver/3` (REQ-183) through the new
  `Letflow.Webhooks.list_delivery_attempts/3` context function — no existing
  function listed `webhook_delivery_attempts` rows before this requirement.
  The response is `%{"items" => [...]}`, each item a 9-field allowlist
  (`delivery_id`, `subscription_id`, `event_type`, `status`,
  `http_status_code`, `attempted_at`, `attempt_count`, `max_attempts`,
  `last_error`) matching `web/src/types/api.ts`'s `WebhookDeliveryAttempt`
  exactly — see `delivery_json/1` below.

  The `limit` query param defaults to `20` when absent, `nil`, or not a
  positive integer (Letflow's own choice, not ported from R-Co per the
  contract-source note above — chosen to match the one real SPA caller's own
  literal `{ limit: 20 }` in
  `web/src/components/webhooks/WebhookSubscriptionDetailPanel.tsx`); no
  acceptance criterion requires a `400` for a malformed `limit`, so a
  malformed value silently falls back to the default rather than erroring.
  Rows are ordered `attempted_at DESC, attempt_count DESC` (most-recent-first,
  with `attempt_count` breaking ties within the same wall-clock second, since
  `attempted_at` is a `:utc_datetime` column at second precision) — this
  two-key order is what makes "more attempts than limit returns exactly
  limit items" deterministic. Both the `limit` default and this ordering are
  this design's own decisions (design §4, OQ-1/OQ-2), not stated by any
  acceptance criterion or by R-Co.

  **Deviation from the design's own §4 wording, flagged for REVIEWER:** the
  design says `limit` is read from `conn.params["limit"]`, but this router's
  pipeline (`Letflow.Api.AuthorizedRouter`, `use Plug.Router`) never calls
  `fetch_query_params/1` — `conn.params` here only ever carries path/body
  params (confirmed: every other query-param reader in `lib/letflow/routers/`,
  e.g. `dlq.ex`, `tasks.ex`, `definitions.ex`, calls `fetch_query_params(conn)`
  explicitly first and reads `conn.query_params`, never `conn.params`, for a
  query string value). `handle_deliveries/2` follows that established,
  codebase-wide idiom instead of the design's literal text.

  ## Authorization (REQ-069, REQ-131)

  Every route below is declared via `authz_get`/`authz_post`/`authz_patch`/
  `authz_delete` (`Letflow.Api.AuthorizedRouter`) with the policy key
  `:WebhookSubscriptionsManage`. `Letflow.Api.Authorization.endpoint_policy_key/2`
  already maps `GET`/`POST /webhooks/subscriptions` and
  `DELETE /webhooks/subscriptions/:id` to this key (shipped pre-REQ-182);
  this requirement adds the one missing
  `endpoint_policy_key("PATCH", "/webhooks/subscriptions/:id")` clause,
  mapping to the same key, so all four routes here resolve consistently.
  `required_permission(:WebhookSubscriptionsManage)` already maps to
  `:WebhooksManage` (unchanged). Per the real `role_allows?/2` matrix, only
  `PLATFORM_ADMIN` (catch-all) and `PROCESS_OPERATOR` (explicit grant) hold
  `:WebhooksManage` — `PROCESS_DESIGNER`, `TASK_WORKER`, `AGENT_RUNNER` do
  not, so such a caller gets `403` before any handler below runs.

  ## Cross-tenant-404 (AC3, INV-5)

  No new mechanism — inherited verbatim from `Letflow.Webhooks.update/3`'s
  and `delete/2`'s own existing, REQ-181-approved behavior: every handler's
  only tenant input is `conn.assigns.scoped_opts`, itself derived solely from
  `conn.assigns.auth_context.tenant_id` by `Letflow.Plugs.Authorize`, before
  this router's code ever runs (schema-per-tenant). A subscription id that
  exists only in a different tenant's schema is, at the `Repo` level,
  indistinguishable from an id that does not exist anywhere — both resolve
  to `{:error, :not_found}` inside `Letflow.Webhooks`, and this router maps
  that one tuple to `Response.not_found/1` for both PATCH and DELETE.
  `:invalid_id` (a malformed UUID) folds into the same branch rather than a
  `400`, for the identical reason: subscription ids are cross-tenant-probeable
  UUIDs reachable from the route path.

  ## Response allowlist (INV-2)

  `subscription_json/1` is a hand-built allowlist over
  `Letflow.Webhooks.Subscription` struct fields — never a raw `Jason.Encoder`
  derivation over the Ecto struct, which would leak `__meta__`/`tenant_id`/
  `secret_hash`. `secret_hash` and `hmac_secret_once` are never emitted by
  `subscription_json/1` under any circumstance — the **only** place
  `hmac_secret_once` is ever added to a response body is the one `POST
  /subscriptions` success branch below, which splices it onto the map
  `subscription_json/1` already produced. The list body is an
  exactly-one-key map, `%{"items" => [...]}` — no pagination fields,
  matching `webhooksApi.list()`'s actual (non-paginated) consumer usage.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Authorization
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.PlatformTenant
  alias Letflow.Webhooks
  alias Letflow.Webhooks.Delivery
  alias Letflow.Webhooks.Subscription

  authz_get "/subscriptions", :WebhookSubscriptionsManage do
    handle_list(conn)
  end

  authz_post "/subscriptions", :WebhookSubscriptionsManage do
    handle_create(conn)
  end

  authz_patch "/subscriptions/:id", :WebhookSubscriptionsManage do
    handle_update(conn, conn.params["id"])
  end

  authz_delete "/subscriptions/:id", :WebhookSubscriptionsManage do
    handle_delete(conn, conn.params["id"])
  end

  authz_get "/subscriptions/:id/deliveries", :WebhookSubscriptionsManage do
    handle_deliveries(conn, conn.params["id"])
  end

  authz_unmatched(:ordinary)

  # ── GET /webhooks/subscriptions (design §3.1) ─────────────────────────────

  defp handle_list(conn) do
    {:ok, subscriptions} = Webhooks.list(conn.assigns.scoped_opts)
    Response.ok(conn, %{"items" => Enum.map(subscriptions, &subscription_json/1)})
  end

  # ── POST /webhooks/subscriptions (design §3.2) ────────────────────────────

  defp handle_create(conn) do
    with {:ok, body} <- object_body(conn),
         {:ok, target_url} <- fetch_target_url(body) do
      attrs =
        %{target_url: target_url}
        |> maybe_put(body, "secret", :secret)
        |> maybe_put(body, "description", :description)
        |> maybe_put(body, "event_types", :event_types)

      case Webhooks.create(attrs, conn.assigns.scoped_opts) do
        {:ok, %{subscription: subscription, hmac_secret_once: plaintext}} ->
          body = subscription |> subscription_json() |> Map.put("hmac_secret_once", plaintext)
          Response.created(conn, body)

        {:error, %Ecto.Changeset{}} ->
          Response.unprocessable(conn, "unable to create webhook subscription")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :missing_target_url} ->
        Response.bad_request(conn, "target_url is required")
    end
  end

  # ── PATCH /webhooks/subscriptions/:id (design §3.3) ───────────────────────

  defp handle_update(conn, id) do
    with {:ok, body} <- object_body(conn),
         :ok <- authorize_link(conn, body) do
      attrs =
        %{}
        |> maybe_put(body, "status", :status)
        |> maybe_put(body, "is_active", :is_active)
        |> maybe_put(body, "outbound_mapping_id", :outbound_mapping_id)

      case Webhooks.update(id, attrs, conn.assigns.scoped_opts) do
        {:ok, subscription} ->
          Response.ok(conn, subscription_json(subscription))

        {:error, :not_found} ->
          Response.not_found(conn)

        {:error, :invalid_id} ->
          Response.not_found(conn)

        {:error, :invalid_status} ->
          Response.bad_request(conn, "status/is_active is missing or invalid")

        {:error, :invalid_mapping} ->
          Response.unprocessable(conn, "invalid outbound_mapping_id")

        {:error, %Ecto.Changeset{}} ->
          Response.unprocessable(conn, "unable to update webhook subscription")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :forbidden} ->
        # Same detail as Letflow.Plugs.Authorize's deny (INV-5: one uniform 403).
        Response.forbidden(conn, "insufficient permissions")
    end
  end

  # Linking a mapping is a mapping-administration act: a body that carries the key (even null)
  # needs :IntegrationMappingsManage on top of the route's :WebhooksManage. Other fields do not.
  defp authorize_link(conn, body) do
    if Map.has_key?(body, "outbound_mapping_id") and
         not holds?(conn, :IntegrationMappingsManage),
       do: {:error, :forbidden},
       else: :ok
  end

  # Recomputed from the DB-resolved auth context (never a request value).
  defp holds?(conn, permission) do
    context = conn.assigns.auth_context
    platform_tenant? = PlatformTenant.platform_tenant?(Map.get(context, :tenant_id))

    Authorization.has_permission_in_scope?(
      Authorization.effective_roles(Map.get(context, :roles, []), platform_tenant?),
      permission,
      platform_tenant?
    )
  end

  # ── DELETE /webhooks/subscriptions/:id (design §3.4) ──────────────────────

  defp handle_delete(conn, id) do
    case Webhooks.delete(id, conn.assigns.scoped_opts) do
      {:ok, _subscription} ->
        Response.no_content(conn)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :invalid_id} ->
        Response.not_found(conn)
    end
  end

  # ── GET /webhooks/subscriptions/:id/deliveries (design §5.1, REQ-184) ─────

  defp handle_deliveries(conn, id) do
    conn = fetch_query_params(conn)

    case resolve_limit(conn.query_params["limit"]) do
      {:ok, limit} ->
        render_deliveries(
          conn,
          Webhooks.list_delivery_attempts(id, limit, conn.assigns.scoped_opts)
        )

      {:error, :invalid_limit} ->
        Response.bad_request(conn, "invalid limit")
    end
  end

  defp render_deliveries(conn, {:ok, deliveries}),
    do: Response.ok(conn, %{"items" => Enum.map(deliveries, &delivery_json/1)})

  defp render_deliveries(conn, {:error, :not_found}), do: Response.not_found(conn)
  defp render_deliveries(conn, {:error, :invalid_id}), do: Response.not_found(conn)

  @default_deliveries_limit 20

  # A positive value above int64 is refused (400), since it cannot be bound as the
  # SQL LIMIT. A huge in-range value is clamped to the platform page-size maximum,
  # the same bound the paginated list routes enforce. Non-positive or non-numeric
  # values keep their fallback to the default.
  defp resolve_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {value, ""} when value > 0 ->
        if Pagination.int64?(value),
          do: {:ok, min(value, Pagination.max_page_size())},
          else: {:error, :invalid_limit}

      _other ->
        {:ok, @default_deliveries_limit}
    end
  end

  defp resolve_limit(_other), do: {:ok, @default_deliveries_limit}

  # ── Request-body helpers ───────────────────────────────────────────────────

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp fetch_target_url(body) do
    case Map.get(body, "target_url") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_target_url}
    end
  end

  defp maybe_put(attrs, body, body_key, attrs_key) do
    case Map.fetch(body, body_key) do
      {:ok, value} -> Map.put(attrs, attrs_key, value)
      :error -> attrs
    end
  end

  # ── Response allowlist (INV-2, design §5) ─────────────────────────────────

  # Hand-built, matching Letflow.Routers.Dlq's dlq_entry_json/1 precedent --
  # never a Jason.Encoder derivation over %Subscription{}, which would leak
  # `__meta__`/`tenant_id`/`secret_hash`. `hmac_secret_once` is never emitted
  # here -- it is not a struct field and is spliced on only by the one
  # POST /subscriptions success branch above.
  @spec subscription_json(Subscription.t()) :: map()
  defp subscription_json(%Subscription{} = subscription) do
    %{
      "id" => subscription.id,
      "target_url" => subscription.target_url,
      "description" => subscription.description,
      "event_types" => subscription.event_types,
      "status" => Atom.to_string(subscription.status),
      "consecutive_failures" => subscription.consecutive_failures,
      "last_attempt_at" => iso8601(subscription.last_attempt_at),
      "last_failure_at" => iso8601(subscription.last_failure_at),
      "paused_at" => iso8601(subscription.paused_at),
      "created_at" => iso8601(subscription.created_at),
      "outbound_mapping_id" => subscription.outbound_mapping_id
    }
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil

  # Hand-built allowlist over %Delivery{} (design §5.2, INV-2) -- never a raw
  # Jason.Encoder derivation, which would leak `tenant_id`/`__meta__`/the
  # row's own primary key `id` (not one of the nine contracted fields;
  # `delivery_id` is a distinct column).
  @spec delivery_json(Delivery.t()) :: map()
  defp delivery_json(%Delivery{} = delivery) do
    %{
      "delivery_id" => delivery.delivery_id,
      "subscription_id" => delivery.subscription_id,
      "event_type" => delivery.event_type,
      "status" => Atom.to_string(delivery.status),
      "http_status_code" => delivery.http_status_code,
      "attempted_at" => iso8601(delivery.attempted_at),
      "attempt_count" => delivery.attempt_count,
      "max_attempts" => delivery.max_attempts,
      "last_error" => delivery.last_error
    }
  end
end
