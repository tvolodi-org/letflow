defmodule Letflow.AttachmentsTest do
  @moduledoc """
  T-2040 S-*: `Letflow.Attachments` on real committed tenants (the service half of criteria C2..C10 of
  the design). The image byte rules are in `attachments/image_test.exs`; the tables in
  `migrations/create_attachments_test.exs`.

  Not forced here: the add-versus-delete race on one blob (two connections inside one owner lock);
  the owner lock and the upsert row lock make it safe by construction, and the single-connection
  tests cover the sequential halves.
  """
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Attachments
  alias Letflow.Attachments.{Blob, Link}
  alias Letflow.Audit.Entry
  alias Letflow.AttachmentsImageFixture, as: Fx
  alias Letflow.{Repo, TenantFixture}
  alias Letflow.Repository.Attachments, as: RepoAttachments

  @sentinel Fx.sentinel()

  defmodule Recorder do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(bytes, _type) do
      if pid = Process.whereis(:t2040_scan_recorder), do: send(pid, {:scanned, bytes})
      {:ok, :clean}
    end
  end

  defmodule Infected do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(_bytes, _type), do: {:ok, :infected, "TEST-VIRUS"}
  end

  defmodule Down do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(_bytes, _type), do: raise("scanner down")
  end

  setup do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2040")
    actor = Ecto.UUID.generate()

    %{
      fx: fx,
      prefix: fx.schema_name,
      owner: %{kind: "assets_card", id: Ecto.UUID.generate()},
      actor: actor,
      ctx: %{actor_id: actor, trace_id: "trace-t2040"}
    }
  end

  defp put_scanner!(module) do
    previous = Application.get_env(:letflow, :attachment_scanner)
    Application.put_env(:letflow, :attachment_scanner, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, :attachment_scanner, previous),
        else: Application.delete_env(:letflow, :attachment_scanner)
    end)
  end

  # A distinct JPEG per `n` (different pad = different bytes).
  defp img(n \\ 0, opts \\ []), do: Fx.jpeg(Keyword.merge([pad: n], opts))

  defp add(c, n \\ 0, extra \\ %{}, owner \\ nil) do
    attrs = Map.merge(%{purpose: "photo", original: img(n)}, extra)
    Attachments.add(c.prefix, owner || c.owner, attrs, c.ctx)
  end

  defp add!(c, n, extra \\ %{}, owner \\ nil) do
    {:ok, link, :created} = add(c, n, extra, owner)
    link
  end

  defp audits(c), do: Repo.all(from(e in Entry, order_by: e.timestamp), prefix: c.prefix)
  defp blob_count(c), do: Repo.aggregate(Blob, :count, prefix: c.prefix)
  defp link_count(c), do: Repo.aggregate(Link, :count, prefix: c.prefix)

  defp lock!(c, link) do
    Repo.update_all(
      from(l in Link, where: l.id == ^link.id),
      [set: [locked_at: DateTime.utc_now()]],
      prefix: c.prefix
    )
  end

  describe "add, list, get, content" do
    test "S-ADD1/S-ADD2/S-LIST positions, main flag, ordered list without bytes", c do
      one = add!(c, 1)
      two = add!(c, 2)
      assert {one.position, one.is_main} == {1, true}
      assert {two.position, two.is_main} == {2, false}
      assert one.uploaded_by == c.actor and one.tenant_id == c.fx.tenant_id

      assert [%Link{id: a}, %Link{id: b}] = Attachments.list(c.prefix, c.owner, "photo")
      assert {a, b} == {one.id, two.id}
      refute Map.has_key?(hd(Attachments.list(c.prefix, c.owner, "photo")), :bytes)
      assert Attachments.list(c.prefix, c.owner, "evidence") == []
    end

    test "S-GET/S-CONTENT original, thumbnail, missing thumbnail", c do
      thumb = Fx.png(width: 4, height: 4)
      with_thumb = add!(c, 1, %{thumbnail: thumb})
      without = add!(c, 2)

      assert {:ok, %Link{id: id}} = Attachments.get(c.prefix, c.owner, with_thumb.id)
      assert id == with_thumb.id

      assert {:ok, %{content_type: "image/jpeg", bytes: bytes, byte_size: n, sha256: sha}} =
               Attachments.content(c.prefix, c.owner, with_thumb.id, :original)

      assert byte_size(bytes) == n
      assert sha == :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert {:ok, %{content_type: "image/png", bytes: tb}} =
               Attachments.content(c.prefix, c.owner, with_thumb.id, :thumbnail)

      assert tb == thumb
      assert {:error, :not_found} = Attachments.content(c.prefix, c.owner, without.id, :thumbnail)
    end

    test "S-STRIP the stored bytes carry no EXIF or GPS", c do
      link = add!(c, 0, %{original: Fx.jpeg(meta: [:exif, :xmp, :com, :after_eoi])})
      {:ok, %{bytes: stored}} = Attachments.content(c.prefix, c.owner, link.id, :original)
      refute stored =~ @sentinel
      refute stored =~ "Exif"
    end
  end

  describe "scanner" do
    test "S-SCAN1 the scanner sees the stripped bytes, not the upload", c do
      put_scanner!(Recorder)
      Process.register(self(), :t2040_scan_recorder)
      upload = Fx.jpeg(meta: [:exif, :com])
      add!(c, 0, %{original: upload})
      assert_receive {:scanned, seen}
      refute seen =~ @sentinel
      assert byte_size(seen) < byte_size(upload)
    end

    test "S-SCAN2 infected and a failing scanner store nothing", c do
      put_scanner!(Infected)
      assert {:error, :photo_infected} = add(c)
      put_scanner!(Down)
      assert {:error, :scan_unavailable} = add(c)
      assert {blob_count(c), link_count(c), audits(c)} == {0, 0, []}
    end
  end

  describe "delete, reorder, main, caption" do
    test "S-DEL1 delete compacts positions and promotes the next main", c do
      [a, b, d] = for n <- 1..3, do: add!(c, n)
      assert {:ok, %Link{}} = Attachments.delete(c.prefix, c.owner, a.id, c.ctx, false)

      assert [%{id: bid, position: 1, is_main: true}, %{id: did, position: 2, is_main: false}] =
               Attachments.list(c.prefix, c.owner, "photo")

      assert {bid, did} == {b.id, d.id}
      assert blob_count(c) == 2
    end

    test "S-DEL2 own photo deletable, another user's needs may_delete_any?", c do
      link = add!(c, 1)
      other = %{c.ctx | actor_id: Ecto.UUID.generate()}
      assert {:error, :forbidden} = Attachments.delete(c.prefix, c.owner, link.id, other, false)
      assert {:ok, _} = Attachments.delete(c.prefix, c.owner, link.id, other, true)

      mine = add!(c, 2)
      assert {:ok, _} = Attachments.delete(c.prefix, c.owner, mine.id, c.ctx, false)
      assert link_count(c) == 0
    end

    test "S-REORD a permutation is applied, bad sets are :invalid_order", c do
      [a, b, d] = for n <- 1..3, do: add!(c, n)

      assert {:ok, [x, y, z]} =
               Attachments.reorder(c.prefix, c.owner, "photo", [d.id, a.id, b.id], c.ctx)

      assert [{x.id, 1}, {y.id, 2}, {z.id, 3}] == [{d.id, 1}, {a.id, 2}, {b.id, 3}]

      for bad <- [
            [a.id],
            [a.id, a.id, b.id],
            [a.id, b.id, Ecto.UUID.generate()],
            [a.id, b.id, d.id, d.id]
          ] do
        assert {:error, :invalid_order} =
                 Attachments.reorder(c.prefix, c.owner, "photo", bad, c.ctx)
      end

      changed = Enum.filter(audits(c), &(&1.action == "attachment.changed"))
      assert length(changed) == 3
    end

    test "S-MAIN the main flag moves and both changes are audited", c do
      a = add!(c, 1)
      b = add!(c, 2)
      assert {:ok, %Link{is_main: true}} = Attachments.set_main(c.prefix, c.owner, b.id, c.ctx)
      assert [%{is_main: false}, %{is_main: true}] = Attachments.list(c.prefix, c.owner, "photo")
      assert {:ok, %Link{}} = Attachments.set_main(c.prefix, c.owner, b.id, c.ctx)
      before = length(audits(c))
      assert {:ok, _} = Attachments.set_main(c.prefix, c.owner, a.id, c.ctx)
      assert length(audits(c)) == before + 2
    end

    test "S-CAP captions: set, clear, 200 code points pass, 201 and controls refused", c do
      link = add!(c, 1)

      assert {:ok, %Link{caption: "Front"}} =
               Attachments.set_caption(c.prefix, c.owner, link.id, " Front ", c.ctx)

      assert {:ok, %Link{caption: nil}} =
               Attachments.set_caption(c.prefix, c.owner, link.id, "", c.ctx)

      ok = String.duplicate("a", 200)

      assert {:ok, %Link{caption: ^ok}} =
               Attachments.set_caption(c.prefix, c.owner, link.id, ok, c.ctx)

      for bad <- [String.duplicate("a", 201), "bad\ncaption", "nul\0", 42, %{}, <<0xFF, 0xFE>>] do
        assert {:error, :caption_invalid} =
                 Attachments.set_caption(c.prefix, c.owner, link.id, bad, c.ctx)

        assert {:error, :caption_invalid} = add(c, 9, %{caption: bad})
      end

      assert %Link{caption: "On add"} = add!(c, 5, %{caption: "On add"})
    end

    test "S-CAP-CP 40 family emoji (40 graphemes, 280 code points) are :caption_invalid, not :storage_failed",
         c do
      family = String.duplicate("👨‍👩‍👧‍👦", 40)
      assert {String.length(family), length(String.to_charlist(family))} == {40, 280}
      link = add!(c, 1)
      assert {:error, :caption_invalid} = add(c, 2, %{caption: family})

      assert {:error, :caption_invalid} =
               Attachments.set_caption(c.prefix, c.owner, link.id, family, c.ctx)

      assert link_count(c) == 1
    end

    test "S-DUPTH thumbnail identical to the original: delete removes the one blob", c do
      bytes = img(3)
      link = add!(c, 3, %{original: bytes, thumbnail: bytes})
      assert blob_count(c) == 1
      assert {:ok, _} = Attachments.delete(c.prefix, c.owner, link.id, c.ctx, false)
      assert {blob_count(c), link_count(c)} == {0, 0}
    end

    test "S-LOCK a locked link refuses delete, reorder, set_main and set_caption", c do
      a = add!(c, 1)
      b = add!(c, 2)
      lock!(c, b)

      assert {:error, :photo_locked} = Attachments.delete(c.prefix, c.owner, b.id, c.ctx, true)

      assert {:error, :photo_locked} =
               Attachments.reorder(c.prefix, c.owner, "photo", [b.id, a.id], c.ctx)

      assert {:error, :photo_locked} = Attachments.set_main(c.prefix, c.owner, b.id, c.ctx)

      assert {:error, :photo_locked} =
               Attachments.set_caption(c.prefix, c.owner, b.id, "x", c.ctx)

      assert link_count(c) == 2
    end
  end

  describe "caps and registry" do
    test "S-REG unknown owner kind and purpose are refused", c do
      assert {:error, :owner_kind_not_registered} =
               Attachments.add(
                 c.prefix,
                 %{kind: "catalog_item", id: c.owner.id},
                 %{purpose: "photo", original: img()},
                 c.ctx
               )

      assert {:error, :purpose_not_allowed} = add(c, 0, %{purpose: "evidence"})
      assert {:error, :purpose_not_allowed} = add(c, 0, %{purpose: nil})
      assert {:error, :photo_malformed} = add(c, 0, %{original: nil})
      assert {:error, :photo_type_not_allowed} = add(c, 0, %{original: "GIF89a....."})
      assert link_count(c) == 0
    end

    test "S-OWN the 11th photo of an owner is :owner_cap_reached", c do
      for n <- 1..10, do: add!(c, n)
      assert {:error, :owner_cap_reached} = add(c, 11)
      assert link_count(c) == 10
    end

    test "S-RATE 60 links of the actor in the last hour block the next add; older ones do not count",
         c do
      first = add!(c, 1)
      blob_id = first.blob_id
      now = DateTime.utc_now()

      rows = fn age_seconds, count ->
        for _ <- 1..count do
          %{
            id: Ecto.UUID.bingenerate(),
            tenant_id: Ecto.UUID.dump!(c.fx.tenant_id),
            owner_kind: "other_owner",
            owner_id: Ecto.UUID.bingenerate(),
            purpose: "photo",
            position: 1,
            is_main: false,
            blob_id: Ecto.UUID.dump!(blob_id),
            uploaded_by: Ecto.UUID.dump!(c.actor),
            inserted_at: DateTime.add(now, -age_seconds, :second),
            updated_at: now
          }
        end
      end

      Repo.insert_all("attachment_links", rows.(7200, 59), prefix: c.prefix)
      assert {:ok, _, :created} = add(c, 2)

      Repo.insert_all("attachment_links", rows.(60, 58), prefix: c.prefix)
      assert {:error, :upload_rate_exceeded} = add(c, 3)
    end

    test "S-REPLAY the same bytes twice give one link and one audit entry", c do
      assert {:ok, link, :created} = add(c, 1)
      assert {:ok, again, :replayed} = add(c, 1)
      assert again.id == link.id
      assert {link_count(c), length(audits(c))} == {1, 1}
    end
  end

  describe "storage allowance" do
    defp allowance!(c, bytes) do
      Repo.update_all(
        from(t in Letflow.Identity.Tenant, where: t.id == ^c.fx.tenant_id),
        set: [storage_allowance_bytes: bytes]
      )
    end

    test "S-Q1/S-Q3 usage counts blob bytes once and drops after the last delete", c do
      other = %{kind: "assets_card", id: Ecto.UUID.generate()}
      a = add!(c, 1)
      b = add!(c, 1, %{}, other)
      assert a.blob_id == b.blob_id

      {:ok, %{byte_size: size}} = Attachments.content(c.prefix, c.owner, a.id, :original)
      assert {:ok, ^size} = RepoAttachments.get_storage_usage(prefix: c.prefix)

      assert {:ok, _} = Attachments.delete(c.prefix, c.owner, a.id, c.ctx, false)
      assert {:ok, ^size} = RepoAttachments.get_storage_usage(prefix: c.prefix)
      assert {:ok, _} = Attachments.delete(c.prefix, other, b.id, c.ctx, false)
      assert {:ok, 0} = RepoAttachments.get_storage_usage(prefix: c.prefix)
    end

    test "S-Q2 an add over the allowance is refused and writes nothing", c do
      allowance!(c, 100)
      assert {:error, :storage_quota_exceeded} = add(c, 1)
      assert {blob_count(c), link_count(c), audits(c)} == {0, 0, []}
    end
  end

  describe "audit" do
    test "S-AU1 one entry per change with the exact key set, no bytes, no caption", c do
      link = add!(c, 1, %{caption: "Secret caption text"})
      {:ok, _} = Attachments.set_caption(c.prefix, c.owner, link.id, "Other secret text", c.ctx)
      {:ok, _} = Attachments.delete(c.prefix, c.owner, link.id, c.ctx, false)

      assert [added, changed, removed] = audits(c)

      assert {added.action, changed.action, removed.action} ==
               {"attachment.added", "attachment.changed", "attachment.removed"}

      keys = ~w(byte_size content_type link_id owner_id owner_kind purpose sha256)
      assert added.after_state |> Map.keys() |> Enum.sort() == keys
      assert changed.after_state |> Map.keys() |> Enum.sort() == Enum.sort(["changed" | keys])

      assert changed.after_state["changed"] == ["caption"]
      assert removed.before_state["link_id"] == link.id and removed.after_state == nil
      assert added.resource_id == link.id and added.actor_id == c.actor
      assert added.trace_id == "trace-t2040"

      everything = inspect(audits(c), limit: :infinity, printable_limit: :infinity)
      refute everything =~ "Secret caption"
      refute everything =~ "Other secret"
    end

    test "S-AU2 a failing audit write rolls the change back as :audit_failed", c do
      keep = add!(c, 1)
      Repo.query!(~s(DROP TABLE "#{c.prefix}".audit_entries CASCADE))

      assert {:error, :audit_failed} = add(c, 2)

      assert {:error, :audit_failed} =
               Attachments.delete(c.prefix, c.owner, keep.id, c.ctx, false)

      assert {link_count(c), blob_count(c)} == {1, 1}
    end

    test "S-AU3 refusals write nothing and emit telemetry", c do
      id = "t2040-refused-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        id,
        [:letflow, :attachments, :refused],
        fn _e, m, meta, _ -> send(test_pid, {:refused, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:error, :purpose_not_allowed} = add(c, 1, %{purpose: "evidence"})

      assert_receive {:refused, %{count: 1},
                      %{reason: :purpose_not_allowed, owner_kind: "assets_card"}}

      assert audits(c) == []
    end
  end

  describe "isolation and malformed input" do
    test "S-ISO another tenant's prefix finds nothing and is unaffected", c do
      link = add!(c, 1)
      other = TenantFixture.provisioned_tenant!(slug_prefix: "t2040b")
      p = other.schema_name

      assert {:error, :not_found} = Attachments.get(p, c.owner, link.id)
      assert {:error, :not_found} = Attachments.content(p, c.owner, link.id, :original)
      assert {:error, :not_found} = Attachments.delete(p, c.owner, link.id, c.ctx, true)
      assert {:error, :not_found} = Attachments.set_caption(p, c.owner, link.id, "x", c.ctx)
      assert {:ok, 0} = RepoAttachments.get_storage_usage(prefix: p)
      assert link_count(c) == 1
    end

    test "S-OWNER a link asked as another owner of the same tenant is :not_found", c do
      link = add!(c, 1)
      y = %{kind: "assets_card", id: Ecto.UUID.generate()}
      assert {:error, :not_found} = Attachments.get(c.prefix, y, link.id)
      assert {:error, :not_found} = Attachments.delete(c.prefix, y, link.id, c.ctx, true)
      assert {:error, :not_found} = Attachments.set_main(c.prefix, y, link.id, c.ctx)

      assert {:error, :not_found} =
               Attachments.get(c.prefix, %{c.owner | kind: "catalog_item"}, link.id)
    end

    test "S-SHARE the same bytes on two owners share a blob until both links are gone", c do
      other = %{kind: "assets_card", id: Ecto.UUID.generate()}
      a = add!(c, 1)
      b = add!(c, 1, %{}, other)
      assert blob_count(c) == 1
      {:ok, _} = Attachments.delete(c.prefix, c.owner, a.id, c.ctx, false)
      assert blob_count(c) == 1
      {:ok, _} = Attachments.delete(c.prefix, other, b.id, c.ctx, false)
      assert blob_count(c) == 0
    end

    test "S-UUID malformed ids never raise", c do
      link = add!(c, 1)
      other = add!(c, 2)

      for bad <- ["abc", nil, 12, "../x", ""] do
        assert {:error, :not_found} = Attachments.get(c.prefix, c.owner, bad)
        assert {:error, :not_found} = Attachments.content(c.prefix, c.owner, bad, :original)
        assert {:error, :not_found} = Attachments.delete(c.prefix, c.owner, bad, c.ctx, true)
        assert {:error, :not_found} = Attachments.set_main(c.prefix, c.owner, bad, c.ctx)
        assert {:error, :not_found} = Attachments.set_caption(c.prefix, c.owner, bad, "x", c.ctx)

        assert {:error, :invalid_order} =
                 Attachments.reorder(c.prefix, c.owner, "photo", [link.id, bad], c.ctx)

        bad_owner = %{kind: "assets_card", id: bad}

        assert {:error, :owner_invalid} =
                 Attachments.add(
                   c.prefix,
                   bad_owner,
                   %{purpose: "photo", original: img(7)},
                   c.ctx
                 )

        assert [] = Attachments.list(c.prefix, bad_owner, "photo")
        assert {:error, :not_found} = Attachments.get(c.prefix, bad_owner, link.id)

        bad_ctx = %{c.ctx | actor_id: bad}

        assert {:error, :actor_invalid} =
                 Attachments.add(
                   c.prefix,
                   c.owner,
                   %{purpose: "photo", original: img(7)},
                   bad_ctx
                 )

        assert {:error, :actor_invalid} =
                 Attachments.delete(c.prefix, c.owner, link.id, bad_ctx, true)
      end

      assert {:error, :invalid_order} =
               Attachments.reorder(c.prefix, c.owner, "photo", "nope", c.ctx)

      assert {:error, :owner_kind_not_registered} =
               Attachments.add(c.prefix, nil, %{purpose: "photo"}, c.ctx)

      upper = String.upcase(other.id)
      assert {:ok, %Link{id: id}} = Attachments.get(c.prefix, c.owner, upper)
      assert id == other.id
      assert {link_count(c), length(audits(c))} == {2, 2}
    end
  end
end
