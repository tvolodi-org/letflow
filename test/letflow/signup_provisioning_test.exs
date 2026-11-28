defmodule Letflow.SignupProvisioningTest do
  @moduledoc """
  T-1593 (TA-SL2b part a, decision 0085): the sign-up saga and (since T-3154) the realm CLIENT against a provisioner stub
  (Bandit on a random loopback port, real `:httpc`). Sandbox is shared (`async: false`) so the off-request
  task sees the test's connection. P = provisioning flow, V = response validation, F = flag/config,
  U = URL check, L = secrets in logs.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Letflow.Test.SignupHelpers

  alias Letflow.Repo
  alias Letflow.Signup
  alias Letflow.Signup.{Provisioning, RealmProvisioner, Request}
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-caller-token"

  setup do
    System.put_env(RealmProvisioner.token_env(), @token)
    on_exit(fn -> System.delete_env(RealmProvisioner.token_env()) end)
    {:ok, _} = Application.ensure_all_started(:inets)
    tenant_create_env!()
    :ok
  end

  defp configure!(stub, overrides \\ []) do
    enable!(
      Keyword.merge(
        [
          provisioner_url: stub.url,
          hostname_domain: "qa.example.test",
          retry_delays_ms: [0, 0],
          http_timeout_ms: 2_000
        ],
        overrides
      )
    )
  end

  defp ready_row(attrs \\ []) do
    tenant_id = Keyword.get(attrs, :tenant_id) || Ecto.UUID.generate()
    track_tenant(tenant_id)

    Repo.insert!(
      struct!(
        %Request{
          tenant_id: tenant_id,
          email: "owner@example.test",
          company_name: "Acme Ltd",
          language: "en",
          state: "verified",
          step: "ready_for_provisioning",
          ip_key: :crypto.hash(:sha256, tenant_id),
          terms_version: "t",
          terms_accepted_at: DateTime.utc_now(),
          verified_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp stub_created(tenant_id, overrides \\ %{}),
    do: Stub.start!([{201, Stub.created(tenant_id, overrides)}])

  defp row(tenant_id), do: Repo.get!(Request, tenant_id)

  defp mails do
    receive do
      {:deliver_message, m} -> [m | mails()]
    after
      50 -> []
    end
  end

  describe "idempotent and resumable" do
    test "P4 a row left at realm_created resumes at the mail without a second POST" do
      id = Ecto.UUID.generate()

      r =
        ready_row(
          tenant_id: id,
          step: "realm_created",
          state: "provisioning",
          idp_realm_id: RealmProvisioner.label(id)
        )

      stub = stub_created(r.tenant_id)
      configure!(stub)

      assert Provisioning.run(r.tenant_id) == :ok
      assert Stub.posts(stub) == []
      assert row(r.tenant_id).step == "completed"
      assert [_hint, _welcome] = mails()
    end

    test "P5 the claim is a compare-and-set: a held row is skipped, a finished one is not re-run" do
      id = Ecto.UUID.generate()

      r =
        ready_row(
          tenant_id: id,
          step: "credential_sent",
          state: "provisioning",
          idp_realm_id: RealmProvisioner.label(id)
        )

      stub = stub_created(r.tenant_id)
      configure!(stub)

      assert %Request{} = Provisioning.claim(r.tenant_id)
      assert Provisioning.claim(r.tenant_id) == nil
      assert Provisioning.run(r.tenant_id) == :noop

      Repo.update_all(from_tenant(r.tenant_id), set: [claimed_at: nil])
      assert Provisioning.run(r.tenant_id) == :ok
      assert Provisioning.run(r.tenant_id) == :noop
      # T-3154: the saga never calls the provisioner
      assert Stub.calls(stub) == []
    end

    test "T2 advance is idempotent and never calls the network" do
      r = ready_row(step: "verified")
      assert Signup.advance(r).step == "ready_for_provisioning"
      assert Signup.advance(row(r.tenant_id)) == row(r.tenant_id)
    end
  end

  # T-3154: the saga no longer calls the provisioner (the registration process does, see
  # `signup_provisioning_process_test.exs`); the CLIENT's own answers are pinned here directly.
  defp create_realm(r) do
    RealmProvisioner.create_realm(
      %{
        tenant_id: r.tenant_id,
        company_name: "Acme Ltd",
        language: "en",
        email: "owner@example.test",
        slug: r.slug
      },
      Signup.config()
    )
  end

  describe "client conflicts" do
    test "P6 409 then GET 200 is a replay; one POST, no password" do
      r = ready_row()

      stub =
        Stub.start!([{409, %{"error" => "conflict"}}], [
          {200, Map.delete(Stub.created(r.tenant_id), "first_admin")}
        ])

      configure!(stub)

      assert {:ok, :replay, realm} = create_realm(r)
      assert realm.password == nil
      assert length(Stub.posts(stub)) == 1
      assert [%{method: "GET", path: path}] = Enum.filter(Stub.calls(stub), &(&1.method == "GET"))
      assert path == "/v1/realms/" <> r.tenant_id
    end

    test "P7 409 demo_cap_reached is that code, at once" do
      r = ready_row()
      stub = Stub.start!([{409, %{"error" => "demo_cap_reached"}}])
      configure!(stub)

      assert create_realm(r) == {:error, :demo_cap_reached}
      assert length(Stub.posts(stub)) == 1
    end

    test "P7b 409 with GET 404 and an unknown cause is a permanent invalid_request" do
      r = ready_row()
      stub = Stub.start!([{409, %{"error" => "other"}}], [{404, %{}}])
      configure!(stub)
      assert create_realm(r) == {:error, :invalid_request}
    end
  end

  describe "chosen slug and the user's own retry (T-2748)" do
    test "P21 a failed request: verify keeps the link valid; only retry:true resumes a retryable one" do
      enable!()
      r = ready_row()
      token = "retry-token-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      Repo.update_all(from(x in Request, where: x.tenant_id == ^r.tenant_id),
        set: [
          token_hash: :crypto.hash(:sha256, token),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          state: "failed",
          step: "provisioning_failed",
          last_error: "unavailable"
        ]
      )

      assert request(:post, "/api/signup/verify", %{"token" => token}).status == 200
      assert row(r.tenant_id).state == "failed"

      assert %{"state" => "failed", "reason" => "unavailable"} =
               request(:post, "/api/signup/status", %{"token" => token}) |> json()

      assert request(:post, "/api/signup/verify", %{"token" => token, "retry" => true}).status ==
               200

      assert row(r.tenant_id).state in ["provisioning", "verified", "completed", "failed"]
      refute row(r.tenant_id).last_error == nil and row(r.tenant_id).state == "failed"
    end

    test "P22 a permanent failure is not resumed by retry" do
      enable!()
      r = ready_row()
      token = "perm-token-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      Repo.update_all(from(x in Request, where: x.tenant_id == ^r.tenant_id),
        set: [
          token_hash: :crypto.hash(:sha256, token),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          state: "failed",
          step: "provisioning_failed",
          last_error: "demo_cap_reached"
        ]
      )

      assert request(:post, "/api/signup/verify", %{"token" => token, "retry" => true}).status ==
               200

      assert row(r.tenant_id).state == "failed"
    end
  end

  describe "visitor retry is bounded; host checked before the realm (T-2748, SF-13)" do
    defp failed_row!(attrs) do
      r = ready_row()
      token = "bound-token-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      Repo.update_all(
        from(x in Request, where: x.tenant_id == ^r.tenant_id),
        set:
          [
            token_hash: :crypto.hash(:sha256, token),
            token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
            state: "failed",
            step: "provisioning_failed"
          ] ++ attrs
      )

      {r, token}
    end

    test "P23 a visitor retry does not reset the attempt budget; an exhausted budget is refused" do
      enable!(max_attempts: 5)
      {r, token} = failed_row!(last_error: "unavailable", step_attempts: 5)

      assert request(:post, "/api/signup/verify", %{"token" => token, "retry" => true}).status ==
               200

      assert row(r.tenant_id).state == "failed"
      assert row(r.tenant_id).step_attempts == 5
      assert Provisioning.retry_failed(r.tenant_id) == :not_retryable

      {r2, _} = failed_row!(last_error: "attempts_exhausted", step_attempts: 1)
      assert Provisioning.retry_failed(r2.tenant_id) == :not_retryable

      {r3, _} = failed_row!(last_error: "unavailable", step_attempts: 2)
      assert Provisioning.retry_failed(r3.tenant_id) == :ok
      assert row(r3.tenant_id).step_attempts == 2
    end

    test "P27 a retry after another visitor took the released slug is a 409 slug_taken, not a crash" do
      enable!()
      {a, token} = failed_row!(last_error: "unavailable", step_attempts: 1, slug: "race-co")
      b = ready_row(slug: "race-co", email: "other@example.test")
      b_before = row(b.tenant_id)

      resp = request(:post, "/api/signup/verify", %{"token" => token, "retry" => true})
      assert resp.status == 409
      assert %{"error" => "slug_taken"} = json(resp)
      assert row(a.tenant_id).state == "failed"
      assert row(b.tenant_id).state == b_before.state
      assert row(b.tenant_id).slug == "race-co"
      assert Provisioning.retry_failed(a.tenant_id) == :slug_taken

      # the same e-mail has a newer live request: not retryable, no crash
      {c, _} = failed_row!(last_error: "unavailable", step_attempts: 1)
      _live = ready_row()
      assert Provisioning.retry_failed(c.tenant_id) == :not_retryable
      assert row(c.tenant_id).state == "failed"
    end

    test "P24 a host outside the allowed suffixes starts no process and calls no provisioner" do
      r = ready_row(slug: "my-co")
      stub = stub_created(r.tenant_id)
      configure!(stub, hostname_domain: "other.example.test")

      assert Provisioning.run(r.tenant_id) == {:failed, "invalid_tenant"}
      assert Stub.posts(stub) == []
      assert row(r.tenant_id).state == "failed"
      assert row(r.tenant_id).last_error == "invalid_tenant"
    end

    test "P25 GET /slug and the verify retry answer 429 once the address bucket is drained" do
      enable!()
      ip = {198, 51, 100, 77}

      statuses =
        for _ <- 1..40, do: request(:get, "/api/signup/slug?slug=my-co", nil, ip: ip).status

      assert 200 in statuses
      assert 429 in statuses

      assert request(:post, "/api/signup/verify", %{"token" => "x", "retry" => true}, ip: ip).status ==
               429
    end

    test "P26 two visitors behind one proxy peer do not share a bucket; the 429 carries retry-after and the privacy headers" do
      enable!()
      prev = Application.get_env(:letflow, Letflow.Plugs.ClientIp)
      Application.put_env(:letflow, Letflow.Plugs.ClientIp, trusted_proxies: [{{10, 0, 0, 0}, 8}])

      on_exit(fn ->
        if prev,
          do: Application.put_env(:letflow, Letflow.Plugs.ClientIp, prev),
          else: Application.delete_env(:letflow, Letflow.Plugs.ClientIp)
      end)

      peer = {10, 0, 0, 1}

      get = fn real ->
        request(:get, "/api/signup/slug?slug=my-co", nil,
          ip: peer,
          headers: [{"x-real-ip", real}]
        )
      end

      last = for(_ <- 1..40, do: get.("198.51.100.10")) |> List.last()
      assert last.status == 429
      assert Plug.Conn.get_resp_header(last, "retry-after") != []
      assert Plug.Conn.get_resp_header(last, "cache-control") == ["private, no-store"]
      assert Plug.Conn.get_resp_header(last, "referrer-policy") == ["no-referrer"]
      assert Plug.Conn.get_resp_header(last, "x-robots-tag") == ["noindex, nofollow"]

      assert get.("203.0.113.99").status == 200
    end
  end

  describe "client failure classes" do
    test "P8 5xx is unavailable (the step retries it); no token in the log" do
      r = ready_row()
      stub = Stub.start!([{503, %{"error" => "down"}}])
      configure!(stub)

      log = capture_log(fn -> assert create_realm(r) == {:error, :unavailable} end)
      assert length(Stub.posts(stub)) == 1
      refute log =~ @token
    end

    test "P8b 401 is permanent: one POST, code unauthorized" do
      r = ready_row()
      stub = Stub.start!([{401, %{}}])
      configure!(stub)

      assert create_realm(r) == {:error, :unauthorized}
      assert length(Stub.posts(stub)) == 1
    end

    test "P8c 429 is rate_limited" do
      r = ready_row()
      stub = Stub.start!([{429, %{}}])
      configure!(stub)
      assert {:error, {:rate_limited, _hint}} = create_realm(r)
    end

    test "P9 a timeout counts as unavailable" do
      r = ready_row()
      stub = Stub.start!([{200, {:sleep, 600}}])
      configure!(stub, http_timeout_ms: 100)

      assert create_realm(r) == {:error, :unavailable}
    end
  end

  describe "response validation" do
    for {id, overrides} <- [
          V1: %{"tenant_id" => "00000000-0000-0000-0000-000000000000"},
          V2: %{"realm" => "t-0123456789abcdef0123"},
          V3: %{"realm" => "master"},
          V4: %{"tier" => "production"},
          V5: %{"client_id" => "admin-cli"},
          V6: %{"issuer" => "ftp://evil"}
        ] do
      test "#{id} #{inspect(overrides)} is rejected as bad_response, no mail" do
        r = ready_row()
        stub = stub_created(r.tenant_id, unquote(Macro.escape(overrides)))
        configure!(stub)
        assert create_realm(r) == {:error, :bad_response}
        assert mails() == []
      end
    end

    test "V7 an oversize body is rejected" do
      r = ready_row()
      stub = Stub.start!([{201, {:raw, String.duplicate("x", 70_000)}}])
      configure!(stub)
      assert create_realm(r) == {:error, :bad_response}
    end
  end

  describe "flag and configuration" do
    test "F1 flag off: verify never calls the provisioner" do
      r = ready_row()
      stub = stub_created(r.tenant_id)
      configure!(stub, enabled: false)
      assert Provisioning.run(r.tenant_id) == :noop
      assert Provisioning.start_async(r.tenant_id) == :ok
      assert await_mail() == :ok
      assert Stub.calls(stub) == []
    end

    test "F2 flag on but provisioner env unset: the step does not run" do
      r = ready_row()
      enable!()
      refute Provisioning.configured?()
      assert Provisioning.run(r.tenant_id) == :noop
      assert row(r.tenant_id).step == "ready_for_provisioning"
    end

    test "F2b missing token: not configured" do
      stub = Stub.start!([{201, %{}}])
      configure!(stub)
      System.delete_env(RealmProvisioner.token_env())
      refute Provisioning.configured?()
    end

    test "F4 tier is demo for every language and no production literal exists in the new modules" do
      for lang <- ~w(ru kk en) do
        r = ready_row(language: lang, email: "owner-#{lang}@example.test")
        stub = stub_created(r.tenant_id)
        configure!(stub)
        assert {:ok, :created, _realm} = create_realm(r)
        assert [%{body: %{"tier" => "demo"}}] = Stub.posts(stub)
      end

      for file <- ~w(lib/letflow/signup/realm_provisioner.ex lib/letflow/signup/provisioning.ex) do
        refute File.read!(file) =~ ~s("production")
      end
    end

    test "I1 the new modules touch no tenant schema prefix" do
      for file <- ~w(lib/letflow/signup/realm_provisioner.ex lib/letflow/signup/provisioning.ex) do
        refute File.read!(file) =~ "prefix:"
      end
    end
  end

  describe "base URL check (INV-9)" do
    test "U1 loopback, RFC 1918 and localhost with an explicit port are accepted" do
      for url <- [
            "http://127.0.0.1:3218",
            "http://10.0.0.5:3218",
            "http://172.20.1.1:80/",
            "http://192.168.1.2:3218",
            "http://[::1]:3218",
            "http://localhost:3218"
          ] do
        assert RealmProvisioner.valid_base_url?(url), url
      end
    end

    test "U2 other hosts, https, userinfo, paths, queries and missing ports are refused" do
      for url <- [
            "http://example.com:3218",
            "https://127.0.0.1:3218",
            "http://127.0.0.1@evil:3218",
            "http://user:pw@127.0.0.1:3218",
            "http://127.0.0.1:3218/v1",
            "http://127.0.0.1:3218?x=1",
            "http://127.0.0.1",
            "http://172.32.0.1:80",
            "http://8.8.8.8:80",
            "",
            nil
          ] do
        refute RealmProvisioner.valid_base_url?(url), inspect(url)
      end
    end

    test "U3 the client re-checks per call and a missing token is not_configured" do
      cfg =
        Map.merge(Signup.config(), %{
          provisioner_url: "http://example.com:1",
          hostname_domain: "x.test"
        })

      req = %{
        tenant_id: Ecto.UUID.generate(),
        company_name: "A",
        language: "en",
        email: "a@b.test"
      }

      assert RealmProvisioner.create_realm(req, cfg) == {:error, :bad_url}
      System.delete_env(RealmProvisioner.token_env())
      assert RealmProvisioner.create_realm(req, cfg) == {:error, :not_configured}
    end
  end

  defp from_tenant(tenant_id) do
    import Ecto.Query
    from(r in Request, where: r.tenant_id == ^tenant_id)
  end
end
