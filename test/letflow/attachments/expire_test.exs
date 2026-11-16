defmodule Letflow.Attachments.ExpireTest do
  @moduledoc "T-2043 E1-E6: retained attachment expiry on a real committed tenant."
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Attachments
  alias Letflow.Attachments.{Blob, Link}
  alias Letflow.AttachmentsImageFixture, as: Fx
  alias Letflow.Audit.Entry
  alias Letflow.{Repo, TenantFixture}

  setup do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2043-exp")
    actor = Ecto.UUID.generate()

    %{
      fx: fx,
      prefix: fx.schema_name,
      owner: %{kind: "problem_report", id: Ecto.UUID.generate()},
      ctx: %{actor_id: actor, trace_id: "trace-t2043-expiry"}
    }
  end

  defp screenshot!(c, n, owner \\ nil) do
    {:ok, link, :created} =
      Attachments.add(
        c.prefix,
        owner || c.owner,
        %{purpose: "screenshot", original: Fx.png(pad: n)},
        c.ctx
      )

    link
  end

  defp retain!(c, link, at) do
    Repo.update_all(
      from(l in Link, where: l.id == ^link.id),
      [set: [retain_until: at]],
      prefix: c.prefix
    )
  end

  defp links(c), do: Repo.all(from(l in Link, order_by: l.position), prefix: c.prefix)
  defp blobs(c), do: Repo.all(from(b in Blob, select: b), prefix: c.prefix)

  defp expiry_audits(c) do
    Repo.all(from(e in Entry, where: e.action == "attachment.expired"), prefix: c.prefix)
  end

  test "E1 expiry deletes the old link and blob and keeps the later one", c do
    now = DateTime.utc_now()
    other = %{kind: "problem_report", id: Ecto.UUID.generate()}
    old = screenshot!(c, 1)
    later = screenshot!(c, 2, other)
    retain!(c, old, DateTime.add(now, -1, :second))
    retain!(c, later, DateTime.add(now, 86_400, :second))

    assert {:ok, 1} = Attachments.expire(c.prefix, now: now)
    assert [%{id: id}] = links(c)
    assert id == later.id
    assert [%{id: blob_id}] = blobs(c)
    assert blob_id == later.blob_id
  end

  test "E2 a blob shared with an unexpired link is kept", c do
    now = DateTime.utc_now()
    other = %{kind: "problem_report", id: Ecto.UUID.generate()}
    bytes = Fx.png(pad: 3)

    {:ok, old, :created} =
      Attachments.add(c.prefix, c.owner, %{purpose: "screenshot", original: bytes}, c.ctx)

    {:ok, kept, :created} =
      Attachments.add(c.prefix, other, %{purpose: "screenshot", original: bytes}, c.ctx)

    assert old.blob_id == kept.blob_id
    retain!(c, old, DateTime.add(now, -1, :second))
    retain!(c, kept, DateTime.add(now, 86_400, :second))

    assert {:ok, 1} = Attachments.expire(c.prefix, now: now)
    assert [%{id: blob_id}] = blobs(c)
    assert blob_id == kept.blob_id

    assert {:ok, %{bytes: stored}} =
             Attachments.content(c.prefix, other, kept.id, :original)

    assert stored == bytes
  end

  test "E3 a locked link never expires", c do
    now = DateTime.utc_now()
    locked = screenshot!(c, 4)
    retain!(c, locked, DateTime.add(now, -1, :second))

    Repo.update_all(
      from(l in Link, where: l.id == ^locked.id),
      [set: [locked_at: now]],
      prefix: c.prefix
    )

    assert {:ok, 0} = Attachments.expire(c.prefix, now: now)
    assert [%{id: id}] = links(c)
    assert id == locked.id
    assert length(blobs(c)) == 1
  end

  test "E4 one aggregate audit per non-empty run and none for an empty run", c do
    now = DateTime.utc_now()
    old = screenshot!(c, 5)
    retain!(c, old, DateTime.add(now, -1, :second))

    assert {:ok, 1} = Attachments.expire(c.prefix, now: now)
    assert [entry] = expiry_audits(c)
    assert entry.actor_id == nil
    assert entry.resource_type == "attachment"
    assert entry.resource_id == "expiry"
    assert entry.after_state["count"] == 1
    assert entry.after_state["by_owner_kind"] == %{"problem_report" => 1}
    assert entry.after_state["retain_cutoff"] == DateTime.to_iso8601(now)

    assert {:ok, 0} = Attachments.expire(c.prefix, now: now)
    assert length(expiry_audits(c)) == 1
  end

  test "E5 the remaining links are renumbered from one", c do
    now = DateTime.utc_now()
    first = screenshot!(c, 6)
    second = screenshot!(c, 7)
    third = screenshot!(c, 8)
    retain!(c, first, DateTime.add(now, -1, :second))
    retain!(c, second, DateTime.add(now, 86_400, :second))
    retain!(c, third, DateTime.add(now, 86_400, :second))

    assert {:ok, 1} = Attachments.expire(c.prefix, now: now)

    assert Enum.map(links(c), &{&1.id, &1.position}) == [
             {second.id, 1},
             {third.id, 2}
           ]
  end

  test "E6 an owner purpose without retain_days keeps retain_until nil", c do
    owner = %{kind: "assets_card", id: Ecto.UUID.generate()}

    {:ok, link, :created} =
      Attachments.add(
        c.prefix,
        owner,
        %{purpose: "photo", original: Fx.jpeg()},
        c.ctx
      )

    assert link.retain_until == nil
    assert {:ok, 0} = Attachments.expire(c.prefix, now: DateTime.add(now(), 365 * 86_400))
    assert [%{id: id}] = links(c)
    assert id == link.id
  end

  defp now, do: DateTime.utc_now()
end
