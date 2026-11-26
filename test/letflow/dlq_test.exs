defmodule Letflow.DlqTest do
  @moduledoc """
  Tests for REQ-176 -- `Letflow.Dlq` (context module) and `Letflow.Dlq.Entry`
  (schema). See `test/specs/REQ-176.md` for the full acceptance-criterion ->
  test-case mapping and rationale. Design authority:
  `lib/letflow/design/req176-dlq-core.md` (commit 1959adf). Implementation
  authority: `lib/letflow/dlq.ex`/`lib/letflow/dlq/entry.ex` (commit b5a028d),
  which already passed SECURITY-REVIEWER and REVIEWER.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Each test that needs real rows provisions a real tenant schema via
  `Letflow.TenantFixture.provisioned_tenant!/1` (real `CREATE SCHEMA` +
  `TenantProvisioning.replay_migrations/1`), mirroring
  `test/letflow/definitions/promotion_test.exs`'s own established pattern for
  this class of context-module test. `async: false` for the same reason every
  other tenant-fixture-using test file in this codebase sets it (real schema
  creation/teardown against one shared Postgres instance).

  There is no route/controller for `Letflow.Dlq` yet (REQ-178's scope, design
  §0) -- every test below calls the context module's functions directly, the
  same way `test/letflow/definitions/promotion_test.exs` exercises
  `Letflow.Definitions.Promotion` with no HTTP layer in front of it yet.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Dlq
  alias Letflow.Dlq.Entry

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req176-dlq") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-176 DLQ Test Tenant"
    )
  end

  defp enqueue!(schema_name, attrs \\ %{}) do
    base = %{entry_type: "event"}
    {:ok, entry} = Dlq.enqueue(Map.merge(base, attrs), prefix: schema_name)
    entry
  end

  # No public function in `Letflow.Dlq` ever transitions an entry to
  # `:resolved` (design §3: only enqueue/list/get/retry/discard exist) -- the
  # only way to construct that starting state for the retry/2 conflict tests
  # is a direct, bypass-the-context-module write, exactly the same "force the
  # state directly" necessity `promotion_test.exs`'s own fixtures document
  # elsewhere in this codebase for states no public API produces.
  defp force_status!(schema_name, %Entry{} = entry, status) do
    entry
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!(prefix: schema_name)
  end

  # `retry_history` is a plain `{:array, :map}` jsonb column (design §2.2, no
  # `embeds_many`): an entry appended in-process (this request's own
  # `apply_retry/2`) is atom-keyed, while an entry that made a DB round-trip
  # decodes back as string-keyed. A single `Dlq.retry/2` call therefore can
  # return a *mixed* list -- some elements atom-keyed (freshly appended this
  # call), some string-keyed (already-persisted from an earlier call). This
  # normalizes either shape for assertions that care about values, not key
  # representation, which is not itself an acceptance criterion.
  defp normalize_attempt(attempt) do
    %{
      attempt_no: Map.get(attempt, :attempt_no) || Map.get(attempt, "attempt_no"),
      attempted_at: Map.get(attempt, :attempted_at) || Map.get(attempt, "attempted_at"),
      outcome: Map.get(attempt, :outcome) || Map.get(attempt, "outcome"),
      error_message: Map.get(attempt, :error_message, Map.get(attempt, "error_message"))
    }
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- dlq_entries lives inside the tenant's own Postgres schema, with a
  # tenant_id column retained (Decision B / decision 0003)
  # ---------------------------------------------------------------------------------

  describe "AC1: dlq_entries migration -- schema-per-tenant with tenant_id retained" do
    test "the table exists in the tenant's own schema, carries a tenant_id column, and is absent from public" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'dlq_entries'",
          [schema_name]
        )

      column_names = Enum.map(tenant_columns, fn [name] -> name end)
      assert "tenant_id" in column_names
      assert "id" in column_names
      assert "status" in column_names

      # The isolation boundary is the Postgres schema, not the tenant_id
      # column (design §1) -- confirmed by there being no dlq_entries table
      # in `public` at all.
      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'dlq_entries'"
        )

      assert public_rows == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- enqueue/2's initial state + list/2's tenant scoping
  # ---------------------------------------------------------------------------------

  describe "AC2: enqueue/2 initial state" do
    test "creates an entry with status pending, retry_count 0, empty retry_history, and a created_at timestamp" do
      %{schema_name: schema_name} = provisioned_tenant()

      entry = enqueue!(schema_name, %{entry_type: "event"})

      assert entry.status == :pending
      assert entry.retry_count == 0
      assert entry.retry_history == []
      assert %DateTime{} = entry.created_at

      # Persisted, not just the in-memory reply -- read it back.
      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :pending
      assert reloaded.retry_count == 0
      assert reloaded.retry_history == []
      assert %DateTime{} = reloaded.created_at
    end
  end

  describe "AC2: list/2 is tenant-scoped" do
    test "an entry enqueued under tenant A is absent from tenant B's list/2" do
      %{schema_name: schema_a} = provisioned_tenant("req176-dlq-a")
      %{schema_name: schema_b} = provisioned_tenant("req176-dlq-b")

      entry_a = enqueue!(schema_a, %{entry_type: "event"})

      {:ok, %{items: items_a}} = Dlq.list(%{cursor: nil, page_size: 10}, prefix: schema_a)
      {:ok, %{items: items_b}} = Dlq.list(%{cursor: nil, page_size: 10}, prefix: schema_b)

      assert Enum.map(items_a, & &1.id) == [entry_a.id]
      assert items_b == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- retry/2's four starting-status cases
  # ---------------------------------------------------------------------------------

  describe "AC3: retry/2 from :pending" do
    test "transitions to :retrying, appends a DlqRetryAttempt-shaped entry, increments retry_count" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)

      assert {:ok, updated} = Dlq.retry(entry.id, prefix: schema_name)

      assert updated.status == :retrying
      assert updated.retry_count == 1
      assert [attempt] = updated.retry_history

      # Exact DlqRetryAttempt field names -- attempt_no/attempted_at/outcome/error_message.
      assert Map.keys(attempt) |> Enum.sort() ==
               [:attempt_no, :attempted_at, :error_message, :outcome]

      assert attempt.attempt_no == 1
      assert is_binary(attempt.attempted_at)
      assert attempt.outcome == "failed"
      assert attempt.error_message == nil

      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :retrying
      assert reloaded.retry_count == 1
    end
  end

  describe "AC3: retry/2 from :retrying" do
    test "stays :retrying, appends a second retry_history entry, increments retry_count again" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)

      {:ok, first} = Dlq.retry(entry.id, prefix: schema_name)
      assert first.status == :retrying
      assert first.retry_count == 1

      assert {:ok, second} = Dlq.retry(entry.id, prefix: schema_name)

      assert second.status == :retrying
      assert second.retry_count == 2
      assert [attempt_1, attempt_2] = Enum.map(second.retry_history, &normalize_attempt/1)
      assert attempt_1.attempt_no == 1
      assert attempt_2.attempt_no == 2

      # Also confirmed on a fresh reload (uniformly string-keyed jsonb, no
      # in-process/DB-round-trip key-shape mismatch to account for).
      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert length(reloaded.retry_history) == 2
    end
  end

  describe "AC3: retry/2 from :resolved" do
    test "returns a conflict error and leaves status, retry_count, retry_history unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)
      resolved = force_status!(schema_name, entry, :resolved)

      assert {:error, {:invalid_state, :resolved}} = Dlq.retry(entry.id, prefix: schema_name)

      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :resolved
      assert reloaded.retry_count == resolved.retry_count
      assert reloaded.retry_history == resolved.retry_history
    end
  end

  describe "AC3: retry/2 from :discarded" do
    test "returns a conflict error and leaves status, retry_count, retry_history unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)
      {:ok, discarded} = Dlq.discard(entry.id, prefix: schema_name)
      assert discarded.status == :discarded

      assert {:error, {:invalid_state, :discarded}} = Dlq.retry(entry.id, prefix: schema_name)

      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :discarded
      assert reloaded.retry_count == discarded.retry_count
      assert reloaded.retry_history == discarded.retry_history
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- discard/2's terminal transitions + already-terminal conflicts
  # ---------------------------------------------------------------------------------

  describe "AC4: discard/2 from :pending" do
    test "transitions to :discarded" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)

      assert {:ok, updated} = Dlq.discard(entry.id, prefix: schema_name)
      assert updated.status == :discarded

      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :discarded
    end
  end

  describe "AC4: discard/2 from :retrying" do
    test "transitions to :discarded" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)
      {:ok, retrying} = Dlq.retry(entry.id, prefix: schema_name)
      assert retrying.status == :retrying

      assert {:ok, updated} = Dlq.discard(entry.id, prefix: schema_name)
      assert updated.status == :discarded
      # discard/2 does not touch retry_history/retry_count (design §3.5).
      assert updated.retry_count == retrying.retry_count

      assert Enum.map(updated.retry_history, &normalize_attempt/1) ==
               Enum.map(retrying.retry_history, &normalize_attempt/1)
    end
  end

  describe "AC4: discard/2 from :resolved" do
    test "returns a conflict error instead of silently succeeding" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)
      resolved = force_status!(schema_name, entry, :resolved)

      assert {:error, {:invalid_state, :resolved}} = Dlq.discard(entry.id, prefix: schema_name)

      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :resolved
      assert reloaded.retry_count == resolved.retry_count
    end
  end

  describe "AC4: discard/2 from :discarded (twice)" do
    test "the second call returns a conflict error instead of silently succeeding" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = enqueue!(schema_name)
      {:ok, first} = Dlq.discard(entry.id, prefix: schema_name)
      assert first.status == :discarded

      assert {:error, {:invalid_state, :discarded}} = Dlq.discard(entry.id, prefix: schema_name)

      reloaded = Repo.get!(Entry, entry.id, prefix: schema_name)
      assert reloaded.status == :discarded
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- list/2's independent entry_type/status filtering + cursor pagination
  # ---------------------------------------------------------------------------------

  describe "AC5: list/2 filters by entry_type and status independently" do
    test "entry_type narrows a result set containing more than one entry_type value" do
      %{schema_name: schema_name} = provisioned_tenant()
      event_entry = enqueue!(schema_name, %{entry_type: "event"})
      _timer_entry = enqueue!(schema_name, %{entry_type: "timer"})
      _webhook_entry = enqueue!(schema_name, %{entry_type: "webhook"})

      {:ok, %{items: items}} =
        Dlq.list(%{entry_type: "event", cursor: nil, page_size: 10}, prefix: schema_name)

      assert Enum.map(items, & &1.id) == [event_entry.id]
    end

    test "status narrows a result set containing more than one status value" do
      %{schema_name: schema_name} = provisioned_tenant()
      pending_entry = enqueue!(schema_name)
      retrying_source = enqueue!(schema_name)
      {:ok, retrying_entry} = Dlq.retry(retrying_source.id, prefix: schema_name)

      {:ok, %{items: pending_items}} =
        Dlq.list(%{status: "pending", cursor: nil, page_size: 10}, prefix: schema_name)

      {:ok, %{items: retrying_items}} =
        Dlq.list(%{status: "retrying", cursor: nil, page_size: 10}, prefix: schema_name)

      assert Enum.map(pending_items, & &1.id) == [pending_entry.id]
      assert Enum.map(retrying_items, & &1.id) == [retrying_entry.id]
    end

    test "entry_type and status filters combine without interacting" do
      %{schema_name: schema_name} = provisioned_tenant()
      target = enqueue!(schema_name, %{entry_type: "event"})
      _wrong_type = enqueue!(schema_name, %{entry_type: "timer"})
      wrong_status_source = enqueue!(schema_name, %{entry_type: "event"})
      {:ok, _wrong_status} = Dlq.retry(wrong_status_source.id, prefix: schema_name)

      {:ok, %{items: items}} =
        Dlq.list(
          %{entry_type: "event", status: "pending", cursor: nil, page_size: 10},
          prefix: schema_name
        )

      assert Enum.map(items, & &1.id) == [target.id]
    end
  end

  describe "AC5: list/2 cursor pagination" do
    test "rows older than 24 hours remain pageable" do
      %{schema_name: schema_name} = provisioned_tenant("cursor-issue-time-dlq")
      entries = for _ <- 1..3, do: enqueue!(schema_name)
      old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)
      Repo.update_all(Entry, [set: [created_at: old]], prefix: schema_name)

      assert {:ok, %{items: [_], next_cursor: cursor1}} =
               Dlq.list(%{cursor: nil, page_size: 1}, prefix: schema_name)

      assert {:ok, %{items: [_], next_cursor: cursor2}} =
               Dlq.list(%{cursor: cursor1, page_size: 1}, prefix: schema_name)

      assert {:ok, %{items: [_], next_cursor: nil}} =
               Dlq.list(%{cursor: cursor2, page_size: 1}, prefix: schema_name)

      assert length(entries) == 3
    end

    test "the first page's next_cursor, fed back, returns the next distinct page with no repeated or skipped ids" do
      %{schema_name: schema_name} = provisioned_tenant()

      entries = for _ <- 1..3, do: enqueue!(schema_name)
      all_ids = MapSet.new(entries, & &1.id)

      {:ok, %{items: page_1, next_cursor: cursor_1}} =
        Dlq.list(%{cursor: nil, page_size: 1}, prefix: schema_name)

      assert length(page_1) == 1
      refute is_nil(cursor_1)

      {:ok, %{items: page_2, next_cursor: cursor_2}} =
        Dlq.list(%{cursor: cursor_1, page_size: 1}, prefix: schema_name)

      assert length(page_2) == 1
      refute is_nil(cursor_2)

      {:ok, %{items: page_3, next_cursor: cursor_3}} =
        Dlq.list(%{cursor: cursor_2, page_size: 1}, prefix: schema_name)

      assert length(page_3) == 1
      assert is_nil(cursor_3)

      page_1_ids = Enum.map(page_1, & &1.id)
      page_2_ids = Enum.map(page_2, & &1.id)
      page_3_ids = Enum.map(page_3, & &1.id)
      seen_ids = page_1_ids ++ page_2_ids ++ page_3_ids

      # No repeats across pages.
      assert length(seen_ids) == length(Enum.uniq(seen_ids))
      # No skips -- the union across all pages is exactly the inserted set.
      assert MapSet.new(seen_ids) == all_ids
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- Letflow.Dlq and Letflow.Dlq.Entry are pure context/schema modules,
  # with no route or controller-shaped constructs of their own
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # ISS-0381 regression -- Entry.insert_changeset/2's cast/3 list must not
  # contradict its own docstring's claim that status/retry_count/
  # retry_history/tenant_id/created_at are "deliberately not castable". See
  # docs/issues/ISS-0381.yaml and
  # lib/letflow/design/iss0381-dlq-entry-insert-changeset-fix.md §9 (the exact
  # proof shape these two tests implement). These are changeset-level tests,
  # deliberately NOT routed through Dlq.enqueue/2 -- the whole point is to
  # prove the CHANGESET itself enforces the invariant, not enqueue/2's own
  # Map.take/2 caller discipline (which was already sufficient pre-fix and is
  # unchanged by this fix).
  # ---------------------------------------------------------------------------------

  describe "ISS-0381: insert_changeset/2 -- status/retry_count/retry_history cannot be caller-overridden" do
    test "a raw, unfiltered attrs map with non-default status/retry_count/retry_history is ignored in favor of schema defaults" do
      trusted_tenant_id = Ecto.UUID.generate()
      trusted_created_at = DateTime.utc_now() |> DateTime.truncate(:second)

      # Deliberately unfiltered/hand-built -- NOT enqueue/2's sanitized
      # insert_attrs map. A real attacker-shaped payload: every protected
      # field carries a value the caller should never be able to force.
      attrs = %{
        entry_type: "event",
        tenant_id: trusted_tenant_id,
        created_at: trusted_created_at,
        status: :discarded,
        retry_count: 7,
        retry_history: [
          %{
            attempt_no: 99,
            attempted_at: "2020-01-01T00:00:00Z",
            outcome: "failed",
            error_message: "forged"
          }
        ]
      }

      changeset = Entry.insert_changeset(%Entry{}, attrs)

      # Fail-first assertions (design §9): pre-fix, cast/3 cast all three of
      # these fields verbatim from attrs, so get_field/3 would have returned
      # :discarded / 7 / the forged list here. Post-fix, none of the three is
      # in cast/3's field list at all, so get_field/3 falls back to the
      # struct's own schema default.
      assert Ecto.Changeset.get_field(changeset, :status) == :pending
      assert Ecto.Changeset.get_field(changeset, :retry_count) == 0
      assert Ecto.Changeset.get_field(changeset, :retry_history) == []

      # tenant_id/created_at are NOT fail-first discriminating on their own
      # (design §9's own nuance) -- both cast/3 (pre-fix) and put_change/3
      # (post-fix) read the same attrs map, so a value round-trip passes on
      # both sides of the fix. Included here only as the "still required and
      # still supplied correctly" sanity check, not as regression proof.
      assert Ecto.Changeset.get_field(changeset, :tenant_id) == trusted_tenant_id
      assert Ecto.Changeset.get_field(changeset, :created_at) == trusted_created_at

      # The changeset is otherwise valid -- the forged fields are silently
      # overridden, not surfaced as validation errors, exactly like a
      # `cast/3` field list that simply never named them.
      assert changeset.valid?
    end
  end

  describe "ISS-0381: insert_changeset/2 -- tenant_id/created_at mechanism (cast/3 vs put_change/3 error-shape divergence)" do
    test "a malformed (non-UUID) tenant_id and a non-parseable created_at surface no changeset-level cast error, deferring failure past changeset validity" do
      attrs = %{
        entry_type: "event",
        tenant_id: "not-a-uuid",
        created_at: "not-a-timestamp"
      }

      changeset = Entry.insert_changeset(%Entry{}, attrs)

      # This is the discriminating, mechanism-level assertion design §9
      # specifies for these two fields -- a value round-trip is NOT
      # discriminating here (both cast/3 and put_change/3 read the same
      # attrs), so the proof is on changeset.valid?/changeset.errors
      # instead:
      #
      #   pre-fix:  tenant_id/created_at are in cast/3's field list ->
      #             Ecto.UUID/:utc_datetime type-casting is attempted on
      #             these raw strings, fails, and cast/3 adds an "is
      #             invalid" error for each to changeset.errors ->
      #             changeset.valid? == false.
      #   post-fix: tenant_id/created_at are NOT in cast/3's field list ->
      #             put_change/3 performs no type casting at all, writes the
      #             raw string straight into changeset.changes -> no cast
      #             error is added for either field -> changeset.valid? at
      #             this level is true (any type mismatch is deferred to
      #             Repo.insert/2, out of scope for a changeset-level test).
      assert changeset.valid?

      refute Keyword.has_key?(changeset.errors, :tenant_id)
      refute Keyword.has_key?(changeset.errors, :created_at)

      # put_change/3 wrote the raw, uncast value directly -- confirms the
      # mechanism (no type-casting attempted), not merely "some value is
      # present".
      assert Ecto.Changeset.get_change(changeset, :tenant_id) == "not-a-uuid"
      assert Ecto.Changeset.get_change(changeset, :created_at) == "not-a-timestamp"
    end
  end

  describe "AC6: Letflow.Dlq core itself has no route or controller-shaped constructs" do
    # NOTE: an earlier revision of this test scoped a `git show --stat` to
    # REQ-176's own implementation commit (b5a028d) -- that hardcoded SHA
    # stopped resolving once REQ-176's PR (#703) was squash-merged, which
    # rewrites history and drops the original commit entirely. A test that
    # depends on a specific commit surviving squash-merge is the same class
    # of local-branch-layout assumption this project's own anti-patterns doc
    # already warns against (see "A test that shells out to git with a
    # hardcoded ref name..."). It was then replaced with a check asserting no
    # router/controller file existed anywhere for `dlq` in the working tree --
    # but that premise is now obsolete too: REQ-178 (a separate, later,
    # gate-approved requirement) correctly and intentionally added
    # `lib/letflow/routers/dlq.ex` as the route layer atop this context
    # module. REQ-176's actual scope was never "no DLQ route ever exists" --
    # it was "this context/schema module itself contains no route or
    # controller-shaped constructs" (design authority
    # `lib/letflow/design/req176-dlq-core.md`). This test is scoped to that
    # narrower, still-true claim: `lib/letflow/dlq.ex` and
    # `lib/letflow/dlq/entry.ex` remain pure context/schema modules with no
    # `use Plug.Router`, no controller `use`, and no route macro defined
    # directly in either file. It says nothing about `lib/letflow/routers/`,
    # which is REQ-178's territory.
    test "neither Letflow.Dlq nor Letflow.Dlq.Entry references Plug/Router-shaped constructs" do
      for path <- ["lib/letflow/dlq.ex", "lib/letflow/dlq/entry.ex"] do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a route"
      end
    end
  end
end
