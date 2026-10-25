defmodule Letflow.Webhooks do
  @moduledoc """
  Context module for the `webhook_subscriptions` table's core CRUD:
  `create/2`, `list/1`, `update/3`, `delete/2`. See
  `lib/letflow/design/req181-webhooks-core.md` for the full design this
  module implements. Plain Ecto context module, no process — same shape as
  `Letflow.Dlq`/`Letflow.Tasks`/`Letflow.Identity`.

  **Scope boundary, restated from the design (§0/§4):** this module covers
  the schema/migration, `create/2`/`list/1`/`update/3`/`delete/2`, the
  private `get/2` helper they're proven against, `deliver/3` (REQ-183's
  dispatch core), and `list_delivery_attempts/3` (REQ-184's read-side query,
  see `lib/letflow/design/req184-webhook-deliveries-route.md`). No route, no
  controller, no Plug module anywhere in this file — that is REQ-182
  (subscription CRUD routes) and REQ-184 (the deliveries route,
  `lib/letflow/routers/webhooks.ex`).

  ## Tenant scoping (INV-1)

  Every function below takes `opts :: [prefix: String.t()]`, `prefix` always
  supplied by the caller (the future REQ-182 route, via
  `Letflow.Api.Context.scoped_repo_opts/1`) — this module never itself
  decides tenant scope, matching every REQ-072+ context module's own
  precedent, restated verbatim from `Letflow.Dlq`'s own moduledoc.

  `tenant_id` is never accepted from caller-supplied attrs — it is always
  derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, the same
  "derived, never accepted" discipline `Letflow.Dlq.enqueue/2` establishes.

  ## Secret handling (REQ-190, design §5.4 — supersedes the original
  ## SHA-256-hash-only design §2.2)

  `create/2` generates (or accepts a caller-supplied) plaintext secret and
  writes it into the global `secrets` table via `Letflow.Secrets.put/2`
  (namespace `"webhook"`, purpose `:webhook_hmac`) instead of hashing it —
  a one-way hash cannot supply the key material HMAC-SHA256 signing needs
  (`docs/migration/decisions/0016-secrets-storage-backend.md` §F). The
  `Subscription` row stores only `secret_ref`/`secret_key_id` (the
  reference, not the plaintext). The plaintext is still returned exactly
  once, as `hmac_secret_once` in `create/2`'s own return value — no other
  function in this module ever returns it again, and no `Subscription`
  struct field carries it (structurally impossible, see
  `Letflow.Webhooks.Subscription`'s own moduledoc). Both the `secrets` insert
  (global, no prefix) and the `webhook_subscriptions` insert (tenant-scoped,
  `prefix: prefix`) happen inside one `Ecto.Multi`/transaction, so a
  `Subscription` row is never left referencing a `secret_ref` that failed to
  write.

  ## Delivery dispatch (REQ-183, `deliver/3`)

  `deliver/3` is this module's dispatch-core half of the REQ-180 split
  (REQ-184's `GET .../deliveries` route is the read-side half, not built
  here). See `lib/letflow/design/req183-webhook-delivery-dispatch.md` for the
  full design.

  **HMAC signing (Letflow's own choice, not ported from R-Co -- R-Co's
  `src/webhook/` dispatch code is not inspectable from this codebase's
  history):** the outgoing request carries an `X-Letflow-Signature` header,
  value format `"sha256=" <> Base.encode16(hmac, case: :lower)`, computed via
  `:crypto.mac(:hmac, :sha256, signing_key, json_body)` over the exact
  `Jason.encode!/1` byte string sent as the request body. `signing_key` is
  resolved per attempt via `Letflow.Secrets.resolve/2` against
  `subscription.secret_ref` (REQ-190).

  **Auto-pause threshold (Letflow's own choice): 5 consecutive failed
  delivery *attempts*, not `deliver/3` calls** -- `@auto_pause_threshold`.
  Reaching it flips `status: :PAUSED` and stamps `paused_at`.

  **Automatic triggering of `deliver/3` after every matching domain-event
  append is explicitly OUT OF SCOPE and a deferred follow-up** -- not
  silently implemented, not silently forgotten. `deliver/3` is directly
  callable by any future caller; wiring its automatic trigger is left for a
  future requirement to scope deliberately (design §6).

  ## Integration mapping (REQ-565 slice 2)

  A subscription may link one outbound `Letflow.IntegrationMappings` mapping
  (`outbound_mapping_id`, set through `update/3`). `deliver/3` applies it after
  `redact_payload_for_delivery` and before encoding and signing, so the signature, the body
  and the DLQ `source_payload` all use the mapped body, and a rule copying a masked field
  sends the masked value. The mapping sees the JSON form of the payload (atom keys become
  strings, structs are encoded). A null link changes nothing. A failure returns
  `{:error, {:mapping_failed, reason}}` (`{:required_missing, index}`, `:body_too_large`,
  `:mapping_not_found`, `:payload_not_encodable`) before the attempt loop. The request URL is
  always `subscription.target_url`; a mapping only shapes the body.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Letflow.Entities.FieldPolicy
  alias Letflow.IntegrationMappings
  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.TenantProvisioning
  alias Letflow.Webhooks.Delivery
  alias Letflow.Webhooks.Subscription
  alias Letflow.Webhooks.UrlValidator

  @typedoc "Threaded into every `Repo` call below — `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @webhook_secret_prefix "lf_whsec_"

  # ===========================================================================
  # deliver/3 (design §3.1-§3.5, §4) constants
  # ===========================================================================

  # Letflow's own choice (design §4.1), not ported from R-Co -- R-Co's
  # src/webhook/ dispatch code is not inspectable from this codebase's
  # history. A round, conservative number that tolerates a brief
  # target-side blip without pausing, while still catching a genuinely dead
  # endpoint within a handful of delivery attempts.
  @auto_pause_threshold 5

  # Letflow's own choice (design §4.2), not ported from R-Co. Exponential
  # backoff, base 2 seconds: 1s after attempt 1, 2s after attempt 2, 4s
  # after attempt 3 (no backoff needed after attempt 4).
  @max_attempts 4

  # REQ-565: a mapped body above this is refused before any attempt.
  @max_mapped_body_bytes 256 * 1024

  @signature_header "X-Letflow-Signature"
  @http_timeout_ms 10_000

  # ===========================================================================
  # create/2 (design §3.1)
  # ===========================================================================

  @type create_attrs :: %{
          required(:target_url) => String.t(),
          optional(:secret) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:event_types) => [String.t()] | nil
        }

  @doc """
  Inserts a new `webhook_subscriptions` row. Always sets `status: :ACTIVE`
  (never caller-settable — `create_attrs()` has no `:status`/`:is_active`
  key at all) and `consecutive_failures: 0`.

  Resolves the plaintext secret: if `attrs[:secret]` is a non-nil, non-empty
  string, uses it verbatim (a caller may bring their own secret); otherwise
  generates one via `:crypto.strong_rand_bytes/1` + `Base.encode16/2`.
  Generates the subscription's own id explicitly (`Ecto.UUID.generate/0`,
  REQ-190 design §5.4 step 2) so it can be used as `Letflow.Secrets.put/2`'s
  `name` before the `Subscription` row itself exists, writes the plaintext
  into the global `secrets` table (namespace `"webhook"`, purpose
  `:webhook_hmac`), then inserts the `Subscription` row referencing the
  returned `secret_ref`/`secret_key_id` — both writes in one
  `Ecto.Multi`/transaction, so a `Subscription` row is never left
  referencing a `secret_ref` that failed to write.

  On success, returns `{:ok, %{subscription: subscription, hmac_secret_once:
  plaintext}}` — the plaintext appears **only** in this one return value,
  this one time. On `Letflow.Secrets.put/2` failure, returns
  `{:error, {:secret_write_failed, reason}}` and no `Subscription` row is
  inserted.
  """
  @spec create(create_attrs(), opts()) ::
          {:ok, %{subscription: Subscription.t(), hmac_secret_once: String.t()}}
          | {:error, :target_url_not_allowed}
          | {:error, {:secret_write_failed, term()}}
          | {:error, Ecto.Changeset.t()}
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    target_url = Map.get(attrs, :target_url, "")

    with :ok <- UrlValidator.validate(target_url),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      plaintext = resolve_secret_plaintext(attrs)
      subscription_id = Ecto.UUID.generate()
      created_at = current_timestamp()

      Multi.new()
      |> Multi.run(:secret, fn _repo, _changes ->
        Secrets.put(%{
          tenant_id: tenant_id,
          namespace: "webhook",
          name: subscription_id,
          purpose: :webhook_hmac,
          plaintext: plaintext,
          created_by: "system:webhooks.create"
        })
      end)
      |> Multi.run(:subscription, fn repo, %{secret: secret} ->
        insert_attrs = %{
          id: subscription_id,
          tenant_id: tenant_id,
          target_url: Map.get(attrs, :target_url),
          secret_ref: secret.reference,
          secret_key_id: secret.key_id,
          description: Map.get(attrs, :description),
          event_types: Map.get(attrs, :event_types) || [],
          created_at: created_at
        }

        %Subscription{}
        |> Subscription.insert_changeset(insert_attrs)
        |> repo.insert(prefix: prefix)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{subscription: subscription}} ->
          {:ok, %{subscription: subscription, hmac_secret_once: plaintext}}

        {:error, :secret, reason, _changes} ->
          {:error, {:secret_write_failed, reason}}

        {:error, :subscription, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  defp resolve_secret_plaintext(%{secret: secret}) when is_binary(secret) and secret != "" do
    secret
  end

  defp resolve_secret_plaintext(_attrs), do: generate_webhook_secret_plaintext()

  defp generate_webhook_secret_plaintext do
    @webhook_secret_prefix <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  # ===========================================================================
  # deliver/3 (design §3.1)
  # ===========================================================================

  @doc """
  Signs and POSTs `payload` (JSON-encoded) to `subscription.target_url`,
  retrying with exponential backoff up to `max_attempts`, and persists
  exactly one `webhook_delivery_attempts` row per attempt.

  Generates one `delivery_id` at the start of the call — every attempt row
  this call produces shares that value (design §1.1/§3.1). Resolves the
  HMAC signing key via `Letflow.Secrets.resolve/2` against
  `subscription.secret_ref` (`consumer: :webhook_dispatcher`, mandatory —
  omitting it would default to `:generic` and fail against the
  `:webhook_hmac`-purpose secret REQ-190 writes). A key-resolution failure
  returns `{:error, {:key_resolution_failed, reason}}` immediately, without
  inserting any attempt row and without incrementing
  `consecutive_failures` — a distinct, earlier failure mode from an actual
  delivery attempt (design §3.1 step 3). An attempt-row write failure (a
  `Delivery.insert_changeset/2` validation error — not named by the design,
  added defensively per INV-8 rather than left as a bare-match crash)
  returns `{:error, {:attempt_write_failed, changeset}}`.

  On the first `:SUCCESS` (any 2xx response), returns `{:ok, delivery}`
  immediately — no `consecutive_failures` increment, no further attempts.
  On `:FAILED` (non-2xx response, or a transport-level error/timeout),
  increments `subscription.consecutive_failures` and either backs off and
  retries, or — on the final configured attempt — lands the delivery in the
  DLQ via `Letflow.Dlq.enqueue/2` (`entry_type: "webhook"`, `reference_id:
  delivery_id`) and returns `{:ok, last_delivery}`. Returning `{:ok, _}` on
  exhaustion is deliberate: every attempt was correctly persisted, the
  subscription's failure state was correctly updated, and the DLQ landing
  succeeded — a caller distinguishes "delivered" from "exhausted, landed in
  DLQ" by reading the returned `Delivery.t()`'s own `status`/`attempt_count`
  fields, not the `{:ok, _} | {:error, _}` tag (design §3.1 step 4.g).
  """
  @spec deliver(Subscription.t(), event_type :: String.t(), payload :: map()) ::
          {:ok, Delivery.t()} | {:error, term()}
  def deliver(%Subscription{} = subscription, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    delivery_id = Ecto.UUID.generate()

    with {:ok, prefix} <- TenantProvisioning.schema_name_for_tenant(subscription.tenant_id),
         {:ok, %{plaintext: signing_key}} <-
           Secrets.resolve(subscription.secret_ref,
             tenant_id: subscription.tenant_id,
             consumer: :webhook_dispatcher
           ) do
      case redact_payload_for_delivery(payload, prefix) do
        {:ok, redacted} ->
          deliver_mapped(subscription, event_type, redacted, delivery_id, prefix, signing_key)

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_tenant_id} = error -> raise inspect(error)
      {:error, reason} -> {:error, {:key_resolution_failed, reason}}
    end
  end

  # REQ-565 slice 2: a linked outbound mapping is applied to the redacted payload, before
  # attempt_loop encodes, signs and (on exhaustion) stores it in the DLQ. A null link runs no
  # new code. Every failure returns before the first attempt: no request, no delivery row, no
  # consecutive_failures change. Errors and the log line carry atoms and a rule index only.
  defp deliver_mapped(subscription, event_type, redacted, delivery_id, prefix, signing_key) do
    case map_payload_for_delivery(subscription, redacted, prefix) do
      {:ok, body_payload} ->
        attempt_loop(subscription, event_type, body_payload, delivery_id, prefix, signing_key, 1)

      {:error, reason} ->
        Logger.warning("webhook mapping failed",
          subscription_id: subscription.id,
          reason: reason
        )

        {:error, {:mapping_failed, reason}}
    end
  end

  defp map_payload_for_delivery(%Subscription{outbound_mapping_id: nil}, redacted, _prefix),
    do: {:ok, redacted}

  defp map_payload_for_delivery(%Subscription{outbound_mapping_id: mapping_id}, redacted, prefix) do
    with {:ok, mapping} <- fetch_mapping(mapping_id, prefix),
         {:ok, source} <- json_shape(redacted),
         {:ok, mapped} <- IntegrationMappings.apply_mapping(mapping, source),
         :ok <- check_mapped_body(mapped) do
      {:ok, mapped}
    end
  end

  defp fetch_mapping(mapping_id, prefix) do
    case IntegrationMappings.fetch_outbound(mapping_id, prefix) do
      {:ok, mapping} -> {:ok, mapping}
      {:error, :not_found} -> {:error, :mapping_not_found}
    end
  end

  # The mapping sees the JSON form of the payload (atom keys become strings), the same
  # representation a receiver would parse.
  defp json_shape(payload) do
    with {:ok, json} <- Jason.encode(payload),
         {:ok, %{} = decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :payload_not_encodable}
    end
  end

  defp check_mapped_body(mapped) do
    case Jason.encode(mapped) do
      {:ok, json} when byte_size(json) > @max_mapped_body_bytes -> {:error, :body_too_large}
      {:ok, _json} -> :ok
      {:error, _} -> {:error, :payload_not_encodable}
    end
  end

  # REQ-516 S1 (C5/C6): an entity-event payload leaves the system, so its
  # `field_values` are masked with every restriction row of the entity type
  # (a recipient has no user, hence no grants). The one returned map is used
  # for the body, the signature and the DLQ copy. Other payloads pass through.
  # A loader failure fails the delivery closed.
  defp redact_payload_for_delivery(payload, prefix) do
    entity_type = payload_value(payload, "entity_type", :entity_type)
    field_values = payload_value(payload, "field_values", :field_values)

    cond do
      is_binary(entity_type) and is_map(field_values) ->
        stringified = Map.new(field_values, fn {key, value} -> {to_string(key), value} end)

        case FieldPolicy.redact_for_recipient(prefix, entity_type, stringified) do
          {:ok, redacted} ->
            {:ok,
             payload
             |> Map.delete(:field_values)
             |> Map.put("field_values", redacted)}

          {:error, reason} ->
            {:error, {:redaction_failed, reason}}
        end

      is_binary(entity_type) and not is_nil(field_values) ->
        {:error, {:redaction_failed, :invalid_field_values}}

      true ->
        {:ok, payload}
    end
  end

  defp payload_value(payload, string_key, atom_key) do
    case Map.fetch(payload, string_key) do
      {:ok, value} -> value
      :error -> Map.get(payload, atom_key)
    end
  end

  defp attempt_loop(
         subscription,
         event_type,
         payload,
         delivery_id,
         prefix,
         signing_key,
         attempt_count
       ) do
    json_body = Jason.encode!(payload)
    signature = sign(signing_key, json_body)
    attempted_at = current_timestamp()

    {status, http_status_code, last_error} =
      dispatch_http(subscription.target_url, json_body, signature)

    insert_attrs = %{
      tenant_id: subscription.tenant_id,
      delivery_id: delivery_id,
      subscription_id: subscription.id,
      event_type: event_type,
      status: status,
      http_status_code: http_status_code,
      attempted_at: attempted_at,
      attempt_count: attempt_count,
      max_attempts: @max_attempts,
      last_error: last_error
    }

    case %Delivery{} |> Delivery.insert_changeset(insert_attrs) |> Repo.insert(prefix: prefix) do
      {:ok, delivery} ->
        handle_attempt_outcome(
          status,
          delivery,
          subscription,
          event_type,
          payload,
          delivery_id,
          prefix,
          signing_key,
          attempt_count,
          attempted_at
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:attempt_write_failed, changeset}}
    end
  end

  defp handle_attempt_outcome(
         :SUCCESS,
         delivery,
         _subscription,
         _event_type,
         _payload,
         _delivery_id,
         _prefix,
         _signing_key,
         _attempt_count,
         _attempted_at
       ) do
    {:ok, delivery}
  end

  defp handle_attempt_outcome(
         :FAILED,
         delivery,
         subscription,
         event_type,
         payload,
         delivery_id,
         prefix,
         signing_key,
         attempt_count,
         attempted_at
       ) do
    _subscription = record_delivery_failure(subscription, prefix)

    if attempt_count < @max_attempts do
      Process.sleep(backoff_delay_ms(attempt_count))

      attempt_loop(
        subscription,
        event_type,
        payload,
        delivery_id,
        prefix,
        signing_key,
        attempt_count + 1
      )
    else
      land_in_dlq(subscription, event_type, payload, delivery_id, attempted_at, prefix)
      {:ok, delivery}
    end
  end

  # design §3.3 -- Letflow's own choice, not a port of any R-Co header/format
  # (R-Co's src/webhook/ is unreachable from this codebase's history).
  defp sign(signing_key, json_body) do
    hmac = :crypto.mac(:hmac, :sha256, signing_key, json_body)
    "sha256=" <> Base.encode16(hmac, case: :lower)
  end

  # design §5 -- :httpc (via :inets, already part of the OTP standard
  # library) chosen over adding a new hex dependency; no HTTP client exists
  # in mix.exs today. Flagged as an open question for REVIEWER (design §7
  # OQ-7): a future requirement may switch this to Req.
  defp dispatch_http(target_url, json_body, signature) do
    # :webhook_ssrf_validation_enabled defaults to true; set to false in delivery
    # tests only so the local :gen_tcp test server's http://127.0.0.1:PORT URL passes.
    if Application.get_env(:letflow, :webhook_ssrf_validation_enabled, true) do
      dispatch_http(target_url, json_body, signature, &UrlValidator.default_resolver/1)
    else
      do_dispatch_http(target_url, json_body, signature)
    end
  end

  # Test-injectable variant for DNS-rebinding tests (AC4 per design §6.2).
  defp dispatch_http(target_url, json_body, signature, dns_resolver) do
    case UrlValidator.validate(target_url, dns_resolver) do
      {:error, :target_url_not_allowed} ->
        {:FAILED, nil, "target_url not allowed (SSRF protection)"}

      :ok ->
        do_dispatch_http(target_url, json_body, signature)
    end
  end

  defp do_dispatch_http(target_url, json_body, signature) do
    headers = [
      {~c"content-type", ~c"application/json"},
      {String.to_charlist(@signature_header), String.to_charlist(signature)}
    ]

    request = {String.to_charlist(target_url), headers, ~c"application/json", json_body}

    case :httpc.request(:post, request, [{:timeout, @http_timeout_ms}], []) do
      {:ok, {{_http_version, status_code, _reason_phrase}, _resp_headers, _resp_body}}
      when status_code >= 200 and status_code < 300 ->
        {:SUCCESS, status_code, nil}

      {:ok, {{_http_version, status_code, _reason_phrase}, _resp_headers, resp_body}} ->
        body_snippet = resp_body |> to_string() |> String.slice(0, 500)
        {:FAILED, status_code, "HTTP #{status_code}: #{body_snippet}"}

      {:error, reason} ->
        {:FAILED, nil, "transport error: #{inspect(reason)}"}
    end
  end

  # design §4.2 -- private so a test can assert the delay computation
  # directly without sleeping through it.
  defp backoff_delay_ms(attempt_count) do
    :timer.seconds(Integer.pow(2, attempt_count - 1))
  end

  # design §3.4/§3.4.1 -- shared write path behind AC4. Row-locked
  # (SELECT ... FOR UPDATE) then in-Elixir-decide then conditional-write,
  # the same hazard class as update/3's own reconciliation: two concurrent
  # failing deliveries for the same subscription must not both read
  # consecutive_failures = 4, both increment to 5, and only one "win" the
  # auto-pause transition while losing a count.
  @spec record_delivery_failure(Subscription.t(), prefix :: String.t()) :: Subscription.t()
  defp record_delivery_failure(%Subscription{id: id}, prefix) do
    {:ok, %{apply: updated}} =
      Multi.new()
      |> Multi.run(:locked, fn repo, _changes -> fetch_and_lock_subscription(repo, id, prefix) end)
      |> Multi.run(:apply, fn _repo, %{locked: locked} ->
        apply_delivery_failure(locked, prefix)
      end)
      |> Repo.transaction()

    updated
  end

  defp apply_delivery_failure(%Subscription{} = locked, prefix) do
    new_count = locked.consecutive_failures + 1
    last_failure_at = current_timestamp()

    attrs =
      if new_count >= @auto_pause_threshold and locked.status != :PAUSED do
        %{
          consecutive_failures: new_count,
          last_failure_at: last_failure_at,
          status: :PAUSED,
          paused_at: current_timestamp()
        }
      else
        %{consecutive_failures: new_count, last_failure_at: last_failure_at}
      end

    locked
    |> Subscription.failure_changeset(attrs)
    |> Repo.update(prefix: prefix)
  end

  # design §3.5 -- step 4.g's final branch (attempt exhausted). Calls the
  # already-shipped Letflow.Dlq.enqueue/2.
  defp land_in_dlq(subscription, event_type, payload, delivery_id, last_attempted_at, prefix) do
    Letflow.Dlq.enqueue(
      %{
        entry_type: "webhook",
        reference_id: delivery_id,
        reason: "webhook delivery exhausted max_attempts",
        source_payload: payload,
        context_json: %{
          subscription_id: subscription.id,
          target_url: subscription.target_url,
          event_type: event_type,
          attempt_count: @max_attempts
        },
        last_failed_at: last_attempted_at
      },
      prefix: prefix
    )
  end

  # ===========================================================================
  # list/1 (design §3.2)
  # ===========================================================================

  @doc """
  Plain, non-paginated listing of `webhook_subscriptions`, ordered
  `created_at DESC`. Deliberate divergence from `Letflow.Dlq.list/2`'s
  cursor convention (design §3.2) — `webhooksApi.list()` takes no query
  parameters at all.

  Tenant-scoped by `opts[:prefix]` alone: `Repo.all(query, prefix: prefix)`
  executes against the caller's own Postgres schema, which never contains
  another tenant's rows (schema-per-tenant, Decision B) — not a `WHERE
  tenant_id = ...` filter that could be omitted by mistake.
  """
  @spec list(opts()) :: {:ok, [Subscription.t()]}
  def list(opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    subscriptions =
      Subscription
      |> order_by([s], desc: s.created_at)
      |> Repo.all(prefix: prefix)

    {:ok, subscriptions}
  end

  # ===========================================================================
  # update/3 (design §3.3)
  # ===========================================================================

  @type update_attrs :: %{
          optional(:status) => String.t(),
          optional(:is_active) => boolean(),
          optional(:outbound_mapping_id) => String.t() | nil
        }

  @doc """
  Reconciles `%{status: "ACTIVE" | "PAUSED"}` and/or `%{is_active:
  boolean()}` to one stored `status` (design §3.3's reconciliation table).
  Resolves the two inputs to a single target atom *before* touching the
  database — the transaction below either has one unambiguous target or
  never starts.

  Row-locked via `SELECT ... FOR UPDATE` then an in-Elixir comparison of
  current vs. target status to decide the `paused_at` effect, then a single
  conditional `status_changeset/2` update — the same lock-then-check idiom
  `Letflow.Dlq.retry/2`/`discard/2` establish.

  `id`/not-found handling mirrors `Letflow.Dlq.get/2` exactly:
  `Ecto.UUID.cast/1` first (`{:error, :invalid_id}`, no DB round-trip), then
  a row-lock-and-fetch scoped to `opts[:prefix]` (`{:error, :not_found}`
  when absent).

  **Outbound mapping link (REQ-565 slice 2):** the presence of the `:outbound_mapping_id` key
  matters. A uuid string links an `"outbound"` mapping of this tenant (taken `FOR SHARE` in the
  same transaction, see `Letflow.IntegrationMappings.delete/3`); `nil` clears the link. Any other
  value, an unknown or malformed id, an inbound mapping or another tenant's mapping is one
  `{:error, :invalid_mapping}` and nothing in the transaction (status included) is written. A
  link-only update needs no `status`/`is_active`; an update with neither status nor link keeps
  `{:error, :invalid_status}`.
  """
  @spec update(id :: String.t(), update_attrs(), opts()) ::
          {:ok, Subscription.t()}
          | {:error, :invalid_id}
          | {:error, :not_found}
          | {:error, :invalid_status}
          | {:error, :invalid_mapping}
          | {:error, Ecto.Changeset.t()}
  def update(id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, id} <- cast_subscription_id(id),
         {:ok, target_status} <- reconcile_status(attrs) do
      Multi.new()
      |> Multi.run(:subscription, fn repo, _changes ->
        fetch_and_lock_subscription(repo, id, prefix)
      end)
      |> Multi.run(:linked, fn _repo, %{subscription: subscription} ->
        apply_mapping_link(subscription, attrs, prefix)
      end)
      |> Multi.run(:apply, fn _repo, %{linked: subscription} ->
        apply_status_update(subscription, target_status, prefix)
      end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  defp apply_mapping_link(subscription, attrs, prefix) do
    case Map.fetch(attrs, :outbound_mapping_id) do
      :error ->
        {:ok, subscription}

      {:ok, nil} ->
        write_link(subscription, nil, prefix)

      {:ok, mapping_id} when is_binary(mapping_id) ->
        case IntegrationMappings.lock_outbound_for_link(mapping_id, prefix) do
          {:ok, mapping} -> write_link(subscription, mapping.id, prefix)
          {:error, :not_found} -> {:error, :invalid_mapping}
        end

      {:ok, _other} ->
        {:error, :invalid_mapping}
    end
  end

  defp write_link(%Subscription{outbound_mapping_id: same} = subscription, same, _prefix),
    do: {:ok, subscription}

  defp write_link(subscription, mapping_id, prefix) do
    subscription
    |> Subscription.link_changeset(%{outbound_mapping_id: mapping_id})
    |> Repo.update(prefix: prefix)
  end

  @spec reconcile_status(update_attrs()) ::
          {:ok, :ACTIVE | :PAUSED | :keep} | {:error, :invalid_status}
  defp reconcile_status(%{status: status, is_active: is_active}) do
    with {:ok, from_status} <- status_string_to_atom(status),
         {:ok, from_is_active} <- is_active_to_atom(is_active) do
      if from_status == from_is_active do
        {:ok, from_status}
      else
        {:error, :invalid_status}
      end
    end
  end

  defp reconcile_status(%{status: status}) do
    status_string_to_atom(status)
  end

  defp reconcile_status(%{is_active: is_active}) do
    is_active_to_atom(is_active)
  end

  defp reconcile_status(%{outbound_mapping_id: _link}), do: {:ok, :keep}

  defp reconcile_status(_attrs), do: {:error, :invalid_status}

  defp status_string_to_atom("ACTIVE"), do: {:ok, :ACTIVE}
  defp status_string_to_atom("PAUSED"), do: {:ok, :PAUSED}
  defp status_string_to_atom(_other), do: {:error, :invalid_status}

  defp is_active_to_atom(true), do: {:ok, :ACTIVE}
  defp is_active_to_atom(false), do: {:ok, :PAUSED}
  defp is_active_to_atom(_other), do: {:error, :invalid_status}

  defp apply_status_update(%Subscription{} = subscription, :keep, _prefix),
    do: {:ok, subscription}

  defp apply_status_update(%Subscription{status: :ACTIVE} = subscription, :ACTIVE, prefix) do
    subscription
    |> Subscription.status_changeset(%{status: :ACTIVE, paused_at: nil})
    |> Repo.update(prefix: prefix)
  end

  defp apply_status_update(%Subscription{status: :PAUSED} = subscription, :ACTIVE, prefix) do
    subscription
    |> Subscription.status_changeset(%{status: :ACTIVE, paused_at: nil})
    |> Repo.update(prefix: prefix)
  end

  defp apply_status_update(%Subscription{status: :PAUSED} = subscription, :PAUSED, _prefix) do
    # Idempotent re-pause: preserve the original pause moment, no write needed.
    {:ok, subscription}
  end

  defp apply_status_update(%Subscription{status: :ACTIVE} = subscription, :PAUSED, prefix) do
    subscription
    |> Subscription.status_changeset(%{status: :PAUSED, paused_at: current_timestamp()})
    |> Repo.update(prefix: prefix)
  end

  # ===========================================================================
  # delete/2 (design §3.4)
  # ===========================================================================

  @doc """
  Tenant-scoped hard delete — no soft-delete/tombstone column exists on this
  schema. `id` validation and not-found handling mirror `update/3`'s own:
  `Ecto.UUID.cast/1` first, then a scoped fetch; if the row is absent (never
  existed, already deleted, or belongs to a different tenant's schema),
  `{:error, :not_found}` — structurally impossible to return a "duplicate
  success," since there is no row left to re-delete.
  """
  @spec delete(id :: String.t(), opts()) ::
          {:ok, Subscription.t()}
          | {:error, :invalid_id}
          | {:error, :not_found}
  def delete(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, subscription} <- get(id, opts) do
      Repo.delete(subscription, prefix: prefix)
    end
  end

  # ===========================================================================
  # list_delivery_attempts/3 (design §1.1, REQ-184)
  # ===========================================================================

  @doc """
  Lists `webhook_delivery_attempts` rows for one subscription, ordered
  `attempted_at DESC, attempt_count DESC` (design §4's two-key ordering,
  OQ-2 -- `attempted_at` is a `:utc_datetime` column, second precision, so
  two attempts within the same wall-clock second are possible; `attempt_count`
  breaks that tie deterministically since it is always populated), limited
  at the database level to `limit` rows via `Ecto.Query.limit/2`.

  Reuses the private `get/2` helper verbatim (design §1.1 step 1) to
  validate + tenant-scope-check the subscription first -- this is what
  makes the cross-tenant-404 behavior automatic and consistent with
  `update/3`/`delete/2`: `get/2` already returns `{:error, :invalid_id}` for
  a malformed UUID (no DB round-trip) and `{:error, :not_found}` for both
  "row absent everywhere" and "row exists only in another tenant's schema."
  The fetched subscription itself is discarded -- only used to prove
  existence/tenant-scope, not rendered into the response.

  A real, in-tenant subscription with zero delivery attempts returns
  `{:ok, []}`, not an error.
  """
  @spec list_delivery_attempts(subscription_id :: String.t(), limit :: pos_integer(), opts()) ::
          {:ok, [Delivery.t()]} | {:error, :invalid_id} | {:error, :not_found}
  def list_delivery_attempts(subscription_id, limit, opts)
      when is_binary(subscription_id) and is_integer(limit) and limit > 0 and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _subscription} <- get(subscription_id, opts) do
      deliveries =
        Delivery
        |> where([d], d.subscription_id == ^subscription_id)
        |> order_by([d], desc: d.attempted_at, desc: d.attempt_count)
        |> limit(^limit)
        |> Repo.all(prefix: prefix)

      {:ok, deliveries}
    end
  end

  # ===========================================================================
  # get/2 (design §3.5, private helper)
  # ===========================================================================

  @spec get(id :: String.t(), opts()) ::
          {:ok, Subscription.t()} | {:error, :invalid_id | :not_found}
  defp get(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case Repo.get(Subscription, id, prefix: prefix) do
          nil -> {:error, :not_found}
          %Subscription{} = subscription -> {:ok, subscription}
        end
    end
  end

  # ── shared helpers ──────────────────────────────────────────────────────

  defp cast_subscription_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_id}
    end
  end

  defp fetch_and_lock_subscription(repo, id, prefix) do
    Subscription
    |> where([s], s.id == ^id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :not_found}
      %Subscription{} = subscription -> {:ok, subscription}
    end
  end

  defp unwrap_write_result({:ok, %{apply: subscription}}), do: {:ok, subscription}
  defp unwrap_write_result({:error, _failed_step, reason, _changes}), do: {:error, reason}

  defp current_timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
