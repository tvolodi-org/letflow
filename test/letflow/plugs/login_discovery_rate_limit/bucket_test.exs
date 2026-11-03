defmodule Letflow.Plugs.LoginDiscoveryRateLimit.BucketTest do
  @moduledoc """
  REQ-436 (spec `test/specs/REQ-436.md`): the ETS token bucket behind
  `Letflow.Plugs.LoginDiscoveryRateLimit` -- namespacing (AC1), bounded state
  and lossless eviction (AC7), the compare-and-swap (AC9) and
  `validate_config!/1` (AC8, config half).

  The table is node-global and owned by the supervised `Bucket`, so this file
  is `async: false`; it empties the table before and after every test and
  restores the Application env it touches. Time is the injectable `now_ms`
  argument, never a sleep.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter
  alias Letflow.Plugs.LoginDiscoveryRateLimit.Bucket
  alias Letflow.Plugs.PublicReadRateLimit

  @table :letflow_login_discovery_rate_limit
  @public_table :letflow_public_read_rate_limit
  @global_key {:login_discovery, :global}

  setup do
    original = Application.fetch_env(:letflow, Limiter)
    :ets.delete_all_objects(@table)

    on_exit(fn ->
      :ets.delete_all_objects(@table)

      case original do
        {:ok, value} -> Application.put_env(:letflow, Limiter, value)
        :error -> Application.delete_env(:letflow, Limiter)
      end
    end)

    :ok
  end

  defp put_config(overrides), do: Application.put_env(:letflow, Limiter, overrides)

  defp rand_key, do: Base.encode16(:crypto.strong_rand_bytes(8))

  defp email_row_count do
    @table
    |> :ets.tab2list()
    |> Enum.count(fn
      {{:login_discovery, kind, _}, kind, _, _} -> kind in [:email_hmac, :email_send]
      _ -> false
    end)
  end

  describe "AC1: keys are namespaced and separate" do
    test "every row written lives in the limiter's own table and starts with :login_discovery" do
      put_config(ip_capacity: 5, ip_refill_per_sec: 0.0001)
      key = rand_key()

      assert Limiter.consume_email(key, :request, 0) == :ok
      assert Limiter.consume_email(key, :send, 0) == :ok

      conn =
        Plug.Test.conn(:post, "/x")
        |> Map.put(:remote_ip, {192, 0, 2, 201})
        |> Limiter.call([])

      refute conn.halted

      rows = :ets.tab2list(@table)
      assert length(rows) >= 5

      for row <- rows do
        assert is_tuple(elem(row, 0))
        assert elem(elem(row, 0), 0) == :login_discovery, "row #{inspect(row)} is not namespaced"
      end

      kinds = for {{:login_discovery, k, _}, _, _, _} <- rows, do: k
      assert [{@global_key, :global, _, _}] = :ets.lookup(@table, @global_key)
      assert Enum.sort(Enum.uniq(kinds)) == [:email_hmac, :email_send, :ip]
      assert Bucket.table() == @table
      refute :ets.info(@table, :id) == :ets.info(@public_table, :id)
    end

    test "the /api/public bucket keeps its own table and its :global / {:ip, ip} key shapes" do
      put_config(ip_capacity: 5, ip_refill_per_sec: 0.0001)
      ip = {198, 51, 100, 201}
      public_global_before = :ets.lookup(@public_table, :global)
      on_exit(fn -> :ets.delete(@public_table, {:ip, ip}) end)

      # login-discovery traffic must leave the public table untouched.
      conn =
        Plug.Test.conn(:post, "/x") |> Map.put(:remote_ip, {192, 0, 2, 202}) |> Limiter.call([])

      refute conn.halted
      assert :ets.lookup(@public_table, :global) == public_global_before
      assert :ets.lookup(@public_table, {:ip, {192, 0, 2, 202}}) == []

      # and the public limiter writes only its pre-existing shapes there.
      public_conn = Plug.Test.conn(:get, "/x") |> Map.put(:remote_ip, ip)
      refute PublicReadRateLimit.call(public_conn, []).halted

      assert [{{:ip, ^ip}, tokens, last_ms}] = :ets.lookup(@public_table, {:ip, ip})
      assert is_float(tokens) and is_integer(last_ms)
      assert [{:global, _, _}] = :ets.lookup(@public_table, :global)

      assert Enum.all?(:ets.tab2list(@public_table), fn {key, _, _} ->
               key == :global or match?({:ip, _}, key)
             end)

      assert :ets.lookup(@table, {:ip, ip}) == []
      assert :ets.lookup(@table, :global) == []
    end
  end

  describe "AC7: bounded state, lossless eviction" do
    test "10x max_email_keys distinct keys never push the email population above the cap" do
      cap = 50
      put_config(max_email_keys: cap, email_capacity: 5, email_refill_per_sec: 0.0001)

      results =
        for i <- 1..(10 * cap) do
          kind = if rem(i, 2) == 0, do: :request, else: :send
          result = Limiter.consume_email(rand_key(), kind, 0)

          if rem(i, cap) == 0 do
            assert Bucket.size(:email) <= cap
            assert email_row_count() <= cap
          end

          result
        end

      assert Enum.count(results, &(&1 == :ok)) == cap
      assert Enum.count(results, &(&1 == :rate_limited)) == 9 * cap
      assert Bucket.size(:email) == cap
      assert email_row_count() == cap
    end

    test "at the cap an existing key is still served by its own bucket; a new key is refused" do
      put_config(max_email_keys: 3, email_capacity: 2, email_refill_per_sec: 0.0001)
      [a, b, c, d] = for _ <- 1..4, do: rand_key()

      assert Limiter.consume_email(a, :request, 0) == :ok
      assert Limiter.consume_email(b, :request, 0) == :ok
      assert Limiter.consume_email(c, :request, 0) == :ok
      assert Limiter.consume_email(d, :request, 0) == :rate_limited
      # existing key a has one token left, then its own bucket refuses.
      assert Limiter.consume_email(a, :request, 0) == :ok
      assert Limiter.consume_email(a, :request, 0) == :rate_limited
      assert Bucket.size(:email) == 3
    end

    test "hot key stays limited while unrelated idle keys are swept (design s7.4 numbers)" do
      put_config(email_capacity: 5, email_refill_per_sec: 1 / 60)
      t0 = 1_000
      hot = {:login_discovery, :email_hmac, "hot"}
      unrelated = for i <- 1..10, do: "unrelated-#{i}"

      for u <- unrelated, do: assert(Limiter.consume_email(u, :request, t0) == :ok)
      for _ <- 1..5, do: assert(Limiter.consume_email("hot", :request, t0) == :ok)
      assert Limiter.consume_email("hot", :request, t0) == :rate_limited
      assert Bucket.size(:email) == 11

      # A sweep with no elapsed time evicts nothing: no row is idle.
      assert Bucket.sweep(t0, :email) == 0
      assert Bucket.size(:email) == 11

      assert Limiter.consume_email("hot", :request, t0 + 30_000) == :rate_limited

      # Unrelated rows are idle by t0+120s (and only they): deleted, hot kept.
      assert Bucket.sweep(t0 + 120_000, :email) == 10
      assert Bucket.size(:email) == 1

      for u <- unrelated do
        assert Bucket.token_count({:login_discovery, :email_hmac, u}, t0 + 120_000) == :absent
      end

      # The hot row was NOT reset to full by the sweep: about 2 tokens refilled,
      # so exactly two admits and then refusal (it cannot be refilled faster).
      assert {:ok, tokens} = Bucket.token_count(hot, t0 + 120_000)
      assert tokens > 1.99 and tokens < 2.1
      assert Limiter.consume_email("hot", :request, t0 + 120_000) == :ok
      assert Limiter.consume_email("hot", :request, t0 + 120_000) == :ok
      assert Limiter.consume_email("hot", :request, t0 + 120_000) == :rate_limited
    end

    test "a non-idle row is never evicted; it first idles at t0+300s and is then a fresh bucket" do
      put_config(email_capacity: 5, email_refill_per_sec: 1 / 60)
      t0 = 5_000
      hot = {:login_discovery, :email_hmac, "hot2"}
      for _ <- 1..5, do: assert(Limiter.consume_email("hot2", :request, t0) == :ok)

      # 299 s: 4_983_433 micro-tokens < 5_000_000 -> still kept.
      assert Bucket.sweep(t0 + 299_000, :all) == 0
      assert {:ok, _} = Bucket.token_count(hot, t0 + 299_000)
      assert Bucket.size(:email) == 1

      # 301 s: 5_016_767 >= 5_000_000 -> idle, deleted.
      assert Bucket.sweep(t0 + 301_000, :all) == 1
      assert Bucket.token_count(hot, t0 + 301_000) == :absent
      assert Bucket.size(:email) == 0

      # A swept key behaves as a brand-new bucket: full capacity again.
      results = for _ <- 1..6, do: Limiter.consume_email("hot2", :request, t0 + 301_000)
      assert results == [:ok, :ok, :ok, :ok, :ok, :rate_limited]
    end

    test "sweep scopes: :email leaves ip rows alone, and :global is never swept" do
      put_config([])
      ip_key = {:login_discovery, :ip, {:v4, {192, 0, 2, 210}}}
      global = {:login_discovery, :global}

      assert Bucket.consume(ip_key, 5, 0.5, 0) == :ok
      assert Bucket.consume(global, 3, 1.0, 0) == :ok
      assert Limiter.consume_email("scope-test", :request, 0) == :ok

      far = 1_000_000_000
      assert Bucket.sweep(far, :email) == 1
      assert {:ok, _} = Bucket.token_count(ip_key, 0)
      assert Bucket.size(:ip) == 1

      assert Bucket.sweep(far, :all) == 1
      assert Bucket.token_count(ip_key, far) == :absent
      assert Bucket.size(:ip) == 0
      assert {:ok, _} = Bucket.token_count(global, far)
    end
  end

  describe "AC9: consume is a compare-and-swap" do
    # Spawns `callers` processes that all block on a barrier, releases them at
    # once, and returns how many of their `fun.()` calls answered :ok. A
    # Task.async_stream start is too staggered to expose a check-then-write race.
    defp barrier_oks(callers, fun) do
      parent = self()

      pids =
        for _ <- 1..callers do
          spawn_link(fn ->
            receive do
              :go -> send(parent, {:result, fun.()})
            end
          end)
        end

      Enum.each(pids, &send(&1, :go))

      Enum.count(1..callers, fn _ ->
        receive do
          {:result, r} -> r == :ok
        end
      end)
    end

    test "barrier-started callers never admit more than capacity on an existing row" do
      capacity = 20

      for round <- 1..300 do
        key = {:login_discovery, :email_hmac, "cas-#{round}"}
        # create the row first so every racing caller takes the replace path.
        assert Bucket.consume(key, capacity, 0.0001, 1_000) == :ok
        oks = barrier_oks(64, fn -> Bucket.consume(key, capacity, 0.0001, 1_000) end)
        assert oks + 1 <= capacity, "round #{round}: #{oks + 1} admitted, capacity #{capacity}"
      end
    end

    test "barrier-started callers never admit more than capacity on the new global key" do
      capacity = 7

      for round <- 1..300 do
        :ets.delete(@table, @global_key)

        oks =
          barrier_oks(64, fn -> Bucket.consume(@global_key, capacity, 0.0001, 1_000) end)

        assert oks <= capacity, "round #{round}: #{oks} admitted, capacity #{capacity}"
        assert oks >= 1
      end
    end

    test "a refusal does not write the row" do
      key = {:login_discovery, :email_hmac, "no-write"}
      assert Bucket.consume(key, 1, 0.0001, 0) == :ok
      before = :ets.lookup(@table, key)
      assert Bucket.consume(key, 1, 0.0001, 10) == :rate_limited
      assert :ets.lookup(@table, key) == before
    end
  end

  describe "AC8 (config half): validate_config!/1" do
    test "accepts the defaults" do
      assert Limiter.validate_config!([]) == :ok
      assert Limiter.validate_config!(Limiter.defaults()) == :ok
    end

    test "the max_email_keys invariant is exact at its boundary" do
      d = Limiter.defaults()

      t_full =
        max(
          d[:email_capacity] / d[:email_refill_per_sec],
          d[:send_capacity] / d[:send_refill_per_sec]
        )

      required =
        2 *
          (d[:global_capacity] +
             ceil(d[:global_refill_per_sec] * (t_full + d[:sweep_interval_ms] / 1000)))

      assert Limiter.validate_config!(max_email_keys: required) == :ok

      assert_raise ArgumentError, ~r/max_email_keys/, fn ->
        Limiter.validate_config!(max_email_keys: required - 1)
      end

      assert_raise ArgumentError, ~r/max_email_keys/, fn ->
        Limiter.validate_config!(max_email_keys: 1_000)
      end
    end

    test "rejects non-positive integers, a too-small max_ip_keys and zero refill" do
      for bad <- [
            [global_capacity: 0],
            [ip_capacity: -1],
            [email_capacity: 1.5],
            [retry_after_seconds: 0],
            [sweep_interval_ms: 0]
          ] do
        assert_raise ArgumentError, fn -> Limiter.validate_config!(bad) end
      end

      assert_raise ArgumentError, ~r/max_ip_keys/, fn ->
        Limiter.validate_config!(max_ip_keys: 5, ip_capacity: 10)
      end

      for bad <- [
            [ip_refill_per_sec: 0],
            [global_refill_per_sec: -1],
            [send_refill_per_sec: 1.0e-7],
            [email_refill_per_sec: "fast"]
          ] do
        assert_raise ArgumentError, fn -> Limiter.validate_config!(bad) end
      end
    end

    test "Bucket.init/1 validates the application env at boot, before creating the table" do
      put_config(max_email_keys: 10)
      assert_raise ArgumentError, ~r/max_email_keys/, fn -> Bucket.init([]) end
    end
  end
end
