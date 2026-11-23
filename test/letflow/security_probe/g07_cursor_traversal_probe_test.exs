defmodule Letflow.Security.G07CursorTraversalProbeTest do
  @moduledoc """
  **G-07 security probe** -- the exact-once multi-page traversal part.

  The pure codec properties live in `g07_cursor_codec_probe_test.exs`; this
  file proves the property that only a real listing can show: a cursor-paged
  listing shows every row EXACTLY ONCE.

  The rows carry a `:` inside their `service_id` -- the shape T-2571 found by
  hand, where a colon in the id shifted the cursor's slots and the listing
  repeated or skipped rows. The traversal is bounded, so a cursor that loops
  (a legacy cursor decoded into the wrong values) fails the test instead of
  hanging it.

  Real Postgres (`service_catalog` is a GLOBAL table, so no tenant schema is
  needed). The rows are deleted in `on_exit/1`; the table is global, so its
  rows are not cleaned up by a tenant schema drop.
  """

  use Letflow.DataCase, async: false

  @moduletag :security_probe
  @moduletag probe_cost_s: 15

  import Ecto.Query

  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry

  @row_count 6

  # A traversal that never ends is a defect, not a slow test: the bound is
  # far above the number of pages the fixture needs.
  @max_pages 200

  setup do
    unique = "g07-trav-#{System.unique_integer([:positive])}"
    base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for index <- 1..@row_count do
        service_id =
          "#{unique}:row-#{index}" <> if(rem(index, 2) == 0, do: ":with:colons", else: "")

        created_at = DateTime.add(base, -index, :second)

        insert_entry!(service_id, created_at)

        %{service_id: service_id, created_at: created_at}
      end

    # `service_catalog` is a GLOBAL table: its rows are not removed by a
    # tenant schema drop, so the fixture deletes its own rows in the test
    # process (an `on_exit/1` callback runs outside the sandbox connection
    # and cannot reach them).
    %{rows: rows, unique: unique}
  end

  test "a cursor-paged listing shows every row exactly once", %{rows: rows, unique: unique} do
    expected =
      rows
      |> Enum.sort_by(&{DateTime.to_unix(&1.created_at, :microsecond), &1.service_id})
      |> Enum.reverse()
      |> Enum.map(& &1.service_id)

    for page_size <- [1, 2, 3] do
      assert traverse(unique, page_size) == expected,
             "a page_size of #{page_size} did not show every row exactly once"
    end

    delete_rows(Enum.map(rows, & &1.service_id))
  end

  test "a cursor is stable: it answers the same page every time it is replayed", %{
    rows: rows,
    unique: unique
  } do
    {:ok, %{items: first_page, next_cursor: cursor}} =
      ServiceCatalog.list_all(%{page_size: 1, cursor: nil})

    assert is_binary(cursor)

    {:ok, %{items: second_page, next_cursor: next_cursor}} =
      ServiceCatalog.list_all(%{page_size: 1, cursor: cursor})

    assert is_binary(next_cursor)

    # The same cursor answers the same page -- the traversal is deterministic,
    # so a defect cannot hide behind a changing page.
    {:ok, %{items: replayed}} = ServiceCatalog.list_all(%{page_size: 1, cursor: cursor})

    assert Enum.map(replayed, & &1.service_id) == Enum.map(second_page, & &1.service_id)
    assert Enum.map(first_page, & &1.service_id) != Enum.map(second_page, & &1.service_id)

    refute Enum.empty?(traverse(unique, 1))

    delete_rows(Enum.map(rows, & &1.service_id))
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp traverse(unique, page_size) do
    traverse(unique, page_size, nil, 0, [])
  end

  defp traverse(unique, page_size, cursor, pages, acc) when pages >= @max_pages do
    _ = {unique, page_size, cursor, acc}
    flunk("the cursor-paged listing did not terminate within #{@max_pages} pages")
  end

  defp traverse(unique, page_size, cursor, pages, acc) do
    case ServiceCatalog.list_all(%{page_size: page_size, cursor: cursor}) do
      {:ok, %{items: items, next_cursor: next_cursor}} ->
        mine =
          items
          |> Enum.filter(&String.starts_with?(&1.service_id, unique))
          |> Enum.map(& &1.service_id)

        acc = acc ++ mine

        if next_cursor do
          traverse(unique, page_size, next_cursor, pages + 1, acc)
        else
          acc
        end
    end
  end

  defp insert_entry!(service_id, created_at) do
    %Entry{}
    |> Entry.insert_changeset(%{
      service_id: service_id,
      endpoint_url: "https://example.test/svc",
      required_auth: :NONE,
      timeout_ms: 1000,
      scope: :global
    })
    |> Ecto.Changeset.change(
      created_at: created_at,
      updated_at: created_at,
      published_at: created_at
    )
    |> Repo.insert!()
  end

  defp delete_rows(service_ids) do
    Repo.delete_all(from(e in Entry, where: e.service_id in ^service_ids))
  end
end
