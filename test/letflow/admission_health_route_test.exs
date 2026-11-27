defmodule Letflow.AdmissionHealthRouteTest do
  @moduledoc """
  T-3034: the public `GET /health` carries the GLOBAL admission counters.

  The counters are what an operator reads when the node answers 503s: the
  budget that is actually applied (`pool_size`, `reserved_headroom`, `cap`),
  the units in use, the fair-share divisor (`tracked_tenants`) and the
  refusals since the process started, split by kind.

  The section is AGGREGATE ONLY: it carries no tenant identifier and no route
  of any tenant's traffic, which is what makes it fit on a public route. The
  per-tenant rows live on the platform-scope route
  `GET /api/v1/platform-status/admission` instead.

  `async: false`: the counters are read from the real, application-supervised
  `Letflow.Admission` singleton.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Test

  alias Letflow.Admission
  alias Letflow.AdmissionTestHelpers

  @opts Letflow.Router.init([])

  defp health do
    conn = conn(:get, "/health") |> Letflow.Router.call(@opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "the answer carries the global admission counters next to the liveness signal" do
    {status, body} = health()

    assert status == 200
    assert body["status"] == "ok"
    assert Map.has_key?(body, "sha")

    admission = body["admission"]
    assert admission["available"] == true
    assert admission["tracked_tenants"] >= 0
    assert admission["in_use"] >= 0
    assert admission["cap"] >= 1
    assert admission["reserved_headroom"] >= 0
    assert admission["pool_size"] >= 1
    assert admission["rejections"]["global"] >= 0
    assert admission["rejections"]["tenant"] >= 0
  end

  test "the counters are the ones of the running admission server" do
    AdmissionTestHelpers.restart_admission!(pool_size: 7, reserved_headroom: 2)

    {_status, body} = health()
    admission = body["admission"]

    assert admission["pool_size"] == 7
    assert admission["reserved_headroom"] == 2
    assert admission["cap"] == 5
    assert admission["in_use"] == Admission.counters().in_use
  end

  test "the public section carries no tenant identifier and no per-tenant row" do
    AdmissionTestHelpers.restart_admission!(pool_size: 7, reserved_headroom: 2)

    {:ok, ref} = Admission.try_acquire({:tenant, "tenant_secret_name"})
    on_exit(fn -> Admission.release(ref) end)

    {_status, body} = health()
    admission = body["admission"]

    # the tenant IS tracked (the divisor moves), but nothing about it is named
    assert admission["tracked_tenants"] >= 1
    refute Map.has_key?(admission, "tenants")
    refute Map.has_key?(admission, "oldest")
    refute inspect(body) =~ "tenant_secret_name"
  end
end
