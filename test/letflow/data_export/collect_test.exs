defmodule Letflow.DataExport.CollectTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.DataExport
  alias Letflow.DataExport.Dataset

  defmodule Provider do
    @behaviour Letflow.DataExport.Dataset
    def dataset_ids, do: ["fake"]
    def module_id, do: "fake"
    def filters(_), do: []
    def authorize(_, _), do: :error
    def validate_filters(_, filters), do: {:ok, filters}
    def columns(_), do: []
    def fetch_page(_, pages, _, cursor), do: Map.fetch!(pages, cursor)
  end

  defp page(rows, next), do: {:ok, %{rows: rows, next: next, meta: [{"cutoff_seq", 7}]}}

  test "DX-6 cap, in-page cut, complete result and non-advancing cursor" do
    pages = %{nil => page([1, 2], :two), two: page([3, 4, 5], nil)}

    assert {:ok, %{rows: [1, 2, 3], truncated: true}} =
             DataExport.collect(Provider, "fake", {pages, %{}}, 3)

    assert {:ok, %{rows: [1, 2, 3, 4, 5], truncated: false}} =
             DataExport.collect(Provider, "fake", {pages, %{}}, 10)

    assert {:ok, %{rows: [1, 2, 3, 4, 5], truncated: false}} =
             DataExport.collect(Provider, "fake", {pages, %{}}, 5)

    stuck = %{nil => page([1], :two), two: page([2], :two)}

    assert {:ok, %{rows: [1, 2], truncated: true}} =
             DataExport.collect(Provider, "fake", {stuck, %{}}, 10)

    empty = %{nil => page([], nil)}

    assert {:ok, %{rows: [], truncated: false}} =
             DataExport.collect(Provider, "fake", {empty, %{}}, 3)

    cycling = %{nil => page([], :one), one: page([], :two), two: page([], :one)}

    assert {:ok, %{rows: [], truncated: true}} =
             DataExport.collect(Provider, "fake", {cycling, %{}}, 3)
  end

  test "DX-16 timeout discards earlier pages and query cancellation maps to timeout" do
    pages = %{nil => page([1, 2], :two), two: {:error, :ledger_read_timeout}}

    assert DataExport.collect(Provider, "fake", {pages, %{}}, 10) ==
             {:error, :ledger_read_timeout}

    error = %Postgrex.Error{postgres: %{code: :query_canceled}}
    assert Dataset.read_error(error) == :ledger_read_timeout
    assert Dataset.read_error({:error, :ledger_read_timeout}) == :ledger_read_timeout
    assert Dataset.read(fn -> raise error end) == {:error, :ledger_read_timeout}
  end

  test "DX-6 movement metadata ends at the last written leg" do
    pages = %{
      nil =>
        {:ok,
         %{
           rows: [%{posting_seq: 1}, %{posting_seq: 1}, %{posting_seq: 2}],
           next: nil,
           meta: [{"first_posting_seq", 1}, {"last_posting_seq", 2}]
         }}
    }

    assert {:ok, result} = DataExport.collect(Provider, "fake", {pages, %{}}, 2)
    assert result.truncated
    assert Map.new(result.meta) == %{"first_posting_seq" => 1, "last_posting_seq" => 1}
  end
end
