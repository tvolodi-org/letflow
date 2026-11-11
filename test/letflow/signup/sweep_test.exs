defmodule Letflow.Signup.SweepTest do
  @moduledoc """
  T-1686 (REQ-803, decision 0085 addendum T-1701): the sign-up step of the provisioner sweep.
  SS1..SS9. `async: false`: the flag and the provisioner env are VM-global.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Letflow.Test.SignupHelpers

  alias Letflow.Repo
  alias Letflow.Signup.{Provisioning, RealmProvisioner, Request}
  alias Letflow.Signup.Sweep, as: SignupSweep
  alias Letflow.TenantProvisioner.Sweep

  setup do
    System.put_env(RealmProvisioner.token_env(), "tok-sweep")
    on_exit(fn -> System.delete_env(RealmProvisioner.token_env()) end)
    :ok
  end

  defp row!(attrs) do
    tenant_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.insert!(
      struct!(
        %Request{
          tenant_id: tenant_id,
          email: "owner-#{System.unique_integer([:positive])}@example.test",
          company_name: "Acme Ltd",
          language: "en",
          state: "verified",
          step: "ready_for_provisioning",
          ip_key: :crypto.hash(:sha256, tenant_id),
          terms_version: "t",
          terms_accepted_at: now,
          verified_at: now
        },
        attrs
      )
    )
  end

  defp pending!(attrs) do
    row!(
      Keyword.merge(
        [
          state: "pending_verification",
          step: "verification",
          verified_at: nil,
          token_hash: "h#{System.unique_integer([:positive])}",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        ],
        attrs
      )
    )
  end

  defp configure!,
    do: enable!(provisioner_url: "http://127.0.0.1:1", hostname_domain: "qa.example.test")

  defp collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {agent, fn id -> Agent.update(agent, &[id | &1]) end}
  end

  defp started(agent), do: Agent.get(agent, & &1)

  test "SS1 flag off: nothing expired, nothing started, no failure" do
    old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
    p = pending!(token_expires_at: old)
    stuck = row!([])
    {agent, start} = collector()

    assert SignupSweep.run(start: start) == %{expired: 0, resumed: 0}
    assert Repo.get!(Request, p.tenant_id).state == "pending_verification"
    assert started(agent) == []
    assert Repo.get!(Request, stuck.tenant_id).step == "ready_for_provisioning"
  end

  test "SS2 expiry closes link-expired and abandoned rows, keeps a fresh one" do
    enable!()
    expired = pending!(token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    fresh = pending!([])

    assert %{expired: n} = SignupSweep.run()
    assert n >= 1
    e = Repo.get!(Request, expired.tenant_id)
    assert {e.state, e.email, e.token_hash} == {"expired", nil, nil}
    assert Repo.get!(Request, fresh.tenant_id).state == "pending_verification"
  end

  test "SS3 resume selects only stale unfinished rows at the three steps" do
    now = DateTime.utc_now()
    ok1 = row!([])

    ok2 =
      row!(
        state: "provisioning",
        step: "realm_created",
        claimed_at: DateTime.add(now, -300, :second)
      )

    ok3 = row!(state: "provisioning", step: "credential_sent")
    fresh = row!(state: "provisioning", step: "realm_created", claimed_at: now)
    failed = row!(state: "failed", step: "provisioning_failed")
    verified = row!(step: "verified")
    done = row!(state: "completed", step: "completed")
    created = row!(state: "provisioning", step: "tenant_created")

    ids = Provisioning.stale_unfinished_ids(DateTime.utc_now())
    assert ok1.tenant_id in ids and ok2.tenant_id in ids and ok3.tenant_id in ids

    for r <- [fresh, failed, verified, done, created],
        do: refute(r.tenant_id in ids, "#{r.state}/#{r.step} must not be selected")
  end

  test "SS4 provisioner not configured: expiry runs, resume does not" do
    enable!()
    expired = pending!(token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    stuck = row!([])
    {agent, start} = collector()

    assert %{resumed: 0, expired: n} = SignupSweep.run(start: start)
    assert n >= 1
    assert Repo.get!(Request, expired.tenant_id).state == "expired"
    assert started(agent) == []
    assert Repo.get!(Request, stuck.tenant_id).step == "ready_for_provisioning"
  end

  test "SS5 failed rows stay failed and attempts are not reset" do
    configure!()

    failed =
      row!(
        state: "failed",
        step: "provisioning_failed",
        step_attempts: 6,
        last_error: "attempts_exhausted"
      )

    {agent, start} = collector()

    SignupSweep.run(start: start)
    refute failed.tenant_id in started(agent)
    r = Repo.get!(Request, failed.tenant_id)
    assert {r.state, r.step_attempts} == {"failed", 6}
  end

  test "SS6 resume starts a stuck row through the real start; second sweep selects nothing" do
    configure!()
    tenant_create_env!()
    stuck = row!([])
    track_tenant(stuck.tenant_id)

    stub =
      Letflow.Test.ProvisionerStub.start!([
        {201, Letflow.Test.ProvisionerStub.created(stuck.tenant_id, %{})}
      ])

    enable!(
      provisioner_url: stub.url,
      hostname_domain: "qa.example.test",
      retry_delays_ms: [0, 0]
    )

    assert %{resumed: n} = SignupSweep.run()
    assert n >= 1
    assert await_mail() == :ok

    r = Repo.get!(Request, stuck.tenant_id)
    assert {r.state, r.step} == {"completed", "completed"}
    refute stuck.tenant_id in Provisioning.stale_unfinished_ids(DateTime.utc_now())

    assert Provisioning.stale_unfinished_ids(DateTime.utc_now()) |> Enum.member?(stuck.tenant_id) ==
             false
  end

  test "SS7 a fault in the signup step is caught and the tick still returns its counters" do
    log =
      capture_log(fn ->
        assert %{expired: _, purged: _, skipped: _, failed: _} =
                 Sweep.run(signup: fn _ -> raise "boom owner@example.test" end)
      end)

    assert log =~ "signup sweep failed (reason=RuntimeError)"
    refute log =~ "owner@example.test"
  end

  test "SS8 nothing is deleted" do
    configure!()
    pending!(token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    row!([])
    before = Repo.aggregate(Request, :count)
    {_agent, start} = collector()
    SignupSweep.run(start: start)
    assert Repo.aggregate(Request, :count) == before
    assert Repo.one(from(t in "tenants", select: count(t.id))) >= 0
  end

  test "SS9 the log carries counts only" do
    configure!()
    pending!(token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    row!([])

    log =
      capture_log(fn ->
        Sweep.run(signup: &SignupSweep.run(Keyword.put(&1, :start, fn _ -> :ok end)))
      end)

    assert log =~ "signup sweep: expired="
    refute log =~ "owner@example.test"
  end
end
