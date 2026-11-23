defmodule Letflow.Engine.ServiceTaskExhaustion do
  @moduledoc """
  REQ-177 Hook A (`land_service_task_exhaustion/2`), split out of `Letflow.Engine`
  (B4#10 slice 3, code health; code moved verbatim apart from qualifying the
  `Engine` types and `set_instance_error/2`, no behaviour change).
  `Letflow.Engine` keeps `land_service_task_exhaustion/2` and the
  `service_task_dlq_landing_context` type as a `defdelegate` / alias with the
  same name, arity and spec, so no caller changed. Design:
  `lib/letflow/design/req177-dlq-hooks.md` section 2.
  """

  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTask

  # The byte cap of a URL that is read for its origin (SF-01): a URL longer
  # than this is not parsed at all, it is redacted.
  @max_url_bytes 512

  @typedoc """
  Extends `ServiceTask.service_task_give_up_context()` with the two
  additional fields a DLQ row needs that context does not itself carry
  (design doc §2.2).
  """
  @type service_task_dlq_landing_context :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t(),
          required(:variables) => map(),
          required(:last_failure_kind) => ServiceTask.failure_kind(),
          required(:attempt_index) => ServiceTask.attempt_index(),
          required(:retry_limit) => non_neg_integer(),
          required(:attempted_request) => %{
            required(:method) => String.t(),
            required(:url) => String.t(),
            optional(:body) => String.t() | nil,
            optional(:headers) => %{optional(String.t()) => String.t()}
          }
        }

  @doc """
  Hook A of REQ-177 (design doc §2). Called by a future SERVICE_TASK
  dispatch orchestrator (none exists in this codebase yet, per
  `Letflow.Engine.ServiceTask`'s own moduledoc) whenever
  `ServiceTask.decide_failure/3` returns `:give_up` for a SERVICE_TASK node,
  in place of calling `set_instance_error/2` directly.

  Re-derives the exhaustion/non-exhaustion split
  `ServiceTask.decide_failure/3`'s own return value does not carry (design
  doc §3): exactly `ServiceTask.is_retriable_failure(context.last_failure_kind)
  == true and context.attempt_index >= context.retry_limit`. When that is
  **not** the case (an immediately non-retriable failure kind), returns
  `{:error, :not_exhaustion}` and calls neither `Letflow.Dlq.enqueue/2` nor
  `set_instance_error/2` -- the caller is expected to call
  `set_instance_error/2` directly for that case instead, so Hook B
  (`Letflow.Engine.ExecutionError.append_multi/3`'s own
  `:execution_error_dlq_landing` step) lands it generically.

  On genuine exhaustion: lands exactly one `dlq_entries` row via
  `Letflow.Dlq.enqueue/2` (`entry_type: "event"`, `instance_id`,
  `full_reason` naming the classified failure kind, `source_payload` the
  attempted request, `first_failed_at`/`last_failed_at` both the current UTC
  time read at landing, design doc §5.1) **before** delegating to
  `set_instance_error/2` with `dlq_landed_externally: true` so Hook B does
  not also land a row for this same transition (design doc §4).

  **Deferred follow-up (REQ-176's `retry/2`), per the requirement's own
  acceptance criterion:** landing a DLQ entry here does not itself, and
  `Letflow.Dlq.retry/2` called against the entry this function creates does
  not either, re-invoke the original SERVICE_TASK dispatch. Two pieces are
  still missing before it could: (a) a wired SERVICE_TASK transport (the
  injectable `ServiceTask.transport_fun()` -- "no concrete implementation
  ... exists in this codebase yet" per that module's own moduledoc) that a
  future `retry/2`-driven re-dispatch path would need to call, and (b) the
  dispatch orchestrator itself (this function's own caller, which does not
  exist yet) that would need to exist before anything calls `retry/2` in
  response to an operator action at all.
  """
  @spec land_service_task_exhaustion(
          context :: service_task_dlq_landing_context(),
          opts :: Engine.set_error_opts()
        ) ::
          {:ok, Engine.set_error_result()}
          | {:error, :not_exhaustion}
          | Engine.set_error_error()
          | {:error, {:dlq_enqueue_failed, Ecto.Changeset.t()}}
  def land_service_task_exhaustion(context, opts) when is_map(context) and is_list(opts) do
    last_failure_kind = Map.fetch!(context, :last_failure_kind)
    attempt_index = Map.fetch!(context, :attempt_index)
    retry_limit = Map.fetch!(context, :retry_limit)

    if ServiceTask.is_retriable_failure(last_failure_kind) and attempt_index >= retry_limit do
      land_service_task_exhaustion_dlq_entry(context, opts, last_failure_kind, retry_limit)
    else
      {:error, :not_exhaustion}
    end
  end

  defp land_service_task_exhaustion_dlq_entry(context, opts, last_failure_kind, retry_limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    dlq_attrs = %{
      entry_type: "event",
      instance_id: Map.fetch!(context, :instance_id),
      # The NODE the exhausted step belongs to: the operator sees which step
      # failed without reading the row's payload.
      reference_id: Map.get(context, :node_id),
      full_reason:
        "service task failed (#{last_failure_kind}): retries exhausted after #{retry_limit} attempts",
      source_payload: sanitised_attempt(context),
      retry_limit: retry_limit,
      first_failed_at: now,
      last_failed_at: now
    }

    case Dlq.enqueue(dlq_attrs, opts) do
      {:ok, _entry} ->
        Engine.set_instance_error(
          build_service_task_dlq_landing_error_attrs(context),
          Keyword.put(opts, :dlq_landed_externally, true)
        )

      {:error, changeset} ->
        {:error, {:dlq_enqueue_failed, changeset}}
    end
  end

  # The DLQ row records WHAT was attempted, never WHAT was sent (INV-4, the
  # pilot's owner item 7: "no secrets in the log").
  #
  # The attempted request carries the method, the URL, the body and the
  # headers -- and every one of those can carry a secret: a mail body or a
  # token in the body, a bearer credential in a header, a token in the query
  # string, a credential in the userinfo. So the row keeps the METHOD and the
  # ORIGIN of the destination (scheme, host, port) and drops everything else:
  # no path, no query, no userinfo, no body, no headers. The failure kind and
  # the node id say which step failed and how; the origin says where it went.
  @spec sanitised_attempt(map()) :: map()
  defp sanitised_attempt(context) when is_map(context) do
    case Map.get(context, :attempted_request) do
      %{method: method, url: url} when is_binary(url) ->
        %{"method" => to_string(method), "url" => origin_of(url)}

      _other ->
        %{}
    end
  end

  # The origin of a URL: scheme, host and port, never the userinfo, never the
  # path, never the query. A URL that does not parse is not stored at all --
  # an unparsable URL is exactly the value an attacker would try to smuggle.
  # The value is byte-bounded and checked for valid UTF-8 BEFORE it is parsed
  # (SF-01): a URL that is not valid UTF-8 makes the URI parser raise.
  @spec origin_of(String.t()) :: String.t()
  defp origin_of(url) do
    if byte_size(url) <= @max_url_bytes and String.valid?(url) do
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host, port: port}}
        when is_binary(scheme) and is_binary(host) ->
          authority = if default_port?(scheme, port), do: host, else: "#{host}:#{port}"
          "#{scheme}://#{authority}"

        _other ->
          "redacted"
      end
    else
      "redacted"
    end
  end

  # The default port of a scheme is not part of the origin's name: it says
  # nothing about where the request went.
  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_scheme, _port), do: false

  # Same standalone_error_attrs() shape
  # ServiceTask.build_service_task_give_up_error_attrs/1 already builds from
  # an equivalent (strict-subset) context -- built inline here rather than
  # via that function since this context carries extra fields it doesn't
  # accept (design doc §2.4 step 3).
  defp build_service_task_dlq_landing_error_attrs(context) do
    last_failure_kind = Map.fetch!(context, :last_failure_kind)
    attempt_index = Map.fetch!(context, :attempt_index)
    retry_limit = Map.fetch!(context, :retry_limit)

    %{
      instance_id: Map.fetch!(context, :instance_id),
      error_type: :service_task_retries_exhausted,
      affected: {:node, Map.fetch!(context, :node_id)},
      reason:
        "service task failed (#{last_failure_kind}): retries exhausted after #{retry_limit} attempts",
      variables: Map.fetch!(context, :variables),
      details: %{
        last_failure_kind: last_failure_kind,
        attempt_index: attempt_index,
        retry_limit: retry_limit
      },
      actor_id: Map.fetch!(context, :actor_id),
      idempotency_key: Map.fetch!(context, :idempotency_key)
    }
  end
end
