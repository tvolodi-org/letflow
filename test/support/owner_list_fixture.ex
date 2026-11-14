defmodule Letflow.Support.OwnerListFixture do
  @moduledoc """
  T-1963: builds owner-list documents (the JSON of the lab list) and tiny valid images for tests.
  Items reach the database through the real `Letflow.ProblemReports.Review.import/1`.
  """

  alias Letflow.ProblemReports.Review

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>

  def png, do: @png
  def jpeg, do: @jpeg

  @doc "One lab item map; `overrides` are string-keyed."
  def item(ref \\ "O-001", overrides \\ %{}) do
    Map.merge(
      %{
        "id" => ref,
        "title" => "Check the stock count screen",
        "kind" => "review",
        "steps" => "Open the screen",
        "why" => "It is new",
        "tasks" => ["T-1948"],
        "state" => "for-review",
        "added" => 1_763_100_000.0,
        "due" => "2026-12-01",
        "recommended" => "",
        "answer" => "",
        "closed" => nil,
        "source" => "operator",
        "cycle" => 1,
        "thread" => []
      },
      overrides
    )
  end

  def document(items),
    do: %{"format" => "letflow-owner-list", "version" => 1, "items" => items}

  @doc "Imports `items` and returns the stored detail maps by owner_ref."
  def import!(items) do
    {:ok, %{"imported" => _}} = Review.import(document(items))
    {:ok, %{"reports" => reports}} = Review.list(%{"status" => "all", "limit" => "100"})
    Map.new(reports, &{&1["number"], &1["id"]})
  end

  @doc "A multipart/form-data body; parts are `{name, filename | nil, content_type | nil, data}`."
  def multipart(parts, boundary \\ "XBOUNDARYX") do
    body =
      Enum.map_join(parts, "", fn {name, file, type, data} ->
        disp =
          if file,
            do: ~s|form-data; name="#{name}"; filename="#{file}"|,
            else: ~s|form-data; name="#{name}"|

        ctype = if type, do: "content-type: #{type}\r\n", else: ""
        "--#{boundary}\r\ncontent-disposition: #{disp}\r\n#{ctype}\r\n" <> data <> "\r\n"
      end)

    {"multipart/form-data; boundary=#{boundary}", body <> "--#{boundary}--\r\n"}
  end
end
