defmodule Letflow.Plugs.AdmissionObservabilityTest do
  @moduledoc """
  T-3034: the admission gate's route class and its refusal line.

  The gate is the only place that knows WHY a request was refused, so it is
  the place that names the route class of the request. The class is the route
  PATTERN the router compiled in, never the request path: a request for
  `/api/v1/instances/<uuid>` is recorded as `/api/v1/instances`.

  `async: false` — like `test/letflow/plugs/admission_test.exs`, these tests
  restart the REAL, application-supervised `Letflow.Admission` singleton
  (`Letflow.Plugs.Admission`'s mount options carry no `:name` override), and
  the refusal line's rate limiter is node-wide.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Test

  alias Letflow.Admission
  alias Letflow.Admission.Observability
  alias Letflow.AdmissionTestHelpers
  alias Letflow.Plugs.Admission, as: AdmissionPlug
  alias Letflow.Test.LoggerCollector

  setup do
    Observability.reset()
    on_exit(&Observability.reset/0)
    :ok
  end

  defp tenant_conn(path, tenant_id) do
    conn(:get, path)
    |> Plug.Conn.assign(:auth_context, %{tenant_id: tenant_id, user_id: "u", roles: []})
  end

  describe "the route class of the admitted request" do
    test "is the route pattern, not the request path" do
      AdmissionTestHelpers.restart_admission!(pool_size: 5, reserved_headroom: 0)

      tenant_id = Ecto.UUID.generate()

      conn =
        tenant_conn("/api/v1/instances/8f3e2a1b-0000-4000-8000-000000000001", tenant_id)
        |> Plug.Conn.put_private(:plug_route, {"/api/v1/instances/:id", fn c -> c end})

      opts = AdmissionPlug.init(pool: :tenant)
      conn = AdmissionPlug.call(conn, opts)

      refute conn.halted
      assert %Admission.Ref{} = conn.assigns.tenant_admission_ref

      counters = Admission.counters()
      assert counters.in_use == 1
      assert [row] = counters.tenants
      assert row.routes == [{"/api/v1/instances/:id", 1}]

      # the request path never reaches the counter: only the pattern does
      refute inspect(counters) =~ "8f3e2a1b"

      Plug.Conn.send_resp(conn, 200, "ok")
    end

    test "is unmatched when no route was matched yet" do
      AdmissionTestHelpers.restart_admission!(pool_size: 5, reserved_headroom: 0)

      tenant_id = Ecto.UUID.generate()

      conn = tenant_conn("/api/v1/instances", tenant_id)
      opts = AdmissionPlug.init(pool: :tenant)
      conn = AdmissionPlug.call(conn, opts)

      refute conn.halted

      counters = Admission.counters()
      assert [row] = counters.tenants
      assert row.routes == [{"unmatched", 1}]

      Plug.Conn.send_resp(conn, 200, "ok")
    end
  end

  describe "the refusal line" do
    test "a request refused at the global gate is logged with its route class" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)

      {:ok, held} = Admission.try_acquire(:global)
      on_exit(fn -> Admission.release(held) end)

      opts = AdmissionPlug.init(pool: :global)

      {_result, entries} =
        LoggerCollector.capture(fn ->
          conn =
            conn(:get, "/api/v1/instances")
            |> Plug.Conn.put_private(:plug_route, {"/api/v1/instances", fn c -> c end})
            |> AdmissionPlug.call(opts)

          assert conn.status == 503
        end)

      text = LoggerCollector.text(entries)
      assert text =~ "admission_rejected"
      assert text =~ "kind=global"
      assert text =~ "route=/api/v1/instances"
      assert text =~ "in_use=1"
      assert text =~ "cap=1"
      # the global gate knows no tenant yet: the field says so instead of guessing
      assert text =~ "tenant=none"
    end

    test "a request refused at the tenant gate names the tenant as a pseudonym" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)

      tenant_id = Ecto.UUID.generate()
      schema = "tenant_" <> String.replace(tenant_id, "-", "")

      {:ok, held} = Admission.try_acquire({:tenant, schema})
      on_exit(fn -> Admission.release(held) end)

      opts = AdmissionPlug.init(pool: :tenant)

      {_result, entries} =
        LoggerCollector.capture(fn ->
          conn =
            tenant_conn("/api/v1/tenants", tenant_id)
            |> Plug.Conn.put_private(:plug_route, {"/api/v1/tenants", fn c -> c end})
            |> AdmissionPlug.call(opts)

          assert conn.status == 503
        end)

      text = LoggerCollector.text(entries)
      assert text =~ "admission_rejected"
      assert text =~ "kind=tenant"
      assert text =~ "route=/api/v1/tenants"
      assert text =~ "tenant=" <> Observability.hash_tenant(schema)

      # the raw schema name never reaches the line
      refute text =~ schema
    end
  end

  describe "the route class through the real pipeline" do
    test "a request refused at the global gate names the MOUNT class of its route" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)

      {:ok, held} = Admission.try_acquire(:global)
      on_exit(fn -> Admission.release(held) end)

      {_result, entries} =
        LoggerCollector.capture(fn ->
          conn =
            conn(:get, "/api/v1/instances")
            |> Letflow.Router.call(Letflow.Router.init([]))

          # the global gate refuses before the body is read and before the
          # tenant is known: the answer is the 503, not a 401
          assert conn.status == 503
        end)

      text = LoggerCollector.text(entries)
      assert text =~ "admission_rejected"
      assert text =~ "route=/api/v1/instances"
      refute text =~ "8f3e2a1b"
    end
  end
end
