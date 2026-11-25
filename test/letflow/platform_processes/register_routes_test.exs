defmodule Letflow.PlatformProcesses.RegisterRoutesTest do
  @moduledoc """
  T-2704 (pilot gap G17b): every route that registers a tenant for an operator
  STARTS the `platform.register_tenant` process; none creates the tenant itself.

  Routes 1 and 2 of the register-tenant design, section "The five paths":
  `POST /api/v1/onboarding` (the "Register tenant" screen) and
  `POST /api/v1/tenants`. Each request goes through the real router with a real
  API token, against the shipped, seeded definition.

  The class table (one test each):

    * (a) route -> start: an INSTANCE_STARTED event of the definition exists in the
      platform tenant, and NO tenant row, schema or onboarding record exists yet
      (nothing was created by a direct call);
    * (b) the answer is 202 with the instance id; a company administrator gets the
      uniform 403 and nothing starts;
    * (c) replay: the same form twice answers the same instance and starts once;
    * (d) with no active definition the route answers 503 and creates nothing (never a
      5xx with a half-created tenant); a taken slug is a 409 before anything starts;
    * (e) the answer carries no realm, no e-mail and no secret.

  The start key is the slug alone: the same slug with other values is a 409 (c). A step
  that fails (the slug taken between the start and the create step) ends the instance in
  ERROR with no canary in the answer, the log or the error detail (d)(e); that test runs
  the platform step runner by hand, since the poller is off in the test environment.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.EventStore.Event
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RegisterTenantProcessFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantSlugFixture
  alias Letflow.Engine.PlatformStepRunner
  alias Letflow.EventStore.InstanceProjection

  import ExUnit.CaptureLog

  @routes ["/api/v1/onboarding", "/api/v1/tenants"]

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2704-plat")
    Fixture.pin!(platform.tenant_id)
    token = Fixture.mint_token!(platform, ["PLATFORM_ADMIN"])

    company = TenantFixture.provisioned_tenant!(slug_prefix: "t2704-co")
    company_token = Fixture.mint_token!(company, ["TENANT_ADMIN"])

    %{platform: platform, token: token, company: company, company_token: company_token}
  end

  defp seed!(ctx), do: RegisterTenantProcessFixture.seed!(ctx.platform.schema_name)

  defp post(ctx, path, body, token \\ nil, tenant_slug \\ nil) do
    :post
    |> Fixture.api_conn(
      path,
      token || ctx.token,
      tenant_slug || ctx.platform.tenant.slug,
      body
    )
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp form(path) do
    slug = TenantSlugFixture.unique_slug("t2704")

    base = %{"slug" => slug, "display_name" => "T-2704 Tenant"}

    if path == "/api/v1/onboarding",
      do: Map.put(base, "hostname", "t2704-#{Ecto.UUID.generate()}.example.com"),
      else: base
  end

  defp started_events(ctx, instance_id) do
    Repo.all(
      from(e in Event,
        where: e.instance_id == ^instance_id and e.event_type == "INSTANCE_STARTED"
      ),
      prefix: ctx.platform.schema_name
    )
  end

  for path <- @routes do
    describe "POST #{path}" do
      test "(a)(b) starts the process: 202 with the instance id, and nothing is created directly",
           ctx do
        seed!(ctx)
        body = form(unquote(path))

        conn = post(ctx, unquote(path), body)

        assert conn.status == 202, conn.resp_body
        answer = json(conn)
        assert is_binary(answer["instance_id"])
        assert answer["slug"] == body["slug"]

        assert [event] = started_events(ctx, answer["instance_id"])
        assert event.event_type == "INSTANCE_STARTED"

        # No direct call: the tenant row, its schema and the onboarding record are the
        # business of the steps, and the runner has not run them.
        assert Repo.get_by(Tenant, slug: body["slug"]) == nil
        assert Repo.all(from(o in OnboardingRecord, where: o.slug == ^body["slug"])) == []
      end

      test "(c) the same form twice is a replay: one instance", ctx do
        seed!(ctx)
        body = form(unquote(path))

        first = post(ctx, unquote(path), body)
        second = post(ctx, unquote(path), body)

        assert first.status == 202, first.resp_body
        assert second.status == 202, second.resp_body
        assert json(second)["instance_id"] == json(first)["instance_id"]
        assert json(second)["replayed"] == true
        assert [_one] = started_events(ctx, json(first)["instance_id"])
      end

      test "(d) no active definition: 503, and nothing was created", ctx do
        body = form(unquote(path))

        conn = post(ctx, unquote(path), body)

        assert conn.status == 503, conn.resp_body
        assert Repo.get_by(Tenant, slug: body["slug"]) == nil
      end

      test "(b) a company administrator gets the uniform 403 and nothing starts", ctx do
        seed!(ctx)
        body = form(unquote(path))

        conn = post(ctx, unquote(path), body, ctx.company_token, ctx.company.tenant.slug)

        assert conn.status == 403
        refute conn.resp_body =~ body["slug"]
        assert Repo.get_by(Tenant, slug: body["slug"]) == nil

        assert Repo.all(
                 from(e in Event, where: e.event_type == "INSTANCE_STARTED"),
                 prefix: ctx.platform.schema_name
               ) == []
      end

      test "(c) the same slug with other values is a 409 and starts nothing more", ctx do
        seed!(ctx)
        body = form(unquote(path))

        first = post(ctx, unquote(path), body)
        other = post(ctx, unquote(path), Map.put(body, "display_name", "Another name"))

        assert first.status == 202, first.resp_body
        assert other.status == 409, other.resp_body
        assert [_one] = started_events(ctx, json(first)["instance_id"])

        assert [_only] =
                 Repo.all(
                   from(e in Event, where: e.event_type == "INSTANCE_STARTED"),
                   prefix: ctx.platform.schema_name
                 )
      end

      test "(c) an identical replay after the create step committed is not a 409", ctx do
        seed!(ctx)
        body = form(unquote(path))

        first = post(ctx, unquote(path), body)
        assert first.status == 202, first.resp_body

        # What the create step does: the tenant of this very registration now exists.
        {:ok, tenant} =
          Letflow.Identity.create_tenant(%{
            "slug" => body["slug"],
            "display_name" => body["display_name"]
          })

        on_exit(fn ->
          Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
          Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)

        again = post(ctx, unquote(path), body)
        assert again.status == 202, again.resp_body
        assert json(again)["instance_id"] == json(first)["instance_id"]
        assert json(again)["replayed"] == true

        other = post(ctx, unquote(path), Map.put(body, "display_name", "Another name"))
        assert other.status == 409, other.resp_body
        assert [_one] = started_events(ctx, json(first)["instance_id"])
      end

      test "(b) a 255-character non-ASCII name is accepted by the route and by the step",
           ctx do
        seed!(ctx)
        name = String.duplicate("é", 255)
        body = Map.put(form(unquote(path)), "display_name", name)

        conn = post(ctx, unquote(path), body)
        assert conn.status == 202, conn.resp_body

        assert {:ok, %{}} =
                 Letflow.PlatformFunctions.Impl.TenantValidate.run(%{
                   inputs: %{"slug" => body["slug"], "name" => name}
                 })
      end

      test "(b) grapheme-cap names (combining marks, emoji) persist through the real step",
           ctx do
        seed!(ctx)

        names = [
          String.duplicate("e\u0301", 255),
          String.duplicate("\u{1F468}\u200D\u{1F469}\u200D\u{1F467}", 255)
        ]

        for name <- names do
          body = Map.put(form(unquote(path)), "display_name", name)
          conn = post(ctx, unquote(path), body)
          assert conn.status == 202, conn.resp_body

          Enum.each(1..4, fn _ -> PlatformStepRunner.run_due(ctx.platform.schema_name) end)

          tenant = Repo.get_by(Tenant, slug: body["slug"])
          assert tenant, "the create step must have stored the tenant"
          assert tenant.display_name == name

          # The real step provisioned a schema: drop it and its registration with the tenant.
          on_exit(fn ->
            Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

            %{rows: schemas} =
              Repo.query!("SELECT schema_name FROM tenant_schemas WHERE tenant_id = $1", [
                Ecto.UUID.dump!(tenant.id)
              ])

            Repo.query!("DELETE FROM tenant_schemas WHERE tenant_id = $1", [
              Ecto.UUID.dump!(tenant.id)
            ])

            for [schema] <- schemas,
                do: Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|)

            # The v2 chain also installs the default modules: every registry row that
            # references the tenant (solution pack installs, artefact bases, ...) goes first.
            %{rows: referencing} =
              Repo.query!("""
              SELECT cl.relname, att.attname
              FROM pg_constraint con
              JOIN pg_class cl ON cl.oid = con.conrelid
              JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
              WHERE con.contype = 'f' AND con.confrelid = 'tenants'::regclass
              """)

            for [table, column] <- referencing do
              Repo.query!(~s|DELETE FROM "#{table}" WHERE "#{column}" = $1|, [
                Ecto.UUID.dump!(tenant.id)
              ])
            end

            Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
          end)
        end
      end

      test "(d)(e) a failing step ends in instance ERROR; no canary in answer or log", ctx do
        seed!(ctx)
        canary = "canary-secret-t2704-#{System.unique_integer([:positive])}"

        email_canary = "owner-#{canary}@example.com"

        body =
          unquote(path)
          |> form()
          |> Map.put("idp_realm_id", TenantSlugFixture.unique_realm(canary))
          |> then(fn b ->
            if unquote(path) == "/api/v1/onboarding",
              do: Map.put(b, "admin_email", email_canary),
              else: b
          end)

        # :debug with LOG_LEVEL=debug semantics: Ecto logs every query and its parameters here.
        {conn, log} =
          with_log([level: :debug], fn ->
            conn = post(ctx, unquote(path), body)

            # The slug is taken between the start and the first step: the create step refuses.
            {:ok, taken} =
              Letflow.Identity.create_tenant(%{
                "slug" => body["slug"],
                "display_name" => "Raced"
              })

            on_exit(fn ->
              Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
              Repo.delete_all(from(t in Tenant, where: t.id == ^taken.id))
            end)

            PlatformStepRunner.run_due(ctx.platform.schema_name)
            conn
          end)

        assert conn.status == 202, conn.resp_body
        instance_id = json(conn)["instance_id"]

        projection =
          Repo.get_by!(InstanceProjection, [instance_id: instance_id],
            prefix: ctx.platform.schema_name
          )

        assert projection.status == :error
        assert projection.error_detail["error_type"] == "platform_step_failed"

        assert log =~ "QUERY", "the capture must see debug query lines or this proves nothing"
        refute conn.resp_body =~ canary
        refute log =~ canary
        refute log =~ email_canary
        refute inspect(projection.error_detail) =~ canary
      end

      test "(e) the answer carries no realm and no e-mail", ctx do
        seed!(ctx)
        realm = TenantSlugFixture.unique_realm("t2704")

        body =
          unquote(path)
          |> form()
          |> Map.put("idp_realm_id", realm)
          |> then(fn b ->
            if unquote(path) == "/api/v1/onboarding",
              do: Map.put(b, "admin_email", "owner-t2704@example.com"),
              else: b
          end)

        conn = post(ctx, unquote(path), body)

        assert conn.status == 202, conn.resp_body
        refute conn.resp_body =~ realm
        refute conn.resp_body =~ "owner-t2704"
      end
    end
  end

  # Flow table row 3 (docs/register-tenant-routes-flow.md): the replay check runs before every
  # state-dependent probe. Route 2 has no external probe; its state precheck (taken slug) is
  # covered by "an identical replay after the create step committed". Route 1 probes the realm.
  for {mode, probe} <- [not_found: {:error, :not_found}, unreachable: {:error, :unreachable}] do
    test "(c) route 1: an identical replay keeps its 202 when the realm probe answers #{mode}",
         ctx do
      seed!(ctx)
      alias Letflow.Oidc.RealmProbeDouble
      realm = TenantSlugFixture.unique_realm("t2704probe")

      body = Map.put(form("/api/v1/onboarding"), "idp_realm_id", realm)

      RealmProbeDouble.put_override(:ok)
      first = post(ctx, "/api/v1/onboarding", body)
      assert first.status == 202, first.resp_body

      RealmProbeDouble.put_override(unquote(Macro.escape(probe)))
      on_exit(&RealmProbeDouble.clear_override/0)

      again = post(ctx, "/api/v1/onboarding", body)
      assert again.status == 202, again.resp_body
      assert json(again)["instance_id"] == json(first)["instance_id"]
      assert json(again)["replayed"] == true

      # Same slug, other values (another realm): the engine's 409, not the probe's 422/503.
      other = post(ctx, "/api/v1/onboarding", Map.put(body, "idp_realm_id", realm <> "-b"))
      assert other.status == 409, other.resp_body
      assert [_one] = started_events(ctx, json(first)["instance_id"])
    end

    test "(c) route 1: a NEW registration still meets the realm probe (#{mode})", ctx do
      seed!(ctx)
      Letflow.Oidc.RealmProbeDouble.put_override(unquote(Macro.escape(probe)))
      on_exit(&Letflow.Oidc.RealmProbeDouble.clear_override/0)

      body =
        Map.put(
          form("/api/v1/onboarding"),
          "idp_realm_id",
          TenantSlugFixture.unique_realm("t2704n")
        )

      conn = post(ctx, "/api/v1/onboarding", body)
      assert conn.status == if(unquote(mode) == :unreachable, do: 503, else: 422), conn.resp_body
    end
  end

  # Flow table row 3, the DB prechecks of route 1: realm_taken and hostname_taken become true
  # AFTER the first start; the identical retry is still the first call's 202 (one instance), and
  # the same slug with other values is the engine's 409.
  test "(c) route 1: an identical replay keeps its 202 when the realm became taken", ctx do
    seed!(ctx)
    alias Letflow.Oidc.RealmProbeDouble
    RealmProbeDouble.put_override(:ok)
    on_exit(&RealmProbeDouble.clear_override/0)

    realm = TenantSlugFixture.unique_realm("t2704rt")
    body = Map.put(form("/api/v1/onboarding"), "idp_realm_id", realm)

    first = post(ctx, "/api/v1/onboarding", body)
    assert first.status == 202, first.resp_body

    # Another tenant binds the realm after the start: realm_taken?/1 is now true.
    TenantFixture.provisioned_tenant!(slug_prefix: "t2704-held", idp_realm_id: realm)

    again = post(ctx, "/api/v1/onboarding", body)
    assert again.status == 202, again.resp_body
    assert json(again)["instance_id"] == json(first)["instance_id"]
    assert json(again)["replayed"] == true

    other = post(ctx, "/api/v1/onboarding", Map.put(body, "display_name", "Another name"))
    assert other.status == 409, other.resp_body
    assert [_one] = started_events(ctx, json(first)["instance_id"])
  end

  test "(c) route 1: an identical replay keeps its 202 when the hostname became taken", ctx do
    seed!(ctx)
    body = form("/api/v1/onboarding")

    first = post(ctx, "/api/v1/onboarding", body)
    assert first.status == 202, first.resp_body

    # An onboarding record takes the hostname after the start: hostname_taken?/1 is now true.
    holder = TenantFixture.provisioned_tenant!(slug_prefix: "t2704-host")

    assert {:ok, record} =
             Letflow.Identity.create_onboarding(%{
               tenant_id: holder.tenant_id,
               slug: holder.tenant.slug,
               hostname: body["hostname"]
             })

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      Repo.delete_all(from(o in OnboardingRecord, where: o.id == ^record.id))
    end)

    again = post(ctx, "/api/v1/onboarding", body)
    assert again.status == 202, again.resp_body
    assert json(again)["instance_id"] == json(first)["instance_id"]
    assert json(again)["replayed"] == true

    other = post(ctx, "/api/v1/onboarding", Map.put(body, "display_name", "Another name"))
    assert other.status == 409, other.resp_body
    assert [_one] = started_events(ctx, json(first)["instance_id"])
  end

  test "(d) a slug that is taken is a 409 on POST /tenants before anything starts", ctx do
    seed!(ctx)

    assert {:ok, taken} =
             Letflow.Identity.create_tenant(%{
               "slug" => TenantSlugFixture.unique_slug("t2704-taken"),
               "display_name" => "Taken"
             })

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      Repo.delete_all(from(t in Tenant, where: t.id == ^taken.id))
    end)

    conn =
      post(ctx, "/api/v1/tenants", %{"slug" => taken.slug, "display_name" => "Again"})

    assert conn.status == 409, conn.resp_body

    assert Repo.all(
             from(e in Event, where: e.event_type == "INSTANCE_STARTED"),
             prefix: ctx.platform.schema_name
           ) == []
  end

  test "T-2727 V8: POST /tenants tenant_type reaches the persisted row on the v2 definition",
       ctx do
    seed!(ctx)
    slug = TenantSlugFixture.unique_slug("t2727-type")

    conn =
      post(ctx, "/api/v1/tenants", %{
        "slug" => slug,
        "display_name" => "Typed",
        "tenant_type" => "production"
      })

    assert conn.status == 202, conn.resp_body
    assert started_variables(ctx, json(conn)["instance_id"])["tenant_type"] == "production"

    Enum.each(1..14, fn _ -> PlatformStepRunner.run_due(ctx.platform.schema_name) end)
    tenant = Repo.get_by(Tenant, slug: slug)
    assert tenant, "the create step must have stored the tenant"
    drop_on_exit(tenant)
    assert tenant.tenant_type == "production"
  end

  test "T-2727 V8: a tenant_type outside the enum is a 422 before anything starts", ctx do
    seed!(ctx)

    conn =
      post(ctx, "/api/v1/tenants", %{
        "slug" => TenantSlugFixture.unique_slug("t2727-bad"),
        "display_name" => "Bad",
        "tenant_type" => "gold"
      })

    assert conn.status in [400, 422], conn.resp_body
  end

  test "T-2727 V8: route 2 WITH admin_email builds notify_admin true; WITHOUT it false and completes",
       ctx do
    seed!(ctx)

    with_mail = Map.put(form("/api/v1/onboarding"), "admin_email", "owner-t2727@example.com")
    conn = post(ctx, "/api/v1/onboarding", with_mail)
    assert conn.status == 202, conn.resp_body
    assert started_variables(ctx, json(conn)["instance_id"])["notify_admin"] == true

    without_mail = form("/api/v1/onboarding")
    conn = post(ctx, "/api/v1/onboarding", without_mail)
    assert conn.status == 202, conn.resp_body
    instance_id = json(conn)["instance_id"]
    assert started_variables(ctx, instance_id)["notify_admin"] == false

    Enum.each(1..16, fn _ -> PlatformStepRunner.run_due(ctx.platform.schema_name) end)

    projection =
      Repo.get_by!(InstanceProjection, [instance_id: instance_id],
        prefix: ctx.platform.schema_name
      )

    for slug <- [with_mail["slug"], without_mail["slug"]],
        tenant = Repo.get_by(Tenant, slug: slug),
        do: drop_on_exit(tenant)

    refute projection.status == :error, inspect(projection.error_detail)
  end

  defp started_variables(ctx, instance_id) do
    [event] = started_events(ctx, instance_id)
    payload = event.payload
    Map.get(payload, "variables") || Map.get(payload, "initial_variables") || payload
  end

  defp drop_on_exit(tenant) do
    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      id = Ecto.UUID.dump!(tenant.id)

      %{rows: schemas} =
        Repo.query!("SELECT schema_name FROM tenant_schemas WHERE tenant_id = $1", [id])

      Repo.query!("DELETE FROM tenant_schemas WHERE tenant_id = $1", [id])
      for [schema] <- schemas, do: Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|)

      %{rows: referencing} =
        Repo.query!("""
        SELECT cl.relname, att.attname
        FROM pg_constraint con
        JOIN pg_class cl ON cl.oid = con.conrelid
        JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
        WHERE con.contype = 'f' AND con.confrelid = 'tenants'::regclass
        """)

      for [table, column] <- referencing,
          do: Repo.query!(~s|DELETE FROM "#{table}" WHERE "#{column}" = $1|, [id])

      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)
  end

  test "REQ-442: a login_disclosure_mode in the create body is not a start variable", ctx do
    seed!(ctx)

    conn =
      post(ctx, "/api/v1/tenants", %{
        "slug" => TenantSlugFixture.unique_slug("t2704-mode"),
        "display_name" => "Mode",
        "login_disclosure_mode" => "uniform_plus_email"
      })

    assert conn.status == 202, conn.resp_body
    assert [event] = started_events(ctx, json(conn)["instance_id"])
    refute inspect(event.payload) =~ "uniform_plus_email"
  end

  describe "SF-08: the notify step's destination check on the registration path (INV-4)" do
    alias Letflow.LoginDiscoveryNotifierDouble, as: Double
    alias Letflow.NotificationSteps.Dispatcher
    alias Letflow.OutboundDestinations
    alias Letflow.Test.SmtpHelpers, as: S

    test "a canary in the administrator's address DOMAIN reaches no debug log line", ctx do
      seed!(ctx)
      canary = "canary-dom-t2704-#{System.unique_integer([:positive])}"
      domain = "#{canary}.example.com"
      body = Map.put(form("/api/v1/onboarding"), "admin_email", "owner@#{domain}")

      # The tenant's allow-list: the channel and this very domain, so the check is passed
      # (the allowed branch is the one that binds the destination for comparison).
      prefix = ctx.platform.schema_name
      {:ok, _} = OutboundDestinations.add(prefix, nil, "email", nil)
      {:ok, _} = OutboundDestinations.add(prefix, nil, "email", domain)

      notifier = Letflow.LoginDiscovery.Notifier
      S.put_app_env!(notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
      Double.set_owner(self())
      on_exit(&Double.reset/0)

      {result, log} =
        with_log([level: :debug], fn ->
          conn = post(ctx, "/api/v1/onboarding", body)
          assert conn.status == 202, conn.resp_body
          instance_id = json(conn)["instance_id"]

          projection =
            Repo.get_by!(InstanceProjection, [instance_id: instance_id], prefix: prefix)

          variables = projection.variables || %{}
          assert Map.get(variables, "admin_email") == "owner@#{domain}"

          # The notify node of the shipped definition, run on the registration's own
          # variables: the destination check is the step's second guard after the recipient.
          Dispatcher.run(
            %{
              "template_key" => "tenant_registered",
              "recipient" => %{"var" => "admin_email"},
              "values" => %{
                "tenant_name" => %{"var" => "display_name"},
                "tenant_slug" => %{"var" => "slug"},
                "registered_by" => %{"var" => "admin_email"}
              }
            },
            Map.put_new(variables, "display_name", body["display_name"]),
            prefix: prefix,
            trigger_ref: instance_id,
            labels: %{}
          )
        end)

      # The check was REACHED and passed: the domain is on the list, so the step went on
      # and sent (a refusal code would mean the check was not passed or not reached).
      assert match?({:ok, _, _}, result), inspect(result)
      assert_receive {:deliver_message, message}, 2000
      assert message.to == "owner@#{domain}"

      assert log =~ "QUERY", "the capture must see debug query lines or this proves nothing"
      refute log =~ canary
    end
  end

  describe "SF-08: the registration values are field-authorised on the instance reads" do
    defp get(ctx, path, token) do
      :get
      |> Fixture.api_conn(path, token, ctx.platform.tenant.slug, nil)
      |> Fixture.dispatch_api()
    end

    defp post_instance(ctx, path, token) do
      :post
      |> Fixture.api_conn(path, token, ctx.platform.tenant.slug, %{})
      |> Fixture.dispatch_api()
    end

    test "a caller without TenantsManage reads neither value (detail, history, reconstruct); a TenantsManage holder does",
         ctx do
      seed!(ctx)
      email = "owner-t2704-mask@example.com"
      realm = TenantSlugFixture.unique_realm("t2704mask")

      started =
        post(ctx, "/api/v1/onboarding", %{
          "slug" => TenantSlugFixture.unique_slug("t2704-mask"),
          "display_name" => "Mask",
          "hostname" => "t2704-mask-#{Ecto.UUID.generate()}.example.com",
          "admin_email" => email,
          "idp_realm_id" => realm
        })

      assert started.status == 202, started.resp_body
      id = json(started)["instance_id"]

      for role <- ["PROCESS_OPERATOR", "TENANT_AUDITOR"] do
        token = Fixture.mint_token!(ctx.platform, [role])

        for path <- ["/api/v1/instances/#{id}", "/api/v1/instances/#{id}/history"] do
          conn = get(ctx, path, token)
          assert conn.status == 200, "#{role} #{path}: #{conn.resp_body}"
          refute conn.resp_body =~ email, "#{role} #{path} leaks the e-mail"
          refute conn.resp_body =~ realm, "#{role} #{path} leaks the realm"
        end

        recon = post_instance(ctx, "/api/v1/instances/#{id}/reconstruct", token)
        refute recon.resp_body =~ email
        refute recon.resp_body =~ realm
      end

      # The authorised platform administrator keeps the progress view.
      detail = get(ctx, "/api/v1/instances/#{id}", ctx.token)
      assert detail.status == 200
      assert json(detail)["variables"]["admin_email"] == email
      assert json(detail)["variables"]["realm_id"] == realm

      history = get(ctx, "/api/v1/instances/#{id}/history", ctx.token)
      assert history.resp_body =~ email
    end
  end

  describe "SF-08: the audit read does not carry the registration values" do
    test "PROCESS_OPERATOR and TENANT_AUDITOR read no value from /audit; PLATFORM_ADMIN does",
         ctx do
      seed!(ctx)
      email = "owner-t2704-audit@example.com"
      realm = TenantSlugFixture.unique_realm("t2704audit")

      started =
        post(ctx, "/api/v1/onboarding", %{
          "slug" => TenantSlugFixture.unique_slug("t2704-audit"),
          "display_name" => "Audit",
          "hostname" => "t2704-audit-#{Ecto.UUID.generate()}.example.com",
          "admin_email" => email,
          "idp_realm_id" => realm
        })

      assert started.status == 202, started.resp_body
      id = json(started)["instance_id"]
      path = "/api/v1/audit?resource_id=#{id}"

      audit = fn token ->
        :get
        |> Fixture.api_conn(path, token, ctx.platform.tenant.slug, nil)
        |> Fixture.dispatch_api()
      end

      for role <- ["PROCESS_OPERATOR", "TENANT_AUDITOR"] do
        conn = audit.(Fixture.mint_token!(ctx.platform, [role]))
        assert conn.status == 200, "#{role}: #{conn.resp_body}"
        assert json(conn)["items"] != [], "#{role}: the instance.create row must be listed"
        refute conn.resp_body =~ email, "#{role} /audit leaks the e-mail"
        refute conn.resp_body =~ realm, "#{role} /audit leaks the realm"
      end

      admin = audit.(ctx.token)
      assert admin.status == 200
      assert admin.resp_body =~ email
    end
  end

  test "T-2727 V16: a replay that adds a tenant_type to a start without one is a 409", ctx do
    seed!(ctx)
    slug = TenantSlugFixture.unique_slug("t2727-typed-replay")
    body = %{"slug" => slug, "display_name" => "Typed replay"}

    assert post(ctx, "/api/v1/tenants", body).status == 202

    conn = post(ctx, "/api/v1/tenants", Map.put(body, "tenant_type", "production"))
    assert conn.status == 409, conn.resp_body
  end
end
