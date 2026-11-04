defmodule Letflow.Modules.Stock.Documents.Kinds do
  @moduledoc """
  REQ-725 / GH #3775: the descriptor of each stock document kind, pure data, no Repo. Both the
  document context (`Letflow.Modules.Stock.Documents`) and the posting code
  (`Letflow.Modules.Stock.Documents.Posting`) read it, so a second kind (`opening`) does not copy
  either of them. `receipt` is the REQ-712 kind; `opening` is the opening balance document (REQ-725,
  posted by REQ-726 through a two-person process).

  `parse/2` dispatches the request body to the shape check of the kind: `opening` to
  `Letflow.Modules.Stock.Documents.OpeningShape`, anything else to `Letflow.Modules.Stock.Documents.Shape`
  (which answers `unknown_kind` for a kind it does not know).
  """

  alias Letflow.Modules.Stock.Documents.OpeningShape
  alias Letflow.Modules.Stock.Documents.Shape

  @type kind :: %{
          kind: String.t(),
          type_key: String.t(),
          header_type: String.t(),
          line_type: String.t(),
          cause: String.t(),
          definition: String.t(),
          post_nodes: [String.t()],
          completion_node: String.t()
        }

  @kinds %{
    "receipt" => %{
      kind: "receipt",
      type_key: "stock_receipt",
      header_type: "stock_receipt",
      line_type: "stock_receipt_line",
      cause: "receipt",
      definition: "stock_receipt",
      post_nodes: ["post"],
      completion_node: "post"
    },
    "opening" => %{
      kind: "opening",
      type_key: "stock_opening",
      header_type: "stock_opening",
      line_type: "stock_opening_line",
      cause: "opening",
      definition: "stock_opening",
      post_nodes: ["submit", "approve"],
      completion_node: "approve"
    }
  }

  @doc "The closed set of document kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: ["receipt", "opening"]

  @doc "The descriptor of `kind` (a kind name), or `nil`."
  @spec get(term()) :: kind() | nil
  def get(kind) when is_binary(kind), do: Map.get(@kinds, kind)
  def get(_other), do: nil

  @doc "The descriptor of the versioned document type `type_key`, or `nil`."
  @spec for_type_key(term()) :: kind() | nil
  def for_type_key(type_key) when is_binary(type_key),
    do: Enum.find_value(Map.values(@kinds), &(&1.type_key == type_key && &1))

  def for_type_key(_other), do: nil

  @doc """
  Parses a save or replace body; `mode` is `:create` or `{:replace, kind}`. See
  `Letflow.Modules.Stock.Documents.Shape.parse/2` for the result and the refusals.
  """
  @spec parse(term(), :create | {:replace, String.t()}) ::
          {:ok, map()} | {:error, {String.t(), map()}}
  def parse(%{"kind" => "opening"} = body, :create), do: OpeningShape.parse(body, :create)
  def parse(body, {:replace, "opening"}), do: OpeningShape.parse(body, {:replace, "opening"})
  def parse(body, mode), do: Shape.parse(body, mode)
end
