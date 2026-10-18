defmodule Letflow.Identity.BindingRefusalTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 1 rows (a) and (b), D-4 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.5 and 3.10, tests
  T-R1..T-R6; spec `test/specs/REQ-519-2e-a.md`; SEC code gate step-06 merge conditions):
  in a tenant stored `on`, `POST /roles` that would create a platform-role binding is refused with
  409 `scope_required`, and `binding.refused` is written AFTER the rollback in its own transaction
  (the `Letflow.Identity.TenantAdminGuard.refuse/4` pattern). The tenant fixture leaves the
  sandbox in `:auto`, so the writer's own `Repo.transaction` really commits or rolls back and an
  entry that was written INSIDE the rolled-back transaction would not exist afterwards.

  Log assertions look only at this module's own constant lines (the Ecto debug QUERY lines in the
  captured log carry ids and are not this module's output).

  `async: false`: committed writes.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Audit
  alias Letflow.Identity.BindingRefusal
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole

  @remedy "create the binding before enabling enforcement, or set enforcement to off with a reason, create it, narrow its scope, and enable again"
  @actor "3c6f6f6e-4a89-4c0d-9a4a-0f5e5d0c2a11"
  @key_set ~w(actor case group role trace_id)

  defp ctx, do: %{actor_id: @actor, trace_id: "req519-refusal-trace", source: "api"}

  defp upsert(s, name, kind, group_id) do
    RoleRegistry.upsert_role_report(name, kind, group_id, prefix: s, audit_context: ctx())
  end

  defp refusals(s), do: entries(s, "binding.refused")

  # Only the lines this module writes.
  defp own_lines(log) do
    log |> String.split(~r/\R/) |> Enum.filter(&(&1 =~ "binding_refusal_not_recorded"))
  end

  defp reasons(lines) do
    Enum.flat_map(lines, fn line ->
      Regex.scan(~r/binding_refusal_not_recorded reason=[a-z_]+/, line) |> List.flatten()
    end)
  end

  defp create_audit_fault!(schema) do
    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".req519_audit_fault() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN RAISE EXCEPTION 'injected audit fault (REQ-519 test)'; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER req519_audit_fault BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".req519_audit_fault()|
    )
  end

  defp drop_audit_fault!(schema) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS req519_audit_fault ON "#{schema}".audit_entries|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".req519_audit_fault()|)
  end

  defp refusal_arg(group_id),
    do: %{case: :nil_to_platform, role: "PROCESS_DESIGNER", group_id: group_id}

  # ===========================================================================================
  describe "T-R1 POST /roles nil -> platform_role in an on tenant" do
    test "409 scope_required: the whole body is fixed, names no id, and the binding is not created" do
      fx = tenant!("req519-r1", :on)
      s = fx.schema_name
      g = group!(fx)

      conn =
        http(:post, "/roles", fx, %{
          "name" => "PROCESS_DESIGNER",
          "kind" => "platform_role",
          "group_id" => g.id
        })

      assert conn.status == 409, conn.resp_body
      payload = body(conn)

      assert payload["detail"] == "scope_required"
      assert payload["remedy"] == @remedy
      assert payload["title"] == "Conflict"
      assert payload["status"] == 409

      assert payload |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(detail remedy status title trace_id type))

      # INV-2: no id, no role name, no group in the body.
      refute conn.resp_body =~ g.id
      refute conn.resp_body =~ "PROCESS_DESIGNER"
      refute conn.resp_body =~ fx.tenant_id
      refute Map.has_key?(payload, "grant_rows")

      assert binding(s, "PROCESS_DESIGNER") == nil
      assert rows(s) == []
    end

    test "the same body bytes for two different refusals (nothing varies with the role or group)" do
      fx = tenant!("req519-r1-same", :on)
      g1 = group!(fx)
      g2 = group!(fx)

      one =
        http(:post, "/roles", fx, %{
          "name" => "PROCESS_DESIGNER",
          "kind" => "platform_role",
          "group_id" => g1.id
        })

      two =
        http(:post, "/roles", fx, %{
          "name" => "TASK_WORKER",
          "kind" => "platform_role",
          "group_id" => g2.id
        })

      assert one.status == 409
      assert two.status == 409
      assert Map.delete(body(one), "trace_id") == Map.delete(body(two), "trace_id")
    end

    test "the internal binding_policy option cannot be passed over HTTP (body or query): still 409, nothing written" do
      fx = tenant!("req519-r1-policy", :on)
      s = fx.schema_name
      g = group!(fx)

      conn =
        http(:post, "/roles", fx, %{
          "name" => "PROCESS_DESIGNER",
          "kind" => "platform_role",
          "group_id" => g.id,
          "binding_policy" => "no_row_when_enforced",
          "opts" => %{"binding_policy" => "no_row_when_enforced"}
        })

      assert conn.status == 409, conn.resp_body
      assert body(conn)["detail"] == "scope_required"
      assert binding(s, "PROCESS_DESIGNER") == nil
      assert rows(s) == []
    end
  end

  # ===========================================================================================
  describe "T-R2 kind change routing -> platform_role, including re-creation after platform -> routing" do
    test "a routing binding stays routing and is refused" do
      fx = tenant!("req519-r2a", :off)
      s = fx.schema_name
      g = group!(fx)
      {:ok, _role, _rows} = upsert(s, "TASK_WORKER", :process_routing_role, g.id)
      set_mode!(fx, :on)

      conn =
        http(:post, "/roles", fx, %{
          "name" => "TASK_WORKER",
          "kind" => "platform_role",
          "group_id" => g.id
        })

      assert conn.status == 409, conn.resp_body
      assert body(conn)["detail"] == "scope_required"
      assert %TenantRole{kind: :process_routing_role} = binding(s, "TASK_WORKER")
      assert rows(s) == []
      assert [refusal] = refusals(s)
      assert refusal.after_state["case"] == "routing_to_platform"
    end

    test "re-creation after platform -> routing: converting back to platform is refused, rows stay empty" do
      fx = tenant!("req519-r2b", :off)
      s = fx.schema_name
      g = group!(fx)
      {:ok, _role, _rows} = upsert(s, "AGENT_RUNNER", :platform_role, g.id)
      assert rows(s) == [tw(g.id, "AGENT_RUNNER")]
      set_mode!(fx, :on)

      # platform -> routing is allowed in on (removal) and drops the row.
      assert {:ok, %TenantRole{kind: :process_routing_role}, :in_place} =
               upsert(s, "AGENT_RUNNER", :process_routing_role, g.id)

      assert rows(s) == []

      # ... and the way back is exactly the refused case.
      assert {:error, :scope_required} = upsert(s, "AGENT_RUNNER", :platform_role, g.id)
      assert %TenantRole{kind: :process_routing_role} = binding(s, "AGENT_RUNNER")
      assert rows(s) == []
      assert [refusal] = refusals(s)
      assert refusal.after_state["case"] == "routing_to_platform"
    end
  end

  # ===========================================================================================
  describe "T-R3 binding.refused is written AFTER the rollback" do
    test "exists after the rolled-back write, key set exactly {actor, role, group, case, trace_id}, nothing else written" do
      fx = tenant!("req519-r3", :on)
      s = fx.schema_name
      g = group!(fx)
      before = entry_ids(s)

      assert {:error, :scope_required} = upsert(s, "PROCESS_DESIGNER", :platform_role, g.id)

      assert [entry] = new_entries(s, before)
      assert entry.action == "binding.refused"
      assert entry.resource_type == "tenant_role"
      assert entry.resource_id == "PROCESS_DESIGNER"
      assert entry.actor_id == @actor
      assert entry.trace_id == "req519-refusal-trace"
      assert entry.before_state == nil
      assert entry.after_state |> Map.keys() |> Enum.sort() == @key_set

      assert entry.after_state == %{
               "actor" => @actor,
               "role" => "PROCESS_DESIGNER",
               "group" => g.id,
               "case" => "nil_to_platform",
               "trace_id" => "req519-refusal-trace"
             }

      # Nothing of the refused write survived: no binding, no row, no binding audit entry.
      assert binding(s, "PROCESS_DESIGNER") == nil
      assert rows(s) == []
      assert entries(s, "role_binding.created") == []
      assert {:ok, :valid} = Audit.verify_chain(s)
    end
  end

  # ===========================================================================================
  describe "T-R4 a failing audit write still returns the refusal and logs the constant line" do
    test "a RAISING audit insert (trigger): the refusal is returned, reason=exception, no entry, no binding" do
      fx = tenant!("req519-r4a", :on)
      s = fx.schema_name
      g = group!(fx)
      create_audit_fault!(s)

      try do
        log =
          capture_log(fn ->
            assert {:error, :scope_required} = upsert(s, "PROCESS_DESIGNER", :platform_role, g.id)
          end)

        assert reasons(own_lines(log)) ==
                 ["binding_refusal_not_recorded reason=exception"]
      after
        drop_audit_fault!(s)
      end

      assert refusals(s) == []
      assert binding(s, "PROCESS_DESIGNER") == nil
      assert rows(s) == []
    end

    test "a NON-raising audit failure (invalid prefix): the refusal is returned, reason=audit_failed" do
      fx = tenant!("req519-r4b", :on)
      s = fx.schema_name
      g = group!(fx)
      "tenant_" <> hex = s
      renamed = "rsg_" <> hex
      Repo.query!(~s|ALTER SCHEMA "#{s}" RENAME TO "#{renamed}"|)

      try do
        log =
          capture_log(fn ->
            assert {:error, :scope_required} =
                     BindingRefusal.refuse(renamed, refusal_arg(g.id), ctx())
          end)

        assert reasons(own_lines(log)) ==
                 ["binding_refusal_not_recorded reason=audit_failed"]

        # The constant line names no id.
        for line <- own_lines(log) do
          refute line =~ g.id
          refute line =~ hex
          refute line =~ @actor
        end
      after
        Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{s}"|)
      end

      assert refusals(s) == []
    end
  end

  # ===========================================================================================
  describe "T-R5 inside an open transaction nothing is written" do
    test "refuse/3 returns the refusal, writes nothing and logs the constant line" do
      fx = tenant!("req519-r5", :on)
      s = fx.schema_name
      g = group!(fx)

      log =
        capture_log(fn ->
          assert {:ok, {:error, :scope_required}} =
                   Repo.transaction(fn -> BindingRefusal.refuse(s, refusal_arg(g.id), ctx()) end)
        end)

      assert reasons(own_lines(log)) ==
               ["binding_refusal_not_recorded reason=inside_transaction"]

      assert refusals(s) == []

      # Outside a transaction the same call writes exactly one entry.
      refute Repo.in_transaction?()
      assert {:error, :scope_required} = BindingRefusal.refuse(s, refusal_arg(g.id), ctx())
      assert [_one] = refusals(s)
    end
  end

  # ===========================================================================================
  describe "T-R6 the remedy text is present and constant" do
    test "the router wire text equals the pinned string and docs/roles.md documents the section" do
      fx = tenant!("req519-r6", :on)
      g = group!(fx)

      conn =
        http(:post, "/roles", fx, %{
          "name" => "PROCESS_DESIGNER",
          "kind" => "platform_role",
          "group_id" => g.id
        })

      assert body(conn)["remedy"] == @remedy

      docs = File.read!("docs/roles.md")
      assert docs =~ "## Creating role bindings while scope enforcement is on"
      assert docs =~ "scope_required"
      assert docs =~ "binding.refused"
    end
  end
end
