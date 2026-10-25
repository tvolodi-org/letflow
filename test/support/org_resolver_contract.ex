defmodule Letflow.Documents.OrgResolverContract do
  @moduledoc """
  The behavioural contract of a `Letflow.Documents.OrgResolver` (REQ-542, GH #3164), as a
  function a resolver's own test calls (REQ-544 will run it against its resolver).

  `run/2` takes the resolver and `%{prefix:, active:, retired:, absent:}` (org unit ids in that
  tenant: one active, one retired, one unknown) and raises `ExUnit.AssertionError` on a breach:
  an active unit exists; a retired and an unknown unit do not; a retired unit's legal entity
  lookup never answers `:unit_not_found` (decision 0056 D1: it still resolves).
  """

  import ExUnit.Assertions

  def run(resolver, %{prefix: prefix, active: active, retired: retired, absent: absent}) do
    assert resolver.unit_exists?(prefix, active) == true
    assert resolver.unit_exists?(prefix, retired) == false
    assert resolver.unit_exists?(prefix, absent) == false

    refute resolver.legal_entity_of(prefix, retired) == {:error, :unit_not_found},
           "a retired unit must still resolve its legal entity"

    :ok
  end
end

defmodule Letflow.Documents.TestResolvers do
  @moduledoc "Resolver doubles for the document tests (REQ-542); test-only."

  defmodule Entity do
    @moduledoc "Every unit exists and belongs to one fixed legal entity; records its calls."
    @behaviour Letflow.Documents.OrgResolver

    def entity_id, do: "11111111-1111-4111-8111-111111111111"

    @impl true
    def unit_exists?(_prefix, _unit), do: true

    @impl true
    def legal_entity_of(_prefix, _unit) do
      send(self(), :legal_entity_of_called)
      {:ok, entity_id()}
    end
  end

  defmodule RetiredWrong do
    @moduledoc "Breaches the contract: a retired unit answers `:unit_not_found`."
    @behaviour Letflow.Documents.OrgResolver

    @impl true
    def unit_exists?(_prefix, _unit), do: false

    @impl true
    def legal_entity_of(_prefix, _unit), do: {:error, :unit_not_found}
  end
end
