defmodule StarlightBot.Vision.Matcher do
  require Logger
  alias StarlightBot.Vision.{Frame, Hook, HookRegistry}

  # OpenCV integer constants (avoids Evision.Constant dependency issues)
  @color_bgr2gray     6  # cv_COLOR_BGR2GRAY
  @color_bgr2hsv      40 # cv_COLOR_BGR2HSV
  @tm_ccoeff_normed   5  # cv_TM_CCOEFF_NORMED — normalized cross-correlation
  @tm_ccorr_normed    3  # cv_TM_CCORR_NORMED  — for binary threshold matching
  @thresh_binary      0  # cv_THRESH_BINARY
  @retr_external      0  # cv_RETR_EXTERNAL
  @chain_approx_simple 2 # cv_CHAIN_APPROX_SIMPLE

  @hsv_tolerance_max 30  # widest per-channel HSV slack, at confidence 0.0
  @hue_max 179           # OpenCV hue range is 0-179, not 0-359

  def find(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        Logger.warning("Hook not found in registry: #{hook_name}", module: __MODULE__)
        :not_found

      {:ok, hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        {image_mat, offset} = crop_to_region(frame.mat, search_region(hook))

        case run_match(image_mat, hook, confidence, :first) do
          {:ok, rect} -> {:ok, add_offset(rect, offset)}
          :not_found -> :not_found
        end
    end
  end

  def find_all(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        Logger.warning("Hook not found in registry: #{hook_name}", module: __MODULE__)
        []

      {:ok, hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        {image_mat, offset} = crop_to_region(frame.mat, search_region(hook))
        run_match(image_mat, hook, confidence, :all)
        |> Enum.map(&add_offset(&1, offset))
    end
  end

  def score_against_mat(mat, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        {:error, :hook_not_found}

      {:ok, %Hook{method: :color_detector} = hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        score = color_detector_raw_score(mat, hook, confidence)
        match = color_cluster_match(mat, hook, confidence, :first)
        {:ok, score, match}

      {:ok, hook} ->
        min_confidence = Keyword.get(opts, :confidence, hook.confidence)
        score = raw_best_score(mat, hook)

        match =
          if score >= min_confidence do
            case do_match(mat, hook.mat, hook.gray_mat, hook.mask_mat, hook.method, min_confidence, :first) do
              [{x, y, w, h}] -> {:ok, {x, y, w, h}}
              [] -> :not_found
            end
          else
            :not_found
          end

        {:ok, score, match}
    end
  end

  def check(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    find(frame, hook_name, opts) != :not_found
  end

  def find_with_score(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        {:error, :hook_not_found}

      {:ok, %Hook{method: :color_detector} = hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        {image_mat, offset} = crop_to_region(frame.mat, search_region(hook))
        score = color_detector_raw_score(image_mat, hook, confidence)

        result =
          case color_cluster_match(image_mat, hook, confidence, :first) do
            {:ok, rect} -> {:ok, add_offset(rect, offset)}
            :not_found -> :not_found
          end

        {:ok, score, result}

      {:ok, hook} ->
        min_confidence = Keyword.get(opts, :confidence, hook.confidence)
        {image_mat, offset} = crop_to_region(frame.mat, search_region(hook))
        score = raw_best_score(image_mat, hook)

        result =
          if score >= min_confidence do
            case run_match(image_mat, hook, min_confidence, :first) do
              {:ok, rect} -> {:ok, add_offset(rect, offset)}
              :not_found -> :not_found
            end
          else
            :not_found
          end

        {:ok, score, result}
    end
  end

  defp search_region(%Hook{method: :color_detector, region: region}), do: region
  defp search_region(%Hook{scan_region: scan}) when not is_nil(scan), do: scan
  defp search_region(%Hook{region: region}), do: region

  defp crop_to_region(mat, nil), do: {mat, {0, 0}}
  defp crop_to_region(mat, {rx, ry, rw, rh}),
    do: {Evision.Mat.roi(mat, {rx, ry, rw, rh}), {rx, ry}}

  defp add_offset({x, y, w, h}, {ox, oy}), do: {x + ox, y + oy, w, h}

  defp run_match(image_mat, %Hook{method: :color_detector} = hook, confidence, mode) do
    color_cluster_match(image_mat, hook, confidence, mode)
  end

  defp run_match(image_mat, %Hook{} = hook, confidence, mode) do
    results = do_match(image_mat, hook.mat, hook.gray_mat, hook.mask_mat, hook.method, confidence, mode)

    case mode do
      :first ->
        case results do
          [rect | _] -> {:ok, rect}
          [] -> :not_found
        end

      :all ->
        results
    end
  rescue
    e in ArgumentError ->
      Logger.warning("Matcher: #{hook.name} raised #{Exception.message(e)} during match — treating as not found",
        module: __MODULE__)

      if mode == :all, do: [], else: :not_found
  end

  defp do_match(image_mat, tmpl_mat, tmpl_gray_mat, mask_mat, method, confidence, mode) do
    case method do
      :gray ->
        gray = Evision.cvtColor(image_mat, @color_bgr2gray)
        result = match_template(gray, tmpl_gray_mat, @tm_ccoeff_normed, mask_mat)
        extract_matches(result, tmpl_gray_mat, confidence, mode)

      :rgb ->
        result = match_template(image_mat, tmpl_mat, @tm_ccoeff_normed, mask_mat)
        extract_matches(result, tmpl_mat, confidence, mode)

      :binary_thresh ->
        gray = Evision.cvtColor(image_mat, @color_bgr2gray)
        tmpl_gray = Evision.cvtColor(tmpl_mat, @color_bgr2gray)
        {_, bin_img} = Evision.threshold(gray, 127, 255, @thresh_binary)
        {_, bin_tmpl} = Evision.threshold(tmpl_gray, 127, 255, @thresh_binary)
        result = match_template(bin_img, bin_tmpl, @tm_ccorr_normed, mask_mat)
        extract_matches(result, tmpl_gray, confidence, mode)

      other ->
        Logger.warning("Matcher: method #{inspect(other)} is not yet implemented",
          module: __MODULE__)
        []
    end
  end

  defp match_template(image, tmpl, _method_const, mask_mat) when not is_nil(mask_mat),
    do: Evision.matchTemplate(image, tmpl, @tm_ccorr_normed, mask: mask_mat)
  defp match_template(image, tmpl, method_const, nil),
    do: Evision.matchTemplate(image, tmpl, method_const)

  defp extract_matches(result_mat, tmpl_mat, confidence, :first) do
    {_, max_val, _, {cx, cy}} = Evision.minMaxLoc(result_mat)
    if max_val >= confidence do
      {tw, th} = mat_wh(tmpl_mat)
      [{cx, cy, tw, th}]
    else
      []
    end
  end

  defp extract_matches(result_mat, tmpl_mat, confidence, :all) do
    {tw, th} = mat_wh(tmpl_mat)
    {_rows, cols} = result_dims(result_mat)

    raw = Evision.Mat.to_binary(result_mat, 0)

    for <<v::float-32-little <- raw>>, do: v
    |> Enum.with_index()
    |> Enum.filter(fn {v, _} -> v >= confidence end)
    |> Enum.map(fn {v, i} -> {v, rem(i, cols), div(i, cols)} end)
    |> Enum.sort(:desc)
    |> greedy_nms(tw, th, [])
  end

  defp greedy_nms([], _tw, _th, acc), do: Enum.reverse(acc)
  defp greedy_nms([{_, cx, cy} | rest], tw, th, acc) do
    remaining = Enum.reject(rest, fn {_, ox, oy} ->
      abs(ox - cx) < tw and abs(oy - cy) < th
    end)
    greedy_nms(remaining, tw, th, [{cx, cy, tw, th} | acc])
  end

  defp mat_hw(mat) do
    case Evision.Mat.shape(mat) do
      {h, w, _} -> {h, w}
      {h, w} -> {h, w}
    end
  end

  defp mat_wh(mat) do
    {h, w} = mat_hw(mat)
    {w, h}
  end

  defp result_dims(mat) do
    case Evision.Mat.shape(mat) do
      {r, c, _} -> {r, c}
      {r, c} -> {r, c}
    end
  end

  defp raw_best_score(image_mat, %Hook{method: method} = hook) do
    {tmpl, tmpl_gray, mask_mat} = {hook.mat, hook.gray_mat, hook.mask_mat}

    result_mat =
      case method do
        :gray ->
          gray = Evision.cvtColor(image_mat, @color_bgr2gray)
          match_template(gray, tmpl_gray, @tm_ccoeff_normed, mask_mat)

        :rgb ->
          match_template(image_mat, tmpl, @tm_ccoeff_normed, mask_mat)

        :binary_thresh ->
          gray = Evision.cvtColor(image_mat, @color_bgr2gray)
          tg = Evision.cvtColor(tmpl, @color_bgr2gray)
          {_, bin_img} = Evision.threshold(gray, 127, 255, @thresh_binary)
          {_, bin_tmpl} = Evision.threshold(tg, 127, 255, @thresh_binary)
          match_template(bin_img, bin_tmpl, @tm_ccorr_normed, mask_mat)

        _ ->
          nil
      end

    case result_mat do
      nil ->
        0.0

      mat ->
        {_, max_val, _, _} = Evision.minMaxLoc(mat)
        max_val
    end
  rescue
    _ -> 0.0
  end

  defp color_cluster_match(_image_mat, %Hook{color: nil}, _confidence, :first), do: :not_found
  defp color_cluster_match(_image_mat, %Hook{color: nil}, _confidence, :all), do: []

  defp color_cluster_match(image_mat, %Hook{} = hook, confidence, mode) do
    tolerance = confidence_to_hsv_tolerance(confidence)
    min_area = scaled_min_cluster_size(hook, image_mat)

    clusters =
      image_mat
      |> color_cluster_rects(hook.color, tolerance)
      |> Enum.filter(fn {area, _rect} -> area >= min_area end)
      |> Enum.sort_by(fn {area, _rect} -> area end, :desc)

    case mode do
      :first ->
        case clusters do
          [{_area, rect} | _] -> {:ok, rect}
          [] -> :not_found
        end

      :all ->
        Enum.map(clusters, fn {_area, rect} -> rect end)
    end
  end

  defp color_detector_raw_score(_image_mat, %Hook{color: nil}, _confidence), do: 0.0

  defp color_detector_raw_score(image_mat, %Hook{} = hook, confidence) do
    tolerance = confidence_to_hsv_tolerance(confidence)
    min_area = scaled_min_cluster_size(hook, image_mat)

    case color_cluster_rects(image_mat, hook.color, tolerance) do
      [] ->
        0.0

      clusters ->
        max_area = clusters |> Enum.map(fn {area, _rect} -> area end) |> Enum.max()
        if min_area <= 0, do: 1.0, else: min(max_area / min_area, 1.0)
    end
  rescue
    _ -> 0.0
  end

  defp color_cluster_rects(image_mat, {h, s, v}, tolerance) do
    hsv = Evision.cvtColor(image_mat, @color_bgr2hsv)
    mask = color_mask(hsv, h, s, v, tolerance)
    {contours, _hierarchy} = Evision.findContours(mask, @retr_external, @chain_approx_simple)

    Enum.map(contours, fn contour ->
      {Evision.contourArea(contour), Evision.boundingRect(contour)}
    end)
  end

  defp color_mask(hsv_mat, h, s, v, tolerance) do
    s_lo = max(s - tolerance, 0)
    s_hi = min(s + tolerance, 255)
    v_lo = max(v - tolerance, 0)
    v_hi = min(v + tolerance, 255)

    h_lo = h - tolerance
    h_hi = h + tolerance

    ranges =
      cond do
        h_lo < 0 ->
          [{0, h_hi}, {@hue_max + 1 + h_lo, @hue_max}]

        h_hi > @hue_max ->
          [{h_lo, @hue_max}, {0, h_hi - @hue_max - 1}]

        true ->
          [{h_lo, h_hi}]
      end

    ranges
    |> Enum.map(fn {lo, hi} -> Evision.inRange(hsv_mat, {lo, s_lo, v_lo}, {hi, s_hi, v_hi}) end)
    |> Enum.reduce(fn mask, acc -> Evision.Mat.bitwise_or(acc, mask) end)
  end

  defp confidence_to_hsv_tolerance(confidence) do
    round((1.0 - confidence) * @hsv_tolerance_max)
  end

  defp scaled_min_cluster_size(%Hook{min_cluster_size: min}, _image_mat) when not is_integer(min), do: 0

  defp scaled_min_cluster_size(%Hook{min_cluster_size: min, region: region}, image_mat) do
    {expected_w, expected_h} =
      case region do
        {_x, _y, w, h} -> {w, h}
        nil -> {1920, 1080}
      end

    {mat_h, mat_w} = mat_hw(image_mat)
    ratio = (mat_w * mat_h) / (expected_w * expected_h)
    round(min * ratio)
  end
end
