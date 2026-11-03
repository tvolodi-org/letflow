defmodule Letflow.Definitions.PromotionReviewTest do
  @moduledoc """
  Pure, no-I/O tests for REQ-035's `Ecto.Schema` module,
  `Letflow.Definitions.PromotionReview`. See `test/specs/REQ-035.md` for the full test
  design rationale and the WF-02 Step 3 scope-test verdict.

  `async: true` is safe here: this module performs no database I/O at all (it reads
  only compiled module metadata via `__info__/1`, `__schema__/1`, `Ecto.Enum`
  reflection and `Code.fetch_docs/1`) and attaches no global `:telemetry` handler
  (`docs/issues/ISS-0011.yaml`). The database-touching half of REQ-035's coverage lives
  in `test/letflow/definitions/promotion_review_migration_test.exs`, which is
  `async: false`.

  Moduledoc assertions read the compiled `Docs` chunk through `Code.fetch_docs/1`
  rather than reading the `.ex` file as a string, so they assert on what the module
  actually publishes. Whitespace is normalised before matching so re-wrapping a
  paragraph is not a failure while deleting or weakening a claim is.

  Mirrors `test/letflow/definitions/schemas_test.exs`'s established shape for REQ-027
  rather than inventing a parallel style.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.PromotionReview

  # ---------------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------------

  # A schema module's own public API, with the functions `use Ecto.Schema` generates
  # (__schema__/1,2, __struct__/0,1, __changeset__/0) filtered out. Every one of those
  # is `__`-prefixed, so the filter is exact rather than a hand-maintained deny-list.
  defp own_public_api(module) do
    module.__info__(:functions)
    |> Enum.reject(fn {name, _arity} ->
      name |> Atom.to_string() |> String.starts_with?("__")
    end)
    |> Enum.sort()
  end

  # The module's published moduledoc with runs of whitespace collapsed to single
  # spaces, so an assertion on a sentence that happens to be line-wrapped in the source
  # still matches. Deliberately pattern-matches the "documented" shape: a module whose
  # moduledoc was deleted (`:none`) or hidden (`:hidden`) raises here, which is the
  # correct outcome for acceptance criteria 3 and 4.
  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # 64 lowercase hex characters, deterministic given the counter -- never
  # :rand/:crypto.strong_rand_bytes/1. A SHA-256 hex digest is always exactly 64 chars
  # and Base.encode16(case: :lower) is always lowercase, so this can never accidentally
  # produce a value the format validation itself would reject.
  defp unique_plan_digest do
    :crypto.hash(:sha256, "req035-plan-#{System.unique_integer([:positive, :monotonic])}")
    |> Base.encode16(case: :lower)
  end

  defp valid_review_attrs do
    %{
      plan_digest: unique_plan_digest(),
      def_id: "req035-proc-#{System.unique_integer([:positive, :monotonic])}",
      serialised_plan: ~s({"nodes":[],"edges":[]}),
      requested_by: Ecto.UUID.generate()
    }
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "status as an Ecto.Enum over exactly the 6 named values"
  #
  # The DB-vs-application enforcement boundary (no CHECK constraint exists) is the
  # database half, in promotion_review_migration_test.exs. This file covers only what
  # is genuinely enforced at this layer: Ecto.Enum's own Ecto.Type callbacks.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 1 -- status is an Ecto.Enum over exactly the 6 named values" do
    test "PromotionReview's status enum is exactly the 6 named values from REQ-035, and dumps lowercase" do
      assert Ecto.Enum.values(PromotionReview, :status) == [
               :pending_review,
               :approved,
               :rejected,
               :applied,
               :failed,
               :superseded
             ]

      assert Ecto.Enum.dump_values(PromotionReview, :status) == [
               "pending_review",
               "approved",
               "rejected",
               "applied",
               "failed",
               "superseded"
             ]

      # Both partial index predicates (uq_promotion_review_active_digest's
      # "status IN ('pending_review', 'approved')" and
      # idx_promotion_review_rollback_lookup's "status IN ('applied', 'superseded')")
      # are written as lowercase string literals. If the enum ever dumped a different
      # case, both indexes would silently stop matching any row and nothing would
      # raise -- stated as its own assertion so a failure reads against that hazard.
      for dumped <- Ecto.Enum.dump_values(PromotionReview, :status) do
        assert dumped == String.downcase(dumped),
               "status dumps #{inspect(dumped)}, which is not lowercase -- both partial index predicates would stop matching rows"
      end
    end

    test "casting :status directly rejects a value outside the 6 named enum values, and accepts each of the 6" do
      # insert_changeset/2 deliberately never casts :status (design section 5.1,
      # INV-PR-3 -- a newly-inserted review is always :pending_review), so the "rejected
      # by the changeset" half of this criterion is exercised by casting :status
      # directly, which is where Ecto.Enum's actual type-level enforcement lives.
      rejected =
        Ecto.Changeset.cast(%PromotionReview{}, %{status: "not_a_real_status"}, [:status])

      refute rejected.valid?
      assert %{status: [_ | _]} = errors_on(rejected)

      for status <- [:pending_review, :approved, :rejected, :applied, :failed, :superseded] do
        accepted =
          Ecto.Changeset.cast(%PromotionReview{}, %{status: Atom.to_string(status)}, [:status])

        assert accepted.valid?,
               "expected #{status} to be accepted, errors: #{inspect(errors_on(accepted))}"

        # get_field/2, not get_change/2: casting :pending_review onto a struct whose
        # default is already :pending_review produces no recorded "change" even though
        # the cast succeeded -- get_field/2 reads the effective value either way.
        assert Ecto.Changeset.get_field(accepted, :status) == status
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2 (schema-module half): the partial unique index's behaviour
  # against real Postgres lives in promotion_review_migration_test.exs. This pins the
  # constraint-name contract that error shape depends on.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 2 -- insert_changeset/2 declares the unique constraint by index name" do
    test "insert_changeset/2 declares uq_promotion_review_active_digest by index name on [:plan_digest]" do
      changeset = PromotionReview.insert_changeset(%PromotionReview{}, valid_review_attrs())

      assert changeset.valid?

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.type == :unique and
                 constraint.constraint == "uq_promotion_review_active_digest" and
                 constraint.field == :plan_digest
             end),
             "expected a :unique constraint named uq_promotion_review_active_digest on :plan_digest, got #{inspect(changeset.constraints)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "row_version defaults to 1 and the schema module documents
  # it as an optimistic-locking column, not a plain counter"
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 3 -- row_version defaults to 1, documented as optimistic-locking" do
    test "a freshly built PromotionReview struct's row_version default is 1" do
      assert %PromotionReview{}.row_version == 1
    end

    test "insert_changeset/2 does not cast :row_version even when attrs supply one" do
      # If this were castable, a caller could insert a review with an arbitrary
      # starting row_version, undermining REQ-037's WHERE row_version = $expected
      # concurrency guard from row zero.
      changeset =
        PromotionReview.insert_changeset(
          %PromotionReview{},
          Map.put(valid_review_attrs(), :row_version, 999)
        )

      assert changeset.valid?

      refute Map.has_key?(changeset.changes, :row_version),
             "insert_changeset/2 cast :row_version, which the optimistic-lock contract forbids"
    end

    test "PromotionReview's moduledoc documents row_version as an optimistic-locking column, not a plain counter" do
      doc = normalized_moduledoc(PromotionReview)

      assert doc =~
               "row_version` is an optimistic-locking column, not a plain audit counter",
             "moduledoc does not state the optimistic-locking contract"

      assert doc =~ "It starts at 1 on insert",
             "moduledoc does not state row_version starts at 1"

      assert doc =~
               "Zero rows affected by that statement means the transition lost a concurrency race",
             "moduledoc does not state the zero-rows-affected contract"

      assert doc =~ "does not use `Ecto.Schema.optimistic_lock/2,3`",
             "moduledoc does not explain why optimistic_lock/2,3 is deliberately unused"
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "the moduledoc flags def_type's open-ended
  # text-vs-CHECK-constraint choice and the PER_TENANT-vs-GLOBAL classification as
  # explicit open questions"
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 4 -- moduledoc flags both open questions" do
    test "PromotionReview's moduledoc flags def_type's open-ended text-vs-CHECK-constraint choice as an open question" do
      doc = normalized_moduledoc(PromotionReview)

      assert doc =~ "def_type` (default \"process\") carries no enum and no CHECK constraint",
             "moduledoc does not flag def_type's open-ended text-vs-CHECK-constraint choice"

      assert doc =~ "prm-04's own Open Question 1",
             "moduledoc does not cite prm-04's Open Question 1"

      assert doc =~
               "Whether a CHECK constraint restricting the value set should be added",
             "moduledoc does not leave the CHECK-constraint question open"
    end

    test "PromotionReview's moduledoc flags the PER_TENANT-vs-GLOBAL classification as an unconfirmed open question" do
      doc = normalized_moduledoc(PromotionReview)

      assert doc =~ "PER_TENANT-vs-GLOBAL classification is NOT independently",
             "moduledoc does not flag the PER_TENANT-vs-GLOBAL classification as unconfirmed"

      assert doc =~ "1147_par01_events_partitioning.sql",
             "moduledoc does not cite the events/events_archive precedent this classification is measured against"

      assert doc =~ "REVIEWER should re-confirm this classification is correct",
             "moduledoc does not ask REVIEWER to re-confirm the classification"
    end
  end

  # ---------------------------------------------------------------------------------
  # Beyond the bare acceptance criteria -- cheap, real, not busywork (per this run's
  # brief). See test/specs/REQ-035.md's "Beyond the bare acceptance criteria" section.
  # ---------------------------------------------------------------------------------

  describe "insert_changeset/2 -- required fields and def_type's deliberate exception" do
    test "insert_changeset/2 requires plan_digest, def_id, serialised_plan and requested_by, and treats def_type as optional" do
      changeset = PromotionReview.insert_changeset(%PromotionReview{}, %{})

      refute changeset.valid?

      errors = errors_on(changeset)

      for field <- [:plan_digest, :def_id, :serialised_plan, :requested_by] do
        assert Map.has_key?(errors, field),
               "expected #{field} to be required, errors: #{inspect(errors)}"
      end

      refute Map.has_key?(errors, :def_type),
             "def_type must NOT be required -- it carries a non-nil column default (design section 5.1)"
    end

    test "def_type defaults to \"process\" when omitted, and is castable when supplied" do
      omitted = PromotionReview.insert_changeset(%PromotionReview{}, valid_review_attrs())
      assert omitted.valid?
      refute Map.has_key?(omitted.changes, :def_type)
      assert %PromotionReview{}.def_type == "process"

      supplied =
        PromotionReview.insert_changeset(
          %PromotionReview{},
          Map.put(valid_review_attrs(), :def_type, "sub_process")
        )

      assert supplied.valid?
      assert Ecto.Changeset.get_change(supplied, :def_type) == "sub_process"
    end
  end

  describe "insert_changeset/2 -- plan_digest's 64-lowercase-hex format validation" do
    test "rejects a plan_digest that is not exactly 64 lowercase hex characters" do
      for bad_digest <- [
            # too short
            String.duplicate("a", 63),
            # too long
            String.duplicate("a", 65),
            # uppercase -- not in the allowed alphabet
            String.duplicate("A", 64),
            # non-hex character
            String.duplicate("g", 64),
            # empty
            ""
          ] do
        changeset =
          PromotionReview.insert_changeset(
            %PromotionReview{},
            %{valid_review_attrs() | plan_digest: bad_digest}
          )

        refute changeset.valid?,
               "expected plan_digest #{inspect(bad_digest)} to be rejected"

        assert %{plan_digest: [_ | _]} = errors_on(changeset)
      end
    end

    test "accepts a genuine 64-char lowercase hex plan_digest" do
      changeset = PromotionReview.insert_changeset(%PromotionReview{}, valid_review_attrs())

      assert changeset.valid?
      refute Map.has_key?(errors_on(changeset), :plan_digest)
    end
  end

  describe "insert_changeset/2 -- transition-owned fields are never castable at insert time" do
    test "insert_changeset/2 does not cast approved_by, approved_at or superseded_by" do
      attrs =
        valid_review_attrs()
        |> Map.put(:approved_by, Ecto.UUID.generate())
        |> Map.put(:approved_at, ~U[2026-01-02 03:04:05.000000Z])
        |> Map.put(:superseded_by, Ecto.UUID.generate())

      changeset = PromotionReview.insert_changeset(%PromotionReview{}, attrs)

      assert changeset.valid?

      for field <- [:approved_by, :approved_at, :superseded_by] do
        refute Map.has_key?(changeset.changes, field),
               "insert_changeset/2 cast #{field}, which is REQ-037 transition-owned"
      end
    end

    test "insert_changeset/2 does not cast :status -- a newly-inserted review is always :pending_review" do
      changeset =
        PromotionReview.insert_changeset(
          %PromotionReview{},
          Map.put(valid_review_attrs(), :status, "approved")
        )

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :status)
    end
  end

  describe "PromotionReview's own public API is exactly insert_changeset/2" do
    test "no update_changeset/2 exists (design section 5.1 -- a changeset-mediated update would reintroduce the lost-update race)" do
      assert own_public_api(PromotionReview) == [insert_changeset: 2]

      refute Keyword.has_key?(PromotionReview.__info__(:functions), :update_changeset)
      refute Keyword.has_key?(PromotionReview.__info__(:functions), :changeset)
    end

    test "no @schema_prefix is pinned, and there are no Ecto associations" do
      # Every read/write must pass prefix: schema_name explicitly at call time
      # (design INV-PR-4). A compile-time @schema_prefix would defeat the
      # per-tenant mechanism silently: every test that passes prefix: explicitly
      # would still pass, which is exactly why this is asserted directly against
      # __schema__(:prefix) rather than inferred.
      assert PromotionReview.__schema__(:prefix) == nil

      # No belongs_to/has_many anywhere (design section 3.1's no-FK, no-association
      # decisions) -- every UUID-typed non-PK column is a plain field.
      assert PromotionReview.__schema__(:associations) == []
    end
  end
end
