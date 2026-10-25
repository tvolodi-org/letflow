defmodule Letflow.TenantProvisioner.RequestTest do
  @moduledoc """
  REQ-572 / GH #3252 (decision 0072): the pure create-body validation, plus the pure config parser
  behind `config/runtime.exs`. Test IDs C5 (validation matrix), C8 (defaults), A3/A5 (hash form).
  No database. `async: false` only because the hostname suffixes and the demo lifetime live in app env.
  """

  use ExUnit.Case, async: false

  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Request

  @id "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  @realm "t-0a1b2c3d4e5f4a6b8c7d"
  @now ~U[2026-10-26 10:00:00.000000Z]

  setup do
    previous = Application.get_env(:letflow, Letflow.TenantProvisioner)

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example"],
      demo_lifetime_days: 14
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, Letflow.TenantProvisioner, previous),
        else: Application.delete_env(:letflow, Letflow.TenantProvisioner)
    end)
  end

  defp body(overrides \\ %{}) do
    Map.merge(
      %{
        "tenant_id" => @id,
        "name" => "Acme Demo",
        "language" => "en",
        "tier" => "demo",
        "owner_email" => "Owner@Example.com",
        "hostname" => "acme.qa.example",
        "idp_realm_id" => @realm
      },
      overrides
    )
  end

  defp parse(overrides), do: Request.parse(body(overrides), now: @now)

  test "C5 a valid body parses; e-mail and tenant id are canonical" do
    assert {:ok, request} = Request.parse(body(%{"tenant_id" => String.upcase(@id)}), now: @now)
    assert request.tenant_id == @id
    assert request.email_key == "owner@example.com"
    assert request.hostname == "acme.qa.example"
    assert request.idp_realm_id == @realm
  end

  test "C5 the slug and realm are derived from the tenant id" do
    assert Request.slug(@id) == "t-0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d"
    assert Request.realm_for(@id) == @realm
  end

  test "C5 a bad tenant_id is refused, injection-shaped included" do
    for bad <- [
          "not-a-uuid",
          "x'; drop schema public; --",
          "{#{@id}}",
          "",
          123,
          nil,
          String.duplicate("a", 64)
        ] do
      assert {:error, "tenant_id"} = parse(%{"tenant_id" => bad})
    end
  end

  test "C5 name, language, tier" do
    assert {:error, "name"} = parse(%{"name" => "   "})
    assert {:error, "name"} = parse(%{"name" => String.duplicate("x", 201)})
    assert {:ok, _} = parse(%{"name" => String.duplicate("x", 200)})
    assert {:error, "name"} = parse(%{"name" => 5})
    assert {:error, "language"} = parse(%{"language" => "de"})
    assert {:error, "tier"} = parse(%{"tier" => "production"})
    assert {:error, "tier"} = parse(%{"tier" => "gold"})
  end

  test "C5 owner_email" do
    for bad <- [
          "",
          "plain",
          "a@b",
          "ünï@example.com",
          "a b@example.com",
          String.duplicate("a", 255)
        ] do
      assert {:error, "owner_email"} = parse(%{"owner_email" => bad})
    end
  end

  test "C5 hostname: one label plus a configured suffix, nothing else" do
    for bad <- [
          "https://acme.qa.example",
          "acme.qa.example:8443",
          "acme.qa.example/path",
          "ac_me.qa.example",
          "acme.qa.example.",
          "10.0.0.1",
          "a.b.qa.example",
          "acme.other.example",
          "qa.example",
          ".qa.example",
          "-acme.qa.example",
          String.duplicate("a", 64) <> ".qa.example",
          String.duplicate("a", 250) <> ".qa.example"
        ] do
      assert {:error, "hostname"} = parse(%{"hostname" => bad}), "accepted #{bad}"
    end

    assert {:ok, %{hostname: "acme.qa.example"}} = parse(%{"hostname" => " ACME.qa.example "})
  end

  test "C5 hostname: no suffix configured refuses every hostname" do
    Application.put_env(:letflow, Letflow.TenantProvisioner, allowed_hostname_suffixes: [])
    assert {:error, "hostname"} = parse(%{})
  end

  test "C5 idp_realm_id must be the one derived from the tenant id" do
    for bad <- [
          "bpm-default",
          "master",
          "acme",
          "t-0a1b2c3d4e5f4a6b8c7e",
          "T-0A1B2C3D4E5F4A6B8C7D",
          "t-0a1b2c3d4e5f4a6b8c7d00",
          String.duplicate("t", 80),
          7
        ] do
      assert {:error, "idp_realm_id"} = parse(%{"idp_realm_id" => bad})
    end
  end

  test "C5 unknown and missing keys; a body that is not an object" do
    assert {:error, "body"} = parse(%{"extra" => 1})
    assert {:error, "owner_email"} = Request.parse(Map.delete(body(), "owner_email"), now: @now)
    assert {:error, "body"} = Request.parse([1], now: @now)
    assert {:error, "body"} = Request.parse(nil, now: @now)
  end

  test "C5 expires_at: ISO 8601 UTC in the future" do
    assert {:ok, %{expires_at: at}} = parse(%{"expires_at" => "2026-12-01T00:00:00Z"})
    assert at == ~U[2026-12-01 00:00:00Z]
    assert {:error, "expires_at"} = parse(%{"expires_at" => "2026-10-01T00:00:00Z"})
    assert {:error, "expires_at"} = parse(%{"expires_at" => "2026-12-01T00:00:00+02:00"})
    assert {:error, "expires_at"} = parse(%{"expires_at" => "tomorrow"})
    assert {:error, "expires_at"} = parse(%{"expires_at" => 5})
  end

  test "C8 the default expiry is now plus the configured lifetime" do
    assert {:ok, %{expires_at: at}} = parse(%{})
    assert at == DateTime.add(@now, 14 * 86_400, :second)

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example"],
      demo_lifetime_days: 3
    )

    assert {:ok, %{expires_at: at3}} = parse(%{})
    assert at3 == DateTime.add(@now, 3 * 86_400, :second)
  end

  describe "config parser (A3, A5)" do
    @hash String.duplicate("a", 64)
    @other String.duplicate("b", 64)
    @write "LETFLOW_PROVISIONER_CREDENTIAL_SHA256"
    @read "LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256"

    test "A3 hashes must be exactly 64 lowercase hex" do
      for bad <- [
            String.upcase(@hash),
            String.duplicate("a", 63),
            String.duplicate("a", 65),
            "zz" <> String.duplicate("a", 62)
          ] do
        assert {:error, @write} = Config.parse(%{@write => bad}, :test)
      end

      assert {:ok, %{auth: [write_sha256: @hash]}} = Config.parse(%{@write => @hash}, :test)
      refute Config.valid_hash?(nil)
    end

    test "A5 equal write and read hashes are refused; different ones are accepted" do
      assert {:error, @read} = Config.parse(%{@write => @hash, @read => @hash}, :test)

      assert {:ok, %{auth: auth}} = Config.parse(%{@write => @hash, @read => @other}, :test)
      assert auth[:write_sha256] == @hash and auth[:read_sha256] == @other
    end

    test "unset or blank writes nothing" do
      assert {:ok, %{auth: [], provisioner: [], public_base_url: nil}} =
               Config.parse(%{@write => "  "}, :test)
    end

    test "suffixes, lifetime days and the public base URL" do
      assert {:ok, %{provisioner: kw, public_base_url: "https://letflow.qa.example"}} =
               Config.parse(
                 %{
                   "LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES" => "QA.example, demo.example",
                   "LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS" => "7",
                   "LETFLOW_PUBLIC_BASE_URL" => "https://letflow.qa.example/"
                 },
                 :prod
               )

      assert kw[:allowed_hostname_suffixes] == ["qa.example", "demo.example"]
      assert kw[:demo_lifetime_days] == 7

      assert {:error, "LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES"} =
               Config.parse(
                 %{"LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES" => "bad suffix"},
                 :test
               )

      assert {:error, "LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS"} =
               Config.parse(%{"LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS" => "0"}, :test)

      assert {:error, "LETFLOW_PUBLIC_BASE_URL"} =
               Config.parse(%{"LETFLOW_PUBLIC_BASE_URL" => "http://insecure.example"}, :prod)
    end
  end
end
