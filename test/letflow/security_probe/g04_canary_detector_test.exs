defmodule Letflow.SecurityProbe.G04CanaryDetectorTest do
  @moduledoc """
  G-04 detector: every needle form is found, near-misses are not, the
  normalisation and container steps work, the exceptions loader refuses what the
  design forbids, a stale baseline fails. No database. The seeded failing cases
  (non-vacuity) are the `seeded:` tests: each plants a canary straight into a
  surface and asserts the verdict names that surface and form.

  Class table: `docs/security-probes/G-04.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag :unit
  @moduletag probe_cost_s: 2

  require Logger

  alias Letflow.SecurityProbe.G04Canary, as: G

  @exceptions Path.expand("../../fixtures/security_probes/g04/exceptions.txt", __DIR__)

  defp hit_forms(bytes, canary, part \\ "any"),
    do: G.scan([{"S1", "t", part, bytes}], canary) |> Enum.map(& &1.form)

  describe "the canary" do
    test "core is deterministic, starts with q, 16 unreserved chars, unique per case" do
      assert G.core("C-01") == G.core("C-01")
      assert G.core("C-01") != G.core("C-02")
      assert G.core("C-01") =~ ~r/\Aq[a-z2-7]{15}\z/
    end

    test "every kind embeds its core" do
      for kind <- G.kinds() do
        c = G.new("C-99", kind)
        assert String.contains?(c.value, c.core), "#{kind}"
      end
    end
  end

  describe "seeded: every needle form is caught" do
    setup do
      {:ok, c: G.new("SEED-1", :email)}
    end

    test("exact", %{c: c}, do: assert(:exact in hit_forms("x " <> c.value <> " y", c)))

    test "core after percent, double percent, JSON and entity encoding", %{c: c} do
      for enc <- [
            URI.encode_www_form(c.value),
            URI.encode_www_form(URI.encode_www_form(c.value)),
            Jason.encode!(c.value)
            |> String.replace("@", "\\u0040")
            |> String.replace("+", "\\u002b"),
            String.replace(c.value, "@", "&#64;")
          ] do
        assert hit_forms(enc, c) != [], enc
      end
    end

    test "core with case folding and a zero-width space", %{c: c} do
      assert hit_forms(String.upcase(c.value), c) != []
      z = String.slice(c.value, 0, 6) <> "​" <> String.slice(c.value, 6..-1//1)
      assert hit_forms(z, c) != []
    end

    test "partial: a 12-char truncation", %{c: c} do
      assert hit_forms("prefix " <> String.slice(c.core, 2, 12), c) != []
    end

    test "base64 std and url-safe of the value, embedded", %{c: c} do
      assert :base64 in hit_forms("tok=" <> Base.encode64("pad" <> c.value) <> ";", c)
      assert :base64 in hit_forms(Base.url_encode64(c.value, padding: false), c)
    end

    test "hex of the value", %{c: c} do
      assert :hex in hit_forms("\\x" <> Base.encode16(c.value, case: :lower), c)
    end

    test "unsalted sha256 of the value", %{c: c} do
      assert :hashed in hit_forms(Base.encode16(:crypto.hash(:sha256, c.value), case: :lower), c)
    end

    test "near-miss: a 9-char window and a masked form do NOT hit", %{c: c} do
      assert hit_forms(String.slice(c.core, 0, 9), c) == []
      assert hit_forms("l***@example.test https://***@127.0.0.1/x", c) == []
      assert hit_forms("admin_email secret_ref count=3", c) == []
    end

    test "another case's canary is not a hit", %{c: c} do
      other = G.new("SEED-2", :email)
      assert hit_forms(other.value, c) == []
    end
  end

  describe "containers" do
    test "a zip member (xlsx shape) is read" do
      c = G.new("SEED-ZIP", :name)

      {:ok, {_, zip}} =
        :zip.create(~c"x.xlsx", [{~c"xl/sharedStrings.xml", "<si>" <> c.core <> "</si>"}], [
          :memory
        ])

      assert hit_forms(zip, c) != []
    end

    test "a PDF FlateDecode stream is inflated" do
      c = G.new("SEED-PDF", :name)

      pdf =
        "%PDF-1.4\n1 0 obj\nstream\n" <>
          :zlib.compress("BT (" <> c.core <> ") Tj ET") <> "\nendstream\nendobj"

      assert hit_forms(pdf, c) != []
      assert hit_forms("%PDF-1.4\nstream\nnot-flate\nendstream", c) == []
    end
  end

  describe "S4 log sink" do
    test "seeded: debug message and metadata are captured" do
      assert Logger.level() == :debug
      c = G.new("SEED-LOG", :email)
      sink = G.attach_sink()
      Logger.debug("leak #{c.value}")
      Logger.info("meta", data: c.core)
      items = G.drain_sink(sink)
      G.detach_sink(sink)
      hits = G.scan(items, c)
      assert length(hits) >= 2, inspect(hits)
      assert Enum.all?(hits, &(&1.surface == "S4"))
    end
  end

  describe "exceptions list" do
    test "the shipped file loads and passes its own rules" do
      assert {:ok, rows} = G.load_exceptions(@exceptions)
      refute rows == []
      refute Enum.any?(rows, &(&1.id == "E-09"))
    end

    test "loader refuses a legit row for secret/token" do
      for kind <- ["secret", "token"] do
        assert {:error, [msg]} =
                 G.load_exceptions([
                   "X-1 | legit | #{kind} | S7 | C-10 | request_headers | r | T-1"
                 ])

        assert msg =~ "secret/token"
      end
    end

    test "loader refuses a personal legit row with case * outside S1/S5/S10" do
      assert {:error, errs} = G.load_exceptions(["X-2 | legit | email | S9 | * | any | r | T-1"])
      assert Enum.any?(errs, &(&1 =~ "case *"))
    end

    test "loader refuses an any/other_* part on a personal S1/S5/S10 row" do
      assert {:error, _} =
               G.load_exceptions(["X-3 | legit | email | S5 | C-03 | other_column | r | T-1"])

      assert {:error, _} = G.load_exceptions(["X-3 | legit | email | S1 | C-03 | any | r | T-1"])
    end

    test "loader refuses a part outside the vocabulary" do
      assert {:error, _} =
               G.load_exceptions(["X-4 | legit | header | S2 | C-24 | body_2xx_other | r | T-1"])
    end
  end

  describe "verdict" do
    setup do
      {:ok, rows} = G.load_exceptions(@exceptions)
      {:ok, rows: rows}
    end

    defp hit(case_id, kind, surface, part),
      do: %{case_id: case_id, kind: kind, surface: surface, locator: "l", part: part, form: :core}

    test "seeded: an unlisted hit fails", %{rows: rows} do
      v = G.verdict([hit("C-02", :email, "S4", "any")], rows)
      assert [%{surface: "S4"}] = v.unlisted
    end

    test "seeded: a personal canary in audit action, resource_id or an unauthorised 2xx body fails despite E-01/E-03",
         %{rows: rows} do
      for {s, p} <- [{"S5", "action"}, {"S5", "resource_id"}, {"S1", "body_2xx_other"}] do
        v = G.verdict([hit("C-03", :email, s, p)], rows)
        assert length(v.unlisted) == 1, "#{s}/#{p}"
      end
    end

    test "a listed legit hit is excused", %{rows: rows} do
      v = G.verdict([hit("C-03", :email, "S1", "body_2xx_authorised")], rows)
      assert v.unlisted == [] and length(v.excused) == 1
    end

    test "a secret hit anywhere fails, even on a surface with a row for other kinds", %{
      rows: rows
    } do
      v = G.verdict([hit("C-10", :secret, "S7", "request_headers")], rows)
      assert length(v.unlisted) == 1
    end

    test "ratchet: a baseline row matching no hit is stale; a legit row is only a warning" do
      {:ok, rows} =
        G.load_exceptions([
          "B-1 | baseline | email | S4 | C-01 | any | r | T-1",
          "E-1 | legit | header | S7 | C-10 | request_headers | r | T-1"
        ])

      v = G.verdict([], rows)
      assert [%{id: "B-1"}] = v.stale
      assert [%{id: "E-1"}] = v.warnings
    end
  end

  describe "obfuscated forms: every character of the core encoded (kills the decode steps)" do
    setup do
      c = G.new("OBF-1", :name)
      {:ok, c: c, chars: String.to_charlist(c.core)}
    end

    test "percent, double percent, JSON \\u, decimal and hex entities", %{c: c, chars: chars} do
      pct = Enum.map_join(chars, &("%" <> Base.encode16(<<&1>>)))
      pct2 = Enum.map_join(chars, &"%25#{Base.encode16(<<&1>>)}")
      json = Enum.map_join(chars, &"\\u00#{Base.encode16(<<&1>>)}")
      dec = Enum.map_join(chars, &"&##{&1};")
      hex = Enum.map_join(chars, &"&#x#{Integer.to_string(&1, 16)};")

      for {label, form} <- [pct: pct, pct2: pct2, json: json, dec: dec, hex: hex] do
        refute c.core =~ form
        assert hit_forms("x=" <> form, c) != [], "#{label} form not detected"
      end
    end

    test "zero-width characters inside the core and a fullwidth form", %{c: c} do
      split = c.core |> String.graphemes() |> Enum.join(<<0x200B::utf8>>)
      assert hit_forms(split, c) != []
      full = for <<ch <- c.core>>, into: "", do: <<ch - 0x21 + 0xFF01::utf8>>
      assert hit_forms(full, c) != []
    end
  end

  describe "SF-01 bounds: the scan fails closed, it never skips" do
    test "an input one byte over the cap raises" do
      big = :binary.copy("a", G.max_input_bytes() + 1)
      assert_raise G.TooLarge, fn -> G.variants(big) end
      assert is_list(G.variants(:binary.copy("a", 1024)))
    end

    test "a zip with more members than the cap raises before any inflate" do
      files = for i <- 1..201, do: {~c"f#{i}", "x"}
      {:ok, {_, zip}} = :zip.create(~c"a.zip", files, [:memory])
      assert_raise G.TooLarge, ~r/members/, fn -> G.variants(zip) end
    end

    test "a zip bomb (declared size over the cap) raises" do
      {:ok, {_, zip}} =
        :zip.create(~c"a.zip", [{~c"z", :binary.copy(<<0>>, G.max_expanded_bytes() + 1)}], [
          :memory
        ])

      assert byte_size(zip) < G.max_input_bytes()
      assert_raise G.TooLarge, fn -> G.variants(zip) end
    end

    test "a nested zip chain deeper than the cap raises" do
      nested =
        Enum.reduce(1..5, "x", fn _, acc ->
          {:ok, {_, z}} = :zip.create(~c"a.zip", [{~c"in", acc}], [:memory])
          z
        end)

      assert_raise G.TooLarge, ~r/nesting/, fn -> G.variants(nested) end
    end

    test "an inflated PDF stream over the cap raises" do
      stream = :zlib.compress(:binary.copy(<<0>>, G.max_expanded_bytes() + 1))
      pdf = "%PDF-1.4\nstream\n" <> stream <> "\nendstream\n"
      assert byte_size(pdf) < G.max_input_bytes()
      assert_raise G.TooLarge, ~r/PDF/, fn -> G.variants(pdf) end
    end
  end
end
