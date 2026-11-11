defmodule StarlightBot.Vision.SinColor do
  alias StarlightBot.Vision.{Frame, Matcher, SkillTray}

  @color_bgr2hsv 40

  # Each sin is {hue, hue_tol, s_lo, s_hi, v_lo, v_hi} in OpenCV HSV (H 0..179, S/V 0..255).
  # A pixel counts as that sin only if it falls inside every range. The same window is used
  # twice: once to pick the sin (the sin with the most matching pixels in the hue scan strip
  # wins), and again to measure tier (matching pixels as a share of the top-right wedge).
  #
  # hue / hue_tol: center and +/- width of the hue band. Wider catches anti-aliased edges and
  #   glow, but starts stealing pixels from a neighboring sin's hue (gloom 96 vs pride 110).
  # s_lo: lowering it admits washed-out pixels (glow, blended edges, translucent fill), which
  #   raises tier fill. Too low and greyish background or card art with a slight tint leaks in.
  # s_hi: only cuts fully saturated pixels. Solid outlines often sit at 250..255, so anything
  #   under 255 can drop the outline itself and leave specks. Lower it only to reject a
  #   specific oversaturated artifact.
  # v_lo: lowering it admits darker pixels: dim animation frames, shadowed parts of the
  #   ornament, dark sins like pride whose outline peaks near V 130. Too low and dark
  #   background or card art of a similar hue leaks in. This is usually the knob for "too sparse".
  # v_hi: only cuts the brightest pixels. Lower it to reject white-hot highlights or glare
  #   that happen to carry the hue; otherwise leave it high.
  #
  # Raising s_lo/v_lo or lowering s_hi/v_hi shrinks the mask, so tier_pct drops and cells slide
  # toward skill1; widening does the opposite and can push skill2 into skill3. When the tray
  # background is close in hue, hue_window_mask lifts s_lo/v_lo further for contrast.
  @colors [
    wrath: {0, 6, 70, 255, 105, 255},
    gloom: {93, 9, 85, 250, 70, 240},
    sloth: {23, 5, 145, 255, 100, 245},
    lust: {12, 5, 140, 255, 105, 245},
    pride: {112, 6, 77, 255, 60, 228},
    gluttony: {41, 6, 100, 255, 100, 252},
    envy: {146, 10, 100, 255, 100, 245}
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
          flame: float,
          match_mask: term,
          reference_mask: term,
          wedge_mask: term,
          tier_mask: term,
          tier_color_mask: term,
          tier_raw_mask: term
        }

  @tier_thresholds [
    wrath: {0.48, 0.60},
    gloom: {0.38, 0.59},
    sloth: {0.43, 0.85},
    lust: {0.50, 0.61},
    pride: {0.39, 0.56},
    gluttony: {0.42, 0.51},
    envy: {0.40, 0.60}
  ]

  @flame_thresholds [
    envy: {0.18, 0.33},
    gloom: {0.30, 0.46},
    gluttony: {0.22, 0.315},
    pride: {0.185, nil},
    wrath: {0.275, 0.325}
  ]

  @flame_zone_start_pct 0.68

  @corner_cut_pct [
    lust: 0.30,
    wrath: 0.05,
    gloom: 0.05,
    pride: 0.08,
    sloth: 0.01,
    gluttony: 0.10,
    envy: 0.05,
  ]

  @wedge_bulge_pct 0.23
  @max_leak_discount 2
  @bg_peak_window 3
  @bg_cluster_hue_tol 15
  @score_weights [gloom: 1.8]
  @gloom_lust_ratio 1.2
  @gloom_lust_penalty 0.8
  @bg_chroma_floor 0.6
  @bg_spread_k 0.5

  @ring_kernel_px 3
  @min_ring_area 8

  @bg_exclusion_hue_tol 20
  @bg_exclusion_s_tol 30
  @bg_exclusion_v_tol 25
  @bg_hue_affect_range 20
  @bg_contrast_margin 30
  @bg_min_value_floor 100

  @spec classify_cell(
          term,
          {integer, integer},
          integer,
          integer,
          integer | nil,
          {integer, integer} | nil,
          0..179 | nil,
          0..255 | nil,
          0..255 | nil,
          %{optional(sin) => float}
        ) :: result
  def classify_cell(mat, {x0, x1}, y, h, hue_scan_y \\ nil, hue_x \\ nil, bg_hue \\ nil, bg_saturation \\ nil, bg_value \\ nil, bg_leak \\ %{}) do
    hue_scan_y = hue_scan_y || y
    {hx0, hx1} = hue_x || {x0, x1}
    hue_cell = Frame.crop(mat, {hx0, hue_scan_y, hx1 - hx0, h})
    hsv = Evision.cvtColor(hue_cell, @color_bgr2hsv)
    bg_mask = background_exclusion_mask(hsv, bg_hue, bg_saturation, bg_value)

    cell_px = (hx1 - hx0) * h

    scores =
      for {name, {hue, tol, s_lo, s_hi, v_lo, v_hi}} <- @colors do
        mask = hue_window_mask(hsv, hue, tol, s_lo, s_hi, v_lo, v_hi, bg_hue, bg_saturation, bg_value, bg_mask)
        raw = Evision.countNonZero(mask)
        leak = min(round(Map.get(bg_leak, name, 0.0) * cell_px), div(raw, @max_leak_discount))
        {name, raw - leak, mask}
      end

    lust_raw = scores |> List.keyfind(:lust, 0) |> elem(1)

    scores =
      Enum.map(scores, fn {name, net, mask} ->
        weight = if name == :gloom and net < lust_raw * @gloom_lust_ratio, do: @gloom_lust_penalty, else: Keyword.get(@score_weights, name, 1.0)
        {name, round(net * weight), mask}
      end)

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

    tier_raw_mask = tier_color_mask(mat, {x0, x1}, y, h, winner, detected_hue, bg_hue, bg_saturation, bg_value)
    tier_color_mask = Matcher.fill_holes_mask(tier_raw_mask)

    wedge = wedge_mask(x1 - x0, h, winner)
    tier_mask = Evision.Mat.bitwise_and(tier_color_mask, wedge)
    tier_area = Evision.countNonZero(tier_mask)
    wedge_area = Evision.countNonZero(wedge)
    tier_pct = if wedge_area > 0, do: tier_area / wedge_area, else: 0.0
    flame = flame_density(tier_raw_mask, x1 - x0, h)
    tier = classify_tier(winner, tier_pct, flame)

    %{
      sin: winner,
      confidence: confidence,
      reference: %{bgr: to_bgr(mean), stddev: to_bgr(stddev)},
      tier: tier,
      tier_area: tier_area,
      wedge_area: wedge_area,
      tier_pct: tier_pct,
      flame: flame,
      match_mask: mask,
      reference_mask: ref_mask,
      wedge_mask: wedge,
      tier_mask: tier_mask,
      tier_color_mask: tier_color_mask,
      tier_raw_mask: tier_raw_mask
    }
  end

  defp tier_color_mask(mat, {x0, x1}, y, h, winner, detected_hue, bg_hue, bg_saturation, bg_value) do
    tier_cell = Frame.crop(mat, {x0, y, x1 - x0, h})
    tier_hsv = Evision.cvtColor(tier_cell, @color_bgr2hsv)
    {canonical_hue, tol, s_lo, s_hi, v_lo, v_hi} = Keyword.fetch!(@colors, winner)
    bg_mask = background_exclusion_mask(tier_hsv, bg_hue, bg_saturation, bg_value)
    hue_window_mask(tier_hsv, detected_hue, tol, s_lo, s_hi, v_lo, v_hi, bg_hue, bg_saturation, bg_value, bg_mask, canonical_hue)
  end

  defp hue_window_mask(hsv, hue, tol, s_lo, s_hi, v_lo, v_hi, bg_hue, bg_saturation, bg_value, bg_mask, affect_hue \\ nil) do
    scale = bg_hue_scale(bg_hue, bg_saturation, bg_value, affect_hue || hue)

    if scale > 0.0 do
      s_floor = min(contrast_saturation_floor(s_lo, bg_saturation, scale), s_hi)
      v_floor = min(contrast_value_floor(v_lo, bg_value, scale), v_hi)

      hsv
      |> Matcher.hue_range_mask(hue, tol, s_floor, s_hi, v_floor, v_hi)
      |> exclude_background(bg_mask)
    else
      Matcher.hue_range_mask(hsv, hue, tol, s_lo, s_hi, v_lo, v_hi)
    end
  end

  defp wedge_mask(w, h, sin) do
    corner_pct = Keyword.get(@corner_cut_pct, sin, 0.0)
    wedge = Matcher.top_right_wedge_mask(w, h, @wedge_bulge_pct)
    corner = Matcher.top_right_corner_mask(w, h, corner_pct)
    Evision.Mat.bitwise_and(wedge, Evision.Mat.bitwise_not(corner))
  end

  defp flame_density(raw_mask, w, h) do
    zone_x = trunc(w * @flame_zone_start_pct)
    zone_w = w - zone_x

    if zone_w > 0 do
      Evision.countNonZero(Frame.crop(raw_mask, {zone_x, 0, zone_w, h})) / (zone_w * h)
    else
      0.0
    end
  end

  defp classify_tier(sin, pct, flame) do
    {tier2_min_pct, tier3_min_pct} = Keyword.fetch!(@tier_thresholds, sin)
    {flame2, flame3} = Keyword.get(@flame_thresholds, sin, {nil, nil})

    tier2? = if flame2, do: flame >= flame2, else: pct >= tier2_min_pct
    tier3? = tier2? and if flame3, do: flame >= flame3 and pct >= tier3_min_pct, else: pct >= tier3_min_pct

    cond do
      tier3? -> :skill3
      tier2? -> :skill2
      true -> :skill1
    end
  end

  defp reference_mask(mask) do
    ring = Matcher.inner_ring_mask(mask, @ring_kernel_px)
    if Evision.countNonZero(ring) >= @min_ring_area, do: ring, else: mask
  end

  @spec classify_row(term, SkillTray.row(), 0..179 | nil, 0..255 | nil, 0..255 | nil, map) :: [result]
  def classify_row(mat, row, bg_hue \\ nil, bg_saturation \\ nil, bg_value \\ nil, bg_leak \\ %{}) do
    tier_columns = SkillTray.row_columns(row)
    hue_columns = SkillTray.hue_scan_columns(row)

    [tier_columns, hue_columns]
    |> Enum.zip()
    |> Enum.map(fn {{x0, x1}, hue_x} ->
      classify_cell(mat, {x0, x1}, row.y, row.h, row.hue_scan_y, hue_x, bg_hue, bg_saturation, bg_value, bg_leak)
    end)
  end

  @spec classify_tray(term, SkillTray.t()) :: {[result], [result]}
  def classify_tray(mat, tray) do
    bg = background_color(mat, SkillTray.background_region(tray))
    top = classify_row(mat, tray.top_row, bg.hue, bg.saturation, bg.value, bg.leak)
    bottom = classify_row(mat, tray.bottom_row, bg.hue, bg.saturation, bg.value, bg.leak)
    {top, Enum.zip_with(top, bottom, &inherit_top_tier/2)}
  end

  defp inherit_top_tier(%{sin: sin, tier: tier}, %{sin: sin} = bottom), do: %{bottom | tier: tier}
  defp inherit_top_tier(%{tier: tier}, %{tier: tier} = bottom), do: %{bottom | tier: next_best_tier(bottom.sin, tier, bottom.tier_pct)}
  defp inherit_top_tier(_top, bottom), do: bottom

  defp next_best_tier(sin, banned, pct) do
    {tier2_min_pct, tier3_min_pct} = Keyword.fetch!(@tier_thresholds, sin)

    case banned do
      :skill1 -> if pct >= tier3_min_pct, do: :skill3, else: :skill2
      :skill2 -> if pct >= (tier2_min_pct + tier3_min_pct) / 2, do: :skill3, else: :skill1
      :skill3 -> if pct >= tier2_min_pct, do: :skill2, else: :skill1
    end
  end

  @spec background_color(term, {integer, integer, integer, integer}) :: %{
          bgr: {number, number, number},
          hue: 0..179,
          saturation: 0..255,
          value: 0..255,
          leak: %{optional(sin) => float}
        }
  def background_color(mat, {x, y, w, h}) do
    strip = Frame.crop(mat, {x, y, w, h})
    {mean, _stddev} = Evision.meanStdDev(strip)
    {b, g, r} = to_bgr(mean)

    hsv_strip = Evision.cvtColor(strip, @color_bgr2hsv)
    {bg_hue, saturation, value} = dominant_hsv(hsv_strip)

    bg_saturation = round(saturation) |> clamp(0, 255)
    bg_value = round(value) |> clamp(0, 255)

    %{
      bgr: {b, g, r},
      hue: bg_hue,
      saturation: bg_saturation,
      value: bg_value,
      leak: background_leak(hsv_strip, bg_hue, bg_saturation, bg_value)
    }
  end

  defp background_leak(hsv_strip, bg_hue, bg_saturation, bg_value) do
    bg_mask = background_exclusion_mask(hsv_strip, bg_hue, bg_saturation, bg_value)
    {rows, cols, _channels} = Evision.Mat.shape(hsv_strip)
    strip_px = max(rows * cols, 1)

    Map.new(@colors, fn {name, {hue, tol, s_lo, s_hi, v_lo, v_hi}} ->
      mask = hue_window_mask(hsv_strip, hue, tol, s_lo, s_hi, v_lo, v_hi, bg_hue, bg_saturation, bg_value, bg_mask)
      {name, Evision.countNonZero(mask) / strip_px}
    end)
  end

  defp dominant_hsv(hsv) do
    pixels = hsv |> Evision.Mat.to_nx() |> Nx.reshape({:auto, 3}) |> Nx.to_list()
    hues = Enum.map(pixels, fn [hue, _s, _v] -> hue end)
    counts = Enum.frequencies(hues)

    peak =
      Enum.max_by(0..179, fn center ->
        Enum.sum(for offset <- -@bg_peak_window..@bg_peak_window, do: Map.get(counts, Integer.mod(center + offset, 180), 0))
      end)

    cluster = Enum.filter(pixels, fn [hue, _s, _v] -> hue_distance(hue, peak) <= @bg_cluster_hue_tol end)
    saturations = Enum.map(cluster, fn [_h, s, _v] -> s end)
    values = Enum.map(cluster, fn [_h, _s, v] -> v end)

    {circular_mean_hue(Enum.map(cluster, fn [hue, _s, _v] -> hue end)), mean_plus_spread(saturations), mean_plus_spread(values)}
  end

  defp mean_plus_spread(samples) do
    n = length(samples)
    mean = Enum.sum(samples) / n
    deviation = :math.sqrt(Enum.sum(Enum.map(samples, &((&1 - mean) * (&1 - mean)))) / n)
    mean + @bg_spread_k * deviation
  end

  defp circular_mean_hue(hues) do
    radians = Enum.map(hues, &(&1 * 2 * :math.pi() / 180))
    sin_sum = radians |> Enum.map(&:math.sin/1) |> Enum.sum()
    cos_sum = radians |> Enum.map(&:math.cos/1) |> Enum.sum()
    degrees = :math.atan2(sin_sum, cos_sum) * 180 / :math.pi()
    degrees = if degrees < 0, do: degrees + 360, else: degrees
    round(degrees / 2) |> rem(180)
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @spec colors() :: keyword({0..179, non_neg_integer, 0..255, 0..255, 0..255, 0..255})
  def colors, do: @colors

  @spec tier_thresholds() :: keyword({float, float})
  def tier_thresholds, do: @tier_thresholds

  defp bg_hue_scale(nil, _bg_saturation, _bg_value, _hue), do: 0.0

  defp bg_hue_scale(bg_hue, bg_saturation, bg_value, hue) do
    hue_proximity = max(0.0, 1.0 - hue_distance(hue, bg_hue) / @bg_hue_affect_range)
    bg_chroma = bg_saturation / 255 * (bg_value / 255)
    hue_proximity * max(bg_chroma, @bg_chroma_floor)
  end

  defp hue_distance(a, b) do
    diff = abs(a - b)
    min(diff, 180 - diff)
  end

  defp contrast_saturation_floor(base, nil, _scale), do: base

  defp contrast_saturation_floor(base, bg_saturation, scale) do
    target = max(base, bg_saturation + @bg_contrast_margin)
    round(base + (target - base) * scale)
  end

  defp contrast_value_floor(base, nil, _scale), do: base

  defp contrast_value_floor(base, bg_value, scale) do
    target = base |> max(bg_value + @bg_contrast_margin) |> max(@bg_min_value_floor)
    round(base + (target - base) * scale)
  end

  defp background_exclusion_mask(_hsv, nil, _bg_saturation, _bg_value), do: nil

  defp background_exclusion_mask(hsv, bg_hue, bg_saturation, bg_value) do
    s_lo = max(bg_saturation - @bg_exclusion_s_tol, 0)
    s_hi = min(bg_saturation + @bg_exclusion_s_tol, 255)
    v_lo = max(bg_value - @bg_exclusion_v_tol, 0)
    v_hi = min(bg_value + @bg_exclusion_v_tol, 255)
    Matcher.hue_range_mask(hsv, bg_hue, @bg_exclusion_hue_tol, s_lo, s_hi, v_lo, v_hi)
  end

  defp exclude_background(mask, nil), do: mask
  defp exclude_background(mask, bg_mask), do: Evision.Mat.bitwise_and(mask, Evision.Mat.bitwise_not(bg_mask))

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
end
