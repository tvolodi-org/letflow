defmodule Letflow.Modules.Exam.CertificateDocument do
  @moduledoc """
  REQ-356 -- renders a `Letflow.Modules.Exam.Certificate` record's `certificate_view()`
  into PDF bytes, with an embedded QR code (plus readable verification URL)
  in the footer. Ported for LAYOUT AND CONTENT ONLY from
  `backend/internal/certificates/pdf.go`'s `GeneratePDF`
  (FR-BB44, called from FR-BB43) --
  `c:\\Users\\tvolo\\dev\\ai-dala\\BilimBaga\\backend\\internal\\certificates\\pdf.go`.
  Per this stage's own "the Go code does not transfer" rule, only the
  content set and layout intent are ported: header, title, candidate name,
  exam title, score, issue date, signatory block, and a footer QR code plus
  readable verification URL.

  ## Libraries -- decision `0033`, landed here (REQ-356's own scope)

  `mix.exs` gains exactly the two dependencies
  `docs/migration/decisions/0033-pdf-qr-rendering-dependencies.md` chose,
  and no others: `pdf` (`atimberlake/pdf-elixir`, pure Elixir, MIT) for PDF
  byte generation, and `eqrcode` (pure Elixir, MIT) for QR encoding. Both
  proved able to do the CORE thing that record assumed (render positioned
  text/rectangles into PDF bytes in-process; encode a string as a QR module
  matrix) -- re-verified against their real APIs in `deps/pdf/lib/pdf.ex`
  and `deps/eqrcode/lib/eqrcode.ex` while building this module, not merely
  assumed from the record's prose. No substitute library was adopted.

  **One finding DOES reopen decision `0033`, reported rather than worked
  around**: `pdf` has no Unicode/non-Latin-1 glyph rendering path at all (see
  "Glyph coverage finding" below, at `safe_text_at/3`'s own comment) -- a gap
  decision `0033` did not evaluate because it never considered glyph
  coverage as a decision criterion. This does not block REQ-356 (this
  module degrades gracefully to a `"?"` placeholder rather than crashing,
  per `encoding_replacement_character`), but it is a real, load-bearing gap
  for this vertical's Cyrillic-script locales (`kk`/`ru`) that a follow-up
  requirement must address -- see this requirement's close-out.

  Per decision `0033` section 4, the two compose directly with no
  intermediate rasterised-image round trip: `EQRCode.encode/2` returns a
  `EQRCode.Matrix.t()` whose `:matrix` field is a tuple-of-tuples of
  `1`/`0` values (one QR module per cell), and this module iterates that
  matrix directly, filling one `Pdf.rectangle/3` + `Pdf.fill/1` per `1`
  cell at a fixed module size -- never decoding a PNG/SVG byte string back
  into pixels.

  ## Storage -- regenerated on every request, nothing persisted (REQ-356's own AC)

  This module is a **pure function of its input** — no `Letflow.Repo` call,
  no read of `Letflow.Repository.EntityAttachments` or
  `Letflow.Repository.Attachments`, no write of PDF bytes anywhere. The
  source's own FR-BB43 Notes/Out-of-Scope sections rule out storing PDF
  binaries and this module preserves that shape rather than reopening it:
  every call to `render/2` produces a fresh binary from the caller-supplied
  certificate view and verification input, and the caller
  (`Letflow.Modules.Exam.Router`'s download route) discards it after
  sending the HTTP response. Nothing under `lib/letflow/exam/` or
  `lib/letflow/routers/` ever writes a certificate PDF to disk, an
  attachment record, or any other persistence layer. See this
  requirement's close-out for the full "storage vs. regenerate" statement
  decision `0033`/REQ-355's own moduledoc anticipate.

  ## Branding -- read from the SNAPSHOT only, never re-derived (REQ-355's own guarantee, preserved here)

  `render/2` takes the certificate's OWN `branding_snapshot` field (captured
  once, at first issuance, by `Letflow.Modules.Exam.Certificate.capture_branding_snapshot/1`)
  as plain input data -- this module makes no `Letflow.Repo` call and reads
  no live `Letflow.Identity.Tenant` row, so a branding change made after
  issuance cannot affect a re-rendered document. This is the same property
  `certificate_test.exs`'s branding-mutation test already proves for the
  ISSUANCE half; `certificate_document_test.exs`'s own branding-mutation
  test proves it again for the RENDER half specifically (mutate branding,
  re-render from the SAME stored snapshot, assert byte-identical/field-
  identical output).

  ## Header -- questioned, not copied, from the source (REQ-356's own required deviation)

  The source hardcodes `"BilimBaga"` into the header's top-right corner
  regardless of tenant. That is wrong for a multi-tenant platform and is
  NOT ported: this module's header carries only the certificate's own
  snapshotted `branding_snapshot["app_name"]` (falling back to `"Letflow"`
  only if the snapshot is somehow missing the key, matching
  `Letflow.Routers.TenantConfig`'s own `@default_app_name`) -- no second,
  platform-hardcoded product name is drawn anywhere on the page. The
  source's `snap.LogoBase64` branch (an embedded base64 PNG logo) is also
  NOT ported: Letflow's own branding snapshot
  (`priv/packs/bilimbaga/entity_definitions/certificate.json`'s
  `branding_snapshot` field, sourced from
  `Letflow.Routers.TenantConfig.branding_from_settings/1`) carries
  `"logo_url"` (a URL string), never embedded image bytes -- fetching that
  URL over the network at render time would violate this module's own
  "pure function, no I/O" shape and turn a from-storage regeneration into a
  network-dependent one. The header therefore always renders the app-name
  text path; adding real logo-image rendering is future work gated on a
  requirement that decides how (or whether) to fetch/cache the logo bytes,
  not a silent scope absorption here.

  ## Verification code -- explicit caller input, not a persisted field (REQ-356/REQ-357 boundary)

  `Letflow.Modules.Exam.Certificate`'s entity definition deliberately has NO
  `verification_code` field (REQ-355's own scope fence: minting a real,
  non-guessable capability handle per decision `0028` is REQ-357's job, via
  REQ-352's authenticated writer). This module therefore takes the
  verification code as an explicit, caller-supplied argument
  (`verification.code`) rather than reading it off the certificate record --
  decision `0033` section 4 leaves the renderer's own function signature to
  this requirement, and this is the shape chosen so `render/2` needs no
  change when a real handle is available. The ONLY caller
  (`Letflow.Modules.Exam.Router`'s download route, REQ-592) passes the
  plaintext of a `Letflow.PublicRead` handle freshly minted for EVERY
  download, so the QR and the printed "Verify:" line resolve through
  `GET /api/public/certificate/:handle`. Consequently `render/2` output
  differs from one download to the next (not byte-identical). A PDF
  downloaded before REQ-592 carries the certificate's record id, which
  resolves nothing; the owner downloads again to get a working code, and
  certificates issued earlier get one on their next download.
  """

  alias EQRCode
  alias EQRCode.Matrix

  @page_size {:a4, :landscape}
  # A4 landscape in Pdf points (Pdf.Paper.size/1: {0, 0, 842, 595}).
  @page_width 842
  @page_height 595
  @margin 28

  @default_app_name "Letflow"

  @qr_module_size 2.2
  @qr_origin_x @page_width - @margin - 90

  @type certificate_view :: %{
          id: String.t(),
          candidate_name: String.t(),
          exam_title: term(),
          score_pct: number(),
          issued_at: DateTime.t(),
          branding_snapshot: map()
        }

  @type verification :: %{base_url: String.t(), code: String.t()}

  @doc """
  Renders `certificate` (a `Letflow.Modules.Exam.Certificate.certificate_view()`, or
  any map carrying the same keys) into PDF bytes, embedding a QR code (and
  matching readable text) that encodes `verification.base_url <> "/verify/"
  <> verification.code`.

  Pure -- no database call, no network call, no filesystem write. Returns
  `{:error, reason}` only if the `pdf`/`eqrcode` libraries themselves raise
  (e.g. an over-length QR payload) rather than letting that exception
  propagate to an HTTP handler.
  """
  @spec render(certificate_view(), verification()) :: {:ok, binary()} | {:error, term()}
  def render(certificate, %{base_url: base_url, code: code})
      when is_map(certificate) and is_binary(base_url) and is_binary(code) do
    verify_url = build_verify_url(base_url, code)

    bytes =
      Pdf.build([size: @page_size, compress: true], fn pdf ->
        pdf
        |> draw_header(certificate)
        |> draw_title()
        |> draw_candidate_block(certificate)
        |> draw_signatory(certificate)
        |> draw_qr_and_verify_text(verify_url, code)
        |> Pdf.export()
      end)

    {:ok, bytes}
  rescue
    error -> {:error, error}
  end

  @spec build_verify_url(String.t(), String.t()) :: String.t()
  defp build_verify_url(base_url, code) do
    String.trim_trailing(base_url, "/") <> "/verify/" <> code
  end

  @doc false
  # Test-only accessor for `certificate_document_test.exs`'s QR-payload
  # reconstruction test -- exposes the exact layout constants
  # `draw_qr_matrix/2` uses, so that test can independently reconstruct the
  # boolean module matrix from the PDF's own raw `re`/`f` fill operators
  # (geometry -> row/col) and compare it, cell for cell, against
  # `EQRCode.encode/2`'s real output for the expected URL -- a real decode
  # check, not merely "an image was produced". Kept in lock-step with the
  # constants below by construction (this function reads the same module
  # attributes `draw_qr_matrix/2` does; there is no second, hand-copied set
  # of numbers to drift).
  @spec __qr_layout__() :: %{origin_x: number(), module_size: number(), footer_y: number()}
  def __qr_layout__ do
    %{origin_x: @qr_origin_x, module_size: @qr_module_size, footer_y: 60}
  end

  # ── Header strip -- app name only, see moduledoc "Header" ────────────────

  defp draw_header(pdf, certificate) do
    app_name = branding_app_name(certificate)

    pdf
    |> Pdf.set_font("Helvetica", 14, bold: true)
    |> safe_text_at({@margin, @page_height - @margin}, app_name)
  end

  defp branding_app_name(%{branding_snapshot: %{"app_name" => app_name}})
       when is_binary(app_name) and app_name != "" do
    app_name
  end

  defp branding_app_name(_certificate), do: @default_app_name

  # ── Title ──────────────────────────────────────────────────────────────

  defp draw_title(pdf) do
    center_y = @page_height - 90

    pdf
    |> Pdf.set_font("Helvetica", 28, bold: true)
    |> centered_text_at(center_y, "Certificate of Completion")
  end

  # ── Candidate / exam / score / date block ─────────────────────────────

  defp draw_candidate_block(pdf, certificate) do
    candidate_name = Map.fetch!(certificate, :candidate_name)
    exam_title = resolve_exam_title(Map.fetch!(certificate, :exam_title))
    score_pct = Map.fetch!(certificate, :score_pct)
    issued_at = Map.fetch!(certificate, :issued_at)

    pdf
    |> Pdf.set_font("Helvetica", 22)
    |> centered_text_at(@page_height - 140, candidate_name)
    |> Pdf.set_font("Helvetica", 14)
    |> centered_text_at(@page_height - 165, "for successfully completing")
    |> Pdf.set_font("Helvetica", 18, bold: true)
    |> centered_text_at(@page_height - 190, exam_title)
    |> Pdf.set_font("Helvetica", 12)
    |> centered_text_at(
      @page_height - 215,
      "Score: #{format_score(score_pct)}%          Issued: #{format_date(issued_at)}"
    )
  end

  # `exam_title` is REQ-355's own `:localized_text` map snapshot (all
  # locales) -- pick "en" when present, else the first locale in sorted key
  # order, so rendering never crashes on a map missing "en". A plain string
  # (a test fixture, or a future non-localized caller) passes through as-is.
  @spec resolve_exam_title(term()) :: String.t()
  defp resolve_exam_title(title) when is_binary(title), do: title

  defp resolve_exam_title(title) when is_map(title) and map_size(title) > 0 do
    case Map.fetch(title, "en") do
      {:ok, text} -> text
      :error -> title |> Map.keys() |> Enum.sort() |> List.first() |> then(&Map.fetch!(title, &1))
    end
  end

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 2)
  defp format_score(score) when is_integer(score), do: format_score(score * 1.0)

  defp format_date(%DateTime{} = dt) do
    dt
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  # ── Signatory block (bottom-left) ─────────────────────────────────────

  defp draw_signatory(pdf, certificate) do
    %{"signatory_name" => name, "signatory_title" => title} = signatory(certificate)

    pdf
    |> Pdf.line({@margin, 90}, {@margin + 200, 90})
    |> Pdf.set_font("Helvetica", 12, bold: true)
    |> safe_text_at({@margin, 74}, name)
    |> Pdf.set_font("Helvetica", 10)
    |> safe_text_at({@margin, 60}, title)
  end

  # Letflow's branding snapshot (`Letflow.Routers.TenantConfig.branding_from_settings/1`)
  # carries `app_name`/`logo_url`/`brand_colors` only -- it has no signatory
  # concept at all (the source's `TemplateSnapshot` carries `SignatoryName`/
  # `SignatoryTitle` as separate tenant-configured fields Letflow has no
  # equivalent setting for yet). Rather than inventing a new tenant-settings
  # key this requirement was not asked to add, the signatory block renders
  # the certificate's own app name as a fixed, honest placeholder signatory
  # line ("<app name> Certification Authority" / "Automated Issuance") --
  # visible, not silently dropped, and clearly a placeholder for a future
  # requirement that adds real per-tenant signatory configuration.
  defp signatory(certificate) do
    app_name = branding_app_name(certificate)

    %{
      "signatory_name" => "#{app_name} Certification Authority",
      "signatory_title" => "Automated Issuance"
    }
  end

  # ── Footer: QR code + readable verification text (bottom-right) ──────
  #
  # Decision 0033 section 4's integration shape: iterate EQRCode's raw
  # module matrix and fill one Pdf rectangle per set (`1`) module, at
  # @qr_module_size Pdf points per module -- no PNG/SVG round trip.

  defp draw_qr_and_verify_text(pdf, verify_url, code) do
    matrix = EQRCode.encode(verify_url, :m)

    pdf
    |> draw_qr_matrix(matrix)
    |> Pdf.set_font("Helvetica", 8)
    |> safe_text_at({@qr_origin_x - 60, 40}, "Verify: #{verify_url}")
    |> safe_text_at({@qr_origin_x - 60, 30}, "Certificate ID: #{code}")
  end

  # NOTE: `%Matrix{}.modules` is the PRE-quiet-zone module count --
  # `EQRCode.Matrix.draw_quite_zone/1` pads a further 4 rows/cols (a 2-module
  # quiet-zone border each side) onto `:matrix` WITHOUT updating `:modules`
  # to match (`deps/eqrcode/lib/eqrcode/matrix.ex:369-386`). The real side
  # length to draw against is therefore `tuple_size(matrix)`, not the
  # `:modules` field -- using the stale field here would mis-flip the
  # vertical (row) coordinate for every quiet-zone row.
  # `certificate_document_test.exs`'s own QR-payload reconstruction test
  # makes the same correction independently (via `tuple_size/1` on the
  # matrix it decodes back from PDF geometry) for the same reason.
  defp draw_qr_matrix(pdf, %Matrix{matrix: matrix}) do
    side = tuple_size(matrix)
    rows = Tuple.to_list(matrix)

    pdf = Pdf.set_fill_color(pdf, :black)

    Enum.reduce(Enum.with_index(rows), pdf, fn {row, row_index}, pdf ->
      cells = Tuple.to_list(row)

      Enum.reduce(Enum.with_index(cells), pdf, fn {cell, col_index}, pdf ->
        draw_qr_cell(pdf, cell, row_index, col_index, side)
      end)
    end)
  end

  defp draw_qr_cell(pdf, 1, row_index, col_index, modules) do
    x = @qr_origin_x + col_index * @qr_module_size
    # Pdf coordinates are bottom-left-origin; the matrix is drawn top-down,
    # so row 0 is the topmost row -- anchor the QR block's bottom edge at a
    # fixed footer y and flip the row index.
    y = 60 + (modules - 1 - row_index) * @qr_module_size

    pdf
    |> Pdf.rectangle({x, y}, {@qr_module_size, @qr_module_size})
    |> Pdf.fill()
  end

  defp draw_qr_cell(pdf, _module_off, _row_index, _col_index, _modules), do: pdf

  # ── Small text-centering helper (this module's own; Pdf itself only
  # centers within `text_wrap/5`'s box, which this fixed layout doesn't use)

  defp centered_text_at(pdf, y, text) do
    safe_text_at(pdf, {@page_width / 2 - estimate_text_width(text) / 2, y}, text)
  end

  # ── FINDING against decision 0033, reported not silently worked around ──
  #
  # `pdf` (option P1) draws text through a bundled Type-1 AFM Helvetica font
  # encoded WinAnsi (single-byte, Latin-1-range) -- `deps/pdf/lib/pdf/font.ex`'s
  # own moduledoc: "Currently only Type 1 AFM/PFB fonts are supported", and
  # `Pdf.Encoding.WinAnsi.encode/2` RAISES `ArgumentError` on any character
  # outside that range by default. Decision 0033 evaluated `pdf` only against
  # "renders positioned text/images sufficient for this document" -- it did
  # not evaluate GLYPH COVERAGE, and this vertical's own exam locales
  # (`priv/packs/bilimbaga/entity_definitions/exam.json`'s `title` field:
  # `"locales": ["kk", "ru", "en"]`) are Cyrillic-script for two of three
  # declared locales, and a candidate's own `display_name`
  # (`Letflow.Identity.User`) is unconstrained free text that can contain any
  # script. `pdf` 0.8.2 has NO Unicode/CID font embedding path at all (only
  # Type-1 AFM/PFB) -- there is no way to make it render real Cyrillic (or
  # any non-Latin-1) glyphs, full stop; this is not a configuration gap this
  # module can close.
  #
  # THIS IS REPORTED AS A FINDING REOPENING DECISION 0033, not
  # worked around by substituting a different library (forbidden -- see this
  # module's own moduledoc and REQ-356's requirements.yaml text). What THIS
  # module does instead, so a Cyrillic candidate name or exam title degrades
  # rather than crashing the whole render: every `text_at` call goes through
  # `safe_text_at/3` below, which passes
  # `encoding_replacement_character: "?"` -- `Pdf.Page.text_at/4`'s own
  # documented opt (`deps/pdf/lib/pdf/page.ex:748`,
  # `deps/pdf/lib/pdf/font.ex:65`) -- so an unsupported character is replaced
  # with a literal `"?"` glyph instead of raising. This keeps `render/2`
  # total (it always returns `{:ok, bytes}` for well-formed input, never
  # crashes on script content) but a Cyrillic name/title is NOT rendered
  # legibly -- every unsupported character becomes `?`. See this
  # requirement's close-out for the finding statement filed against decision
  # 0033; a follow-up requirement must decide whether to embed a Unicode
  # TrueType font (a `pdf` capability gap, not a bug) or otherwise address
  # non-Latin rendering before this vertical's Cyrillic-locale content can
  # produce a genuinely readable certificate.
  @text_opts [encoding_replacement_character: "?"]

  # ── SECURITY FIX (SECURITY-REVIEWER finding against REQ-356) ─────────────
  #
  # `deps/pdf`'s own `Pdf.Text.escape/1` (`deps/pdf/lib/pdf/text.ex:8-12`)
  # escapes `(` and `)` but NEVER a literal backslash:
  #
  #     string |> String.replace("(", "\\(") |> String.replace(")", "\\)")
  #
  # A caller-controlled string containing a literal backslash immediately
  # followed by `)` (e.g. `candidate_name` = `Letflow.Identity.User.display_name`,
  # or a tenant-authored `exam_title`) therefore round-trips through this
  # library's escaping UNCHANGED for that pair: `\)` stays `\)` in the emitted
  # PDF text-literal operand. Per the PDF literal-string grammar, `\)` is
  # itself a valid escape (an escaped literal `)`), so this looks safe in
  # isolation -- the actual break is a backslash that is NOT already paired
  # with a following paren, or more than one running together, e.g. input
  # `\\)` (two backslashes, then a close-paren): the library's escape only
  # touches the `)` producing `\\\)` (three backslashes then `)`), and a PDF
  # parser consumes backslash-escapes pairwise left to right -- `\\` (one
  # literal backslash) then `\)` (one literal `)`) -- reconstructing the
  # original 3-byte input correctly ONLY because the count happens to be odd.
  # Any input with an EVEN run of backslashes directly before a `)` (the
  # simplest: a single `\` followed by `)`, i.e. literal bytes `\` `)`) hits
  # the real bug: `Pdf.Text.escape/1` turns `)` into `\)`, yielding `\` `\`
  # `)` (backslash, backslash, close-paren) -- a PDF parser reads THAT as one
  # escaped-backslash pair (`\\`) followed by a BARE, unescaped `)`, which
  # closes the PDF text-literal early. Everything after it in the content
  # stream is then interpreted as raw PDF operators, not literal text --
  # letting a candidate name or exam title inject arbitrary content-stream
  # commands (e.g. drawing over/altering the displayed score).
  #
  # Fix: pre-escape every literal backslash to `\\` OURSELVES, BEFORE handing
  # the string to `Pdf.text_at/4` (which internally calls the flawed
  # `Text.escape/1` for the `(`/`)` pass only, via `Pdf.Page.kern_text/3`).
  # Order is load-bearing per the PDF spec's own literal-string escaping
  # rules: backslash MUST be escaped first, then `(`/`)`, or the parens pass
  # would double-escape a backslash we already doubled and reintroduce this
  # same bug. Concretely, for input bytes `\` `)`:
  #   1. `escape_backslash/1` (this module): `\` -> `\\`, giving `\` `\` `)`.
  #   2. `Pdf.Text.escape/1` (library, escapes `)` only, untouched by us):
  #      `)` -> `\)`, giving `\` `\` `\` `)`.
  #   3. A PDF parser reads that left to right as one `\\` pair (one literal
  #      `\`) then one `\)` pair (one literal `)`) -- reconstructing the
  #      original `\` `)` exactly, with NO early literal-close. Verified
  #      against the real `pdf` library output, not just traced by hand --
  #      see `certificate_document_test.exs`'s
  #      "backslash-paren injection" test.
  defp escape_backslash(text) when is_binary(text), do: String.replace(text, "\\", "\\\\")

  defp safe_text_at(pdf, coords, text),
    do: Pdf.text_at(pdf, coords, escape_backslash(text), @text_opts)

  # A fixed-width-per-character estimate (Helvetica is NOT monospace, so
  # this is deliberately approximate) -- good enough for this document's
  # own "roughly centered on an A4-landscape page" requirement, avoiding a
  # dependency on `Pdf.Font.Metrics`' internal, undocumented API for exact
  # glyph widths.
  defp estimate_text_width(text), do: String.length(text) * 8
end
