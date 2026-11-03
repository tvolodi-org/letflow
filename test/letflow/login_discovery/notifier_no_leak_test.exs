defmodule Letflow.LoginDiscovery.NotifierNoLeakTest do
  @moduledoc """
  REQ-441 AC5 (spec `test/specs/REQ-441.md`; design s6.2 AC5 row, s13 C-4 form): NO LEAK.

  For the success case and EVERY failure case, the whole ATTRIBUTED log output contains none of:
  the typed address (any case), a tenant slug or display name, the SMTP reply text
  (`SINKREPLYMARKER`), the compile-time-built username and password markers, or any exception
  message text. The typed address is deliberately placed in the exception / exit reason of the
  raising double, so a leak would be visible.

  The sink is a synchronous `:logger` handler (`Letflow.Test.LoggerCollector`) attached at all
  levels that records the raw event terms (so a `:proc_lib` crash report that bypasses the
  Logger translator would still be seen), restricted to events attributable to this test: its
  own process, its `$callers` / `$ancestors`, and the notifier TaskSupervisor's own reports.

  ATTRIBUTION NARROWING (ISS-1038, decided deliberately): events from processes NOT linked to
  the test -- e.g. `:ssl` connection helpers or `gen_smtp` internals that were not started
  through the test's call chain -- are not observed, so the unique-marker leak scan covers
  attributed events only. A global (unattributed) scan was rejected: it is exactly the
  hazard class being removed (another test's events making this one flake). Partial
  mitigation: the M2b no-survivors check below proves the call leaves no process behind that
  could log later.

  Why not `capture_log`: it is a GLOBAL capture, so under concurrent tests it also picked up
  an error-level "alert delivery exhausted" event logged by another test's alert deliverer
  (ISS-1038 / Q-1039, a flake in `no leak: untrusted_implicit`). The attributed handler
  cannot see such an event (proved by the probe test and by
  `test/letflow/test_support/logger_collector_test.exs`).

  Non-vacuity: the sink DECODES the AUTH exchange, and the success case asserts the
  markers really were presented to the server; a failure case asserts the one fixed
  warning line is present; a probe test proves the sink is live and attributes correctly.

  M2b: after the brutal-kill paths and the forced library failures, no process started by
  the call survives (bounded wait) and the sink's `open_connections/1` is 0.

  `async: false` (application env, OS env, the notifier supervisor, the sink, the
  global logger).
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  require Logger

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.Test.LoggerCollector
  alias Letflow.Test.LoginDiscoveryHelpers, as: H
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @notifier Letflow.LoginDiscovery.Notifier
  @typed "Typed.Leak+Probe@Example.org"
  @slug "leakslug-zq7x"
  @display "LeakDisplay Zq7x Ltd"
  @reply_marker "SINKREPLYMARKER"
  @fixed_line "login discovery: notifier delivery did not complete"
  @wait 15_000

  @cases ~w(success rejected_recipient connection_refused untrusted_starttls untrusted_implicit
            hang slow_drip invalid_utf8_display_name double_raise double_exit
            forced_garbage_ca forced_bad_port forced_negative_timeout forced_bad_host)a

  # cases ended by the hard timeout (brutal_kill) or a forced library-path failure
  @process_checked ~w(hang slow_drip forced_garbage_ca forced_bad_port forced_negative_timeout
                      forced_bad_host)a

  setup do
    H.setup_limiter!([])
    H.debug_logging!()
    H.await_idle()
    :ok
  end

  # ── scenario preparation ────────────────────────────────────────────────

  defp tenants, do: [%{slug: @slug, display_name: @display, disclose: true}, hd(S.tenants())]

  defp smtp(script, opts, outcome) do
    sink = S.start_sink!(script)

    opts =
      case sink.ca_der do
        nil -> opts
        ca -> Keyword.put_new(opts, :tls_cacerts, [ca])
      end

    S.configure_smtp!(sink, opts)
    %{sink: sink, tenants: tenants(), outcome: outcome}
  end

  defp prepare(:success), do: smtp(:accept, [], :delivered)
  defp prepare(:rejected_recipient), do: smtp({:refuse_rcpt, @reply_marker}, [], :failed)
  defp prepare(:connection_refused), do: smtp(:refuse_connection, [], :failed)

  defp prepare(:untrusted_starttls),
    do: smtp({:starttls, :untrusted}, [host: "localhost", tls: :starttls], :failed)

  defp prepare(:untrusted_implicit),
    do: smtp({:implicit_tls, :untrusted}, [host: "localhost", tls: :tls], :failed)

  defp prepare(:hang), do: smtp(:hang, [timeout_ms: 1_500, socket_timeout_ms: 500], :failed)

  defp prepare(:slow_drip),
    do: smtp(:slow_drip, [timeout_ms: 1_500, socket_timeout_ms: 500], :failed)

  # the encoder error path: a display name that is not valid UTF-8
  defp prepare(:invalid_utf8_display_name) do
    env = smtp(:accept, [], :failed)
    %{env | tenants: [%{slug: @slug, display_name: <<0xFF, 0xFE, @display::binary>>}]}
  end

  # the raising double carries the typed address in its message / exit reason
  defp prepare(:double_raise), do: double(:raise)
  defp prepare(:double_exit), do: double(:exit)

  # forced failure INSIDE the library path (the adapter's own validation passes)
  defp prepare(:forced_garbage_ca) do
    smtp(
      {:starttls, :trusted},
      [host: "localhost", tls: :starttls, tls_cacerts: [<<1, 2, 3>>]],
      :failed
    )
  end

  defp prepare(:forced_bad_port) do
    env = smtp(:accept, [], :failed)
    S.put_app_env!(Smtp, port: 99_999)
    env
  end

  defp prepare(:forced_negative_timeout) do
    env = smtp(:accept, [], :failed)
    S.put_app_env!(Smtp, socket_timeout_ms: -5)
    env
  end

  defp prepare(:forced_bad_host) do
    env = smtp(:accept, [], :failed)
    S.put_app_env!(Smtp, host: "not a host name!!")
    env
  end

  defp double(behaviour) do
    H.put_env!(@notifier, adapter: Double, timeout_ms: 1_000, max_concurrent: 100)
    Double.reset()
    Double.set_behaviour(behaviour)
    ExUnit.Callbacks.on_exit(&Double.reset/0)
    %{sink: nil, tenants: tenants(), outcome: :failed}
  end

  # ── observation ─────────────────────────────────────────────────────────

  # Runs `fun` under the all-levels, synchronous, ATTRIBUTED :logger handler. Returns
  # `{log_text, entries}`: the entries attributable to this test and their joined text.
  defp observe(fun) do
    collector = attach_collector()
    events = S.attach_notifier!()

    try do
      fun.(events)
      H.await_idle()
      Process.sleep(100)
      LoggerCollector.assert_alive!(collector)
    after
      LoggerCollector.detach(collector)
    end

    entries = LoggerCollector.collected(collector)
    {Enum.map_join(entries, "\n", & &1.text), entries}
  end

  # The TaskSupervisor itself emits the child-terminated report on a brutal kill, so its
  # own events are attributed too. `also_from` is safe only because every other test touching
  # LoginDiscovery.TaskSupervisor is async: false (nothing concurrent can emit from it).
  defp attach_collector do
    LoggerCollector.attach!(
      attribute_to: self(),
      sasl: true,
      raw: true,
      also_from: [Letflow.LoginDiscovery.TaskSupervisor]
    )
  end

  defp run_case(name) do
    env = prepare(name)
    before = MapSet.new(Process.list())

    {log, entries} =
      observe(fn events ->
        assert S.submit_multi(@typed, env.tenants) == :ok
        assert {%{count: 1}, %{outcome: outcome}} = S.next_event(events, @wait)
        assert outcome == env.outcome, "#{name}: expected #{env.outcome}, got #{outcome}"
      end)

    if env.sink do
      assert S.wait_until(fn -> SmtpSink.open_connections(env.sink) == 0 end),
             "#{name}: the relay still sees an open connection"
    end

    if name in @process_checked, do: assert_no_survivors(name, before, env.sink)
    {name, env, log, entries}
  end

  # Every process the call started is gone within a bounded wait (the sink's own
  # processes are excluded).
  defp assert_no_survivors(name, before, sink) do
    survivors = fn ->
      for pid <- Process.list(),
          not MapSet.member?(before, pid),
          pid != self(),
          pid != sink.pid,
          pid != sink.acceptor,
          info = Process.info(pid, [:registered_name, :current_function, :initial_call]),
          info != nil,
          not logger_machinery?(info),
          do: {pid, info}
    end

    assert S.wait_until(fn -> survivors.() == [] end, 100),
           "#{name}: surviving process(es): #{inspect(survivors.())}"
  end

  # Named OTP singletons that are started lazily and live for the VM's lifetime: the logger's
  # own handler processes (restarted by Logger.configure) and OTP ssl's
  # registered helpers (e.g. `:ssl_unknown_listener`, created on the first handshake that
  # meets an undecodable CA). A per-call WORKER leaked by the SMTP call is not one of these.
  defp logger_machinery?(info) do
    {m, _f, _a} = info[:current_function]
    name = info[:registered_name]

    m in [:logger_std_h, :logger_h_common, :logger_proxy, :logger_olp] or
      (is_atom(name) and String.starts_with?(Atom.to_string(name), ["logger", "ssl_"]))
  end

  defp forbidden do
    [
      @typed,
      String.downcase(@typed),
      String.upcase(@typed),
      "Typed.Leak",
      "typed.leak",
      @slug,
      @display,
      "LeakDisplay",
      "Zq7x",
      @reply_marker,
      S.user(),
      S.pass(),
      "notifier boom",
      "notifier_boom",
      # the other tenant of the list
      "acme-co",
      "Acme Corp"
    ]
  end

  defp assert_clean(name, log, entries) do
    everything = log <> "\n" <> Enum.map_join(entries, "\n", & &1.text)

    for secret <- forbidden() do
      refute everything =~ secret, "#{name}: log output contains #{inspect(secret)}"
    end
  end

  # ── the tests ───────────────────────────────────────────────────────────

  test "the sink is live and attributing: own and child lines arrive, unrelated ones do not" do
    {:ok, sup} = Task.Supervisor.start_link()

    {log, entries} =
      observe(fn _events ->
        Logger.error("PROBE-REQ441-LINE")

        Task.Supervisor.async_nolink(sup, fn -> Logger.error("PROBE-REQ441-CHILD") end)
        |> Task.await()

        parent = self()

        {pid, ref} =
          spawn_monitor(fn ->
            Logger.error("alert delivery exhausted unrelated")
            send(parent, :unrelated_logged)
          end)

        assert_receive :unrelated_logged, 5_000
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      end)

    assert Enum.any?(entries, &(&1.text =~ "PROBE-REQ441-LINE" and &1.level == :error))
    assert log =~ "PROBE-REQ441-CHILD"
    refute log =~ "alert delivery exhausted unrelated"
  end

  test "positive control: a proc_lib crash that carries the password IS visible to the sink" do
    pass = S.pass()

    {log, entries} =
      observe(fn _events ->
        {pid, ref} = :proc_lib.spawn_opt(fn -> exit({:crashed_with, pass}) end, [:monitor])
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end)

    assert Enum.any?(entries, &(&1.level == :error and &1.text =~ pass)),
           "the all-levels handler would not have seen a crash report leaking the password"

    assert log =~ pass
  end

  for name <- @cases do
    test "no leak: #{name}" do
      {name, env, log, entries} = run_case(unquote(name))
      assert_clean(name, log, entries)

      if env.outcome == :failed do
        # non-vacuous: the failure really was logged, as the one fixed line
        assert log =~ @fixed_line
        assert Enum.any?(entries, &(&1.text =~ @fixed_line))
      end

      # No crash report of any kind, at any level (SASL-domain reports included, see
      # LoggerCollector). The ONE permitted error-level event is the supervisor's
      # child-terminated report for the hard-timeout kill (hang, slow_drip), whose
      # `Start Call` carries no arguments (`Task.Supervised.start_link/?`); it is a SASL
      # report the default Logger configuration drops anyway.
      errors = Enum.filter(entries, &(&1.level in [:error, :critical, :alert, :emergency]))

      killed_report? = fn entry ->
        entry.text =~ "of Supervisor Letflow.LoginDiscovery.TaskSupervisor terminated" and
          entry.text =~ "** (exit) killed" and
          entry.text =~ "Start Call: Task.Supervised.start_link/?"
      end

      if name in [:hang, :slow_drip] do
        assert Enum.all?(errors, killed_report?),
               "#{name}: unexpected error event(s): #{inspect(errors)}"
      else
        assert errors == [], "#{name}: error-level event(s): #{inspect(errors)}"
      end
    end
  end

  test "the success case really presented the secrets to the relay (so their absence from logs means something)" do
    env = prepare(:success)
    assert SmtpSink.connections(env.sink) == 0

    assert Smtp.deliver_tenant_list(@typed, tenants()) == :ok
    SmtpSink.await_closed(env.sink)
    assert [%{auth: [{user, pass}]}] = SmtpSink.transcripts(env.sink)
    assert {user, pass} == {S.user(), S.pass()}
    assert [%{rcpts: [rcpt]}] = SmtpSink.messages(env.sink)
    assert String.downcase(rcpt) == String.downcase(@typed)
  end

  test "ALL cases under ONE capture: nothing sensitive in the combined output" do
    collector = attach_collector()

    try do
      for name <- @cases, do: run_case(name)
      LoggerCollector.assert_alive!(collector)
    after
      LoggerCollector.detach(collector)
    end

    entries = LoggerCollector.collected(collector)
    log = Enum.map_join(entries, "\n", & &1.text)

    assert_clean(:all_cases, log, entries)
    assert log =~ @fixed_line
  end

  test "the secrets are in no application env and no inspected configuration" do
    S.configure_smtp!(S.start_sink!(:accept), [])

    dump =
      inspect(Application.get_all_env(:letflow), limit: :infinity, printable_limit: :infinity)

    refute dump =~ S.pass()
    refute dump =~ S.user()

    {:ok, runtime} = Letflow.LoginDiscovery.Notifier.Smtp.Config.runtime()
    refute inspect(runtime, limit: :infinity) =~ S.pass()
    refute inspect(runtime, limit: :infinity) =~ S.user()

    assert runtime |> Map.keys() |> Enum.sort() ==
             [:base_url, :from, :host, :port, :socket_timeout_ms, :tls]
  end

  # ── structural guards ───────────────────────────────────────────────────

  describe "structural guards (no process, no struct, no logging in the new modules)" do
    @new_files ["lib/letflow/login_discovery/notifier/smtp.ex"] ++
                 Path.wildcard("lib/letflow/login_discovery/notifier/smtp/*.ex")

    test "the new SMTP modules start no process of any kind and define no struct" do
      assert length(@new_files) == 4

      for path <- @new_files do
        src = code(path)

        refute src =~
                 ~r/(\bstart_child|\basync_nolink|\bTask\.(start|async|Supervisor)|\bspawn|\bGenServer\.start|\bAgent\.start|\bSupervisor\.start|:proc_lib|\bProcess\.spawn)/,
               "#{path} starts a process"

        refute src =~ ~r/\bdefstruct\b|@derive\b|\bdefexception\b|\bdefprotocol\b|\bdefimpl\b/,
               "#{path} defines a struct/exception"

        refute src =~ ~r/Process\.flag\(:trap_exit|:erlang\.process_flag/, "#{path} traps exits"
      end
    end

    test "the new SMTP modules never log, print or inspect anything" do
      for path <- @new_files do
        refute code(path) =~
                 ~r/\bLogger\b|\bIO\.(inspect|puts|write)|\binspect\(|\bdbg\(|:logger\.|:error_logger|Exception\.message|Exception\.format/,
               "#{path} logs/prints/inspects"
      end
    end

    test "start_child / async_nolink / spawn* / Task.start* under lib/letflow/login_discovery/ appear only in closure form" do
      for path <- Path.wildcard("lib/letflow/login_discovery/**/*.ex") do
        src = code(path)

        refute src =~ ~r/\bTask\.start(_link)?\(/, "#{path}: Task.start*"
        refute src =~ ~r/\bspawn(_link|_monitor)?\(/, "#{path}: spawn*"
        refute src =~ ~r/Task\.(Supervisor\.)?async\(/, "#{path}: linked async"

        for [_whole, name, args] <- Regex.scan(~r/\b(start_child|async_nolink)\(([^)]*)/, src) do
          assert args =~ ~r/^\s*@?[a-z_]+,\s*(fun|fn)\b/,
                 "#{path}: #{name}(#{String.slice(args, 0, 60)}) is not a (supervisor, closure) call"
        end
      end

      dispatch = code("lib/letflow/login_discovery/dispatch.ex")
      assert length(Regex.scan(~r/\b(start_child|async_nolink)\(/, dispatch)) == 2
    end

    test "the transport is the only module that names the mail library" do
      owners =
        for path <- Path.wildcard("lib/**/*.ex"),
            code(path) =~ ~r/:gen_smtp|:mimemail|gen_smtp_client/,
            do: path

      assert owners == ["lib/letflow/login_discovery/notifier/smtp/transport.ex"]
      refute code("lib/letflow/login_discovery/notifier/smtp/transport.ex") =~ ":mimemail"
    end
  end

  defp code(path) do
    path
    |> File.read!()
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end
end
