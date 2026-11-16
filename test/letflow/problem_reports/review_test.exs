defmodule Letflow.ProblemReports.ReviewTest do
  @moduledoc "T-1963 RV1-RV8: the owner-list rules, import and thread, through the context."
  use Letflow.DataCase, async: false

  import Ecto.Query
  alias Letflow.{Audit, Repo}
  alias Letflow.ProblemReports.{Comment, CommentImage, Report, Review}
  alias Letflow.Support.OwnerListFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp upload(bytes) do
    path = Path.join(System.tmp_dir!(), "t1963-#{System.unique_integer([:positive])}.bin")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "x.png", content_type: "image/jpeg"}
  end

  defp setup_item(state \\ "for-review", extra \\ %{}) do
    ids = F.import!([F.item("O-001", Map.merge(%{"state" => state}, extra))])
    ids["O-001"]
  end

  test "RV2 owner_transition/2 is the whole table of R2-R5" do
    for s <- ~w(for_review waiting owner_reviewed in_work) do
      assert Review.owner_transition(s, :finding) == {:ok, "owner_reviewed", :same_cycle}
      assert Review.owner_transition(s, "waiting") == {:ok, "waiting"}
      assert Review.owner_transition(s, "closed") == {:ok, "closed"}
    end

    assert Review.owner_transition("ready", :finding) == {:ok, "owner_reviewed", :next_cycle}
    assert Review.owner_transition("ready", "waiting") == {:ok, "waiting"}
    assert Review.owner_transition("ready", "closed") == {:ok, "closed"}

    for a <- [:finding, "waiting", "closed"],
        do: assert(Review.owner_transition("closed", a) == {:error, :item_closed})

    assert Review.owner_transition("waiting", "ready") == {:error, {:invalid, "state"}}
    assert Review.owner_transition("bogus", :finding) == {:error, {:invalid, "state"}}
  end

  test "RV1 RV3 an owner entry is stored, ordered, and the cycle follows R2", %{p: p} do
    id = setup_item("ready")
    actor = Ecto.UUID.generate()

    assert {:ok, d1} = Review.add_owner_entry(id, %{"text" => "First look"}, actor)
    assert d1["status"] == "owner_reviewed" and d1["cycle"] == 2
    assert {:ok, d2} = Review.add_owner_entry(id, %{"text" => "Second look"}, actor)
    assert d2["cycle"] == 2 and d2["status"] == "owner_reviewed"

    assert [%{"text" => "First look", "cycle" => 2}, %{"text" => "Second look"}] = d2["thread"]
    assert Enum.all?(d2["thread"], &(&1["author"] == "owner" and &1["type"] == "finding"))
    stored = Repo.all(from(c in Comment, order_by: c.seq), prefix: p.schema_name)
    assert Enum.all?(stored, &(&1.author_user_id == actor))

    # an entry on an open state keeps the cycle
    other = F.import!([F.item("O-002", %{"state" => "in-work", "cycle" => 3})])["O-002"]
    assert {:ok, d3} = Review.add_owner_entry(other, %{"text" => "x"}, actor)
    assert d3["cycle"] == 3 and d3["status"] == "owner_reviewed"
  end

  test "RV4 a closed item is read-only", %{p: p} do
    id = setup_item("closed", %{"closed" => 1_763_200_000.0})
    before_rows = Repo.all(from(r in Report), prefix: p.schema_name)

    assert Review.add_owner_entry(id, %{"text" => "late"}, Ecto.UUID.generate()) ==
             {:error, :item_closed}

    assert Review.set_owner_state(id, %{"state" => "waiting"}, Ecto.UUID.generate()) ==
             {:error, :item_closed}

    assert Repo.all(from(r in Report), prefix: p.schema_name) == before_rows
    assert Repo.aggregate(Comment, :count, prefix: p.schema_name) == 0
    assert {:ok, %{"status" => "closed"}} = Review.get(id)
  end

  test "RV5 the import keeps tasks, lesson, cycle, due date, closed time and the thread order", %{
    p: p
  } do
    thread = [
      %{
        "id" => 2,
        "ts" => 1_763_110_100.0,
        "author" => "operator",
        "type" => "answer",
        "text" => "b",
        "cycle" => 1
      },
      %{
        "id" => 1,
        "ts" => 1_763_110_000.0,
        "author" => "owner",
        "type" => "finding",
        "text" => "a",
        "tasks" => "T-1953",
        "lesson" => "Check phones",
        "cycle" => 1,
        "forwarded" => true
      }
    ]

    id = setup_item("closed", %{"thread" => thread, "closed" => 1_763_200_000.0, "cycle" => 2})
    assert {:ok, d} = Review.get(id)

    assert [%{"text" => "a", "tasks" => "T-1953", "lesson" => "Check phones"}, %{"text" => "b"}] =
             d["thread"]

    assert d["tasks"] == ["T-1948"] and d["cycle"] == 2 and d["due"] == ~D[2026-12-01]
    assert DateTime.to_unix(d["closed_at"]) == 1_763_200_000 and d["status"] == "closed"
    assert d["number"] == "O-001" and d["title"] == "Check the stock count screen"
    row = Repo.one!(from(c in Comment, where: c.text == "a"), prefix: p.schema_name)
    assert row.forwarded and is_nil(row.author_user_id)
  end

  test "RV6 set_owner_state: waiting and closed from every open state, with a note" do
    for s <- ~w(for-review waiting owner-reviewed in-work ready) do
      ref = "O-" <> Integer.to_string(System.unique_integer([:positive]) + 100)
      id = F.import!([F.item(ref, %{"state" => s})])[ref]

      assert {:ok, %{"status" => "waiting", "closed_at" => nil}} =
               Review.set_owner_state(id, %{"state" => "waiting"}, Ecto.UUID.generate())

      assert {:ok, d} =
               Review.set_owner_state(
                 id,
                 %{"state" => "closed", "text" => "Done, thanks"},
                 Ecto.UUID.generate()
               )

      assert d["status"] == "closed" and d["closed_at"]
      assert [%{"author" => "owner", "type" => "note", "text" => "Done, thanks"}] = d["thread"]
    end

    id = setup_item()

    for bad <- ["ready", "in_work", "garbage", nil, 5] do
      assert Review.set_owner_state(id, %{"state" => bad}, Ecto.UUID.generate()) ==
               {:error, {:invalid, "state"}}
    end
  end

  test "RV7 secret-shaped text is refused and never echoed" do
    id = setup_item()
    secret = "password: hunter2abc"

    assert Review.add_owner_entry(id, %{"text" => "my " <> secret}, Ecto.UUID.generate()) ==
             {:error, :secret}

    assert Review.set_owner_state(
             id,
             %{"state" => "closed", "text" => secret},
             Ecto.UUID.generate()
           ) == {:error, :secret}

    for {key, value} <- [{"title", secret}, {"why", secret}, {"answer", secret}] do
      doc = F.document([F.item("O-077", %{key => value})])
      assert {:error, {:invalid_import, message}} = Review.import(doc)
      assert message =~ "O-077 #{key}"
      refute message =~ "hunter2"
    end

    lesson =
      F.item("O-078", %{
        "thread" => [
          %{
            "ts" => 1.0e9,
            "author" => "owner",
            "type" => "finding",
            "lesson" => secret,
            "cycle" => 1
          }
        ]
      })

    assert {:error, {:invalid_import, message}} = Review.import(F.document([lesson]))
    refute message =~ "hunter2"
  end

  test "RV8 audit holds counts only; an audit failure rolls the entry back", %{p: p} do
    id = setup_item()
    actor = Ecto.UUID.generate()

    assert {:ok, _} =
             Review.add_owner_entry(
               id,
               %{"text" => "Private words here", "images" => [upload(F.png())]},
               actor
             )

    assert {:ok, _} = Review.set_owner_state(id, %{"state" => "waiting"}, actor)

    entries =
      Repo.all(
        from(e in Audit.Entry,
          where: e.resource_type == "owner_item" and e.action != "owner_list.imported"
        ),
        prefix: p.schema_name
      )

    assert Enum.sort(Enum.map(entries, & &1.action)) == [
             "owner_item.entry_added",
             "owner_item.state_set"
           ]

    added = Enum.find(entries, &(&1.action == "owner_item.entry_added"))
    assert added.after_state["images"] == 1 and added.after_state["text_length"] == 18
    refute inspect(entries) =~ "Private words"

    Repo.query!(~s|ALTER TABLE "#{p.schema_name}".audit_entries RENAME TO audit_entries_gone|)

    assert {:error, :internal} = Review.add_owner_entry(id, %{"text" => "will roll back"}, actor)
    Repo.query!(~s|ALTER TABLE "#{p.schema_name}".audit_entries_gone RENAME TO audit_entries|)

    assert Repo.aggregate(from(c in Comment, where: c.text == "will roll back"), :count,
             prefix: p.schema_name
           ) == 0
  end

  test "IM images are typed from the first bytes, capped, and stored with the entry", %{p: p} do
    id = setup_item()
    actor = Ecto.UUID.generate()

    assert {:ok, d} =
             Review.add_owner_entry(
               id,
               %{"text" => "", "images" => [upload(F.png()), upload(F.jpeg())]},
               actor
             )

    assert [%{"images" => [%{"content_type" => "image/png"}, %{"content_type" => "image/jpeg"}]}] =
             d["thread"]

    assert Repo.aggregate(CommentImage, :count, prefix: p.schema_name) == 2

    count = fn -> Repo.aggregate(Comment, :count, prefix: p.schema_name) end
    n = count.()
    seven = for _ <- 1..7, do: upload(F.png())

    assert Review.add_owner_entry(id, %{"text" => "x", "images" => seven}, actor) ==
             {:error, {:invalid, "images"}}

    assert Review.add_owner_entry(id, %{"text" => "x", "images" => [upload("GIF89a....")]}, actor) ==
             {:error, :bad_image_type}

    big = F.png() <> :binary.copy(<<0>>, 5_242_881)

    assert Review.add_owner_entry(id, %{"text" => "x", "images" => [upload(big)]}, actor) ==
             {:error, :image_too_large}

    assert Review.add_owner_entry(id, %{"text" => "x", "images" => ["not an upload"]}, actor) ==
             {:error, {:invalid, "images"}}

    assert Review.add_owner_entry(id, %{"text" => "  "}, actor) == {:error, {:invalid, "text"}}
    assert count.() == n
  end
end
