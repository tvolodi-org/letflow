Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.AttachmentsTest do
  @moduledoc """
  GH #3503 / REQ-626 parts A and B (B1..B9 for the submitted branch, state/tasks/T-0963/design.md), the context half of criteria 1, 2, 3, 4, 5, 7 and 9 (spec:
  state/tasks/T-0962/design.md, tests A1..A3, R1..R6, L1, L2, D1, P1..P3, U1..U3, S1, S4, S5):
  `Letflow.Modules.Procurement.Attachments` on a real tenant.

  Not forced here, with the reason: two concurrent replaces of one slot and the lock-timeout arm
  (the file runs in the shared Sandbox mode, one connection); U3 and the document row lock cover them
  in effect.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Letflow.Audit.Entry
  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.Procurement.Attachment
  alias Letflow.Modules.Procurement.Attachments
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo
  alias Letflow.Repository.Artifact

  defmodule Infected do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(_bytes, _type), do: {:ok, :infected, "TEST-VIRUS"}
  end

  defmodule Retired do
    @moduledoc false
    @behaviour Letflow.Documents.OrgResolver
    @impl true
    def unit_exists?(_prefix, _unit), do: false
    @impl true
    def legal_entity_of(_prefix, _unit), do: {:error, :unit_not_found}
  end

  defmodule Down do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(_bytes, _type), do: {:error, :down}
  end

  setup do
    ctx = Fixture.tenant!("gh3503a")
    requester = Ecto.UUID.generate()

    {:ok, %{document_id: id}} =
      PurchaseRequests.create(ctx.schema, requester, Fixture.params(ctx))

    base = Repo.aggregate(Artifact, :count, prefix: ctx.schema)
    Map.merge(ctx, %{requester: requester, id: id, base_blobs: base})
  end

  defp file(name \\ "a.pdf", bytes \\ "hello", type \\ "application/pdf"),
    do: %{file_name: name, content_type: type, bytes: bytes}

  defp attach!(ctx, name \\ "a.pdf", bytes \\ "hello") do
    {:ok, view} = Attachments.attach(ctx.schema, ctx.requester, ctx.id, file(name, bytes))
    view
  end

  defp rows(ctx), do: Repo.aggregate(Attachment, :count, prefix: ctx.schema)
  # byte rows added since setup (a fresh tenant already holds a few seeded ones)
  defp blobs(ctx), do: Repo.aggregate(Artifact, :count, prefix: ctx.schema) - ctx.base_blobs
  defp audits(ctx), do: Repo.aggregate(Entry, :count, prefix: ctx.schema)

  defp put_scanner!(module) do
    previous = Application.get_env(:letflow, :attachment_scanner)
    Application.put_env(:letflow, :attachment_scanner, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, :attachment_scanner, previous),
        else: Application.delete_env(:letflow, :attachment_scanner)
    end)
  end

  describe "attach" do
    test "A1: two files make two slots in the draft", ctx do
      one = attach!(ctx, "a.pdf", "one")
      two = attach!(ctx, "b.pdf", "two")

      assert one.slot_id == one.attachment_id
      assert two.slot_id == two.attachment_id
      assert one.slot_id != two.slot_id
      assert one.version_no == 1 and one.replaces_id == nil
      assert one.uploaded_by == ctx.requester
      assert %DateTime{} = one.uploaded_at
      assert rows(ctx) == 2
    end

    test "A2: the same bytes twice make two link rows and one byte row", ctx do
      attach!(ctx, "a.pdf", "same")
      attach!(ctx, "b.pdf", "same")
      assert rows(ctx) == 2
      assert blobs(ctx) == 1
    end

    test "A3: the view has the listed fields and no content hash", ctx do
      view = attach!(ctx)

      assert Enum.sort(Map.keys(view)) ==
               Enum.sort(~w(attachment_id slot_id version_no file_name content_type byte_size
                            uploaded_by uploaded_at replaces_id)a)

      hash = :crypto.hash(:sha256, "hello")
      body = inspect(view)
      refute body =~ Base.encode16(hash, case: :lower)
      refute body =~ Base.encode64(hash)
      assert view.byte_size == 5
    end
  end

  describe "refusals write nothing" do
    test "R1: a type outside the allow-list", ctx do
      assert {:error, :content_type_not_allowed} =
               Attachments.attach(
                 ctx.schema,
                 ctx.requester,
                 ctx.id,
                 file("a.html", "x", "text/html")
               )

      assert {rows(ctx), blobs(ctx)} == {0, 0}
    end

    test "R2: 26214401 bytes are refused, a small file is accepted", ctx do
      big = :binary.copy("a", 26_214_401)

      assert {:error, :file_too_large} =
               Attachments.attach(ctx.schema, ctx.requester, ctx.id, file("a.pdf", big))

      assert {rows(ctx), blobs(ctx)} == {0, 0}
      assert %{byte_size: 1} = attach!(ctx, "ok.pdf", "x")
    end

    test "R3: an infected verdict", ctx do
      put_scanner!(Infected)

      assert {:error, :infected} =
               Attachments.attach(ctx.schema, ctx.requester, ctx.id, file())

      assert {rows(ctx), blobs(ctx)} == {0, 0}
    end

    test "R4: an unavailable scanner", ctx do
      put_scanner!(Down)

      assert {:error, :scan_unavailable} =
               Attachments.attach(ctx.schema, ctx.requester, ctx.id, file())

      assert {rows(ctx), blobs(ctx)} == {0, 0}
    end

    test "R5: a blank name and a 256-character name", ctx do
      for name <- ["   ", String.duplicate("n", 256), 5] do
        assert {:error, {:validation, [%{field: "file_name"}]}} =
                 Attachments.attach(ctx.schema, ctx.requester, ctx.id, file(name))
      end

      assert {rows(ctx), blobs(ctx)} == {0, 0}
    end

    test "R6: scan_content/2 gives the verdict of the configured scanner", ctx do
      alias Letflow.Repository.Attachments, as: Repo_attachments
      assert {:ok, :clean} = Repo_attachments.scan_content("plain", "text/plain")
      put_scanner!(Infected)
      assert {:ok, :infected, "TEST-VIRUS"} = Repo_attachments.scan_content("plain", "text/plain")
      assert rows(ctx) == 0
    end
  end

  describe "list and download" do
    test "L1: version 1 stays listed after version 2 exists", ctx do
      view = attach!(ctx)
      issue(ctx)
      {:ok, %{version_no: 2}} = revise(ctx)

      assert {:ok, %{version_no: 1, attachments: [%{attachment_id: id}]}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id, version_no: "1")

      assert id == view.attachment_id

      # the open draft is version 2 and has no files
      assert {:ok, %{version_no: 2, attachments: []}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)
    end

    test "L2: default version, explicit version, bad and absent version", ctx do
      view = attach!(ctx)

      assert {:ok, %{version_no: 1, attachments: [entry]}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)

      assert entry.attachment_id == view.attachment_id and entry.replaces_id == nil

      issue(ctx)

      assert {:ok, %{version_no: 1, attachments: [_one]}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)

      assert {:error, :not_found} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id, version_no: "9")

      for bad <- ["x", "0", "1.5", "-1", ""] do
        assert {:error, {:validation, [%{field: "version_no"}]}} =
                 Attachments.list(ctx.schema, ctx.requester, ctx.id, version_no: bad)
      end
    end

    test "D1: download returns the stored bytes, name and type", ctx do
      view = attach!(ctx, "report.pdf", "BYTES")

      assert {:ok, %{content: "BYTES", content_type: "application/pdf", file_name: "report.pdf"}} =
               Attachments.download(ctx.schema, ctx.requester, ctx.id, view.attachment_id)
    end

    test "D2: absent, malformed and foreign attachment ids are not found", ctx do
      attach!(ctx)

      {:ok, %{document_id: other}} =
        PurchaseRequests.create(ctx.schema, ctx.requester, Fixture.params(ctx))

      theirs = Ecto.UUID.generate()

      for id <- [theirs, "not-a-uuid", nil] do
        assert {:error, :not_found} = Attachments.download(ctx.schema, ctx.requester, ctx.id, id)
      end

      [row] = Repo.all(Attachment, prefix: ctx.schema)

      assert {:error, :not_found} =
               Attachments.download(ctx.schema, ctx.requester, other, row.id)
    end
  end

  describe "replace" do
    test "P1: a replacement keeps slot and version, the old row and bytes remain", ctx do
      old = attach!(ctx, "a.pdf", "old")

      assert {:ok, new} =
               Attachments.replace(
                 ctx.schema,
                 ctx.requester,
                 ctx.id,
                 old.slot_id,
                 file("a2.pdf", "new")
               )

      assert new.slot_id == old.slot_id and new.version_no == old.version_no
      assert new.replaces_id == old.attachment_id
      assert new.attachment_id != old.attachment_id

      assert {:ok, %{attachments: [%{attachment_id: listed}]}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)

      assert listed == new.attachment_id
      assert rows(ctx) == 2 and blobs(ctx) == 2

      assert {:ok, %{content: "old"}} =
               Attachments.download(ctx.schema, ctx.requester, ctx.id, old.attachment_id)
    end

    test "P2: a second replace replaces the newest row", ctx do
      old = attach!(ctx, "a.pdf", "v1")

      {:ok, two} =
        Attachments.replace(ctx.schema, ctx.requester, ctx.id, old.slot_id, file("a.pdf", "v2"))

      {:ok, three} =
        Attachments.replace(ctx.schema, ctx.requester, ctx.id, old.slot_id, file("a.pdf", "v3"))

      assert three.replaces_id == two.attachment_id
      assert rows(ctx) == 3

      assert {:ok, %{attachments: [%{attachment_id: id}]}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)

      assert id == three.attachment_id
    end

    test "an unknown or malformed slot is not found", ctx do
      attach!(ctx)

      for slot <- [Ecto.UUID.generate(), "nope"] do
        assert {:error, :not_found} =
                 Attachments.replace(ctx.schema, ctx.requester, ctx.id, slot, file())
      end

      assert rows(ctx) == 1
    end

    test "B8: a request whose current version is cancelled answers not_draft", ctx do
      attach!(ctx)
      issue(ctx)

      {:ok, _} =
        Documents.cancel(
          ctx.schema,
          %{document_id: ctx.id, version_no: 1, reason: "no longer needed"},
          ctx.requester
        )

      before = {rows(ctx), blobs(ctx), audits(ctx)}

      assert {:error, :not_draft} =
               Attachments.attach(ctx.schema, ctx.requester, ctx.id, file("n.pdf", "n"))

      assert {:error, :not_draft} =
               Attachments.replace(
                 ctx.schema,
                 ctx.requester,
                 ctx.id,
                 Ecto.UUID.generate(),
                 file("n.pdf", "n")
               )

      assert {rows(ctx), blobs(ctx), audits(ctx)} == before
    end
  end

  describe "submitted request: new version (part B)" do
    defp version_rows(ctx) do
      Repo.all(
        from(v in DocumentVersion, where: v.document_id == ^ctx.id, order_by: v.version_no),
        prefix: ctx.schema
      )
    end

    defp all_attachments(ctx),
      do: Repo.all(from(a in Attachment, order_by: [a.version_no, a.id]), prefix: ctx.schema)

    test "B1: replace after submission makes N+1 and keeps N", ctx do
      old = attach!(ctx, "a.pdf", "original")
      other = attach!(ctx, "b.pdf", "second")
      issue(ctx)
      [v1] = version_rows(ctx)
      snapshot = Enum.filter(all_attachments(ctx), &(&1.version_no == 1))
      blobs_before = blobs(ctx)

      assert {:ok, view} =
               Attachments.replace(
                 ctx.schema,
                 ctx.requester,
                 ctx.id,
                 old.slot_id,
                 file("c.pdf", "replacement")
               )

      assert view.version_no == 2 and view.replaces_id == old.attachment_id
      assert view.slot_id == old.slot_id

      [n, n1] = version_rows(ctx)
      assert n.status == :superseded and n.content_hash == v1.content_hash
      assert n1.status == :issued and n1.content == n.content
      assert Repo.get(Document, ctx.id, prefix: ctx.schema).current_version == n1.id

      assert Enum.filter(all_attachments(ctx), &(&1.version_no == 1)) == snapshot

      assert {:ok, %{version_no: 2, attachments: heads}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)

      assert length(heads) == 2
      copy = Enum.find(heads, &(&1.slot_id == other.slot_id))
      assert copy.attachment_id != other.attachment_id and copy.replaces_id == nil
      assert Enum.find(heads, &(&1.slot_id == old.slot_id)).file_name == "c.pdf"

      assert {:ok, %{version_no: 1, attachments: [first, _second]}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id, version_no: 1)

      assert first.attachment_id == old.attachment_id

      assert {:ok, %{content: "original"}} =
               Attachments.download(ctx.schema, ctx.requester, ctx.id, old.attachment_id)

      assert {:ok, %{content: "second"}} =
               Attachments.download(ctx.schema, ctx.requester, ctx.id, copy.attachment_id)

      assert blobs(ctx) == blobs_before + 1
    end

    test "B2: attach after submission adds a slot in N+1", ctx do
      attach!(ctx, "a.pdf", "one")
      attach!(ctx, "b.pdf", "two")
      issue(ctx)

      assert {:ok, view} =
               Attachments.attach(ctx.schema, ctx.requester, ctx.id, file("n.pdf", "three"))

      assert view.version_no == 2 and view.replaces_id == nil and
               view.slot_id == view.attachment_id

      assert {:ok, %{version_no: 2, attachments: heads}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id)

      assert length(heads) == 3

      assert {:ok, %{version_no: 1, attachments: v1}} =
               Attachments.list(ctx.schema, ctx.requester, ctx.id, version_no: 1)

      assert length(v1) == 2
    end

    test "B3: a second replace gives N+2; every version lists its own files", ctx do
      old = attach!(ctx, "a.pdf", "v1")
      issue(ctx)

      {:ok, two} =
        Attachments.replace(ctx.schema, ctx.requester, ctx.id, old.slot_id, file("b.pdf", "v2"))

      {:ok, three} =
        Attachments.replace(ctx.schema, ctx.requester, ctx.id, old.slot_id, file("c.pdf", "v3"))

      assert three.version_no == 3 and three.replaces_id == two.attachment_id

      for {no, name} <- [{1, "a.pdf"}, {2, "b.pdf"}, {3, "c.pdf"}] do
        assert {:ok, %{attachments: [%{file_name: ^name}]}} =
                 Attachments.list(ctx.schema, ctx.requester, ctx.id, version_no: no)
      end
    end

    test "B4: a refused issue rolls back the version, the rows and the bytes", ctx do
      old = attach!(ctx)
      issue(ctx)
      before = {length(version_rows(ctx)), rows(ctx), blobs(ctx), audits(ctx)}
      current = Repo.get(Document, ctx.id, prefix: ctx.schema).current_version

      Process.put(:letflow_document_org_resolver, Retired)

      assert {:error, :org_unit_not_found} =
               Attachments.replace(
                 ctx.schema,
                 ctx.requester,
                 ctx.id,
                 old.slot_id,
                 file("z.pdf", "zzz")
               )

      assert {length(version_rows(ctx)), rows(ctx), blobs(ctx), audits(ctx)} == before
      assert Repo.get(Document, ctx.id, prefix: ctx.schema).current_version == current
    end

    test "B5: one audit entry with ids and counts, plus the document entries", ctx do
      old = attach!(ctx, "secret-name.pdf", "secret-bytes")
      attach!(ctx, "b.pdf", "b")
      issue(ctx)

      {:ok, _} =
        Attachments.replace(
          ctx.schema,
          ctx.requester,
          ctx.id,
          old.slot_id,
          file("secret2.pdf", "s2")
        )

      entries = Repo.all(from(e in Entry, order_by: e.inserted_at), prefix: ctx.schema)
      replaced = Enum.filter(entries, &(&1.action == "procurement.attachment_replaced"))
      assert [entry] = replaced
      assert entry.after_state["version_no"] == 2
      assert entry.after_state["previous_version_no"] == 1
      assert entry.after_state["carried_count"] == 1

      assert entry.after_state |> Map.keys() |> Enum.sort() ==
               ~w(attachment_id byte_size carried_count previous_version_no replaces_id slot_id version_no)

      refute inspect(entry) =~ "secret"
      actions = Enum.map(entries, & &1.action)
      assert "document.superseded" in actions and "document.issued" in actions
    end

    test "B6: a stranger, a decider and a malformed id get not_found", ctx do
      old = attach!(ctx)
      issue(ctx)
      before = {length(version_rows(ctx)), rows(ctx), blobs(ctx), audits(ctx)}
      stranger = Ecto.UUID.generate()

      for who <- [stranger, ctx.requester],
          id <- [ctx.id, "bad"],
          who == stranger or id == "bad" do
        assert {:error, :not_found} = Attachments.attach(ctx.schema, who, id, file("x.pdf", "x"))

        assert {:error, :not_found} =
                 Attachments.replace(ctx.schema, who, id, old.slot_id, file("x.pdf", "x"))
      end

      assert {length(version_rows(ctx)), rows(ctx), blobs(ctx), audits(ctx)} == before
    end

    test "B7: an unknown slot or a slot of another request writes nothing", ctx do
      attach!(ctx)
      issue(ctx)

      {:ok, %{document_id: other_id}} =
        PurchaseRequests.create(ctx.schema, ctx.requester, Fixture.params(ctx))

      {:ok, foreign} = Attachments.attach(ctx.schema, ctx.requester, other_id, file("f.pdf", "f"))
      before = {length(version_rows(ctx)), rows(ctx), blobs(ctx), audits(ctx)}

      for slot <- [Ecto.UUID.generate(), foreign.slot_id, "nope"] do
        assert {:error, :not_found} =
                 Attachments.replace(ctx.schema, ctx.requester, ctx.id, slot, file("x.pdf", "x"))
      end

      assert {length(version_rows(ctx)), rows(ctx), blobs(ctx), audits(ctx)} == before
    end

    test "B9: an approval of N does not cover N+1; the decider still reads N", ctx do
      old = attach!(ctx, "a.pdf", "original")
      issue(ctx)
      approver = Ecto.UUID.generate()
      [v1] = version_rows(ctx)

      decide = fn version_no, hash ->
        Decisions.record(ctx.schema, approver, %{
          document_id: ctx.id,
          version_no: version_no,
          content_hash: hash,
          decision: "approve",
          idempotency_key: "d-" <> Ecto.UUID.generate()
        })
      end

      assert {:ok, _} = decide.(1, v1.content_hash)
      assert Decisions.approved?(ctx.schema, ctx.id, 1)

      {:ok, _} =
        Attachments.replace(
          ctx.schema,
          ctx.requester,
          ctx.id,
          old.slot_id,
          file("b.pdf", "changed")
        )

      assert {:ok,
              %{approved: false, state: :submitted, current_version_no: 2, content_hash: hash2}} =
               Decisions.status(ctx.schema, ctx.id)

      refute Decisions.approved?(ctx.schema, ctx.id, 1)

      assert {:ok, %{version_no: 1, attachments: [only]}} =
               Attachments.list(ctx.schema, approver, ctx.id, decider?: true, version_no: 1)

      assert only.attachment_id == old.attachment_id

      assert {:ok, %{content: "original"}} =
               Attachments.download(ctx.schema, approver, ctx.id, old.attachment_id,
                 decider?: true
               )

      assert {:error, :binding_refused} = decide.(2, v1.content_hash)
      assert {:ok, _} = decide.(2, hash2)
      assert Decisions.approved?(ctx.schema, ctx.id, 2)
    end
  end

  describe "append-only table" do
    test "U1: raw UPDATE and DELETE are refused", ctx do
      attach!(ctx)
      table = ~s("#{ctx.schema}".procurement_attachments)

      for sql <- ["UPDATE #{table} SET file_name = 'x'", "DELETE FROM #{table}"] do
        assert_raise Postgrex.Error, ~r/immutable/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql) end)
        end
      end
    end

    test "U2: a second root row of a slot is a unique violation mapped to slot_conflict", ctx do
      row = attach!(ctx)
      [stored] = Repo.all(Attachment, prefix: ctx.schema)

      attrs = %{
        id: Ecto.UUID.generate(),
        document_id: ctx.id,
        version_no: 1,
        slot_id: row.slot_id,
        content_hash: stored.content_hash,
        file_name: "dup.pdf",
        content_type: "application/pdf",
        byte_size: 5,
        uploaded_by: ctx.requester,
        uploaded_at: DateTime.utc_now()
      }

      assert {:error, changeset} =
               attrs |> Attachment.insert_changeset() |> Repo.insert(prefix: ctx.schema)

      assert {_msg, opts} = changeset.errors[:slot_id]
      assert opts[:constraint] == :unique
    end

    test "U3: two rows replacing one row are a unique violation", ctx do
      old = attach!(ctx)

      {:ok, _new} =
        Attachments.replace(ctx.schema, ctx.requester, ctx.id, old.slot_id, file("b.pdf", "b"))

      [stored | _] =
        Repo.all(from(a in Attachment, where: a.id == ^old.attachment_id), prefix: ctx.schema)

      attrs = %{
        id: Ecto.UUID.generate(),
        document_id: ctx.id,
        version_no: 1,
        slot_id: old.slot_id,
        content_hash: stored.content_hash,
        file_name: "fork.pdf",
        content_type: "application/pdf",
        byte_size: 5,
        uploaded_by: ctx.requester,
        uploaded_at: DateTime.utc_now(),
        replaces_id: old.attachment_id
      }

      assert {:error, changeset} =
               attrs |> Attachment.insert_changeset() |> Repo.insert(prefix: ctx.schema)

      assert {_msg, opts} = changeset.errors[:replaces_id]
      assert opts[:constraint] == :unique
    end
  end

  describe "ownership and audit" do
    test "S1: a non-requester, another type and another tenant get not_found", ctx do
      other = Ecto.UUID.generate()
      other_tenant = Fixture.tenant!("gh3503b")

      assert {:error, :not_found} =
               Attachments.replace(ctx.schema, other, ctx.id, Ecto.UUID.generate(), file())

      assert {:error, :not_found} = Attachments.attach(ctx.schema, other, ctx.id, file())

      assert {:error, :not_found} =
               Attachments.attach(other_tenant.schema, ctx.requester, ctx.id, file())

      assert {:error, :not_found} = Attachments.attach(ctx.schema, ctx.requester, "bad", file())
      assert rows(ctx) == 0
    end

    test "S6: a decider reads, a stranger does not", ctx do
      view = attach!(ctx)
      other = Ecto.UUID.generate()

      assert {:error, :not_found} = Attachments.list(ctx.schema, other, ctx.id)

      assert {:ok, %{attachments: [_one]}} =
               Attachments.list(ctx.schema, other, ctx.id, decider?: true)

      assert {:ok, %{content: "hello"}} =
               Attachments.download(ctx.schema, other, ctx.id, view.attachment_id, decider?: true)

      assert {:error, :not_found} =
               Attachments.download(ctx.schema, other, ctx.id, view.attachment_id)
    end

    test "S4: one audit row per write, ids and counts only, none for a refusal", ctx do
      start = audits(ctx)
      old = attach!(ctx, "secret-name.pdf", "secret-bytes")
      assert audits(ctx) == start + 1

      {:ok, new} =
        Attachments.replace(
          ctx.schema,
          ctx.requester,
          ctx.id,
          old.slot_id,
          file("secret-name2.pdf", "b")
        )

      assert audits(ctx) == start + 2

      entries =
        Repo.all(
          from(e in Entry,
            where: like(e.action, "procurement.attachment_%"),
            order_by: e.inserted_at
          ),
          prefix: ctx.schema
        )

      assert Enum.map(entries, & &1.action) |> Enum.sort() ==
               ["procurement.attachment_added", "procurement.attachment_replaced"]

      added = Enum.find(entries, &(&1.action == "procurement.attachment_added"))
      replaced = Enum.find(entries, &(&1.action == "procurement.attachment_replaced"))

      assert added.after_state |> Map.keys() |> Enum.sort() ==
               ~w(attachment_id byte_size slot_id version_no)

      assert replaced.after_state |> Map.keys() |> Enum.sort() ==
               ~w(attachment_id byte_size replaces_id slot_id version_no)

      assert replaced.after_state["attachment_id"] == new.attachment_id
      refute inspect(entries) =~ "secret"

      {:error, :content_type_not_allowed} =
        Attachments.attach(ctx.schema, ctx.requester, ctx.id, file("x", "x", "text/html"))

      assert audits(ctx) == start + 2
    end

    test "S5: each refusal is counted once without ids or names", ctx do
      test = self()
      handler = "gh3503-" <> Ecto.UUID.generate()

      :telemetry.attach(
        handler,
        [:letflow, :procurement, :refused],
        fn _event, _m, meta, _ -> send(test, {:refused, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:error, :content_type_not_allowed} =
        Attachments.attach(
          ctx.schema,
          ctx.requester,
          ctx.id,
          file("secret.html", "x", "text/html")
        )

      assert_receive {:refused, meta}
      assert meta.action == :attach_attachment and meta.reason == :content_type_not_allowed
      refute inspect(meta) =~ "secret"
      refute inspect(meta) =~ ctx.id
      refute_receive {:refused, _}, 50
    end
  end

  defp issue(ctx) do
    {:ok, _} =
      PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, %{
        document_id: ctx.id,
        version_no: 1,
        content_hash: nil,
        idempotency_key: "s-" <> Ecto.UUID.generate()
      })
  end

  defp revise(ctx),
    do:
      PurchaseRequests.revise(
        ctx.schema,
        ctx.requester,
        ctx.id,
        Fixture.params(ctx, %{"justification" => "More"})
      )
end
