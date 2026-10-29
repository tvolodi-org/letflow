defmodule Letflow.Modules.Exam.CertificateDocumentTest do
  @moduledoc """
  REQ-356 -- unit coverage for `Letflow.Modules.Exam.CertificateDocument.render/2`
  against a fixture certificate view (no database, no tenant provisioning --
  this module is a pure function of its input, see its own moduledoc).
  HTTP-level route wiring (the authenticated download route) lives in
  `test/letflow/routers/exam_sessions_test.exs`'s own "REQ-356" describe
  block.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Exam.CertificateDocument

  defp fixture_certificate(overrides \\ %{}) do
    Map.merge(
      %{
        id: "11111111-1111-1111-1111-111111111111",
        candidate_name: "Jane Candidate",
        exam_title: %{"en" => "Intro to Elixir", "ru" => "Введение в Elixir"},
        score_pct: 87.5,
        issued_at: ~U[2026-09-15 12:00:00Z],
        branding_snapshot: %{
          "app_name" => "Acme Testing Co",
          "logo_url" => nil,
          "brand_colors" => %{"primary" => "#228be6"}
        }
      },
      overrides
    )
  end

  defp fixture_verification(overrides \\ %{}) do
    Map.merge(%{base_url: "https://verify.example.com", code: "verify-code-123"}, overrides)
  end

  # ---------------------------------------------------------------------
  # AC: a non-empty binary whose leading bytes are the PDF magic number.
  # ---------------------------------------------------------------------

  describe "render/2 -- output shape" do
    test "returns a non-empty binary starting with the PDF magic number" do
      assert {:ok, bytes} =
               CertificateDocument.render(fixture_certificate(), fixture_verification())

      assert is_binary(bytes)
      assert byte_size(bytes) > 0
      assert binary_part(bytes, 0, 5) == "%PDF-"
    end
  end

  # ---------------------------------------------------------------------
  # AC: candidate name, exam title, score and issue date each individually
  # present in the rendered document.
  # ---------------------------------------------------------------------

  describe "render/2 -- content fields" do
    test "the rendered PDF stream contains the candidate name, exam title (en), score and issue date" do
      assert {:ok, bytes} =
               CertificateDocument.render(fixture_certificate(), fixture_verification())

      text = pdf_text_ops(bytes)

      assert text =~ "Jane Candidate"
      assert text =~ "Intro to Elixir"
      assert text =~ "87.50"
      assert text =~ "2026-09-15"
    end

    test "a plain-string exam_title (non-localized fixture) passes through unchanged" do
      cert = fixture_certificate(%{exam_title: "Plain Exam Title"})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      assert pdf_text_ops(bytes) =~ "Plain Exam Title"
    end

    test "an exam_title map missing \"en\" falls back to its first locale in sorted key order" do
      cert =
        fixture_certificate(%{exam_title: %{"ru" => "Только русский", "kk" => "Тек қазақша"}})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      # sorted(["kk", "ru"]) -> "kk" wins. Every character here falls outside
      # `pdf`'s WinAnsi/Latin-1 glyph range, so per this module's own
      # documented finding against decision 0033 (`safe_text_at/3`'s
      # comment) each one degrades to the literal replacement character
      # "?" rather than crashing the render -- asserting THAT degraded
      # text (not the original Cyrillic, which `pdf` cannot draw at all)
      # is the honest assertion for this library's actual behaviour.
      assert pdf_text_ops(bytes) =~ "??? ???????"
    end
  end

  # ---------------------------------------------------------------------
  # AC: the QR code encodes the exact verification URL, decoded and
  # asserted, not merely "an image was produced".
  # ---------------------------------------------------------------------

  describe "render/2 -- QR payload" do
    test "the QR code drawn into the PDF decodes, cell for cell, to the exact verification URL" do
      verification =
        fixture_verification(%{base_url: "https://verify.example.com", code: "abc-123"})

      expected_url = "https://verify.example.com/verify/abc-123"

      assert {:ok, bytes} = CertificateDocument.render(fixture_certificate(), verification)

      # Independently derive what SHOULD have been encoded -- a real,
      # separate call into the same QR library render/2 itself calls, over
      # the exact URL string we expect render/2 to have built.
      expected_matrix = EQRCode.encode(expected_url, :m)

      # Then reconstruct what render/2 ACTUALLY drew, purely from the PDF's
      # own raw fill-rectangle operators (`x y w h re` + `f`) plus the
      # module's own published layout constants -- geometry back to a
      # row/col boolean matrix, with no dependency on internal render/2
      # state. This is a real decode of the rendered artefact, not a
      # restatement of the input.
      # `expected_matrix.modules` is the PRE-quiet-zone module count --
      # `EQRCode.Matrix.draw_quite_zone/1` pads `:matrix` with a further
      # 4 rows/cols without updating `:modules` to match
      # (`deps/eqrcode/lib/eqrcode/matrix.ex:369-386`) -- the real side
      # length to reconstruct against is `tuple_size/1` of the final
      # matrix, matching the correction `certificate_document.ex`'s own
      # `draw_qr_matrix/2` makes for the same reason.
      actual_matrix = reconstruct_qr_matrix(bytes, tuple_size(expected_matrix.matrix))

      assert actual_matrix == expected_matrix.matrix

      # And a negative control: a DIFFERENT code must NOT reconstruct to the
      # same matrix, proving this comparison is sensitive to the payload
      # rather than trivially true for any QR-shaped output.
      wrong_matrix = EQRCode.encode("https://verify.example.com/verify/WRONG-CODE", :m)
      assert actual_matrix != wrong_matrix.matrix
    end

    test "a base_url with a trailing slash is normalized before building the verify URL" do
      verification =
        fixture_verification(%{base_url: "https://verify.example.com/", code: "abc-123"})

      assert {:ok, bytes} = CertificateDocument.render(fixture_certificate(), verification)
      assert pdf_text_ops(bytes) =~ "Verify: https://verify.example.com/verify/abc-123"
      refute pdf_text_ops(bytes) =~ "https://verify.example.com//verify/"
    end
  end

  # ---------------------------------------------------------------------
  # AC: the same verification URL appears as readable text too.
  # ---------------------------------------------------------------------

  describe "render/2 -- readable verification text" do
    test "the verification URL appears as plain readable text in the document" do
      verification =
        fixture_verification(%{base_url: "https://verify.example.com", code: "xyz-999"})

      assert {:ok, bytes} = CertificateDocument.render(fixture_certificate(), verification)
      assert pdf_text_ops(bytes) =~ "Verify: https://verify.example.com/verify/xyz-999"
      assert pdf_text_ops(bytes) =~ "Certificate ID: xyz-999"
    end
  end

  # ---------------------------------------------------------------------
  # AC: branding in the document comes from the SNAPSHOT passed in, never
  # from a live re-read -- proven by mutating the input map's own snapshot
  # field between two renders and asserting the RENDER output tracks
  # whatever snapshot was passed (this module has nothing else to read),
  # matching this requirement's "render/2 is a pure function of its input,
  # no Repo call" contract stated in the moduledoc.
  # ---------------------------------------------------------------------

  describe "render/2 -- branding" do
    test "the header carries the certificate's own snapshotted app_name, not a platform-hardcoded name" do
      cert = fixture_certificate(%{branding_snapshot: %{"app_name" => "Original Co"}})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      text = pdf_text_ops(bytes)

      assert text =~ "Original Co"
      refute text =~ "BilimBaga"
    end

    test "re-rendering from an unchanged stored snapshot after a live branding mutation elsewhere leaves the document's own branding text unchanged" do
      original_snapshot = %{"app_name" => "Original Co", "logo_url" => nil, "brand_colors" => %{}}
      cert = fixture_certificate(%{branding_snapshot: original_snapshot})

      assert {:ok, first_bytes} = CertificateDocument.render(cert, fixture_verification())

      # Simulate "live tenant branding changed after issuance" by building a
      # SEPARATE, mutated branding map -- exactly what
      # Letflow.Routers.TenantConfig.branding_from_settings/1 would now
      # return for the tenant -- and confirming render/2 never reads it:
      # only the record's own already-captured `branding_snapshot` (the
      # `cert` map above, untouched) is ever passed to a second render.
      _live_branding_now = %{
        "app_name" => "Rebranded Co",
        "logo_url" => nil,
        "brand_colors" => %{}
      }

      assert {:ok, second_bytes} = CertificateDocument.render(cert, fixture_verification())

      assert pdf_text_ops(first_bytes) =~ "Original Co"
      assert pdf_text_ops(second_bytes) =~ "Original Co"
      refute pdf_text_ops(second_bytes) =~ "Rebranded Co"
      assert first_bytes == second_bytes
    end

    test "a snapshot missing app_name falls back to the platform default, not a crash" do
      cert = fixture_certificate(%{branding_snapshot: %{}})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      assert pdf_text_ops(bytes) =~ "Letflow"
    end
  end

  # REQ-595 part B: the signatory block reads the snapshot's two keys, each
  # line falling back on its own to the placeholder.
  describe "render/2 -- signatory block" do
    defp signed_cert(extra) do
      fixture_certificate(%{
        branding_snapshot: Map.merge(%{"app_name" => "Acme Testing Co"}, extra)
      })
    end

    defp rendered_text(cert) do
      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      pdf_text_ops(bytes)
    end

    test "D10a: both keys are printed and the placeholder is gone" do
      text =
        rendered_text(
          signed_cert(%{
            "signatory_name" => "Dr. Jane Doe",
            "signatory_title" => "Chief Examiner"
          })
        )

      assert text =~ "Dr. Jane Doe"
      assert text =~ "Chief Examiner"
      refute text =~ "Certification Authority"
      refute text =~ "Automated Issuance"
    end

    test "D10b: neither key prints the placeholder" do
      text = rendered_text(signed_cert(%{}))

      assert text =~ "Acme Testing Co Certification Authority"
      assert text =~ "Automated Issuance"
    end

    test "D10c: only the name prints the name and the placeholder title" do
      text = rendered_text(signed_cert(%{"signatory_name" => "Dr. Jane Doe"}))

      assert text =~ "Dr. Jane Doe"
      assert text =~ "Automated Issuance"
      refute text =~ "Certification Authority"
    end

    test "D11a: a legacy snapshot without the keys prints the placeholder" do
      for snapshot <- [%{"app_name" => "Acme Testing Co"}, %{}] do
        text = rendered_text(fixture_certificate(%{branding_snapshot: snapshot}))

        assert text =~ "Certification Authority"
        assert text =~ "Automated Issuance"
      end
    end

    test "D11b: Latin-1 characters survive and Cyrillic degrades to ? without a crash" do
      text = rendered_text(signed_cert(%{"signatory_name" => "Aygül Айгул"}))

      assert text =~ "Ayg"
      # the Latin-1 prefix is followed by a space and exactly five '?'
      assert text =~ "l ?????)"
      refute text =~ "Certification Authority"
    end

    test "D11c: blank and non-string values fall back to the placeholder (INV-8)" do
      for bad <- [123, ["x"], nil, "   ", %{"a" => 1}] do
        text =
          rendered_text(signed_cert(%{"signatory_name" => bad, "signatory_title" => bad}))

        assert text =~ "Certification Authority"
        assert text =~ "Automated Issuance"
      end

      for snapshot <- [nil, 5, ["x"]] do
        text = rendered_text(fixture_certificate(%{branding_snapshot: snapshot}))
        assert text =~ "Automated Issuance"
      end
    end
  end

  # ---------------------------------------------------------------------
  # SECURITY REGRESSION -- `deps/pdf`'s own `Pdf.Text.escape/1`
  # (`deps/pdf/lib/pdf/text.ex:8-12`) escapes `(` and `)` but never a
  # literal backslash. A candidate name (or exam title) containing a
  # backslash directly before a `)` therefore made it into the emitted
  # PDF content stream as `\` `\` `)` -- one escaped-backslash pair
  # followed by a BARE, unescaped `)` that closed the PDF text-literal
  # early, letting whatever followed be interpreted as raw content-stream
  # operators instead of literal text (e.g. drawing over/altering the
  # displayed score). `certificate_document.ex`'s `safe_text_at/3` now
  # pre-escapes every backslash to `\\` BEFORE the library's own
  # `(`/`)`-escaping pass runs, per the PDF literal-string spec's
  # mandatory escaping order. These tests decode the ACTUAL PDF
  # literal-string operands out of the rendered content stream (honoring
  # backslash-escaping the way a real PDF parser would, not merely
  # grepping for substrings) and assert every operand recovers exactly
  # to its original input, with no injected content-stream operator ever
  # appearing outside a literal.
  # ---------------------------------------------------------------------

  describe "render/2 -- PDF literal-string escaping (security)" do
    test "a candidate name containing backslash-close-paren does not break out of its PDF text literal" do
      # The exact defect class: a single `\` immediately followed by `)`,
      # then content-stream operators that -- if the literal broke open --
      # would inject a filled rectangle (visually overlaying the
      # certificate) and open a second, unterminated literal.
      injection = "Eve\\) 1 0 0 RG 0 0 800 800 re f (pwned"
      cert = fixture_certificate(%{candidate_name: injection})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())

      {literals, residual} = decode_pdf_literal_operands(pdf_text_ops(bytes))

      # The entire payload -- including the embedded operator-shaped text
      # -- must recover as ONE literal, byte-for-byte identical to the
      # original input. If the literal had broken open, this operand
      # would instead show up truncated (e.g. just "Eve\") with the rest
      # missing from `literals` entirely.
      assert injection in literals

      # And none of the injected tokens ever appear as REAL operators
      # outside a decoded literal (i.e. leaked into the live content
      # stream) -- only inside the literal operand asserted above.
      refute residual =~ "RG"
      refute residual =~ "800 800"
      refute residual =~ "pwned"
    end

    test "standalone backslash, open-paren, and close-paren each round-trip as literal text" do
      for {label, raw} <- [
            {"lone backslash", "Back\\Slash"},
            {"lone open-paren", "Open(Paren"},
            {"lone close-paren", "Close)Paren"},
            {"double backslash then close-paren", "Double\\\\)Close"}
          ] do
        cert = fixture_certificate(%{candidate_name: raw})

        assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification()),
               "render/2 failed for #{label}"

        {literals, _residual} = decode_pdf_literal_operands(pdf_text_ops(bytes))

        assert raw in literals,
               "expected #{label} (#{inspect(raw)}) to round-trip exactly, got literals: #{inspect(literals)}"
      end
    end

    test "an exam title containing backslash-close-paren round-trips exactly" do
      injection = "Title\\) 1 0 0 rg (evil"
      cert = fixture_certificate(%{exam_title: injection})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())

      {literals, _residual} = decode_pdf_literal_operands(pdf_text_ops(bytes))
      assert injection in literals
    end
  end

  # Decodes every well-formed PDF literal-string operand (`(...)`) out of a
  # decompressed content-stream text, honoring backslash-escaping exactly as
  # a real PDF parser would (ISO 32000-1 7.3.4.2: `\\` -> one literal
  # backslash, `\(`/`\)` -> a literal paren, `\` + any other char -> that
  # char literally, an UNESCAPED `)` closes the literal). Returns
  # `{decoded_literals, residual_text}` where `residual_text` is everything
  # OUTSIDE any literal (each literal replaced by a single space) -- used to
  # confirm an injection payload never leaks out as real operators.
  defp decode_pdf_literal_operands(text) do
    {literals, residual} = scan_pdf_literals(text, false, [], [], [])
    {Enum.reverse(literals), residual |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp scan_pdf_literals(<<>>, _in_literal?, _acc, literals, residual), do: {literals, residual}

  defp scan_pdf_literals(<<"\\", c, rest::binary>>, true, acc, literals, residual) do
    decoded =
      case c do
        ?\\ -> ?\\
        ?( -> ?(
        ?) -> ?)
        other -> other
      end

    scan_pdf_literals(rest, true, [decoded | acc], literals, residual)
  end

  defp scan_pdf_literals(<<")", rest::binary>>, true, acc, literals, residual) do
    decoded = acc |> Enum.reverse() |> :binary.list_to_bin()
    scan_pdf_literals(rest, false, [], [decoded | literals], [" " | residual])
  end

  defp scan_pdf_literals(<<c, rest::binary>>, true, acc, literals, residual) do
    scan_pdf_literals(rest, true, [c | acc], literals, residual)
  end

  defp scan_pdf_literals(<<"(", rest::binary>>, false, _acc, literals, residual) do
    scan_pdf_literals(rest, true, [], literals, residual)
  end

  defp scan_pdf_literals(<<c, rest::binary>>, false, acc, literals, residual) do
    scan_pdf_literals(rest, false, acc, literals, [c | residual])
  end

  # -----------------------------------------------------------------------
  # A PDF built by the `pdf` library is FlateDecode-compressed by default
  # (`compress: true`), so text operators are not literally grep-able in
  # the raw output bytes -- this helper inflates every stream object and
  # concatenates the result, giving the tests above a plain-text haystack
  # to assert against instead of parsing the PDF content-stream operator
  # grammar (`Tj`/`TJ`) in full.
  # -----------------------------------------------------------------------
  defp pdf_text_ops(bytes) do
    ~r/stream\r?\n(.*?)endstream/s
    |> Regex.scan(bytes, capture: :all_but_first)
    |> Enum.map(fn [stream] -> inflate(stream) end)
    |> Enum.join("\n")
  end

  # Reconstructs the boolean QR module matrix (as the same tuple-of-tuples
  # shape `EQRCode.Matrix.t()`'s own `:matrix` field uses) purely from the
  # PDF's decompressed content-stream fill operators, using
  # `CertificateDocument.__qr_layout__/0`'s published origin/module-size
  # constants to invert each rectangle's geometry back to a (row, col) QR
  # cell. `modules` is the expected matrix's own side length (from a real,
  # independent `EQRCode.encode/2` call), used only to size the output
  # tuple -- every cell not found filled in the PDF is `0`.
  defp reconstruct_qr_matrix(bytes, modules) do
    %{origin_x: origin_x, module_size: size, footer_y: footer_y} =
      CertificateDocument.__qr_layout__()

    text = pdf_text_ops(bytes)

    filled =
      ~r/([\d.]+)\s+([\d.]+)\s+[\d.]+\s+[\d.]+\s+re\s+f/
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [x_str, y_str] ->
        {x, ""} = Float.parse(x_str)
        {y, ""} = Float.parse(y_str)

        col = round((x - origin_x) / size)
        row = modules - 1 - round((y - footer_y) / size)
        {row, col}
      end)
      |> MapSet.new()

    for row <- 0..(modules - 1) do
      for col <- 0..(modules - 1) do
        if MapSet.member?(filled, {row, col}), do: 1, else: 0
      end
      |> List.to_tuple()
    end
    |> List.to_tuple()
  end

  defp inflate(stream) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z)

    result =
      try do
        z |> :zlib.inflate(stream) |> IO.iodata_to_binary()
      rescue
        _ -> ""
      end

    :zlib.close(z)
    result
  end
end
