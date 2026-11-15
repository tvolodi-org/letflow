defmodule Letflow.Documents.FormFingerprintTest do
  @moduledoc """
  T-1979 guard (owner checklist item 20): every shipped official form is generated in ru and kk
  and its structure is compared with a stored fingerprint of the Ministry reference template.

  The fingerprints (`test/fixtures/form_fingerprints/<form>.json`) hold only structure: page size,
  margins, and per table the column count, the column shares and the merged cells of the header
  block. They were produced by `scripts/forms_compare.py fingerprint` from the reference template
  of the form's annex; no template file and no template text is in the repository. To update one on
  purpose, run that command on the template again and replace the file (see
  docs/design-system/owner-review-checklist.md, item 20).

  Tolerances: page size exact; margins 60 twips (about 1 mm); the data tables (top level, 4 or more columns) must be the same
  in number, columns and header merged cells, and their column shares within 2.0 percentage points.
  Row counts are not compared (they depend on the data); the small layout tables around the data
  tables are recorded in the fingerprint but not compared.

  `@known_deviations` lists the forms whose print still differs from the template: each is a later
  slice of the same owner finding. A form on that list may differ; a form not on it must match, so a
  layout change that breaks the template fails here. A listed form that now matches fails too, so
  the list only shrinks.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Documents.FormPrint

  @script Path.expand("../../../scripts/forms_compare.py", __DIR__)
  @dir Path.expand("../../fixtures/form_fingerprints", __DIR__)
  @margin_tol 60
  @share_tol 2.0
  @wide_columns 4

  # Measured 2026-11-15 (T-1979): the owner finding of the official forms is fixed slice by slice
  # (docs/status/official-forms-vs-templates.md); DA-1, DA-3 and DA-4 already match.
  @known_deviations ~w(da2 inv8 inv10 inv18 z1 z2 z3 z5 z6)

  defp fingerprint_of(bytes) do
    path = Path.join(System.tmp_dir!(), "t1979_#{System.unique_integer([:positive])}.docx")
    File.write!(path, bytes)

    try do
      {out, 0} =
        System.cmd("python3", ["-I", "-B", @script, "fingerprint", path], stderr_to_stdout: true)

      Jason.decode!(out)
    after
      File.rm(path)
    end
  end

  defp stored(form), do: @dir |> Path.join("#{form}.json") |> File.read!() |> Jason.decode!()

  # The list of differences between the stored fingerprint and a generated one.
  defp differences(ref, gen) do
    page =
      for k <- ~w(width height orientation), ref["page"][k] != gen["page"][k] do
        "page #{k}: template #{inspect(ref["page"][k])}, print #{inspect(gen["page"][k])}"
      end

    margins =
      for k <- ~w(top right bottom left),
          abs((ref["margins"][k] || 0) - (gen["margins"][k] || 0)) > @margin_tol do
        "margin #{k}: template #{ref["margins"][k]}, print #{gen["margins"][k]} twips"
      end

    {ref_wide, gen_wide} = {wide(ref), wide(gen)}

    count =
      if length(ref_wide) == length(gen_wide),
        do: [],
        else: [
          "wide table count: template #{length(ref_wide)}, print #{length(gen_wide)}"
        ]

    tables =
      if count == [] do
        ref_wide
        |> Enum.zip(gen_wide)
        |> Enum.with_index()
        |> Enum.flat_map(fn {{r, g}, i} -> table_differences(i, r, g) end)
      else
        []
      end

    page ++ margins ++ count ++ tables
  end

  # The data tables: top level, at least @wide_columns columns. The small layout tables around them
  # (boxed facts, signature blocks) are built differently from the template by design and are not
  # part of the fingerprint comparison; they stay in the stored file as the reference record.
  defp wide(fp) do
    Enum.filter(fp["tables"], &(is_nil(&1["nested_in"]) and &1["columns"] >= @wide_columns))
  end

  defp table_differences(i, r, g) do
    cond do
      r["columns"] != g["columns"] ->
        ["table #{i}: columns template #{r["columns"]}, print #{g["columns"]}"]

      r["head_merged"] != g["head_merged"] ->
        [
          "table #{i}: header merged cells template #{inspect(r["head_merged"])}, print #{inspect(g["head_merged"])}"
        ]

      true ->
        for {a, b} <- Enum.zip(r["shares"], g["shares"]), abs(a - b) > @share_tol, into: [] do
          "table #{i}: column share template #{a}, print #{b}"
        end
        |> Enum.take(1)
    end
  end

  test "F1 every shipped form has a fingerprint and no fingerprint is orphaned" do
    files = @dir |> File.ls!() |> Enum.map(&Path.basename(&1, ".json")) |> Enum.sort()
    assert files == FormPrint.forms() -- ["messages"]

    for f <- files do
      fp = stored(f)
      assert fp["form"] == f
      assert fp["fingerprint_version"] == 1
      assert {:ok, layout} = FormPrint.layout(f)
      assert fp["annex"] == layout["annex"]
    end
  end

  test "F2 known deviations name shipped forms only" do
    assert @known_deviations -- FormPrint.forms() == []
  end

  test "F3 the comparison finds a changed margin, column share and wide table count" do
    ref = stored("z2")
    assert differences(ref, ref) == []

    bad_margin = put_in(ref, ["margins", "left"], ref["margins"]["left"] + 200)
    assert [msg] = differences(ref, bad_margin)
    assert msg =~ "margin left"

    tables = ref["tables"]
    last = List.last(tables)
    shares = [hd(last["shares"]) + 5.0 | tl(last["shares"])]
    bad_share = %{ref | "tables" => List.replace_at(tables, -1, %{last | "shares" => shares})}
    assert [msg] = differences(ref, bad_share)
    assert msg =~ "column share"

    wide_first = Enum.find_index(tables, &(&1["columns"] >= 4))
    assert [msg] = differences(ref, %{ref | "tables" => List.delete_at(tables, wide_first)})
    assert msg =~ "wide table count"
  end

  for form <- Path.wildcard(Path.join(@dir, "*.json")) |> Enum.map(&Path.basename(&1, ".json")),
      lang <- ~w(ru kk) do
    @tag timeout: 60_000
    test "F4 #{form} #{lang} print matches the template fingerprint" do
      form = unquote(form)
      lang = unquote(lang)
      {:ok, bytes} = FormPrint.build(form, %{}, lang, :docx)
      diffs = differences(stored(form), fingerprint_of(bytes))

      if form in @known_deviations do
        assert diffs != [],
               "#{form} #{lang} now matches the template: remove it from @known_deviations"
      else
        assert diffs == [],
               "#{form} #{lang} differs from the template fingerprint:\n" <>
                 Enum.join(diffs, "\n")
      end
    end
  end
end
