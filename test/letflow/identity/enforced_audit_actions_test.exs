defmodule Letflow.Identity.EnforcedAuditActionsTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 7 for the action introduced in 2e-a, `binding.refused`
  (decision 0051 D8 amendment rule 3; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 8.1, tests T-A1 and T-A2;
  spec `test/specs/REQ-519-2e-a.md`):

    * T-A1: `Letflow.Audit.list_entries/1` returns each 2e-a entry without error through its
      `resource_type` / `resource_id` filters (the function has no action filter, design
      finding F7, so the action is asserted on the returned items);
    * T-A2: no token value, token hash, IdP claim value, e-mail or user name appears in any entry
      the 2e-a code writes (`binding.refused`, and the `role_binding.created` entry of a seeded
      NO-ROW binding, which gains the fixed key `rows`).

  The 2e-b actions (`grant.sync_suppressed`, `binding.pending_scope`, `group_member.*` with
  `scope_delta`) belong to the next slice.

  `async: false`: committed writes in a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry

  @actor "7c1d5f22-9a40-4e7b-b3a8-0d3f6f1e5b10"

  defp list(s, resource_type, resource_id) do
    Audit.list_entries(%{
      prefix: s,
      page_size: 50,
      resource_type: resource_type,
      resource_id: resource_id
    })
  end

  describe "T-A1 binding.refused is listed without error" do
    test "through the resource_type and resource_id filters, with the action on the returned item" do
      fx = tenant!("req519-a1", :on)
      s = fx.schema_name
      g = group!(fx)

      assert {:error, :scope_required} =
               RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, g.id,
                 prefix: s,
                 audit_context: %{actor_id: @actor, trace_id: "req519-a1-trace", source: "api"}
               )

      assert {:ok, %{items: [item], has_more: false}} = list(s, "tenant_role", "PROCESS_DESIGNER")
      assert item.action == "binding.refused"
      assert item.actor_id == @actor
      assert item.trace_id == "req519-a1-trace"

      # No match for another role name: the filter is real, not a pass-through.
      assert {:ok, %{items: []}} = list(s, "tenant_role", "TASK_WORKER")

      # The chain still verifies after the entry written outside the rolled-back transaction.
      assert {:ok, :valid} = Audit.verify_chain(s)
    end
  end

  describe "T-A2 no secret in any entry written by 2e-a" do
    test "binding.refused and the NO-ROW role_binding.created hold ids and fixed strings only" do
      fx = tenant!("req519-a2", :off)
      s = fx.schema_name

      # A member with identifying data and a real token whose plaintext and hash exist.
      group = group!(s, "TASK_WORKER")
      user = member!(s, group.id, user!(s)) |> Map.take([:id, :username, :email])

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil}, prefix: s)

      set_mode!(fx, :on)
      ids = entry_ids(s)
      other = group!(fx)

      assert {:error, :scope_required} =
               RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, other.id,
                 prefix: s,
                 audit_context: %{actor_id: @actor, trace_id: "req519-a2-trace", source: "api"}
               )

      assert {:ok, %{skipped_enforced: [_ | _]}} =
               RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

      written = new_entries(s, ids)
      actions = written |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()
      assert actions == ["binding.refused", "role_binding.created"]

      dump = Jason.encode!(Enum.map(written, &%{before: &1.before_state, after: &1.after_state}))

      for secret <- [plaintext, token.token_hash, user.username, user.email] do
        assert is_binary(secret) and secret != ""
        refute dump =~ secret
      end

      refute dump =~ "lf_tok_"
      refute dump =~ ~r/password/i

      # Key sets: nothing beyond ids and fixed strings.
      refused = Enum.find(written, &(&1.action == "binding.refused"))

      assert refused.after_state |> Map.keys() |> Enum.sort() ==
               ~w(actor case group role trace_id)

      created = Enum.find(written, &(&1.action == "role_binding.created"))
      assert created.after_state["rows"] == "skipped_enforced"
      assert created.after_state["granted_user_ids"] == [user.id]
    end
  end
end
