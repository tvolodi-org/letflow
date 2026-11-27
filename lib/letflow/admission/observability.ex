defmodule Letflow.Admission.Observability do
  @moduledoc """
  The observability surface of the admission control (T-3034).

  `Letflow.Admission` keeps the numbers (the budget that is applied, the
  refusals since the process started, the in-flight admissions with their route
  class and age). This module renders them for a CALLER and emits the two log
  lines an operator needs:

    * `counters/0` — the global figures, safe to serve from the PUBLIC
      `GET /health`: the budget that is actually applied (`pool_size`,
      `reserved_headroom`, `cap`), `in_use`, the fair-share divisor
      (`tracked_tenants`) and the refusals since the process started, split by
      kind. No tenant identifier and no route of any tenant's traffic.
    * `counters_with_tenants/0` — the same figures PLUS the per-tenant
      in-flight rows (the tenant name hashed) and the oldest in-flight
      admission. This one shows tenant data and is therefore served only from
      the PLATFORM-scope route (`GET /api/v1/platform-status/admission`).
    * `log_rejection/2` — ONE structured line per capacity refusal, rate
      limited to at most one line per second.
    * `log_stale/1` — ONE line per admission held longer than the age bound.

  ## What can reach a line (INV-4)

  Only constants, integers, a boolean, the route CLASS of a request (the route
  PATTERN compiled into the router — never the request path, never a path
  parameter, never a query value), and 16-hex keyed pseudonyms of the tenant
  schema names. No token, no header, no body, no request path, no email, no
  raw tenant id and no raw schema name ever reaches a line or a counter map.

  ## The hash key

  `subkey = HMAC-SHA256(master, "letflow/admission-observability/v1" <> <<1>>)`
  (HKDF-Expand, one block), where `master` is the already validated 32-byte
  `:secrets_master_key`. When that key is not available (it cannot be after a
  successful boot), a per-boot random key is used instead and a single
  constant line says so — the hashes stay stable for the lifetime of the
  process, which is what the counter snapshot and the log lines need to be
  comparable with each other.

  ## The rate limit

  At most one rejection line per second, node-wide: the refusals of a busy
  node are one fact ("the budget is exhausted"), not one line per request. The
  number of lines the limit withheld since the previous one is carried in the
  `suppressed=` field, so a burst is visible without being noisy.
  """

  require Logger

  @label "letflow/admission-observability/v1"
  @fallback_key {__MODULE__, :fallback_key}
  @fallback_noted_key {__MODULE__, :fallback_noted}
  @sampler_key {__MODULE__, :sampler}
  @unavailable %{available: false}

  @type context :: %{kind: :global | :tenant, tenant: String.t() | nil, route: String.t()}

  @doc """
  The global counters of the running admission server, as a plain map with
  string keys (the shape a JSON response carries).

  Returns `%{available: false}` when the admission process cannot be reached:
  a counter that cannot be read must never make the caller fail, and the
  public liveness route must never answer 500 because of it.
  """
  @spec counters() :: map()
  def counters do
    case snapshot() do
      nil -> @unavailable
      snapshot -> global_map(snapshot)
    end
  end

  @doc """
  The global counters PLUS the per-tenant in-flight rows and the oldest
  in-flight admission, with the tenant schema names hashed.

  This map shows tenant data and belongs on a platform-scope route only.
  """
  @spec counters_with_tenants() :: map()
  def counters_with_tenants do
    case snapshot() do
      nil -> @unavailable
      snapshot -> Map.merge(global_map(snapshot), tenant_map(snapshot))
    end
  end

  @doc """
  The route CLASS of a request: the route pattern the router compiled in, never
  the request path.

  `"unmatched"` when no route was matched yet (the admission gate runs BEFORE
  the dispatch of the API pipeline's own router when the chain has not matched
  a route) or when the recorded pattern is not printable ASCII.
  """
  @spec route_class(Plug.Conn.t()) :: String.t()
  def route_class(conn) do
    if Map.has_key?(conn.private, :plug_route) do
      pattern = conn |> Plug.Router.match_path() |> String.replace("/*glob", "")

      cond do
        String.ends_with?(pattern, "/*_path") -> "unmatched"
        printable?(pattern) -> pattern
        true -> "unmatched"
      end
    else
      "unmatched"
    end
  rescue
    _error -> "unmatched"
  catch
    _kind, _reason -> "unmatched"
  end

  @doc """
  Emits ONE structured line for a capacity refusal, rate limited to at most one
  line per second. Never raises, exits or throws: a broken log line must not
  turn a 503 into a 500.
  """
  @spec log_rejection(context(), map() | nil) :: :ok
  def log_rejection(context, counters \\ nil) do
    do_log_rejection(context, counters)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp do_log_rejection(context, counters) do
    snapshot = counters || safe_snapshot()

    case sample() do
      :suppress ->
        :ok

      {:emit, suppressed} ->
        fields = fields(context, snapshot)
        Logger.warning(format_message(fields, suppressed), metadata(fields, suppressed))
        :ok
    end
  end

  @doc """
  Emits ONE line for an admission that has been held longer than the age
  bound. The admission stays held (the admission contract forbids revoking a
  held admission) — the line is the whole remedy.
  """
  @spec log_stale(map()) :: :ok
  def log_stale(entry) do
    fields = %{
      tenant: entry[:tenant],
      route: entry[:route] || "unknown",
      age_ms: entry[:age_ms] || 0,
      in_use: entry[:in_use] || 0,
      cap: entry[:cap] || 0
    }

    Logger.warning(
      "admission_stale age_ms=#{fields.age_ms} route=#{fields.route} tenant=#{hash_tenant(fields.tenant)}" <>
        " in_use=#{fields.in_use} cap=#{fields.cap}"
    )

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  The 16-hex pseudonym of a tenant schema name (the first 16 lowercase hex
  characters of `HMAC-SHA256(subkey, "tenant:" <> name)`). `"none"` for a
  missing or empty name. The name is never coerced.
  """
  @spec hash_tenant(String.t() | nil) :: String.t()
  def hash_tenant(name) when is_binary(name) and name != "" do
    :hmac
    |> :crypto.mac(:sha256, subkey(), "tenant:" <> name)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def hash_tenant(_name), do: "none"

  @doc """
  The derived hash key (see the moduledoc). Falls back to a per-boot random
  key when the master key is not a 32-byte binary.
  """
  @spec subkey() :: binary()
  def subkey do
    master =
      case Application.get_env(:letflow, :secrets_master_key) do
        k when is_binary(k) and byte_size(k) == 32 -> k
        _other -> fallback_key()
      end

    :crypto.mac(:hmac, :sha256, master, @label <> <<1>>)
  end

  defp fallback_key do
    key =
      case :persistent_term.get(@fallback_key, nil) do
        nil ->
          k = :crypto.strong_rand_bytes(32)
          :persistent_term.put(@fallback_key, k)
          k

        k ->
          k
      end

    if :persistent_term.get(@fallback_noted_key, nil) == nil do
      :persistent_term.put(@fallback_noted_key, true)
      Logger.warning("admission observability hash key fallback in use")
    end

    key
  end

  # --- counters ------------------------------------------------------------------------------

  defp snapshot do
    safe_snapshot()
  end

  # -> the counter map of the running admission server, or `nil` when it
  # cannot be reached (a node whose admission process is down).
  defp safe_snapshot do
    Letflow.Admission.counters()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
    _kind, _reason -> nil
  end

  defp global_map(snapshot) do
    %{
      "available" => true,
      "tracked_tenants" => snapshot.tracked_tenants,
      "in_use" => snapshot.in_use,
      "cap" => snapshot.cap,
      "reserved_headroom" => snapshot.reserved_headroom,
      "pool_size" => snapshot.pool_size,
      "rejections" => %{
        "global" => snapshot.rejections.global,
        "tenant" => snapshot.rejections.tenant
      }
    }
  end

  defp tenant_map(snapshot) do
    %{
      "tenants" =>
        Enum.map(snapshot.tenants, fn row ->
          %{
            "tenant" => hash_tenant(row.tenant),
            "in_use" => row.in_use,
            "oldest_ms" => row.oldest_ms,
            "routes" =>
              Enum.map(row.routes, fn {class, count} -> %{"route" => class, "count" => count} end)
          }
        end),
      "oldest" =>
        case snapshot.oldest do
          nil ->
            nil

          oldest ->
            %{
              "tenant" => hash_tenant(oldest.tenant),
              "route" => oldest.route,
              "age_ms" => oldest.age_ms
            }
        end
    }
  end

  # --- the rejection line --------------------------------------------------------------------

  defp fields(context, snapshot) do
    snapshot = snapshot || %{}
    holder = Map.get(snapshot, :oldest)

    %{
      kind: context[:kind] || :global,
      in_use: Map.get(snapshot, :in_use) || 0,
      cap: Map.get(snapshot, :cap) || 0,
      tenant: context[:tenant],
      route: context[:route] || "unmatched",
      holder_tenant: holder && holder.tenant,
      holder_route: holder && holder.route,
      holder_age_ms: (holder && holder.age_ms) || 0
    }
  end

  defp format_message(f, suppressed) do
    base =
      "admission_rejected kind=#{f.kind} in_use=#{f.in_use} cap=#{f.cap}" <>
        " tenant=#{hash_tenant(f.tenant)} route=#{f.route}" <>
        " holder_route=#{f.holder_route || "none"} holder_age_ms=#{f.holder_age_ms}" <>
        " holder_tenant=#{hash_tenant(f.holder_tenant)}"

    if suppressed > 0, do: base <> " suppressed=" <> Integer.to_string(suppressed), else: base
  end

  defp metadata(f, suppressed) do
    base = [
      admission_kind: f.kind,
      admission_in_use: f.in_use,
      admission_cap: f.cap,
      admission_tenant: hash_tenant(f.tenant),
      admission_route: f.route,
      admission_holder_route: f.holder_route || "none",
      admission_holder_age_ms: f.holder_age_ms,
      admission_holder_tenant: hash_tenant(f.holder_tenant)
    ]

    if suppressed > 0, do: base ++ [admission_suppressed: suppressed], else: base
  end

  # --- the rate limit ------------------------------------------------------------------------

  # One slot, one second: a node-wide limit. Fail-open (a broken sampler must
  # never silence the line that explains a 503).
  defp sample do
    do_sample()
  rescue
    _error -> {:emit, 0}
  catch
    _kind, _reason -> {:emit, 0}
  end

  defp do_sample do
    {last_ref, suppressed_ref} = sampler()
    now = System.monotonic_time(:millisecond)

    case :atomics.compare_exchange(last_ref, 1, 0, now) do
      :ok ->
        {:emit, :atomics.exchange(suppressed_ref, 1, 0)}

      _lost ->
        previous = :atomics.get(last_ref, 1)

        if previous != 0 and now - previous < 1_000 do
          :atomics.add(suppressed_ref, 1, 1)
          :suppress
        else
          # The window elapsed: take the slot over.
          case :atomics.compare_exchange(last_ref, 1, previous, now) do
            :ok -> {:emit, :atomics.exchange(suppressed_ref, 1, 0)}
            _lost -> :suppress
          end
        end
    end
  end

  defp sampler do
    case :persistent_term.get(@sampler_key, nil) do
      nil ->
        pair = {
          :atomics.new(1, signed: true),
          :atomics.new(1, signed: true)
        }

        :persistent_term.put(@sampler_key, pair)
        pair

      pair ->
        pair
    end
  end

  defp printable?(s), do: Regex.match?(~r/\A[\x21-\x7E]{1,200}\z/, s)

  @doc false
  # TEST ONLY: forget the rate limiter's slot and the fallback key, so a test
  # starts from a node that has not emitted a refusal line yet.
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@sampler_key)
    :persistent_term.erase(@fallback_key)
    :persistent_term.erase(@fallback_noted_key)
    :ok
  end
end
