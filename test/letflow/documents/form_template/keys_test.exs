defmodule Letflow.Documents.FormTemplate.KeysTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.{FormPrint, FormTemplate}
  alias FormTemplate.Keys

  test "K1 closed, unique, disjoint vocabularies for every shipped form" do
    for form <- FormPrint.forms() do
      assert {:ok, k} = Keys.for_form(form)
      assert Enum.all?(k.legal ++ k.data, &Regex.match?(~r/^[a-z0-9_.]{1,64}$/, &1))
      assert Enum.uniq(k.legal) == k.legal
      assert Enum.uniq(k.data) == k.data
      assert MapSet.disjoint?(MapSet.new(k.legal), MapSet.new(k.data))
      {:ok, layout} = FormPrint.layout(form)

      for b <- layout["blocks"], b["type"] in ["text", "title", "proxy", "annex_line"] do
        refute Enum.at(String.split(b["label"], "."), 1) in ~w(label col colno group total sig cap stamp)
      end
    end
  end

  test "K2 z2 exact independent names" do
    {:ok, k} = Keys.for_form("z2")

    fields =
      ~w(org_name org_bin number date sender receiver responsible transport ttn words_qty words_sum)

    parts =
      ~w(allowed_by.position allowed_by.signature allowed_by.name chief_acc.signature chief_acc.name released.signature released.name received.signature received.name)

    columns = ~w(no name nom unit qty_plan qty_issued price sum_vat vat)

    legal =
      ~w(legal.annex legal.form_code legal.title legal.proxy legal.group.1.1 legal.total.1 legal.stamp.chief_acc) ++
        Enum.map(fields, &("legal.label." <> &1)) ++
        Enum.map(1..9, &"legal.col.1.#{&1}") ++
        Enum.map(1..9, &"legal.colno.1.#{&1}") ++
        Enum.map(~w(allowed_by chief_acc released received), &("legal.sig." <> &1)) ++
        Enum.map(parts, &("legal.cap." <> &1))

    assert Enum.sort(k.legal) == Enum.sort(legal)

    assert Enum.sort(k.data) ==
             Enum.sort(
               fields ++ Enum.map(columns, &("lines." <> &1)) ++ Enum.map(parts, &("sig." <> &1))
             )
  end

  test "K3 da2, repeated texts and independent caption counts" do
    {:ok, da2} = Keys.for_form("da2")
    for n <- ~w(lines.name lines.cost sig.filled.position), do: assert(n in da2.data)
    assert "legal.cap.filled.signature" in da2.legal
    {:ok, da1} = Keys.for_form("da1")
    assert "legal.approve_date" in da1.legal
    assert "legal.approve_date.2" in da1.legal

    counts = %{
      "da1" => 28,
      "da2" => 3,
      "da3" => 16,
      "da4" => 8,
      "inv10" => 18,
      "inv18" => 8,
      "inv8" => 21,
      "z1" => 4,
      "z2" => 9,
      "z3" => 0,
      "z5" => 12,
      "z6" => 14
    }

    for {f, count} <- counts do
      {:ok, k} = Keys.for_form(f)
      {:ok, layout} = FormPrint.layout(f)
      assert Enum.count(k.legal, &String.starts_with?(&1, "legal.cap.")) == count

      assert layout["blocks"]
             |> Enum.filter(&(&1["type"] in ["signature", "signature_table"]))
             |> Enum.map(&length(&1["parts"]))
             |> Enum.sum() == count
    end
  end

  test "K4 unknown form is refused before reading input" do
    assert Keys.for_form("nope") == :error
    assert {:error, [%{code: :unknown_form, rule: "D3"}]} = FormTemplate.check("nope", "x")
  end

  test "K6 inventory page breaks add no keys and nested legal groups are locked" do
    {:ok, inv10} = Keys.for_form("inv10")

    assert Enum.filter(inv10.legal, &String.starts_with?(&1, "legal.group.")) ==
             ~w(legal.group.1.1 legal.group.1.2)

    {:ok, inv18} = Keys.for_form("inv18")

    assert Enum.filter(hd(inv18.tables).headings, fn {key, _} ->
             String.starts_with?(key, "legal.group.")
           end) ==
             [
               {"legal.group.1.1", 4},
               {"legal.group.1.2", 4},
               {"legal.group.1.3", 6},
               {"legal.group.1.4", 8},
               {"legal.group.1.5", 8},
               {"legal.group.1.6", 11}
             ]

    for n <- 1..5, do: assert("legal.group.2.#{n}" in inv18.legal)

    for f <- ~w(inv10 inv18) do
      assert {:ok, _} =
               FormTemplate.check(
                 f,
                 Letflow.FormTemplateDocx.valid(f) |> Letflow.FormTemplateDocx.zip()
               )
    end
  end

  test "K5 pilot blocks retain field, annex and signature placeholders" do
    assert {:ok, keys} = Keys.for_form("z2")
    assert "legal.annex" in keys.legal
    assert "legal.form_code" in keys.legal

    for field <- ~w(org_name org_bin number date sender receiver responsible transport ttn) do
      assert ("legal.label." <> field) in keys.legal
      assert field in keys.data
    end

    assert Enum.map(keys.signatures, & &1["key"]) ==
             ~w(allowed_by chief_acc released received)

    for signer <- keys.signatures, part <- signer["parts"] do
      assert ("legal.sig." <> signer["key"]) in keys.legal
      assert ("legal.cap." <> signer["key"] <> "." <> part) in keys.legal
      assert ("sig." <> signer["key"] <> "." <> part) in keys.data
    end

    assert "legal.stamp.chief_acc" in keys.legal
    assert length(keys.tables) == 1

    assert {:ok, _} =
             FormTemplate.check(
               "z2",
               Letflow.FormTemplateDocx.valid() |> Letflow.FormTemplateDocx.zip()
             )
  end
end
