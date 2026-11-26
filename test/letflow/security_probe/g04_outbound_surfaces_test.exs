defmodule Letflow.SecurityProbe.G04OutboundSurfacesTest do
  @moduledoc """
  G-04, outbound surfaces (design cases C-12..C-16 and the seeded leaks of S6, S7
  and S9). A 127.0.0.1 listener records every request it receives (S7); the
  notifier double records every message (S9); the S* catch-all reads every table
  of the tenant and `public` schema, which includes the DLQ (S6) and delivery rows.

  Each real case plants canaries (`G04Canary.new/2`) in the input form of its
  design row, drives the REAL context function (`Webhooks.deliver/3`,
  `Notifications.deliver_to_address/6`, `OutboundDestinations.add/4`), then scans
  every collector. A hit fails unless the exceptions list excuses it. Per-case
  verdicts only judge the rows that name their case (see `G04Canary.verdict/3`).

  Non-vacuity: the `seeded:` tests plant a canary straight into S6, S7 and S9
  through the same collectors and assert the hit is named. C-10/C-11 (the delivery
  that exhausts its four attempts: about 27 s of backoff and timeouts) live in
  `g04_dlq_surface_test.exs`, which declares its cost and runs in CI and nightly.
  Class table:
  `docs/security-probes/G-04.md`.
  """

  use Letflow.DataCase, async: false

  @moduletag :security_probe
  @moduletag probe_cost_s: 5

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.OutboundDestinations
  alias Letflow.Repo
  alias Letflow.SecurityProbe.G04Canary, as: G
  alias Letflow.Secrets
  alias Letflow.Support.PlatformCallFixture, as: PCF
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.TenantProvisioning
  alias Letflow.Webhooks
  alias Letflow.Webhooks.Subscription
  alias Letflow.WebhookTestServer

  @exceptions Path.expand("../../fixtures/security_probes/g04/exceptions.txt", __DIR__)
  @notifier Letflow.LoginDiscovery.Notifier

  # The tenant is committed and provisioning dominates the cost, so ONE test
  # (tagged `tenant: true`) drives every real case; the seeded S7/S9 tests need none.
  setup tags do
    fx =
      if tags[:tenant] do
        on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
        PCF.tenant!("g04-out")
      end

    {:ok, rows} = G.load_exceptions(@exceptions)

    Application.put_env(:letflow, :webhook_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :webhook_ssrf_validation_enabled) end)

    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)

    sink = G.attach_sink()
    on_exit(fn -> G.detach_sink(sink) end)
    {:ok, fx: fx, rows: rows, sink: sink}
  end

  # --- collectors --------------------------------------------------------------

  # S7: what the listener received, split into path/query, headers and body.
  defp listener_items do
    drain_requests([])
    |> Enum.flat_map(fn r ->
      headers = Enum.map_join(r.headers, "\n", fn {k, v} -> "#{k}: #{v}" end)

      [
        {"S7", "#{r.method} request line", "request_path_query", r.path},
        {"S7", "#{r.method} #{r.path}", "request_headers", headers},
        {"S7", "#{r.method} #{r.path}", "request_body", r.body}
      ]
    end)
  end

  defp drain_requests(acc) do
    receive do
      {:webhook_test_server_request, r} -> drain_requests([r | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # S9: every message the notifier double was asked to send.
  defp notifier_items do
    drain_messages([])
    |> Enum.map(fn m -> {"S9", "notifier double", "any", inspect(m, limit: :infinity)} end)
  end

  defp drain_messages(acc) do
    receive do
      {:deliver_message, m} -> drain_messages([m | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp verdict(ctx, canaries, items) do
    all = items ++ G.drain_sink(ctx.sink) ++ G.database_items(ctx.fx.schema_name)

    G.verdict_cases(all, canaries, ctx.rows)
  end

  defp assert_clean(v) do
    assert v.unlisted == [], "G-04 leak(s): #{inspect(v.unlisted, pretty: true)}"
    assert v.stale == [], "stale baseline row(s): #{inspect(v.stale)}"
  end

  # --- fixtures ------------------------------------------------------------------

  defp subscription!(schema, target_url, secret_plaintext) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema)
    id = Ecto.UUID.generate()

    {:ok, secret} =
      Secrets.put(%{
        tenant_id: tenant_id,
        namespace: "webhook",
        name: id,
        purpose: :webhook_hmac,
        plaintext:
          secret_plaintext || "lf_whsec_" <> Base.encode16(:crypto.strong_rand_bytes(16)),
        created_by: "system:g04"
      })

    {:ok, sub} =
      %Subscription{}
      |> Subscription.insert_changeset(%{
        id: id,
        tenant_id: tenant_id,
        target_url: target_url,
        secret_ref: secret.reference,
        secret_key_id: secret.key_id,
        description: nil,
        event_types: [],
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert(prefix: schema)

    sub
  end

  # --- seeded failing cases (non-vacuity) ----------------------------------------

  describe "seeded: a canary written straight into each surface is caught" do
    test "S7: a request the listener received (path, header, body)", ctx do
      c = G.new("SEED-S7", :email)
      server = WebhookTestServer.start(200, "ok")

      {:ok, _} =
        :httpc.request(
          :post,
          {String.to_charlist(server.url <> "?e=" <> URI.encode_www_form(c.value)),
           [{~c"x-seed", String.to_charlist(c.core)}], ~c"application/json",
           Jason.encode!(%{"v" => c.value})},
          [],
          []
        )

      assert_receive {:webhook_test_server_request, _} = msg
      send(self(), msg)
      hits = G.scan(listener_items(), c)

      assert Enum.sort(Enum.map(hits, & &1.part)) ==
               ["request_body", "request_headers", "request_path_query"]

      assert length(G.verdict(hits, ctx.rows).unlisted) == 3
    end

    test "S9: a message sent to the notifier double", ctx do
      c = G.new("SEED-S9", :email)
      send(self(), {:deliver_message, %{to: c.value, body: "hello"}})
      hits = G.scan(notifier_items(), c)
      assert [%{surface: "S9"}] = hits
      assert [_] = G.verdict(hits, ctx.rows).unlisted
    end
  end

  # --- real cases ---------------------------------------------------------------

  # C-12 + C-13: an instance event payload with canary variables, signed with a
  # canary secret, sent to the tenant's own endpoint. E-04 excuses the body.
  @tag tenant: true
  test "real cases C-12..C-16 on one tenant", ctx do
    c12(ctx)
    c14(ctx)
    c16(ctx)
    s6(ctx)
  end

  defp c12(ctx) do
    # C-12/C-13: webhook delivery of canary variables, signing secret never leaves", ctx do
    email = G.new("C-12", :email)
    name = G.new("C-12", :name)
    secret = G.new("C-13", :secret)
    server = WebhookTestServer.start(200, "ok")
    sub = subscription!(ctx.fx.schema_name, server.url, secret.value)

    assert {:ok, d} =
             Webhooks.deliver(sub, "g04.event", %{"email" => email.value, "name" => name.value})

    assert d.status == :SUCCESS
    items = listener_items()
    assert Enum.any?(items, fn {_, _, part, b} -> part == "request_body" and b =~ email.core end)
    assert_clean(verdict(ctx, [email, name, secret], items))
  end

  defp c14(ctx) do
    email = G.new("C-14", :email)
    name = G.new("C-14", :name)
    {:ok, _} = OutboundDestinations.add(ctx.fx.schema_name, nil, "email", nil)
    {:ok, _} = OutboundDestinations.add(ctx.fx.schema_name, nil, "email", "example.test")

    assert {"sent", nil} =
             Letflow.Notifications.deliver_to_address(
               "tenant_registered",
               email.value,
               Ecto.UUID.generate(),
               %{"tenant_name" => name.value, "tenant_slug" => "g04", "registered_by" => "g04"},
               ctx.fx.schema_name
             )

    assert_receive {:deliver_message, msg}, 2000
    send(self(), {:deliver_message, msg})
    v = verdict(ctx, [email, name], notifier_items())
    # delivery rows are the notification log: the S9 home of the same values
    rest = Enum.reject(v.unlisted, &String.starts_with?(&1.surface, "S*:notification"))
    assert rest == [], "G-04 leak(s): #{inspect(rest, pretty: true)}"
    assert v.excused != [], "E-05 matched nothing: the message did not carry the canary"
  end

  # C-16: a percent- and double-percent-encoded canary as an outbound destination.
  defp c16(ctx) do
    c = G.new("C-16", :credential_url)
    once = URI.encode_www_form(c.value)
    twice = URI.encode_www_form(once)

    results =
      for dest <- [once, twice] do
        OutboundDestinations.add(ctx.fx.schema_name, nil, "webhook", dest)
      end

    assert Enum.all?(results, &(match?({:ok, _}, &1) or match?({:error, _}, &1)))
    v = verdict(ctx, [c], [])
    # a stored destination is the allow-list entry itself (its home); anything else leaks
    rest = Enum.reject(v.unlisted, &String.starts_with?(&1.surface, "S*:outbound_destinations"))
    assert rest == [], "G-04 leak(s): #{inspect(rest, pretty: true)}"
  end

  # seeded S6: the DLQ is part of the derived inventory and a seeded row in it is caught
  defp s6(ctx) do
    c = G.new("SEED-S6", :credential_url)
    prefix = ctx.fx.schema_name

    dlq_table =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name LIKE '%dlq%' LIMIT 1",
        [prefix]
      ).rows

    assert [[table]] = dlq_table, "no dlq table in the tenant schema: S6 would be vacuous"
    # the DLQ is part of the inventory the catch-all derives (not a hand list)
    assert Enum.any?(G.database_items(prefix), fn {s, _, _, _} -> s == "S*:" <> table end)

    Repo.query!(~s|CREATE TABLE "#{prefix}".g04_dlq_seed (reason text)|)
    Repo.query!(~s|INSERT INTO "#{prefix}".g04_dlq_seed VALUES ($1)|, [c.value])

    try do
      assert [%{surface: "S*:g04_dlq_seed"}] = G.scan(G.database_items(prefix), c)
    after
      Repo.query!(~s|DROP TABLE "#{prefix}".g04_dlq_seed|)
    end
  end
end
