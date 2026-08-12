defmodule StarlightBot.Vision.SinColor do
  alias StarlightBot.Vision.{Matcher, SkillTray}

  @color_bgr2hsv 40

  @colors [
    wrath: {0, 4, 140, 255, 63, 245},
    gloom: {96, 5, 100, 255, 63, 245},
    sloth: {23, 5, 140, 255, 63, 245},
    lust: {12, 5, 140, 255, 63, 245},
    pride: {110, 5, 100, 255, 63, 200},
    gluttony: {41, 5, 100, 255, 63, 252},
    envy: {140, 6, 140, 255, 63, 245}
  ]

  @type sin :: :wrath | :lust | :sloth | :gluttony | :gloom | :pride | :envy
  @type tier :: :skill1 | :skill2 | :skill3

  @type result :: %{
          sin: sin,
          confidence: float,
          reference: %{bgr: {number, number, number}, stddev: {number, number, number}},
          tier: tier,
          tier_area: non_neg_integer,
          wedge_area: non_neg_integer,
          tier_pct: float,
          match_mask: term,
          reference_mask: term,
          wedge_mask: term,
          tier_mask: term,
          tier_color_mask: term
        }

  @tier_thresholds [
    wrath: {0.48, 0.72},
    gloom: {0.38, 0.59},
    sloth: {0.45, 0.68},
    lust: {0.45, 0.68},
    pride: {0.41, 0.52},
    gluttony: {0.35, 0.51},
    envy: {0.40, 0.60}
  ]

  @corner_cut_pct [
    lust: 0.20,
    wrath: 0.05,
    gloom: 0.05,
    pride: 0.08,
    sloth: 0.01,
    gluttony: 0.08,
    envy: 0.05,
  ]

  @wedge_bulge_pct 0.2

  @ring_kernel_px 3
  @min_ring_area 8

  @bg_mix_pct 0.03

  @spec classify_cell(
          term,
          {integer, integer},
          integer,
          integer,
          integer | nil,
          {integer, integer} | nil,
          0..179 | nil,
          0..255 | nil
        ) :: result
  def classify_cell(mat, {x0, x1}, y, h, hue_scan_y \\ nil, hue_x \\ nil, bg_hue \\ nil, bg_saturation \\ nil) do
    hue_scan_y = hue_scan_y || y
    {hx0, hx1} = hue_x || {x0, x1}
    hue_cell = Evision.Mat.roi(mat, {hx0, hue_scan_y, hx1 - hx0, h})
    hsv = Evision.cvtColor(hue_cell, @color_bgr2hsv)

    scores =
      for {name, {hue, tol, s_lo, s_hi, v_lo, v_hi}} <- @colors do
        mask = Matcher.hue_range_mask(hsv, mix_hue(hue, bg_hue, bg_saturation), tol, s_lo, s_hi, v_lo, v_hi)
        {name, Evision.countNonZero(mask), mask}
      end

    {winner, area, mask} = Enum.max_by(scores, fn {_name, area, _mask} -> area end)

    second_best =
      scores
      |> Enum.reject(fn {name, _area, _mask} -> name == winner end)
      |> Enum.map(fn {_name, area, _mask} -> area end)
      |> Enum.max(fn -> 0 end)

    confidence = if area <= 0, do: 0.0, else: (area - second_best) / area
    ref_mask = reference_mask(mask)
    {mean, stddev} = Evision.meanStdDev(hue_cell, mask: ref_mask)
    detected_hue = hue_of_mean(mean)

    tier_color_mask =
      mat
      |> tier_color_mask({x0, x1}, y, h, winner, detected_hue)
      |> Matcher.fill_holes_mask()

    wedge = wedge_mask(x1 - x0, h, winner)
    tier_mask = Evision.Mat.bitwise_and(tier_color_mask, wedge)
    tier_area = Evision.countNonZero(tier_mask)
    wedge_area = Evision.countNonZero(wedge)
    tier_pct = if wedge_area > 0, do: tier_area / wedge_area, else: 0.0
    tier = classify_tier(winner, tier_pct)

    %{
      sin: winner,
      confidence: confidence,
      reference: %{bgr: to_bgr(mean), stddev: to_bgr(stddev)},
      tier: tier,
      tier_area: tier_area,
      wedge_area: wedge_area,
      tier_pct: tier_pct,
      match_mask: mask,
      reference_mask: ref_mask,
      wedge_mask: wedge,
      tier_mask: tier_mask,
      tier_color_mask: tier_color_mask
    }
  end

  defp tier_color_mask(mat, {x0, x1}, y, h, winner, detected_hue) do
    tier_cell = Evision.Mat.roi(mat, {x0, y, x1 - x0, h})
    tier_hsv = Evision.cvtColor(tier_cell, @color_bgr2hsv)
    {_hue, tol, s_lo, s_hi, v_lo, v_hi} = Keyword.fetch!(@colors, winner)
    Matcher.hue_range_mask(tier_hsv, detected_hue, tol, s_lo, s_hi, v_lo, v_hi)
  end

  defp wedge_mask(w, h, sin) do
    corner_pct = Keyword.get(@corner_cut_pct, sin, 0.0)
    wedge = Matcher.top_right_wedge_mask(w, h, @wedge_bulge_pct)
    corner = Matcher.top_right_corner_mask(w, h, corner_pct)
    Evision.Mat.bitwise_and(wedge, Evision.Mat.bitwise_not(corner))
  end

  defp classify_tier(sin, pct) do
    {tier2_min_pct, tier3_min_pct} = Keyword.fetch!(@tier_thresholds, sin)

    cond do
      pct >= tier3_min_pct -> :skill3
      pct >= tier2_min_pct -> :skill2
      true -> :skill1
    end
  end

  defp reference_mask(mask) do
    ring = Matcher.inner_ring_mask(mask, @ring_kernel_px)
    if Evision.countNonZero(ring) >= @min_ring_area, do: ring, else: mask
  end

  @spec classify_row(term, SkillTray.row(), 0..179 | nil, 0..255 | nil) :: [result]
  def classify_row(mat, row, bg_hue \\ nil, bg_saturation \\ nil) do
    tier_columns = SkillTray.row_columns(row)
    hue_columns = SkillTray.hue_scan_columns(row)

    [tier_columns, hue_columns]
    |> Enum.zip()
    |> Enum.map(fn {{x0, x1}, hue_x} ->
      classify_cell(mat, {x0, x1}, row.y, row.h, row.hue_scan_y, hue_x, bg_hue, bg_saturation)
    end)
  end

  @spec background_color(term, {integer, integer, integer, integer}) :: %{
          bgr: {number, number, number},
          hue: 0..179,
          saturation: 0..255
        }
  def background_color(mat, {x, y, w, h}) do
    strip = Evision.Mat.roi(mat, {x, y, w, h})
    {mean, _stddev} = Evision.meanStdDev(strip)
    {b, g, r} = to_bgr(mean)
    {hue, saturation} = hue_and_saturation_of_mean(mean)
    %{bgr: {b, g, r}, hue: hue, saturation: saturation}
  end

  @spec colors() :: keyword({0..179, non_neg_integer, 0..255, 0..255, 0..255, 0..255})
  def colors, do: @colors

  @spec tier_thresholds() :: keyword({float, float})
  def tier_thresholds, do: @tier_thresholds

  @spec bg_mix_pct() :: float
  def bg_mix_pct, do: @bg_mix_pct

  @spec effective_mix_pct(0..255 | nil) :: float
  def effective_mix_pct(nil), do: @bg_mix_pct
  def effective_mix_pct(bg_saturation), do: @bg_mix_pct * (bg_saturation / 255)

  defp mix_hue(hue, nil, _bg_saturation), do: hue

  defp mix_hue(hue, bg_hue, bg_saturation) do
    sat_scale = if bg_saturation, do: bg_saturation / 255, else: 1.0
    diff = Integer.mod(bg_hue - hue + 90, 180) - 90
    hue |> Kernel.+(diff * @bg_mix_pct * sat_scale) |> round() |> Integer.mod(180)
  end

  defp to_bgr(mat) do
    [b, g, r] = mat |> Evision.Mat.to_nx() |> Nx.to_flat_list()
    {b, g, r}
  end

  defp hsv_of_mean(mean) do
    {b, g, r} = to_bgr(mean)
    pixel = Evision.Mat.from_binary(<<round(b), round(g), round(r)>>, {:u, 8}, 1, 1, 3)
    hsv = Evision.cvtColor(pixel, @color_bgr2hsv)
    <<hue, saturation, value>> = Evision.Mat.to_binary(hsv)
    {hue, saturation, value}
  end

  defp hue_of_mean(mean) do
    {hue, _saturation, _value} = hsv_of_mean(mean)
    hue
  end

  defp hue_and_saturation_of_mean(mean) do
    {hue, saturation, _value} = hsv_of_mean(mean)
    {hue, saturation}
  end
end
