defmodule Letflow.AdmissionTest do
  use ExUnit.Case, async: true

  # No Letflow.DataCase here deliberately: Letflow.Admission makes no Repo
  # call at all (see its moduledoc's "Supervision-tree placement" section),
  # so pulling in the sandboxed-connection test case would suggest a DB
  # dependency that does not exist. Every test starts its own isolated
  # instance under a unique `:name` (mirroring
  # Letflow.SandboxPool's own test-isolation convention) so tests run
  # `async: true` with no shared state.

  alias Letflow.Admission

  defp start_admission(opts) do
    n = System.unique_integer([:positive])
    name = Module.concat(__MODULE__, "Server#{n}")

    {:ok, pid} =
      start_supervised(%{
        id: {Admission, n},
        start: {Admission, :start_link, [Keyword.put(opts, :name, name)]}
      })

    {pid, name}
  end

  # AC1: try_acquire(:global) admits up to exactly (pool_size -
  # reserved_headroom), rejects beyond, both read from config, and the cap
  # changes with a pool_size override with no other code edit.
  describe "AC1: global cap = pool_size - reserved_headroom" do
    test "admits exactly pool_size - reserved_headroom concurrent :global admissions, then rejects" do
      {_pid, name} = start_admission(pool_size: 5, reserved_headroom: 2)

      # cap == 3
      assert {:ok, _ref1} = Admission.try_acquire(:global, name)
      assert {:ok, _ref2} = Admission.try_acquire(:global, name)
      assert {:ok, _ref3} = Admission.try_acquire(:global, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end

    test "the computed cap changes when pool_size override changes, no other code edit" do
      {_pid, name_small} = start_admission(pool_size: 3, reserved_headroom: 2)
      # cap == 1
      assert {:ok, _ref} = Admission.try_acquire(:global, name_small)
      assert {:error, :capacity} = Admission.try_acquire(:global, name_small)

      {_pid2, name_big} = start_admission(pool_size: 10, reserved_headroom: 2)
      # cap == 8
      refs = for _ <- 1..8, do: Admission.try_acquire(:global, name_big) |> elem(1)
      assert length(refs) == 8
      assert {:error, :capacity} = Admission.try_acquire(:global, name_big)
    end

    test "reserved_headroom is also read from config, not hardcoded" do
      {_pid, name} = start_admission(pool_size: 10, reserved_headroom: 8)
      # cap == 2
      assert {:ok, _ref1} = Admission.try_acquire(:global, name)
      assert {:ok, _ref2} = Admission.try_acquire(:global, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end
  end

  # AC2: per-tenant cap enforced independently -- A's exhaustion doesn't
  # block B.
  describe "AC2: per-tenant caps are independent across tenants" do
    test "tenant A exhausting its own share still leaves tenant B able to acquire up to B's own share" do
      # global cap 10. Track tenant B FIRST (one attempt) so both tenants
      # are tracked before A's share is computed -- otherwise, with only A
      # tracked, A's own cap would be floor(10/1) = 10, not the floor(10/2)
      # = 5 this test means to exercise.
      {_pid, name} = start_admission(pool_size: 12, reserved_headroom: 2)

      {:ok, _b_ref0} = Admission.try_acquire({:tenant, "tenant_b"}, name)

      # now 2 tenants tracked -> each gets floor(10/2) = 5
      a_refs = for _ <- 1..5, do: Admission.try_acquire({:tenant, "tenant_a"}, name) |> elem(1)
      assert length(a_refs) == 5
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "tenant_a"}, name)

      # tenant B, simultaneously, can still acquire up to its own share
      # (already used 1 of 5)
      assert {:ok, _ref} = Admission.try_acquire({:tenant, "tenant_b"}, name)
    end
  end

  # AC3: a {:tenant, schema} acquisition that would pass the per-tenant gate
  # is still rejected once the GLOBAL cap is exhausted, even for a fresh
  # tenant with zero per-tenant usage of its own.
  describe "AC3: tenant acquisition also gated by the global cap" do
    test "a fresh tenant with zero usage is rejected once :global acquisitions alone exhaust the global cap" do
      {_pid, name} = start_admission(pool_size: 5, reserved_headroom: 2)
      # cap == 3

      assert {:ok, _} = Admission.try_acquire(:global, name)
      assert {:ok, _} = Admission.try_acquire(:global, name)
      assert {:ok, _} = Admission.try_acquire(:global, name)

      # fresh tenant, zero per-tenant usage of its own -- still rejected
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "fresh_tenant"}, name)
    end
  end

  # AC4: release/1 frees exactly one unit of both the global AND (for a
  # {:tenant, _}) the per-tenant budget it was acquired against.
  describe "AC4: release frees exactly the budget(s) it was acquired against" do
    test "acquiring to capacity, releasing one, observes exactly one subsequent try_acquire succeeds (:global)" do
      {_pid, name} = start_admission(pool_size: 4, reserved_headroom: 2)
      # cap == 2
      {:ok, ref1} = Admission.try_acquire(:global, name)
      {:ok, _ref2} = Admission.try_acquire(:global, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)

      assert :ok = Admission.release(ref1, name)

      assert {:ok, _ref3} = Admission.try_acquire(:global, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end

    test "releasing a {:tenant, _} ref frees both the global unit AND that tenant's own unit" do
      {_pid, name} = start_admission(pool_size: 4, reserved_headroom: 2)
      # cap == 2, 1 tenant tracked -> per-tenant cap == 2
      {:ok, tref} = Admission.try_acquire({:tenant, "t1"}, name)
      {:ok, _tref2} = Admission.try_acquire({:tenant, "t1"}, name)

      # global exhausted (2/2) and tenant exhausted (2/2)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "t1"}, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)

      assert :ok = Admission.release(tref, name)

      # exactly one further acquisition succeeds against EITHER budget
      assert {:ok, _} = Admission.try_acquire({:tenant, "t1"}, name)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "t1"}, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end

    test "release/1 is idempotent on an unknown/already-released ref" do
      # cap == 1 (deliberately, not 2+) so the closing behavioral proof
      # below can distinguish "no-op releases freed nothing" from "a no-op
      # release phantom-freed a unit" with a single further acquisition.
      {_pid, name} = start_admission(pool_size: 3, reserved_headroom: 2)
      {:ok, ref} = Admission.try_acquire(:global, name)

      assert :ok = Admission.release(ref, name)
      state_after_real_release = :sys.get_state(name)

      # second release of the same ref is a documented no-op, not a raise --
      # and, critically, must NOT further decrement global_in_use. A buggy
      # {:release,...} clause that always decrements regardless of whether
      # the ref is still a live member of state.refs would return :ok here
      # too, so asserting only the return value (as this test used to)
      # cannot tell a correct no-op apart from a state-corrupting
      # double-release -- assert on the actual counter instead.
      assert :ok = Admission.release(ref, name)
      assert :sys.get_state(name).global_in_use == state_after_real_release.global_in_use

      # a hand-constructed, never-issued ref is also a no-op -- same
      # state-corruption concern: a forged ref must not free a phantom unit.
      forged = %Admission.Ref{id: make_ref(), pool: :global}
      assert :ok = Admission.release(forged, name)
      assert :sys.get_state(name).global_in_use == state_after_real_release.global_in_use

      # behavioral proof, independent of internal field names: the freed
      # unit from the one REAL release above is still the only extra
      # capacity available -- exactly one further :global acquisition
      # succeeds, and the next one after that is rejected. If either no-op
      # release above had phantom-freed a unit, a second acquisition here
      # would also succeed.
      assert {:ok, _} = Admission.try_acquire(:global, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end
  end

  # AC5: per-tenant cap = floor(global_cap / tracked_tenant_count), floor 1.
  describe "AC5: per-tenant cap is an equal fair-share split with a floor of 1" do
    test "3 tracked tenants against a global cap of 10 -> each gets floor(10/3) = 3, not 1" do
      {_pid, name} = start_admission(pool_size: 12, reserved_headroom: 2)
      # cap == 10

      # touch all three tenants once each so all three are tracked before
      # asserting the per-tenant cap
      {:ok, _} = Admission.try_acquire({:tenant, "t1"}, name)
      {:ok, _} = Admission.try_acquire({:tenant, "t2"}, name)
      {:ok, _} = Admission.try_acquire({:tenant, "t3"}, name)

      # t1 already holds 1; floor(10/3) == 3, so 2 more should succeed, then reject
      assert {:ok, _} = Admission.try_acquire({:tenant, "t1"}, name)
      assert {:ok, _} = Admission.try_acquire({:tenant, "t1"}, name)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "t1"}, name)
    end

    test "5 tenants against a global cap of 9 -> each gets the floor of 1, not 0, isolated from global exhaustion" do
      # global cap deliberately large enough (9) that it is NOT the
      # bottleneck for this assertion -- floor(9/5) == 1 is what's under
      # test, isolated from AC3's separate global-exhaustion behavior.
      {_pid, name} = start_admission(pool_size: 11, reserved_headroom: 2)
      # cap == 9

      # each of the 5 tenants' FIRST attempt succeeds (proves the floor is
      # 1, not 0 -- a floor of 0 would reject every one of these)
      for schema <- ["t1", "t2", "t3", "t4", "t5"] do
        assert {:ok, _} = Admission.try_acquire({:tenant, schema}, name)
      end

      # a SECOND attempt by any one of them is rejected by its own
      # per-tenant cap (floor(9/5) == 1), even though the global budget
      # still has 4 units free (9 - 5 == 4) -- proves the rejection is the
      # per-tenant gate, not global exhaustion
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "t1"}, name)
      # confirmed still not globally exhausted
      assert {:ok, _} = Admission.try_acquire(:global, name)
    end

    test "the per-tenant cap recomputes as the tracked-tenant set grows (never retroactively revokes)" do
      {_pid, name} = start_admission(pool_size: 12, reserved_headroom: 2)
      # cap == 10

      # tenant A alone: floor(10/1) == 10, acquire 3
      refs_a = for _ <- 1..3, do: Admission.try_acquire({:tenant, "a"}, name) |> elem(1)
      assert length(refs_a) == 3

      # a 4th... actually 2nd and 3rd tenant now attempt, shrinking A's
      # NEXT computed cap without touching A's already-held refs
      {:ok, _} = Admission.try_acquire({:tenant, "b"}, name)
      {:ok, _} = Admission.try_acquire({:tenant, "c"}, name)
      # now 3 tenants tracked -> floor(10/3) == 3, A already holds 3 -> A's
      # next attempt is rejected
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "a"}, name)

      # but every ref A already holds remains valid and freely releasable
      for ref <- refs_a do
        assert :ok = Admission.release(ref, name)
      end
    end
  end

  # ISS-0421 §3a/§7: `global_cap/1` is a new read-only accessor added so
  # `Letflow.Scheduler.Poller`'s six Admission-gated sweeps can derive their
  # `Task.async_stream/3` `max_concurrency:` bound live, instead of a
  # hardcoded literal (`handoffs/WF03-ISS0421-20260904/step-04-reviewer.json`
  # FAILed the earlier draft precisely because a hardcoded `8` only happened
  # to equal `Admission.global_cap` at DEFAULT config). This describe block
  # proves the accessor genuinely reads LIVE per-instance state -- not a
  # hardcoded/cached default -- by starting an instance at a NON-default
  # `pool_size`/`reserved_headroom` pair (the same `pool_size: 3,
  # reserved_headroom: 2` config REQ-218's own poller tests already use) and
  # asserting the derived value, not the default-config value of 8.
  describe "ISS-0421: global_cap/1 reads this instance's own live global_cap, not a default" do
    test "pool_size: 3, reserved_headroom: 2 -> global_cap/1 returns 1, not the default-config 8" do
      {_pid, name} = start_admission(pool_size: 3, reserved_headroom: 2)

      assert Admission.global_cap(name) == 1
    end

    test "global_cap/1 tracks a pool_size override with no other code edit, mirroring try_acquire/2's own admitted count" do
      {_pid, name} = start_admission(pool_size: 12, reserved_headroom: 2)
      # cap == 10 -- a different non-default value from the test above,
      # proving the accessor is not merely returning a second hardcoded
      # constant that happens to match one particular config.
      assert Admission.global_cap(name) == 10

      # Cross-check against try_acquire/2's own independently-implemented
      # admission count, so this test does not merely duplicate the same
      # arithmetic the accessor itself performs -- it proves the accessor's
      # return value is the SAME number the real admission gate enforces.
      refs = for _ <- 1..10, do: Admission.try_acquire(:global, name) |> elem(1)
      assert length(refs) == 10
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end

    test "global_cap/1 with no override still returns the documented default-config derivation (8)" do
      {_pid, name} = start_admission(pool_size: 10, reserved_headroom: 2)
      assert Admission.global_cap(name) == 8
    end
  end

  # AC6: Letflow.Admission is present in Letflow.Application's supervision
  # tree, with its moduledoc stating explicitly whether it has an ordering
  # dependency.
  describe "AC6: present in the live supervision tree, no ordering dependency documented" do
    test "Letflow.Admission is supervised as its own child of Letflow.Supervisor.Infrastructure" do
      # REQ-219 (design req219-supervision-layering.md §1.1) moved
      # Letflow.Admission, along with the rest of the original flat
      # 20-child list, one level down from Letflow.Supervisor's own direct
      # children into Letflow.Supervisor.Infrastructure.
      children = Supervisor.which_children(Letflow.Supervisor.Infrastructure)

      admission_child =
        Enum.find(children, fn
          {_id, _pid, _type, [Letflow.Admission]} -> true
          _ -> false
        end)

      assert {_id, pid, :worker, [Letflow.Admission]} = admission_child
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "the running instance is usable end-to-end (proves it started from real config)" do
      assert {:ok, ref} = Admission.try_acquire(:global)
      assert :ok = Admission.release(ref)
    end

    test "the moduledoc states an explicit ordering-dependency stance" do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Admission)

      assert moduledoc =~ "ordering dependency"
    end
  end

  # AC7 (mix test / mix compile --warnings-as-errors) is verified by running
  # the suite itself, not by an in-suite assertion -- see the ELIXIR-DEV
  # handoff for quoted command output.

  # ISS-0437: forget_tenant/2 evicts a deactivated tenant's entry so it stops
  # permanently diluting every remaining active tenant's fair-share cap. See
  # lib/letflow/design/iss0437-admission-tenant-eviction.md §6.
  describe "ISS-0437: forget_tenant/2 tenant eviction" do
    test "forget_tenant/2 genuinely shrinks the fair-share divisor, un-gating another tenant (Test 1)" do
      {_pid, name} = start_admission(pool_size: 5, reserved_headroom: 2)
      # global_cap == 3 (deliberately > 2, so the global budget still has
      # one spare unit after "a" and "b" each acquire once -- the load-
      # bearing rejection/admission below must turn on the per-tenant
      # fairness divisor shrinking, not on global exhaustion)

      assert {:ok, _a_ref} = Admission.try_acquire({:tenant, "a"}, name)
      assert {:ok, _b_ref} = Admission.try_acquire({:tenant, "b"}, name)
      # map_size(tenants) == 2 -> per_tenant_cap == max(div(3, 2), 1) == 1,
      # and "a" is already at that cap (global_in_use == 2 < 3, so this
      # rejection is the per-tenant gate, not global exhaustion)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "a"}, name)

      assert :ok = Admission.forget_tenant("b", name)

      # map_size(tenants) == 1 -> per_tenant_cap == max(div(3, 1), 1) == 3,
      # strictly greater than "a"'s unchanged in_use == 1, and global_in_use
      # (2) is still < global_cap (3) -- this is only possible because the
      # divisor genuinely shrank.
      assert {:ok, _a_ref2} = Admission.try_acquire({:tenant, "a"}, name)
    end

    test "eviction while a ref is still held does not crash release/2, and the tenant never reactivates (Test 2)" do
      {_pid, name} = start_admission(pool_size: 3, reserved_headroom: 2)
      # cap == 1

      {:ok, ref} = Admission.try_acquire({:tenant, "c"}, name)
      assert {:error, :capacity} = Admission.try_acquire(:global, name)

      assert :ok = Admission.forget_tenant("c", name)

      # release of a ref whose schema was forgotten (and never reactivated)
      # must not raise
      assert :ok = Admission.release(ref, name)

      # the global unit was still freed correctly, despite the tenant-side
      # map having no entry to update
      assert {:ok, _} = Admission.try_acquire(:global, name)
    end

    test "reactivation resumes tracking with zero additional code (Test 3)" do
      {_pid, name} = start_admission(pool_size: 12, reserved_headroom: 2)
      # cap == 10

      {:ok, _} = Admission.try_acquire({:tenant, "d"}, name)
      {:ok, _} = Admission.try_acquire({:tenant, "e"}, name)
      assert :ok = Admission.forget_tenant("d", name)

      # "d" is admitted exactly as a never-before-seen schema would be, and
      # is freshly counted into the fair-share divisor alongside "e"
      # (2 tracked tenants -> per_tenant_cap == max(div(10, 2), 1) == 5)
      assert {:ok, _} = Admission.try_acquire({:tenant, "d"}, name)

      for _ <- 1..3, do: {:ok, _} = Admission.try_acquire({:tenant, "d"}, name)
      # "d" now holds 4 (one from the fresh admission above + 3 more) -- one
      # more attempt succeeds (5th, at cap), then rejects
      assert {:ok, _} = Admission.try_acquire({:tenant, "d"}, name)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "d"}, name)
    end

    test "deactivate -> reactivate -> stale pre-eviction releases never corrupt the fresh entry's in_use (Test 4)" do
      {_pid, name} = start_admission(pool_size: 7, reserved_headroom: 2)
      # global_cap == 5. A second tenant ("spectator") is tracked first so
      # that "a"'s own per_tenant_cap is a tight 2 (max(div(5, 2), 1) == 2)
      # while the GLOBAL cap (5) still has enough headroom to admit a
      # post-reactivation attempt on top of two still-live, pre-eviction
      # refs -- decoupling the tenant-cap boundary this test is pinning from
      # the global-cap arithmetic, which a single-tracked-tenant setup can't
      # do (per_tenant_cap always equals global_cap when only one tenant is
      # tracked).
      assert {:ok, _spectator_ref} = Admission.try_acquire({:tenant, "spectator"}, name)

      # two tracked tenants now -> per_tenant_cap == max(div(5, 2), 1) == 2
      ref1 = Admission.try_acquire({:tenant, "a"}, name) |> elem(1)
      ref2 = Admission.try_acquire({:tenant, "a"}, name) |> elem(1)
      # tenants["a"].in_use == 2 == per_tenant_cap, both refs live and
      # unreleased -- a third (pre-forget) attempt is rejected
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "a"}, name)

      assert :ok = Admission.forget_tenant("a", name)

      # a third admission attempt -- simulating a post-reactivation request
      # reaching the gate again -- starts a fresh epoch at in_use == 0 -> 1
      assert {:ok, _ref3} = Admission.try_acquire({:tenant, "a"}, name)
      # exactly one more succeeds (fresh in_use 1 -> 2, still == cap 2) --
      # if the fresh entry had wrongly inherited the discarded epoch's
      # in_use == 2, this would already reject; if in_use had started
      # corrupted/negative, more than one further success would be possible
      assert {:ok, _ref4} = Admission.try_acquire({:tenant, "a"}, name)
      # now fresh in_use == 2 == per_tenant_cap -- a further attempt rejects
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "a"}, name)

      # release the two STALE refs from the discarded epoch (captured at
      # generation 0; the fresh entry is generation 1) -- neither may raise,
      # and neither may free a slot in the fresh epoch
      assert :ok = Admission.release(ref1, name)
      assert :ok = Admission.release(ref2, name)

      # the fresh epoch's admission state is unchanged by those stale
      # releases: still at cap, not wrongly freed to 1/0/negative -- this is
      # the load-bearing assertion distinguishing this fix from both the
      # original crash/dilution bug and the rejected floor-clamp alternative
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "a"}, name)
    end
  end

  describe "atomicity (AC3 mutation-testing target)" do
    test "a rejected {:tenant, _} acquisition mutates neither counter" do
      {_pid, name} = start_admission(pool_size: 5, reserved_headroom: 2)
      # cap == 3, exhaust globally first
      {:ok, _} = Admission.try_acquire(:global, name)
      {:ok, _} = Admission.try_acquire(:global, name)
      {:ok, _} = Admission.try_acquire(:global, name)

      state_before = :sys.get_state(name)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "x"}, name)
      state_after = :sys.get_state(name)

      assert state_after.global_in_use == state_before.global_in_use
      # the tenant entry is still created (lazy tracking happens regardless
      # of outcome), but its in_use must remain 0 -- not incremented on a
      # rejected attempt
      assert state_after.tenants["x"].in_use == 0
    end
  end

  describe "T-1613: usage/1" do
    test "reports in_use and cap, following acquire and release" do
      {_pid, name} = start_admission(pool_size: 5, reserved_headroom: 2)
      cap = Admission.global_cap(name)
      assert %{in_use: 0, cap: ^cap} = Admission.usage(name)
      {:ok, ref} = Admission.try_acquire(:global, name)
      assert %{in_use: 1, cap: ^cap} = Admission.usage(name)
      :ok = Admission.release(ref, name)
      assert %{in_use: 0, cap: ^cap} = Admission.usage(name)
    end
  end
end
