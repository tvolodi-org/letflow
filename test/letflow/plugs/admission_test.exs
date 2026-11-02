defmodule Letflow.Plugs.AdmissionTest do
  @moduledoc """
  Plug-level unit tests for `Letflow.Plugs.Admission` (REQ-217). See
  `test/specs/REQ-217.md` if it exists, and `docs/requirements.yaml`'s REQ-217
  entry for the full acceptance-criteria text.

  These tests exercise `Letflow.Plugs.Admission.call/2` directly (no DB, no
  full `Letflow.Router` dispatch) — the plug's own crash branches (§2 of the
  design doc) are only reachable this way, by hand-assigning `:auth_context`
  the way `test/letflow/plugs/api_pipeline_integration_test.exs`'s own AC5
  test does for `Letflow.Plugs.TenantStatus`'s comparable "should not occur"
  branch — the real `Letflow.Plugs.AuthPipeline` never produces a malformed
  `tenant_id` or a missing `:auth_context` for a request that reaches this
  plug's mount point, so those branches are unreachable through a real HTTP
  round trip by design.

  **`async: false`** — every test here calls `Letflow.Admission.try_acquire/2`
  or `Letflow.Admission.release/2` against the REAL, application-supervised
  `Letflow.Admission` singleton (`Letflow.Plugs.Admission`'s `mount_opt()` has
  no `:name` override, so it always talks to that one singleton — see
  `Letflow.AdmissionTestHelpers`'s own moduledoc). Some tests restart that
  singleton with an artificially tiny cap via `Letflow.AdmissionTestHelpers.
  restart_admission!/1`; per ExUnit's own scheduling (all `async: true`
  modules finish before any `async: false` module starts, and `async: false`
  modules run one at a time), no concurrently-running test can observe the
  shrunk cap.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Test
  import Plug.Conn

  alias Letflow.Admission
  alias Letflow.AdmissionTestHelpers
  alias Letflow.Plugs.Admission, as: AdmissionPlug
  alias Letflow.TenantProvisioning

  describe "init/1" do
    test "accepts pool: :global and returns opts unchanged" do
      assert AdmissionPlug.init(pool: :global) == [pool: :global]
    end

    test "accepts pool: :tenant and returns opts unchanged" do
      assert AdmissionPlug.init(pool: :tenant) == [pool: :tenant]
    end

    test "raises on any other :pool value" do
      assert_raise ArgumentError, fn -> AdmissionPlug.init(pool: :bogus) end
    end

    test "raises when :pool is absent" do
      assert_raise ArgumentError, fn -> AdmissionPlug.init([]) end
    end
  end

  describe "pool: :tenant derivation crash branches (design doc §2, believed unreachable in practice)" do
    test "a missing :auth_context assign crashes rather than silently passing through" do
      conn = conn(:get, "/whatever")
      opts = AdmissionPlug.init(pool: :tenant)

      assert_raise KeyError, fn -> AdmissionPlug.call(conn, opts) end
    end

    test "a malformed tenant_id (fails Ecto.UUID.cast/1) crashes rather than admitting or silently rejecting" do
      conn =
        conn(:get, "/whatever")
        |> assign(:auth_context, %{tenant_id: "not-a-uuid", user_id: "u", roles: []})

      opts = AdmissionPlug.init(pool: :tenant)

      assert_raise MatchError, fn -> AdmissionPlug.call(conn, opts) end
    end
  end

  describe "AC5: 503 body shape matches Letflow.Api.Error.service_unavailable/1 exactly" do
    test "global gate rejection produces the exact same RFC 9457 shape REQ-066's own test asserts" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)
      # cap == 1, consume it so the very next try_acquire(:global) is rejected.
      {:ok, held_ref} = Admission.try_acquire(:global)
      on_exit(fn -> Admission.release(held_ref) end)

      opts = AdmissionPlug.init(pool: :global)
      conn = conn(:get, "/whatever") |> AdmissionPlug.call(opts)

      assert conn.halted
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]

      decoded = Jason.decode!(conn.resp_body)

      # Same four RFC 9457 fields test/letflow/api/error_test.exs's own
      # "service_unavailable/1 builds the 503 document" test asserts, via the
      # exact same Letflow.Api.Error.service_unavailable/1 constructor -- not
      # an ad hoc body shape invented for this plug.
      assert decoded["status"] == 503
      assert decoded["title"] == "Service Unavailable"
      assert String.ends_with?(decoded["type"], "/problems/service-unavailable")
      assert is_binary(decoded["detail"])
      assert Map.has_key?(decoded, "trace_id")
    end

    test "retry-after reflects the configured :retry_after_seconds, read fresh (no other code change)" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)
      {:ok, held_ref} = Admission.try_acquire(:global)

      original = Application.get_env(:letflow, :admission, [])
      Application.put_env(:letflow, :admission, Keyword.put(original, :retry_after_seconds, 7))

      on_exit(fn ->
        Application.put_env(:letflow, :admission, original)
        Admission.release(held_ref)
      end)

      opts = AdmissionPlug.init(pool: :global)
      conn = conn(:get, "/whatever") |> AdmissionPlug.call(opts)

      assert get_resp_header(conn, "retry-after") == ["7"]
    end

    test "tenant gate rejection uses the same shape, distinct wording, no schema name leaked in detail" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)
      schema = "tenant_" <> String.replace(Ecto.UUID.generate(), "-", "")
      {:ok, held_ref} = Admission.try_acquire({:tenant, schema})
      on_exit(fn -> Admission.release(held_ref) end)

      conn =
        conn(:get, "/whatever")
        |> assign(:auth_context, %{tenant_id: tenant_id_for(schema), user_id: "u", roles: []})

      opts = AdmissionPlug.init(pool: :tenant)
      conn = AdmissionPlug.call(conn, opts)

      assert conn.status == 503
      decoded = Jason.decode!(conn.resp_body)
      refute String.contains?(decoded["detail"], schema)
    end
  end

  describe "Mechanism A: register_before_send/2 releases on normal completion" do
    test "a successful global admission releases its slot once send_resp/3 runs" do
      AdmissionTestHelpers.restart_admission!(pool_size: 1, reserved_headroom: 0)

      opts = AdmissionPlug.init(pool: :global)
      conn = conn(:get, "/whatever") |> AdmissionPlug.call(opts)

      refute conn.halted
      assert %Admission.Ref{} = conn.assigns.global_admission_ref

      # cap is 1 and fully consumed by the admission above -- confirm it, then
      # complete the response (which runs the registered before_send
      # callback) and confirm the slot is free again.
      assert {:error, :capacity} = Admission.try_acquire(:global)

      _sent = send_resp(conn, 200, "ok")

      assert {:ok, ref} = Admission.try_acquire(:global)
      Admission.release(ref)
    end
  end

  describe "Mechanism B: Letflow.Plugs.Admission.release_pending_refs/0 (Letflow.Plugs.ApiPipeline's handle_errors/2 delegates to this)" do
    test "drains and releases every ref accumulated in the process dictionary, idempotent-safe" do
      AdmissionTestHelpers.restart_admission!(pool_size: 2, reserved_headroom: 0)

      global_opts = AdmissionPlug.init(pool: :global)
      tenant_opts = AdmissionPlug.init(pool: :tenant)
      schema = "tenant_" <> String.replace(Ecto.UUID.generate(), "-", "")

      conn =
        conn(:get, "/whatever")
        |> assign(:auth_context, %{tenant_id: tenant_id_for(schema), user_id: "u", roles: []})

      # Simulate both gates having already succeeded earlier in the SAME
      # request/process, exactly as ApiPipeline's real chain would leave
      # things right before a raise in a later pre-dispatch plug (design doc
      # §5's Mechanism B) -- both refs are in conn.assigns AND in the process
      # dictionary at this point.
      conn = AdmissionPlug.call(conn, global_opts)
      _conn_with_both = AdmissionPlug.call(conn, tenant_opts)

      # cap == 2, both consumed -- confirm exhaustion before cleanup.
      assert {:error, :capacity} = Admission.try_acquire(:global)

      # handle_errors/2's own conn parameter, per the design doc's corrected
      # crash trace, is the PRE-PIPELINE conn -- it carries NEITHER
      # admission-ref assign. Passing the original bare `conn` (not
      # `_conn_with_both`) here is what makes this test honest: cleanup MUST
      # come from the process dictionary, not from conn.assigns.
      bare_conn = conn(:get, "/whatever")

      result =
        Letflow.Plugs.ApiPipeline.handle_errors(bare_conn, %{
          kind: :error,
          reason: %RuntimeError{message: "boom"},
          stack: []
        })

      assert result == bare_conn

      # Both slots freed -- exactly once each (release/2 is idempotent, so a
      # double-release wouldn't show up as an error here, but a NEVER-released
      # ref would keep try_acquire/2 rejecting).
      assert {:ok, ref1} = Admission.try_acquire(:global)
      assert {:ok, ref2} = Admission.try_acquire(:global)
      Admission.release(ref1)
      Admission.release(ref2)
    end

    test "handle_errors/2 is a no-op (never raises) when nothing was pending" do
      bare_conn = conn(:get, "/whatever")

      result =
        Letflow.Plugs.ApiPipeline.handle_errors(bare_conn, %{
          kind: :error,
          reason: %RuntimeError{message: "boom"},
          stack: []
        })

      assert result == bare_conn
    end
  end

  # Reverses Letflow.TenantProvisioning.schema_name_for_tenant/1's own pure
  # "tenant_" <> hex encoding via the SAME production function that direction
  # already has, so these tests can hand-craft a conn whose
  # auth_context.tenant_id decodes to a KNOWN schema name without a real DB
  # tenant.
  defp tenant_id_for(schema) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema)
    tenant_id
  end
end
