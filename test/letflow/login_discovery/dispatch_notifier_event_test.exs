defmodule Letflow.LoginDiscovery.DispatchNotifierEventTest do
  @moduledoc """
  REQ-441 AC4 (spec `test/specs/REQ-441.md`): failure handling and the
  `[:letflow, :login_discovery, :notifier]` event emitted by
  `Letflow.LoginDiscovery.Dispatch`.

    * (a) a FAILED attempt still consumes the per-address `:send` bucket: the second
      attempt inside the interval is `:skipped` and the relay is NOT contacted again;
    * (b) exactly ONE event per attempt, measurement `%{count: 1}`, metadata EXACTLY
      `%{outcome: _}` (`==` on the map, so no extra key), with the outcome mapping of
      design s4.2; nothing-to-deliver shapes emit no event; a refused INNER task start
      after the bucket was spent is a `:failed` event plus the fixed log line (F5);
    * (c) a transient (4xx) rejection and a dropped connection are each attempted
      exactly once (no library-level retry);
    * (d) grep guard: no retry loop or `Process.send_after` family on the delivery path;
    * (e) F4 guard: nothing in `lib/` attaches a handler to a login-discovery event;
    * (f) F9 capacity: the limiter burst bounds the messages the relay receives, and the
      connections that ever reach the relay never exceed `max_concurrent`.

  `async: false` (global limiter table, application env, the notifier supervisor, the
  sink).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.LoginDiscovery.Dispatch
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.Test.LoggerCollector
  alias Letflow.Test.LoginDiscoveryHelpers, as: H
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @notifier Letflow.LoginDiscovery.Notifier
  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @tiny 0.0001
  @wait 15_000
  @login_discovery_dir "lib/letflow/login_discovery"

  setup_all do
    {:ok, world: H.provision_world!([:a, :b])}
  end

  setup do
    H.setup_limiter!([])
    H.put_mode!(:redirect_single)
    H.put_enabled!(true)
    H.put_env!(@notifier, adapter: Double, timeout_ms: 1_000, max_concurrent: 100)
    Double.reset()
    Double.set_owner(self())
    on_exit(&Double.reset/0)
    H.debug_logging!()
    H.await_idle()
    :ok
  end

  defp recipient, do: H.email()

  # `Dispatch.submit/3` is called exactly as the router calls it for a multi-tenant match.
  defp submit(recipient), do: S.submit_multi(recipient, S.tenants())

  defp assert_event(events, outcome) do
    assert {%{count: 1} = measurements, metadata} = S.next_event(events, @wait),
           "no notifier event arrived (expected #{outcome})"

    assert measurements == %{count: 1}
    # `==` on the whole map: no address, tenant, slug, reason or any other key
    assert metadata == %{outcome: outcome}
  end

  # ── (a) a failed attempt consumes the :send bucket ──────────────────────

  describe "(a) the per-address :send bucket is consumed by a failed attempt" do
    for {label, script} <- [
          rejected: {:refuse_rcpt, "REJECTEDMARKER"},
          temporary_failure: {:tempfail_rcpt, "LATERMARKER"},
          connection_refused: :refuse_connection,
          dropped: :drop_after_greeting
        ] do
      test "after #{label} the second attempt in the interval is :skipped and never reaches the relay" do
        H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
        sink = S.start_sink!(unquote(Macro.escape(script)))
        S.configure_smtp!(sink, [])
        events = S.attach_notifier!()
        to = recipient()

        assert submit(to) == :ok
        assert_event(events, :failed)
        H.await_idle()

        connections_after_first = SmtpSink.connections(sink)

        expected_first = if unquote(Macro.escape(script)) == :refuse_connection, do: 0, else: 1
        assert connections_after_first == expected_first

        assert submit(to) == :ok
        assert_event(events, :skipped)
        H.await_idle()

        # not retried: not one new connection, no further event
        assert SmtpSink.connections(sink) == connections_after_first
        assert S.drain_events(events) == []
        assert SmtpSink.messages(sink) == []
      end
    end

    test "a successful attempt consumes it as well: the second attempt is :skipped, one message" do
      H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])
      events = S.attach_notifier!()
      to = recipient()

      submit(to)
      assert_event(events, :delivered)
      submit(to)
      assert_event(events, :skipped)
      H.await_idle()

      assert [%{rcpts: [^to]}] = SmtpSink.messages(sink)
      assert SmtpSink.connections(sink) == 1
    end

    test "a different address is not affected by another address's spent bucket" do
      H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
      sink = S.start_sink!({:refuse_rcpt, "REJECTEDMARKER"})
      S.configure_smtp!(sink, [])
      events = S.attach_notifier!()

      submit(recipient())
      assert_event(events, :failed)
      submit(recipient())
      assert_event(events, :failed)
      H.await_idle()

      assert SmtpSink.connections(sink) == 2
    end
  end

  # ── (b) the event ───────────────────────────────────────────────────────

  describe "(b) one event per attempt, metadata exactly %{outcome: _}" do
    for {label, behaviour, outcome, timeout} <- [
          {:adapter_ok, :ok, :delivered, 1_000},
          {:adapter_error, :error, :failed, 1_000},
          {:adapter_raise, :raise, :failed, 1_000},
          {:adapter_exit, :exit, :failed, 1_000},
          {:adapter_timeout, {:sleep, 5_000}, :failed, 200}
        ] do
      test "#{label} -> #{outcome}, exactly one event, fixed log line only when failed" do
        H.put_env!(@notifier, adapter: Double, timeout_ms: unquote(timeout), max_concurrent: 100)
        Double.set_behaviour(unquote(Macro.escape(behaviour)))
        events = S.attach_notifier!()
        to = recipient()

        {_, entries} =
          LoggerCollector.capture(
            fn ->
              submit(to)
              assert_event(events, unquote(outcome))
              H.await_idle()
            end,
            attribute_to: self()
          )

        log = LoggerCollector.text(entries)

        assert S.drain_events(events) == []

        if unquote(outcome) == :failed do
          assert log =~ "login discovery: notifier delivery did not complete"
        else
          refute log =~ "did not complete"
        end
      end
    end

    test "the :send bucket refusing -> :skipped, the adapter is not called" do
      H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
      events = S.attach_notifier!()
      to = recipient()

      submit(to)
      assert_event(events, :delivered)
      assert [{^to, _}] = H.deliveries()

      submit(to)
      assert_event(events, :skipped)
      H.await_idle()
      assert H.deliveries() == []
      assert S.drain_events(events) == []
    end

    test "the Noop adapter delivers nothing, so it is :skipped (never :delivered)" do
      H.put_env!(@notifier, adapter: Noop, timeout_ms: 1_000, max_concurrent: 100)
      events = S.attach_notifier!()

      submit(recipient())
      assert_event(events, :skipped)
      H.await_idle()
      assert S.drain_events(events) == []
    end

    test "the event is emitted even when the fixed warning is logged, and submit/3 returns :ok at once" do
      Double.set_behaviour(:raise)
      events = S.attach_notifier!()

      {micros, result} = :timer.tc(fn -> submit(recipient()) end)
      assert result == :ok
      # coarse backstop only: the structural proof is the asynchronous event below
      assert micros < 1_000_000

      assert_event(events, :failed)
    end

    test "nothing-to-deliver shapes emit NO notifier event and never call the adapter",
         %{world: w} do
      events = S.attach_notifier!()
      [a, b] = S.tenants()
      only = %{slug: w.a.slug, display_name: w.a.display_name, disclose: true}

      # a disclosed single match is answered by the 200, not by mail
      assert Dispatch.submit("one@example.test", :redirect_single, {:ok, [only]}) == :ok
      # no match, lookup failure, no recipient, a non-binary recipient
      assert Dispatch.submit("none@example.test", :redirect_single, {:ok, []}) == :ok

      assert Dispatch.submit("fail@example.test", :redirect_single, {:error, :lookup_failed}) ==
               :ok

      assert Dispatch.submit(nil, :redirect_single, {:ok, [a, b]}) == :ok
      assert Dispatch.submit(12_345, :redirect_single, {:ok, [a, b]}) == :ok
      assert Dispatch.submit("x@example.test", :redirect_single, :garbage) == :ok

      H.await_idle()
      # a bounded negative wait: nothing may arrive
      assert S.next_event(events, 300) == :timeout
      assert H.deliveries() == []
    end

    test "F5: a refused INNER task start (supervisor saturated after the bucket was spent) is a :failed event and the fixed line" do
      events = S.attach_notifier!()
      cap = 2 * Dispatch.max_concurrent()

      # leave exactly ONE free slot: the outer start_child gets it, the inner async_nolink
      # is refused after consume_email_silent already spent the token
      sleepers =
        for _ <- 1..(cap - 1) do
          {:ok, pid} =
            Task.Supervisor.start_child(@supervisor, fn -> Process.sleep(:infinity) end)

          pid
        end

      on_exit(fn ->
        for pid <- sleepers, do: Task.Supervisor.terminate_child(@supervisor, pid)
      end)

      log =
        capture_log([level: :debug], fn ->
          assert submit(recipient()) == :ok
          assert_event(events, :failed)
          Process.sleep(50)
        end)

      assert log =~ "login discovery: notifier delivery did not complete"
      assert S.drain_events(events) == []
      assert H.deliveries() == []

      for pid <- sleepers, do: Task.Supervisor.terminate_child(@supervisor, pid)
      H.await_idle()
    end
  end

  # ── (c) no library-level retry ──────────────────────────────────────────

  describe "(c) no retry of a transient failure or a dropped connection" do
    for {label, script} <- [
          tempfail_4xx: {:tempfail_rcpt, "LATERMARKER"},
          dropped_after_greeting: :drop_after_greeting,
          rejected_5xx: {:refuse_rcpt, "REJECTEDMARKER"}
        ] do
      test "#{label}: exactly one connection, still one after a wait longer than any retry" do
        sink = S.start_sink!(unquote(Macro.escape(script)))
        S.configure_smtp!(sink, [])
        events = S.attach_notifier!()

        submit(recipient())
        assert_event(events, :failed)
        H.await_idle()
        assert SmtpSink.connections(sink) == 1

        # bounded NEGATIVE wait: a retry (immediate or backed-off) would show up here
        Process.sleep(1_500)
        assert SmtpSink.connections(sink) == 1
        assert S.drain_events(events) == []
        assert SmtpSink.messages(sink) == []
      end
    end
  end

  # ── (d) grep guard: no retry process / timer on the delivery path ───────

  describe "(d) grep guard: no retry loop and no timer on the delivery path" do
    @timers ~w(Process.send_after :timer.send_after :timer.apply_after :timer.send_interval :timer.apply_interval Process.send_interval)

    test "no timer-based re-send anywhere under lib/letflow/login_discovery/ or login_discovery.ex" do
      files = delivery_files()
      assert length(files) >= 7
      assert Enum.any?(files, &String.ends_with?(&1, "smtp/transport.ex"))

      for path <- files, timer <- @timers do
        refute code(path) =~ timer, "#{path} uses #{timer}"
      end
    end

    test "'retry'/'retries' appears nowhere in code except the single `retries: 0` in smtp/transport.ex" do
      for path <- delivery_files() do
        hits =
          path
          |> code()
          |> String.split("\n")
          |> Enum.filter(&(&1 =~ ~r/retr(y|ies)/i))
          |> Enum.map(&String.trim/1)

        if String.ends_with?(path, "smtp/transport.ex") do
          assert hits == ["retries: 0,"], "#{path}: #{inspect(hits)}"
        else
          assert hits == [], "#{path}: #{inspect(hits)}"
        end
      end
    end

    test "no recursive re-submission: Dispatch.submit/3 is called from the router only" do
      callers =
        for path <- Path.wildcard("lib/**/*.ex"),
            code(path) =~ ~r/Dispatch\.submit\(/,
            do: path

      assert callers == ["lib/letflow/routers/login_discovery.ex"]
    end
  end

  # ── (e) F4 guard: the event stays inert ─────────────────────────────────

  describe "(e) F4 guard: no handler is attached to a login-discovery event" do
    test "no :telemetry.attach/attach_many in lib/ mentions a login-discovery event" do
      attachers =
        for path <- Path.wildcard("lib/**/*.ex"), code(path) =~ ~r/:telemetry\.attach/, do: path

      # the guard is not vacuous: the metrics registry is a real attacher
      assert "lib/letflow/metrics/registry.ex" in attachers

      for path <- attachers do
        refute code(path) =~ ":login_discovery", "#{path} attaches near a login_discovery event"
        refute code(path) =~ "login_discovery", "#{path} mentions login_discovery"
      end
    end

    test "the registry attaches exactly its five events, none a login-discovery event" do
      src = code("lib/letflow/metrics/registry.ex")

      [events] =
        Regex.run(~r/:telemetry\.attach_many\(\s*@handler_id,\s*(\[.*?\n\s*\]),/s, src,
          capture: :all_but_first
        )

      {parsed, _} = Code.eval_string(events)

      assert parsed == [
               [:letflow, :task, :completed],
               [:letflow, :event_store, :append, :stop],
               [:letflow, :repo, :query],
               [:letflow, :http, :request],
               # REQ-497 1b metrics family 7. The guard stays: no handler on a login-discovery event.
               [:letflow, :scope, :shadow, :would_deny]
             ]
    end

    test "at runtime no handler exists on the notifier event (nor the outcome event)" do
      assert :telemetry.list_handlers([:letflow, :login_discovery, :notifier]) == []
      assert :telemetry.list_handlers([:letflow, :login_discovery, :outcome]) == []
      assert :telemetry.list_handlers([:letflow, :login_discovery]) == []
    end

    test "the emitted event is produced only by Dispatch, never by an adapter" do
      emitters =
        for path <- Path.wildcard("lib/**/*.ex"),
            code(path) =~ "[:letflow, :login_discovery, :notifier]",
            do: path

      assert emitters == ["lib/letflow/login_discovery/dispatch.ex"]
    end
  end

  # ── (f) F9 capacity ─────────────────────────────────────────────────────

  describe "(f) F9 capacity bounds" do
    test "N distinct addresses at the limiter burst reach the relay at most `burst` times",
         %{world: w} do
      burst = 5
      H.setup_limiter!(global_capacity: burst, global_refill_per_sec: @tiny)
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])
      events = S.attach_notifier!()

      statuses =
        for _ <- 1..(burst * 2 + 2) do
          email = H.email()
          H.add_entry!(w.a, email)
          H.add_entry!(w.b, email)
          H.post_email(email).status
        end

      for _ <- 1..burst, do: assert({_, %{outcome: :delivered}} = S.next_event(events, @wait))
      H.await_idle()

      accepted = Enum.count(statuses, &(&1 == 202))
      assert accepted == burst
      assert Enum.count(statuses, &(&1 == 429)) == length(statuses) - burst

      assert length(SmtpSink.messages(sink)) == burst
      assert SmtpSink.connections(sink) == burst
      assert S.drain_events(events) == []
    end

    test "2 * max_concurrent + 1 simultaneous submits never put more than max_concurrent connections on the relay" do
      max_concurrent = Dispatch.max_concurrent()
      sink = S.start_sink!(:hang)
      S.configure_smtp!(sink, timeout_ms: 2_000, socket_timeout_ms: 500)
      events = S.attach_notifier!()

      # one attempt first: proves the path is live and a connection really reaches the relay
      submit(recipient())
      assert S.wait_until(fn -> SmtpSink.open_connections(sink) == 1 end)

      # (the capture keeps the ~200 expected "did not complete" warnings out of the test output)
      capture_log(fn ->
        for _ <- 1..(2 * max_concurrent), do: submit(recipient())

        # let every task end (hard timeout) and the relay see every close
        assert S.wait_until(fn -> Task.Supervisor.children(@supervisor) == [] end, 300)
        assert S.wait_until(fn -> SmtpSink.open_connections(sink) == 0 end)
      end)

      peak = SmtpSink.peak_open_connections(sink)
      assert peak >= 1
      assert peak <= max_concurrent, "relay saw #{peak} simultaneous connections"
      assert SmtpSink.connections(sink) <= 2 * max_concurrent + 1

      # every attempt that started ended as exactly one event
      assert Enum.all?(S.drain_events(events), &match?({%{count: 1}, %{outcome: :failed}}, &1))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp delivery_files do
    Path.wildcard(@login_discovery_dir <> "/**/*.ex") ++ ["lib/letflow/login_discovery.ex"]
  end

  # Source without heredoc docs and comment lines (so prose cannot trip a code guard).
  defp code(path) do
    path
    |> File.read!()
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end
end
