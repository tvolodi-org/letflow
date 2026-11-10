defmodule Letflow.SignupTest do
  @moduledoc """
  T-1579 TA-SL2a: sign-up through the real `Letflow.Router` (S1-S4, V1-V5, A1-A5, T1-T4, P1, M3).
  Sandbox is shared (`async: false`) so the off-request mail task sees the same connection.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Ecto.Query
  import Letflow.Test.SignupHelpers

  alias Letflow.Repo
  alias Letflow.Signup
  alias Letflow.Signup.Request

  setup do
    enable!()
    :ok
  end

  defp the_row, do: Repo.one!(Request)

  defp mail!,
    do:
      (
        assert_receive {:deliver_message, message}, 2_000
        message
      )

  defp no_mail, do: refute_receive({:deliver_message, _}, 100)

  describe "submit" do
    test "S1 happy path: 202, one pending row, server-generated tenant_id, mail sent" do
      conn = post_signup(%{"language" => "kk"})
      assert conn.status == 202
      assert json(conn) == %{"status" => "check_your_mail"}
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      row = the_row()

      assert {row.state, row.step, row.language} ==
               {"pending_verification", "await_verification", "kk"}

      assert row.email == "owner@example.test"
      assert {:ok, _} = Ecto.UUID.cast(row.tenant_id)
      assert row.terms_version == Signup.terms_version()
      assert mail!().to == "owner@example.test"
    end

    test "S2 field errors answer 422 with the field names and store nothing" do
      conn =
        post_signup(%{
          "company_name" => "  ",
          "email" => "nope",
          "language" => "de",
          "terms_accepted" => false
        })

      assert conn.status == 422
      assert json(conn)["fields"] == ["company_name", "email", "language", "terms_accepted"]
      assert post_signup(%{"company_name" => String.duplicate("x", 201)}).status == 422
      assert Repo.aggregate(Request, :count) == 0
      no_mail()
    end

    test "S3 body-supplied tenant_id and slug are ignored (INV-10 negative)" do
      forged = Ecto.UUID.generate()

      assert post_signup(%{"tenant_id" => forged, "slug" => "evil", "tier" => "production"}).status ==
               202

      refute the_row().tenant_id == forged
    end

    test "S4 oversize body, wrong content type and junk answer 422, never 500" do
      assert request(:post, "/api/signup", String.duplicate("x", 10_000)).status == 422

      assert request(:post, "/api/signup", Jason.encode!(signup_body()), json: false).status ==
               422

      assert request(:post, "/api/signup", "[1,2]").status == 422
      assert request(:post, "/api/signup", "{").status == 422
      assert Repo.aggregate(Request, :count) == 0
    end

    test "GET /config reports the languages and the terms version" do
      conn = request(:get, "/api/signup/config")
      assert conn.status == 200
      assert %{"enabled" => true, "languages" => ["ru", "kk", "en"]} = json(conn)
    end
  end

  describe "verify" do
    setup do
      assert post_signup().status == 202
      %{token: token_from(mail!())}
    end

    test "V1/V2 a valid token verifies and a repeat is the same 200; step is ready_for_provisioning",
         %{token: token} do
      assert verify(token).status == 200
      row = the_row()
      assert {row.state, row.step} == {"verified", "ready_for_provisioning"}
      assert verify(token).status == 200
      assert the_row() == row
    end

    test "M3 only the SHA-256 of the token is stored", %{token: token} do
      row = the_row()
      assert row.token_hash == :crypto.hash(:sha256, token)
      refute inspect(row) =~ token
    end

    test "V3 unknown, malformed, expired and closed tokens all answer the identical 400", %{
      token: token
    } do
      unknown = verify(String.duplicate("a", 43))
      assert unknown.status == 400
      assert json(unknown) == %{"error" => "invalid_or_expired_link"}

      for bad <- ["", "short", String.duplicate("z", 500), 12, nil, ["x"]] do
        conn = request(:post, "/api/signup/verify", %{"token" => bad})
        assert {conn.status, conn.resp_body} == {400, unknown.resp_body}
      end

      assert request(:post, "/api/signup/verify", "not json").resp_body == unknown.resp_body

      Repo.update_all(Request,
        set: [token_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

      expired = verify(token)
      assert {expired.status, expired.resp_body} == {400, unknown.resp_body}
    end

    test "V3 a token of an expired (closed) request is refused", %{token: token} do
      Repo.update_all(Request, set: [state: "expired", email: nil, token_hash: nil])
      assert verify(token).status == 400
    end

    test "V4 GET on the verify path does not verify (prefetch safety)", %{token: token} do
      assert request(:get, "/api/signup/verify?token=#{token}").status == 404
      assert the_row().state == "pending_verification"
    end

    test "V5 a later submit does not change a verified request", %{token: token} do
      assert verify(token).status == 200
      before = the_row()
      assert post_signup().status == 202
      no_mail()
      assert the_row() == before
    end

    test "P1 verify touches neither tenants nor tenant_lifecycles", %{token: token} do
      count = fn ->
        Repo.aggregate("tenants", :count) + Repo.aggregate("tenant_lifecycles", :count)
      end

      before = count.()
      assert verify(token).status == 200
      assert count.() == before
    end
  end

  describe "saga" do
    test "T1 the table keeps its constraints" do
      assert post_signup().status == 202
      id = Ecto.UUID.dump!(the_row().tenant_id)

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE signup_requests SET state = 'weird' WHERE tenant_id = $1", [id])
      end
    end

    test "T1 a second open row for one e-mail is refused by the partial unique index" do
      assert post_signup().status == 202
      row = the_row()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%{row | tenant_id: Ecto.UUID.generate(), token_hash: <<1>>})
      end
    end

    test "T2 advance/1 twice leaves the same row" do
      assert post_signup().status == 202
      Repo.update_all(Request, set: [state: "verified", step: "verified"])
      once = Signup.advance(the_row())
      assert once.step == "ready_for_provisioning"
      assert Signup.advance(once) == once
    end

    test "T3 a crash after insert (no mail) resumes: a later submit mails without a second row" do
      assert post_signup().status == 202
      _lost = mail!()
      past = DateTime.add(DateTime.utc_now(), -120, :second)
      Repo.update_all(Request, set: [last_sent_at: past])

      assert post_signup().status == 202
      assert Repo.aggregate(Request, :count) == 1
      assert mail!().to == "owner@example.test"
    end

    test "T4 concurrent submits for one e-mail leave one row" do
      tasks =
        for _ <- 1..4, do: Task.async(fn -> Signup.submit(signup_body(), {203, 0, 113, 9}) end)

      assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == :accepted))
      assert Repo.aggregate(Request, :count) == 1
    end
  end

  describe "anti-abuse" do
    test "A1 the per-IP cap answers 429 with one constructor; other IPs and IPv6 /64 work as designed" do
      enable!(ip_hourly_cap: 2)
      for n <- 1..2, do: assert(post_signup(%{"email" => "a#{n}@example.test"}).status == 202)
      limited = post_signup(%{"email" => "a3@example.test"})
      assert limited.status == 429
      assert get_resp_header(limited, "retry-after") != []
      assert %{"error" => "rate_limited", "message" => "Too many" <> _} = json(limited)
      assert post_signup(%{"email" => "b@example.test"}, ip: {198, 51, 100, 1}).status == 202

      v6 = fn last -> {0x2001, 0xDB8, 0, 1, 0, 0, 0, last} end
      assert Signup.ip_key(v6.(1)) == Signup.ip_key(v6.(2))
      refute Signup.ip_key(v6.(1)) == Signup.ip_key({0x2001, 0xDB8, 0, 2, 0, 0, 0, 1})

      assert Signup.ip_key({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}) ==
               Signup.ip_key({192, 0, 2, 1})

      refute Enum.any?(Repo.all(from(r in Request, select: r.ip_key)), &(&1 =~ "203"))
    end

    test "A2 a resubmit inside the interval sends nothing; after it the token rotates" do
      assert post_signup().status == 202
      old = token_from(mail!())
      assert post_signup().status == 202
      no_mail()
      assert Repo.aggregate(Request, :count) == 1

      Repo.update_all(Request,
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -61, :second)]
      )

      assert post_signup().status == 202
      new = token_from(mail!())
      refute new == old
      assert verify(old).status == 400
      assert verify(new).status == 200
    end

    test "A3 the sixth mail for one request is not sent" do
      assert post_signup().status == 202
      _ = mail!()

      for _ <- 2..5 do
        Repo.update_all(Request,
          set: [last_sent_at: DateTime.add(DateTime.utc_now(), -61, :second)]
        )

        assert post_signup().status == 202
        _ = mail!()
      end

      Repo.update_all(Request,
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -61, :second)]
      )

      assert post_signup().status == 202
      no_mail()
      assert the_row().send_count == 5
    end

    test "A4 new, pending, verified and rate-limited-address answers are byte-identical" do
      first = post_signup()
      token = token_from(mail!())
      pending = post_signup()
      verify(token)
      verified = post_signup()
      same = fn conn -> {conn.status, conn.resp_body, conn.resp_headers} end
      assert same.(first) == same.(pending)
      assert same.(first) == same.(verified)
    end

    test "A4b at the pending cap an unknown and a verified address get the same answer" do
      assert post_signup(%{"email" => "victim@example.test"}).status == 202
      verify(token_from(mail!()))
      enable!(pending_cap: 1)
      assert post_signup(%{"email" => "filler@example.test"}).status == 202
      _ = mail!()
      same = fn conn -> {conn.status, conn.resp_body} end
      known = post_signup(%{"email" => "victim@example.test"})
      unknown = post_signup(%{"email" => "nobody@example.test"})
      assert same.(known) == same.(unknown)
      assert known.status == 503
      no_mail()
    end

    test "A5 the pending cap answers 503 and writes nothing; expired rows free capacity" do
      enable!(pending_cap: 1)
      assert post_signup(%{"email" => "one@example.test"}).status == 202
      _ = mail!()
      full = post_signup(%{"email" => "two@example.test"})
      assert full.status == 503
      assert %{"error" => "signup_unavailable", "message" => message} = json(full)
      assert message =~ "unavailable"
      assert Repo.aggregate(Request, :count) == 1
      no_mail()

      Repo.update_all(Request,
        set: [token_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert post_signup(%{"email" => "two@example.test"}).status == 202
      assert Repo.aggregate(from(r in Request, where: r.state == "expired"), :count) == 1
      assert Repo.one!(from(r in Request, where: r.state == "expired")).email == nil
    end

    test "abandon age closes a row whose link is still valid" do
      assert post_signup().status == 202

      Repo.update_all(Request,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)]
      )

      assert Signup.expire_stale() == 1
    end
  end

  defp verify(token), do: request(:post, "/api/signup/verify", %{"token" => token})
  defp get_resp_header(conn, key), do: Plug.Conn.get_resp_header(conn, key)

  describe "T-1620 anti-abuse" do
    defp domain_body(n, domain), do: %{"email" => "u#{n}@#{domain}"}

    test "S2 the per-domain cap refuses the next request; another domain and a later hour pass" do
      enable!(domain_hourly_cap: 2)
      now = DateTime.utc_now()
      body = fn n, d -> signup_body(domain_body(n, d)) end

      for n <- 1..2,
          do: assert(Signup.submit(body.(n, "corp.test"), {10, 0, 0, n}, now) == :accepted)

      assert Signup.submit(body.(3, "corp.test"), {10, 0, 0, 3}, now) ==
               {:error, :rate_limited_domain}

      assert Signup.submit(body.(3, "other.test"), {10, 0, 0, 3}, now) == :accepted

      later = DateTime.add(now, 3601, :second)
      assert Signup.submit(body.(4, "corp.test"), {10, 0, 0, 4}, later) == :accepted
    end

    test "S3 an exempt provider is not capped by the domain cap" do
      enable!(domain_hourly_cap: 1)
      body = fn n -> signup_body(domain_body(n, "gmail.com")) end
      assert Signup.submit(body.(1), {10, 0, 1, 1}) == :accepted
      assert Signup.submit(body.(2), {10, 0, 1, 2}) == :accepted
    end

    test "S4 domain_key is a hash and the plain domain is not in the row" do
      assert Signup.submit(signup_body(domain_body(1, "corp.test")), {10, 0, 2, 1}) == :accepted
      row = the_row()
      assert row.domain_key == Signup.domain_key("u1@corp.test")
      assert byte_size(row.domain_key) == 32
      refute String.contains?(row.domain_key, "corp")
    end

    test "S5 the domain cap is checked before the pending cap" do
      enable!(domain_hourly_cap: 1, pending_cap: 1)
      assert Signup.submit(signup_body(domain_body(1, "corp.test")), {10, 0, 3, 1}) == :accepted

      assert Signup.submit(signup_body(domain_body(2, "corp.test")), {10, 0, 3, 2}) ==
               {:error, :rate_limited_domain}

      assert Signup.submit(signup_body(domain_body(2, "elsewhere.test")), {10, 0, 3, 2}) ==
               {:error, :unavailable}
    end

    test "S7 a disposable domain is refused: no row, no mail" do
      assert Signup.submit(signup_body(domain_body(1, "mailinator.com")), {10, 0, 4, 1}) ==
               {:error, :email_not_accepted}

      enable!(disposable_domains: ["custom-bad.test"])

      assert Signup.submit(signup_body(domain_body(1, "custom-bad.test")), {10, 0, 4, 1}) ==
               {:error, :email_not_accepted}

      assert Repo.aggregate(Request, :count) == 0
      no_mail()
    end

    test "S8 captcha off by default: accepted without a token; config says not required" do
      assert post_signup().status == 202
      conn = request(:get, "/api/signup/config")
      assert json(conn)["captcha_required"] == false
    end

    defp with_captcha(answer) do
      Application.put_env(:letflow, :signup_captcha_fake_owner, self())
      Application.put_env(:letflow, :signup_captcha_fake_answer, answer)

      on_exit(fn ->
        Application.delete_env(:letflow, :signup_captcha_fake_owner)
        Application.delete_env(:letflow, :signup_captcha_fake_answer)
      end)

      enable!(captcha_adapter: Letflow.Test.SignupCaptchaFake)
    end

    test "S9 captcha adapter ok: accepted and the token is passed through" do
      with_captcha(:ok)
      body = signup_body(%{"captcha_token" => "tok-123"})
      assert Signup.submit(body, {10, 0, 5, 1}) == :accepted
      assert_receive {:captcha_token, "tok-123"}
      assert request(:get, "/api/signup/config") |> json() |> Map.get("captcha_required") == true
    end

    test "S9 a missing or oversize token reaches the adapter as nil" do
      with_captcha({:error, :failed})
      assert Signup.submit(signup_body(), {10, 0, 5, 2}) == {:error, :captcha_failed}
      assert_receive {:captcha_token, nil}

      assert Signup.submit(
               signup_body(%{"captcha_token" => String.duplicate("x", 5_000)}),
               {10, 0, 5, 2}
             ) ==
               {:error, :captcha_failed}

      assert_receive {:captcha_token, nil}
    end

    test "S9 failed, unavailable, raise and exit all refuse (fail closed) with no row and no mail" do
      for {answer, expected} <- [
            {{:error, :failed}, {:error, :captcha_failed}},
            {{:error, :unavailable}, {:error, :unavailable}},
            {:garbage, {:error, :unavailable}},
            {:raise, {:error, :unavailable}},
            {:exit, {:error, :unavailable}}
          ] do
        with_captcha(answer)
        assert Signup.submit(signup_body(), {10, 0, 6, 1}) == expected
      end

      assert Repo.aggregate(Request, :count) == 0
      no_mail()
    end

    test "S16 a row without domain_key (an older row) is valid and not counted" do
      assert Signup.submit(signup_body(domain_body(1, "corp.test")), {10, 0, 7, 1}) == :accepted
      Repo.update_all(Request, set: [domain_key: nil])
      enable!(domain_hourly_cap: 1)
      assert Signup.submit(signup_body(domain_body(2, "corp.test")), {10, 0, 7, 2}) == :accepted
    end

    test "S13 refusal bodies carry error and a message in the request language, default en" do
      blocked = post_signup(%{"email" => "x@mailinator.com", "language" => "ru"})
      assert blocked.status == 422
      assert %{"error" => "email_not_accepted", "message" => ru} = json(blocked)
      assert ru =~ "адрес"

      assert %{"message" => en} = json(post_signup(%{"email" => "x@mailinator.com"}))
      assert en =~ "e-mail address"

      assert %{"error" => "invalid_request", "message" => kk, "fields" => ["terms_accepted"]} =
               json(post_signup(%{"language" => "kk", "terms_accepted" => false}))

      assert kk != en

      enable!(domain_hourly_cap: 1)
      assert post_signup(%{"email" => "a@corp.test"}).status == 202

      limited =
        post_signup(%{"email" => "b@corp.test", "language" => "kk"}, ip: {198, 51, 100, 7})

      assert limited.status == 429
      assert get_resp_header(limited, "retry-after") != []
      assert %{"error" => "rate_limited", "message" => _} = json(limited)

      with_captcha({:error, :failed})
      failed = post_signup(%{"language" => "ru"})
      assert failed.status == 422
      assert %{"error" => "captcha_failed", "message" => _} = json(failed)

      with_captcha(:raise)
      down = post_signup()
      assert down.status == 503
      assert %{"error" => "signup_unavailable", "message" => _} = json(down)
    end

    test "S14 the refused-domain answer is the same whether or not the address is known" do
      same = fn conn -> {conn.status, conn.resp_body} end
      known = post_signup(%{"email" => "known@mailinator.com"})
      unknown = post_signup(%{"email" => "other@mailinator.com"})
      assert same.(known) == same.(unknown)
      assert known.status == 422
      assert post_signup(%{"email" => "fine@example.test"}).status == 202
    end

    test "S15 telemetry carries only the outcome and the log holds no e-mail or captcha token" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "t1620-#{inspect(ref)}",
        [:letflow, :signup, :outcome],
        fn _e, _m, meta, _c -> send(parent, {:outcome, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("t1620-#{inspect(ref)}") end)
      with_captcha({:error, :failed})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          post_signup(%{
            "email" => "secret-person@mailinator.com",
            "captcha_token" => "SECRET-CAPTCHA"
          })

          post_signup(%{
            "email" => "secret-person@example.test",
            "captcha_token" => "SECRET-CAPTCHA"
          })
        end)

      assert_receive {:outcome, %{outcome: :email_not_accepted} = meta1}
      assert_receive {:outcome, %{outcome: :captcha_failed} = meta2}
      assert Map.keys(meta1) == [:outcome] and Map.keys(meta2) == [:outcome]
      refute log =~ "secret-person"
      refute log =~ "SECRET-CAPTCHA"
    end
  end
end
