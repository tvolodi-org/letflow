defmodule Letflow.Entities.ViewsTest do
  @moduledoc """
  REQ-555 / GH #3157: storage and audit of `Letflow.Entities.Views` (design ids S1, S2, A1-A5).
  """

  use Letflow.DataCase, async: false

  import Letflow.EntityViewsSupport

  alias Letflow.Entities.Views

  setup do
    base = tenant!("views-ctx-a")
    a = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    {:ok, a: a}
  end

  defp create!(ctx, overrides \\ %{}) do
    {:ok, view} = Views.create(ctx.schema_name, ctx.user_id, valid_view(overrides))
    view
  end

  describe "criterion 1: storage" do
    test "S1 a view created in tenant A is absent from tenant B's schema", %{a: a} do
      view = create!(a)
      assert view.tenant_id == a.tenant_id
      assert view_count(a) == 1

      b = tenant!("views-ctx-b")
      assert view_count(b) == 0
      assert {:error, :not_found} = Views.get(b.schema_name, a.user_id, view.id)
    end

    test "S2 name is unique per entity type within the tenant", %{a: a} do
      create!(a)
      assert {:error, :name_taken} = Views.create(a.schema_name, a.user_id, valid_view())
      assert view_count(a) == 1
    end

    test "the stored row carries ordered columns, clauses, actors and timestamps", %{a: a} do
      view = create!(a, %{"columns" => ["is_correct", "text"]})
      assert view.columns == ["is_correct", "text"]
      assert view.filter == [%{"field" => "text", "op" => "neq", "value" => "Z"}]
      assert view.sort == [%{"field" => "text", "dir" => "asc"}]
      assert view.created_by == a.user_id and view.updated_by == a.user_id
      assert view.inserted_at && view.updated_at
    end
  end

  describe "criterion 7: audit in the same transaction" do
    test "A1 create writes one audit entry", %{a: a} do
      create!(a)
      assert audit_count(a, "entity_view.create") == 1
    end

    test "A2 update writes one audit entry", %{a: a} do
      view = create!(a)

      {:ok, _} =
        Views.update(a.schema_name, a.user_id, view.id, valid_view(%{"name" => "Renamed"}))

      assert audit_count(a, "entity_view.update") == 1
    end

    test "A3 delete writes one audit entry", %{a: a} do
      view = create!(a)
      {:ok, _} = Views.delete(a.schema_name, a.user_id, view.id)
      assert audit_count(a, "entity_view.delete") == 1
      assert view_count(a) == 0
    end

    test "A4 an audit failure rolls the write back", %{a: a} do
      # The audit table disappears inside the test transaction (rolled back by the sandbox), so the
      # audit insert fails after the view insert.
      Repo.query!(~s|ALTER TABLE "#{a.schema_name}".audit_entries RENAME TO audit_entries_gone|)

      result =
        try do
          Views.create(a.schema_name, a.user_id, valid_view())
        rescue
          error -> {:raised, error}
        end

      refute match?({:ok, _}, result)
      assert view_count(a) == 0
    end

    test "A5 refusals write no audit entry", %{a: a} do
      view = create!(a)
      before = audit_count(a, "entity_view.create")

      assert {:error, {:unprocessable, _}} =
               Views.create(a.schema_name, a.user_id, valid_view(%{"columns" => ["nope"]}))

      assert {:error, :name_taken} = Views.create(a.schema_name, a.user_id, valid_view())

      assert {:error, :not_found} =
               Views.update(a.schema_name, a.user_id, Ecto.UUID.generate(), valid_view())

      assert {:error, :not_found} = Views.delete(a.schema_name, a.user_id, "bad")

      assert {:error, {:unprocessable, _}} =
               Views.update(a.schema_name, a.user_id, view.id, valid_view(%{"name" => ""}))

      assert audit_count(a, "entity_view.create") == before
      assert audit_count(a, "entity_view.update") == 0
      assert audit_count(a, "entity_view.delete") == 0
    end
  end
end
