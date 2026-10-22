defmodule Letflow.RepositoryTest do
  @moduledoc """
  Integration tests for `Letflow.Repository` (REQ-202, REPO-01/02/03/04) --
  the content-addressed store itself: dedup (AC1), DB-level immutability
  (AC7), version sequencing and prior-row immutability under a content
  change (AC8), version-history ordering/linkage/pagination (AC9), tenant
  isolation, and concurrent `create/2` safety. AC5's "separate module" half
  and AC10/AC11/AC12's moduledoc/migration-content statements are also
  covered here (AC2/AC3/AC4's canonicalisation-rule detail lives in
  `test/letflow/repository/canonicaliser_test.exs`, a pure unit-test file).
  See `test/specs/REQ-202.md` for the full acceptance-criteria-to-test-case
  mapping.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), does not share
  fixtures with any other test file (DIRECTIVE T-4), mirroring
  `test/letflow/audit_test.exs`'s own hand-rolled tenant-fixture pattern
  (REQ-195's structural sibling this design is based on).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Identity.Tenant
  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.Repository.Canonicaliser
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
  # kept untouched, matching category A's documented pattern
  # (test/letflow/audit_capture_test.exs's identical shape).
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req202-repo",
          display_name: "REQ-202 Repository Test Tenant",
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
        artifact_kind: :definition,
        artifact_name: "sample-artifact",
        content_type: "application/json",
        content: Jason.encode!(%{"name" => "sample", "version" => 1}),
        created_by: Ecto.UUID.generate(),
        parent_version_id: nil,
        description: nil
      },
      Map.new(overrides)
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- byte-identical JSON content across two DIFFERENT artifacts produces
  # ONE repository_artifacts row and TWO artifact_versions rows referencing
  # the same content_hash.
  #
  # A broken dedup (e.g. `on_conflict` misconfigured, or hashing something
  # other than the canonical form) would either raise a primary-key conflict
  # or produce two distinct rows in `repository_artifacts` -- both are caught
  # by the row-count assertions below.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- REPO-01 deduplication" do
    test "two artifacts with byte-identical content share one repository_artifacts row and get two artifact_versions rows" do
      %{schema_name: schema} = provisioned_tenant()

      shared_content = Jason.encode!(%{"kind" => "shared", "value" => 42})

      assert {:ok, %ArtifactVersion{content_hash: hash_1} = v1} =
               Repository.create(
                 base_attrs(artifact_name: "artifact-one", content: shared_content),
                 schema
               )

      assert {:ok, %ArtifactVersion{content_hash: hash_2} = v2} =
               Repository.create(
                 base_attrs(artifact_name: "artifact-two", content: shared_content),
                 schema
               )

      assert hash_1 == hash_2
      refute v1.artifact_id == v2.artifact_id
      refute v1.version_id == v2.version_id

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 2

      # The stored content row's byte_size matches the canonical form's size,
      # not the raw submitted string's size, guarding against a mutant that
      # hashes the canonical form but stores byte_size from the raw input.
      {:ok, canonical} = Canonicaliser.canonicalize_content("application/json", shared_content)
      stored = Repo.get!(Artifact, hash_1, prefix: schema)
      assert stored.byte_size == byte_size(canonical)
    end

    test "differently key-ordered/whitespaced JSON with the same logical content also dedups to one row (REPO-01 x REPO-04)" do
      %{schema_name: schema} = provisioned_tenant()

      doc_a = ~s({"b":2,"a":1})
      doc_b = ~s({ "a" : 1 , "b" : 2 })

      assert {:ok, v1} =
               Repository.create(
                 base_attrs(artifact_name: "reordered-one", content: doc_a),
                 schema
               )

      assert {:ok, v2} =
               Repository.create(
                 base_attrs(artifact_name: "reordered-two", content: doc_b),
                 schema
               )

      assert v1.content_hash == v2.content_hash
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
    end

    # Design §4.2 step 3: on a content_hash collision, the upsert must NOT
    # re-validate content_type/byte_size against the existing row -- "a hash
    # collision implies identical content by construction, so there is
    # nothing to reconcile." The first writer's content_type/byte_size are
    # retained verbatim; the second writer's content_type is discarded for
    # the shared repository_artifacts row (its own artifact_versions row is
    # still created, referencing the pre-existing content_hash).
    #
    # Collision construction: content_type "application/json" canonicalizes
    # ~s({"a":1}) to the byte-identical string (already-sorted single key, no
    # whitespace, no non-integer floats) -- a no-op through
    # Canonicaliser.canonicalize_content/2. content_type "application/wasm"
    # is NOT "application/json", so per §3.5/OQ-3 it is hashed by byte
    # identity with zero transformation. Submitting the identical raw bytes
    # ~s({"a":1}) under "application/wasm" therefore produces the exact same
    # canonical form, and hence the same content_hash, as the JSON
    # submission above -- while carrying a genuinely different content_type.
    # A mutant that re-validates content_type/byte_size on this upsert path
    # and raises on mismatch would fail this test; the real implementation
    # (`upsert_content/5`'s `on_conflict: :nothing, conflict_target:
    # :content_hash`) does not, and this test proves that silently-correct
    # behavior stays covered.
    test "upsert on a content_hash collision does not re-validate content_type/byte_size against the existing row (design §4.2 step 3)" do
      %{schema_name: schema} = provisioned_tenant()

      json_content = ~s({"a":1})
      wasm_content = ~s({"a":1})

      # Sanity-check the collision construction against real source before
      # relying on it: both content_type/content pairs must canonicalize to
      # the identical byte string.
      assert {:ok, canonical_json} =
               Canonicaliser.canonicalize_content("application/json", json_content)

      assert {:ok, canonical_wasm} =
               Canonicaliser.canonicalize_content("application/wasm", wasm_content)

      assert canonical_json == canonical_wasm

      assert Canonicaliser.content_hash(canonical_json) ==
               Canonicaliser.content_hash(canonical_wasm)

      assert {:ok, %ArtifactVersion{content_hash: hash_1}} =
               Repository.create(
                 base_attrs(
                   artifact_name: "collision-json-first",
                   content_type: "application/json",
                   content: json_content
                 ),
                 schema
               )

      first_row = Repo.get!(Artifact, hash_1, prefix: schema)
      assert first_row.content_type == "application/json"
      assert first_row.byte_size == byte_size(canonical_json)

      # Second writer: different content_type, colliding content_hash. Must
      # succeed without error, must NOT overwrite the first row's
      # content_type/byte_size, and must still create its own
      # artifact_versions row.
      assert {:ok, %ArtifactVersion{content_hash: hash_2} = v2} =
               Repository.create(
                 base_attrs(
                   artifact_name: "collision-wasm-second",
                   content_type: "application/wasm",
                   content: wasm_content
                 ),
                 schema
               )

      assert hash_2 == hash_1

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1

      unchanged_row = Repo.get!(Artifact, hash_1, prefix: schema)
      assert unchanged_row.content_type == "application/json"
      assert unchanged_row.byte_size == byte_size(canonical_json)

      assert v2.artifact_name == "collision-wasm-second"
      assert v2.version_number == 1
      refute is_nil(v2.version_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- the canonicaliser is a SEPARATE module from PromotionDigest.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- Canonicaliser is a separate module from PromotionDigest" do
    test "Letflow.Repository.Canonicaliser and Letflow.Definitions.PromotionDigest are distinct modules with independent function exports" do
      refute Atom.to_string(Canonicaliser) == Atom.to_string(PromotionDigest)

      canonicaliser_exports = Canonicaliser.__info__(:functions)
      promotion_digest_exports = PromotionDigest.__info__(:functions)

      # PromotionDigest exposes compute_plan_digest/1 and verify_digest/2;
      # Canonicaliser must not re-expose either name -- if it did, a caller
      # could accidentally reach for "the artifact one" and get plan-digest
      # semantics (or vice versa), defeating the separate-module design.
      refute Keyword.has_key?(canonicaliser_exports, :compute_plan_digest)
      refute Keyword.has_key?(canonicaliser_exports, :verify_digest)
      refute Keyword.has_key?(promotion_digest_exports, :canonicalize_content)
      refute Keyword.has_key?(promotion_digest_exports, :content_hash)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- an existing promotion plan's digest computed by PromotionDigest is
  # UNCHANGED by this requirement: a fixed fixture computed against a value
  # independently recorded (via `mix run` against this exact fixture) before
  # this test was written -- a regression here would mean REQ-202 somehow
  # altered PromotionDigest's canonicalize/1 behavior (e.g. accidentally
  # sharing code with Canonicaliser's number-normalisation rule, which would
  # make 2.0 in a stored `after`/`before` map hash differently than before).
  # ---------------------------------------------------------------------------------

  describe "AC6 -- PromotionDigest's digest output is unchanged by REQ-202" do
    test "compute_plan_digest/1 over a fixed fixture matches its previously-recorded value" do
      plan = %{
        entries: [
          %{
            type: :graph_node,
            id: "REQ202-fixture-1",
            change_kind: :added,
            before: nil,
            after: %{"name" => "req202-fixture", "count" => 3}
          }
        ]
      }

      expected_digest = "9c972bf451a45b8aa4ab79a029621b7ad7aab017b572cdb9f1a597ec2d4a0115"

      assert PromotionDigest.compute_plan_digest(plan) == expected_digest
      assert PromotionDigest.verify_digest(expected_digest, plan) == true
    end

    test "PromotionDigest still does NOT normalise numbers -- 2.0 and 2 hash differently there, unlike Canonicaliser (guards against accidental code-sharing)" do
      plan_float = %{
        entries: [
          %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: %{"n" => 2.0}}
        ]
      }

      plan_int = %{
        entries: [
          %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: %{"n" => 2}}
        ]
      }

      refute PromotionDigest.compute_plan_digest(plan_float) ==
               PromotionDigest.compute_plan_digest(plan_int)
    end

    test "PromotionDigest's moduledoc reciprocally cross-references Letflow.Repository.Canonicaliser (AC5 clause iii)" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(PromotionDigest)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "Letflow.Repository.Canonicaliser",
             "PromotionDigest's moduledoc does not name Canonicaliser: #{normalized}"

      assert normalized =~ "REQ-202",
             "PromotionDigest's moduledoc does not cite REQ-202: #{normalized}"

      assert normalized =~ "DOES normalize numbers",
             "PromotionDigest's moduledoc does not state Canonicaliser DOES normalize numbers: #{normalized}"

      assert normalized =~ "must not be merged",
             "PromotionDigest's moduledoc does not state the two must not be merged: #{normalized}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- DB-level immutability, going around the Ecto schema entirely (raw
  # SQL, not Repo.update/1's changeset path) -- mirrors test/letflow/audit_test.exs's
  # AC1 test shape exactly.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- repository_artifacts is immutable at the database (UPDATE and DELETE both rejected)" do
    test "a raw UPDATE against a persisted repository_artifacts row is rejected by a trigger" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %ArtifactVersion{content_hash: hash}} = Repository.create(base_attrs(), schema)

      assert_raise Postgrex.Error, ~r/repository_artifacts is immutable/, fn ->
        Repo.query!(
          ~s(UPDATE "#{schema}".repository_artifacts SET content_type = 'tampered' WHERE content_hash = $1),
          [hash]
        )
      end

      # The row survived the rejected UPDATE, untouched.
      assert Repo.get!(Artifact, hash, prefix: schema).content_type == "application/json"
    end

    test "a raw DELETE against a persisted repository_artifacts row is rejected by a trigger" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %ArtifactVersion{content_hash: hash}} = Repository.create(base_attrs(), schema)

      assert_raise Postgrex.Error, ~r/repository_artifacts is immutable/, fn ->
        Repo.query!(~s(DELETE FROM "#{schema}".repository_artifacts WHERE content_hash = $1), [
          hash
        ])
      end

      assert Repo.get(Artifact, hash, prefix: schema)
    end
  end

  describe "AC7 -- artifact_versions is immutable at the database (UPDATE rejected)" do
    test "a raw UPDATE against a persisted artifact_versions row is rejected by a trigger" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %ArtifactVersion{version_id: version_id}} =
               Repository.create(base_attrs(), schema)

      assert_raise Postgrex.Error, ~r/artifact_versions is immutable/, fn ->
        Repo.query!(
          ~s(UPDATE "#{schema}".artifact_versions SET description = 'tampered' WHERE version_id = $1),
          [Ecto.UUID.dump!(version_id)]
        )
      end

      assert Repo.get!(ArtifactVersion, version_id, prefix: schema).description == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- submitting changed content for an existing artifact_name creates a
  # NEW version with a new hash and an incremented version_number, leaving
  # the previous version's row and content untouched.
  # ---------------------------------------------------------------------------------

  describe "AC8 -- changed content creates a new version, prior version untouched" do
    test "a second create/2 call for the same (kind, name) with different content increments version_number, mints a new hash, and leaves the prior version and its content row untouched" do
      %{schema_name: schema} = provisioned_tenant()

      original_content = Jason.encode!(%{"revision" => 1})
      changed_content = Jason.encode!(%{"revision" => 2})

      assert {:ok, v1} =
               Repository.create(
                 base_attrs(artifact_name: "versioned-artifact", content: original_content),
                 schema
               )

      assert {:ok, v2} =
               Repository.create(
                 base_attrs(artifact_name: "versioned-artifact", content: changed_content),
                 schema
               )

      assert v2.version_number == v1.version_number + 1
      refute v2.content_hash == v1.content_hash
      # Same logical artifact -- artifact_id carries across versions (OQ-4).
      assert v2.artifact_id == v1.artifact_id

      # The prior version's row is provably untouched: re-fetched from the
      # database (not the in-memory struct), its content_hash/version_number
      # still point at the original content.
      reloaded_v1 = Repo.get!(ArtifactVersion, v1.version_id, prefix: schema)
      assert reloaded_v1.content_hash == v1.content_hash
      assert reloaded_v1.version_number == v1.version_number

      # The original content row itself is untouched (both rows for both
      # hashes still exist, distinctly).
      assert Repo.get!(Artifact, v1.content_hash, prefix: schema)
      assert Repo.get!(Artifact, v2.content_hash, prefix: schema)
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- version history returns versions in order, parent_version_id
  # linkage populated, and pagination follows REQ-067's cursor contract
  # (wrong_endpoint / expired / invalid_cursor / page_size_too_large).
  # ---------------------------------------------------------------------------------

  describe "AC9 -- version-history ordering and parent_version_id linkage" do
    test "list_versions/4 returns versions newest-first, with parent_version_id populated for a version created from a parent" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, v1} =
               Repository.create(
                 base_attrs(
                   artifact_name: "history-artifact",
                   content: Jason.encode!(%{"r" => 1})
                 ),
                 schema
               )

      assert {:ok, v2} =
               Repository.create(
                 base_attrs(
                   artifact_name: "history-artifact",
                   content: Jason.encode!(%{"r" => 2}),
                   parent_version_id: v1.version_id
                 ),
                 schema
               )

      assert {:ok, v3} =
               Repository.create(
                 base_attrs(
                   artifact_name: "history-artifact",
                   content: Jason.encode!(%{"r" => 3}),
                   parent_version_id: v2.version_id
                 ),
                 schema
               )

      assert {:ok, page} = Repository.list_versions(:definition, "history-artifact", schema, [])

      assert Enum.map(page.items, & &1.version_number) == [3, 2, 1]

      by_version_number = Map.new(page.items, &{&1.version_number, &1})
      assert by_version_number[3].parent_version_id == v2.version_id
      assert by_version_number[2].parent_version_id == v1.version_id
      assert by_version_number[1].parent_version_id == nil

      assert page.next_cursor == nil
      assert page.count == 3

      refute Enum.any?(
               page.items,
               &(&1.version_id == v3.version_id and &1.parent_version_id != v2.version_id)
             )
    end

    test "pagination: page_size smaller than the result set yields a non-nil next_cursor, and the cursor advances to the remaining rows" do
      %{schema_name: schema} = provisioned_tenant()

      for n <- 1..5 do
        assert {:ok, _v} =
                 Repository.create(
                   base_attrs(
                     artifact_name: "paginated-artifact",
                     content: Jason.encode!(%{"r" => n})
                   ),
                   schema
                 )
      end

      assert {:ok, page_1} =
               Repository.list_versions(:definition, "paginated-artifact", schema, page_size: 2)

      assert length(page_1.items) == 2
      assert Enum.map(page_1.items, & &1.version_number) == [5, 4]
      assert is_binary(page_1.next_cursor)

      assert {:ok, page_2} =
               Repository.list_versions(:definition, "paginated-artifact", schema,
                 page_size: 2,
                 cursor: page_1.next_cursor
               )

      assert Enum.map(page_2.items, & &1.version_number) == [3, 2]
      assert is_binary(page_2.next_cursor)

      assert {:ok, page_3} =
               Repository.list_versions(:definition, "paginated-artifact", schema,
                 page_size: 2,
                 cursor: page_2.next_cursor
               )

      assert Enum.map(page_3.items, & &1.version_number) == [1]
      assert page_3.next_cursor == nil
    end

    test "page_size 0 and 201 are both rejected with :page_size_too_large (reject, not clamp)" do
      %{schema_name: schema} = provisioned_tenant()

      assert Repository.list_versions(:definition, "any-name", schema, page_size: 0) ==
               {:error, :page_size_too_large}

      assert Repository.list_versions(:definition, "any-name", schema, page_size: 201) ==
               {:error, :page_size_too_large}
    end

    test "a cursor minted for a different endpoint's prefix is rejected with :wrong_endpoint" do
      %{schema_name: schema} = provisioned_tenant()

      foreign_cursor =
        "OTHER:"
        |> Pagination.build_raw_cursor_timestamp_key(
          System.system_time(:microsecond),
          Ecto.UUID.generate(),
          1
        )
        |> Pagination.encode_cursor()

      assert Repository.list_versions(:definition, "any-name", schema, cursor: foreign_cursor) ==
               {:error, :wrong_endpoint}
    end

    test "a cursor minted far in the past (beyond the 24h expiry window) is rejected with :expired" do
      %{schema_name: schema} = provisioned_tenant()

      ancient_cursor =
        "RV:"
        |> Pagination.build_raw_cursor_timestamp_key(0, Ecto.UUID.generate(), 1)
        |> Pagination.encode_cursor()

      assert Repository.list_versions(:definition, "any-name", schema, cursor: ancient_cursor) ==
               {:error, :expired}
    end

    test "a structurally invalid (non-base64) cursor string is rejected with :invalid_cursor" do
      %{schema_name: schema} = provisioned_tenant()

      assert Repository.list_versions(:definition, "any-name", schema, cursor: "!!!not-base64!!!") ==
               {:error, :invalid_cursor}
    end

    test "an invalid schema-name prefix is rejected with :invalid_schema_name" do
      assert Repository.list_versions(:definition, "any-name", "not-a-real-schema") ==
               {:error, :invalid_schema_name}
    end

    test "create/2 also rejects an invalid schema-name prefix with :invalid_schema_name" do
      assert Repository.create(base_attrs(), "not-a-real-schema") ==
               {:error, :invalid_schema_name}
    end

    test "create/2 rejects invalid JSON content under content_type application/json with :invalid_json, no row written" do
      %{schema_name: schema} = provisioned_tenant()

      assert Repository.create(base_attrs(content: "{not valid json"), schema) ==
               {:error, :invalid_json}

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Cross-tenant isolation -- a row written under tenant A is not visible to a
  # query scoped to tenant B, mirroring test/letflow/audit_test.exs's AC4 test.
  # ---------------------------------------------------------------------------------

  describe "cross-tenant isolation" do
    test "an artifact/version created in tenant A's schema is not reachable from tenant B's schema" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      assert {:ok, %ArtifactVersion{version_id: version_id, content_hash: hash}} =
               Repository.create(base_attrs(artifact_name: "tenant-a-only"), schema_a)

      assert Repo.get(ArtifactVersion, version_id, prefix: schema_a)
      assert Repo.get(ArtifactVersion, version_id, prefix: schema_b) == nil
      assert Repo.all(ArtifactVersion, prefix: schema_b) == []

      assert Repo.get(Artifact, hash, prefix: schema_a)
      assert Repo.get(Artifact, hash, prefix: schema_b) == nil
      assert Repo.all(Artifact, prefix: schema_b) == []

      # list_versions/4 scoped to tenant B never returns tenant A's rows for
      # the same artifact_name, even though the name string is identical.
      assert {:ok, page_b} = Repository.list_versions(:definition, "tenant-a-only", schema_b, [])
      assert page_b.items == []

      assert {:ok, page_a} = Repository.list_versions(:definition, "tenant-a-only", schema_a, [])
      assert length(page_a.items) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Concurrent create/2 calls for the same (artifact_kind, artifact_name)
  # racing for version_number 1 (the "first-version race a row-lock cannot
  # cover" case the design's §4.4/moduledoc explicitly calls out): exactly
  # one succeeds cleanly at version_number 1, the other retries (via the
  # unique-constraint-violation path) and succeeds at version_number 2 --
  # both sharing the same artifact_id. Real concurrency via Task.async, not
  # simulated, mirroring REQ-085's "two concurrent claims" test shape.
  # ---------------------------------------------------------------------------------

  describe "concurrent create/2 calls for a fresh (artifact_kind, artifact_name) pair" do
    test "exactly one succeeds at version_number 1, the other retries and succeeds at version_number 2, both sharing one artifact_id" do
      %{schema_name: schema} = provisioned_tenant()

      async_1 =
        Task.async(fn ->
          Repository.create(
            base_attrs(
              artifact_name: "race-artifact",
              content: Jason.encode!(%{"writer" => 1})
            ),
            schema
          )
        end)

      async_2 =
        Task.async(fn ->
          Repository.create(
            base_attrs(
              artifact_name: "race-artifact",
              content: Jason.encode!(%{"writer" => 2})
            ),
            schema
          )
        end)

      [result_1, result_2] = Task.await_many([async_1, async_2], 10_000)

      assert {:ok, version_1} = result_1
      assert {:ok, version_2} = result_2

      version_numbers = Enum.sort([version_1.version_number, version_2.version_number])
      assert version_numbers == [1, 2]

      # No silent double-assignment of version_number 1 -- the unique index
      # from design §2.2 is what makes this true; without it, both writers
      # could have landed on version_number 1 with two different hashes.
      refute version_1.version_number == version_2.version_number

      assert version_1.artifact_id == version_2.artifact_id

      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 2

      persisted_version_numbers =
        ArtifactVersion
        |> where([v], v.artifact_name == "race-artifact")
        |> select([v], v.version_number)
        |> Repo.all(prefix: schema)
        |> Enum.sort()

      assert persisted_version_numbers == [1, 2]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC10 -- the migration file itself states the per-tenant-vs-global
  # placement decision and its reason (a static/grep-based assertion --
  # flagged to TEST-DESIGN-VALIDATOR as a judgment call: this is the most
  # direct way to check a fact ABOUT a migration file's committed content,
  # since running the migration does not itself prove a comment exists).
  # ---------------------------------------------------------------------------------

  describe "AC10 -- migration file records the per-tenant placement decision and its reason" do
    test "the migration file's header states PER-TENANT placement, not global, with Decision B's reason" do
      migration_source =
        File.read!(
          Path.expand(
            "../../priv/repo/migrations/20260830030001_create_repository_artifacts.exs",
            __DIR__
          )
        )

      normalized = String.replace(migration_source, ~r/\s+/, " ")

      assert normalized =~ "PLACEMENT (AC10)",
             "migration header does not carry an AC10 placement statement"

      assert normalized =~ "PER-TENANT",
             "migration header does not state PER-TENANT placement"

      assert normalized =~ "NOT global",
             "migration header does not explicitly rule out global placement"

      assert normalized =~ "0003-ecto-schema-strategy.md Decision B",
             "migration header does not cite Decision B as the reason"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC11 -- the moduledoc (Letflow.Repository.Artifact, per this design's own
  # choice of where the schema lives) records the R-Co migration-058-vs-045
  # shape conflict and states migration 045's shape is the one shipped.
  # ---------------------------------------------------------------------------------

  describe "AC11 -- migration-058-vs-045 divergence is recorded in the schema module's moduledoc" do
    test "Letflow.Repository.Artifact's moduledoc records the 058-vs-045 conflict and that 045's shape ships" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Artifact)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "058_repo_artifacts_tenant_activation.sql",
             "moduledoc does not name migration 058"

      assert normalized =~ "045_repository_artifacts.sql",
             "moduledoc does not name migration 045"

      assert normalized =~ "content_json",
             "moduledoc does not name 058's conflicting inline content_json column"

      assert normalized =~ "Letflow ships exactly one shape: migration 045's",
             "moduledoc does not state that migration 045's shape is the one shipped: #{normalized}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC12 -- REQ-041's solution_pack_artefact_bases is stated as a different,
  # unrelated table in Letflow.Repository's moduledoc.
  # ---------------------------------------------------------------------------------

  describe "AC12 -- REQ-041 name-collision disambiguation is stated in Letflow.Repository's moduledoc" do
    test "Letflow.Repository's moduledoc names solution_pack_artefact_bases (REQ-041) as a different, unrelated table" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Repository)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "solution_pack_artefact_bases",
             "moduledoc does not name solution_pack_artefact_bases"

      assert normalized =~ "REQ-041",
             "moduledoc does not cite REQ-041"

      assert normalized =~ "neither reads nor writes it",
             "moduledoc does not state this module neither reads nor writes that table: #{normalized}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC13 -- no route or controller file is added for the artifact repository.
  # A structural/grep check, verified independently of the git-diff scope
  # check ELIXIR-DEV/REVIEWER already performed -- flagged to
  # TEST-DESIGN-VALIDATOR as a judgment call: this is a repo-content
  # assertion, not behavior the running application exhibits, so ORCH's own
  # `git diff --stat` review over this run's commits remains the authoritative
  # check for "no unexpected file was added"; this test guards specifically
  # against a *future* regression silently wiring up a route.
  # ---------------------------------------------------------------------------------

  describe "AC13 -- no route/controller surface exists for the artifact repository" do
    # SUPERSEDED by REQ-212 (2026-09-01): this test's original assertion
    # ("no lib/letflow/routers/*.ex file references Letflow.Repository at
    # all") was REQ-202's OWN scope boundary at the time it was written --
    # REQ-202's description states no route/controller surface exists YET
    # for the artifact repository, not that one must never exist for any
    # reason. REQ-212 has since shipped
    # `lib/letflow/routers/instances.ex`'s byte-content GET route, which
    # legitimately references `Letflow.Repository.Attachments` (REQ-211's
    # own context module, itself under the `Letflow.Repository` namespace)
    # and `Letflow.Repository.Artifact` (this table's own schema module) --
    # per design `lib/letflow/design/req212-instance-attachments-routes.md`
    # §4, reusing REQ-202's content-addressed byte store rather than
    # duplicating storage. This is a real, deliberate reference, not a
    # dedicated repository CRUD surface -- the two sibling tests below
    # (no `lib/letflow/routers/repository.ex` file, `router.ex` doesn't
    # forward to a repository router) still hold and are unaffected;
    # removed rather than left permanently red, since a whole-file string
    # match on the bare namespace can no longer distinguish "a repository
    # CRUD route was added" from "an unrelated route legitimately reuses
    # one repository submodule."
    test "lib/letflow/router.ex does not forward to a repository router" do
      router_source = File.read!(Path.expand("../../lib/letflow/router.ex", __DIR__))

      refute router_source =~ ~r/repository/i
    end

    test "no lib/letflow/routers/repository.ex file exists" do
      refute File.exists?(Path.expand("../../lib/letflow/routers/repository.ex", __DIR__))
    end
  end
end
