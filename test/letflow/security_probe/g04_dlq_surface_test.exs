defmodule Letflow.SecurityProbe.G04DlqSurfaceTest do
  @moduledoc """
  G-04 cases C-10 and C-11 (surface S6, the DLQ, and S7): a webhook target with
  userinfo and a query token; the delivery fails four times (1 s + 2 s + 4 s of
  backoff and the HTTP timeouts, about 27 s measured) and lands in the DLQ.
  The cost is declared (`probe_cost_s: 30`), so `lf.sh` runs it in CI and the
  nightly job, not in the checks step (PM rule 2, design section 7).

  The first run on main FOUND a leak: `dlq_entries` keeps the target URL with its
  credential. It is recorded as baseline row B-02 in the exceptions list (not
  fixed here); if the product stops storing the credential the row goes stale and
  this test fails until the row is deleted (the ratchet).
  """

  use Letflow.DataCase, async: false

  @moduletag :security_probe
  @moduletag probe_cost_s: 30

  alias Letflow.Repo
  alias Letflow.SecurityProbe.G04Canary, as: G
  alias Letflow.Secrets
  alias Letflow.Support.PlatformCallFixture, as: PCF
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.TenantProvisioning
  alias Letflow.Webhooks
  alias Letflow.Webhooks.Subscription
  alias Letflow.WebhookTestServer

  @exceptions Path.expand("../../fixtures/security_probes/g04/exceptions.txt", __DIR__)

  setup do
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    fx = PCF.tenant!("g04-dlq")
    {:ok, rows} = G.load_exceptions(@exceptions)
    Application.put_env(:letflow, :webhook_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :webhook_ssrf_validation_enabled) end)
    sink = G.attach_sink()
    on_exit(fn -> G.detach_sink(sink) end)
    {:ok, fx: fx, rows: rows, sink: sink}
  end

  defp listener_items(acc \\ []) do
    receive do
      {:webhook_test_server_request, r} -> listener_items([r | acc])
    after
      0 ->
        acc
        |> Enum.reverse()
        |> Enum.flat_map(fn r ->
          headers = Enum.map_join(r.headers, "\n", fn {k, v} -> "#{k}: #{v}" end)

          [
            {"S7", "request line", "request_path_query", r.path},
            {"S7", r.path, "request_headers", headers},
            {"S7", r.path, "request_body", r.body}
          ]
        end)
    end
  end

  defp subscription!(schema, target_url) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema)
    id = Ecto.UUID.generate()

    {:ok, secret} =
      Secrets.put(%{
        tenant_id: tenant_id,
        namespace: "webhook",
        name: id,
        purpose: :webhook_hmac,
        plaintext: "lf_whsec_" <> Base.encode16(:crypto.strong_rand_bytes(16)),
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

  # C-10 + C-11: a target with userinfo and a query token; the listener answers 500 so the
  # delivery exhausts into the DLQ. E-10 excuses the Authorization header to the host the
  # credential was configured for; the body, path/query and every stored row must be clean.
  @tag tenant: true
  test "C-10/C-11: a credential URL target, delivery that fails into the DLQ", ctx do
    server = WebhookTestServer.start(500, "boom")
    cu = G.new("C-10", :credential_url, port: server.port)
    sub = subscription!(ctx.fx.schema_name, cu.value)

    assert {:ok, d} = Webhooks.deliver(sub, "g04.event", %{"n" => 1})
    assert d.status == :FAILED and d.attempt_count == 4
    items = listener_items()
    # a userinfo URL is not sent by the HTTP client (nothing arrives), yet its failure
    # record is stored: that is the S6 leak B-02 records. A delivery that did arrive
    # is E-10's case (the Authorization header to the configured host).
    v = verdict(ctx, [cu], items)
    # the subscription row holds its own target_url (its home); the DLQ hit is baseline B-02
    rest = Enum.reject(v.unlisted, &(&1.surface == "S*:webhook_subscriptions"))
    assert rest == [], "G-04 leak(s): #{inspect(rest, pretty: true)}"
    assert Enum.any?(v.excused, &(&1.surface == "S*:dlq_entries")), "B-02 matched nothing"
    assert v.stale == []
  end

  # C-14 + C-15: a template rendering a canary variable, to a canary recipient. E-05
  # excuses the notifier message, the delivery rows hold the same values by design.

  defp verdict(ctx, canaries, items) do
    all = items ++ G.drain_sink(ctx.sink) ++ G.database_items(ctx.fx.schema_name)

    G.verdict_cases(all, canaries, ctx.rows)
  end
end
