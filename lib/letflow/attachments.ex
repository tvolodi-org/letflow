defmodule Letflow.Attachments do
  @moduledoc """
  The one attachment service (T-2040, Photos P1; design `docs/design/photos.md` section 8). Photos,
  and later evidence photos, asset-store files and problem-report screenshots, are links from an
  owner (kind + id) to a deduplicated, really deletable blob in the tenant's own schema.

  P1 had no route, permission atom or screen: the caller decides who may read or write; this module
  decides the owner-relative facts a caller must not get wrong (the owner filter on every link
  lookup, the own-unlocked-photo delete rule, lock refusals, caps). P2 (T-2041) exposes the asset
  card gallery through `Letflow.Modules.Assets.CardPhotos`, whose routes are keyed `AssetsRead` and
  whose writes check the core atoms `PhotosAdd` / `PhotosDelete`.

  ## Decisions

    * **Bytes are checked and stripped here** (`Letflow.Attachments.Image`): the type is decided by the
      first bytes, the structure is walked once, EXIF/GPS/XMP/text metadata is removed by allowlist,
      and the scanner runs on the stripped bytes. A declared content type is not an input.
    * **Ids are cast first** (`Ecto.UUID.cast/1`, never raises): a malformed id gives the same answer
      as an unknown one (`:not_found`; `:invalid_order` in a reorder list; `:owner_invalid` /
      `:actor_invalid` where a refusal is needed). INV-5, INV-8.
    * **One advisory transaction lock per owner** serialises cap, position and main-flag changes.
      Postgres arbitrates; there is no process per owner (REQ-045). The lock key is a bound parameter.
    * **Blob deletion** happens in `delete/5` and `expire/2` only when no other link uses the blob
      (`BlobStore.release/2`; `ON DELETE RESTRICT` is the backstop).
    * **Audit**: one entry per change in the owner's schema, in the same transaction, with no bytes
      and no caption text. A failing audit write rolls the change back as `{:error, :audit_failed}`.
      Refusals write nothing and emit `[:letflow, :attachments, :refused]` telemetry.
    * **Retries** are safe by content: the same stripped bytes on the same owner and purpose return
      the existing link (`:replayed`), without a write or an audit entry.
    * **Caps** are module attributes (`limits/0`); the quota check counts the full new bytes and is not
      serialised across owners, so concurrent uploads can overshoot the allowance by their own size.
    * `locked_at` is set in slice P6. `retain_until` is set from the owner's optional `retain_days`
      rule; `expire/2` (T-2043, P5) deletes expired, unlocked links and their unshared blobs.
  """

  import Ecto.Query

  alias Letflow.Attachments.{Blob, Image, Link, Owners}
  alias Letflow.{Audit, Repo, TenantProvisioning}
  alias Letflow.Repository.Attachments, as: RepoAttachments

  @blob_store Letflow.Attachments.BlobStore.Postgres
  @uploads_per_hour 60
  @caption_max 200
  @caption_max_bytes 4 * @caption_max + 1024

  @type owner :: %{kind: String.t(), id: Ecto.UUID.t()}
  @type ctx :: %{actor_id: Ecto.UUID.t(), trace_id: String.t() | nil}

  @doc "The caps in force (starting values, photos.md 5.4)."
  @spec limits() :: map()
  def limits do
    %{
      original: Image.caps(:original),
      thumbnail: Image.caps(:thumbnail),
      uploads_per_user_per_hour: @uploads_per_hour,
      caption_max_code_points: @caption_max
    }
  end

  # ---------------------------------------------------------------------------
  # add
  # ---------------------------------------------------------------------------

  @doc """
  Adds one attachment. `attrs`: `%{purpose, original, thumbnail \\\\ nil, caption \\\\ nil}`.

  Returns `{:ok, link, :created | :replayed}` or `{:error, reason}`; the reasons are
  `:owner_kind_not_registered`, `:owner_invalid`, `:actor_invalid`, `:purpose_not_allowed`,
  `:caption_invalid`, `:photo_too_large`, `:photo_type_not_allowed`, `:photo_malformed`,
  `:photo_infected`, `:scan_unavailable`, `:owner_cap_reached`, `:upload_rate_exceeded`,
  `:storage_quota_exceeded`, `:tenant_not_found`, `:audit_failed`, `:storage_failed`.
  """
  @spec add(String.t(), owner(), map(), ctx()) ::
          {:ok, %Link{}, :created | :replayed} | {:error, atom()}
  def add(prefix, owner, attrs, ctx) when is_binary(prefix) do
    purpose = attr(attrs, :purpose)

    owner
    |> do_add(prefix, attrs, purpose, ctx)
    |> track(owner_kind(owner), purpose)
  end

  defp do_add(owner, prefix, attrs, purpose, ctx) do
    with {:ok, kind, entry} <- registered(owner),
         {:ok, owner_id} <- cast_owner_id(owner),
         {:ok, actor} <- cast_actor(ctx),
         # Rate check runs before the expensive Image.check and virus scan so a throttled
         # uploader does not pay the parse and scan cost (T-2133).
         :ok <- check_rate(prefix, actor),
         {:ok, rules} <- purpose_rules(entry, purpose),
         {:ok, caption} <- normalize_caption(attr(attrs, :caption)),
         {:ok, original} <- Image.check(attr(attrs, :original), :original),
         {:ok, thumb} <- check_thumbnail(attr(attrs, :thumbnail)),
         :ok <- scan(original),
         :ok <- scan(thumb),
         {:ok, tenant_id} <- tenant_id(prefix) do
      ref = %{prefix: prefix, tenant_id: tenant_id, kind: kind, id: owner_id, purpose: purpose}
      insert_link(ref, rules, original, thumb, caption, actor, ctx)
    end
  end

  defp check_thumbnail(nil), do: {:ok, nil}
  defp check_thumbnail(bytes), do: Image.check(bytes, :thumbnail)

  defp scan(nil), do: :ok

  defp scan(%{bytes: bytes, content_type: type}) do
    case RepoAttachments.scan_content(bytes, type) do
      {:ok, :clean} -> :ok
      {:ok, :infected, _verdict} -> {:error, :photo_infected}
      _ -> {:error, :scan_unavailable}
    end
  end

  defp tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :tenant_not_found}
    end
  end

  defp insert_link(ref, rules, original, thumb, caption, actor, ctx) do
    sha = sha256(original.bytes)

    result =
      Repo.transaction(fn ->
        lock_owner!(ref)

        with :ok <- no_replay(ref, sha),
             :ok <- check_cap(ref, rules),
             :ok <- check_quota(ref.prefix, original, thumb) do
          blob_id = put_blob!(ref, original, sha)
          thumb_blob_id = thumb && put_blob!(ref, thumb, sha256(thumb.bytes))
          link = insert_link!(ref, rules, blob_id, thumb_blob_id, caption, actor)
          record_upload_event!(ref.prefix, actor)

          state =
            state_of(link, %{
              sha: sha,
              size: byte_size(original.bytes),
              type: original.content_type
            })

          audit!(ref.prefix, ctx, actor, "attachment.added", link, nil, state)
          {:created, link}
        else
          {:replay, link} -> {:replayed, link}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {tag, link}} -> {:ok, link, tag}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      log_storage_failure(e)
      {:error, :storage_failed}
  end

  defp no_replay(ref, sha) do
    query =
      from(l in Link,
        join: b in Blob,
        on: b.id == l.blob_id,
        where:
          l.owner_kind == ^ref.kind and l.owner_id == ^ref.id and l.purpose == ^ref.purpose and
            b.sha256 == ^sha,
        select: l,
        limit: 1
      )

    case Repo.one(query, prefix: ref.prefix) do
      nil -> :ok
      link -> {:replay, link}
    end
  end

  defp check_rate(prefix, actor) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)
    {:ok, actor_bin} = Ecto.UUID.dump(actor)

    count =
      Repo.aggregate(
        from(e in "upload_events", where: e.actor_id == ^actor_bin and e.inserted_at > ^cutoff),
        :count,
        prefix: prefix
      )

    if count >= @uploads_per_hour, do: {:error, :upload_rate_exceeded}, else: :ok
  end

  # Records one upload event per successful link creation. The event survives link deletion,
  # so the rolling-hour count is deletion-proof (T-2133).
  defp record_upload_event!(prefix, actor) do
    {:ok, actor_bin} = Ecto.UUID.dump(actor)
    {:ok, id_bin} = Ecto.UUID.dump(Ecto.UUID.generate())

    Repo.insert_all(
      "upload_events",
      [%{id: id_bin, actor_id: actor_bin, inserted_at: DateTime.utc_now()}],
      prefix: prefix
    )
  end

  defp check_cap(ref, rules) do
    count = Repo.aggregate(owner_purpose_query(ref), :count, prefix: ref.prefix)
    if count >= rules.max, do: {:error, :owner_cap_reached}, else: :ok
  end

  defp check_quota(prefix, original, thumb) do
    new_bytes = byte_size(original.bytes) + if(thumb, do: byte_size(thumb.bytes), else: 0)

    case RepoAttachments.storage_summary(prefix: prefix) do
      {:ok, %{used_bytes: used, allowance_bytes: allowance}} ->
        if used + new_bytes > allowance, do: {:error, :storage_quota_exceeded}, else: :ok

      {:error, _} ->
        {:error, :tenant_not_found}
    end
  end

  defp put_blob!(ref, image, sha) do
    {:ok, id} =
      @blob_store.put(ref.prefix, ref.tenant_id, %{
        sha256: sha,
        content_type: image.content_type,
        byte_size: byte_size(image.bytes),
        width: image.width,
        height: image.height,
        bytes: image.bytes
      })

    id
  end

  defp insert_link!(ref, rules, blob_id, thumb_blob_id, caption, actor) do
    max_position =
      Repo.one(
        from(l in Link,
          where:
            l.owner_kind == ^ref.kind and l.owner_id == ^ref.id and l.purpose == ^ref.purpose,
          select: max(l.position)
        ),
        prefix: ref.prefix
      ) || 0

    has_main? =
      Repo.exists?(from(l in owner_purpose_query(ref), where: l.is_main), prefix: ref.prefix)

    now = DateTime.utc_now()

    Repo.insert!(
      %Link{
        tenant_id: ref.tenant_id,
        owner_kind: ref.kind,
        owner_id: ref.id,
        purpose: ref.purpose,
        position: max_position + 1,
        is_main: rules.main and not has_main?,
        caption: caption,
        blob_id: blob_id,
        thumb_blob_id: thumb_blob_id,
        uploaded_by: actor,
        inserted_at: now,
        updated_at: now,
        retain_until: retain_until(rules, now)
      },
      prefix: ref.prefix
    )
  end

  defp retain_until(rules, now) do
    case Map.get(rules, :retain_days) do
      days when is_integer(days) and days > 0 -> DateTime.add(now, days * 86_400, :second)
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # reads
  # ---------------------------------------------------------------------------

  @doc "Links of one owner and purpose in position order (no bytes). An unusable owner gives `[]`."
  @spec list(String.t(), owner(), String.t()) :: [%Link{}]
  def list(prefix, owner, purpose) when is_binary(prefix) do
    with {:ok, kind, id} <- read_owner(owner),
         true <- is_binary(purpose) do
      Repo.all(
        from(l in Link,
          where: l.owner_kind == ^kind and l.owner_id == ^id and l.purpose == ^purpose,
          order_by: [asc: l.position]
        ),
        prefix: prefix
      )
    else
      _ -> []
    end
  end

  @doc """
  Summary maps of one owner's links, including the blob's content type and byte size but no bytes.
  An unusable owner gives `[]`.
  """
  @spec list_summaries(String.t(), owner(), String.t()) :: [map()]
  def list_summaries(prefix, owner, purpose) when is_binary(prefix) do
    with {:ok, kind, id} <- read_owner(owner),
         true <- is_binary(purpose) do
      Repo.all(
        from(l in Link,
          join: b in Blob,
          on: b.id == l.blob_id,
          where: l.owner_kind == ^kind and l.owner_id == ^id and l.purpose == ^purpose,
          order_by: [asc: l.position],
          select: %{
            id: l.id,
            position: l.position,
            content_type: b.content_type,
            byte_size: b.byte_size,
            is_main: l.is_main,
            caption: l.caption,
            has_thumbnail: not is_nil(l.thumb_blob_id)
          }
        ),
        prefix: prefix
      )
    else
      _ -> []
    end
  end

  @spec get(String.t(), owner(), term()) :: {:ok, %Link{}} | {:error, :not_found}
  def get(prefix, owner, link_id) when is_binary(prefix) do
    with {:ok, kind, id} <- read_owner(owner),
         {:ok, link_id} <- cast_uuid(link_id),
         %Link{} = link <- Repo.one(link_query(kind, id, link_id), prefix: prefix) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The stored (stripped) bytes of the original or the thumbnail, with the stored content type."
  @spec content(String.t(), owner(), term(), :original | :thumbnail) ::
          {:ok,
           %{content_type: String.t(), bytes: binary(), sha256: String.t(), byte_size: integer()}}
          | {:error, :not_found}
  def content(prefix, owner, link_id, which)
      when is_binary(prefix) and which in [:original, :thumbnail] do
    with {:ok, kind, id} <- read_owner(owner),
         {:ok, link_id} <- cast_uuid(link_id),
         %Link{} = link <- Repo.one(link_query(kind, id, link_id), prefix: prefix),
         blob_id when not is_nil(blob_id) <- blob_of(link, which),
         %{} = blob <-
           Repo.one(
             from(b in Blob,
               where: b.id == ^blob_id,
               select: %{
                 content_type: b.content_type,
                 bytes: b.bytes,
                 sha256: b.sha256,
                 byte_size: b.byte_size
               }
             ),
             prefix: prefix
           ) do
      {:ok, blob}
    else
      _ -> {:error, :not_found}
    end
  end

  defp blob_of(link, :original), do: link.blob_id
  defp blob_of(link, :thumbnail), do: link.thumb_blob_id

  # ---------------------------------------------------------------------------
  # mutations on an existing link
  # ---------------------------------------------------------------------------

  @doc """
  Deletes a link, compacts the positions, promotes the next link to main when the main one went, and
  deletes the blob(s) no other link uses. `may_delete_any?` is the caller's verdict; without it only
  the uploader may delete.
  """
  @spec delete(String.t(), owner(), term(), ctx(), boolean()) ::
          {:ok, %Link{}}
          | {:error, :not_found | :photo_locked | :forbidden | :audit_failed | atom()}
  def delete(prefix, owner, link_id, ctx, may_delete_any?) when is_binary(prefix) do
    mutate(prefix, owner, link_id, ctx, fn link, ref, actor ->
      cond do
        link.locked_at != nil ->
          {:error, :photo_locked}

        not (may_delete_any? == true or link.uploaded_by == actor) ->
          {:error, :forbidden}

        true ->
          do_delete(link, ref, ctx, actor)
      end
    end)
  end

  defp do_delete(link, ref, ctx, actor) do
    meta = blob_meta(ref.prefix, link)
    Repo.delete!(link, prefix: ref.prefix)

    Repo.update_all(
      from(l in owner_purpose_query(%{ref | purpose: link.purpose}),
        where: l.position > ^link.position
      ),
      [inc: [position: -1]],
      prefix: ref.prefix
    )

    promoted =
      if link.is_main, do: promote_first!(ref, link.purpose), else: nil

    [link.blob_id, link.thumb_blob_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&@blob_store.release(ref.prefix, &1))

    audit!(ref.prefix, ctx, actor, "attachment.removed", link, state_of(link, meta), nil)

    if promoted do
      audit_change!(ref.prefix, ctx, actor, promoted, ["is_main"])
    end

    {:ok, link}
  end

  defp promote_first!(ref, purpose) do
    query =
      from(l in owner_purpose_query(%{ref | purpose: purpose}),
        where: l.position == 1,
        lock: "FOR UPDATE"
      )

    case Repo.one(query, prefix: ref.prefix) do
      nil ->
        nil

      first ->
        first |> Ecto.Changeset.change(is_main: true) |> Repo.update!(prefix: ref.prefix)
    end
  end

  @doc """
  Sets the order of one owner's links of one purpose. `link_ids` must be exactly the set of the
  owner's link ids of that purpose.
  """
  @spec reorder(String.t(), owner(), String.t(), [term()], ctx()) ::
          {:ok, [%Link{}]} | {:error, :invalid_order | :photo_locked | :audit_failed | atom()}
  def reorder(prefix, owner, purpose, link_ids, ctx) when is_binary(prefix) do
    with {:ok, kind, id} <- read_owner(owner),
         true <- is_binary(purpose) and is_list(link_ids),
         {:ok, ids} <- cast_all(link_ids),
         {:ok, actor} <- cast_actor(ctx) do
      ref = %{prefix: prefix, kind: kind, id: id, purpose: purpose}

      kind
      |> run_locked(ref, fn -> do_reorder(ref, ids, ctx, actor) end)
      |> track(kind, purpose)
    else
      {:error, :actor_invalid} = err -> err
      _ -> {:error, :invalid_order}
    end
  end

  defp do_reorder(ref, ids, ctx, actor) do
    links =
      Repo.all(from(l in owner_purpose_query(ref), order_by: l.position, lock: "FOR UPDATE"),
        prefix: ref.prefix
      )

    cond do
      Enum.sort(ids) != Enum.sort(Enum.map(links, & &1.id)) or ids != Enum.uniq(ids) ->
        Repo.rollback(:invalid_order)

      Enum.any?(links, &(&1.locked_at != nil)) ->
        Repo.rollback(:photo_locked)

      true ->
        apply_order!(ref, ids)
        reordered = list(ref.prefix, %{kind: ref.kind, id: ref.id}, ref.purpose)
        by_old = Map.new(links, &{&1.id, &1.position})

        for l <- reordered, by_old[l.id] != l.position do
          audit_change!(ref.prefix, ctx, actor, l, ["position"])
        end

        reordered
    end
  end

  defp apply_order!(_ref, []), do: :ok

  defp apply_order!(ref, ids) do
    now = DateTime.utc_now()

    # One statement: the deferrable position constraint is checked at its end, so a permutation
    # does not trip the unique key row by row.
    from(l in Link,
      join:
        v in fragment(
          "SELECT t.id, t.ord::smallint AS position FROM unnest(?) WITH ORDINALITY AS t(id, ord)",
          type(^ids, {:array, Ecto.UUID})
        ),
      on: v.id == l.id,
      where: l.owner_kind == ^ref.kind and l.owner_id == ^ref.id and l.purpose == ^ref.purpose,
      update: [set: [position: v.position, updated_at: ^now]]
    )
    |> Repo.update_all([], prefix: ref.prefix)
  end

  @spec set_main(String.t(), owner(), term(), ctx()) ::
          {:ok, %Link{}}
          | {:error, :not_found | :main_not_allowed | :photo_locked | :audit_failed | atom()}
  def set_main(prefix, owner, link_id, ctx) when is_binary(prefix) do
    mutate(prefix, owner, link_id, ctx, fn link, ref, actor ->
      cond do
        not main_allowed?(link) ->
          {:error, :main_not_allowed}

        link.locked_at != nil ->
          {:error, :photo_locked}

        link.is_main ->
          {:ok, link}

        true ->
          old =
            Repo.one(
              from(l in owner_purpose_query(%{ref | purpose: link.purpose}),
                where: l.is_main,
                lock: "FOR UPDATE"
              ),
              prefix: ref.prefix
            )

          if old do
            old
            |> Ecto.Changeset.change(is_main: false, updated_at: DateTime.utc_now())
            |> Repo.update!(prefix: ref.prefix)
          end

          new =
            link
            |> Ecto.Changeset.change(is_main: true, updated_at: DateTime.utc_now())
            |> Repo.update!(prefix: ref.prefix)

          if old, do: audit_change!(ref.prefix, ctx, actor, old, ["is_main"])
          audit_change!(ref.prefix, ctx, actor, new, ["is_main"])
          {:ok, new}
      end
    end)
  end

  defp main_allowed?(link) do
    with {:ok, entry} <- Owners.fetch(link.owner_kind),
         %{main: true} <- Map.get(entry.purposes, link.purpose) do
      true
    else
      _ -> false
    end
  end

  @spec set_caption(String.t(), owner(), term(), term(), ctx()) ::
          {:ok, %Link{}}
          | {:error, :not_found | :caption_invalid | :photo_locked | :audit_failed | atom()}
  def set_caption(prefix, owner, link_id, caption, ctx) when is_binary(prefix) do
    case normalize_caption(caption) do
      {:error, _} = err ->
        track(err, owner_kind(owner), nil)

      {:ok, caption} ->
        mutate(prefix, owner, link_id, ctx, fn link, ref, actor ->
          cond do
            link.locked_at != nil ->
              {:error, :photo_locked}

            link.caption == caption ->
              {:ok, link}

            true ->
              new =
                link
                |> Ecto.Changeset.change(caption: caption, updated_at: DateTime.utc_now())
                |> Repo.update!(prefix: ref.prefix)

              audit_change!(ref.prefix, ctx, actor, new, ["caption"])
              {:ok, new}
          end
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # retention
  # ---------------------------------------------------------------------------

  @doc """
  Deletes expired, unlocked links in one tenant schema, compacts positions and releases blobs that
  no remaining link uses. Options: `now:` (default the real clock) and `limit:` (default 500), the
  maximum number of distinct `(owner_kind, owner_id, purpose)` owners considered in this run.

  Returns `{:ok, deleted_link_count}`. One `attachment.expired` audit entry is written per non-empty
  run. Locked links are evidence and never expire. The caller chooses the schema: P5 calls this only
  for the platform schema, where problem-report screenshots live; a later retained purpose in a
  customer schema needs its own caller.
  """
  @spec expire(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :storage_failed | :audit_failed}
  def expire(prefix, opts \\ []) when is_binary(prefix) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 500)

    refs =
      Repo.all(
        from(l in Link,
          where: not is_nil(l.retain_until) and l.retain_until <= ^now and is_nil(l.locked_at),
          distinct: true,
          order_by: [asc: l.owner_kind, asc: l.owner_id, asc: l.purpose],
          limit: ^limit,
          select: %{kind: l.owner_kind, id: l.owner_id, purpose: l.purpose}
        ),
        prefix: prefix
      )

    case refs do
      [] ->
        {:ok, 0}

      refs ->
        Repo.transaction(fn ->
          Enum.each(refs, &lock_owner!(Map.put(&1, :prefix, prefix)))

          {count, by_kind, blob_ids} =
            Enum.reduce(refs, {0, %{}, []}, fn ref, {count, by_kind, blob_ids} ->
              ref = Map.put(ref, :prefix, prefix)
              {deleted, released} = expire_owner!(ref, now)

              {
                count + deleted,
                Map.update(by_kind, ref.kind, deleted, &(&1 + deleted)),
                released ++ blob_ids
              }
            end)

          blob_ids |> Enum.uniq() |> Enum.each(&@blob_store.release(prefix, &1))
          if count > 0, do: expire_audit!(prefix, now, count, by_kind)
          count
        end)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      log_storage_failure(e)
      {:error, :storage_failed}
  end

  defp expire_owner!(ref, now) do
    expired =
      Repo.all(
        from(l in owner_purpose_query(ref),
          where: not is_nil(l.retain_until) and l.retain_until <= ^now and is_nil(l.locked_at),
          order_by: [asc: l.position],
          lock: "FOR UPDATE"
        ),
        prefix: ref.prefix
      )

    case expired do
      [] ->
        {0, []}

      links ->
        ids = Enum.map(links, & &1.id)
        Repo.delete_all(from(l in Link, where: l.id in ^ids), prefix: ref.prefix)

        remaining_ids =
          Repo.all(
            from(l in owner_purpose_query(ref), order_by: [asc: l.position], select: l.id),
            prefix: ref.prefix
          )

        apply_order!(ref, remaining_ids)
        if Enum.any?(links, & &1.is_main), do: promote_first!(ref, ref.purpose)

        blob_ids =
          links
          |> Enum.flat_map(&[&1.blob_id, &1.thumb_blob_id])
          |> Enum.reject(&is_nil/1)

        {length(links), blob_ids}
    end
  end

  defp expire_audit!(prefix, now, count, by_kind) do
    attrs = %{
      actor_id: nil,
      action: "attachment.expired",
      resource_type: "attachment",
      resource_id: "expiry",
      before_state: nil,
      after_state: %{
        "count" => count,
        "by_owner_kind" => by_kind,
        "retain_cutoff" => DateTime.to_iso8601(now)
      },
      trace_id: nil
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> :ok
      _ -> Repo.rollback(:audit_failed)
    end
  rescue
    _ -> Repo.rollback(:audit_failed)
  end

  # Shared shell of delete / set_main / set_caption: cast ids, one transaction under the owner lock,
  # the link read FOR UPDATE with the owner filter (another owner's link is `:not_found`).
  defp mutate(prefix, owner, link_id, ctx, fun) do
    with {:ok, kind, id} <- read_owner(owner),
         {:ok, link_id} <- cast_uuid(link_id),
         {:ok, actor} <- cast_actor(ctx) do
      ref = %{prefix: prefix, kind: kind, id: id, purpose: nil}

      kind
      |> run_locked(ref, fn ->
        query = from(l in link_query(kind, id, link_id), lock: "FOR UPDATE")

        case Repo.one(query, prefix: prefix) do
          nil ->
            Repo.rollback(:not_found)

          link ->
            case fun.(link, ref, actor) do
              {:ok, result} -> result
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
      |> unwrap_link(kind)
    else
      {:error, :actor_invalid} = err -> err
      _ -> {:error, :not_found}
    end
  end

  defp unwrap_link({:ok, link}, _kind), do: {:ok, link}
  defp unwrap_link({:error, :not_found} = err, _kind), do: err
  defp unwrap_link({:error, _} = err, kind), do: track(err, kind, nil)

  # Runs `fun` in a transaction under the owner's advisory lock and maps storage failures (INV-8).
  defp run_locked(_kind, ref, fun) do
    Repo.transaction(fn ->
      lock_owner!(ref)
      fun.()
    end)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      log_storage_failure(e)
      {:error, :storage_failed}
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp lock_owner!(ref) do
    key = ref.prefix <> ":attachments:" <> ref.kind <> ":" <> ref.id
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
  end

  defp owner_purpose_query(ref) do
    from(l in Link,
      where: l.owner_kind == ^ref.kind and l.owner_id == ^ref.id and l.purpose == ^ref.purpose
    )
  end

  defp link_query(kind, owner_id, link_id) do
    from(l in Link, where: l.id == ^link_id and l.owner_kind == ^kind and l.owner_id == ^owner_id)
  end

  defp attr(attrs, key) when is_map(attrs), do: Map.get(attrs, key)
  defp attr(_, _), do: nil

  defp owner_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp owner_kind(_), do: nil

  defp registered(%{kind: kind}) when is_binary(kind) do
    case Owners.fetch(kind) do
      {:ok, entry} -> {:ok, kind, entry}
      :error -> {:error, :owner_kind_not_registered}
    end
  end

  defp registered(_), do: {:error, :owner_kind_not_registered}

  defp cast_owner_id(%{id: id}) do
    case cast_uuid(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :owner_invalid}
    end
  end

  defp cast_owner_id(_), do: {:error, :owner_invalid}

  defp read_owner(%{kind: kind, id: id}) when is_binary(kind) do
    case cast_uuid(id) do
      {:ok, id} -> {:ok, kind, id}
      :error -> :error
    end
  end

  defp read_owner(_), do: :error

  defp cast_actor(%{actor_id: actor_id}) do
    case cast_uuid(actor_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :actor_invalid}
    end
  end

  defp cast_actor(_), do: {:error, :actor_invalid}

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_), do: :error

  defp cast_all(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case cast_uuid(value) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp purpose_rules(entry, purpose) when is_binary(purpose) do
    case Map.fetch(entry.purposes, purpose) do
      {:ok, rules} -> {:ok, rules}
      :error -> {:error, :purpose_not_allowed}
    end
  end

  defp purpose_rules(_entry, _purpose), do: {:error, :purpose_not_allowed}

  # Code points, the same unit as PostgreSQL `char_length` in the table CHECK. `String.valid?/1`
  # first: `String.to_charlist/1` raises on invalid UTF-8.
  defp normalize_caption(nil), do: {:ok, nil}

  # The byte bound comes first (INV-8): the caption is untrusted input that reaches this function
  # unbounded over HTTP (multipart parts up to the 25 MiB body cap), and the charlist below costs
  # 16 bytes per code point. A UTF-8 code point is at most 4 bytes, so a valid caption is at most
  # `4 * @caption_max` bytes plus the surrounding whitespace that is trimmed away.
  defp normalize_caption(caption)
       when is_binary(caption) and byte_size(caption) > @caption_max_bytes,
       do: {:error, :caption_invalid}

  defp normalize_caption(caption) when is_binary(caption) do
    trimmed = if String.valid?(caption), do: String.trim(caption), else: nil

    cond do
      trimmed == nil -> {:error, :caption_invalid}
      trimmed == "" -> {:ok, nil}
      length(String.to_charlist(trimmed)) > @caption_max -> {:error, :caption_invalid}
      Regex.match?(~r/[\x{0}-\x{1F}\x{7F}]/u, trimmed) -> {:error, :caption_invalid}
      true -> {:ok, trimmed}
    end
  end

  defp normalize_caption(_), do: {:error, :caption_invalid}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp blob_meta(prefix, link) do
    Repo.one(
      from(b in Blob,
        where: b.id == ^link.blob_id,
        select: %{sha: b.sha256, size: b.byte_size, type: b.content_type}
      ),
      prefix: prefix
    )
  end

  defp state_of(link, meta) do
    %{
      "owner_kind" => link.owner_kind,
      "owner_id" => link.owner_id,
      "purpose" => link.purpose,
      "link_id" => link.id,
      "sha256" => meta.sha,
      "byte_size" => meta.size,
      "content_type" => meta.type
    }
  end

  defp audit_change!(prefix, ctx, actor, link, fields) do
    state = link |> state_of(blob_meta(prefix, link)) |> Map.put("changed", fields)
    audit!(prefix, ctx, actor, "attachment.changed", link, nil, state)
  end

  # Inside the caller's transaction. A failure, whether an error tuple or the raise on a database
  # error, rolls the whole change back as `:audit_failed`.
  defp audit!(prefix, ctx, actor, action, link, before_state, after_state) do
    attrs = %{
      actor_id: actor,
      action: action,
      resource_type: "attachment",
      resource_id: link.id,
      before_state: before_state,
      after_state: after_state,
      trace_id: Map.get(ctx, :trace_id)
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> :ok
      _ -> Repo.rollback(:audit_failed)
    end
  rescue
    _ -> Repo.rollback(:audit_failed)
  end

  defp log_storage_failure(exception) do
    require Logger

    Logger.error("attachments: storage failure #{inspect(exception.__struct__)}")
  end

  defp track({:error, reason} = result, owner_kind, purpose) do
    :telemetry.execute([:letflow, :attachments, :refused], %{count: 1}, %{
      reason: reason,
      owner_kind: owner_kind,
      purpose: purpose
    })

    result
  end

  defp track(result, _owner_kind, _purpose), do: result
end
