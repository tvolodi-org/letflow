defmodule Letflow.Platform.ChangeSetReviewTest do
  @moduledoc """
  REQ-535 (GH #3098): `Letflow.Platform.ChangeSetReview.review/1` is pure; this
  file uses plain `ExUnit.Case` (no Ecto sandbox is checked out).
  """
  use ExUnit.Case, async: true

  alias Letflow.Platform.ChangeSetReview

  defp add(id, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        kind: :add_column,
        entity_type: "invoice",
        attribute: "vat",
        pg_type: "text",
        nullable: true
      },
      extra
    )
  end

  defp backfill(id), do: %{id: id, kind: :backfill, entity_type: "invoice", attribute: "vat"}
  defp not_null(id), do: %{id: id, kind: :set_not_null, entity_type: "invoice", attribute: "vat"}
  defp rewrite(id), do: %{id: id, kind: :rewrite_stored_history, entity_type: "invoice"}

  defp ids({:error, {:rejected, vs}}), do: Enum.map(vs, &{&1.change_id, &1.kind})

  test "history rewrite is rejected alone" do
    set = %{changes: [add("a"), rewrite("b"), backfill("c")], ack_destructive: []}
    assert {:error, {:rejected, [v]}} = ChangeSetReview.review(set)
    assert v.change_id == "b"
    assert v.kind == :unbounded_lock
    assert v.class == nil
  end

  test "add_column + set_not_null without backfill is Class B" do
    set = %{changes: [add("a"), not_null("b")], ack_destructive: ["b"]}
    assert {:error, {:rejected, [v]}} = ChangeSetReview.review(set)
    assert %{change_id: "b", kind: :not_covered, class: :b} = v
    assert v.change.attribute == "vat"
  end

  test "backfill + ack accepted; missing ack and backfill-after rejected" do
    ok = %{changes: [add("a"), backfill("b"), not_null("c")], ack_destructive: ["c"]}
    assert {:ok, %{class_b_ids: ["c"]}} = ChangeSetReview.review(ok)

    assert ids(ChangeSetReview.review(%{ok | ack_destructive: []})) == [{"c", :missing_ack}]

    late = %{changes: [add("a"), not_null("c"), backfill("b")], ack_destructive: ["c"]}
    assert ids(ChangeSetReview.review(late)) == [{"c", :not_covered}]
  end

  test "unknown kind or missing field is invalid_change_set" do
    assert {:error, {:invalid_change_set, _}} =
             ChangeSetReview.review(%{
               changes: [%{id: "a", kind: :drop_table}],
               ack_destructive: []
             })

    assert {:error, {:invalid_change_set, _}} =
             ChangeSetReview.review(%{changes: [%{id: "a", kind: :backfill, entity_type: "x"}]})

    assert {:error, {:invalid_change_set, {:duplicate_id, "a"}}} =
             ChangeSetReview.review(%{changes: [backfill("a"), backfill("a")]})
  end

  test "verdicts are deterministic and order-independent" do
    set = %{
      changes: [rewrite("z"), add("a", %{attribute: "q", nullable: false}), rewrite("m")],
      ack_destructive: []
    }

    r = ChangeSetReview.review(set)
    assert r == ChangeSetReview.review(set)
    assert r == ChangeSetReview.review(%{set | changes: Enum.reverse(set.changes)})
    assert ids(r) == [{"a", :not_covered}, {"m", :unbounded_lock}, {"z", :unbounded_lock}]
  end

  test "all violations are returned" do
    set = %{changes: [rewrite("a"), not_null("b")], ack_destructive: []}
    assert ids(ChangeSetReview.review(set)) == [{"a", :unbounded_lock}, {"b", :not_covered}]
  end

  test "runs without the sandbox and without Repo or MigrationRollout" do
    assert {:ok, _} = ChangeSetReview.review(%{changes: [add("a")], ack_destructive: []})
    src = File.read!("lib/letflow/platform/change_set_review.ex")
    refute src =~ "Repo."
    refute src =~ ~r/MigrationRollout\./
  end
end
