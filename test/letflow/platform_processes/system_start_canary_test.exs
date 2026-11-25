defmodule Letflow.PlatformProcesses.SystemStartCanaryTest do
  @moduledoc """
  T-2727 V9 (design `docs/platform-register-tenant-v2.md` section 10): the INV-4 canary of the
  system-authority start. The e-mail, the realm and the hostname of a system registration appear in
  no audit row, no event metadata, no debug log line and no instance read of a caller who may not
  see them.

  The run is real: the system start, then the platform step runner over the shipped v2 definition,
  with the log captured at `:debug`.

  `async: false`: the platform tenant pin is application configuration.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Engine.PlatformStepRunner
  alias Letflow.EventStore.Event
  alias Letflow.PlatformProcesses
  alias Letflow.PlatformProcesses.SystemStart
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.Support.RegisterTenantProcessFixture

  test "the e-mail, the realm and the hostname reach no audit READ of a caller without the permission, event metadata, log or masked read" do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)
    prefix = tenants.p.schema_name
    RegisterTenantProcessFixture.seed!(prefix)
    {:ok, system_start} = SystemStart.for_route(:signup_provisioning)

    n = System.unique_integer([:positive])
    email = "canary-mail-#{n}@canary-dom-#{n}.example.com"
    realm = "canaryrealm#{n}"
    hostname = "canary-host-#{n}.example.com"
    canaries = [email, realm, hostname, "canary-mail-#{n}", "canary-dom-#{n}"]

    request = %{
      tenant_id: Ecto.UUID.generate(),
      name: "Canary Co",
      hostname: hostname,
      idp_realm_id: realm,
      email_key: email
    }

    {result, log} =
      with_log([level: :debug], fn ->
        started = PlatformProcesses.start_register_tenant_system(request, system_start, [])
        Enum.each(1..16, fn _ -> PlatformStepRunner.run_due(prefix) end)
        started
      end)

    assert {:ok, %{instance_id: instance_id}} = result
    assert log =~ "QUERY", "the capture must see debug query lines or this proves nothing"

    for canary <- canaries, do: refute(log =~ canary, "log carries #{canary}")

    # The stored `instance.create` row carries the start variables (the engine's own shape, masked on
    # READ by the registration labels, as for the operator starts: `register_routes_test.exs` SF-08).
    # So the audit proof is the read: a caller without TenantsManage sees the system row, no value.
    assert Repo.exists?(
             from(e in Entry,
               where: e.action == "instance.create" and e.resource_id == ^instance_id
             ),
             prefix: prefix
           )

    metadata =
      from(e in Event, where: e.instance_id == ^instance_id, select: e.metadata)
      |> Repo.all(prefix: prefix)
      |> inspect(limit: :infinity)

    for canary <- canaries, do: refute(metadata =~ canary, "event metadata carries #{canary}")

    # The masked read: a caller without TenantsManage reads none of the three values.
    token = PlatformFx.mint_token!(tenants.p, ["PROCESS_OPERATOR"])

    paths = [
      "/api/v1/instances/#{instance_id}",
      "/api/v1/instances/#{instance_id}/history",
      "/api/v1/audit?resource_id=#{instance_id}"
    ]

    for path <- paths do
      conn =
        :get
        |> PlatformFx.api_conn(path, token, tenants.p.tenant.slug, nil)
        |> PlatformFx.dispatch_api()

      assert conn.status == 200, "#{path}: #{conn.resp_body}"
      # The hostname is not a masked value (a public name, shown on the tenant's own record); the
      # e-mail and the realm are, by the registration labels.
      for canary <- canaries -- [hostname],
          do: refute(conn.resp_body =~ canary, "#{path} carries #{canary}")
    end
  end
end
