defmodule Letflow.Entities.RequestAccess do
  @moduledoc """
  The one gate for a caller's query-shaped request (GH #2700, INV-2, INV-5).

  `check/4` is the ONLY thing `Letflow.Routers.Entities` calls for `/query`,
  export and aggregate. It composes, in this order, each step's failure final:

    1. `RequestGuard.request_entity_types/2` -- the primary plus every join
       `entity_type` and `through` (shape errors and unwalked clauses refuse);
    2. `TypeAccess.denied_types/3` over the whole set (an error refuses);
    3. an existence read (`Allowlist.fk_defs/2`) for EVERY distinct type,
       unconditionally and with no short-circuit, so a denied and an absent
       request of the same shape do the same database work;
    4. only if steps 2-3 found nothing, `FieldPolicy.check_request/4`
       unchanged.

  A denied type and an absent type produce the SAME `{:error,
  :entity_type_not_found}` from the same exit, so no later code or renderer
  can tell them apart. Nothing is logged or audited on that refusal. The
  `exempt?` option (unredacted export) is forwarded only to step 4 and never
  lifts a type denial.
  """

  alias Letflow.Entities.FieldPolicy
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.RequestGuard
  alias Letflow.Entities.TypeAccess

  @type access_error :: :entity_type_not_found | RequestGuard.guard_error()

  @spec check(
          FieldPolicy.principal(),
          RequestGuard.request_kind(),
          map(),
          %{required(:exempt?) => boolean()}
        ) :: {:ok, RequestGuard.guard_ok()} | {:error, access_error()}
  def check(%{user_id: user_id, prefix: prefix} = principal, kind, request, %{exempt?: _} = opts) do
    with {:ok, types} <- RequestGuard.request_entity_types(request, kind),
         {:ok, denied} <- TypeAccess.denied_types(user_id, types, prefix),
         :ok <- ensure_all_visible(types, denied, prefix) do
      FieldPolicy.check_request(principal, kind, request, opts)
    end
  end

  # Reads EVERY type's definition (no `Enum.all?`/`reduce_while` early exit),
  # then makes one decision.
  defp ensure_all_visible(types, denied, prefix) do
    # MUTANT M12: existence reads skipped when a type is denied
    results =
      if MapSet.size(denied) > 0,
        do: [],
        else: Enum.map(types, &Allowlist.fk_defs(&1, prefix))

    cond do
      Enum.any?(results, &(&1 == {:error, :invalid_schema_name})) ->
        {:error, :invalid_schema_name}

      # Fail closed: anything but a loaded definition counts as absent.
      MapSet.size(denied) > 0 or not Enum.all?(results, &match?({:ok, _}, &1)) ->
        {:error, :entity_type_not_found}

      true ->
        :ok
    end
  end
end
