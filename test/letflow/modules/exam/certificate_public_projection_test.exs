defmodule Letflow.Modules.Exam.CertificatePublicProjectionTest do
  @moduledoc """
  REQ-357 -- unit coverage for `Letflow.Modules.Exam.CertificatePublicProjection`
  (`test/specs/REQ-357.md`) directly against the `Letflow.PublicRead.Projection`
  behaviour contract, with no HTTP round trip and no real tenant provisioning
  in the way. The end-to-end issuance -> mint -> resolve wiring (AC-6) lives
  in `test/letflow/routers/exam_sessions_test.exs`'s own REQ-357 describe
  block instead -- this file exercises `schema/0`/`project/2` as a pure unit,
  matching `test/letflow/exam/certificate_test.exs`'s own "exercise the
  context/projection module directly" precedent.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.CertificatePublicProjection, as: Projection

  defp record(field_values, attrs \\ %{}) do
    struct(
      Latest,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          record_id: Ecto.UUID.generate(),
          field_values: field_values,
          deleted: false
        },
        attrs
      )
    )
  end

  @field_values %{
    "session_id" => Ecto.UUID.generate(),
    "issued_at" => "2026-01-01T00:00:00Z",
    "candidate_name" => "Ada Lovelace",
    "exam_title" => %{"en" => "Elixir Fundamentals"},
    "score_pct" => 87.5,
    "branding_snapshot" => %{"logo_url" => "https://example.test/logo.png"}
  }

  describe "schema/0" do
    test "returns Letflow.Entities.Record.Latest -- the bucket-A current-state schema" do
      assert Projection.schema() == Latest
    end
  end

  # ── AC-1/AC-2: exact envelope `data` key set, no more, no fewer ──────────

  describe "project/2 -- exact field set" do
    test "returns exactly the five documented keys, no tenant/internal/candidate-identifier field" do
      assert {:ok, data} = Projection.project(record(@field_values), %{})

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 "candidate_name",
                 "exam_title",
                 "score_pct",
                 "issued_on",
                 "branding_snapshot"
               ])

      # Not just presence -- the exact five, with nothing named after a
      # tenant id, session id, record id, or candidate account identifier
      # (design's own exclusion table) sneaking in under a different key.
      refute Map.has_key?(data, "session_id")
      refute Map.has_key?(data, "id")
      refute Map.has_key?(data, "record_id")
      refute Map.has_key?(data, "tenant_id")
      refute Map.has_key?(data, "user_id")
      refute Map.has_key?(data, "email")
    end

    test "maps source fields to their documented output names/values" do
      assert {:ok, data} = Projection.project(record(@field_values), %{})

      assert data["candidate_name"] == "Ada Lovelace"
      assert data["exam_title"] == %{"en" => "Elixir Fundamentals"}
      assert data["score_pct"] == 87.5
      # "issued_on" is sourced from field_values["issued_at"], NOT from the
      # handle_meta issued_at -- the certificate's own issuance timestamp,
      # not the (possibly later, on a mint retry) handle-mint timestamp.
      assert data["issued_on"] == "2026-01-01T00:00:00Z"
      assert data["branding_snapshot"] == %{"logo_url" => "https://example.test/logo.png"}
    end

    test "score_pct is coerced to a float regardless of source numeric shape" do
      assert {:ok, %{"score_pct" => 100.0}} =
               Projection.project(record(Map.put(@field_values, "score_pct", 100)), %{})

      assert {:ok, %{"score_pct" => 87.5}} =
               Projection.project(
                 record(Map.put(@field_values, "score_pct", Decimal.new("87.5"))),
                 %{}
               )
    end

    test "handle_meta is ignored entirely -- project/2 is a function of the resource alone" do
      assert Projection.project(record(@field_values), %{
               issued_at: DateTime.utc_now(),
               kind: "certificate"
             }) ==
               Projection.project(record(@field_values), %{})
    end
  end

  # ── REQ-595 part B: signatory fields on the public verify projection ─────

  describe "project/2 -- signatory fields in branding_snapshot" do
    test "P12a: both signatory keys in the snapshot are exposed" do
      snapshot = %{"signatory_name" => "Dr. Jane Doe", "signatory_title" => "Chief Examiner"}
      fv = Map.put(@field_values, "branding_snapshot", snapshot)

      assert {:ok, data} = Projection.project(record(fv), %{})
      assert data["branding_snapshot"]["signatory_name"] == "Dr. Jane Doe"
      assert data["branding_snapshot"]["signatory_title"] == "Chief Examiner"
    end

    test "P12b: a snapshot without them exposes no signatory key and the top-level set is unchanged" do
      assert {:ok, data} = Projection.project(record(@field_values), %{})

      refute Map.has_key?(data["branding_snapshot"], "signatory_name")
      refute Map.has_key?(data["branding_snapshot"], "signatory_title")
      assert map_size(data) == 5
    end

    test "P12c: the moduledoc names both fields" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Projection)

      assert moduledoc =~ "signatory_name"
      assert moduledoc =~ "signatory_title"
    end
  end

  # ── AC-4: publishability predicate ───────────────────────────────────────

  describe "project/2 -- :skip on a soft-deleted certificate record" do
    test "returns :skip, never {:ok, data} carrying a valid:false shape, when deleted: true" do
      assert Projection.project(record(@field_values, %{deleted: true}), %{}) == :skip
    end

    test "returns {:ok, _} when deleted: false" do
      assert {:ok, _data} = Projection.project(record(@field_values, %{deleted: false}), %{})
    end
  end

  # ── AC-3: purity -- no Repo call, decided as a documented grep, not a
  # runtime test. See this run's TEST-DESIGNER handoff for the justification
  # (module source has zero call sites naming Letflow.Repo or Ecto.Query;
  # SECURITY-REVIEWER already independently grepped the same file for the
  # same absence). A runtime "assert zero additional queries" test would
  # only ever exercise the code path this static grep already rules out by
  # construction -- project/2's own source contains no possible call site --
  # so it would add a mechanism that could only ever pass, never a
  # regression-catching check. Recorded here (as a real, current grep, not a
  # historical claim) so the absence is re-verified on this run's actual
  # source, not merely cited.
  describe "purity (documented grep, no runtime test -- see rationale above)" do
    test "the module's CODE (moduledoc excluded) contains no Letflow.Repo / Ecto.Query reference" do
      source = File.read!("lib/letflow/modules/exam/certificate_public_projection.ex")

      # The moduledoc legitimately DISCUSSES `Repo.get/3` in prose (explaining
      # why schema/0's return value is only correct in combination with
      # Letflow.PublicRead.resolve/2's own Repo.get/3 call) -- that mention
      # belongs to documentation, not to this module's own code. Strip the
      # `@moduledoc """ ... """` block and grep only what remains: the actual
      # `@behaviour`/alias/function clauses that would execute at runtime.
      code =
        source
        |> String.split(~s(@moduledoc """), parts: 2)
        |> List.last()
        |> String.split(~s("""), parts: 2)
        |> List.last()

      refute code =~ "Repo"
      refute code =~ "Ecto.Query"
      refute code =~ "Application."
    end
  end
end
