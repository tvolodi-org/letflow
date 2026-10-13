defmodule Letflow.Definitions.PromotionReviewStore do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for `promotion_reviews`' state-machine transition functions
  (`insert_review/2`, `approve_review/4`, `reject_review/3`,
  `mark_review_applied/2`, `mark_review_failed/2`, `supersede_review/3`), ported
  from R-Co's `src/definition/promotion_review.zig` (PRM-04). See
  `lib/letflow/design/promotion_review_state_machine.md` §2 for the full
  gate-approved design this module implements; this moduledoc restates the
  invariants that design requires to be stated here verbatim in substance.

  ## Exactly 8 permitted edges, no 9th possible — structural, not just documented
  (design §2.1, INV-PRM04-1; widened from 7 to 8 by REQ-038
  (`lib/letflow/design/req038-promotion-rollback.md` §7) — `supersede_review/3`
  gained the `approved -> superseded` edge. This is a real, deliberate change to a
  previously-true "exactly 7" claim about this already-merged, gate-approved module,
  not a drive-by edit — flagged explicitly for REVIEWER's attention on the REQ-038
  handoff.)

  ```
                   insert_review/2
                          |
                          v
                   [pending_review]
                     /            \\
        approve_review/4      reject_review/3
                   /                  \\
                  v                    v
            [approved]              [rejected]
             /    |    \\                  \\
  mark_review_applied/2 |  mark_review_failed/2  \\
           /       |          \\                   \\
          v         \\          v                    \\
      [applied]       \\    [failed]                   \\
          \\             \\      /                        \\
           \\              \\   /                          |
            `----------- supersede_review/3 (all 4 edges) -'
                                |
                                v
                          [superseded]
  ```

  The middle diagonal out of `[approved]` (labeled implicitly above, since ASCII
  space is tight) is `supersede_review/3` called directly on an `:approved` row —
  see the REQ-038 note below for why this edge is real, not a shortcut.

  Every transition function has a hardcoded, closed `allowed_source_statuses`
  list (never computed, never "default allow"):

    * `approve_review/4` — `[:pending_review]`
    * `reject_review/3` — `[:pending_review]`
    * `mark_review_applied/2` — `[:approved]`
    * `mark_review_failed/2` — `[:approved]`
    * `supersede_review/3` — `[:applied, :approved, :failed, :rejected]`

  Any call whose row's current `status` isn't a member of that function's own
  list — whether caught at the pre-check or only at the guarded `UPDATE`'s
  `WHERE` clause (the race case) — returns `{:error, :invalid_transition}`, the
  same atom for every illegal edge (`rejected -> approved`,
  `pending_review -> applied`, `superseded -> anything`, ...). No function lists
  `:pending_review` or `:superseded` in its own `allowed_source_statuses`, so no
  function can move a row backward into `pending_review` or out of
  `superseded` — this follows structurally from the fixed lists above, not from
  a separate check. `supersede_review/3` includes `:rejected` — the edge PRM-04
  originally added; `rejected` is not terminal. It also includes `:approved` —
  the edge REQ-038 adds (`lib/letflow/design/req038-promotion-rollback.md` §7):
  `promote_definition/3` and `mark_review_applied/2` are two separate calls made
  by some future orchestrator, which leaves a real window where the
  `process_definitions` row is already `:active` but its originating review is
  still `:approved` (the orchestrator's second call hasn't run yet, or failed
  independently) — `Letflow.Definitions.rollback_definition_version/4` needs to
  be able to supersede a review in that window, not only an already-`:applied`
  one.

  ## The generic guarded-update pattern (design §2.2) — every transition shares it

  `transition/6` (private) is the single mechanism every one of the six
  transition functions routes through:

    1. `Repo.get(PromotionReview, review_id, prefix: prefix)`. `nil` ->
       `{:error, :review_not_found}`.
    2. `pre_gate.(row)` — function-specific gate(s) that must run before the
       status pre-check (only `approve_review/4`'s self-approval gate uses
       this; every other function passes a no-op).
    3. Status pre-check: `row.status in allowed_source_statuses`. `false` ->
       `{:error, :invalid_transition}` — a fast, non-authoritative rejection
       that avoids issuing a doomed `UPDATE`.
    4. `post_gate.(row)` — function-specific gate(s) that run after the status
       pre-check but before the `UPDATE` (only `approve_review/4`'s digest
       gate uses this).
    5. **Authoritative step:** one `Repo.update_all/3` call with
       `WHERE id = $1 AND status = $2 AND row_version = $3`, `select: p`
       (`RETURNING`). Postgres's row-level locking makes this `WHERE`
       re-evaluate at execution time, not at step 1's read time. Zero rows
       affected -> `{:error, :invalid_transition}` (the row changed between
       step 1 and step 5). One row -> `{:ok, updated_row}`.

  Because every transition function supplies only its own
  `allowed_source_statuses` list and (where relevant) its own gates to this one
  shared mechanism, "exactly 7 permitted edges, no 8th" is a property of this
  module's code shape, not a comment someone could let drift out of sync.

  ## `row_version` is authoritative, never the pre-read (INV-PRM04-2)

  Correctness of every transition depends solely on the guarded `UPDATE`'s
  `WHERE status = $2 AND row_version = $3` clause evaluated by Postgres at
  execution time — never on the pre-read from step 1 remaining valid. No
  `Repo.transaction/1` wraps the read+update pair anywhere in this module
  (INV-PRM04-4) — correctness comes entirely from the guarded `UPDATE`'s own
  `WHERE` clause.

  ## Constant-time digest comparison (INV-PRM04-3, inherited from
  `PromotionDigest`'s INV-PRM-5)

  `approve_review/4`'s digest gate and `insert_review/2`'s digest
  re-verification are the only two places in this module that touch a
  `plan_digest`-shaped value, and both go through
  `Letflow.Definitions.PromotionDigest.verify_digest/2` — never `==`/`=:=`
  directly.

  ## `approve_review/4`'s 3 gates, in this exact order, 3 distinct error atoms

  1. **Self-approval** (`row.requested_by == actor_id`) ->
     `{:error, :self_approval_forbidden}` — checked immediately after the
     row is read, strictly before the status pre-check and before any `UPDATE`
     is ever issued.
  2. **Status** (folded into the generic pre-check, `allowed_source_statuses =
     [:pending_review]`) -> `{:error, :invalid_transition}`.
  3. **Digest match** (`PromotionDigest.verify_digest(row.plan_digest,
     plan_digest)`) -> `{:error, :digest_mismatch}` on mismatch.
  4. **The guarded `UPDATE`** -> `{:error, :invalid_transition}` on a lost
     optimistic-lock race (this is AC4's concurrent-call outcome).

  No gate short-circuits past an earlier one, and no gate is skipped just
  because a later one would also fail.

  ## No `permission_checker` gate on `approve_review/4` (design §2.4, OQ-3)

  REQ-037's own text names only the 3 gates above plus the row_version lock —
  there is no data path from `actor_id` to a real `promotion.approve`-equivalent
  permission in Letflow today (same gap `PromotionPlan`'s own moduledoc names
  for `permission_checker`). Flagged as a real, adjacent authorization gap, not
  silently added or silently ignored.

  ## `reject_review/3`'s `actor_id` is accepted but not persisted (OQ-4)

  `promotion_reviews` has an `approved_by` column but no `rejected_by` column.
  `actor_id` is kept in the signature (matches the requirement's own named
  parameter, kept for symmetry/future audit use) but is never written to the
  row — reusing `approved_by` to mean "rejecting actor" would corrupt a column
  whose name specifically means "who approved."

  ## `supersede_review/3`'s `superseded_by_event_id` (resolves REQ-035's OQ-3)

  `superseded_by` stores the `event_id` of whatever downstream event caused
  this row to become superseded — not a self-referential `promotion_reviews.id`
  and not a `users.id` actor reference. This function does not validate that
  the id actually corresponds to an existing `events` row (no cross-table
  read-before-write), matching `PromotionConflict.reject_if_conflicts/4`'s own
  "plain read, no cross-validation beyond what's named" precedent.

  ## `mark_review_applied/2` / `mark_review_failed/2` do not call
  `Letflow.Definitions.Promotion.promote_definition/3`

  Per REQ-037's own text, `promote_definition/3` is the operation
  `mark_review_applied/2`'s *caller* invokes (some future orchestrator —
  REQ-040 or later — calls `promote_definition/3` first, then
  `mark_review_applied/2` on success or `mark_review_failed/2` on failure).
  This module deliberately does not depend on `Letflow.Definitions.Promotion`.

  ## `opts[:prefix]` is mandatory on every function, no default

  Every function in this module writes to `promotion_reviews`, a table with no
  `@schema_prefix` (schema-per-tenant). `opts[:prefix]` is `Keyword.fetch!/2`'d
  — no default, raises if omitted, same stance every other REQ-022-provisioned
  table's context module takes.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # New, distinct cursor-endpoint prefix (REQ-397 design §3.3) -- does not
  # collide with "PE:" (this router's own R11 platform-events cursor), "DL:"
  # (Definitions.list_paginated/2), or "A:"/"T:"/"U:" (Audit/Tenants/
  # Identity, per R11's own comment citing them). decode_cursor/4's prefix
  # check is what makes a cursor minted by one endpoint rejected by every
  # other endpoint's decode call.
  @promotion_reviews_list_cursor_prefix "PR:"

  # ISS-1029: minimum rows fetched per keyset chunk when a :row_visible?
  # predicate is scanning (the chunk is max(page_size + 1, this)).
  @min_scan_chunk 100

  @type status :: PromotionReview.status()

  @type list_reviews_filters :: %{
          optional(:status) => [status()] | nil,
          optional(:def_id) => String.t() | nil,
          optional(:def_type) => String.t() | nil,
          optional(:cursor) => String.t() | nil,
          required(:page_size) => pos_integer()
        }

  @type list_reviews_result :: %{items: [PromotionReview.t()], next_cursor: String.t() | nil}

  @typedoc """
  `:row_visible?` (ISS-1029): optional 1-arity predicate applied to each row
  inside the keyset scan; absent or nil means no filtering.
  """
  @type list_reviews_opts :: [
          prefix: String.t(),
          row_visible?: (PromotionReview.t() -> boolean()) | nil
        ]

  @type list_reviews_error :: :invalid_cursor | :wrong_endpoint | :expired | :invalid_schema_name

  @doc """
  Cursor-paginated, filterable read of `promotion_reviews` rows, scoped to
  `opts[:prefix]` (NEW, REQ-397 design §3). Reuses
  `Letflow.Api.Pagination`'s opaque-cursor codec exactly as
  `Letflow.Definitions.list_paginated/2` (`GET /definitions`) already does --
  `page_size`/`cursor` query params, `{items, next_cursor}` envelope, no new
  pagination shape.

  Sorted `inserted_at` DESC, `id` DESC (keyset pagination) -- the same
  compound tiebreak `Definitions.list_paginated/2`/`Letflow.Instances.list/2`/
  `Letflow.Identity.list_users/2` all already use, giving deterministic
  ordering for two rows with an identical `inserted_at`.

  `status` filters to one or more of the six enum values (an `IN` condition,
  no-op when `nil`); `def_id`/`def_type` are plain exact-match filters, each
  a no-op when `nil`. Parsing/validating raw query-param strings into this
  function's `filters` shape (including rejecting an unrecognised `status`
  token) is the caller's (router's) responsibility -- this function assumes
  already-validated input, the same split of responsibility
  `list_paginated/2` uses for `page_size`.

  `opts[:row_visible?]` (ISS-1029, optional): a 1-arity predicate over the
  loaded row. Rows for which it returns false are omitted from the page and
  never contribute to `next_cursor` (a cursor only ever encodes an emitted
  row). The scan walks the keyset in chunks of `max(page_size + 1, 100)`
  full rows until `page_size + 1` visible rows are held or the table is
  exhausted; there is deliberately no scan cap. A non-nil value that is not a
  1-arity function raises `ArgumentError` (fail closed). The predicate is
  expected not to raise; an exception propagates.

  Opens with the same `TenantProvisioning.tenant_id_for_schema_name/1` guard
  `list_paginated/2`/`insert_review/2` already use (see design §3.2): a list
  query with no `WHERE id = ...` clause against a schema whose
  `promotion_reviews` table doesn't exist would otherwise raise a raw
  `Postgrex.Error` instead of returning a typed error.
  """
  @spec list_reviews(filters :: list_reviews_filters(), opts :: list_reviews_opts()) ::
          {:ok, list_reviews_result()} | {:error, list_reviews_error()}
  def list_reviews(filters, opts) when is_map(filters) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    row_visible? = fetch_row_visible!(opts)
    page_size = Map.fetch!(filters, :page_size)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, cursor_seek} <- decode_list_reviews_cursor(Map.get(filters, :cursor)) do
      {page, next_cursor} =
        collect_list_reviews_page(filters, prefix, row_visible?, cursor_seek, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  # `:row_visible?` contract: absent/nil = no filtering; a 1-arity function =
  # per-row visibility decision; anything else fails closed (never silently
  # unfiltered).
  defp fetch_row_visible!(opts) do
    case Keyword.get(opts, :row_visible?) do
      nil ->
        nil

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError,
              "list_reviews/2 :row_visible? must be nil or a 1-arity function, got: #{inspect(other)}"
    end
  end

  # ISS-1029: without a predicate the single-query path is exactly the
  # pre-existing behaviour. With one, scan the keyset in chunks (SQL filters
  # first), keep only visible rows, and stop when page_size + 1 visible rows
  # are held or the table is exhausted. No scan cap: a cap would force a cursor
  # anchored on a hidden row (discloses it) or make visible rows unreachable.
  # The in-memory seek between chunks never leaves this call, so every
  # returned next_cursor encodes only an EMITTED (visible) row.
  defp collect_list_reviews_page(filters, prefix, nil, cursor_seek, page_size) do
    rows = fetch_list_reviews_chunk(filters, prefix, cursor_seek, page_size + 1)
    split_list_reviews_page(rows, page_size)
  end

  defp collect_list_reviews_page(filters, prefix, row_visible?, cursor_seek, page_size) do
    chunk_size = max(page_size + 1, @min_scan_chunk)

    visible =
      scan_visible_reviews(
        filters,
        prefix,
        row_visible?,
        cursor_seek,
        chunk_size,
        page_size + 1,
        []
      )

    split_list_reviews_page(visible, page_size)
  end

  defp scan_visible_reviews(filters, prefix, row_visible?, seek, chunk_size, want, acc) do
    chunk = fetch_list_reviews_chunk(filters, prefix, seek, chunk_size)
    acc = acc ++ Enum.filter(chunk, row_visible?)

    cond do
      length(acc) >= want ->
        Enum.take(acc, want)

      length(chunk) < chunk_size ->
        acc

      true ->
        %PromotionReview{id: id, inserted_at: inserted_at} = List.last(chunk)

        scan_visible_reviews(
          filters,
          prefix,
          row_visible?,
          {id, DateTime.to_unix(inserted_at, :microsecond)},
          chunk_size,
          want,
          acc
        )
    end
  end

  defp fetch_list_reviews_chunk(filters, prefix, cursor_seek, limit) do
    PromotionReview
    |> where_review_status(Map.get(filters, :status))
    |> where_review_def_id(Map.get(filters, :def_id))
    |> where_review_def_type(Map.get(filters, :def_type))
    |> filter_by_list_reviews_cursor(cursor_seek)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all(prefix: prefix)
  end

  # ---------------------------------------------------------------------
  # list_reviews/2 helpers (design §3.3) -- mirror
  # Definitions.list_paginated/2's own same-named-pattern helpers.
  # ---------------------------------------------------------------------

  defp where_review_status(query, nil), do: query

  defp where_review_status(query, statuses) when is_list(statuses) do
    where(query, [r], r.status in ^statuses)
  end

  defp where_review_def_id(query, nil), do: query
  defp where_review_def_id(query, def_id), do: where(query, [r], r.def_id == ^def_id)

  defp where_review_def_type(query, nil), do: query
  defp where_review_def_type(query, def_type), do: where(query, [r], r.def_type == ^def_type)

  defp filter_by_list_reviews_cursor(query, nil), do: query

  defp filter_by_list_reviews_cursor(query, {id, inserted_at_us}) do
    ts = DateTime.from_unix!(inserted_at_us, :microsecond)
    from(r in query, where: {r.inserted_at, r.id} < {^ts, ^id})
  end

  defp decode_list_reviews_cursor(nil), do: {:ok, nil}

  defp decode_list_reviews_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @promotion_reviews_list_cursor_prefix,
           byte_size(@promotion_reviews_list_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_list_reviews_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is "PR:<mint_time_us>:<id>:<inserted_at_us>" -- same field-slot
  # idiom as Definitions.list_paginated/2's own "DL:<mint_time_us>:<id>:
  # <created_at_us>" (design §3.3): the first slot after the prefix is
  # always the mint-time timestamp decode_cursor/4's own expiry check reads,
  # never the domain inserted_at value itself.
  defp decode_list_reviews_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@promotion_reviews_list_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, id_str, inserted_at_us_str] = String.split(rest, ":", parts: 3)
    {id_str, String.to_integer(inserted_at_us_str)}
  end

  defp split_list_reviews_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_reviews_next_cursor(List.last(page))}
  end

  defp split_list_reviews_page(rows, _page_size), do: {rows, nil}

  defp build_list_reviews_next_cursor(%PromotionReview{id: id, inserted_at: inserted_at}) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = DateTime.to_unix(inserted_at, :microsecond)

    @promotion_reviews_list_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, id, inserted_at_us)
    |> Pagination.encode_cursor()
  end

  @doc """
  Reads one `promotion_reviews` row by id, scoped to `opts[:prefix]` (NEW,
  REQ-077 design §9.1 — this module had no read function at all before this).

  Casts `review_id` with `Ecto.UUID.cast/1` before any `Repo` access —
  `Repo.get/3`'s `:binary_id` primary-key lookup raises `Ecto.Query.CastError`
  for a non-UUID binary rather than returning a tagged error, so this is the
  one place every caller (HTTP or otherwise) is protected from that crash.
  `nil` from either the cast or the lookup collapses to the same
  `{:error, :review_not_found}` atom every transition function in this module
  already returns for "no such row" — one mapping rule for the router
  (REQ-077 design §5), not two.

  Returns the struct, not a map — response shaping belongs to the caller
  (REQ-077 design §7.3's allowlist), never to this context module.
  """
  @spec get_review(review_id :: Ecto.UUID.t() | String.t(), opts :: [prefix: String.t()]) ::
          {:ok, PromotionReview.t()} | {:error, :review_not_found}
  def get_review(review_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, uuid} <- Ecto.UUID.cast(review_id),
         %PromotionReview{} = row <- Repo.get(PromotionReview, uuid, prefix: prefix) do
      {:ok, row}
    else
      _cast_error_or_nil -> {:error, :review_not_found}
    end
  end

  @type insert_review_error ::
          :duplicate_review
          | :digest_mismatch
          | :invalid_schema_name
          | Ecto.Changeset.t()

  @doc """
  Creates a `:pending_review` row from a `PromotionPlan.t()` + its digest.
  Re-verifies `digest` actually matches `plan` before writing (this module's
  own defense of `PromotionDigest`'s INV-PRM-5 — no comparator against a
  `plan_digest`-shaped value is ever bypassed).

  **Post-Decision-0006-D2 note (REQ-064):** `promotion_reviews.tenant_id` no
  longer exists as a column — the per-tenant Postgres schema already
  identifies the tenant, so this function no longer stamps a `tenant_id`
  value into the insert. `opts[:prefix]` is still resolved via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` before any row is
  written, purely as an early prefix-validity guard (an unprovisioned or
  malformed prefix surfaces as `{:error, :invalid_schema_name}` here rather
  than a raw error later out of `Repo.insert/2`) — its result is otherwise
  unused. A duplicate `plan_digest` while an earlier review is still
  `pending_review`/`approved` (the partial unique index, REQ-035, now
  `[:plan_digest]` alone per Decision 0006 D2) surfaces as `{:error,
  :duplicate_review}` — never a leaked changeset for that one case.
  """
  @spec insert_review(
          args :: %{
            required(:plan) => PromotionPlan.t(),
            required(:digest) => String.t(),
            required(:requested_by) => Ecto.UUID.t()
          },
          opts :: [prefix: String.t()]
        ) :: {:ok, PromotionReview.t()} | {:error, insert_review_error()}
  def insert_review(%{plan: plan, digest: digest, requested_by: requested_by}, opts) do
    if PromotionDigest.verify_digest(digest, plan) do
      prefix = Keyword.fetch!(opts, :prefix)

      with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
        attrs = %{
          plan_digest: digest,
          def_id: plan.process_key,
          serialised_plan: Jason.encode!(plan),
          requested_by: requested_by
        }

        %PromotionReview{}
        |> PromotionReview.insert_changeset(attrs)
        |> Repo.insert(prefix: prefix)
        |> handle_insert_result()
      end
    else
      {:error, :digest_mismatch}
    end
  end

  @type approve_review_error ::
          :review_not_found
          | :self_approval_forbidden
          | :digest_mismatch
          | :invalid_transition

  @doc """
  `pending_review -> approved`. Gates, in order (see moduledoc): self-approval,
  status, digest match, row_version-guarded update. See this module's
  moduledoc for the full 4-gate ordering and error-atom contract.
  """
  @spec approve_review(
          review_id :: Ecto.UUID.t(),
          actor_id :: Ecto.UUID.t(),
          plan_digest :: String.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, PromotionReview.t()} | {:error, approve_review_error()}
  def approve_review(review_id, actor_id, plan_digest, opts) do
    self_approval_gate = fn row ->
      if row.requested_by == actor_id do
        {:error, :self_approval_forbidden}
      else
        :ok
      end
    end

    digest_gate = fn row ->
      if PromotionDigest.verify_digest(row.plan_digest, plan_digest) do
        :ok
      else
        {:error, :digest_mismatch}
      end
    end

    set_fn = fn _row ->
      [
        status: :approved,
        approved_by: actor_id,
        approved_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ]
    end

    transition(review_id, opts, [:pending_review], self_approval_gate, digest_gate, set_fn)
  end

  @doc """
  `pending_review -> rejected`. No digest check, no self-rejection
  restriction (PRM-05: "Reject does NOT have the same restriction" as
  approve). `actor_id` is accepted but not persisted — see moduledoc OQ-4.
  """
  @spec reject_review(
          review_id :: Ecto.UUID.t(),
          actor_id :: Ecto.UUID.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
  def reject_review(review_id, _actor_id, opts) do
    transition(review_id, opts, [:pending_review], &no_gate/1, &no_gate/1, fn _row ->
      [status: :rejected]
    end)
  end

  @doc """
  `approved -> applied`. No extra gates, no `actor_id` (no `applied_by`
  column exists). Does not call `Letflow.Definitions.Promotion.promote_definition/3`
  — see moduledoc.
  """
  @spec mark_review_applied(review_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
          {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
  def mark_review_applied(review_id, opts) do
    transition(review_id, opts, [:approved], &no_gate/1, &no_gate/1, fn _row ->
      [status: :applied]
    end)
  end

  @doc """
  `approved -> failed`. No extra gates, no `actor_id` (no `failed_by` column
  exists).
  """
  @spec mark_review_failed(review_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
          {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
  def mark_review_failed(review_id, opts) do
    transition(review_id, opts, [:approved], &no_gate/1, &no_gate/1, fn _row ->
      [status: :failed]
    end)
  end

  @doc """
  `applied|approved|failed|rejected -> superseded` — one function for all 4
  supersession edges (`:rejected` is the edge PRM-04 originally added --
  `rejected` is not terminal; `:approved` is the edge REQ-038 adds, see
  moduledoc). `superseded_by_event_id` is stored verbatim, unvalidated against
  `events` — see moduledoc.
  """
  @spec supersede_review(
          review_id :: Ecto.UUID.t(),
          superseded_by_event_id :: Ecto.UUID.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
  def supersede_review(review_id, superseded_by_event_id, opts) do
    transition(
      review_id,
      opts,
      [:applied, :approved, :failed, :rejected],
      &no_gate/1,
      &no_gate/1,
      fn _row -> [status: :superseded, superseded_by: superseded_by_event_id] end
    )
  end

  # ---------------------------------------------------------------------
  # Generic transition mechanism (moduledoc "generic guarded-update
  # pattern") -- every public transition function above routes through
  # this. pre_gate runs before the status pre-check, post_gate runs after
  # it and before the guarded UPDATE; both default to a no-op via
  # `&no_gate/1` for every function except approve_review/4.
  # ---------------------------------------------------------------------

  @spec transition(
          Ecto.UUID.t(),
          [prefix: String.t()],
          [PromotionReview.status()],
          (PromotionReview.t() -> :ok | {:error, term()}),
          (PromotionReview.t() -> :ok | {:error, term()}),
          (PromotionReview.t() -> Keyword.t())
        ) :: {:ok, PromotionReview.t()} | {:error, term()}
  defp transition(review_id, opts, allowed_source_statuses, pre_gate, post_gate, set_fn) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(PromotionReview, review_id, prefix: prefix) do
      nil ->
        {:error, :review_not_found}

      %PromotionReview{} = row ->
        with :ok <- pre_gate.(row),
             :ok <- check_status(row, allowed_source_statuses),
             :ok <- post_gate.(row) do
          execute_update(row, prefix, set_fn.(row))
        end
    end
  end

  @spec no_gate(PromotionReview.t()) :: :ok
  defp no_gate(_row), do: :ok

  @spec check_status(PromotionReview.t(), [PromotionReview.status()]) ::
          :ok | {:error, :invalid_transition}
  defp check_status(row, allowed_source_statuses) do
    if row.status in allowed_source_statuses do
      :ok
    else
      {:error, :invalid_transition}
    end
  end

  # The authoritative step (design §2.2 step 4/5): a single row_version- and
  # status-guarded Repo.update_all/3, `select: p` for RETURNING. Zero rows
  # affected means the row changed since the pre-read -- lost the race, or an
  # intervening concurrent call already moved it.
  @spec execute_update(PromotionReview.t(), String.t(), Keyword.t()) ::
          {:ok, PromotionReview.t()} | {:error, :invalid_transition}
  defp execute_update(row, prefix, set_fields) do
    query =
      from(p in PromotionReview,
        where: p.id == ^row.id and p.status == ^row.status and p.row_version == ^row.row_version,
        select: p
      )

    set = set_fields ++ [row_version: row.row_version + 1]

    case Repo.update_all(query, [set: set], prefix: prefix) do
      {1, [updated_row]} -> {:ok, updated_row}
      {0, []} -> {:error, :invalid_transition}
    end
  end

  defp handle_insert_result({:ok, %PromotionReview{}} = ok), do: ok

  defp handle_insert_result({:error, %Ecto.Changeset{} = changeset}) do
    if duplicate_digest_error?(changeset) do
      {:error, :duplicate_review}
    else
      {:error, changeset}
    end
  end

  # Matches Ecto's own unique_constraint/3-declared error shape, same
  # constraint_name-matching convention lib/letflow/event_store.ex's
  # sequence_conflict?/1 already establishes for the identical class of
  # problem (a unique-index violation that must surface as a distinct typed
  # error, never a leaked changeset/raw Postgrex/Ecto.ConstraintError).
  @spec duplicate_digest_error?(Ecto.Changeset.t()) :: boolean()
  defp duplicate_digest_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "uq_promotion_review_active_digest"
    end)
  end
end
