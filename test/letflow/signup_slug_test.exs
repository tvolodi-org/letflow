defmodule Letflow.SignupSlugTest do
  @moduledoc """
  T-2748 (PILOT G22): the sign-up slug check, the slug and user name on the request, the status route of the
  result page and the config flags the sign-up screens read.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Letflow.Test.SignupHelpers

  import Ecto.Query
  alias Letflow.Repo
  alias Letflow.Signup.Request

  setup do
    enable!(hostname_domain: "qa.example.test")
    :ok
  end

  defp slug_status(slug) do
    conn = request(:get, "/api/signup/slug?slug=" <> URI.encode_www_form(slug))
    assert conn.status == 200
    json(conn)["status"]
  end

  defp insert_row!(attrs) do
    token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    row =
      Repo.insert!(
        struct!(
          Request,
          Map.merge(
            %{
              tenant_id: Ecto.UUID.generate(),
              ip_key: :crypto.hash(:sha256, "t"),
              terms_version: "t",
              terms_accepted_at: DateTime.utc_now(),
              email: "x#{System.unique_integer([:positive])}@example.test",
              company_name: "Co",
              language: "en",
              state: "verified",
              step: "verified",
              token_hash: :crypto.hash(:sha256, token),
              token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            },
            attrs
          )
        )
      )

    {row, token}
  end

  describe "GET /api/signup/slug" do
    test "available, invalid shapes and reserved words" do
      assert slug_status("my-company") == "available"
      assert slug_status("ab") == "invalid"
      assert slug_status("-bad-") == "invalid"
      assert slug_status("a--b") == "invalid"
      assert slug_status("Upper") == "invalid"
      assert slug_status("t-0123456789abcdef") == "invalid"
      assert slug_status(String.duplicate("a", 31)) == "invalid"
      assert slug_status("www") == "reserved"
    end

    test "a missing parameter is invalid, not a 500" do
      conn = request(:get, "/api/signup/slug")
      assert conn.status == 200
      assert json(conn)["status"] == "invalid"
    end

    test "taken by a live request, released by a failed one" do
      {row, _} =
        insert_row!(%{
          slug: "taken-co",
          state: "pending_verification",
          step: "await_verification"
        })

      assert slug_status("taken-co") == "taken"

      row |> Ecto.Changeset.change(state: "failed") |> Repo.update!()
      assert slug_status("taken-co") == "available"
    end

    test "taken by an existing tenant" do
      tenant = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "slugtk")

      Repo.update_all(
        from(t in Letflow.Identity.Tenant, where: t.id == ^tenant.tenant_id),
        set: [slug: "existing-co"]
      )

      assert slug_status("existing-co") == "taken"
    end

    test "off by default: 404 when the flag is off" do
      Application.put_env(:letflow, Letflow.Signup, enabled: false)
      assert request(:get, "/api/signup/slug?slug=free-one").status == 404
    end
  end

  describe "POST /api/signup with a slug" do
    test "stores slug and user name on the row" do
      conn = post_signup(%{"slug" => "my-company", "user_name" => "Aigerim S."})
      assert conn.status == 202
      row = Repo.one!(Request)
      assert row.slug == "my-company"
      assert row.user_name == "Aigerim S."
    end

    test "a taken slug is 422 slug_taken with the field named and a localised message" do
      insert_row!(%{slug: "taken-co", state: "pending_verification", step: "await_verification"})
      conn = post_signup(%{"slug" => "taken-co", "language" => "ru"})
      assert conn.status == 422
      body = json(conn)
      assert body["error"] == "slug_taken"
      assert body["fields"] == ["slug"]
      assert body["message"] =~ "занято"
      assert Repo.aggregate(Request, :count) == 1
    end

    test "a taken slug answers every address alike, owner or not, in every live state (INV-5)" do
      for state <- ["pending_verification", "verified", "provisioning"] do
        slug = "held-" <> String.replace(state, "_", "-")
        owner = slug <> "@example.test"
        insert_row!(%{slug: slug, email: owner, state: state, step: state})
        mine = post_signup(%{"slug" => slug, "email" => String.upcase(owner)})
        other = post_signup(%{"slug" => slug, "email" => "someone@example.test"})
        assert mine.status == 422, state
        assert other.status == 422, state
        assert mine.resp_body == other.resp_body, state
      end
    end

    test "a free slug keeps the neutral 202 for a known and an unknown address" do
      insert_row!(%{
        slug: "mine-co",
        email: "owner@example.test",
        state: "pending_verification",
        step: "await_verification"
      })

      assert post_signup(%{"slug" => "free-co", "email" => "owner@example.test"}).status == 202
      assert post_signup(%{"slug" => "free-co2", "email" => "new@example.test"}).status == 202
    end

    test "a visitor password-shaped canary never reaches logs, responses or the read model" do
      canary = "Cnry-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          ok = post_signup(%{"slug" => "canary-co", "password" => canary})
          bad = post_signup(%{"slug" => "www", "password" => canary})

          taken =
            post_signup(%{
              "slug" => "canary-co",
              "password" => canary,
              "email" => "z@example.test"
            })

          send(self(), {:bodies, [ok.resp_body, bad.resp_body, taken.resp_body]})
        end)

      assert_received {:bodies, bodies}
      refute log =~ canary
      for b <- bodies, do: refute(b =~ canary)
      refute inspect(Repo.all(Request), limit: :infinity) =~ canary
    end

    test "an invalid or reserved slug and a bad user name are 422 invalid_request" do
      for params <- [%{"slug" => "www"}, %{"slug" => "x"}, %{"slug" => 5}, %{"user_name" => 7}] do
        conn = post_signup(params)
        assert conn.status == 422, inspect(params)
        assert json(conn)["error"] == "invalid_request"
      end
    end

    test "no slug keeps the old behaviour" do
      assert post_signup().status == 202
      assert Repo.one!(Request).slug == nil
    end
  end

  describe "POST /api/signup/status" do
    test "pending, ready (host from the slug) and failed with a closed reason" do
      {_, t1} = insert_row!(%{slug: "my-co", state: "provisioning", step: "realm_created"})
      conn = request(:post, "/api/signup/status", %{"token" => t1})
      assert %{"state" => "pending", "host" => nil} = json(conn)

      {row2, t2} = insert_row!(%{slug: "my-co2", state: "completed", step: "completed"})
      realm = Letflow.TenantProvisioner.Request.slug(row2.tenant_id)

      assert %{"state" => "ready", "host" => "my-co2.qa.example.test", "realm" => ^realm} =
               json(request(:post, "/api/signup/status", %{"token" => t2}))

      {_, t3} =
        insert_row!(%{
          state: "failed",
          step: "provisioning_failed",
          last_error: "demo_cap_reached"
        })

      assert %{"state" => "failed", "reason" => "demo_cap_reached"} =
               json(request(:post, "/api/signup/status", %{"token" => t3}))

      {_, t4} =
        insert_row!(%{
          state: "failed",
          step: "provisioning_failed",
          last_error: "some internal text"
        })

      assert %{"reason" => "internal"} =
               json(request(:post, "/api/signup/status", %{"token" => t4}))
    end

    test "an unknown or malformed token is one generic 400" do
      assert request(:post, "/api/signup/status", %{"token" => "nope"}).status == 400

      assert request(:post, "/api/signup/status", %{"token" => String.duplicate("a", 30)}).status ==
               400

      assert request(:post, "/api/signup/status", %{}).status == 400
    end
  end

  test "config tells the form there is no password field yet and the host domain" do
    body = json(request(:get, "/api/signup/config"))
    assert body["password_required"] == false
    assert body["slug_supported"] == true
    assert body["hostname_domain"] == "qa.example.test"
  end
end
