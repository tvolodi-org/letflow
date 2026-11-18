defmodule Letflow.LoginDiscovery.DispatchTest do
  @moduledoc """
  REQ-437 (spec `test/specs/REQ-437.md`): the notifier port, `Dispatch` and its
  isolation guarantees (INV-8, INV-4, C-4; design s13, s15.3), observed through
  the real `Letflow.Router` plus direct `Dispatch.submit/3` calls.

  An adapter that raises, exits, returns an error or times out must leave the HTTP
  response byte-unchanged and the request process alive; the `:send` bucket limits
  a second delivery to one address SILENTLY (no second outcome event); the default
  Noop adapter delivers nothing and logs no address or tenant; a refused or failed
  submission is dropped. The double raises/exits WITH THE TYPED ADDRESS in the
  message, so any leak into a log or crash report is visible.

  `async: false` (global limiter table, application env, the real
  `Letflow.LoginDiscovery.TaskSupervisor`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.LoginDiscovery.Dispatch
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.Test.LoginDiscoveryHelpers, as: H
  alias Letflow.Test.LoggerCollector

  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @notifier Letflow.LoginDiscovery.Notifier
  @tiny 0.0001
  @neutral ~s({"result":"accepted"})

  setup_all do
    {:ok, world: H.provision_world!([:a, :b])}
  end

  setup %{world: w} do
    H.setup_limiter!([])
    H.put_mode!(:redirect_single)
    H.put_enabled!(true)
    H.put_env!(@notifier, adapter: Double, timeout_ms: 1_000, max_concurrent: 100)
    Double.reset()
    Double.set_owner(self())
    on_exit(&Double.reset/0)
    H.debug_logging!()
    H.await_idle()
    {:ok, w: w}
  end

  # :timeout blocks the adapter far past the hard timeout: the task is killed and the
  # request never waited for it.
  defp arm(:timeout) do
    H.put_env!(@notifier, adapter: Double, timeout_ms: 150, max_concurrent: 100)
    Double.set_behaviour({:sleep, 5_000})
  end

  defp arm(behaviour), do: Double.set_behaviour(behaviour)

  # An address held by BOTH tenants: Mode B neutral, one delivery of a list of 2.
  defp multi(w) do
    email = H.email()
    H.add_entry!(w.a, email)
    H.add_entry!(w.b, email)
    email
  end

  defp tenants(w), do: [tenant_ref(w.a), tenant_ref(w.b)]
  defp tenant_ref(t), do: %{slug: t.slug, display_name: t.display_name, hostname: nil}

  # ── failure isolation (INV-8) ───────────────────────────────────────────

  for behaviour <- [:raise, :exit, :error, :timeout] do
    test "adapter #{behaviour}: response unchanged, request process alive, one fixed log line, no address in any log",
         %{w: w} do
      baseline_email = multi(w)
      baseline = H.fp(H.post_email(baseline_email))
      H.await_idle()
      assert baseline.status == 202 and baseline.body == @neutral
      _ = H.deliveries()

      arm(unquote(behaviour))

      email = multi(w)

      {_, entries} =
        LoggerCollector.capture(
          fn ->
            send(self(), {:conn, H.post_email(email)})
            H.await_idle()
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      assert_received {:conn, conn}
      assert H.fp(conn) == baseline
      assert Process.alive?(self())

      # the adapter WAS invoked (the failure is real), with the stripped tenant maps
      assert [{^email, tenants}] = H.deliveries()
      assert tenants == tenants(w)

      assert log =~ "login discovery: notifier delivery did not complete"
      refute log =~ email
      refute log =~ w.a.slug
      refute log =~ w.a.display_name
      refute log =~ w.b.slug
      refute log =~ "notifier boom"
      refute log =~ "notifier_boom"
    end
  end

  test "an adapter that succeeds leaves no failure line in the log", %{w: w} do
    email = multi(w)

    {_, entries} =
      LoggerCollector.capture(
        fn ->
          H.post_email(email)
          H.await_idle()
        end,
        attribute_to: self()
      )

    log = LoggerCollector.text(entries)

    assert [{^email, _}] = H.deliveries()
    refute log =~ "did not complete"
    refute log =~ email
  end

  test "a notifier that sleeps 2 s does NOT delay the response: the request returns while the task is still running",
       %{w: w} do
    email = multi(w)
    baseline = H.fp(H.post_email(multi(w)))
    H.await_idle()

    Double.set_behaviour({:sleep, 2_000})
    {micros, conn} = :timer.tc(fn -> H.post_email(email) end)

    # structural proof: the delivery task is STILL RUNNING under the supervisor when the
    # response is already built (the handler never awaited it)
    assert Task.Supervisor.children(@supervisor) != []
    assert H.fp(conn) == baseline
    # coarse wall-clock backstop, 2x margin below the sleep
    assert micros < 1_000_000
    H.await_idle()
  end

  # ── the :send bucket (D6) ───────────────────────────────────────────────

  describe "per-address :send bucket" do
    test "a second delivery to the same address inside the interval is NOT made; the responses stay identical and no extra outcome event is emitted",
         %{w: w} do
      H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
      email = multi(w)

      {{first, second}, outcomes} =
        H.capture_outcomes(fn ->
          first = H.post_email(email)
          H.await_idle()
          second = H.post_email(email)
          H.await_idle()
          {first, second}
        end)

      assert H.fp(first) == H.fp(second)
      assert first.status == 202

      # exactly ONE delivery for the two requests
      assert [{^email, _tenants}] = H.deliveries()

      # one :accepted per request; the refused :send adds NO second event
      assert outcomes == [
               {%{count: 1}, %{outcome: :accepted}},
               {%{count: 1}, %{outcome: :accepted}}
             ]
    end

    test "the bucket is per ADDRESS (normalised): a case/whitespace variant is the same address, a different address still delivers",
         %{w: w} do
      H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
      email = multi(w)
      other = multi(w)

      H.post_email(email)
      H.await_idle()
      H.post_email("  " <> String.upcase(email) <> " ")
      H.await_idle()
      H.post_email(other)
      H.await_idle()

      recipients = H.deliveries() |> Enum.map(&elem(&1, 0))
      assert recipients == [email, other]
    end

    test "a refused :send never turns a later request into a 429",
         %{w: w} do
      H.setup_limiter!(send_capacity: 1, send_refill_per_sec: @tiny)
      email = multi(w)

      statuses =
        for _ <- 1..3 do
          conn = H.post_email(email)
          H.await_idle()
          conn.status
        end

      assert statuses == [202, 202, 202]
    end
  end

  # ── the default (Noop) adapter ──────────────────────────────────────────

  describe "default adapter" do
    test "Noop returns :ok and its log output carries no address, slug or display name" do
      tenants = [%{slug: "zorblax-slug", display_name: "Zorblax Display"}]

      {_, entries} =
        LoggerCollector.capture(
          fn -> assert Noop.deliver_tenant_list("someone@zorblax.test", tenants) == :ok end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      refute log =~ "someone@zorblax.test"
      refute log =~ "zorblax"
      refute log =~ "Zorblax"
    end

    test "with the Noop adapter configured nothing is delivered, the response is the neutral 202 and no email or tenant name is logged",
         %{w: w} do
      H.put_env!(@notifier, adapter: Noop, timeout_ms: 1_000, max_concurrent: 100)
      email = multi(w)

      {_, entries} =
        LoggerCollector.capture(
          fn ->
            send(self(), {:conn, H.post_email(email)})
            H.await_idle()
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      assert_received {:conn, conn}
      assert conn.status == 202 and conn.resp_body == @neutral
      assert H.deliveries() == []
      refute log =~ email
      refute log =~ w.a.slug
      refute log =~ w.a.display_name
      refute log =~ w.b.display_name
    end

    test "Dispatch.adapter/0: the Noop adapter when the key or the adapter is missing; the configured module otherwise" do
      H.delete_env!(@notifier)
      assert Dispatch.adapter() == Noop

      H.put_env!(@notifier, adapter: nil)
      assert Dispatch.adapter() == Noop

      H.put_env!(@notifier, adapter: Double)
      assert Dispatch.adapter() == Double
    end

    test "Dispatch limits: defaults when unset (5 s timeout, 100 concurrent), configured positive integers otherwise" do
      H.delete_env!(@notifier)
      assert Dispatch.timeout_ms() == 5_000
      assert Dispatch.max_concurrent() == 100

      H.put_env!(@notifier, timeout_ms: 250, max_concurrent: 7)
      assert Dispatch.timeout_ms() == 250
      assert Dispatch.max_concurrent() == 7

      H.put_env!(@notifier, timeout_ms: 0, max_concurrent: -1)
      assert Dispatch.timeout_ms() == 5_000
      assert Dispatch.max_concurrent() == 100
    end
  end

  # ── submit/3 contract ───────────────────────────────────────────────────

  describe "Dispatch.submit/3" do
    test "always returns :ok without waiting, for every input class", %{w: w} do
      ok = {:ok, tenants(w)}

      for {recipient, result} <- [
            {"a@x.test", ok},
            {"a@x.test", {:ok, []}},
            {"a@x.test", {:error, :lookup_failed}},
            {nil, ok},
            {nil, {:ok, []}}
          ],
          mode <- [:redirect_single, :uniform_plus_email] do
        assert Dispatch.submit(recipient, mode, result) == :ok
      end

      H.await_idle()
    end

    test "delivers one list for a non-empty neutral result, nothing for a disclosed single, nothing without a recipient",
         %{w: w} do
      two = Enum.map([w.a, w.b], &Map.put(tenant_ref(&1), :disclose, true))
      [only | _] = two

      assert Dispatch.submit("two@x.test", :redirect_single, {:ok, two}) == :ok
      H.await_idle()
      assert [{"two@x.test", delivered}] = H.deliveries()
      # `disclose` is stripped before the notifier sees the tenant maps
      assert Enum.all?(
               delivered,
               &(&1 |> Map.keys() |> Enum.sort() == [:display_name, :hostname, :slug])
             )

      # a disclosed single is answered by the 200, not by mail
      assert Dispatch.submit("one@x.test", :redirect_single, {:ok, [only]}) == :ok
      # no recipient (malformed input)
      assert Dispatch.submit(nil, :redirect_single, {:ok, two}) == :ok
      # lookup failure / no match
      assert Dispatch.submit("f@x.test", :redirect_single, {:error, :lookup_failed}) == :ok
      assert Dispatch.submit("n@x.test", :redirect_single, {:ok, []}) == :ok
      H.await_idle()
      assert H.deliveries() == []
    end

    test "at the supervisor's max_children cap a submission is DROPPED silently (still :ok, nothing delivered), and the cap is 2 x max_concurrent",
         %{w: w} do
      cap = 2 * Dispatch.max_concurrent()

      started =
        Stream.repeatedly(fn ->
          Task.Supervisor.start_child(@supervisor, fn -> Process.sleep(:infinity) end)
        end)
        |> Enum.take_while(&match?({:ok, _}, &1))

      on_exit(fn ->
        for {:ok, pid} <- started, do: Task.Supervisor.terminate_child(@supervisor, pid)
      end)

      assert length(started) == cap

      assert {:error, :max_children} =
               Task.Supervisor.start_child(@supervisor, fn -> :ok end)

      ok = {:ok, tenants(w)}
      assert Dispatch.submit("capped@x.test", :redirect_single, ok) == :ok

      for {:ok, pid} <- started, do: Task.Supervisor.terminate_child(@supervisor, pid)
      H.await_idle()
      assert H.deliveries() == []
    end
  end
end
