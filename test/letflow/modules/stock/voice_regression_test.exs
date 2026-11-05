Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.VoiceRegressionTest do
  @moduledoc """
  T-1348 / D2d (`docs/assets/voice-port-design.md` section 8): the typed layer of the voice regression
  tests. The 20 phrases of `test/fixtures/voice/phrases.yaml` (10 ru, 10 kk) go through the real
  `VoiceService.draft_text/2`: real `VoicePrompt.build/2` on a committed fixture tenant, real
  `VoiceDraft.parse_answer/1` and `check/3`. Only the model client is a double that answers the stored
  `model_answer` of the phrase. Tests R-1..R-9; L-1 (`:voice_live`, real model, opt-in) is excluded by
  default. Runbook: `docs/runbooks/stock-voice-regression.md`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.VoiceService
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.VoiceDoubles
  alias Letflow.Voice.Settings

  @phrases_path Path.expand("../../../fixtures/voice/phrases.yaml", __DIR__)
  @phrases YamlElixir.read_from_file!(@phrases_path)
  @external_resource @phrases_path

  @items [
    {"NUT-M8", "Гайка М8"},
    {"NUT-M10", "Гайка М10"},
    {"BLT-M8-40", "Болт М8x40"},
    {"BLT-M10-60", "Болт М10x60"},
    {"WSH-8", "Шайба 8"},
    {"CBL-3x2.5", "Кабель 3x2.5"},
    {"CBL-3x1.5", "Кабель 3x1.5"}
  ]
  @locations [
    {"A-01", "Зона A-01"},
    {"B-02", "Зона B-02"},
    {"LA3", "Слева А 3"},
    {"LN2", "Слева Н 2"}
  ]

  @hard_cases ~w(letter_article zone_word shared_name transfer missing_quantity)
  @case_table %{
    "01" => ["zone_word"],
    "02" => ["transfer", "shared_name"],
    "03" => ["missing_location"],
    "04" => ["letter_article", "transfer"],
    "05" => ["shared_name"],
    "06" => ["missing_quantity"],
    "07" => ["noise"],
    "08" => ["zone_word"],
    "09" => ["letter_article"],
    "10" => ["missing_quantity"]
  }
  @router_ids ~w(ru-01 ru-04 kk-01 kk-04)

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = S.tenant!("stk-vr", ctx.names.a)
    b = S.tenant!("stk-vs", ctx.names.b)
    seed!(a.schema_name)

    Map.merge(ctx, %{a: a, b: b, tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  defp seed!(schema) do
    uom = Letflow.CatalogItemsFixture.uom!(schema, "PCS")

    for {code, name} <- @items,
        do: Letflow.CatalogItemsFixture.item!(schema, code, uom.record_id, %{"name" => name})

    for {code, name} <- @locations do
      {:ok, _} =
        Locations.create_node(
          schema,
          %{"code" => code, "name" => name, "node_kind" => "zone"},
          %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
        )
    end

    :ok
  end

  defp by_text, do: Map.new(@phrases, &{&1["text"], &1["model_answer"]})

  # The model double: answers the stored model_answer of the phrase; an unknown text raises.
  defp install_model!(table \\ by_text()) do
    VoiceDoubles.install!(model: fn text -> {:ok, Jason.encode!(Map.fetch!(table, text))} end)
  end

  defp draft!(schema, p) do
    {:ok, draft} = VoiceService.draft_text(schema, %{"text" => p["text"], "lang" => p["lang"]})
    draft
  end

  # One representation of a draft, for the atom-keyed service result and the string-keyed JSON body.
  defp norm(draft) do
    g = fn m, k -> Map.get(m, k, Map.get(m, to_string(k))) end

    code = fn
      nil -> nil
      r -> g.(r, :code)
    end

    %{
      "kind" => g.(draft, :kind),
      "items" => Enum.map(g.(draft, :items), &g.(&1, :code)),
      "location" => code.(g.(draft, :location)),
      "to_location" => code.(g.(draft, :to_location)),
      "quantity" => qty(g.(draft, :quantity)),
      "dropped" => Enum.map(g.(draft, :dropped), &g.(&1, :reason))
    }
  end

  defp qty(nil), do: nil
  defp qty(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp qty(q) when is_binary(q), do: q
  defp qty(q), do: to_string(q)

  defp expected(p),
    do: Map.take(p["expected"], ~w(kind items location to_location quantity dropped))

  defp ids(lang), do: for(p <- @phrases, p["lang"] == lang, do: p)

  describe "the typed layer: every phrase" do
    for p <- @phrases do
      @phrase p
      test "R-1 #{p["id"]}", ctx do
        install_model!()
        assert norm(draft!(ctx.a.schema_name, @phrase)) == expected(@phrase)
      end
    end
  end

  describe "the real prompt and the check" do
    test "R-2 the prompt holds the tenant's records and the transcript is the typed text", ctx do
      install_model!()
      p = Enum.find(@phrases, &(&1["id"] == "ru-01"))
      _ = draft!(ctx.a.schema_name, p)

      assert_received {:model, prompt, text}
      assert text == p["text"]

      for {code, _} <- @items ++ @locations, do: assert(prompt =~ code)
    end

    test "R-7 a defective answer: the unknown item is dropped", ctx do
      p = Enum.find(@phrases, &(&1["id"] == "ru-01"))
      bad = Map.put(p["model_answer"], "item_codes", ["NOPE-1"])
      install_model!(%{p["text"] => bad})

      d = norm(draft!(ctx.a.schema_name, p))
      assert d["items"] == []
      assert d["dropped"] == ["unknown_item"]
    end

    test "R-8 a code of tenant A is unknown in tenant B", ctx do
      {:ok, items_b} = CatalogItems.list_active(ctx.b.schema_name)
      assert items_b == []

      install_model!()
      p = Enum.find(@phrases, &(&1["id"] == "ru-01"))
      d = norm(draft!(ctx.b.schema_name, p))

      assert d["items"] == [] and d["location"] == nil
      assert "unknown_item" in d["dropped"]
      assert "unknown_location" in d["dropped"]
    end

    test "R-9 four phrases through the full router give the same draft", ctx do
      install_model!()

      for id <- @router_ids do
        p = Enum.find(@phrases, &(&1["id"] == id))

        conn =
          Plug.Test.conn(
            :post,
            S.base() <> "/voice/draft-text",
            Jason.encode!(%{"text" => p["text"], "lang" => p["lang"]})
          )
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.tok_a)
          |> Letflow.Router.call(Letflow.Router.init([]))

        assert conn.status == 200, "#{id}: #{conn.status} #{conn.resp_body}"
        assert norm(S.json(conn)) == expected(p), id
      end
    end
  end

  describe "the phrase list itself" do
    test "R-3 shape: 20 phrases, 10 per language, unique ids, every key present" do
      assert length(@phrases) == 20
      assert length(ids("ru")) == 10 and length(ids("kk")) == 10
      assert @phrases |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 20
      assert Enum.all?(@phrases, &(&1["lang"] in ["ru", "kk"]))
      assert @phrases |> Enum.map(& &1["text"]) |> Enum.uniq() |> length() == 20

      keys =
        ~w(kind item_codes location_words location_code to_location_words to_location_code quantity)

      exp = ~w(kind items location to_location quantity dropped)

      for p <- @phrases do
        assert Enum.sort(Map.keys(p["model_answer"])) == Enum.sort(keys), p["id"]
        assert Enum.sort(Map.keys(p["expected"])) == Enum.sort(exp), p["id"]
        assert is_binary(p["text"]) and p["text"] != "", p["id"]
      end
    end

    test "R-4 split: per language 6 tune and 4 heldout" do
      for lang <- ["ru", "kk"] do
        counts = lang |> ids() |> Enum.frequencies_by(& &1["split"])
        assert counts == %{"tune" => 6, "heldout" => 4}, lang
      end
    end

    test "R-5 hard-case coverage: every hard case twice per language, labels as designed" do
      for lang <- ["ru", "kk"] do
        freq = lang |> ids() |> Enum.flat_map(& &1["cases"]) |> Enum.frequencies()

        for c <- @hard_cases, do: assert(Map.get(freq, c, 0) >= 2, "#{lang} #{c}")
      end

      for p <- @phrases do
        [_, nn] = String.split(p["id"], "-")
        assert p["cases"] == Map.fetch!(@case_table, nn), p["id"]
      end
    end

    test "R-6 Kazakh entries are pending the native check" do
      for p <- ids("kk"), do: assert(p["checked_by"] == "pending_native", p["id"])
      for p <- ids("ru"), do: refute(Map.has_key?(p, "checked_by"), p["id"])
    end
  end

  describe "live mode (needs the model settings; excluded by default)" do
    @tag :voice_live
    test "L-1 the same table with the real model client", ctx do
      case Settings.model() do
        {:ok, _} ->
          results =
            for p <- @phrases do
              ok = norm(draft!(ctx.a.schema_name, p)) == expected(p)
              {p["lang"], p["split"], ok}
            end

          for {key, rows} <- Enum.group_by(results, fn {l, s, _} -> {l, s} end) do
            IO.puts(
              "voice live #{inspect(key)}: #{Enum.count(rows, &elem(&1, 2))}/#{length(rows)}"
            )
          end

        _ ->
          IO.puts("voice live: model settings are off, skipped")
      end
    end
  end
end
