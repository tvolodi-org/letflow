defmodule Letflow.Modules.Stock.Documents.KindsTest do
  @moduledoc """
  Every document kind names the task whose completion posts it. `Posting.state_fields/3` reads
  `completion_node` for the `posted_by` field of every kind, so a kind without it crashes the
  document read (KeyError) once the document is posted (found merging P36 with REQ-725).
  """
  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.Documents.Kinds

  test "K-1: every kind has a completion_node; opening posts on approve, all others on post" do
    for spec <- Kinds.all() do
      expected = if spec.kind == "opening", do: "approve", else: "post"
      assert Map.get(spec, :completion_node) == expected, "kind #{spec.kind}"
    end
  end
end
