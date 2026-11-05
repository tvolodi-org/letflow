defmodule Letflow.Modules.Stock.FormCountInv10 do
  @moduledoc """
  T-1418 (phase E, E5d): the data of official form Inv-10 (ru) / Tug-10 (kk), annex 41 of order
  No. 562, "inventory list of stock", for the ISSUED `sheet` document of a count. Pure: the output
  of `CountPaperworkSource.read_form/4` in, the data map of `Letflow.Documents.FormPrint` (form
  `inv10`) out. Layout and wording are in `priv/print_forms/inv10.json` and `messages.json`.

  Filled from Letflow: organisation name and BIN, number and date of the sheet, the order number
  and date, the cut-off date, the responsible persons of the lines (first two, the rest joined
  onto the second), the commission chair and members of the order (name and position, only the
  ones the caller's scope shows), line number, item name and code, unit, the counted quantity
  (actual) and the book quantity (accounting data), the count of rows and the total counted
  quantity. Left blank (never invented): kind of stock, balance account, prices and all sums
  (G5), the amounts in words (G10), the actual start and end of the count (the planned times are
  not the actual ones, G12), the responsible persons' statement and its date, every signature,
  the IIN (G1).
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.FormCount

  @spec data(map(), map()) :: map()
  def data(issued, names) do
    content = Map.get(issued, :content, %{})
    order_content = Map.get(issued, :order_content, %{})
    lines = FormCount.lines(content)
    {order_no, order_date} = FormCount.order(names)

    responsible =
      lines
      |> Enum.map(& &1["responsible_employee_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {first, rest} = Enum.split(responsible, 1)
    members = CountPaperwork.list_ids(order_content["member_employee_ids"])
    {m1, m_rest} = Enum.split(members, 1)

    rows = Enum.map(lines, &row(&1, names))

    FormCount.org(content, order_content, names)
    |> Map.merge(%{
      "number" => FormCount.text(issued[:number_label]),
      "date" => FormCount.date_of(issued[:issued_at], names, :issued_at),
      "order_date" => order_date,
      "order_no" => order_no,
      "cut_off" => FormCount.date_of(content["cut_off_at"], names, :cut_off_at),
      "lines" => rows,
      "total_nos" => if(rows == [], do: "", else: Integer.to_string(length(rows))),
      "total_qty" => FormCount.sum_text(Enum.map(rows, & &1["qty_fact"]))
    })
    |> Map.merge(FormCount.signature("resp1", FormCount.people(names, first)))
    |> Map.merge(FormCount.signature("resp2", FormCount.people(names, rest)))
    |> Map.merge(
      FormCount.signature("chair", FormCount.person(names, order_content["chair_employee_id"]))
    )
    |> Map.merge(FormCount.signature("member1", FormCount.people(names, m1)))
    |> Map.merge(FormCount.signature("member2", FormCount.people(names, m_rest)))
  end

  defp row(line, names) do
    line
    |> FormCount.line_cells(names)
    |> Map.merge(%{
      "qty_fact" => FormCount.text(line["counted_quantity"]),
      "qty_book" => FormCount.text(line["book_quantity"])
    })
  end
end
