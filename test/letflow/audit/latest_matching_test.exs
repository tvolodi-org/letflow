defmodule Letflow.Audit.LatestMatchingTest do
  @moduledoc """
  REQ-519 slice 2f-a (GH #2535), design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.5/4.6/8.3 and the SEC
  code-gate merge condition (step-16): `Letflow.Audit.latest_matching/4`, the one new audit
  read (shadow-window start) that `Letflow.Identity.SyncScopeGuard`'s dedup now shares.

  Pinned here: the ORDER (`timestamp DESC`, then `id DESC`), the tenant PREFIX, the
  `resource_type` / `resource_id` filters, the ACTION filter (a list; an empty list matches
  nothing), `nil` when nothing matches, ONE statement, and that the answer is the full entry.
  Rows are inserted RAW with chosen timestamps and ids (synthetic chain hashes, so
  `Audit.verify_chain/1` is never called here); the dedup predicate of the sync guard is
  reproduced with real `Audit.insert_entry/3` entries (the guard's own tests,
  `test/letflow/identity/sync_scope_guard_test.exs`, stay the behavioural proof of the swap).

  `async: false`: real tenant schemas.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.TestSupport.QueryCount

  @t1 ~U[2026-03-01 10:00:00.000000Z]
  @t2 ~U[2026-03-02 10:00:00.000000Z]
  @t3 ~U[2026-03-03 10:00:00.000000Z]
  @low_id "00000000-0000-4000-8000-000000000001"
  @high_id "00000000-0000-4000-8000-000000000009"
  @enabled "scope.enforcement_enabled"
  @disabled "scope.enforcement_disabled"

  defp raw!(fx, attrs) do
    base = %{
      action: @enabled,
      resource_type: "tenant",
      resource_id: fx.tenant_id,
      timestamp: @t1,
      after_state: %{"mode" => "shadow"}
    }

    F.raw_entry!(fx, Map.merge(base, attrs))
  end

  defp latest(fx, actions),
    do: Audit.latest_matching(fx.schema_name, "tenant", fx.tenant_id, actions)

  test "nil when nothing matches" do
    fx = F.admin_tenant!("req519-lm1")

    assert latest(fx, [@enabled, @disabled]) == nil
  end

  test "the LATEST entry by timestamp wins, whatever the insertion order" do
    fx = F.admin_tenant!("req519-lm2")
    newest = raw!(fx, %{timestamp: @t3})
    _older = raw!(fx, %{timestamp: @t1})
    _middle = raw!(fx, %{timestamp: @t2})

    assert %Entry{id: id, timestamp: @t3} = latest(fx, [@enabled])
    assert id == newest
  end

  test "equal timestamps are broken by the HIGHER id" do
    fx = F.admin_tenant!("req519-lm3")
    _low = raw!(fx, %{timestamp: @t2, id: @low_id})
    _high = raw!(fx, %{timestamp: @t2, id: @high_id})

    assert %Entry{id: @high_id} = latest(fx, [@enabled])

    # and not by insertion order: insert the higher id FIRST in another tenant
    other = F.admin_tenant!("req519-lm3b")
    _high = raw!(other, %{timestamp: @t2, id: @high_id})
    _low = raw!(other, %{timestamp: @t2, id: @low_id})

    assert %Entry{id: @high_id} = latest(other, [@enabled])
  end

  test "the action filter: a list of actions, the latest among them, others ignored" do
    fx = F.admin_tenant!("req519-lm4")
    enabled = raw!(fx, %{action: @enabled, timestamp: @t1})
    disabled = raw!(fx, %{action: @disabled, timestamp: @t2, after_state: %{"mode" => "off"}})
    _refused = raw!(fx, %{action: "scope.enforcement_refused", timestamp: @t3})

    assert %Entry{id: ^disabled} = latest(fx, [@enabled, @disabled])
    assert %Entry{id: ^enabled} = latest(fx, [@enabled])
    assert %Entry{id: ^disabled} = latest(fx, [@disabled])
    assert latest(fx, []) == nil
    assert latest(fx, ["scope.enforcement_unknown"]) == nil
  end

  test "the resource filters: another resource id or type never matches, even when newer" do
    fx = F.admin_tenant!("req519-lm5")
    mine = raw!(fx, %{timestamp: @t1})
    _other_id = raw!(fx, %{timestamp: @t3, resource_id: Ecto.UUID.generate()})
    _other_type = raw!(fx, %{timestamp: @t3, resource_type: "tenant_role"})

    assert %Entry{id: ^mine} = latest(fx, [@enabled])
    assert Audit.latest_matching(fx.schema_name, "tenant_role", fx.tenant_id, [@enabled])
    assert Audit.latest_matching(fx.schema_name, "nothing", fx.tenant_id, [@enabled]) == nil
  end

  test "the prefix: an entry of another tenant schema is never returned" do
    fx = F.admin_tenant!("req519-lm6a")
    other = F.admin_tenant!("req519-lm6b")
    _theirs = raw!(other, %{timestamp: @t3, resource_id: fx.tenant_id})
    mine = raw!(fx, %{timestamp: @t1})

    assert %Entry{id: ^mine} = latest(fx, [@enabled])

    # the other tenant's schema has only its own row, reachable only through ITS prefix
    assert %Entry{timestamp: @t3} =
             Audit.latest_matching(other.schema_name, "tenant", fx.tenant_id, [@enabled])

    assert Audit.latest_matching(other.schema_name, "tenant", other.tenant_id, [@enabled]) == nil
  end

  test "it returns the full entry with the decoded after_state, and issues ONE statement" do
    fx = F.admin_tenant!("req519-lm7")
    id = raw!(fx, %{timestamp: @t2, after_state: %{"mode" => "shadow", "reason" => "x"}})

    {entry, statements} = QueryCount.count_statements(fn -> latest(fx, [@enabled]) end)

    assert statements == 1
    assert %Entry{id: ^id, action: @enabled, resource_type: "tenant"} = entry
    assert entry.resource_id == fx.tenant_id
    assert entry.after_state == %{"mode" => "shadow", "reason" => "x"}
    assert entry.timestamp == @t2
  end

  test "the sync guard's dedup predicate: an entry of the action exists, another action's does not" do
    fx = F.admin_tenant!("req519-lm8")
    resource_id = "#{Ecto.UUID.generate()}:TASK_WORKER"

    assert Audit.latest_matching(fx.schema_name, "user_role", resource_id, [
             "binding.pending_scope"
           ]) == nil

    {:ok, _entry} =
      Audit.insert_entry(
        Repo,
        %{
          actor_id: nil,
          action: "binding.pending_scope",
          resource_type: "user_role",
          resource_id: resource_id,
          before_state: nil,
          after_state: %{"role" => "TASK_WORKER"},
          trace_id: F.trace()
        },
        fx.schema_name
      )

    assert %Entry{action: "binding.pending_scope"} =
             Audit.latest_matching(fx.schema_name, "user_role", resource_id, [
               "binding.pending_scope"
             ])

    assert Audit.latest_matching(fx.schema_name, "user_role", resource_id, [
             "grant.sync_suppressed"
           ]) == nil
  end

  test "a prefix that is not a string or actions that are not a list are rejected by the function head" do
    # opaque values, so the compiler's type checker does not (rightly) flag the bad calls
    no_prefix = F.opaque(nil)
    not_a_list = F.opaque(@enabled)

    assert_raise FunctionClauseError, fn ->
      Audit.latest_matching(no_prefix, "tenant", "x", [@enabled])
    end

    assert_raise FunctionClauseError, fn ->
      Audit.latest_matching("tenant_x", "tenant", "x", not_a_list)
    end
  end
end
