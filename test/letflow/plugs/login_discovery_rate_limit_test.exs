defmodule Letflow.Plugs.LoginDiscoveryRateLimitTest do
  @moduledoc """
  REQ-436 (spec `test/specs/REQ-436.md`): the plug through the stub chain
  `ClientIp -> LoginDiscoveryRateLimit -> :match` in
  `Letflow.LoginDiscoveryProbeRouter`.

  Covers AC2 (independence from `/api/public`, both directions), AC3 (per-IP
  window, spoofed headers, global trips across many addresses), AC4
  (ordering), AC5 (IPv6 / mapped IPv4), AC6 (byte-identical 429s, body never
  read), AC8 (`max_ip_keys` fail closed), AC10 (per-email and `:send`), AC11
  (telemetry) and AC13 (no email / key / IP in Logger output).

  `async: false`: the limiter's ETS table (and `/api/public`'s) are node-global.
  Every test empties the login-discovery table before and after, snapshots and
  restores the `/api/public` rows it touches, and restores the Application env
  it overrides. Refill rates are tiny (0.0001/s) so real elapsed time during a
  test is negligible; nothing sleeps. Addresses are RFC 5737 / RFC 3849
  documentation addresses.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.LoginDiscoveryProbeRouter, as: Probe
  alias Letflow.Plugs.ClientIp
  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter
  alias Letflow.Plugs.LoginDiscoveryRateLimit.Bucket
  alias Letflow.Plugs.PublicReadRateLimit

  @table :letflow_login_discovery_rate_limit
  @public_table :letflow_public_read_rate_limit
  @global {:login_discovery, :global}
  @event [:letflow, :login_discovery, :outcome]

  @base [
    global_capacity: 1_000,
    global_refill_per_sec: 0.0001,
    ip_capacity: 5,
    ip_refill_per_sec: 0.0001,
    email_capacity: 3,
    email_refill_per_sec: 0.0001,
    send_capacity: 1,
    send_refill_per_sec: 0.0001
  ]

  def handle_event(_event, measurements, metadata, test_pid) do
    send(test_pid, {:outcome_event, measurements, metadata})
  end

  setup do
    original = Application.fetch_env(:letflow, Limiter)
    original_public = Application.fetch_env(:letflow, PublicReadRateLimit)
    original_client_ip = Application.fetch_env(:letflow, ClientIp)
    public_global = :ets.lookup(@public_table, :global)

    :ets.delete_all_objects(@table)
    Application.put_env(:letflow, Limiter, @base)
    Application.put_env(:letflow, ClientIp, trusted_proxies: [])

    handler_id = "req436-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :ets.delete_all_objects(@table)
      restore_env(Limiter, original)
      restore_env(PublicReadRateLimit, original_public)
      restore_env(ClientIp, original_client_ip)

      :ets.delete(@public_table, :global)
      Enum.each(public_global, &:ets.insert(@public_table, &1))
    end)

    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:letflow, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:letflow, key)

  defp put_config(overrides), do: Application.put_env(:letflow, Limiter, @base ++ overrides)

  defp reset_table, do: :ets.delete_all_objects(@table)

  # @base plus overrides, preserving only a retry_after_seconds already set by the test.
  defp tweak(overrides) do
    keep = Keyword.take(Application.get_env(:letflow, Limiter), [:retry_after_seconds])
    Application.put_env(:letflow, Limiter, @base ++ keep ++ overrides)
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Distinct /64 per n, documentation prefix 2001:db8::/32 (RFC 3849).
  defp addr(n), do: {0x2001, 0xDB8, n, 0, 0, 0, 0, 1}

  defp send_probe(ip, headers) do
    base = conn(:post, "/probe") |> Map.put(:remote_ip, ip)
    conn = Enum.reduce(headers, base, fn {k, v}, c -> put_req_header(c, k, v) end)
    Probe.call(conn, Probe.init([]))
  end

  defp probe(ip), do: send_probe(ip, [])

  defp probe_email(ip, key, kind) do
    conn(:post, "/probe-email")
    |> Map.put(:remote_ip, ip)
    |> put_req_header("x-test-email-key", key)
    |> put_req_header("x-test-kind", Atom.to_string(kind))
    |> then(&Probe.call(&1, Probe.init([])))
  end

  defp drain_events(acc) do
    receive do
      {:outcome_event, m, md} -> drain_events([{m, md} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp events, do: drain_events([])

  defp global_tokens(at_ms) do
    {:ok, tokens} = Bucket.token_count(@global, at_ms)
    tokens
  end

  # Produces a 429 whose cause is `cause`, from a clean table, and returns it.
  defp refuse(:ip, _key) do
    reset_table()
    tweak(ip_capacity: 1)
    assert probe({192, 0, 2, 1}).status == 200
    probe({192, 0, 2, 1})
  end

  defp refuse(:global, _key) do
    reset_table()
    tweak(global_capacity: 1)
    assert probe({192, 0, 2, 2}).status == 200
    probe({192, 0, 2, 3})
  end

  defp refuse(:email, key) do
    reset_table()
    tweak(email_capacity: 1)
    assert probe_email({192, 0, 2, 4}, key, :request).status == 200
    probe_email({192, 0, 2, 5}, key, :request)
  end

  describe "AC2: independence from /api/public, both directions" do
    test "flooding the login-discovery GLOBAL bucket leaves /api/public unaffected" do
      put_config(global_capacity: 5)
      statuses = for n <- 1..6, do: probe(addr(n)).status
      assert statuses == [200, 200, 200, 200, 200, 429]
      assert [{_, %{outcome: :rate_limited_global}}] = events()

      public = conn(:get, "/x") |> Map.put(:remote_ip, {203, 0, 113, 10})
      on_exit(fn -> :ets.delete(@public_table, {:ip, {203, 0, 113, 10}}) end)
      result = PublicReadRateLimit.call(public, [])
      refute result.halted
      refute result.status == 429
    end

    test "flooding the /api/public GLOBAL bucket leaves login-discovery unaffected" do
      Application.put_env(:letflow, PublicReadRateLimit,
        global_capacity: 2,
        global_refill_per_sec: 0.0001,
        ip_capacity: 50,
        ip_refill_per_sec: 0.0001
      )

      :ets.insert(@public_table, {:global, 0.0, now()})
      on_exit(fn -> :ets.delete(@public_table, {:ip, {203, 0, 113, 11}}) end)

      public = conn(:get, "/x") |> Map.put(:remote_ip, {203, 0, 113, 11})
      exhausted = PublicReadRateLimit.call(public, [])
      assert exhausted.halted and exhausted.status == 429

      assert probe(addr(1)).status == 200
      assert global_tokens(now()) < @base[:global_capacity]
      assert global_tokens(now()) > @base[:global_capacity] - 2
    end

    test "one address exhausting its login-discovery bucket leaves the same address on /api/public unaffected" do
      ip = {198, 51, 100, 12}
      on_exit(fn -> :ets.delete(@public_table, {:ip, ip}) end)
      statuses = for _ <- 1..6, do: probe(ip).status
      assert statuses == [200, 200, 200, 200, 200, 429]

      result = PublicReadRateLimit.call(conn(:get, "/x") |> Map.put(:remote_ip, ip), [])
      refute result.halted
    end

    test "one address exhausting its /api/public bucket leaves the same address on login-discovery unaffected" do
      ip = {198, 51, 100, 13}
      on_exit(fn -> :ets.delete(@public_table, {:ip, ip}) end)

      Application.put_env(:letflow, PublicReadRateLimit,
        global_capacity: 1_000,
        global_refill_per_sec: 1,
        ip_capacity: 2,
        ip_refill_per_sec: 0.0001
      )

      public = fn -> PublicReadRateLimit.call(conn(:get, "/x") |> Map.put(:remote_ip, ip), []) end
      assert [false, false, true] == [public.().halted, public.().halted, public.().halted]

      assert probe(ip).status == 200
      assert {:ok, tokens} = Bucket.token_count({:login_discovery, :ip, {:v4, ip}}, now())
      assert tokens > 3.99 and tokens < 4.01
    end
  end

  describe "AC3: per-IP window, spoofed headers, global independent of any single IP" do
    test "the (ip_capacity+1)th request from one address is 429, whatever X-Forwarded-For says" do
      ip = {192, 0, 2, 20}

      statuses =
        for i <- 1..6 do
          send_probe(ip, [
            {"x-forwarded-for", "203.0.113.#{i}"},
            {"forwarded", "for=198.51.100.#{i}"}
          ]).status
        end

      assert statuses == [200, 200, 200, 200, 200, 429]
      assert Bucket.size(:ip) == 1
    end

    test "a spoofed X-Real-IP from an untrusted peer does not change the bucket either" do
      ip = {192, 0, 2, 21}

      statuses =
        for i <- 1..6, do: send_probe(ip, [{"x-real-ip", "203.0.113.#{i}"}]).status

      assert statuses == [200, 200, 200, 200, 200, 429]
      assert Bucket.size(:ip) == 1
    end

    test "the bucket follows conn.assigns.client_ip, and conn.remote_ip when the assign is absent" do
      a = {192, 0, 2, 22}
      b = {192, 0, 2, 23}

      from_assign = fn peer ->
        conn(:post, "/x") |> Map.put(:remote_ip, peer) |> assign(:client_ip, a)
      end

      call = fn conn -> Limiter.call(conn, []) end

      assert Enum.map(1..5, fn _ -> call.(from_assign.(b)).halted end) == List.duplicate(false, 5)
      # a's bucket is spent, so the assign wins over a DIFFERENT remote_ip ...
      assert call.(from_assign.({192, 0, 2, 99})).halted
      # ... and b's own bucket (the remote_ip) was never touched.
      assert {:ok, tokens} = Bucket.token_count({:login_discovery, :ip, {:v4, a}}, now())
      assert tokens < 0.01
      assert :absent == Bucket.token_count({:login_discovery, :ip, {:v4, b}}, now())

      no_assign = fn -> conn(:post, "/x") |> Map.put(:remote_ip, b) |> call.() end
      assert Enum.map(1..5, fn _ -> no_assign.().halted end) == List.duplicate(false, 5)
      assert no_assign.().halted
    end

    test "an unusable client_ip assign falls back to remote_ip" do
      peer = {192, 0, 2, 24}

      for junk <- [nil, "1.2.3.4", {1, 2, 3}, {300, 1, 1, 1}, {1, 2, 3, 4, 5, 6, 7, 70_000}] do
        conn = conn(:post, "/x") |> Map.put(:remote_ip, peer) |> assign(:client_ip, junk)
        assert Limiter.client_address(conn) == peer
      end
    end

    test "the global bucket trips across many distinct addresses, none over its own limit" do
      put_config(global_capacity: 8)
      statuses = for n <- 1..9, do: probe(addr(n)).status
      assert statuses == List.duplicate(200, 8) ++ [429]

      assert [{%{count: 1}, %{outcome: :rate_limited_global}}] = events()
      assert Bucket.size(:ip) == 9
    end
  end

  describe "AC4: ordering -- the per-IP bucket is consumed first" do
    test "one IP sending 10x global_capacity is refused after ip_capacity and spends few global tokens" do
      put_config(global_capacity: 20)
      ip = {192, 0, 2, 30}
      statuses = for _ <- 1..200, do: probe(ip).status
      assert Enum.take(statuses, 5) == List.duplicate(200, 5)
      assert Enum.drop(statuses, 5) == List.duplicate(429, 195)

      at = now()
      assert global_tokens(at) >= 20 - 5

      ev = events()
      assert length(ev) == 195

      assert Enum.all?(ev, fn {m, md} ->
               m == %{count: 1} and md == %{outcome: :rate_limited_ip}
             end)

      # a second address is still admitted and never sees a global refusal.
      assert probe({192, 0, 2, 31}).status == 200
      assert events() == []
    end

    test "an IP-refused request consumes no global token" do
      put_config(global_capacity: 20)
      ip = {192, 0, 2, 32}
      for _ <- 1..5, do: assert(probe(ip).status == 200)

      at = now()
      before = global_tokens(at)
      assert probe(ip).status == 429
      assert global_tokens(at) == before
    end
  end

  describe "AC5: IPv6 aggregation and IPv4-mapped IPv6" do
    test "ip_bucket_id/1 table" do
      for {input, expected} <- [
            {{192, 0, 2, 1}, {:v4, {192, 0, 2, 1}}},
            {{0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}, {:v4, {192, 0, 2, 1}}},
            {{0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, {:v4, {203, 0, 113, 7}}},
            {{0, 0, 0, 0, 0, 0xFFFF, 0, 0}, {:v4, {0, 0, 0, 0}}},
            {{0, 0, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF}, {:v4, {255, 255, 255, 255}}},
            {{0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}, {:v6_64, {0x2001, 0xDB8, 1, 2}}},
            {{0x2001, 0xDB8, 1, 2, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF},
             {:v6_64, {0x2001, 0xDB8, 1, 2}}},
            {{0, 0, 0, 0, 0, 0, 0, 1}, {:v6_64, {0, 0, 0, 0}}},
            # IPv4-compatible (not mapped) and a mapped-looking prefix with extra bits stay v6.
            {{0, 0, 0, 0, 0, 0, 0x0102, 0x0304}, {:v6_64, {0, 0, 0, 0}}},
            {{0, 0, 0, 0, 1, 0xFFFF, 0x0102, 0x0304}, {:v6_64, {0, 0, 0, 0}}}
          ] do
        assert Limiter.ip_bucket_id(input) == expected, "ip_bucket_id(#{inspect(input)})"
      end

      assert Limiter.ip_bucket_id({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
               Limiter.ip_bucket_id({0x2001, 0xDB8, 1, 2, 9, 8, 7, 6})

      refute Limiter.ip_bucket_id({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
               Limiter.ip_bucket_id({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})

      refute Limiter.ip_bucket_id({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
               Limiter.ip_bucket_id({0x2001, 0xDB9, 1, 2, 0, 0, 0, 1})
    end

    test "end-to-end: addresses sharing a /64 share one bucket; another /64 does not" do
      same_a = {0x2001, 0xDB8, 0x55, 0, 0, 0, 0, 1}
      same_b = {0x2001, 0xDB8, 0x55, 0, 0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD}
      other = {0x2001, 0xDB8, 0x56, 0, 0, 0, 0, 1}

      statuses =
        for i <- 1..6, do: probe(if(rem(i, 2) == 0, do: same_a, else: same_b)).status

      assert statuses == [200, 200, 200, 200, 200, 429]
      assert Bucket.size(:ip) == 1
      assert probe(other).status == 200
      assert Bucket.size(:ip) == 2
    end

    test "end-to-end: a mapped X-Real-IP from a trusted proxy and the plain v4 form share ONE bucket" do
      Application.put_env(:letflow, ClientIp, trusted_proxies: [{{10, 0, 0, 0}, 8}])
      proxy = {10, 0, 0, 7}

      mapped = send_probe(proxy, [{"x-real-ip", "::ffff:203.0.113.9"}])
      assert mapped.status == 200
      # ClientIp hands the limiter the mapped v6 tuple; the limiter must fold it to v4.
      assert tuple_size(mapped.assigns.client_ip) == 8

      statuses =
        for header <- ["::ffff:203.0.113.9", "203.0.113.9", "::ffff:cb00:7109", "203.0.113.9"] do
          send_probe(proxy, [{"x-real-ip", header}]).status
        end

      assert statuses == [200, 200, 200, 200]
      assert send_probe(proxy, [{"x-real-ip", "::ffff:203.0.113.9"}]).status == 429
      assert send_probe(proxy, [{"x-real-ip", "203.0.113.9"}]).status == 429

      assert Bucket.size(:ip) == 1

      assert {:ok, _} =
               Bucket.token_count({:login_discovery, :ip, {:v4, {203, 0, 113, 9}}}, now())

      # the proxy's own address never became a key: the visitor is the client.
      assert :absent == Bucket.token_count({:login_discovery, :ip, {:v4, proxy}}, now())
    end
  end

  describe "AC6: the 429 is byte-identical for every cause and independent of the email" do
    test "ip, global and email refusals have the same status, headers and body" do
      ip = refuse(:ip, nil)
      global = refuse(:global, nil)
      email = refuse(:email, "alice@example.test")

      assert Enum.map(events(), fn {_, md} -> md.outcome end) ==
               [:rate_limited_ip, :rate_limited_global, :rate_limited_email]

      for c <- [ip, global, email], do: assert(c.status == 429 and c.halted)
      assert Enum.sort(ip.resp_headers) == Enum.sort(global.resp_headers)
      assert Enum.sort(ip.resp_headers) == Enum.sort(email.resp_headers)
      assert ip.resp_body == global.resp_body
      assert ip.resp_body == email.resp_body

      headers = Map.new(ip.resp_headers)
      assert headers["retry-after"] == Integer.to_string(Limiter.config().retry_after_seconds)
      assert headers["cache-control"] == "private, no-store"
      assert headers["referrer-policy"] == "no-referrer"
      assert headers["x-robots-tag"] == "noindex, nofollow"
    end

    test "the body does not depend on which email was submitted, and retry-after is configurable" do
      other = refuse(:email, "bob-the-second-address@example.test")
      base = refuse(:email, "alice@example.test")
      assert other.resp_body == base.resp_body
      assert Enum.sort(other.resp_headers) == Enum.sort(base.resp_headers)
      refute String.contains?(base.resp_body, "alice")

      put_config(retry_after_seconds: 123)
      assert Map.new(refuse(:email, "alice@example.test").resp_headers)["retry-after"] == "123"
      assert Map.new(refuse(:ip, nil).resp_headers)["retry-after"] == "123"
      assert Map.new(refuse(:global, nil).resp_headers)["retry-after"] == "123"
    end

    test "a refused source gets 429 even when the body is invalid or unreadable (body never read)" do
      put_config(ip_capacity: 1)
      ip = {192, 0, 2, 40}
      assert probe(ip).status == 200

      bad =
        conn(:post, "/probe", "{\"email\": \"truncated")
        |> Map.put(:remote_ip, ip)
        |> put_req_header("content-type", "application/json; charset=\"broken")

      result = Probe.call(bad, Probe.init([]))
      assert result.status == 429
      assert result.halted
      assert %Plug.Conn.Unfetched{} = result.body_params
      assert result.resp_body == probe(ip).resp_body
    end
  end

  describe "AC8: max_ip_keys fails closed without spending a global token" do
    test "the (cap+1)th distinct source is refused, nothing is evicted, earlier sources are served" do
      put_config(max_ip_keys: 3)
      for n <- 1..3, do: assert(probe(addr(n)).status == 200)
      assert Bucket.size(:ip) == 3

      at = now()
      before = global_tokens(at)
      refused = probe(addr(4))
      assert refused.status == 429
      assert refused.halted
      assert global_tokens(at) == before

      assert [{_, %{outcome: :rate_limited_ip}}] = events()
      assert Bucket.size(:ip) == 3
      assert Bucket.sweep(at, :ip) == 0

      for n <- 1..3 do
        assert {:ok, _} =
                 Bucket.token_count({:login_discovery, :ip, Limiter.ip_bucket_id(addr(n))}, at)
      end

      # existing sources are unaffected until their own bucket empties; the new one stays refused.
      assert probe(addr(1)).status == 200
      assert probe(addr(2)).status == 200
      assert probe(addr(4)).status == 429
      assert Bucket.size(:ip) == 3
    end
  end

  describe "AC10: per-email and :send buckets" do
    test "the Nth request for one address across different source IPs trips; another address is unaffected" do
      key = "carol@example.test"

      statuses = for n <- 1..4, do: probe_email(addr(n), key, :request).status
      assert statuses == [200, 200, 200, 429]
      assert probe_email(addr(5), "dave@example.test", :request).status == 200
    end

    test ":send is an independent bucket: one send per address, request bucket unchanged" do
      key = "erin@example.test"
      t = 1_000

      assert Limiter.consume_email(key, :request, t) == :ok
      assert Limiter.consume_email(key, :send, t) == :ok
      assert Limiter.consume_email(key, :send, t) == :rate_limited
      assert Limiter.consume_email(key, :send, t + 1) == :rate_limited

      assert {:ok, request_tokens} = Bucket.token_count({:login_discovery, :email_hmac, key}, t)
      assert request_tokens > 1.99 and request_tokens < 2.01
      assert Limiter.consume_email(key, :request, t) == :ok

      # a refused :send does not consume request tokens and other keys have their own send bucket
      assert Limiter.consume_email("frank@example.test", :send, t) == :ok

      assert [{_, %{outcome: :rate_limited_email}}, {_, %{outcome: :rate_limited_email}}] =
               events()
    end

    test "kind :send through the endpoint chain is refused with the same 429" do
      key = "grace@example.test"
      assert probe_email(addr(1), key, :send).status == 200
      refused = probe_email(addr(2), key, :send)
      assert refused.status == 429
      assert probe_email(addr(3), key, :request).status == 200

      assert refused.resp_body == refuse(:ip, nil).resp_body
    end
  end

  describe "AC11: outcome telemetry" do
    test "each refusal emits exactly one event with only the :outcome metadata key" do
      refuse(:ip, nil)
      assert [{%{count: 1}, md}] = events()
      assert md == %{outcome: :rate_limited_ip}

      refuse(:global, nil)
      assert [{%{count: 1}, md}] = events()
      assert md == %{outcome: :rate_limited_global}

      refuse(:email, "heidi@example.test")
      assert [{%{count: 1}, md}] = events()
      assert md == %{outcome: :rate_limited_email}
      assert Map.keys(md) == [:outcome]
    end

    test "admitted requests emit nothing" do
      assert probe(addr(1)).status == 200
      assert probe_email(addr(1), "ivan@example.test", :request).status == 200
      assert Limiter.consume_email("judy@example.test", :send, 0) == :ok
      assert events() == []
    end
  end

  describe "AC13: nothing identifying reaches the Logger (INV-4)" do
    test "no email, key or IP appears in captured log output while flooding" do
      email = "kim-secret-#{System.unique_integer([:positive])}@example.test"

      log =
        capture_log([level: :debug], fn ->
          put_config(ip_capacity: 2, email_capacity: 1)
          ip = {192, 0, 2, 50}
          for _ <- 1..4, do: probe_email(ip, email, :request)
          for _ <- 1..3, do: probe(ip)
          for _ <- 1..3, do: probe(addr(77))
          Limiter.consume_email(email, :send, 0)
          Limiter.consume_email(email, :send, 1)
          Logger.flush()
        end)

      for needle <- [
            email,
            Base.encode16(email),
            Base.encode16(email, case: :lower),
            "192.0.2.50",
            "{192, 0, 2, 50}",
            "2001:db8"
          ] do
        refute String.contains?(log, needle), "log leaked #{inspect(needle)}"
      end
    end
  end
end
