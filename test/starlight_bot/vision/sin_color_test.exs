defmodule StarlightBot.Vision.SinColorTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.{SinColor, SkillTray}

  @color_hsv2bgr 54

  describe "classify_cell/4" do
    test "classifies a solid wrath-colored cell as wrath with high confidence" do
      bgr = hsv_to_bgr({0, 220, 200})
      mat = solid_mat(40, 30, bgr)

      result = SinColor.classify_cell(mat, {0, 40}, 0, 30)

      assert result.sin == :wrath
      assert result.confidence > 0.9
      assert result.reference.bgr == bgr
    end

    test "reference color reflects the border ring, not muddied same-hue fill" do
      border_bgr = hsv_to_bgr({110, 220, 200})
      fill_bgr = hsv_to_bgr({110, 150, 250})

      mat = solid_mat(40, 40, fill_bgr)
      mat = Evision.rectangle(mat, {0, 0}, {39, 39}, border_bgr, thickness: 3)

      result = SinColor.classify_cell(mat, {0, 40}, 0, 40)

      assert result.sin == :pride

      {rb, rg, rr} = result.reference.bgr
      {bb, bg, br} = border_bgr
      {fb, _fg, fr} = fill_bgr

      assert_in_delta rb, bb, 10
      assert_in_delta rg, bg, 10
      assert_in_delta rr, br, 10

      assert abs(rb - fb) > abs(rb - bb)
      assert abs(rr - fr) > abs(rr - br)
    end

    test "classifies each vivid sin correctly from its tuned hue" do
      for {sin, {hue, _tol, _s_lo, _s_hi, _v_lo, _v_hi}} <- SinColor.colors() do
        bgr = hsv_to_bgr({hue, 220, 200})
        mat = solid_mat(40, 30, bgr)

        assert SinColor.classify_cell(mat, {0, 40}, 0, 30).sin == sin
      end
    end

    test "picks the sin with more saturated area when a cell mixes two colors" do
      wrath_bgr = hsv_to_bgr({0, 220, 200})
      envy_bgr = hsv_to_bgr({140, 220, 200})

      mat = solid_mat(60, 20, {0, 0, 0})
      mat = Evision.rectangle(mat, {0, 0}, {39, 19}, wrath_bgr, thickness: -1)
      mat = Evision.rectangle(mat, {40, 0}, {59, 19}, envy_bgr, thickness: -1)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 20)

      assert result.sin == :wrath
      assert result.confidence > 0.0
      assert result.confidence < 1.0
    end

    test "still returns one of the 7 sins, with zero confidence, when nothing is saturated enough to match" do
      mat = solid_mat(20, 20, {0, 0, 0})

      result = SinColor.classify_cell(mat, {0, 20}, 0, 20)

      assert result.sin in Keyword.keys(SinColor.colors())
      assert result.confidence == 0.0
    end

    test "exposes the match mask and reference mask actually used, for UI inspection" do
      {hue, _tol, s_lo, s_hi, v_lo, v_hi} = SinColor.colors()[:pride]
      border_bgr = hsv_to_bgr({hue, s_hi, v_hi})
      fill_bgr = hsv_to_bgr({hue, mid(s_lo, s_hi), mid(v_lo, v_hi)})

      mat = solid_mat(40, 40, fill_bgr)
      mat = Evision.rectangle(mat, {0, 0}, {39, 39}, border_bgr, thickness: 3)

      result = SinColor.classify_cell(mat, {0, 40}, 0, 40)

      match_area = Evision.countNonZero(result.match_mask)
      reference_area = Evision.countNonZero(result.reference_mask)

      assert match_area == 1600
      assert reference_area > 0
      assert reference_area < match_area
    end

    test "hue_scan_y shifts sin/reference detection away from a contaminated top region, while tier/wedge detection stays anchored there" do
      gluttony_bgr = hsv_to_bgr({41, 220, 200})
      gloom_bgr = hsv_to_bgr({96, 220, 200})

      mat = solid_mat(60, 90, gluttony_bgr)
      mat = Evision.rectangle(mat, {0, 0}, {59, 15}, gloom_bgr, thickness: -1)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 30, 45)

      assert result.sin == :gluttony

      match_area = Evision.countNonZero(result.match_mask)
      tier_color_area = Evision.countNonZero(result.tier_color_mask)
      assert tier_color_area < match_area
    end

    test "a narrower hue_x prevents column-edge contamination from winning the sin vote" do
      gluttony_bgr = hsv_to_bgr({41, 220, 200})
      wrath_bgr = hsv_to_bgr({0, 220, 200})

      mat = solid_mat(100, 20, wrath_bgr)
      mat = Evision.rectangle(mat, {40, 0}, {59, 19}, gluttony_bgr, thickness: -1)

      contaminated = SinColor.classify_cell(mat, {0, 100}, 0, 20)
      assert contaminated.sin == :wrath

      result = SinColor.classify_cell(mat, {0, 100}, 0, 20, nil, {40, 60})
      assert result.sin == :gluttony
    end

    test "without an explicit hue_scan_y, tier detection reads the same region as classification (today's single-region behavior)" do
      bgr = hsv_to_bgr({41, 220, 200})
      mat = solid_mat(60, 30, bgr)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 30)

      assert Evision.Mat.to_binary(result.tier_color_mask) == Evision.Mat.to_binary(result.match_mask)
    end

    test "tier ignores color matches outside the top-right wedge, defaulting to skill1" do
      pride_bgr = hsv_to_bgr({110, 220, 200})
      mat = solid_mat(60, 30, {0, 0, 0})
      mat = Evision.rectangle(mat, {0, 20}, {19, 29}, pride_bgr, thickness: -1)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 30)

      assert result.sin == :pride
      assert result.tier_pct == 0.0
      assert result.tier == :skill1
    end

    test "hole_fill recovers a decoration's full area despite small internal design gaps" do
      sloth_bgr = hsv_to_bgr({23, 220, 200})

      solid_mat_cell = solid_mat(60, 30, {0, 0, 0})
      solid_mat_cell = Evision.rectangle(solid_mat_cell, {45, 10}, {57, 19}, sloth_bgr, thickness: -1)
      solid_result = SinColor.classify_cell(solid_mat_cell, {0, 60}, 0, 30)

      gapped_mat = solid_mat(60, 30, {0, 0, 0})
      gapped_mat = Evision.rectangle(gapped_mat, {45, 10}, {57, 19}, sloth_bgr, thickness: -1)
      gapped_mat = Evision.rectangle(gapped_mat, {49, 13}, {53, 16}, {0, 0, 0}, thickness: -1)
      gapped_result = SinColor.classify_cell(gapped_mat, {0, 60}, 0, 30)

      assert solid_result.sin == :sloth
      assert gapped_result.sin == :sloth
      assert solid_result.tier_area == gapped_result.tier_area
    end

    test "a wedge entirely covered by the matched color reaches skill3" do
      bgr = hsv_to_bgr({110, 220, 200})
      mat = solid_mat(60, 30, bgr)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 30)

      assert result.sin == :pride
      assert result.tier_pct == 1.0
      assert result.tier == :skill3
    end

    test "tier_pct is the matched-in-wedge area divided by the wedge's own area" do
      pride_bgr = hsv_to_bgr({110, 220, 200})
      mat = solid_mat(60, 30, {0, 0, 0})
      mat = Evision.rectangle(mat, {0, 20}, {19, 29}, pride_bgr, thickness: -1)
      mat = Evision.rectangle(mat, {45, 0}, {54, 5}, pride_bgr, thickness: -1)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 30)

      assert result.wedge_area > 0
      assert_in_delta result.tier_pct, result.tier_area / result.wedge_area, 0.0001
    end

    test "corner_cut_pct shrinks a sin's own wedge relative to a sin with no cut, same cell dimensions" do
      lust_bgr = hsv_to_bgr({13, 220, 200})
      pride_bgr = hsv_to_bgr({110, 220, 200})

      lust_result = SinColor.classify_cell(solid_mat(60, 30, lust_bgr), {0, 60}, 0, 30)
      pride_result = SinColor.classify_cell(solid_mat(60, 30, pride_bgr), {0, 60}, 0, 30)

      assert lust_result.sin == :lust
      assert pride_result.sin == :pride

      assert lust_result.wedge_area < pride_result.wedge_area
    end
  end

  describe "classify_row/2" do
    test "classifies each column of a real tray row independently" do
      tray = SkillTray.geometry(400)
      row = tray.top_row
      colors = SinColor.colors()
      columns = SkillTray.row_columns(row)

      {mat, expected_sins} =
        columns
        |> Enum.with_index()
        |> Enum.reduce({solid_mat(1920, 1080, {0, 0, 0}), []}, fn {{x0, x1}, i}, {mat, acc} ->
          {sin, {hue, _tol, s_lo, s_hi, v_lo, v_hi}} = Enum.at(colors, rem(i, length(colors)))
          bgr = hsv_to_bgr({hue, mid(s_lo, s_hi), mid(v_lo, v_hi)})
          mat = Evision.rectangle(mat, {x0, row.y}, {x1 - 1, row.y + row.h - 1}, bgr, thickness: -1)
          {mat, [sin | acc]}
        end)

      expected_sins = Enum.reverse(expected_sins)
      results = SinColor.classify_row(mat, row)

      assert Enum.map(results, & &1.sin) == expected_sins
    end
  end

  describe "classify_cell/7 with background hue mixing" do
    test "recovers a sin whose true color has drifted toward a green background, once mixing compensates for the same drift" do
      drifted_bgr = hsv_to_bgr({89, 220, 200})
      mat = solid_mat(40, 30, drifted_bgr)

      unmixed = SinColor.classify_cell(mat, {0, 40}, 0, 30)
      assert unmixed.confidence == 0.0

      mixed = SinColor.classify_cell(mat, {0, 40}, 0, 30, nil, nil, 41)
      assert mixed.sin == :gloom
      assert mixed.confidence > 0.0
    end

    test "an untainted background hue (nil) leaves classification unchanged" do
      bgr = hsv_to_bgr({110, 220, 200})
      mat = solid_mat(40, 30, bgr)

      assert SinColor.classify_cell(mat, {0, 40}, 0, 30, nil, nil, nil).sin ==
               SinColor.classify_cell(mat, {0, 40}, 0, 30).sin
    end

    test "tier/wedge matching follows the empirically detected sin color, not a separate bg_hue remix" do
      drifted_sloth_bgr = hsv_to_bgr({29, 220, 200})
      pure_sloth_bgr = hsv_to_bgr({23, 220, 200})

      mat = solid_mat(60, 90, drifted_sloth_bgr)
      mat = Evision.rectangle(mat, {0, 45}, {59, 74}, pure_sloth_bgr, thickness: -1)

      unmixed = SinColor.classify_cell(mat, {0, 60}, 0, 30, 45)
      assert unmixed.sin == :sloth
      assert unmixed.tier == :skill1

      mixed = SinColor.classify_cell(mat, {0, 60}, 0, 30, 45, nil, 50)
      assert mixed.sin == :sloth
      assert mixed.tier == :skill1
    end

    test "tier/wedge matching tracks the real detected color when the whole icon (not just the hue-scan sample) drifted together" do
      drifted_sloth_bgr = hsv_to_bgr({29, 220, 200})
      mat = solid_mat(60, 30, drifted_sloth_bgr)

      result = SinColor.classify_cell(mat, {0, 60}, 0, 30, nil, nil, 50)

      assert result.sin == :sloth
      assert result.tier == :skill3
    end
  end

  describe "background_color/2" do
    test "recovers the average color and hue of a solid-colored strip" do
      bgr = hsv_to_bgr({41, 220, 200})
      mat = solid_mat(40, 20, bgr)

      result = SinColor.background_color(mat, {0, 0, 40, 20})

      assert result.hue == 41
      assert result.bgr == bgr
      assert_in_delta result.saturation, 220, 1
    end
  end

  describe "effective_mix_pct/1" do
    test "nil saturation mixes at the full bg_mix_pct" do
      assert SinColor.effective_mix_pct(nil) == SinColor.bg_mix_pct()
    end

    test "0 saturation means no mix" do
      assert SinColor.effective_mix_pct(0) == 0.0
    end

    test "max saturation (255) mixes at the full bg_mix_pct" do
      assert SinColor.effective_mix_pct(255) == SinColor.bg_mix_pct()
    end

    test "half saturation mixes at half the bg_mix_pct" do
      assert_in_delta SinColor.effective_mix_pct(128), SinColor.bg_mix_pct() * (128 / 255), 0.0001
    end
  end

  describe "classify_cell/8 with background saturation scaling" do
    test "a fully desaturated background (saturation 0) applies no hue mixing" do
      drifted_bgr = hsv_to_bgr({89, 220, 200})
      mat = solid_mat(40, 30, drifted_bgr)

      unmixed = SinColor.classify_cell(mat, {0, 40}, 0, 30)
      no_sat_mix = SinColor.classify_cell(mat, {0, 40}, 0, 30, nil, nil, 41, 0)

      assert no_sat_mix.sin == unmixed.sin
      assert no_sat_mix.confidence == unmixed.confidence
    end

    test "a fully saturated background (saturation 255) mixes identically to omitting saturation" do
      drifted_bgr = hsv_to_bgr({89, 220, 200})
      mat = solid_mat(40, 30, drifted_bgr)

      full_mix = SinColor.classify_cell(mat, {0, 40}, 0, 30, nil, nil, 41)
      explicit_full_sat = SinColor.classify_cell(mat, {0, 40}, 0, 30, nil, nil, 41, 255)

      assert explicit_full_sat.sin == full_mix.sin
      assert_in_delta explicit_full_sat.confidence, full_mix.confidence, 0.0001
    end
  end

  defp mid(lo, hi), do: div(lo + hi, 2)

  defp hsv_to_bgr({h, s, v}) do
    hsv = Evision.Mat.from_binary(<<h, s, v>>, {:u, 8}, 1, 1, 3)
    bgr = Evision.cvtColor(hsv, @color_hsv2bgr)
    <<b, g, r>> = Evision.Mat.to_binary(bgr)
    {b, g, r}
  end

  defp solid_mat(w, h, {b, g, r}) do
    Evision.Mat.from_binary(:binary.copy(<<b, g, r>>, w * h), {:u, 8}, h, w, 3)
  end
end
