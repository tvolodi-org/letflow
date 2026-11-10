defmodule Letflow.Definitions.PackUpdatePlan do
  @moduledoc """
  The solution-pack three-way update plan (REQ-041, REQ-125, REQ-379, REQ-617), split out of
  `Letflow.Definitions` (T-1615, one slice of the code-health split of the largest files).

  Pure move: `Letflow.Definitions.compute_pack_update_plan/5`, `blocking_conflict?/1` and
  `classify_artefact/3` delegate here with the same names, arities and results, so callers do not
  change. The shared types (`artefact_input`, `classification`, `plan_entry`, `plan`) stay in
  `Letflow.Definitions`. Design: `lib/letflow/design/req041-pack-update-diff-schema.md` section 5.3.
  """

  alias Letflow.Definitions
  alias Letflow.Definitions.PackUpdateOverrides
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Repo

  @doc """
  Computes a solution-pack update three-way diff plan for one tenant's
  install of one pack against an offered incoming version, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3.

  Read-only — performs no mutation (INV-PU-5). Queries
  `solution_pack_artefact_bases` (the `base` lookup, by `(tenant_id, pack_id,
  artefact_type, artefact_id)`) and `pack_update_resolutions` (the
  `has_unresolved_conflicts` lookup, by `(tenant_id, pack_id, target_version:
  incoming_version, artefact_type, artefact_id)`) but writes neither those nor
  `solution_pack_installs`.
  It also reads the tenant's active solution-pack overrides (REQ-617,
  `Letflow.Definitions.PackUpdateOverrides.read_active/3`, the prefix derived from `tenant_id`) and
  gives each entry an `override` (`nil` when there is none); the override patch never enters the plan.

  `theirs_artefacts`/`incoming_artefacts` are caller-supplied — no real
  install/export path exists yet to source them from (SOL-01/02/03, unscoped).
  `base` is never caller-supplied: it is always looked up from
  `solution_pack_artefact_bases` by this function itself, because AC2's core
  assertion (an artefact with no matching base row classifies `:conflict`) is
  a statement about this function's own DB-lookup behavior, not about a value
  a caller chooses to omit.

  The artefact set processed is the union of `theirs_artefacts`' and
  `incoming_artefacts`' `{artefact_type, artefact_id}` keys, in first-seen
  order (theirs first, then incoming) — an artefact named in neither list is
  not represented in the returned plan at all.

  Returns `{:error, :empty_artefact_set}` when both `theirs_artefacts` and
  `incoming_artefacts` are `[]` — an empty result would otherwise be
  ambiguous between "nothing changed" and "caller passed no data by
  mistake" (mirrors REQ-036's `compute_promotion_plan/5`'s empty-plan error;
  design §5.3, flagged there as this design's own addition, not a literal
  REQ-041 acceptance-criterion mandate).
  """
  @spec compute_pack_update_plan(
          tenant_id :: Ecto.UUID.t(),
          pack_id :: String.t(),
          incoming_version :: String.t(),
          theirs_artefacts :: [Definitions.artefact_input()],
          incoming_artefacts :: [Definitions.artefact_input()]
        ) :: {:ok, Definitions.plan()} | {:error, :empty_artefact_set}
  def compute_pack_update_plan(_tenant_id, _pack_id, _incoming_version, [], []) do
    {:error, :empty_artefact_set}
  end

  def compute_pack_update_plan(
        tenant_id,
        pack_id,
        incoming_version,
        theirs_artefacts,
        incoming_artefacts
      ) do
    theirs_by_key = index_by_key(theirs_artefacts)
    incoming_by_key = index_by_key(incoming_artefacts)

    keys =
      (theirs_artefacts ++ incoming_artefacts)
      |> Enum.map(&{&1.artefact_type, &1.artefact_id})
      |> Enum.uniq()

    overrides = PackUpdateOverrides.read_active(tenant_id, pack_id, keys)

    entries =
      Enum.map(keys, fn {artefact_type, artefact_id} = key ->
        base = fetch_base(tenant_id, pack_id, artefact_type, artefact_id)
        theirs = Map.get(theirs_by_key, key)
        incoming = Map.get(incoming_by_key, key)
        classification = classify_artefact(base, theirs, incoming)

        override =
          case Map.get(overrides, key) do
            nil ->
              nil

            row ->
              PackUpdateOverrides.override_map(
                row,
                PackUpdateOverrides.evaluate(row, classification, base, incoming)
              )
          end

        resolved =
          (classification == :conflict or override_outcome(override) == :override_conflict) and
            resolution_exists?(tenant_id, pack_id, incoming_version, artefact_type, artefact_id)

        %{
          artefact_type: artefact_type,
          artefact_id: artefact_id,
          classification: classification,
          base: base,
          theirs: theirs,
          incoming: incoming,
          resolved: resolved,
          override: override
        }
      end)

    has_unresolved_conflicts = Enum.any?(entries, &blocking_conflict?/1)

    {:ok,
     %{
       tenant_id: tenant_id,
       pack_id: pack_id,
       incoming_version: incoming_version,
       entries: entries,
       has_unresolved_conflicts: has_unresolved_conflicts
     }}
  end

  @doc """
  True when a plan entry blocks apply until it is resolved: a base `:conflict`, or an active
  override whose outcome is `:override_conflict` (REQ-617), that has no resolution yet. An entry
  whose override is `:orphaned` never blocks. One predicate for the plan and for apply, so the two
  cannot drift.
  """
  @spec blocking_conflict?(Definitions.plan_entry()) :: boolean()
  def blocking_conflict?(entry) do
    outcome = override_outcome(Map.get(entry, :override))

    (entry.classification == :conflict or outcome == :override_conflict) and not entry.resolved and
      outcome != :orphaned
  end

  defp override_outcome(nil), do: nil
  defp override_outcome(%{outcome: outcome}), do: outcome

  @doc """
  Classifies one artefact's three-way diff, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3's truth table.
  Pure — no I/O, independently testable without DB fixtures or the full
  5-argument `compute_pack_update_plan/5` orchestration.

  `base`/`theirs`/`incoming` are compared by **byte-level string equality**
  over content that MUST already be canonical-JSON text by the time it
  reaches this function (sorted keys, no insignificant whitespace) —
  REQ-041's own description says this comparison uses "same normalization as
  REQ-036's plan digest," but REQ-036's `compute_plan_digest/1` is
  `status: pending` and has no shared canonicalization helper to call yet
  (design §5.4, OQ-1). This function does not parse, re-serialize, or
  normalize anything itself, and does not reimplement REQ-036's
  canonicalization as a private duplicate — that would risk drifting from
  REQ-036's real implementation once it ships.

  `nil` is never treated as equal to any other value, including another
  `nil` compared against a third non-nil value. A `nil` `base` (no matching
  `solution_pack_artefact_bases` row) always classifies `:conflict`,
  regardless of `theirs`/`incoming` — REQ-041 acceptance criterion 2 /
  INV-PU-2, "cannot prove no modification" (PRM-09 AC5).

  | `base` | `base == theirs` | `base == incoming` | Result |
  |---|---|---|---|
  | non-nil | true | true | `:unchanged` |
  | non-nil | true | false | `:clean_update` |
  | non-nil | false | true | `:local_only` |
  | non-nil | false | false | `:conflict` |
  | `nil` | — | — | `:conflict` (always) |
  """
  @spec classify_artefact(
          base :: String.t() | nil,
          theirs :: String.t() | nil,
          incoming :: String.t() | nil
        ) :: Definitions.classification()
  def classify_artefact(nil, _theirs, _incoming), do: :conflict
  def classify_artefact(base, base, base), do: :unchanged
  def classify_artefact(base, base, _incoming), do: :clean_update
  def classify_artefact(base, _theirs, base), do: :local_only
  def classify_artefact(_base, _theirs, _incoming), do: :conflict

  defp index_by_key(artefacts) do
    Map.new(artefacts, fn %{artefact_type: type, artefact_id: id, content: content} ->
      {{type, id}, content}
    end)
  end

  defp fetch_base(tenant_id, pack_id, artefact_type, artefact_id) do
    SolutionPackArtefactBase
    |> Repo.get_by(
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: artefact_type,
      artefact_id: artefact_id
    )
    |> case do
      nil -> nil
      %SolutionPackArtefactBase{base_content: base_content} -> base_content
    end
  end

  defp resolution_exists?(tenant_id, pack_id, target_version, artefact_type, artefact_id) do
    not is_nil(
      Repo.get_by(PackUpdateResolution,
        tenant_id: tenant_id,
        pack_id: pack_id,
        target_version: target_version,
        artefact_type: artefact_type,
        artefact_id: artefact_id
      )
    )
  end
end
