defmodule Letflow.AuditTest do
  @moduledoc """
  Tests for `Letflow.Audit` (REQ-195) -- the storage/chaining primitives
  themselves: DB-level immutability (AC1), tenant scoping (AC4), chain
  linkage including the first-entry-null case (AC5), and the
  recompute-based `verify_chain/2` (AC6, the single most important test in
  this requirement -- see this module's own moduledoc for why R-Co's own
  linkage-only check is the defect this must not repeat). AC2/AC3 (real
  before/after capture on definition/instance/task operations, and
  audit-write-failure rollback) are covered in
  `test/letflow/audit_capture_test.exs`, against the actual covered context
  functions rather than `Letflow.Audit` directly.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), does not share
  fixtures with any other test file (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file wraps provisioning in
  # SandboxAutoMode.provision!/2 and needs its own on_exit to force :auto mode
  # back on before the drop/delete cleanup and restore :manual afterward (the
  # ISS-0580 leak fix) -- TenantFixture's own default teardown does not do that
  # composition, so it stays disabled and this file's pre-existing on_exit is
  # kept untouched, matching category A's documented pattern.
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req195-audit",
          display_name: "REQ-195 Audit Test Tenant",
          teardown: false
        )

      on_exit(fn ->
        # ISS-0580 rework: this callback runs AFTER the test process (and thus
        # SandboxAutoMode.provision!/2's own restore-to-:manual-plus-checkout,
        # scoped to that now-gone process) is gone -- so it must not assume
        # :manual mode still has a connection checked out for THIS (OnExitHandler)
        # process. Force :auto mode first so the DROP SCHEMA/delete_all cleanup
        # below always gets a real, checked-in connection regardless of what mode
        # the test process left the pool in. Mirrors role_registry_test.exs's own
        # on_exit/1 handling of this exact hazard.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))

        # REVIEWER fix (ISS-0580): restore :manual after cleanup -- leaving the
        # force-:auto above unrestored would reopen this exact leak, once per
        # test in this file instead of once ever. No checkout needed (same
        # reasoning as SandboxAutoMode.exit_auto_mode!/1's own doc: this
        # OnExitHandler process is not going to issue another Repo call).
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
  end

  defp base_attrs(overrides \\ []) do
    Map.merge(
      %{
        actor_id: nil,
        action: "definition.create",
        resource_type: "definition",
        resource_id: Ecto.UUID.generate(),
        before_state: nil,
        after_state: %{"name" => "sample", "version" => "1.0.0"},
        trace_id: nil
      },
      Map.new(overrides)
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- DB-level immutability, going around the Ecto schema entirely
  # (raw SQL, not Repo.update/1's changeset path).
  # ---------------------------------------------------------------------------------

  describe "AC1 -- immutability enforced by the database" do
    test "a raw UPDATE against a persisted row is rejected by a trigger" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{id: id}} = Audit.insert_entry(Repo, base_attrs(), schema_name)

      assert_raise Postgrex.Error, ~r/audit_entries is immutable/, fn ->
        Repo.query!(
          ~s(UPDATE "#{schema_name}".audit_entries SET action = 'tampered' WHERE id = $1),
          [Ecto.UUID.dump!(id)]
        )
      end
    end

    test "a raw DELETE against a persisted row is rejected by a trigger" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{id: id}} = Audit.insert_entry(Repo, base_attrs(), schema_name)

      assert_raise Postgrex.Error, ~r/audit_entries is immutable/, fn ->
        Repo.query!(~s(DELETE FROM "#{schema_name}".audit_entries WHERE id = $1), [
          Ecto.UUID.dump!(id)
        ])
      end

      # The row survived the rejected DELETE -- immutability, not merely an
      # error being raised for an unrelated reason.
      assert Repo.get(Entry, id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- tenant scoping.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- tenant-scoped rows" do
    test "a row written under tenant A is not visible to a query scoped to tenant B" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      assert {:ok, %Entry{id: id_a}} = Audit.insert_entry(Repo, base_attrs(), schema_a)

      assert Repo.get(Entry, id_a, prefix: schema_a)
      assert Repo.get(Entry, id_a, prefix: schema_b) == nil
      assert Repo.all(Entry, prefix: schema_b) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- prev_chain_hash linkage, including the first-entry-null case.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- chain linkage" do
    test "the first entry in a tenant's chain has a null prev_chain_hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{prev_chain_hash: nil}} =
               Audit.insert_entry(Repo, base_attrs(), schema_name)
    end

    test "each subsequent entry's prev_chain_hash equals the immediately-prior entry's chain_hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{chain_hash: hash_1, prev_chain_hash: nil}} =
               Audit.insert_entry(Repo, base_attrs(action: "definition.create"), schema_name)

      assert {:ok, %Entry{chain_hash: hash_2, prev_chain_hash: ^hash_1}} =
               Audit.insert_entry(Repo, base_attrs(action: "definition.activate"), schema_name)

      assert {:ok, %Entry{prev_chain_hash: ^hash_2}} =
               Audit.insert_entry(Repo, base_attrs(action: "definition.deprecate"), schema_name)

      assert {:ok, :valid} = Audit.verify_chain(schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- the critical fix: verify_chain/2 RECOMPUTES, it does not just check
  # linkage. This is this requirement's single most important test.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- verify_chain/2 recomputes each entry's hash, catching tampered content" do
    test "an untampered chain of several entries verifies :valid" do
      %{schema_name: schema_name} = provisioned_tenant()

      for n <- 1..4 do
        assert {:ok, _entry} =
                 Audit.insert_entry(
                   Repo,
                   base_attrs(resource_id: "res-#{n}", after_state: %{"n" => n}),
                   schema_name
                 )
      end

      assert {:ok, :valid} = Audit.verify_chain(schema_name)
    end

    test "modifying a persisted after_state directly, leaving both hash columns untouched, is caught as a hash_mismatch" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{id: id_1}} =
               Audit.insert_entry(
                 Repo,
                 base_attrs(resource_id: "res-1", after_state: %{"name" => "original"}),
                 schema_name
               )

      assert {:ok, %Entry{id: id_2}} =
               Audit.insert_entry(
                 Repo,
                 base_attrs(resource_id: "res-2", after_state: %{"name" => "second"}),
                 schema_name
               )

      # Adversarially bypass the immutability trigger (§2/AC1) the same way a
      # superuser incident-response tamper would -- disable the trigger for
      # this connection, mutate after_state directly via raw SQL, re-enable
      # it. chain_hash/prev_chain_hash are deliberately left untouched, which
      # is exactly the case R-Co's own linkage-only check cannot detect (see
      # Letflow.Audit's moduledoc).
      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries DISABLE TRIGGER ALL))

      Repo.query!(
        ~s(UPDATE "#{schema_name}".audit_entries SET after_state = $1 WHERE id = $2),
        [%{"name" => "TAMPERED"}, Ecto.UUID.dump!(id_1)]
      )

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries ENABLE TRIGGER ALL))

      # Confirm the tamper actually landed (sanity check on the test itself).
      tampered = Repo.get!(Entry, id_1, prefix: schema_name)
      assert tampered.after_state == %{"name" => "TAMPERED"}
      # chain_hash was NOT recomputed after the direct mutation -- still the
      # original digest over the original content.

      assert {:error, {:hash_mismatch, ^id_1}} = Audit.verify_chain(schema_name)

      # Confirms this is genuinely a *recompute* check and not merely
      # "any chain with 2 rows always fails": id_2 is never reached because
      # verify_chain/2 stops at the first bad entry (id_1), which is itself
      # the assertion above. A chain-linkage-only check (R-Co's own defect)
      # would instead report id_2 as :chain_broken, or nothing at all, since
      # id_1's own stored chain_hash/prev_chain_hash pair was left internally
      # self-consistent by the tamper -- only recomputing from content
      # detects it.
      refute match?({:error, {:chain_broken, ^id_2}}, Audit.verify_chain(schema_name))
    end

    test "a deleted middle entry breaks the chain linkage, reported as chain_broken (not hash_mismatch)" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Note: prev_chain_hash is itself one of the 11 hashed fields (design
      # §5.1 field 11) -- directly overwriting it on a persisted row (without
      # also recomputing that row's own chain_hash to match) is a content
      # tamper, caught as hash_mismatch, not chain_broken (see the test
      # above). A genuine chain_broken case -- linkage disrupted without any
      # single row's own stored chain_hash disagreeing with its own stored
      # content -- is a deleted-and-never-reinserted entry: id_3's own row is
      # completely untouched, but the entry its prev_chain_hash points to no
      # longer exists between id_1 and id_3.
      assert {:ok, %Entry{}} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-1"), schema_name)

      assert {:ok, %Entry{id: id_2}} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-2"), schema_name)

      assert {:ok, %Entry{id: id_3}} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-3"), schema_name)

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries DISABLE TRIGGER ALL))

      Repo.query!(~s(DELETE FROM "#{schema_name}".audit_entries WHERE id = $1), [
        Ecto.UUID.dump!(id_2)
      ])

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries ENABLE TRIGGER ALL))

      assert {:error, {:chain_broken, ^id_3}} = Audit.verify_chain(schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- resource_id's column type (design §1.2 Decision 1): a non-uuid
  # resource identifier round-trips cleanly.
  # ---------------------------------------------------------------------------------

  describe "AC9 -- resource_id accepts a non-uuid identifier" do
    test "writes and reads back an audit entry whose resource_id is not a uuid" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{resource_id: "tenant_role:approver"}} =
               Audit.insert_entry(
                 Repo,
                 base_attrs(
                   action: "tenant_role.upsert",
                   resource_type: "tenant_role",
                   resource_id: "tenant_role:approver"
                 ),
                 schema_name
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0972 -- chain_precedes?/3: a genuine, structural (not timestamp-based)
  # ordering primitive, walking `prev_chain_hash` backward from `later` looking
  # for `earlier`'s id.
  # ---------------------------------------------------------------------------------

  describe "ISS-0972 -- chain_precedes?/3" do
    test "returns {:ok, true} when earlier genuinely chain-precedes later" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{} = first} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-1"), schema_name)

      assert {:ok, %Entry{} = second} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-2"), schema_name)

      assert {:ok, true} = Audit.chain_precedes?(schema_name, first, second)
    end

    test "returns {:ok, false} when the arguments are reversed (later does not precede earlier)" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{} = first} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-1"), schema_name)

      assert {:ok, %Entry{} = second} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-2"), schema_name)

      assert {:ok, false} = Audit.chain_precedes?(schema_name, second, first)
    end

    test "returns {:ok, false} when both arguments are the same entry (not meaningfully ordered)" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{} = entry} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-1"), schema_name)

      assert {:ok, false} = Audit.chain_precedes?(schema_name, entry, entry)
    end

    test "returns {:error, {:broken_chain_link, chain_hash}} when later's prev_chain_hash points nowhere" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{} = earlier} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-1"), schema_name)

      # A hand-built `later` entry (never persisted) whose prev_chain_hash
      # points at a chain_hash that does not exist in this tenant's table --
      # exactly the corruption case the immutability triggers should make
      # impossible in practice, but chain_precedes?/3 must report rather than
      # crash on.
      missing_hash = "deadbeef" <> String.duplicate("00", 28)

      later = %Entry{
        id: Ecto.UUID.generate(),
        prev_chain_hash: missing_hash
      }

      assert {:error, {:broken_chain_link, ^missing_hash}} =
               Audit.chain_precedes?(schema_name, earlier, later)
    end

    test "returns {:error, {:max_hops_exceeded, bound}} when the chain between the two entries is deeper than the walk bound" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Build a long linked chain directly via Repo.insert_all/3 (bypassing
      # Audit.insert_entry/3's per-row transaction/hash-tail-fetch overhead,
      # and the immutability triggers only guard UPDATE/DELETE, not INSERT) --
      # chain_precedes?/3 only cares about id/chain_hash/prev_chain_hash
      # linkage, not hash-content correctness, so the chain_hash values here
      # are arbitrary unique strings, not real SHA-256 digests.
      entry_count = 30
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      naive_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      ids = for _ <- 1..entry_count, do: Ecto.UUID.generate()
      hashes = for n <- 1..entry_count, do: "synthetic-chain-hash-#{n}"

      rows =
        Enum.zip([ids, hashes, 0..(entry_count - 1)])
        |> Enum.map(fn {id, hash, index} ->
          prev_hash = if index == 0, do: nil, else: Enum.at(hashes, index - 1)

          %{
            id: id,
            tenant_id: Ecto.UUID.generate(),
            actor_id: nil,
            action: "definition.create",
            resource_type: "definition",
            resource_id: "res-#{index}",
            timestamp: now,
            before_state: nil,
            after_state: nil,
            trace_id: nil,
            chain_hash: hash,
            prev_chain_hash: prev_hash,
            inserted_at: naive_now
          }
        end)

      # Chunked: Postgres caps a single statement at 65535 bound parameters,
      # and this schema's row shape (11 fields) times entry_count exceeds
      # that in one insert_all/3 call.
      rows
      |> Enum.chunk_every(1_000)
      |> Enum.each(fn chunk -> Repo.insert_all(Entry, chunk, prefix: schema_name) end)

      earlier = %Entry{id: Enum.at(ids, 0), prev_chain_hash: nil}

      later = %Entry{
        id: Enum.at(ids, entry_count - 1),
        prev_chain_hash: Enum.at(hashes, entry_count - 2)
      }

      # A small :max_hops keeps the walk bounded work (GH #2525: 10_000 DB
      # round trips timed out at 60 s under CI load). Same code path as the
      # default bound; the chain is deeper than the bound.
      assert {:error, {:max_hops_exceeded, 5}} =
               Audit.chain_precedes?(schema_name, earlier, later, max_hops: 5)

      # Within the bound the same chain resolves.
      assert {:ok, true} =
               Audit.chain_precedes?(schema_name, earlier, later, max_hops: 100)
    end
  end
end
