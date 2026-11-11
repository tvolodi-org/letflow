defmodule Letflow.SignupProvisioningTest do
  @moduledoc """
  T-1593 (TA-SL2b part a, decision 0085): the realm step of the sign-up saga against a provisioner stub
  (Bandit on a random loopback port, real `:httpc`). Sandbox is shared (`async: false`) so the off-request
  task sees the test's connection. P = provisioning flow, V = response validation, F = flag/config,
  U = URL check, L = secrets in logs.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import ExUnit.CaptureLog
  import Letflow.Test.SignupHelpers

  alias Letflow.Repo
  alias Letflow.Signup
  alias Letflow.Signup.{Provisioning, RealmProvisioner, Request}
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-caller-token"
  @password "Tmp-Pa55-ONE-time"

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

  describe "happy path" do
    test "P1 verify over the real router starts the step: realm stored, credential mailed, bearer sent" do
      enable!()
      assert post_signup().status == 202
      assert_receive {:deliver_message, verification}, 2_000
      token = token_from(verification)
      tenant_id = Repo.one!(Request).tenant_id
      track_tenant(tenant_id)
      stub = stub_created(tenant_id)
      configure!(stub)

      assert request(:post, "/api/signup/verify", %{"token" => token}).status == 200
      assert await_mail() == :ok

      row = row(tenant_id)
      label = RealmProvisioner.label(tenant_id)
      assert {row.state, row.step} == {"provisioning", "tenant_created"}
      assert {row.idp_realm_id, row.template_version} == {label, "v2"}
      assert row.idp_issuer =~ label
      assert row.credential_sent_at

      assert [post] = Stub.posts(stub)
      assert post.auth == "Bearer " <> @token
      assert post.path == "/v1/realms"
      assert post.body["tier"] == "demo"
      assert post.body["tenant_id"] == tenant_id
      assert post.body["owner_email"] == "owner@example.test"
      assert post.body["hostname"] == label <> ".qa.example.test"

      assert_receive {:deliver_message, credential}, 2_000
      assert credential.to == "owner@example.test"
      assert credential.body =~ @password

      # a repeat of the link is the same 200 and does not call the provisioner again
      assert request(:post, "/api/signup/verify", %{"token" => token}).status == 200
      assert await_mail() == :ok
      assert length(Stub.posts(stub)) == 1
    end

    test "P2 the password is only in the mail: not in the row, its inspect, or the log" do
      r = ready_row()
      stub = stub_created(r.tenant_id)
      configure!(stub)

      log = capture_log(fn -> assert Provisioning.run(r.tenant_id) == :ok end)
      assert_receive {:deliver_message, %{body: body}}, 2_000
      assert body =~ @password

      row = row(r.tenant_id)
      refute inspect(row) =~ @password
      refute inspect(Map.from_struct(row)) =~ @password
      refute log =~ @password
      refute log =~ @token
      refute :erlang.term_to_binary(Application.get_all_env(:letflow)) =~ @token
    end
  end

  describe "idempotent and resumable" do
    test "P3 a replay (200 without the password) sends the Forgot-password hint" do
      r = ready_row()
      replay = Stub.created(r.tenant_id) |> Map.delete("first_admin")
      stub = Stub.start!([{200, replay}])
      configure!(stub)

      assert Provisioning.run(r.tenant_id) == :ok
      assert [%{body: body}] = mails()
      assert body =~ "Forgot password"
      refute body =~ @password
      assert row(r.tenant_id).step == "tenant_created"
    end

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
      assert row(r.tenant_id).step == "tenant_created"
      assert [_hint] = mails()
    end

    test "P5 the claim is a compare-and-set: a held row is skipped, a finished one is not re-run" do
      r = ready_row()
      stub = stub_created(r.tenant_id)
      configure!(stub)

      assert %Request{} = Provisioning.claim(r.tenant_id)
      assert Provisioning.claim(r.tenant_id) == nil
      assert Provisioning.run(r.tenant_id) == :noop
      assert Stub.posts(stub) == []

      Repo.update_all(from_tenant(r.tenant_id), set: [claimed_at: nil])
      assert Provisioning.run(r.tenant_id) == :ok
      assert Provisioning.run(r.tenant_id) == :noop
      assert length(Stub.posts(stub)) == 1
    end

    test "T2 advance is idempotent and never calls the network" do
      r = ready_row(step: "verified")
      assert Signup.advance(r).step == "ready_for_provisioning"
      assert Signup.advance(row(r.tenant_id)) == row(r.tenant_id)
    end
  end

  describe "conflicts" do
    test "P6 409 then GET 200 is a replay; one POST, no password in the mail" do
      r = ready_row()

      stub =
        Stub.start!([{409, %{"error" => "conflict"}}], [
          {200, Map.delete(Stub.created(r.tenant_id), "first_admin")}
        ])

      configure!(stub)

      assert Provisioning.run(r.tenant_id) == :ok
      assert length(Stub.posts(stub)) == 1
      assert [%{method: "GET", path: path}] = Enum.filter(Stub.calls(stub), &(&1.method == "GET"))
      assert path == "/v1/realms/" <> r.tenant_id
      assert [%{body: body}] = mails()
      refute body =~ @password
    end

    test "P7 409 demo_cap_reached fails at once with that code" do
      r = ready_row()
      stub = Stub.start!([{409, %{"error" => "demo_cap_reached"}}])
      configure!(stub)

      assert Provisioning.run(r.tenant_id) == {:failed, "demo_cap_reached"}
      assert length(Stub.posts(stub)) == 1
      assert {row(r.tenant_id).state, row(r.tenant_id).step} == {"failed", "provisioning_failed"}
      assert mails() == []
    end

    test "P7b 409 with GET 404 and an unknown cause is a permanent invalid_request" do
      r = ready_row()
      stub = Stub.start!([{409, %{"error" => "other"}}], [{404, %{}}])
      configure!(stub)
      assert Provisioning.run(r.tenant_id) == {:failed, "invalid_request"}
    end
  end

  describe "failure leaves a visible state and a cleanup path" do
    test "P8 5xx is retried within the budget, then the row is failed with a fixed code" do
      r = ready_row()
      stub = Stub.start!([{503, %{"error" => "down"}}])
      configure!(stub)

      log =
        capture_log(fn -> assert Provisioning.run(r.tenant_id) == {:failed, "unavailable"} end)

      assert length(Stub.posts(stub)) == 3
      row = row(r.tenant_id)

      assert {row.state, row.step, row.last_error} ==
               {"failed", "provisioning_failed", "unavailable"}

      assert row.step_attempts == 3
      assert log =~ "signup provisioning failed: unavailable"
      [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "signup provisioning failed"))
      refute line =~ r.tenant_id
      refute log =~ @token
    end

    test "P8b 401 is permanent: one POST, code unauthorized" do
      r = ready_row()
      stub = Stub.start!([{401, %{}}])
      configure!(stub)

      assert capture_log(fn ->
               assert Provisioning.run(r.tenant_id) == {:failed, "unauthorized"}
             end)

      assert length(Stub.posts(stub)) == 1
    end

    test "P8c 429 with Retry-After is retried, then the next answer is used" do
      r = ready_row()
      stub = Stub.start!([{429, %{}}, {201, Stub.created(r.tenant_id)}])
      configure!(stub)
      assert Provisioning.run(r.tenant_id) == :ok
      assert length(Stub.posts(stub)) == 2
    end

    test "P9 a timeout counts as unavailable" do
      r = ready_row()
      stub = Stub.start!([{200, {:sleep, 600}}])
      configure!(stub, http_timeout_ms: 100, retry_delays_ms: [0])

      capture_log(fn -> assert Provisioning.run(r.tenant_id) == {:failed, "unavailable"} end)
      assert row(r.tenant_id).last_error == "unavailable"
    end

    test "P10 the resume path completes a failed row once the provisioner recovers" do
      r = ready_row()
      stub = Stub.start!([{503, %{}}])
      configure!(stub)
      capture_log(fn -> Provisioning.run(r.tenant_id) end)
      assert row(r.tenant_id).state == "failed"

      Stub.set_script(stub, :post, [{201, Stub.created(r.tenant_id)}])
      assert [{tenant_id, :ok}] = Provisioning.resume()
      assert tenant_id == r.tenant_id
      assert {row(tenant_id).state, row(tenant_id).step} == {"provisioning", "tenant_created"}
    end

    test "P10b resume leaves a permanent failure alone unless forced" do
      r = ready_row()
      stub = Stub.start!([{409, %{"error" => "demo_cap_reached"}}])
      configure!(stub)
      Provisioning.run(r.tenant_id)
      assert Provisioning.resume() == []
      assert row(r.tenant_id).state == "failed"

      Stub.set_script(stub, :post, [{201, Stub.created(r.tenant_id)}])
      assert [{_, :ok}] = Provisioning.resume(force: true)
    end

    test "P11 a failing mail adapter fails the row after the realm exists; resume sends the hint" do
      r = ready_row()
      stub = stub_created(r.tenant_id)
      configure!(stub)
      Letflow.LoginDiscoveryNotifierDouble.set_behaviour(:error)

      capture_log(fn ->
        assert Provisioning.run(r.tenant_id) == {:failed, "credential_mail_failed"}
      end)

      row = row(r.tenant_id)
      assert row.idp_realm_id == RealmProvisioner.label(r.tenant_id)
      assert length(Stub.posts(stub)) == 1
      refute inspect(row) =~ @password

      Letflow.LoginDiscoveryNotifierDouble.set_behaviour(:ok)
      mails()
      assert [{_, :ok}] = Provisioning.resume()
      assert length(Stub.posts(stub)) == 1
      assert [%{body: body}] = mails()
      assert body =~ "Forgot password"
      assert row(r.tenant_id).step == "tenant_created"
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
        assert Provisioning.run(r.tenant_id) == {:failed, "bad_response"}
        assert mails() == []
        assert row(r.tenant_id).idp_realm_id == nil
      end
    end

    test "V7 an oversize body is rejected" do
      r = ready_row()
      stub = Stub.start!([{201, {:raw, String.duplicate("x", 70_000)}}])
      configure!(stub)
      assert Provisioning.run(r.tenant_id) == {:failed, "bad_response"}
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
        assert Provisioning.run(r.tenant_id) == :ok
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
