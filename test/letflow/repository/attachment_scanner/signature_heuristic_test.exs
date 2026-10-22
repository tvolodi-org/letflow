defmodule Letflow.Repository.AttachmentScanner.SignatureHeuristicTest do
  @moduledoc """
  Unit tests for the default `Letflow.Repository.AttachmentScanner` adapter
  (ISS-0399, `lib/letflow/design/iss0399-attachment-content-scanning.md`
  §3.2). Pure-function unit tests -- no database, no tenant fixture (test
  developer guide §2, "pure functions first") -- `scan/2` performs no I/O.
  """

  use ExUnit.Case, async: true

  alias Letflow.Repository.AttachmentScanner.SignatureHeuristic

  @eicar_signature "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

  describe "scan/2" do
    test "returns {:ok, :clean} for ordinary content" do
      assert SignatureHeuristic.scan("hello world", "text/plain") == {:ok, :clean}
    end

    test "returns {:ok, :clean} for empty content" do
      assert SignatureHeuristic.scan("", "text/plain") == {:ok, :clean}
    end

    test "returns {:ok, :infected, \"eicar-test-signature\"} when the bytes are exactly the EICAR string" do
      assert SignatureHeuristic.scan(@eicar_signature, "text/plain") ==
               {:ok, :infected, "eicar-test-signature"}
    end

    test "returns {:ok, :infected, _} when the EICAR string is a substring of larger content" do
      raw_bytes = "leading bytes " <> @eicar_signature <> " trailing bytes"

      assert {:ok, :infected, "eicar-test-signature"} =
               SignatureHeuristic.scan(raw_bytes, "text/plain")
    end

    test "content_type is never consulted -- an EICAR payload is flagged regardless of declared content_type" do
      assert SignatureHeuristic.scan(@eicar_signature, "application/pdf") ==
               {:ok, :infected, "eicar-test-signature"}

      assert SignatureHeuristic.scan(@eicar_signature, "image/png") ==
               {:ok, :infected, "eicar-test-signature"}
    end

    test "a near-miss (one character altered) is NOT flagged -- proves this is a real substring match, not a loose heuristic" do
      near_miss = String.replace(@eicar_signature, "EICAR", "EIXAR")
      assert SignatureHeuristic.scan(near_miss, "text/plain") == {:ok, :clean}
    end

    test "never returns {:error, _} -- this adapter performs no I/O and cannot fail" do
      for bytes <- ["", "x", @eicar_signature, :binary.copy("a", 10_000)] do
        assert elem(SignatureHeuristic.scan(bytes, "text/plain"), 0) == :ok
      end
    end
  end
end
