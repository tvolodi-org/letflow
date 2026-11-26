defmodule Letflow.Repository.AttachmentsTest do
  @moduledoc """
  Basic sanity tests for REQ-211's `Letflow.Repository.Attachments` context
  module, written by ELIXIR-DEV at Step 2a to exercise the implementation
  against a real Postgres tenant schema. Not full 11-AC coverage --
  TEST-DESIGNER writes that later in this pipeline (WF-02 Step 2d+). See
  `lib/letflow/design/req211-instance-attachments-core.md` for the design
  these tests spot-check.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Instances
  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.Attachment
  alias Letflow.Repository.Attachments

  defp set_storage_allowance!(tenant_id, allowance) do
    Repo.update_all(
      from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id),
      set: [storage_allowance_bytes: allowance]
    )
  end

  defp provisioned_tenant(slug_prefix \\ "req211-attach") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-211 Attachments Test Tenant"
    )
  end

  # REQ-391 §2.3: EventStore.append/2's M1 active_instance_guard requires a
  # real, ACTIVE instance_projections row to exist for the given instance_id
  # -- upload/2's own primary write has no such requirement (attachments can
  # be added to instances this module never checks the state of), so the
  # post-commit history-event append is a silent, logged no-op against a
  # synthetic instance_id with no backing projection row. Tests that assert
  # the history entry itself (as opposed to upload/2's own unaffected return
  # value) need a real projection row -- seeded directly, matching
  # test/letflow/event_store_test.exs's own `seed_projection!/4` idiom (that
  # file's moduledoc: "a direct Repo.insert against instance_projections,
  # NEVER via append/2 itself").
  defp seed_active_instance_projection!(schema_name, instance_id) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      last_event_seq: 0,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp upload_attrs(overrides \\ []) do
    Map.merge(
      %{
        instance_id: Ecto.UUID.generate(),
        raw_bytes: "hello attachment bytes",
        file_name: "note.txt",
        content_type: "text/plain",
        uploaded_by: Ecto.UUID.generate(),
        description: nil
      },
      Map.new(overrides)
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- instance_attachments lives inside the tenant's own Postgres schema,
  # with tenant_id retained and instance_id required (not nullable) -- matching
  # decision 0003 Decision B's pattern (dlq_test.exs's AC1 test is the idiom
  # copied here). ELIXIR-DEV's own 15 sanity tests exercised upload/2 (which
  # always supplies instance_id) but never demonstrated the column-level
  # NOT NULL constraint itself, nor that the table is absent from `public` --
  # gap closed here.
  # ---------------------------------------------------------------------------------

  describe "AC1: instance_attachments migration -- schema-per-tenant, tenant_id retained, instance_id required" do
    test "the table exists in the tenant's own schema, carries tenant_id/instance_id columns (both NOT NULL), and is absent from public" do
      %{schema_name: schema_name} = provisioned_tenant("req211-ac1")

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name, is_nullable FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'instance_attachments'",
          [schema_name]
        )

      columns = Map.new(tenant_columns, fn [name, nullable] -> {name, nullable} end)

      assert columns["tenant_id"] == "NO"
      assert columns["instance_id"] == "NO"
      assert columns["content_hash"] == "NO"
      assert columns["id"] == "NO"

      # The isolation boundary is the Postgres schema itself (design §1.1) --
      # confirmed by there being no instance_attachments table in `public` at
      # all, matching Letflow.Dlq's own AC1 test idiom.
      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'instance_attachments'"
        )

      assert public_rows == []
    end

    test "attempting to insert a row with instance_id = NULL is rejected at the database level" do
      %{schema_name: schema} = provisioned_tenant("req211-ac1-null")

      assert {:ok, %Attachment{}} = Attachments.upload(upload_attrs(), prefix: schema)

      # Bypass the context module's own changeset validation (which also
      # requires instance_id) to prove the NOT NULL constraint is real at the
      # DB layer, not merely application-level -- a raw insert with
      # instance_id omitted must be rejected by Postgres itself.
      hash_hex = Base.encode16(:crypto.hash(:sha256, "no-instance-id"))

      sql = """
      INSERT INTO "#{schema}".instance_attachments
        (id, tenant_id, content_hash, file_name, content_type, byte_size, uploaded_by, created_at)
      VALUES (gen_random_uuid(), gen_random_uuid(),
              decode('#{hash_hex}', 'hex'),
              'x.txt', 'text/plain', 1, gen_random_uuid(), now())
      """

      assert_raise Postgrex.Error, ~r/null value in column "instance_id"/, fn ->
        Repo.query!(sql, [])
      end
    end
  end

  describe "upload/2" do
    test "hashes bytes independently, upserts repository_artifacts (with real content), and creates one instance_attachments row" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %Attachment{} = attachment} =
               Attachments.upload(upload_attrs(), prefix: schema)

      assert attachment.file_name == "note.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.byte_size == byte_size("hello attachment bytes")

      expected_hash = :crypto.hash(:sha256, "hello attachment bytes")
      assert attachment.content_hash == expected_hash

      stored_artifact = Repo.get!(Artifact, expected_hash, prefix: schema)
      assert stored_artifact.content == "hello attachment bytes"
      assert stored_artifact.content_type == "text/plain"
    end

    test "byte-identical content under two different instance_id values reuses one repository_artifacts row but creates two instance_attachments rows (AC2)" do
      %{schema_name: schema} = provisioned_tenant()

      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()
      shared_bytes = "shared delivery note content"

      assert {:ok, attachment_a} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_a, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert {:ok, attachment_b} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_b, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert attachment_a.content_hash == attachment_b.content_hash
      refute attachment_a.id == attachment_b.id

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 2
    end

    test "byte_size is independently measured from the actual bytes, not any caller-supplied field (AC3 -- upload_attrs has no such field)" do
      %{schema_name: schema} = provisioned_tenant()

      raw_bytes = :binary.copy("x", 777)

      assert {:ok, attachment} =
               Attachments.upload(upload_attrs(raw_bytes: raw_bytes), prefix: schema)

      assert attachment.byte_size == 777
    end

    test "a caller-supplied byte_size-shaped value that mismatches the real byte count is ignored -- stored byte_size always reflects the actual bytes (AC3, gap-closing mutation test)" do
      %{schema_name: schema} = provisioned_tenant()

      raw_bytes = :binary.copy("y", 42)

      # upload_attrs() intentionally has no :byte_size key in its @type
      # (design §4.0 item 4 -- "there is structurally nothing to ignore").
      # This test proves that guarantee holds even when a caller smuggles a
      # mismatched byte_size-shaped value into the attrs map -- upload/2 must
      # not accidentally read it via Map.get/2 with a fallback, or any other
      # path that would let a caller-declared size win. A mutation that
      # introduces exactly that (e.g. `Map.get(attrs, :byte_size,
      # byte_size(raw_bytes))`) is caught here even though it survives the
      # other upload/2 tests, none of which ever pass a :byte_size key.
      attrs = Map.put(upload_attrs(raw_bytes: raw_bytes), :byte_size, 999_999)

      assert {:ok, attachment} = Attachments.upload(attrs, prefix: schema)

      assert attachment.byte_size == 42
      refute attachment.byte_size == 999_999

      stored_artifact = Repo.get!(Artifact, attachment.content_hash, prefix: schema)
      assert stored_artifact.byte_size == 42
    end

    test "an upload exceeding the 25 MiB ceiling is rejected before any persistence, with neither row created (AC4)" do
      %{schema_name: schema} = provisioned_tenant()

      oversized = :binary.copy("a", 26_214_401)

      assert Attachments.upload(upload_attrs(raw_bytes: oversized), prefix: schema) ==
               {:error, :file_too_large}

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
    end

    test "does not canonicalise attachment bytes even when content_type is application/json" do
      %{schema_name: schema} = provisioned_tenant()

      # Not canonical JSON (unsorted keys, extra whitespace) -- if this module
      # ran it through Canonicaliser, the hash would differ from a plain
      # byte-identity hash of these exact bytes.
      raw_bytes = ~s({ "b": 2, "a": 1 })

      assert {:ok, attachment} =
               Attachments.upload(
                 upload_attrs(raw_bytes: raw_bytes, content_type: "application/json"),
                 prefix: schema
               )

      assert attachment.content_hash == :crypto.hash(:sha256, raw_bytes)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0399 -- content-scanning pipeline (lib/letflow/design/iss0399-attachment-
  # content-scanning.md). Four traps this fix exists to close, each with its own
  # test: (1) infected content must not be persisted; (2) a scanner exception must
  # not become a false-clean; (3) a pre-existing/pending row must not be servable;
  # (4) an infected-upload attempt must be audit-logged without leaking raw bytes.
  # ---------------------------------------------------------------------------------

  describe "ISS-0399: clean upload is scanned, marked :clean, and servable" do
    test "a non-EICAR upload gets scan_status: :clean and its content is fetchable via get_content/3" do
      %{schema_name: schema} = provisioned_tenant("iss0399-clean")

      assert {:ok, attachment} = Attachments.upload(upload_attrs(), prefix: schema)
      assert attachment.scan_status == :clean

      assert {:ok, ^attachment, artifact} =
               Attachments.get_content(attachment.id, attachment.instance_id, prefix: schema)

      assert artifact.content == "hello attachment bytes"
    end
  end

  describe "ISS-0399: EICAR-signature upload is rejected and nothing is persisted" do
    test "upload/2 returns {:error, :infected, verdict} and creates neither an instance_attachments nor a repository_artifacts row" do
      %{schema_name: schema} = provisioned_tenant("iss0399-eicar")

      eicar =
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

      assert {:error, :infected, verdict} =
               Attachments.upload(upload_attrs(raw_bytes: eicar), prefix: schema)

      assert verdict == "eicar-test-signature"

      # Nothing persisted -- asserted directly via DB counts, not inference
      # (Mutant A target: infected branch must short-circuit before any
      # upsert/insert).
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end

    test "an EICAR upload rejection is audit-logged with tenant/actor/hash metadata but never the raw bytes" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("iss0399-audit")

      eicar =
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

      uploaded_by = Ecto.UUID.generate()
      instance_id = Ecto.UUID.generate()

      log =
        ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
          assert {:error, :infected, _verdict} =
                   Attachments.upload(
                     upload_attrs(
                       raw_bytes: eicar,
                       instance_id: instance_id,
                       uploaded_by: uploaded_by
                     ),
                     prefix: schema
                   )
        end)

      assert log =~ "attachment upload rejected: infected content"
      assert log =~ tenant_id
      assert log =~ instance_id
      assert log =~ uploaded_by
      assert log =~ Base.encode16(:crypto.hash(:sha256, eicar), case: :lower)

      # The raw bytes/EICAR signature itself must never appear in the log line.
      refute log =~ "EICAR-STANDARD-ANTIVIRUS-TEST-FILE"
    end
  end

  describe "ISS-0399: a scanner adapter exception fails closed, never a false-clean" do
    defmodule RaisingScanner do
      @moduledoc false
      @behaviour Letflow.Repository.AttachmentScanner

      @impl true
      def scan(_raw_bytes, _content_type) do
        raise "simulated scanner crash"
      end
    end

    defp put_attachment_scanner!(module) do
      previous = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :attachment_scanner, module)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :attachment_scanner, previous)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      :ok
    end

    test "an adapter that raises returns {:error, :scan_unavailable}, not a false {:ok, :clean}, and nothing is persisted" do
      %{schema_name: schema} = provisioned_tenant("iss0399-raise")
      put_attachment_scanner!(RaisingScanner)

      assert Attachments.upload(upload_attrs(), prefix: schema) == {:error, :scan_unavailable}

      # Mutant B target: the rescue clause must return an error tuple, not
      # {:ok, :clean} -- asserted here by proving nothing was persisted, which
      # is only possible if the scan step genuinely fails closed.
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end
  end

  describe "ISS-0399: a non-:clean attachment's content is never servable via get_content/2" do
    test "a :pending row (pre-existing/backfilled shape) is rejected with {:error, :not_available}" do
      %{schema_name: schema} = provisioned_tenant("iss0399-pending")

      # upload/2 itself can never produce a :pending row (only :clean is ever
      # written on the write path) -- simulate the ONE way a :pending row can
      # exist: a pre-existing row from before this migration shipped
      # (design §1.1's DB-level default). Constructed directly via the
      # schema's own changeset/Repo.insert, bypassing upload/2 entirely, the
      # same way this codebase's other "simulate a pre-existing row" fixtures
      # work.
      tenant_id = Ecto.UUID.generate()
      content_hash = :crypto.hash(:sha256, "pending row content")

      {:ok, _artifact} =
        Repository.upsert_content(
          schema,
          tenant_id,
          content_hash,
          "text/plain",
          20,
          "pending row content"
        )

      pending_attrs = %{
        tenant_id: tenant_id,
        instance_id: Ecto.UUID.generate(),
        content_hash: content_hash,
        file_name: "pending.txt",
        content_type: "text/plain",
        byte_size: 20,
        uploaded_by: Ecto.UUID.generate(),
        scan_status: :pending
      }

      {:ok, pending_attachment} =
        %Attachment{}
        |> Attachment.changeset(pending_attrs)
        |> Repo.insert(prefix: schema)

      assert pending_attachment.scan_status == :pending

      # Mutant C target: the scan_status != :clean gate in get_content/3 must
      # reject this, not just :infected/:error.
      assert Attachments.get_content(pending_attachment.id, pending_attachment.instance_id,
               prefix: schema
             ) ==
               {:error, :not_available}

      # Metadata is still readable -- only byte-serving is gated (design §4.2).
      assert {:ok, %Attachment{scan_status: :pending}} =
               Attachments.get(pending_attachment.id, prefix: schema)
    end

    test "an :infected row (not reachable via upload/2, simulated directly) is rejected with {:error, :not_available}" do
      %{schema_name: schema} = provisioned_tenant("iss0399-infected-row")

      tenant_id = Ecto.UUID.generate()
      content_hash = :crypto.hash(:sha256, "infected row content")

      {:ok, _artifact} =
        Repository.upsert_content(
          schema,
          tenant_id,
          content_hash,
          "text/plain",
          22,
          "infected row content"
        )

      infected_attrs = %{
        tenant_id: tenant_id,
        instance_id: Ecto.UUID.generate(),
        content_hash: content_hash,
        file_name: "infected.txt",
        content_type: "text/plain",
        byte_size: 22,
        uploaded_by: Ecto.UUID.generate(),
        scan_status: :infected
      }

      {:ok, infected_attachment} =
        %Attachment{}
        |> Attachment.changeset(infected_attrs)
        |> Repo.insert(prefix: schema)

      assert Attachments.get_content(infected_attachment.id, infected_attachment.instance_id,
               prefix: schema
             ) ==
               {:error, :not_available}
    end
  end

  describe "list/2" do
    test "tenant-scoped and filtered by instance_id (AC5)" do
      %{schema_name: schema_a} = provisioned_tenant("req211-list-a")
      %{schema_name: schema_b} = provisioned_tenant("req211-list-b")

      instance_x = Ecto.UUID.generate()
      instance_y = Ecto.UUID.generate()

      assert {:ok, _} =
               Attachments.upload(upload_attrs(instance_id: instance_x), prefix: schema_a)

      assert {:ok, %{items: items_b}} =
               Attachments.list(%{instance_id: instance_x, cursor: nil, page_size: 10},
                 prefix: schema_b
               )

      assert items_b == []

      assert {:ok, %{items: items_wrong_instance}} =
               Attachments.list(%{instance_id: instance_y, cursor: nil, page_size: 10},
                 prefix: schema_a
               )

      assert items_wrong_instance == []

      assert {:ok, %{items: items_a}} =
               Attachments.list(%{instance_id: instance_x, cursor: nil, page_size: 10},
                 prefix: schema_a
               )

      assert length(items_a) == 1
    end

    test "rows older than 24 hours remain pageable" do
      %{schema_name: schema} = provisioned_tenant("cursor-issue-time-attachments")
      instance_id = Ecto.UUID.generate()

      entries =
        for n <- 1..3 do
          assert {:ok, entry} =
                   Attachments.upload(
                     upload_attrs(instance_id: instance_id, raw_bytes: "old-#{n}"),
                     prefix: schema
                   )

          entry
        end

      old =
        DateTime.utc_now()
        |> DateTime.add(-2 * 86_400, :second)
        |> DateTime.truncate(:microsecond)

      ids = Enum.map(entries, & &1.id)

      Repo.update_all(from(a in Attachment, where: a.id in ^ids), [set: [created_at: old]],
        prefix: schema
      )

      assert {:ok, %{items: [_], next_cursor: cursor1}} =
               Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 1},
                 prefix: schema
               )

      assert {:ok, %{items: [_], next_cursor: cursor2}} =
               Attachments.list(%{instance_id: instance_id, cursor: cursor1, page_size: 1},
                 prefix: schema
               )

      assert {:ok, %{items: [_], next_cursor: nil}} =
               Attachments.list(%{instance_id: instance_id, cursor: cursor2, page_size: 1},
                 prefix: schema
               )
    end

    test "cursor pagination returns the next distinct page with no repeated or skipped ids (AC6)" do
      %{schema_name: schema} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      for n <- 1..5 do
        assert {:ok, _} =
                 Attachments.upload(
                   upload_attrs(instance_id: instance_id, raw_bytes: "content-#{n}"),
                   prefix: schema
                 )
      end

      assert {:ok, page_1} =
               Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 2},
                 prefix: schema
               )

      assert length(page_1.items) == 2
      assert is_binary(page_1.next_cursor)

      assert {:ok, page_2} =
               Attachments.list(
                 %{instance_id: instance_id, cursor: page_1.next_cursor, page_size: 2},
                 prefix: schema
               )

      assert length(page_2.items) == 2

      ids_1 = Enum.map(page_1.items, & &1.id)
      ids_2 = Enum.map(page_2.items, & &1.id)
      refute Enum.any?(ids_2, &(&1 in ids_1))
    end
  end

  describe "get/2" do
    test "invalid id returns :invalid_id without a DB round-trip" do
      %{schema_name: schema} = provisioned_tenant()
      assert Attachments.get("not-a-uuid", prefix: schema) == {:error, :invalid_id}
    end

    test "nonexistent id in a real tenant schema returns :not_found" do
      %{schema_name: schema} = provisioned_tenant()
      assert Attachments.get(Ecto.UUID.generate(), prefix: schema) == {:error, :not_found}
    end
  end

  describe "delete/2 (AC7)" do
    test "removes the instance_attachments row only -- repository_artifacts row and a sibling attachment sharing the hash both survive" do
      %{schema_name: schema} = provisioned_tenant()

      shared_bytes = "shared for delete test"
      instance_id = Ecto.UUID.generate()

      assert {:ok, attachment_1} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_id, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert {:ok, attachment_2} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_id, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert {:ok, _deleted} =
               Attachments.delete(attachment_1.id, Ecto.UUID.generate(), prefix: schema)

      assert Attachments.get(attachment_1.id, prefix: schema) == {:error, :not_found}
      assert {:ok, _} = Attachments.get(attachment_2.id, prefix: schema)

      assert Repo.get!(Artifact, attachment_2.content_hash, prefix: schema)
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
    end
  end

  describe "cross-tenant isolation" do
    test "an attachment uploaded in tenant A's schema is not reachable from tenant B's schema" do
      %{schema_name: schema_a} = provisioned_tenant("req211-iso-a")
      %{schema_name: schema_b} = provisioned_tenant("req211-iso-b")

      assert {:ok, attachment} = Attachments.upload(upload_attrs(), prefix: schema_a)

      assert Attachments.get(attachment.id, prefix: schema_b) == {:error, :not_found}
      assert {:ok, _} = Attachments.get(attachment.id, prefix: schema_a)
    end

    test "two different tenants uploading byte-identical content produce two independent repository_artifacts rows, not one shared row (AC8)" do
      %{schema_name: schema_a} = provisioned_tenant("req211-dedup-a")
      %{schema_name: schema_b} = provisioned_tenant("req211-dedup-b")

      shared_bytes = "identical bytes across tenants"

      assert {:ok, attachment_a} =
               Attachments.upload(upload_attrs(raw_bytes: shared_bytes), prefix: schema_a)

      assert {:ok, attachment_b} =
               Attachments.upload(upload_attrs(raw_bytes: shared_bytes), prefix: schema_b)

      assert attachment_a.content_hash == attachment_b.content_hash

      # Each tenant's own schema independently holds a row for this hash --
      # not one shared row. Each schema has exactly one repository_artifacts
      # row of its own (not zero, not two) -- physically separate rows in
      # physically separate Postgres schemas, never a cross-tenant-shared row.
      row_in_a = Repo.get!(Artifact, attachment_a.content_hash, prefix: schema_a)
      row_in_b = Repo.get!(Artifact, attachment_b.content_hash, prefix: schema_b)

      assert row_in_a.content == shared_bytes
      assert row_in_b.content == shared_bytes
      assert Repo.aggregate(Artifact, :count, prefix: schema_a) == 1
      assert Repo.aggregate(Artifact, :count, prefix: schema_b) == 1
    end
  end

  describe "moduledoc content statements" do
    test "states per-tenant dedup boundary, no-canonicalisation, and the real content-scanning mechanism (ISS-0399)" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Attachments)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "Decision B"
      assert normalized =~ "never one shared row"
      assert normalized =~ "No canonicalisation is applied to attachment bytes"

      # ISS-0399 design §4.3: the old "Content-scanning deferral" section
      # (which said this was a "deliberately deferred follow-up") is REPLACED,
      # not appended to, by a statement of the mechanism actually shipped --
      # the deferral is now resolved, so asserting deferral language would
      # assert something no longer true. This is the corrected assertion:
      # the moduledoc must document the real synchronous scan step, its
      # reject-before-persist guarantee, and the default adapter, and must
      # NOT still claim the scan is deferred.
      refute normalized =~ "deliberately deferred follow-up"
      assert normalized =~ "synchronous"
      assert normalized =~ "reject-before-persist"
      assert normalized =~ "Letflow.Repository.AttachmentScanner.SignatureHeuristic"
    end
  end

  # AC10's original test ("no lib/letflow/routers/*.ex file references
  # Letflow.Repository.Attachments") asserted REQ-211's OWN scope boundary
  # at the time it was written -- REQ-211's own description states the
  # route/controller layer is explicitly out of REQ-211's scope and belongs
  # to a future requirement (REQ-212). That guard was a temporal statement
  # ("not yet, and not by this requirement"), not a permanent invariant that
  # instance_attachments must never have a route surface at all. REQ-212 has
  # now shipped `lib/letflow/routers/instances.ex`'s four
  # `/instances/:id/attachments...` routes atop this exact context module,
  # per design `lib/letflow/design/req212-instance-attachments-routes.md` --
  # removed rather than kept failing, since a permanently-red test asserting
  # the wrong thing is worse than no test. See
  # `test/letflow/routers/req212_attachments_routes_test.exs` for the route
  # layer's own coverage.

  describe "Repository.upsert_content/6 (option (a) shared upsert path)" do
    test "is a public function on Letflow.Repository" do
      # function_exported?/3 checks the loaded-module table, not the compiled
      # .beam on disk -- Repository may not yet be loaded if no earlier test
      # in this run has touched it (ISS-0401).
      Code.ensure_loaded?(Repository)
      assert function_exported?(Repository, :upsert_content, 6)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0785 regression -- cross-instance-same-tenant denial in get_content/3
  # must return {:error, :not_found} before any artifact blob read.
  #
  # Pre-fix failure evidence: the old get_content/2 had no instance_id parameter at
  # all; calling get_content/3 on pre-fix code raises UndefinedFunctionError at
  # runtime (trivially satisfied). Per WF-03 procedure for the "code did not exist"
  # case, a mutation of check_instance_match/2 is also reported in the handoff.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # REQ-390 -- per-tenant storage-quota tracking and queryable usage figure.
  # AC1: usage correct immediately after upload (tested together with AC4 in one test).
  # AC2: over-quota upload refused with {:error, :storage_quota_exceeded}, no DB rows.
  # AC3: quota check and per-file check independently triggerable.
  # AC4: delete reduces usage on the very next read (tested together with AC1).
  # ---------------------------------------------------------------------------------

  describe "REQ-390: per-tenant storage quota and usage tracking" do
    test "get_storage_usage/1 returns correct byte count after upload and after delete (AC1, AC4)" do
      %{schema_name: schema} = provisioned_tenant("req390-usage")
      raw_bytes = "hello attachment bytes"

      assert {:ok, 0} = Attachments.get_storage_usage(prefix: schema)

      assert {:ok, attachment} =
               Attachments.upload(upload_attrs(raw_bytes: raw_bytes), prefix: schema)

      assert {:ok, usage_after_upload} = Attachments.get_storage_usage(prefix: schema)
      assert usage_after_upload == byte_size(raw_bytes)

      assert {:ok, _deleted} =
               Attachments.delete(attachment.id, Ecto.UUID.generate(), prefix: schema)

      assert {:ok, 0} = Attachments.get_storage_usage(prefix: schema)
    end

    test "upload/2 refuses an upload that would exceed storage quota -- no DB rows created (AC2)" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("req390-quota")
      set_storage_allowance!(tenant_id, 1)

      assert Attachments.upload(upload_attrs(), prefix: schema) ==
               {:error, :storage_quota_exceeded}

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
    end

    test "storage_quota_exceeded triggers without hitting file_too_large (AC3)" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("req390-ac3a")
      # 100 bytes: well under the 25 MiB per-file ceiling, but over a 1-byte allowance
      raw_bytes = :binary.copy("x", 100)
      set_storage_allowance!(tenant_id, 1)

      assert Attachments.upload(upload_attrs(raw_bytes: raw_bytes), prefix: schema) ==
               {:error, :storage_quota_exceeded}
    end

    test "file_too_large triggers without triggering storage_quota (AC3)" do
      # Default allowance is 1 GiB; 26_214_401 bytes exceeds the 25 MiB per-file
      # ceiling and is well under the 1 GiB quota, so file_too_large fires before
      # the quota check is reached.
      %{schema_name: schema} = provisioned_tenant("req390-ac3b")
      oversized = :binary.copy("a", 26_214_401)

      assert Attachments.upload(upload_attrs(raw_bytes: oversized), prefix: schema) ==
               {:error, :file_too_large}
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-389 -- content-type allowlist enforcement.
  # AC1: a disallowed content_type is rejected before any persistence, checked before
  #      the size ceiling, the malware scan, and the storage-quota check.
  # AC3: application/pdf (already accepted before this change) continues to be accepted.
  # ---------------------------------------------------------------------------------

  describe "REQ-389: content-type allowlist" do
    test "a disallowed content_type is rejected before any persistence, with neither row created (AC1)" do
      %{schema_name: schema} = provisioned_tenant("req389-disallowed")

      assert Attachments.upload(upload_attrs(content_type: "video/mp4"), prefix: schema) ==
               {:error, :content_type_not_allowed}

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
    end

    test "content_type_not_allowed wins over file_too_large and storage_quota_exceeded when all three would independently fire (AC1 ordering)" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("req389-ordering")

      # Both independently-failing conditions are present: an oversized body
      # (would trigger :file_too_large on its own) and an exhausted storage
      # allowance (would trigger :storage_quota_exceeded on its own) -- only
      # the disallowed content_type should be observed, proving the new guard
      # is the literal first check in upload/2 (design §3.1).
      set_storage_allowance!(tenant_id, 1)
      oversized = :binary.copy("a", 26_214_401)

      assert Attachments.upload(
               upload_attrs(content_type: "video/mp4", raw_bytes: oversized),
               prefix: schema
             ) == {:error, :content_type_not_allowed}

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
    end

    test "application/pdf continues to be accepted (AC3 regression, same fixture REQ-211/212's own tests use)" do
      %{schema_name: schema} = provisioned_tenant("req389-pdf-regression")

      assert {:ok, %Attachment{content_type: "application/pdf"}} =
               Attachments.upload(
                 upload_attrs(content_type: "application/pdf", raw_bytes: "PDF-BYTES-HERE"),
                 prefix: schema
               )
    end
  end

  describe "ISS-0785: cross-instance-same-tenant denial in get_content/3" do
    test "returns {:error, :not_found} when the attachment belongs to a different instance in the same tenant" do
      %{schema_name: schema} = provisioned_tenant("iss0785-cross-instance")

      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()

      assert {:ok, attachment} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_a),
                 prefix: schema
               )

      # instance_b is a valid UUID in the same tenant schema but does not own
      # this attachment -- check_instance_match/2 must fire before the blob read
      # and return {:error, :not_found}.
      assert Attachments.get_content(attachment.id, instance_b, prefix: schema) ==
               {:error, :not_found}

      # Confirm the owning instance (instance_a) can still retrieve the content.
      assert {:ok, ^attachment, _artifact} =
               Attachments.get_content(attachment.id, instance_a, prefix: schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-391 §2 -- upload/2 and delete/2 each record one instance-history
  # entry (ATTACHMENT_ATTACHED / ATTACHMENT_REMOVED), naming the action,
  # file_name, and actor. Light inline coverage per ELIXIR-DEV's own handoff
  # (TEST-DESIGNER writes the full AC coverage later in this pipeline).
  # ---------------------------------------------------------------------------------

  describe "REQ-391 AC1 -- upload/2 records an ATTACHMENT_ATTACHED history entry" do
    test "produces a history/timeline entry naming the file and uploading actor" do
      %{schema_name: schema} = provisioned_tenant("req391-attach")
      instance_id = Ecto.UUID.generate()
      uploaded_by = Ecto.UUID.generate()
      seed_active_instance_projection!(schema, instance_id)

      assert {:ok, attachment} =
               Attachments.upload(
                 upload_attrs(
                   instance_id: instance_id,
                   file_name: "delivery-note.pdf",
                   uploaded_by: uploaded_by
                 ),
                 prefix: schema
               )

      # Asserted over the existing history/timeline read path (Letflow.Instances),
      # not by inspecting the events table directly.
      assert {:ok, %{items: items}} =
               Instances.history(instance_id, %{page_size: 50}, prefix: schema)

      assert [event] = Enum.filter(items, &(&1.event_type == "ATTACHMENT_ATTACHED"))
      assert event.actor_id == uploaded_by
      assert event.payload["attachment_id"] == attachment.id
      assert event.payload["file_name"] == "delivery-note.pdf"

      assert {:ok, %{items: timeline_items}} =
               Instances.timeline(instance_id, %{page_size: 50}, prefix: schema)

      assert [timeline_event] =
               Enum.filter(timeline_items, &(&1.event_type == "ATTACHMENT_ATTACHED"))

      # No Letflow.Identity.User row exists for uploaded_by in this test, so
      # actor_display_name falls through Instances's own 4-level fallback
      # (design §2) to "system" -- the render_description/3 clause under test
      # (lib/letflow/instances.ex) still uses whatever actor name it's given,
      # which this asserts, rather than duplicating that fallback's own
      # resolution logic here.
      assert timeline_event.description == "delivery-note.pdf attached by system"
    end
  end

  describe "REQ-391 AC2 -- delete/2 records an ATTACHMENT_REMOVED history entry" do
    test "produces a distinct history entry naming the file and removing actor, retained after the row is gone" do
      %{schema_name: schema} = provisioned_tenant("req391-remove")
      instance_id = Ecto.UUID.generate()
      deleted_by = Ecto.UUID.generate()
      seed_active_instance_projection!(schema, instance_id)

      assert {:ok, attachment} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_id, file_name: "signed-form.pdf"),
                 prefix: schema
               )

      assert {:ok, _deleted} = Attachments.delete(attachment.id, deleted_by, prefix: schema)

      # The attachment row itself is gone...
      assert Attachments.get(attachment.id, prefix: schema) == {:error, :not_found}

      # ...but the history entry naming its removal is retained.
      assert {:ok, %{items: items}} =
               Instances.history(instance_id, %{page_size: 50}, prefix: schema)

      assert [attached_event] = Enum.filter(items, &(&1.event_type == "ATTACHMENT_ATTACHED"))
      assert [removed_event] = Enum.filter(items, &(&1.event_type == "ATTACHMENT_REMOVED"))

      assert attached_event.payload["attachment_id"] == attachment.id
      assert removed_event.actor_id == deleted_by
      assert removed_event.payload["attachment_id"] == attachment.id
      assert removed_event.payload["file_name"] == "signed-form.pdf"
    end
  end

  describe "REQ-391 -- event_type_registry seeding" do
    test "ATTACHMENT_ATTACHED and ATTACHMENT_REMOVED are both seeded for a freshly-provisioned tenant" do
      %{schema_name: schema} = provisioned_tenant("req391-seed")

      names =
        Letflow.EventStore.Registry.EventType
        |> Repo.all(prefix: schema)
        |> Enum.map(& &1.name)

      assert "ATTACHMENT_ATTACHED" in names
      assert "ATTACHMENT_REMOVED" in names
    end
  end

  describe "storage_summary/1 (REQ-392 design §1.1)" do
    test "returns {:ok, %{used_bytes, allowance_bytes}} reflecting real uploads and the tenant's own allowance" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("req392-summary")
      instance_id = Ecto.UUID.generate()
      seed_active_instance_projection!(schema, instance_id)

      set_storage_allowance!(tenant_id, 500_000)

      assert {:ok, %{used_bytes: 0, allowance_bytes: 500_000}} =
               Attachments.storage_summary(prefix: schema)

      assert {:ok, _attachment} =
               Attachments.upload(
                 upload_attrs(
                   instance_id: instance_id,
                   file_name: "first.pdf",
                   raw_bytes: :crypto.strong_rand_bytes(1_000)
                 ),
                 prefix: schema
               )

      assert {:ok, %{used_bytes: 1_000, allowance_bytes: 500_000}} =
               Attachments.storage_summary(prefix: schema)

      assert {:ok, _attachment2} =
               Attachments.upload(
                 upload_attrs(
                   instance_id: instance_id,
                   file_name: "second.pdf",
                   raw_bytes: :crypto.strong_rand_bytes(2_500)
                 ),
                 prefix: schema
               )

      # AC3's own wording: the figure must rise correctly across an accepted
      # upload -- 1_000 + 2_500 = 3_500, not e.g. only the latest upload's
      # byte_size or a stale cached value.
      assert {:ok, %{used_bytes: 3_500, allowance_bytes: 500_000}} =
               Attachments.storage_summary(prefix: schema)
    end

    test "used_bytes falls after a removal (AC3's own 'and a removal' wording)" do
      %{schema_name: schema} = provisioned_tenant("req392-summary-del")
      instance_id = Ecto.UUID.generate()
      seed_active_instance_projection!(schema, instance_id)
      deleted_by = Ecto.UUID.generate()

      assert {:ok, attachment} =
               Attachments.upload(
                 upload_attrs(
                   instance_id: instance_id,
                   file_name: "removable.pdf",
                   raw_bytes: :crypto.strong_rand_bytes(4_096)
                 ),
                 prefix: schema
               )

      assert {:ok, %{used_bytes: 4_096}} = Attachments.storage_summary(prefix: schema)

      assert {:ok, _deleted} = Attachments.delete(attachment.id, deleted_by, prefix: schema)

      assert {:ok, %{used_bytes: 0}} = Attachments.storage_summary(prefix: schema)
    end

    test "is per-tenant, not per-instance -- takes no instance_id and does not mix two instances' usage in the same tenant" do
      %{schema_name: schema} = provisioned_tenant("req392-summary-multi")
      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()
      seed_active_instance_projection!(schema, instance_a)
      seed_active_instance_projection!(schema, instance_b)

      assert {:ok, _} =
               Attachments.upload(
                 upload_attrs(
                   instance_id: instance_a,
                   file_name: "a.pdf",
                   raw_bytes: :crypto.strong_rand_bytes(600)
                 ),
                 prefix: schema
               )

      assert {:ok, _} =
               Attachments.upload(
                 upload_attrs(
                   instance_id: instance_b,
                   file_name: "b.pdf",
                   raw_bytes: :crypto.strong_rand_bytes(400)
                 ),
                 prefix: schema
               )

      # storage_summary/1 has no instance_id parameter to pass at all -- this
      # assertion is really "the function signature is per-tenant", proven
      # by the fact that the returned figure is the SUM across both
      # instances, not either instance's own subset.
      assert {:ok, %{used_bytes: 1_000}} = Attachments.storage_summary(prefix: schema)
    end

    test "returns {:error, :tenant_not_found} when the tenant row is absent (same unreachable-but-mapped edge check_storage_quota/3 guards, ISS-0788 precedent)" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("req392-summary-norow")

      Repo.delete_all(
        from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
      )

      Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id))

      assert {:error, :tenant_not_found} = Attachments.storage_summary(prefix: schema)
    end
  end
end
