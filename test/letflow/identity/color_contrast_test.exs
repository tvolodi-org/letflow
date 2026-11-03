defmodule Letflow.Identity.ColorContrastTest do
  @moduledoc """
  Unit tests for `Letflow.Identity.ColorContrast` (REQ-382 §2.5,
  `lib/letflow/design/req382-tenant-branding-write-path.md`). Pure math, no
  `Ecto`/`Plug`/I/O — pins the WCAG 2.1 §1.4.3 relative-luminance/contrast-
  ratio formula and the 4.5:1 AA normal-text threshold independently of
  `Tenant.settings_changeset/2`'s changeset-integration behavior (that
  integration is covered separately by
  `test/letflow/routers/tenant_settings_test.exs`'s AC2 describe block).

  Reference values pinned here are computed once via a throwaway script
  calling this exact module (`mix run --no-start` against a scratch file
  invoking `ColorContrast.contrast_ratio/2` directly) and then hard-coded —
  this is legitimate for a *unit* test of the formula itself: the numbers
  are independently checkable against any WCAG contrast calculator (e.g.
  black-on-white is the textbook 21:1 maximum), not merely "whatever the
  module returns today." `#1864AB`/`#228be6` against `#F8F9FA`/`#FFFFFF` are
  the exact same colors `test/letflow/identity/tenant_test.exs`'s own
  "brand_colors: a valid #RRGGBB primary color round-trips" test comment
  already cites (~5.77/~6.09 passing, ~3.37/~3.56 failing) — kept numerically
  consistent with that file rather than picking new, disconnected fixtures.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Identity.ColorContrast

  # ── relative_luminance/1 ─────────────────────────────────────────────────

  describe "relative_luminance/1" do
    test "black is 0.0" do
      assert_in_delta ColorContrast.relative_luminance("#000000"), 0.0, 0.0001
    end

    test "white is 1.0" do
      assert_in_delta ColorContrast.relative_luminance("#FFFFFF"), 1.0, 0.0001
    end

    test "is case-insensitive on hex digits" do
      assert ColorContrast.relative_luminance("#1864ab") ==
               ColorContrast.relative_luminance("#1864AB")
    end
  end

  # ── contrast_ratio/2 ──────────────────────────────────────────────────────

  describe "contrast_ratio/2" do
    test "black on white is the textbook maximum, 21:1" do
      assert_in_delta ColorContrast.contrast_ratio("#000000", "#FFFFFF"), 21.0, 0.001
    end

    test "a color against itself is always 1:1" do
      assert_in_delta ColorContrast.contrast_ratio("#1864AB", "#1864AB"), 1.0, 0.0001
      assert_in_delta ColorContrast.contrast_ratio("#F8F9FA", "#F8F9FA"), 1.0, 0.0001
    end

    test "is symmetric in its two arguments -- order of the colors passed in never changes the result" do
      assert ColorContrast.contrast_ratio("#1864AB", "#F8F9FA") ==
               ColorContrast.contrast_ratio("#F8F9FA", "#1864AB")

      assert ColorContrast.contrast_ratio("#228be6", "#FFFFFF") ==
               ColorContrast.contrast_ratio("#FFFFFF", "#228be6")
    end

    test "#1864AB (the passing fixture color) against tokens.css's two reference backgrounds" do
      assert_in_delta ColorContrast.contrast_ratio("#1864AB", "#F8F9FA"), 5.7749, 0.001
      assert_in_delta ColorContrast.contrast_ratio("#1864AB", "#FFFFFF"), 6.0874, 0.001
    end

    test "#228be6 (the pre-REQ-382 failing fixture color) against tokens.css's two reference backgrounds" do
      assert_in_delta ColorContrast.contrast_ratio("#228be6", "#F8F9FA"), 3.3745, 0.001
      assert_in_delta ColorContrast.contrast_ratio("#228be6", "#FFFFFF"), 3.5571, 0.001
    end
  end

  # ── meets_wcag_aa_normal_text?/2 ──────────────────────────────────────────

  describe "meets_wcag_aa_normal_text?/2" do
    test "black on white (21:1) meets the 4.5:1 AA normal-text minimum" do
      assert ColorContrast.meets_wcag_aa_normal_text?("#000000", "#FFFFFF")
    end

    test "#1864AB meets the minimum against both tokens.css reference backgrounds" do
      assert ColorContrast.meets_wcag_aa_normal_text?("#1864AB", "#F8F9FA")
      assert ColorContrast.meets_wcag_aa_normal_text?("#1864AB", "#FFFFFF")
    end

    test "#228be6 fails the minimum against both tokens.css reference backgrounds" do
      refute ColorContrast.meets_wcag_aa_normal_text?("#228be6", "#F8F9FA")
      refute ColorContrast.meets_wcag_aa_normal_text?("#228be6", "#FFFFFF")
    end

    test "a color identical to its own background never meets the minimum (1:1 ratio)" do
      refute ColorContrast.meets_wcag_aa_normal_text?("#F8F9FA", "#F8F9FA")
    end
  end

  # ── aa_normal_text_min_ratio/0 ────────────────────────────────────────────

  describe "aa_normal_text_min_ratio/0" do
    test "is exactly 4.5, the WCAG 2.1 AA normal-text minimum" do
      assert ColorContrast.aa_normal_text_min_ratio() == 4.5
    end
  end
end
