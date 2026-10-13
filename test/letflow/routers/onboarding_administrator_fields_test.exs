defmodule Letflow.Routers.OnboardingAdministratorFieldsTest do
  @moduledoc """
  ISS-1030 PR 1 -- `POST /api/v1/onboarding` administrator echo, optional
  validated `idp_realm_id`, `login` marking, and the bind-once
  `POST /api/v1/onboarding/:id/bind-realm` route. Design:
  `lib/letflow/design/iss1030-onboarding-administrator.md` sections 3 and 10.1;
  mapping in `test/specs/ISS-1030-PR1.md`.

  Every request goes through the real `Letflow.Router` pipeline with a real API
  token of a PLATFORM_ADMIN of the pinned platform tenant (the same mechanism as
  `test/letflow/routers/onboarding_test.exs`), against real Postgres and real
  tenant schemas. The realm probe is the deterministic
  `Letflow.Oidc.RealmProbeDouble` (`config/test.exs`: a realm starting with
  `unknown` is not found, one starting with `unreachable` is unreachable);
  the one test that needs the real adapter's URL building switches to it and a
  scripted local server (`Letflow.Support.RealmProbeTestServer`).

  `async: false`: tenant provisioning flips the SQL sandbox to `:auto`, and the
  platform-tenant pin, the realm-probe adapter and the OIDC config are VM-global.

  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RealmProbeTestServer, as: Server
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.TenantSlugFixture

  @runbook "docs/runbooks/onboarding-new-tenant-realm.md"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-plat")
    Fixture.pin!(platform.tenant_id)
    token = Fixture.mint_token!(platform, ["PLATFORM_ADMIN"])

    # `mint_token!/2` creates exactly one user in the platform tenant's schema: the operator.
    operator_id =
      Repo.one!(
        from(u in User, where: like(u.username, "scope-caller-%"), select: u.id),
        prefix: platform.schema_name
      )

    %{platform: platform, token: token, operator_id: operator_id}
  end

  # --- helpers ---------------------------------------------------------------

  defp call(ctx, method, path, body) do
    method
    |> Fixture.api_conn(path, ctx.token, ctx.platform.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Byte-level comparison: the body with only the per-request trace_id removed.
  defp stable_body(conn), do: Regex.replace(~r/"trace_id":"[^"]*",?/, conn.resp_body, "")

  defp new_body(extra) do
    Map.merge(
      %{
        "slug" => TenantSlugFixture.unique_slug("iss1030"),
        "display_name" => "ISS-1030 Tenant",
        "hostname" => "iss1030-#{Ecto.UUID.generate()}.example.com"
      },
      extra
    )
  end

  # POST /onboarding that must succeed; returns the decoded 201 body. The created
  # tenant is torn down at the end of the test.
  defp onboard!(ctx, extra) do
    conn = call(ctx, :post, "/api/v1/onboarding", new_body(extra))
    assert conn.status == 201, conn.resp_body
    resp = json(conn)
    cleanup_onboarded_tenant!(resp["tenant_id"])
    resp
  end

  # POST /onboarding that must be refused with `status` and create nothing.
  defp refused!(ctx, extra, status) do
    body = new_body(extra)
    conn = call(ctx, :post, "/api/v1/onboarding", body)

    # A tenant the request created is removed even when an assert below fails (TEST-DESIGN-VALIDATOR MINOR 8).
    if tenant = Repo.get_by(Tenant, slug: body["slug"]), do: cleanup_onboarded_tenant!(tenant.id)

    assert conn.status == status, conn.resp_body
    assert Repo.get_by(Tenant, slug: body["slug"]) == nil, "a tenant row was created"
    # The record stores the trimmed hostname, so the check uses the trimmed value (MINOR 10).
    assert Repo.get_by(OnboardingRecord, hostname: String.trim(body["hostname"])) == nil
    conn
  end

  defp field_error?(conn, field, constraint) do
    conn
    |> json()
    |> Map.get("errors", [])
    |> Enum.any?(&(&1["field"] == field and &1["constraint"] == constraint))
  end

  defp field_error_on?(conn, field) do
    conn |> json() |> Map.get("errors", []) |> Enum.any?(&(&1["field"] == field))
  end

  defp bind(ctx, onboarding_id, realm_value) do
    call(ctx, :post, "/api/v1/onboarding/#{onboarding_id}/bind-realm", %{
      "idp_realm_id" => realm_value
    })
  end

  defp realm, do: TenantSlugFixture.unique_realm("iss1030")

  defp stored_realm(tenant_id), do: Repo.get!(Tenant, tenant_id).idp_realm_id

  defp schema_of(tenant_id) do
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    schema_name
  end

  defp entries(schema_name, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema_name)

  defp set_status!(tenant_id, status) do
    Tenant
    |> Repo.get!(tenant_id)
    |> Tenant.status_changeset(%{status: status})
    |> Repo.update!()
  end

  # Teardown for a tenant created through a real POST /onboarding (it is not a
  # TenantFixture tenant, so it gets none of that module's own cleanup); the
  # same shape as `test/letflow/routers/onboarding_test.exs`.
  defp cleanup_onboarded_tenant!(tenant_id) do
    on_exit(fn -> drop_tenant_rows!(tenant_id) end)
  end

  # For a test whose request may raise before it returns the tenant id: the tenant for the slug, if one was
  # committed, is looked up at exit and removed.
  defp cleanup_slug_on_exit(slug) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      case Repo.get_by(Tenant, slug: slug) do
        %Tenant{id: tenant_id} -> drop_tenant_rows!(tenant_id)
        nil -> :ok
      end
    end)
  end

  defp drop_tenant_rows!(tenant_id) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      {:error, :invalid_tenant_id} -> :ok
    end

    Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  # --- administrator echo (design 3.4) -----------------------------------------

  test "POST /onboarding with no admin fields returns 201 and administrator.state none with the next-step message",
       ctx do
    resp = onboard!(ctx, %{})

    administrator = resp["administrator"]
    assert administrator["state"] == "none"
    assert administrator["not_provisioned"] == []
    message = administrator["message"]
    steps = administrator["next_steps"]

    assert message =~ "no administrator"
    assert message =~ @runbook
    refute message =~ "NOT used"
    assert is_list(steps) and steps != []
    assert Enum.any?(steps, &(&1 =~ "TENANT_ADMIN"))
  end

  test "POST /onboarding with admin_email, admin_username and admin_display_name returns 201, echoes each as not_provisioned and stores nothing",
       ctx do
    email = "Ada.Admin@Example.com"

    resp =
      onboard!(ctx, %{
        "admin_email" => email,
        "admin_username" => "ada-admin",
        "admin_display_name" => "Ada Admin"
      })

    assert resp["administrator"]["state"] == "not_provisioned"
    assert resp["administrator"]["message"] =~ "NOT used"
    assert resp["administrator"]["message"] =~ @runbook

    echoed = Map.new(resp["administrator"]["not_provisioned"], &{&1["field"], &1["value"]})

    assert echoed == %{
             "admin_email" => email,
             "admin_username" => "ada-admin",
             "admin_display_name" => "Ada Admin"
           }

    # Nothing was created from the named administrator: no user in the new tenant.
    schema_name = schema_of(resp["tenant_id"])

    assert Repo.aggregate(
             from(u in User,
               where:
                 u.username == "ada-admin" or
                   fragment("lower(?)", u.email) == ^String.downcase(email)
             ),
             :count,
             :id,
             prefix: schema_name
           ) == 0

    # And nothing was granted: the tenant has no membership row at all.
    members = Repo.aggregate(Letflow.Identity.GroupMember, :count, :user_id, prefix: schema_name)
    assert members == 0
  end

  test "POST /onboarding treats a blank-string admin field as not sent: state none and no echo",
       ctx do
    resp =
      onboard!(ctx, %{"admin_email" => "", "admin_username" => "", "admin_display_name" => ""})

    assert resp["administrator"]["state"] == "none"
    assert resp["administrator"]["not_provisioned"] == []
    refute resp["administrator"]["message"] =~ "NOT used"
    assert resp["ignored_fields"] == []
  end

  test "POST /onboarding treats a null admin field as not sent: state none and no echo", ctx do
    resp =
      onboard!(ctx, %{
        "admin_email" => nil,
        "admin_username" => nil,
        "admin_display_name" => nil
      })

    assert resp["administrator"]["state"] == "none"
    assert resp["administrator"]["not_provisioned"] == []
    refute resp["administrator"]["message"] =~ "NOT used"
    assert resp["ignored_fields"] == []
  end

  test "POST /onboarding treats a whitespace-only admin field as not sent: state none and no echo",
       ctx do
    resp =
      onboard!(ctx, %{
        "admin_email" => "   ",
        "admin_username" => "\t \n",
        "admin_display_name" => " "
      })

    assert resp["administrator"]["state"] == "none"
    assert resp["administrator"]["not_provisioned"] == []
    refute resp["administrator"]["message"] =~ "NOT used"
    assert resp["ignored_fields"] == []
  end

  test "POST /onboarding with only admin_username and admin_display_name returns state none, the no-administrator message and both fields echoed as not_provisioned",
       ctx do
    resp =
      onboard!(ctx, %{"admin_username" => "grace", "admin_display_name" => "Grace Hopper"})

    assert resp["administrator"]["state"] == "none"
    assert resp["administrator"]["message"] =~ "no administrator"
    assert resp["administrator"]["message"] =~ "other administrator details"
    assert resp["administrator"]["message"] =~ "NOT used"

    echoed = Map.new(resp["administrator"]["not_provisioned"], &{&1["field"], &1["value"]})
    assert echoed == %{"admin_username" => "grace", "admin_display_name" => "Grace Hopper"}
  end

  test "POST /onboarding with a non-string admin_email answers 422 and creates no tenant row",
       ctx do
    for value <- [42, true, ["a@b.example"], %{"leak" => "zzLEAKEDVALUEzz"}] do
      conn = refused!(ctx, %{"admin_email" => value}, 422)

      assert field_error_on?(conn, "admin_email"), "value #{inspect(value)}: #{conn.resp_body}"
      refute conn.resp_body =~ "zzLEAKEDVALUEzz"
    end
  end

  test "POST /onboarding does not echo a non-string admin value and omits oversize values", ctx do
    at_limit = String.duplicate("a", 255)
    oversize = String.duplicate("d", 256)

    resp =
      onboard!(ctx, %{
        "admin_email" => at_limit,
        "admin_username" => 42,
        "admin_display_name" => oversize
      })

    echoed = Map.new(resp["administrator"]["not_provisioned"], &{&1["field"], &1})

    assert echoed["admin_email"] == %{"field" => "admin_email", "value" => at_limit}
    assert echoed["admin_username"] == %{"field" => "admin_username"}
    assert echoed["admin_display_name"] == %{"field" => "admin_display_name"}
    refute resp |> Jason.encode!() |> String.contains?(oversize)
  end

  test "POST /onboarding lists client_config, realm_config and redirect_uris in ignored_fields by name only",
       ctx do
    resp =
      onboard!(ctx, %{
        "client_config" => %{"secret" => "zzCLIENTSECRETzz"},
        "realm_config" => %{"display" => "zzREALMCONFIGzz"},
        "redirect_uris" => ["https://zzREDIRECTzz.example/cb"]
      })

    assert resp["ignored_fields"] == ["client_config", "realm_config", "redirect_uris"]

    encoded = Jason.encode!(resp)

    for marker <- ["zzCLIENTSECRETzz", "zzREALMCONFIGzz", "zzREDIRECTzz"] do
      refute encoded =~ marker
    end
  end

  test "an unknown admin_* key is listed in ignored_fields by name, while the three known ones are not",
       ctx do
    resp =
      onboard!(ctx, %{
        "admin_phone" => "zzPHONEVALUEzz",
        "admin_username" => "known-one"
      })

    assert resp["ignored_fields"] == ["admin_phone"]
    refute Jason.encode!(resp) =~ "zzPHONEVALUEzz"
  end

  test "ignored_fields is capped at 20 names, truncates each to 64 characters and strips control characters",
       ctx do
    # Cap: 25 distinct extra keys -> the first 20 (sorted) and a final marker.
    many = Map.new(1..25, fn n -> {"extra_" <> String.pad_leading("#{n}", 2, "0"), "v"} end)
    capped = onboard!(ctx, many)["ignored_fields"]

    assert length(capped) == 21
    assert List.last(capped) == "..."
    expected_first = Enum.map(1..20, &("extra_" <> String.pad_leading("#{&1}", 2, "0")))
    assert Enum.take(capped, 20) == expected_first

    # Truncation, control-character stripping and de-duplication after stripping.
    long = String.duplicate("L", 100)

    sanitised =
      onboard!(ctx, %{
        long => 1,
        "a\u0001b\u007Fc" => 2,
        "x\u0001" => 3,
        "x\u0002" => 4
      })["ignored_fields"]

    assert sanitised == [String.duplicate("L", 64), "abc", "x"]
  end

  test "POST /onboarding without any extra field is unchanged: status 201 and the five original keys are present",
       ctx do
    body = new_body(%{})
    conn = call(ctx, :post, "/api/v1/onboarding", body)

    assert conn.status == 201
    resp = json(conn)
    cleanup_onboarded_tenant!(resp["tenant_id"])

    # The five original keys, with their original values ...
    assert resp["slug"] == body["slug"]
    assert resp["hostname"] == body["hostname"]
    assert is_binary(resp["id"])
    assert is_binary(resp["tenant_id"])
    assert is_binary(resp["created_at"])

    # ... and only the three additive keys beside them.
    assert Enum.sort(Map.keys(resp)) ==
             Enum.sort([
               "id",
               "tenant_id",
               "slug",
               "hostname",
               "created_at",
               "login",
               "administrator",
               "ignored_fields"
             ])

    assert resp["ignored_fields"] == []
    assert resp["login"]["loginable"] == false
  end

  # --- idp_realm_id on create (design 3.1) -------------------------------------

  test "POST /onboarding with a valid idp_realm_id binds it and the record says loginable true",
       ctx do
    realm_id = realm()
    resp = onboard!(ctx, %{"idp_realm_id" => realm_id})

    assert resp["login"] == %{
             "loginable" => true,
             "status" => "realm_bound",
             "idp_realm_id" => realm_id,
             "next_steps" => []
           }

    assert stored_realm(resp["tenant_id"]) == realm_id
    assert_received {:realm_probe, ^realm_id}
  end

  test "POST /onboarding with an unknown idp_realm_id answers 422 and creates no tenant row",
       ctx do
    conn = refused!(ctx, %{"idp_realm_id" => "unknown-realm-" <> Ecto.UUID.generate()}, 422)

    assert field_error?(conn, "idp_realm_id", "not_found")
  end

  test "POST /onboarding with a blank, malformed or master idp_realm_id answers 422 and creates no tenant row",
       ctx do
    cases = [
      {"   ", "not_blank"},
      {"", "not_blank"},
      {"a.b", "format"},
      {"a/b", "format"},
      {"a b", "format"},
      {"master", "reserved"}
    ]

    for {value, constraint} <- cases do
      conn = refused!(ctx, %{"idp_realm_id" => value}, 422)

      assert field_error?(conn, "idp_realm_id", constraint),
             "value #{inspect(value)}: #{conn.resp_body}"
    end

    # An invalid value is refused before the identity provider is asked.
    refute_received {:realm_probe, _realm}
  end

  test "idp_realm_id validation refuses '.', '..', 'Master' (any case of master), an over-long value (65 characters) and a leading dash or underscore, and stores ' x ' as 'x' after trimming",
       ctx do
    refused = [".", "..", "Master", "MASTER", "mAsTeR", String.duplicate("a", 65), "-x", "_x"]

    for value <- refused do
      conn = refused!(ctx, %{"idp_realm_id" => value}, 422)
      assert field_error_on?(conn, "idp_realm_id"), "value #{inspect(value)}: #{conn.resp_body}"
    end

    refute_received {:realm_probe, _realm}

    # A unique-column value: a generated realm, so a leftover row can never collide with a later run.
    value = realm()
    resp = onboard!(ctx, %{"idp_realm_id" => " " <> value <> " "})

    assert stored_realm(resp["tenant_id"]) == value
    assert resp["login"]["idp_realm_id"] == value
    assert_received {:realm_probe, ^value}
  end

  test "an idp_realm_id validation error never echoes the received value", ctx do
    leaky = String.duplicate("Q", 65)

    for value <- [%{"leak" => "zzREALMLEAKzz"}, leaky, "has space zzLEAKzz"] do
      conn = refused!(ctx, %{"idp_realm_id" => value}, 422)

      assert field_error_on?(conn, "idp_realm_id")
      refute conn.resp_body =~ "zzREALMLEAKzz"
      refute conn.resp_body =~ "zzLEAKzz"
      refute conn.resp_body =~ "QQQQQ"
    end
  end

  test "a validated realm reaches the probe URL path unchanged (trimmed, not escaped)", ctx do
    Server.use_real_probe!()

    server =
      Server.start(fn _request -> {:respond, [Server.response(404, [], "")]} end, [])

    Server.put_base_url!(server.base_url)

    # Trimmed first, then built into the URL; the allowed alphabet needs no escaping.
    conn = refused!(ctx, %{"idp_realm_id" => " Real_m-9X "}, 422)

    assert field_error?(conn, "idp_realm_id", "not_found")
    assert_received {:realm_probe_server, :request, %{path: path}}
    assert path == "/realms/Real_m-9X/.well-known/openid-configuration"
  end

  test "POST /onboarding with an idp_realm_id already bound to another tenant answers 409 and creates no tenant row",
       ctx do
    held = realm()
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-held", idp_realm_id: held)

    conn = refused!(ctx, %{"idp_realm_id" => held}, 409)

    assert json(conn)["detail"] == "realm already bound"
    refute conn.resp_body =~ other.tenant_id
    refute conn.resp_body =~ other.tenant.slug
    assert stored_realm(other.tenant_id) == held
  end

  # The hostname is pre-checked: the 409 is answered before any row is written, so no tenant is left
  # behind and the realm stays free (SECURITY-REVIEWER MAJOR-2).
  test "POST /onboarding with a realm and a taken hostname answers 409 and creates no tenant",
       ctx do
    first = onboard!(ctx, %{})
    slug = Letflow.TenantSlugFixture.unique_slug("iss1030")
    free = realm()

    conn =
      call(ctx, :post, "/api/v1/onboarding", %{
        "slug" => slug,
        "display_name" => "ISS-1030 Tenant",
        "hostname" => first["hostname"],
        "idp_realm_id" => free
      })

    assert conn.status == 409
    assert json(conn)["detail"] == "hostname already bound"
    assert Repo.get_by(Tenant, slug: slug) == nil
    refute Repo.exists?(from(t in Tenant, where: t.idp_realm_id == ^free))

    # The realm is still free: a later create with a free hostname binds it.
    created = onboard!(ctx, %{"idp_realm_id" => free})
    assert created["login"]["loginable"] == true
    assert stored_realm(created["tenant_id"]) == free
  end

  # The authorization plug answers 403 before the handler's own prefix gate (design 3.2), so the
  # create-path gate is defence in depth: reachable only by a race, and pinned by mutant M12.
  test "POST /onboarding with a realm answers 403 before any write when the platform pin is another tenant",
       ctx do
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-plug-other")
    Fixture.pin!(other.tenant_id)

    refused!(ctx, %{"idp_realm_id" => realm()}, 403)
  end

  test "POST /onboarding whose realm is claimed by another tenant before the bind answers 201 with realm_request not_bound and keeps the record",
       ctx do
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-race-other")
    value = realm()
    slug = TenantSlugFixture.unique_slug("iss1030")

    conn =
      with_realm_claimed_after_registry_insert(other.tenant_id, value, fn ->
        call(
          ctx,
          :post,
          "/api/v1/onboarding",
          new_body(%{"slug" => slug, "idp_realm_id" => value})
        )
      end)

    assert conn.status == 201, conn.resp_body
    created = json(conn)
    cleanup_onboarded_tenant!(created["tenant_id"])

    assert created["login"]["loginable"] == false
    assert created["realm_request"] == %{"status" => "not_bound", "reason" => "taken"}
    assert stored_realm(created["tenant_id"]) == nil
    assert stored_realm(other.tenant_id) == value

    fetched = call(ctx, :get, "/api/v1/onboarding/#{created["id"]}", nil)
    assert fetched.status == 200
    assert json(fetched)["login"]["loginable"] == false
  end

  # A bind that cannot run because the tenant is no longer active (a state change after the onboarding
  # insert) is reported as realm_request reason "unavailable" in the 201 body.
  test "POST /onboarding whose tenant is not active when the bind runs answers 201 with realm_request unavailable",
       ctx do
    value = realm()
    slug = TenantSlugFixture.unique_slug("iss1030")
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.deactivate_on_registry_insert/4,
      {self(), slug}
    )

    conn =
      try do
        call(
          ctx,
          :post,
          "/api/v1/onboarding",
          new_body(%{"slug" => slug, "idp_realm_id" => value})
        )
      after
        :telemetry.detach(handler_id)
      end

    # Cleanup first, so a failing assertion still drops the schema (a non-201 body has no tenant_id: a no-op).
    created = json(conn)
    cleanup_onboarded_tenant!(created["tenant_id"])

    assert conn.status == 201, conn.resp_body
    assert created["realm_request"] == %{"status" => "not_bound", "reason" => "unavailable"}
    assert created["login"]["loginable"] == false
    assert stored_realm(created["tenant_id"]) == nil
  end

  @doc false
  def deactivate_on_registry_insert(_event, _measurements, metadata, {test_pid, slug}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and String.starts_with?(query, ~s(INSERT INTO "onboarding_registry")) and
         match?({:ok, _}, Map.get(metadata, :result)) do
      Repo.update_all(from(t in Tenant, where: t.slug == ^slug), set: [status: :inactive])
    end
  end

  # JSON cannot carry invalid UTF-8, and the harness encodes bodies as JSON, so the parsed body is set
  # directly, as multipart parsing would set it. A part name with invalid bytes must be refused with 422
  # before any write (SECURITY-REVIEWER BLOCKER-1 on the create route).
  test "POST /onboarding with an invalid UTF-8 field name answers 422 and writes nothing", ctx do
    slug = TenantSlugFixture.unique_slug("iss1030")
    hostname = "iss1030-#{Ecto.UUID.generate()}.example.com"
    value = realm()

    body = %{
      "slug" => slug,
      "display_name" => "ISS-1030 Tenant",
      "hostname" => hostname,
      "idp_realm_id" => value,
      <<0xFF, 0xFE>> => "x"
    }

    conn =
      :post
      |> Fixture.api_conn("/api/v1/onboarding", ctx.token, ctx.platform.tenant.slug, nil)
      |> Map.put(:body_params, body)
      |> Map.put(:params, body)
      |> Fixture.dispatch_api()

    assert conn.status == 422, conn.resp_body

    assert json(conn)["errors"] == [
             %{
               "field" => "(root)",
               "constraint" => "encoding",
               "message" => "field names must be valid UTF-8",
               "received" => nil
             }
           ]

    assert Repo.get_by(Tenant, slug: slug) == nil
    assert Repo.get_by(OnboardingRecord, hostname: hostname) == nil
    refute Repo.exists?(from(t in Tenant, where: t.idp_realm_id == ^value))
  end

  # The validator counts graphemes and the column counts code points: 255 graphemes made of a letter and
  # a combining mark is 510 code points. It must be refused with 422 before any write (SECURITY-REVIEWER F1).
  test "POST /onboarding with a hostname over 255 code points answers 422 and creates no tenant",
       ctx do
    slug = Letflow.TenantSlugFixture.unique_slug("iss1030")
    hostname = String.duplicate("é", 255)

    conn =
      call(ctx, :post, "/api/v1/onboarding", new_body(%{"slug" => slug, "hostname" => hostname}))

    assert conn.status == 422, conn.resp_body
    assert field_error_on?(conn, "hostname")
    assert Repo.get_by(Tenant, slug: slug) == nil
    assert Repo.get_by(OnboardingRecord, hostname: hostname) == nil
  end

  test "POST /onboarding with a display_name over 255 code points answers 422 and creates no tenant",
       ctx do
    slug = Letflow.TenantSlugFixture.unique_slug("iss1030")
    display_name = String.duplicate("é", 255)

    conn =
      call(
        ctx,
        :post,
        "/api/v1/onboarding",
        new_body(%{"slug" => slug, "display_name" => display_name})
      )

    assert conn.status == 422, conn.resp_body
    assert field_error_on?(conn, "display_name")
    assert Repo.get_by(Tenant, slug: slug) == nil
  end

  test "bind-realm records the request's x-trace-id in the platform chain and never in the tenant chain",
       ctx do
    resp = onboard!(ctx, %{})
    bound = realm()

    conn =
      :post
      |> Fixture.api_conn(
        "/api/v1/onboarding/#{resp["id"]}/bind-realm",
        ctx.token,
        ctx.platform.tenant.slug,
        %{"idp_realm_id" => bound}
      )
      |> Plug.Conn.put_req_header("x-trace-id", "t-router-7")
      |> Fixture.dispatch_api()

    assert conn.status == 200, conn.resp_body
    assert [tenant_entry] = entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound")
    assert tenant_entry.trace_id == nil
    assert [platform_entry] = entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")
    assert platform_entry.trace_id == "t-router-7"
  end

  # SECURITY-REVIEWER R1: a hostname taken after the pre-check but before the onboarding insert answers 409,
  # and its detail says the tenant exists (it is committed and active). It must not read as "nothing created".
  test "POST /onboarding whose hostname is taken in the race window answers 409 and says the tenant was created",
       ctx do
    owner = onboard!(ctx, %{})
    slug = TenantSlugFixture.unique_slug("iss1030")
    rival_slug = TenantSlugFixture.unique_slug("iss1030")
    hostname = "iss1030-race-#{Ecto.UUID.generate()}.example.com"

    conn =
      with_hostname_taken_after_tenant_insert(owner["tenant_id"], rival_slug, hostname, fn ->
        call(
          ctx,
          :post,
          "/api/v1/onboarding",
          new_body(%{"slug" => slug, "hostname" => hostname})
        )
      end)

    tenant = Repo.get_by(Tenant, slug: slug)
    if tenant, do: cleanup_onboarded_tenant!(tenant.id)

    assert conn.status == 409, conn.resp_body
    assert json(conn)["detail"] =~ "the tenant for this slug was created"
    assert json(conn)["detail"] =~ "do not retry with a new slug"
  end

  test "POST /onboarding answers 500 with the after-commit detail when provisioning fails after the tenant was committed",
       ctx do
    slug = TenantSlugFixture.unique_slug("iss1030")
    hostname = "iss1030-post-commit-#{Ecto.UUID.generate()}.example.com"

    # The tenant row is removed right after its committed insert, so provisioning finds no tenant
    # and fails after the create's commit: the answer must say the tenant may exist (SECURITY-REVIEWER
    # F1). The removal is the forced failure; the answer under test is the one the router gives for it.
    conn =
      with_tenant_removed_after_insert(slug, fn ->
        call(
          ctx,
          :post,
          "/api/v1/onboarding",
          new_body(%{"slug" => slug, "hostname" => hostname})
        )
      end)

    # The hook removes the tenant, so none is expected; a tenant found here (the hook failed) is cleaned up.
    tenant = Repo.get_by(Tenant, slug: slug)
    if tenant, do: cleanup_onboarded_tenant!(tenant.id)

    assert conn.status == 500, conn.resp_body
    assert json(conn)["detail"] =~ "the tenant may exist"
    assert json(conn)["detail"] =~ "do not retry with a new slug"
    refute Repo.get_by(OnboardingRecord, hostname: hostname)
  end

  # The database faults inside provisioning, after the tenant is committed: the provisioning transaction
  # re-raises it, and the answer is the fixed post-commit 500 with a committed tenant behind it. The fault
  # is real (a trigger on tenant_schemas raises; see with_tenant_schema_insert_failing/1), not a stub.
  test "POST /onboarding answers 500 with the after-commit detail when the database faults during provisioning after the tenant was committed",
       ctx do
    slug = TenantSlugFixture.unique_slug("iss1030")
    hostname = "iss1030-raise-#{Ecto.UUID.generate()}.example.com"

    # Registered before the request: a request that raises out of the test still leaves no committed tenant.
    cleanup_slug_on_exit(slug)

    # The trigger is created outside the captured log, so the log holds only what the request itself logged.
    {conn, log} =
      with_tenant_schema_insert_failing(fn ->
        with_log(fn ->
          call(
            ctx,
            :post,
            "/api/v1/onboarding",
            new_body(%{"slug" => slug, "hostname" => hostname})
          )
        end)
      end)

    assert conn.status == 500, conn.resp_body
    assert json(conn)["detail"] =~ "the tenant may exist"
    assert json(conn)["detail"] =~ "do not retry with a new slug"

    # The fault's message reaches neither the answer nor Letflow's own log line (INV-4). Letflow's line is one
    # line by construction (the log call concatenates its parts), so the match below reads that whole line.
    # Without these, a wrong implementation that echoed the exception text would still pass the detail check.
    refute conn.resp_body =~ "injected database fault"
    [letflow_line] = Regex.run(~r/onboarding failed after the tenant was committed[^\n]*/, log)
    assert letflow_line =~ "exception=Postgrex.Error"
    refute letflow_line =~ "injected database fault"
    assert %Tenant{status: :migrating} = Repo.get_by(Tenant, slug: slug)
    refute Repo.get_by(OnboardingRecord, hostname: hostname)
  end

  test "POST /onboarding with a whitespace-only hostname answers 422 and creates no tenant",
       ctx do
    refused!(ctx, %{"hostname" => "   "}, 422)
  end

  # The hostname is trimmed before the duplicate pre-check, so a padded value that matches a bound hostname is
  # answered 409 before any write (TEST-DESIGN-VALIDATOR B1, the padded case).
  test "POST /onboarding with a padded hostname that is already bound answers 409 and creates no tenant",
       ctx do
    hostname = "iss1030-padded-#{Ecto.UUID.generate()}.example.com"
    _owner = onboard!(ctx, %{"hostname" => hostname})
    slug = TenantSlugFixture.unique_slug("iss1030")

    conn =
      call(
        ctx,
        :post,
        "/api/v1/onboarding",
        new_body(%{"slug" => slug, "hostname" => "  " <> hostname <> "  "})
      )

    assert conn.status == 409, conn.resp_body
    assert json(conn)["detail"] == "hostname already bound"
    assert Repo.get_by(Tenant, slug: slug) == nil
  end

  test "POST /onboarding answers 503 with a retry-after header of 5 and creates no tenant row when the realm probe is unreachable",
       ctx do
    conn = refused!(ctx, %{"idp_realm_id" => "unreachable-" <> Ecto.UUID.generate()}, 503)

    assert get_resp_header(conn, "retry-after") == ["5"]
    assert json(conn)["status"] == 503
  end

  test "GET /onboarding/:id and GET /onboarding?hostname= mark a tenant without a realm as not_yet_loginable with next steps",
       ctx do
    resp = onboard!(ctx, %{})

    by_id = call(ctx, :get, "/api/v1/onboarding/#{resp["id"]}", nil)
    by_hostname = call(ctx, :get, "/api/v1/onboarding?hostname=#{resp["hostname"]}", nil)

    for conn <- [by_id, by_hostname] do
      assert conn.status == 200

      assert %{
               "loginable" => false,
               "status" => "not_yet_loginable",
               "idp_realm_id" => nil,
               "next_steps" => [step]
             } = json(conn)["login"]

      assert step =~ @runbook
      assert step =~ "bind-realm"
      # `administrator` is only in the 201 body, never in the GET maps (design section 3).
      refute Map.has_key?(json(conn), "administrator")
    end

    # The same record, once bound, reads loginable through both routes.
    bound = realm()
    assert bind(ctx, resp["id"], bound).status == 200

    paths = [
      "/api/v1/onboarding/#{resp["id"]}",
      "/api/v1/onboarding?hostname=#{resp["hostname"]}"
    ]

    for path <- paths do
      conn = call(ctx, :get, path, nil)

      assert %{"loginable" => true, "status" => "realm_bound", "idp_realm_id" => ^bound} =
               json(conn)["login"]
    end
  end

  # --- bind-realm (design 3.2) --------------------------------------------------

  test "POST /onboarding/:id/bind-realm binds the realm once, answers 200 and writes a tenant.idp_realm.bound audit entry",
       ctx do
    resp = onboard!(ctx, %{})
    bound = realm()

    conn = bind(ctx, resp["id"], bound)

    assert conn.status == 200
    body = json(conn)
    assert body["id"] == resp["id"]
    assert body["tenant_id"] == resp["tenant_id"]

    assert body["login"] == %{
             "loginable" => true,
             "status" => "realm_bound",
             "idp_realm_id" => bound,
             "next_steps" => []
           }

    assert stored_realm(resp["tenant_id"]) == bound
    assert [_one] = entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound")
  end

  test "POST /onboarding/:id/bind-realm with the same realm again answers 200 and writes no second audit entry",
       ctx do
    resp = onboard!(ctx, %{})
    bound = realm()

    assert bind(ctx, resp["id"], bound).status == 200
    assert bind(ctx, resp["id"], bound).status == 200

    assert stored_realm(resp["tenant_id"]) == bound
    assert [_one] = entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound")
    assert [_one] = entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")
  end

  test "POST /onboarding/:id/bind-realm with a different realm after binding answers 409 and leaves the tenant unchanged",
       ctx do
    resp = onboard!(ctx, %{})
    first = realm()
    assert bind(ctx, resp["id"], first).status == 200

    conn = bind(ctx, resp["id"], realm())

    assert conn.status == 409
    assert json(conn)["detail"] == "realm already bound"
    assert stored_realm(resp["tenant_id"]) == first
    assert [_one] = entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound")
  end

  test "POST /onboarding/:id/bind-realm with an unknown realm answers 422 and leaves the tenant unchanged",
       ctx do
    resp = onboard!(ctx, %{})

    conn = bind(ctx, resp["id"], "unknown-realm-" <> Ecto.UUID.generate())

    assert conn.status == 422
    assert field_error?(conn, "idp_realm_id", "not_found")
    assert stored_realm(resp["tenant_id"]) == nil
    assert entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound") == []
  end

  test "POST /onboarding/:id/bind-realm validates the realm like onboarding does and answers 503 when the probe is unreachable",
       ctx do
    resp = onboard!(ctx, %{})

    invalid = [{"   ", "not_blank"}, {"a.b", "format"}, {"master", "reserved"}]

    for {value, constraint} <- invalid do
      conn = bind(ctx, resp["id"], value)
      assert conn.status == 422
      assert field_error?(conn, "idp_realm_id", constraint), "value #{inspect(value)}"
    end

    missing = call(ctx, :post, "/api/v1/onboarding/#{resp["id"]}/bind-realm", %{})
    assert missing.status == 422
    assert field_error?(missing, "idp_realm_id", "required")

    refute_received {:realm_probe, _realm}

    unreachable = bind(ctx, resp["id"], "unreachable-" <> Ecto.UUID.generate())
    assert unreachable.status == 503
    assert get_resp_header(unreachable, "retry-after") == ["5"]

    assert stored_realm(resp["tenant_id"]) == nil
  end

  test "POST /onboarding/:id/bind-realm on a tenant that became non-active answers 409 even for the realm already stored",
       ctx do
    resp = onboard!(ctx, %{})
    bound = realm()
    assert bind(ctx, resp["id"], bound).status == 200

    set_status!(resp["tenant_id"], :inactive)

    conn = bind(ctx, resp["id"], bound)
    assert conn.status == 409
    assert json(conn)["detail"] == "tenant is not active"
    assert stored_realm(resp["tenant_id"]) == bound
  end

  test "POST /onboarding/:id/bind-realm issues no tenant read after the bind commits", ctx do
    resp = onboard!(ctx, %{})
    bound = realm()
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.forward_query_sql/4,
      test_pid
    )

    try do
      assert bind(ctx, resp["id"], bound).status == 200
    after
      :telemetry.detach(handler_id)
    end

    statements = drain_query_sql([])
    update_index = Enum.find_index(statements, &String.contains?(&1, ~s(UPDATE "tenants")))
    assert is_integer(update_index), "the bind did not write the tenant row"

    after_commit = Enum.drop(statements, update_index + 1)

    refute Enum.any?(after_commit, &String.contains?(&1, ~s(FROM "tenants"))),
           "a tenant read ran after the bind commit: #{inspect(after_commit)}"
  end

  @doc false
  def forward_query_sql(_event, _measurements, metadata, test_pid) do
    if self() == test_pid do
      send(test_pid, {:query_sql, to_string(Map.get(metadata, :query) || "")})
    end
  end

  defp drain_query_sql(acc) do
    receive do
      {:query_sql, sql} -> drain_query_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "POST /onboarding/:id/bind-realm for a nonexistent onboarding id answers 404", ctx do
    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      conn = bind(ctx, id, realm())

      assert conn.status == 404, "id #{inspect(id)}: #{conn.status}"
    end
  end

  test "POST /onboarding/:id/bind-realm on a deactivated or migrating tenant answers 409 tenant is not active with identical bytes and writes nothing",
       ctx do
    responses =
      for status <- [:inactive, :migrating] do
        resp = onboard!(ctx, %{})
        set_status!(resp["tenant_id"], status)

        conn = bind(ctx, resp["id"], realm())

        assert conn.status == 409
        assert json(conn)["detail"] == "tenant is not active"
        assert stored_realm(resp["tenant_id"]) == nil
        assert entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound") == []
        stable_body(conn)
      end

    assert [same, same] = responses
    assert entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound") == []
  end

  test "POST /onboarding/:id/bind-realm 409 for a realm bound to another tenant names no tenant",
       ctx do
    held = realm()
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-held", idp_realm_id: held)

    # A tenant with no realm yet tries to take the other tenant's realm ...
    fresh = onboard!(ctx, %{})
    elsewhere = bind(ctx, fresh["id"], held)

    # ... and a tenant that already has a (different) realm tries the same.
    bound = onboard!(ctx, %{})
    assert bind(ctx, bound["id"], realm()).status == 200
    different = bind(ctx, bound["id"], held)

    for conn <- [elsewhere, different] do
      assert conn.status == 409
      assert json(conn)["detail"] == "realm already bound"
      refute conn.resp_body =~ other.tenant_id
      refute conn.resp_body =~ other.tenant.slug
      refute conn.resp_body =~ other.schema_name
    end

    # Both causes answer the same bytes.
    assert stable_body(elsewhere) == stable_body(different)
    assert stored_realm(fresh["tenant_id"]) == nil
    assert stored_realm(other.tenant_id) == held
  end

  test "bind-realm writes a tenant-chain entry with a NIL actor and a platform-chain entry with the operator id",
       ctx do
    resp = onboard!(ctx, %{})
    bound = realm()
    assert bind(ctx, resp["id"], bound).status == 200

    assert [tenant_entry] = entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound")
    assert tenant_entry.actor_id == nil
    assert tenant_entry.resource_id == resp["tenant_id"]
    # No operator-chosen trace id in the tenant chain (tenant admins read it).
    assert tenant_entry.trace_id == nil

    assert tenant_entry.after_state == %{
             "idp_realm_id" => bound,
             "actor_class" => "platform_operator"
           }

    refute inspect(tenant_entry) =~ ctx.operator_id

    assert [platform_entry] = entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")
    assert platform_entry.actor_id == ctx.operator_id
    assert platform_entry.resource_id == resp["tenant_id"]
    assert platform_entry.after_state["tenant_id"] == resp["tenant_id"]
    assert platform_entry.after_state["idp_realm_id"] == bound
    assert platform_entry.after_state["onboarding_id"] == resp["id"]
  end

  test "POST /onboarding/:id/bind-realm answers the fixed 500 and writes nothing when the platform prefix differs from the caller's tenant prefix",
       ctx do
    resp = onboard!(ctx, %{})
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-other-plat")

    # The gate (platform scope) passes against the real pin; the pin is moved to
    # another tenant right after the onboarding record is read, so the handler's
    # own `PlatformTenant.platform_prefix/0` no longer equals the caller's prefix.
    {conn, log} =
      with_log(fn ->
        with_pin_change({:pin, other.tenant_id}, fn -> bind(ctx, resp["id"], realm()) end)
      end)

    assert conn.status == 500
    assert json(conn)["status"] == 500
    refute conn.resp_body =~ other.tenant_id
    refute conn.resp_body =~ ctx.platform.tenant_id
    # SQL debug lines carry the ids as query parameters, so the invariant is scoped
    # to what the request path logs at warning/error level.
    ids = Enum.map_join([other.tenant_id, ctx.platform.tenant_id], "|", &Regex.escape/1)
    refute Regex.match?(~r/\[(warning|error)\][^\n]*(#{ids})/, log)
    # The fault is still logged (design 3.4: a real fault is logged, with fixed text).
    assert log =~ "[error] operator realm bind refused: platform prefix check failed"

    assert stored_realm(resp["tenant_id"]) == nil
    assert entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound") == []
    assert entries(other.schema_name, "platform.tenant_idp_realm.bound") == []
  end

  test "POST /onboarding/:id/bind-realm answers the fixed 500 and writes nothing when no platform tenant is configured",
       ctx do
    resp = onboard!(ctx, %{})

    {conn, log} =
      with_log(fn -> with_pin_change(:unpin, fn -> bind(ctx, resp["id"], realm()) end) end)

    assert conn.status == 500
    assert json(conn)["status"] == 500
    refute conn.resp_body =~ ctx.platform.tenant_id
    assert log =~ "[error] operator realm bind refused: platform prefix check failed"

    assert stored_realm(resp["tenant_id"]) == nil
    assert entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound") == []
  end

  test "POST /onboarding/:id/bind-realm by an admin of another tenant answers the uniform 403, byte-identical for a matched and an unmatched path",
       ctx do
    resp = onboard!(ctx, %{})
    outsider = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-outsider")
    outsider_token = Fixture.mint_token!(outsider, ["TENANT_ADMIN"])

    as_outsider = fn method, path, body ->
      method
      |> Fixture.api_conn(path, outsider_token, outsider.tenant.slug, body)
      |> Fixture.dispatch_api()
    end

    bind_body = %{"idp_realm_id" => realm()}

    matched =
      as_outsider.(:post, "/api/v1/onboarding/#{resp["id"]}/bind-realm", bind_body)

    unknown_id =
      as_outsider.(:post, "/api/v1/onboarding/#{Ecto.UUID.generate()}/bind-realm", bind_body)

    unmatched = as_outsider.(:post, "/api/v1/onboarding/x/y/z", bind_body)

    for conn <- [matched, unknown_id, unmatched], do: assert(conn.status == 403)

    assert stable_body(matched) == stable_body(unknown_id)
    assert stable_body(matched) == stable_body(unmatched)
    refute matched.resp_body =~ resp["tenant_id"]

    # INV-10: nothing was written for the target tenant, in either chain.
    assert stored_realm(resp["tenant_id"]) == nil
    assert entries(schema_of(resp["tenant_id"]), "tenant.idp_realm.bound") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound") == []
    assert entries(outsider.schema_name, "platform.tenant_idp_realm.bound") == []
  end

  test "after bind-realm a token from that realm resolves the tenant and a tenant without a realm cannot be resolved",
       ctx do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

    resp = onboard!(ctx, %{})
    bound = realm()

    token_call = fn ->
      conn(:post, "/whatever")
      |> put_req_header("authorization", "Bearer realm-token:#{bound}:sub=iss1030-subject")
      |> AuthPipeline.call(AuthPipeline.init([]))
    end

    # Before the bind the tenant has no realm, so no tenant resolves it and the token is rejected.
    assert Repo.get!(Tenant, resp["tenant_id"]).idp_realm_id == nil
    assert {:error, :not_found} = Letflow.Identity.resolve_tenant_by_realm(bound)
    before_bind = token_call.()
    assert before_bind.halted
    assert before_bind.status == 401

    assert bind(ctx, resp["id"], bound).status == 200

    # After the bind the SAME token resolves the onboarded tenant.
    after_bind = token_call.()
    refute after_bind.halted, "status #{inspect(after_bind.status)}: #{after_bind.resp_body}"
    assert after_bind.assigns.auth_context.tenant_id == resp["tenant_id"]
  end

  # --- telemetry seam: change the platform pin mid-request -----------------------

  # Runs `fun` with a `[:letflow, :repo, :query]` handler that changes the
  # platform-tenant pin on the FIRST query that reads `onboarding_registry` in
  # the calling process. The bind-realm handler issues that read after the
  # platform-scope gate and before its own platform-prefix check, so this is the
  # only way to make the two disagree through a real request (the gate and the
  # accessor read the same configuration). The fixture's `on_exit` restores the
  # original pin.
  defp with_pin_change(action, fun) do
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.change_pin_on_registry_read/4,
      {self(), action}
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  # Claims the realm for another tenant right after the create's onboarding-record insert, so the
  # create's own bind loses the race (after the pre-check, before the bind). Calling process only.
  # The claim is an UPDATE: its telemetry event re-enters this handler, but it does not match the INSERT
  # filter, so the nested call does nothing.
  defp with_realm_claimed_after_registry_insert(tenant_id, realm_value, fun) do
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.claim_realm_on_registry_insert/4,
      {self(), tenant_id, realm_value}
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def claim_realm_on_registry_insert(
        _event,
        _measurements,
        metadata,
        {test_pid, tenant_id, value}
      ) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and String.starts_with?(query, ~s(INSERT INTO "onboarding_registry")) and
         match?({:ok, _}, Map.get(metadata, :result)) do
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id), set: [idp_realm_id: value])
    end
  end

  # Takes the hostname right after the create's tenant insert, so the create's own onboarding insert loses the
  # race (after the pre-check, before the onboarding record). Calling process only. Runs once per test.
  defp with_hostname_taken_after_tenant_insert(owner_tenant_id, slug, hostname, fun) do
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.take_hostname_on_tenant_insert/4,
      {self(), owner_tenant_id, slug, hostname}
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def take_hostname_on_tenant_insert(
        _event,
        _measurements,
        metadata,
        {test_pid, owner_tenant_id, slug, hostname}
      ) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and String.starts_with?(query, ~s(INSERT INTO "tenants")) and
         match?({:ok, _}, Map.get(metadata, :result)) do
      Repo.insert_all(OnboardingRecord, [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: owner_tenant_id,
          slug: slug,
          hostname: hostname,
          inserted_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        }
      ])
    end
  end

  # Removes the tenant right after the create's committed tenant insert, so provisioning fails after the
  # commit. Calling process only. Runs once per test (the handler is detached in `after`).
  defp with_tenant_removed_after_insert(slug, fun) do
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.remove_tenant_on_insert/4,
      {self(), slug}
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def remove_tenant_on_insert(_event, _measurements, metadata, {test_pid, slug}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and String.starts_with?(query, ~s(INSERT INTO "tenants")) and
         match?({:ok, _}, Map.get(metadata, :result)) do
      Repo.delete_all(from(t in Tenant, where: t.slug == ^slug))
    end
  end

  # Makes every insert into tenant_schemas raise, so provisioning raises inside the request after the tenant
  # commit. A real database fault: the trigger raises, and the provisioning transaction re-raises it. The
  # sandbox in this module commits (see cleanup_onboarded_tenant!/1), so the trigger and its function are
  # dropped on exit, including when the request raises.
  defp with_tenant_schema_insert_failing(fun) do
    # The restore is registered first, so ExUnit's LIFO order runs it last, after the drop below and after
    # every other cleanup that needs autocommit (see Letflow.Test.SandboxAutoMode). The mode is set through
    # the helper, not inline: Sandbox.mode/2 is pool-wide.
    on_exit(fn -> Letflow.Test.SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)
    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    # The drop runs on exit, not in an `after` block, so it also runs when the test process is killed or
    # the request raises. It also runs once before the create, to clear a trigger a killed run left behind.
    drop = fn ->
      Repo.query!("DROP TRIGGER IF EXISTS letflow_iss1030_fail_insert ON tenant_schemas")
      Repo.query!("DROP FUNCTION IF EXISTS letflow_iss1030_fail_insert()")
    end

    drop.()
    on_exit(drop)

    Repo.query!(
      "CREATE FUNCTION letflow_iss1030_fail_insert() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected database fault (ISS-1030 test)'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER letflow_iss1030_fail_insert BEFORE INSERT ON tenant_schemas FOR EACH ROW EXECUTE FUNCTION letflow_iss1030_fail_insert()"
    )

    fun.()
  end

  @doc false
  def change_pin_on_registry_read(_event, _measurements, metadata, {test_pid, action}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and Process.get(:iss1030_pin_changed) != true and
         String.contains?(query, "onboarding_registry") do
      Process.put(:iss1030_pin_changed, true)

      case action do
        {:pin, tenant_id} -> Fixture.pin!(tenant_id)
        :unpin -> Fixture.unpin!()
      end
    end

    :ok
  end

  # PR1 scope guard for AC5 (ISS-1030). Narrow on purpose: it scans only the PR 1 modules and fails on
  # a Keycloak admin realm or user call. Remove or replace it when Q-1061 / GH #2414 (decision gate) lands.
  test "PR 1 modules make no Keycloak admin realm or user call (AC5 scope guard)" do
    # No module under lib names a Keycloak admin realm or user path.
    for path <- Path.wildcard("lib/**/*.ex"), pattern <- [~r{/admin/realms}, ~r{/admin/users}] do
      refute File.read!(path) =~ pattern, "#{path} matches #{inspect(pattern)}"
    end

    # The PR 1 modules make no outbound write call through any HTTP client.
    outbound_write =
      ~r{:httpc\.request\(:(post|put|patch|delete)|Req\.(post|put|patch|delete|request)\(|HTTPoison\.|Finch\.|Tesla\.}

    for path <-
          ~w(lib/letflow/routers/onboarding.ex lib/letflow/identity.ex lib/letflow/identity/tenant.ex
                   lib/letflow/platform_tenant.ex lib/letflow/api/authorization.ex lib/letflow/oidc/realm_probe.ex) do
      refute File.read!(path) =~ outbound_write, path
    end

    # The probe is the only outbound request of PR 1: one GET through :httpc.
    probe_source = File.read!("lib/letflow/oidc/realm_probe.ex")
    assert length(Regex.scan(~r{:httpc\.request\(}, probe_source)) == 1
    assert probe_source =~ ~r{:httpc\.request\(:get, }
  end

  # AC3 (design section 11): the operator runbook exists and names the steps it must.
  test "the onboarding runbook exists and references T-0150, T-0158 and bind-realm" do
    runbook = File.read!(@runbook)

    for reference <- ["T-0150", "T-0158", "bind-realm"] do
      assert runbook =~ reference
    end

    # The realm and first-administrator steps, and the activate step: activation is automatic.
    assert runbook =~ "Create the realm"
    assert runbook =~ "Create the first administrator"
    assert runbook =~ "Activation is automatic"
  end
end
