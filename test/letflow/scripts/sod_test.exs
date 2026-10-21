defmodule Letflow.Scripts.SodTest do
  @moduledoc """
  GH 2534 PR 7b-2b (decision 0053 D6 + amendment), design
  `lib/letflow/design/gh2534-7b2b-script-sod.md` sections 3-5, 8, 9, at the context level:

    * AC1: defaults (`strict`, solo forbidden) and the DB CHECK refusing solo while forbidden.
    * AC4: an allowed solo publish (`self_published`, `sod_excluded`, audit); a publisher outside
      the admin set is refused.
    * AC5: auto-strict in the NORMAL case (step B) commits the flip with one audit entry and runs
      no stored test; a non-contributor publish with two admins does not flip.
    * AC5b: the BACKSTOP (second admin added during the stored tests, via `:before_case`).
    * AC6: under `strict` a contributor publish is refused without taking the admin lock.
    * AC7: the `script_rules_guard()` rules of design 3.3 (raw writes, LF001).
    * AC8: the derived pending-review list as the admin set changes (group member, token mint,
      deactivation, token revoke, token expiry).
    * AC9: `confirm/5` at context level, including the SEC F2 discarded-draft contributor.
    * AC10: the source-order scan, a per-key lock holder not blocking step B, the real
      publish's query order (admin lock first, never again after the key lock) and the stored
      tests running outside any transaction.
    * AC11: a solo publish racing a real `Identity.add_group_member/3`, both orders forced with
      the telemetry probe.

  Admins are created through the real GH #2547 paths (`add_group_member/3`,
  `create_token/3`), so the count is the helper's. Real committed state (`:auto` sandbox);
  every cross-process wait is bounded.

  TDV 6: the cross-process tests (AC6, AC10, AC11) rely on `TenantFixture.provisioned_tenant!/1`
  switching the sandbox to `:auto` (`test/support/tenant_fixture.ex:247`,
  `Sandbox.mode(Letflow.Repo, :auto)`), so each `Task` checks out its own connection and sees
  committed state.

  `async: false`: real committed state, cross-connection advisory locks.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Scripts
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.TenantFixture

  @manifest %{
    "input_schema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}},
    "output_schema" => %{"type" => "object", "properties" => %{"y" => %{"type" => "integer"}}},
    "fail_codes" => []
  }

  @passing [
    %{"name" => "one", "input" => %{"x" => 1}, "expect" => %{"output" => %{"y" => 2}}},
    %{"name" => "two", "input" => %{"x" => 2}, "expect" => %{"output" => %{"y" => 4}}}
  ]

  # Would yield :test_case_failed if it ran.
  @failing [%{"name" => "wrong", "input" => %{"x" => 1}, "expect" => %{"output" => %{"y" => 99}}}]

  @admin_lock_sql "pg_advisory_xact_lock($1::bigint)"

  setup do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7b2b-sod")
    SP.seed_roles!(fx.schema_name)
    {:ok, schema: fx.schema_name, tenant_id: fx.tenant_id}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp key, do: "sod_#{System.unique_integer([:positive])}"

  defp body(cases),
    do: %{
      "hook_kind" => "service_task",
      "source" => "return {y = ctx.input.x * 2}",
      "manifest" => @manifest,
      "test_cases" => cases
    }

  defp draft!(schema, k, author, cases \\ @passing) do
    {:ok, rule} = Scripts.create_draft(schema, k, body(cases), SP.actor(author))
    rule
  end

  defp publish(schema, rule, publisher, opts \\ []),
    do:
      Scripts.publish(
        schema,
        rule.key,
        rule.version,
        rule.sha256,
        SP.actor(publisher),
        false,
        opts
      )

  defp row(schema, k, v \\ 1), do: Repo.get_by!(ScriptRule, [key: k, version: v], prefix: schema)
  defp policy(schema), do: Repo.get!(ScriptPolicy, 1, prefix: schema)

  defp published!(schema, k, publisher, author) do
    rule = draft!(schema, k, author)
    assert {:ok, published} = publish(schema, rule, publisher)
    published
  end

  defp assert_lf001(fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.pg_code == "LF001"
  end

  defp raw_update(schema, k, set),
    do: Repo.update_all(from(r in ScriptRule, where: r.key == ^k), [set: set], prefix: schema)

  defp auto_strict_entries(schema), do: SP.entries(schema, "script_policy.sod_auto_strict")

  # A process holding `fun`'s locks in an open transaction until `:release` (bounded 10 s).
  defp hold_in_transaction(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          fun.()
          send(parent, :held)

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end

          Repo.rollback(:released)
        end)
      end)

    assert_receive :held, 5_000
    task
  end

  defp release(task) do
    send(task.pid, :release)
    Task.await(task, 15_000)
  end

  # Bounded poll (~5 s): true once a backend waits on a lock running a statement like `pattern`.
  defp lock_waiter?(pattern) do
    Enum.reduce_while(1..500, false, fn _, _ ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
            "AND wait_event_type = 'Lock' AND query ILIKE $1",
          ["%" <> pattern <> "%"]
        )

      if n >= 1 do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  # ── AC1 ────────────────────────────────────────────────────────────────────

  describe "AC1 defaults" do
    test "declared strict, solo forbidden; the DB refuses solo_audited while forbidden", ctx do
      p = policy(ctx.schema)
      assert {p.sod, p.platform_solo_audited_allowed} == {:strict, false}
      assert Policy.effective_sod(ctx.schema) == {:strict, :declared_strict}

      assert_raise Postgrex.Error, ~r/script_policy_solo_requires_platform/, fn ->
        Repo.update_all(ScriptPolicy, [set: [sod: :solo_audited]], prefix: ctx.schema)
      end

      assert_raise Postgrex.Error, ~r/script_policy_sod_value/, fn ->
        # Schemaless source: the Ecto.Enum would refuse "lenient" before the DB sees it.
        Repo.update_all("script_policy", [set: [sod: "lenient"]], prefix: ctx.schema)
      end
    end
  end

  # ── AC4 ────────────────────────────────────────────────────────────────────

  describe "AC4 solo publish" do
    test "the sole admin publishes their own version: self_published, sod_excluded, audited",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      assert Policy.effective_sod(ctx.schema) == {:solo_audited, :solo_allowed}

      k = key()
      rule = draft!(ctx.schema, k, a)
      assert {:ok, published} = publish(ctx.schema, rule, a)
      assert published.self_published
      assert published.sod_excluded == [a]
      assert published.publisher_id == a

      [entry] =
        SP.entries(ctx.schema, "script_rule.published")
        |> Enum.filter(&(&1.after_state["key"] == k))

      assert entry.after_state["self_published"] == true
      assert entry.after_state["sod_excluded"] == [a]
      assert policy(ctx.schema).sod == :solo_audited
    end

    test "a contributor outside the admin set (count 1, someone else) is refused, no flip", ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      outsider = SP.user!(ctx.schema)

      rule = draft!(ctx.schema, key(), outsider)
      assert publish(ctx.schema, rule, outsider) == {:error, :publisher_is_contributor}
      refute row(ctx.schema, rule.key).self_published
      assert row(ctx.schema, rule.key).status == :draft
      assert policy(ctx.schema).sod == :solo_audited
      assert auto_strict_entries(ctx.schema) == []
    end

    test "a non-contributor publish stores sod_excluded = contributors + publisher, not self-published",
         ctx do
      author = Ecto.UUID.generate()
      publisher = Ecto.UUID.generate()
      published = published!(ctx.schema, key(), publisher, author)

      refute published.self_published
      assert Enum.sort(published.sod_excluded) == Enum.sort([author, publisher])
    end
  end

  # ── AC5 / AC5b ─────────────────────────────────────────────────────────────

  describe "AC5 auto-strict" do
    test "NORMAL case: second admin added before the request -> 403, flipped to strict, one audit entry, no stored test ran",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      SP.admin!(ctx.schema)

      rule = draft!(ctx.schema, key(), a, @failing)

      # a run would have answered :test_case_failed
      assert publish(ctx.schema, rule, a) == {:error, :publisher_is_contributor}

      p = policy(ctx.schema)

      assert {p.sod, p.sod_set_by_class, p.sod_set_by, p.sod_reason} ==
               {:strict, "system", nil, "auto_strict"}

      assert [entry] = auto_strict_entries(ctx.schema)
      assert entry.actor_id == a
      assert entry.before_state == %{"sod" => "solo_audited"}

      assert entry.after_state == %{
               "sod" => "strict",
               "set_by_class" => "system",
               "cause" => "tenant_wide_admin_count",
               "admin_count" => 2,
               "key" => rule.key,
               "version" => 1
             }

      assert row(ctx.schema, rule.key).status == :draft
      assert Policy.effective_sod(ctx.schema) == {:strict, :declared_strict}
    end

    test "a non-contributor publish with two admins does not flip", ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      b = SP.admin!(ctx.schema)
      assert Policy.effective_sod(ctx.schema) == {:strict, :multiple_admins}

      published = published!(ctx.schema, key(), b, a)
      refute published.self_published
      assert policy(ctx.schema).sod == :solo_audited
      assert auto_strict_entries(ctx.schema) == []
    end

    test "BACKSTOP: a second admin added during the stored tests (after step B) -> step D refuses and the flip is committed",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      rule = draft!(ctx.schema, key(), a)
      test_pid = self()

      hook = fn
        1 ->
          send(test_pid, {:in_transaction_during_tests, Repo.in_transaction?()})
          SP.admin!(ctx.schema)

        _ ->
          :ok
      end

      assert publish(ctx.schema, rule, a, before_case: hook) ==
               {:error, :publisher_is_contributor}

      assert_received {:in_transaction_during_tests, false}
      assert policy(ctx.schema).sod == :strict
      assert [entry] = auto_strict_entries(ctx.schema)
      assert entry.after_state["admin_count"] == 2
      assert row(ctx.schema, rule.key).status == :draft
      refute row(ctx.schema, rule.key).self_published
    end
  end

  # ── AC6 ────────────────────────────────────────────────────────────────────

  describe "AC6 strict declared" do
    test "a contributor publish is refused at once: no admin lock, no flip, no test run", ctx do
      author = SP.admin!(ctx.schema)
      rule = draft!(ctx.schema, key(), author, @failing)
      holder = hold_in_transaction(fn -> Identity.lock_tenant_admins!(ctx.schema) end)

      try do
        task = Task.async(fn -> publish(ctx.schema, rule, author) end)
        assert Task.yield(task, 5_000) == {:ok, {:error, :publisher_is_contributor}}
      after
        release(holder)
      end

      assert auto_strict_entries(ctx.schema) == []
      refute row(ctx.schema, rule.key).self_published
      assert policy(ctx.schema).sod == :strict
    end
  end

  # ── AC7 trigger ────────────────────────────────────────────────────────────

  describe "AC7 script_rules_guard()" do
    test "publish shapes: self_published under strict, missing or incomplete sod_excluded", ctx do
      author = Ecto.UUID.generate()
      other = Ecto.UUID.generate()
      k = key()
      draft!(ctx.schema, k, author)
      now = DateTime.utc_now()
      base = [status: :published, published_at: now]

      for set <- [
            # TDV 1: a contributor publishing NOT self-published, sod_excluded valid
            base ++ [publisher_id: author, self_published: false, sod_excluded: [author]],
            # self_published while the policy is strict
            base ++ [publisher_id: author, self_published: true, sod_excluded: [author]],
            # without sod_excluded
            base ++ [publisher_id: other],
            # a contributor missing from it
            base ++ [publisher_id: other, sod_excluded: [other]],
            # the publisher missing from it
            base ++ [publisher_id: other, sod_excluded: [author]],
            # confirmation columns at publish
            base ++
              [
                publisher_id: other,
                sod_excluded: [author, other],
                confirmed_by: other,
                confirmed_at: now,
                confirmed_sha256: "x"
              ]
          ] do
        assert_lf001(fn -> raw_update(ctx.schema, k, set) end)
      end

      # a draft never carries sod state
      assert_lf001(fn -> raw_update(ctx.schema, k, sod_excluded: [author]) end)
      assert_lf001(fn -> raw_update(ctx.schema, k, self_published: true) end)
      assert row(ctx.schema, k).status == :draft

      # the well-formed non-solo publish passes the trigger
      assert {1, _} =
               raw_update(
                 ctx.schema,
                 k,
                 base ++ [publisher_id: other, sod_excluded: [author, other]]
               )
    end

    test "TDV 1: under a declared, allowed solo policy a contributor publish NOT marked self_published is still refused",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      k = key()
      draft!(ctx.schema, k, a)

      assert_lf001(fn ->
        raw_update(ctx.schema, k,
          status: :published,
          published_at: DateTime.utc_now(),
          publisher_id: a,
          self_published: false,
          sod_excluded: [a]
        )
      end)

      assert row(ctx.schema, k).status == :draft
    end

    test "SECURITY F2: a raw INSERT must be a plain draft (status, self_published, sod_excluded, confirmed_*)",
         ctx do
      now = DateTime.utc_now()
      who = Ecto.UUID.generate()

      base = %ScriptRule{
        key: key(),
        version: 1,
        hook_kind: "service_task",
        status: :draft,
        source: "return {y = 1}",
        manifest: @manifest,
        test_cases: @passing,
        sha256: "x",
        contributors: [who]
      }

      for {label, rule} <- [
            {"published", %{base | status: :published, publisher_id: who, published_at: now}},
            {"retired", %{base | status: :retired}},
            {"self_published", %{base | self_published: true}},
            {"sod_excluded", %{base | sod_excluded: [who]}},
            {"confirmed", %{base | confirmed_by: who, confirmed_at: now, confirmed_sha256: "x"}}
          ] do
        error = assert_raise Postgrex.Error, fn -> Repo.insert!(rule, prefix: ctx.schema) end
        assert error.postgres.pg_code == "LF001", label
      end

      assert Repo.all(ScriptRule, prefix: ctx.schema) == []

      # control: a plain draft inserts
      assert %ScriptRule{} = Repo.insert!(base, prefix: ctx.schema)
    end

    test "self_published is accepted only while solo is declared and allowed", ctx do
      a = SP.admin!(ctx.schema)
      k = key()
      draft!(ctx.schema, k, a)
      set = [status: :published, published_at: DateTime.utc_now(), publisher_id: a]
      solo = set ++ [self_published: true, sod_excluded: [a]]

      SP.allow_solo!(ctx.schema, ctx.tenant_id)
      # allowed but declared strict
      assert_lf001(fn -> raw_update(ctx.schema, k, solo) end)

      {:ok, _} = Policy.set_sod(ctx.schema, "solo_audited", "r", SP.actor(a))
      assert {1, _} = raw_update(ctx.schema, k, solo)
    end

    test "published rows: self_published and sod_excluded immutable; confirmation shape rules",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      outsider = Ecto.UUID.generate()

      solo = published!(ctx.schema, key(), a, a)
      plain = published!(ctx.schema, key(), Ecto.UUID.generate(), Ecto.UUID.generate())
      revoked = published!(ctx.schema, key(), a, a)

      {:ok, _} = Scripts.revoke(ctx.schema, revoked.key, 1, "r", SP.actor(a))

      now = DateTime.utc_now()
      confirm = fn by, sha -> [confirmed_by: by, confirmed_at: now, confirmed_sha256: sha] end

      for set <- [
            [self_published: false],
            [sod_excluded: [a, outsider]],
            [sod_excluded: nil],
            # by a member of sod_excluded
            confirm.(a, solo.sha256),
            # wrong sha
            confirm.(outsider, String.duplicate("0", 64)),
            # partial
            [confirmed_by: outsider]
          ] do
        assert_lf001(fn -> raw_update(ctx.schema, solo.key, set) end)
      end

      # not self-published; revoked
      assert_lf001(fn -> raw_update(ctx.schema, plain.key, confirm.(outsider, plain.sha256)) end)

      assert_lf001(fn ->
        raw_update(ctx.schema, revoked.key, confirm.(outsider, revoked.sha256))
      end)

      # the valid confirmation passes; a second one does not
      assert {1, _} = raw_update(ctx.schema, solo.key, confirm.(outsider, solo.sha256))

      assert_lf001(fn ->
        raw_update(ctx.schema, solo.key, confirm.(Ecto.UUID.generate(), solo.sha256))
      end)

      # retire keeps the confirmation; changing it on retire is refused
      assert_lf001(fn ->
        raw_update(ctx.schema, solo.key,
          status: :retired,
          retired_at: now,
          confirmed_by: Ecto.UUID.generate()
        )
      end)

      assert {:ok, _} = Scripts.retire(ctx.schema, solo.key, 1, "r", SP.actor(a))
    end

    test "a NULL element in sod_excluded is refused by the table constraint (a publish the trigger accepts)",
         ctx do
      k = key()
      author = Ecto.UUID.generate()
      draft!(ctx.schema, k, author)
      publisher = Ecto.UUID.generate()

      assert_raise Postgrex.Error, ~r/script_rules_sod_excluded_no_null/, fn ->
        Repo.query!(
          ~s|UPDATE "#{ctx.schema}".script_rules SET status = 'published', published_at = now(), | <>
            ~s|publisher_id = $2, sod_excluded = ARRAY[$3::uuid, $2::uuid, NULL::uuid] WHERE key = $1|,
          [k, Ecto.UUID.dump!(publisher), Ecto.UUID.dump!(author)]
        )
      end

      assert row(ctx.schema, k).status == :draft
    end
  end

  # ── AC8 ────────────────────────────────────────────────────────────────────

  describe "AC8 pending review (derived at read time)" do
    test "appears once a second admin exists; revoked and confirmed never; follows deactivation, token mint, revoke and expiry",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)

      [k1, k2, k3] = Enum.sort([key(), key(), key()])
      published!(ctx.schema, k1, a, a)
      published!(ctx.schema, k2, a, a)
      published!(ctx.schema, k3, a, a)
      {:ok, _} = Scripts.retire(ctx.schema, k2, 1, "r", SP.actor(a))
      {:ok, _} = Scripts.revoke(ctx.schema, k3, 1, "r", SP.actor(a))
      # a plain (non-self) published version never appears
      published!(ctx.schema, key(), Ecto.UUID.generate(), Ecto.UUID.generate())

      listed = fn -> ctx.schema |> Policy.pending_review() |> elem(0) |> Enum.map(& &1.key) end

      assert Policy.pending_review(ctx.schema) == {[], false}

      # group member: no identity hook, adding then reading is enough
      b = SP.admin!(ctx.schema)
      assert listed.() == [k1, k2]
      assert {_, false} = Policy.pending_review(ctx.schema)

      # deactivating b drops the count to 1
      {:ok, _} =
        Identity.update_user_status(b, :inactive, prefix: ctx.schema, login_directory: :skip)

      assert listed.() == []

      # a TENANT_ADMIN token of an active user counts; revoking it does not
      {_c, token_id} = SP.token_admin!(ctx.schema)
      assert listed.() == [k1, k2]
      {:ok, _} = Identity.revoke_token(token_id, prefix: ctx.schema)
      assert listed.() == []

      # an expired token does not count
      {_d, token2} = SP.token_admin!(ctx.schema)
      assert listed.() == [k1, k2]

      Repo.update_all(
        from(t in Letflow.Identity.ApiToken, where: t.id == ^token2),
        [
          set: [expires_at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)]
        ],
        prefix: ctx.schema
      )

      assert listed.() == []

      # confirmed leaves the list
      {:ok, _} =
        Identity.update_user_status(b, :active, prefix: ctx.schema, login_directory: :skip)

      assert listed.() == [k1, k2]
      {:ok, _} = Scripts.confirm(ctx.schema, k1, 1, row(ctx.schema, k1).sha256, SP.actor(b))
      assert listed.() == [k2]
    end
  end

  # ── AC9 ────────────────────────────────────────────────────────────────────

  describe "AC9 confirm" do
    setup ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      c = SP.user!(ctx.schema)
      d = SP.user!(ctx.schema)
      k = key()

      # c authored a DISCARDED v1; d authored v2, a saved it; a self-publishes v2
      draft!(ctx.schema, k, c)
      {:ok, _} = Scripts.discard(ctx.schema, k, 1, SP.actor(c))
      draft!(ctx.schema, k, d)
      {:ok, saved} = Scripts.save_draft(ctx.schema, k, 2, body(@passing), SP.actor(a))
      assert {:ok, published} = publish(ctx.schema, saved, a)
      assert published.self_published
      assert Enum.sort(published.sod_excluded) == Enum.sort([a, c, d])

      # c and d become counted admins AFTER the publish
      SP.make_admin!(ctx.schema, c)
      SP.make_admin!(ctx.schema, d)
      b = SP.admin!(ctx.schema)

      {:ok, a: a, b: b, c: c, d: d, key: k, sha: published.sha256}
    end

    test "the publisher, a contributor of this version and of a discarded earlier draft are each refused",
         ctx do
      for who <- [ctx.a, ctx.c, ctx.d] do
        assert Scripts.confirm(ctx.schema, ctx.key, 2, ctx.sha, SP.actor(who)) ==
                 {:error, :confirmer_is_contributor}
      end

      assert is_nil(row(ctx.schema, ctx.key, 2).confirmed_at)
    end

    test "refusals: non-admin, stale sha, API token, unknown and discarded versions", ctx do
      outsider = SP.user!(ctx.schema)

      assert Scripts.confirm(ctx.schema, ctx.key, 2, ctx.sha, SP.actor(outsider)) ==
               {:error, :not_tenant_wide_admin}

      assert Scripts.confirm(ctx.schema, ctx.key, 2, String.duplicate("0", 64), SP.actor(ctx.b)) ==
               {:error, :content_changed}

      assert Scripts.confirm(ctx.schema, ctx.key, 2, ctx.sha, %{
               user_id: ctx.b,
               credential: :api_token
             }) == {:error, :api_token_not_allowed}

      for v <- [1, 99, "abc"] do
        assert Scripts.confirm(ctx.schema, ctx.key, v, ctx.sha, SP.actor(ctx.b)) ==
                 {:error, :not_found}
      end

      assert Scripts.confirm(ctx.schema, key(), 1, ctx.sha, SP.actor(ctx.b)) ==
               {:error, :not_found}
    end

    test "TDV 2: a RETIRED self-published version is confirmable (S6) and leaves the list", ctx do
      {:ok, _} = Scripts.retire(ctx.schema, ctx.key, 2, "superseded", SP.actor(ctx.a))
      assert {[pending], false} = Policy.pending_review(ctx.schema)
      assert {pending.key, pending.status} == {ctx.key, :retired}

      assert {:ok, confirmed} = Scripts.confirm(ctx.schema, ctx.key, 2, ctx.sha, SP.actor(ctx.b))
      assert {confirmed.status, confirmed.confirmed_by} == {:retired, ctx.b}
      assert row(ctx.schema, ctx.key, 2).confirmed_sha256 == ctx.sha
      assert Policy.pending_review(ctx.schema) == {[], false}
    end

    test "a counted admin outside sod_excluded confirms; audited; then not pending; non-self-published not pending",
         ctx do
      assert {:ok, confirmed} = Scripts.confirm(ctx.schema, ctx.key, 2, ctx.sha, SP.actor(ctx.b))
      assert confirmed.confirmed_by == ctx.b
      assert confirmed.confirmed_sha256 == ctx.sha
      assert confirmed.confirmed_at

      [entry] = SP.entries(ctx.schema, "script_rule.confirmed")
      assert entry.actor_id == ctx.b
      assert entry.after_state["confirmed_by"] == ctx.b
      assert entry.after_state["confirmed_sha256"] == ctx.sha
      assert entry.after_state["publisher_id"] == ctx.a
      assert Enum.sort(entry.after_state["sod_excluded"]) == Enum.sort([ctx.a, ctx.c, ctx.d])

      assert Scripts.confirm(ctx.schema, ctx.key, 2, ctx.sha, SP.actor(ctx.b)) ==
               {:error, :not_pending_review}

      plain = published!(ctx.schema, key(), ctx.b, Ecto.UUID.generate())

      assert Scripts.confirm(ctx.schema, plain.key, 1, plain.sha256, SP.actor(ctx.c)) ==
               {:error, :not_pending_review}
    end
  end

  # ── AC10 lock order ────────────────────────────────────────────────────────

  describe "AC10 lock order" do
    @scripts_src File.read!("lib/letflow/scripts.ex")
    @policy_src File.read!("lib/letflow/scripts/policy.ex")

    # The text of `def(p) name(` up to the next top-level def/defp/@doc.
    defp body_of(src, name) do
      [_, rest] = Regex.split(~r/\n  defp? #{name}\(/, src, parts: 2)
      [body | _] = Regex.split(~r/\n  (defp? |@doc|@spec)/, rest, parts: 2)
      body
    end

    test "source scan: lock_tenant_admins! precedes every other lock and the audit in each 7b-2b transaction" do
      for {src, name} <- [
            {@scripts_src, "publish_transaction"},
            {@scripts_src, "confirm"},
            {@policy_src, "solo_gate"},
            {@policy_src, "set_sod"},
            {@policy_src, "set_platform_solo_audited"}
          ] do
        body = body_of(src, name)
        {admin, _} = :binary.match(body, "lock_tenant_admins!(")

        for later <- ["lock_key!(", "lock_row!(", "lock_policy!(", "FOR UPDATE", "audit!("] do
          case :binary.match(body, later) do
            {pos, _} -> assert admin < pos, "#{name}: #{later} before lock_tenant_admins!"
            :nomatch -> :ok
          end
        end

        assert length(:binary.matches(body, "lock_tenant_admins!(")) == 1, name
      end

      # step D re-enters the gate with the admin lock already held, never re-taking it
      [_, gate_clause] =
        String.split(@scripts_src, "defp sod_decision(prefix, actor, rule, true)")

      [gate_clause | _] = String.split(gate_clause, "\n  defp ", parts: 2)
      assert gate_clause =~ "admin_lock_held: true"
      refute gate_clause =~ "lock_tenant_admins!"
    end

    test "a process holding the per-key lock does not block step B", ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      SP.admin!(ctx.schema)
      rule = draft!(ctx.schema, key(), a)

      holder =
        hold_in_transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
            ctx.schema <> ":script_rules:" <> rule.key
          ])
        end)

      try do
        task = Task.async(fn -> publish(ctx.schema, rule, a) end)
        assert Task.yield(task, 5_000) == {:ok, {:error, :publisher_is_contributor}}
      after
        release(holder)
      end

      assert [_] = auto_strict_entries(ctx.schema)
    end

    test "the real solo publish: admin lock first in steps B and D, never again after the key lock",
         ctx do
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      rule = draft!(ctx.schema, key(), a)

      {{:ok, published}, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> publish(ctx.schema, rule, a) end)

      assert published.self_published
      sql = Enum.map(queries, &(Map.get(&1, :query) || ""))

      idx = fn pred ->
        sql |> Enum.with_index() |> Enum.filter(&pred.(elem(&1, 0))) |> Enum.map(&elem(&1, 1))
      end

      admin = idx.(&String.contains?(&1, @admin_lock_sql))
      key_lock = idx.(&String.contains?(&1, "hashtext"))
      rule_row = idx.(&(&1 =~ ~s("script_rules") and &1 =~ "FOR UPDATE"))
      policy_row = idx.(&(&1 =~ ~s("script_policy") and &1 =~ "FOR UPDATE"))
      begins = idx.(&(&1 == "begin"))

      # B and D each take it once
      assert [b_admin, d_admin] = admin
      assert [d_key] = key_lock
      assert [b_policy, d_policy] = policy_row
      assert [d_row] = rule_row

      # step B: the admin lock is its transaction's first statement
      assert Enum.any?(begins, &(&1 == b_admin - 1))
      assert b_admin < b_policy and b_policy < d_admin
      # step D: admin lock, key lock, rule row, policy row
      assert Enum.any?(begins, &(&1 == d_admin - 1))
      assert d_admin < d_key and d_key < d_row and d_row < d_policy
      refute Enum.any?(admin, &(&1 > d_key))
    end
  end

  # ── AC11 concurrency ───────────────────────────────────────────────────────

  describe "AC11 solo publish racing a real group-member add" do
    setup ctx do
      SP.attach_probe!()
      a = SP.admin!(ctx.schema)
      SP.solo!(ctx.schema, ctx.tenant_id, a)
      second = SP.user!(ctx.schema)
      rule = draft!(ctx.schema, key(), a)
      {:ok, a: a, second: second, rule: rule}
    end

    test "grant commits first: the publish is refused and auto-strict is committed", ctx do
      test_pid = self()

      grant =
        Task.async(fn ->
          SP.arm_probe(test_pid, &String.contains?(&1, @admin_lock_sql))
          SP.make_admin!(ctx.schema, ctx.second)
        end)

      assert_receive {:probe_hit, grant_pid}, 15_000
      publisher = Task.async(fn -> publish(ctx.schema, ctx.rule, ctx.a) end)

      try do
        assert lock_waiter?(@admin_lock_sql)
      after
        send(grant_pid, :probe_continue)
      end

      Task.await(grant, 15_000)
      assert Task.await(publisher, 15_000) == {:error, :publisher_is_contributor}
      assert policy(ctx.schema).sod == :strict
      assert [_] = auto_strict_entries(ctx.schema)
      assert row(ctx.schema, ctx.rule.key).status == :draft
    end

    test "publish commits first: self_published, then pending review once the grant lands", ctx do
      test_pid = self()

      publisher =
        Task.async(fn ->
          SP.arm_probe(test_pid, &(&1 =~ ~s("script_rules") and &1 =~ "FOR UPDATE"))
          publish(ctx.schema, ctx.rule, ctx.a)
        end)

      assert_receive {:probe_hit, publisher_pid}, 15_000
      grant = Task.async(fn -> SP.make_admin!(ctx.schema, ctx.second) end)

      try do
        assert lock_waiter?(@admin_lock_sql)
      after
        send(publisher_pid, :probe_continue)
      end

      assert {:ok, published} = Task.await(publisher, 15_000)
      Task.await(grant, 15_000)

      assert published.self_published
      assert auto_strict_entries(ctx.schema) == []
      assert {[pending], false} = Policy.pending_review(ctx.schema)
      assert pending.key == ctx.rule.key
    end
  end
end
