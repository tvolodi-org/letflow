out = System.get_env("PROBE_OUT")
names = %{items: %{}, employees: %{}, org_units: %{}, locations: %{}, lots: %{}, uoms: %{}}

lines =
  for n <- 1..90, do: %{"line_no" => n, "catalog_item_id" => "x", "quantity" => "#{n * 1234}.500"}

issued = %{
  content: %{
    "kind" => "transfer",
    "header" => %{"event_time" => "2026-11-01T10:00:00Z", "note" => "Қазақша жазба әіңғүұқөһ ЁЙ"},
    "lines" => lines
  },
  number_label: "TR-1",
  version_no: 1,
  issued_at: "2026-11-01T10:00:00Z"
}

for lang <- [:ru, :kk, :en] do
  {:ok, pdf} = Letflow.Modules.Stock.DocumentPrint.build(issued, names, lang)
  File.write!("#{out}/doc-#{lang}.pdf", pdf)
end

for form <- Letflow.Documents.FormPrint.forms(), lang <- ["ru", "kk"], fmt <- [:pdf, :docx] do
  case Letflow.Documents.FormPrint.build(
         form,
         %{"rows" => [], "lines" => Enum.map(1..60, &%{"name" => "Позиция #{&1}"})},
         lang,
         fmt
       ) do
    {:ok, b} -> File.write!("#{out}/form-#{form}-#{lang}.#{fmt}", b)
    e -> IO.inspect({form, lang, fmt, e})
  end
end

codes =
  for i <- 1..30,
      do: %{
        "value" => "INV-#{1000 + i}",
        "kind" => if(rem(i, 2) == 0, do: "qr", else: "barcode"),
        "status" => "active"
      }

{:ok, pdf} = Letflow.Modules.Codes.Labels.render(codes)
File.write!("#{out}/labels.pdf", pdf)
