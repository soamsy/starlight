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
  @morph_close        3  # cv_MORPH_CLOSE — bridges small gaps in a mask
  @morph_ellipse      2  # cv_MORPH_ELLIPSE — structuring element shape
  @border_constant    0  # cv_BORDER_CONSTANT

  @cluster_detectors [:color_detector, :value_detector, :saturation_detector]
  @feature_methods [:sift, :sift_saturation]
  @hsv_tolerance_max 30  # widest per-channel HSV slack, at confidence 0.0
  @hue_max 179           # OpenCV hue range is 0-179, not 0-359

  @fill_holes_close_kernel_px 3
  @deep_defect_min_depth_px 6    # convexity-defect depth past which a concavity counts as an invasive line to patch, not a shape edge

  @sift_ratio_test 0.75
  @sift_contrast_threshold 0.06
  @scene_sift_max_features 500
  @clahe_clip_limit 1.0
  @clahe_tile_grid_size {8, 2}
  @min_good_matches 8
  @target_inliers 20
  @ransac_reproj_threshold 5.0
  @ransac_method 8
  @norm_l2 2
  @min_match_scale_ratio 0.6
  @max_match_scale_ratio 1.6

  def find(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        Logger.warning("Hook not found in registry: #{hook_name}", module: __MODULE__)
        :not_found

      {:ok, hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        {image_mat, offset} = crop_to_region(frame, search_region(hook))

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
        {image_mat, offset} = crop_to_region(frame, search_region(hook))
        run_match(image_mat, hook, confidence, :all)
        |> Enum.map(&add_offset(&1, offset))
    end
  end

  def find_all_with_scores(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        {:error, :hook_not_found}

      {:ok, hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        {image_mat, offset} = crop_to_region(frame, search_region(hook))

        matches =
          image_mat
          |> scored_matches(hook, confidence)
          |> Enum.map(fn {rect, score} -> {add_offset(rect, offset), score} end)

        {:ok, matches}
    end
  end

  def find_all_with_scores_batch(%Frame{} = frame, hook_names, opts \\ []) when is_list(hook_names) do
    {missing, found} =
      hook_names
      |> Enum.map(fn name -> {name, HookRegistry.find(name)} end)
      |> Enum.split_with(fn {_name, result} -> result == {:error, :not_found} end)

    crops =
      found
      |> Enum.map(fn {_name, {:ok, hook}} -> search_region(hook) end)
      |> Enum.uniq()
      |> Map.new(fn region -> {region, crop_to_region(frame, region)} end)

    found
    |> Enum.map(fn {name, {:ok, hook}} ->
      confidence = Keyword.get(opts, :confidence, hook.confidence)
      {image_mat, offset} = Map.fetch!(crops, search_region(hook))
      matches = image_mat |> scored_matches(hook, confidence) |> Enum.map(fn {rect, score} -> {add_offset(rect, offset), score} end)
      {name, {:ok, matches}}
    end)
    |> Kernel.++(Enum.map(missing, fn {name, _} -> {name, {:error, :hook_not_found}} end))
  end

  def score_against_mat(mat, hook_name, opts \\ []) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:error, :not_found} ->
        {:error, :hook_not_found}

      {:ok, %Hook{method: method} = hook} when method in @cluster_detectors ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        score = color_detector_raw_score(mat, hook, confidence)
        match = color_cluster_match(mat, hook, confidence, :first)
        {:ok, score, match}

      {:ok, %Hook{method: :grayscale_detector} = hook} ->
        confidence = Keyword.get(opts, :confidence, hook.confidence)
        score = grayscale_score(mat)
        match = grayscale_match(mat, hook, confidence, :first)
        {:ok, score, match}

      {:ok, %Hook{method: method} = hook} when method in @feature_methods ->
        min_confidence = Keyword.get(opts, :confidence, hook.confidence)
        scene_features = detect_scene_features(method, mat)
        {score, rect} = match_scene_features(scene_features, hook.keypoints, hook.descriptors, hook.gray_mat)
        match = if score >= min_confidence and rect != nil, do: {:ok, rect}, else: :not_found
        {:ok, score, match}

      {:ok, hook} ->
        min_confidence = Keyword.get(opts, :confidence, hook.confidence)
        score = raw_best_score(mat, hook)

        match =
          if score >= min_confidence do
            case do_match(mat, hook.mat, hook.gray_mat, hook.mask_mat, hook.keypoints, hook.descriptors, hook.method, min_confidence, :first) do
              [{x, y, w, h}] -> {:ok, {x, y, w, h}}
              [] -> :not_found
            end
          else
            :not_found
          end

        {:ok, score, match}
    end
  end

  def search_rect(hook_name) when is_atom(hook_name) do
    case HookRegistry.find(hook_name) do
      {:ok, hook} -> search_region(hook)
      {:error, :not_found} -> nil
    end
  end

  def check(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    find(frame, hook_name, opts) != :not_found
  end

  def find_with_score(%Frame{} = frame, hook_name, opts \\ []) when is_atom(hook_name) do
    hook_result = HookRegistry.find(hook_name)
    cache = single_scene_cache(frame, hook_result)
    find_with_score_resolved(frame, hook_result, cache, opts)
  end

  def find_with_score_batch(%Frame{} = frame, hook_names, opts \\ []) when is_list(hook_names) do
    resolved = Enum.map(hook_names, fn name -> {name, HookRegistry.find(name)} end)
    cache = build_scene_feature_cache(frame, resolved)

    resolved
    |> Task.async_stream(
      fn {name, hook_result} ->
        {duration_us, result} = :timer.tc(fn -> find_with_score_resolved(frame, hook_result, cache, opts) end)
        {name, result, duration_us}
      end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, entry} -> entry end)
  end

  defp find_with_score_resolved(_frame, {:error, :not_found}, _cache, _opts), do: {:error, :hook_not_found}

  defp find_with_score_resolved(frame, {:ok, %Hook{method: method} = hook}, _cache, opts) when method in @cluster_detectors do
    confidence = Keyword.get(opts, :confidence, hook.confidence)
    {image_mat, offset} = crop_to_region(frame, search_region(hook))
    score = color_detector_raw_score(image_mat, hook, confidence)

    result =
      case color_cluster_match(image_mat, hook, confidence, :first) do
        {:ok, rect} -> {:ok, add_offset(rect, offset)}
        :not_found -> :not_found
      end

    {:ok, score, result}
  end

  defp find_with_score_resolved(frame, {:ok, %Hook{method: :grayscale_detector} = hook}, _cache, opts) do
    confidence = Keyword.get(opts, :confidence, hook.confidence)
    {image_mat, offset} = crop_to_region(frame, search_region(hook))
    score = grayscale_score(image_mat)

    result =
      case grayscale_match(image_mat, hook, confidence, :first) do
        {:ok, rect} -> {:ok, add_offset(rect, offset)}
        :not_found -> :not_found
      end

    {:ok, score, result}
  end

  defp find_with_score_resolved(_frame, {:ok, %Hook{method: method} = hook}, cache, opts)
       when method in @feature_methods do
    min_confidence = Keyword.get(opts, :confidence, hook.confidence)
    region = search_region(hook)
    scene_features = Map.fetch!(cache, {region, method})
    {score, rect} = match_scene_features(scene_features, hook.keypoints, hook.descriptors, hook.gray_mat)

    result =
      if score >= min_confidence and rect != nil do
        {:ok, add_offset(rect, region_offset(region))}
      else
        :not_found
      end

    {:ok, score, result}
  end

  defp find_with_score_resolved(frame, {:ok, hook}, _cache, opts) do
    min_confidence = Keyword.get(opts, :confidence, hook.confidence)
    {image_mat, offset} = crop_to_region(frame, search_region(hook))
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

  defp region_offset(nil), do: {0, 0}
  defp region_offset({rx, ry, _rw, _rh}), do: {rx, ry}

  defp single_scene_cache(_frame, {:error, :not_found}), do: %{}

  defp single_scene_cache(frame, {:ok, %Hook{method: method} = hook}) when method in @feature_methods do
    region = search_region(hook)
    {image_mat, _offset} = crop_to_region(frame, region)
    %{{region, method} => detect_scene_features(method, image_mat)}
  end

  defp single_scene_cache(_frame, {:ok, _hook}), do: %{}

  defp build_scene_feature_cache(frame, resolved) do
    resolved
    |> Enum.flat_map(fn
      {_name, {:ok, %Hook{method: m} = hook}} when m in @feature_methods -> [{search_region(hook), m}]
      _ -> []
    end)
    |> Enum.uniq()
    |> Task.async_stream(
      fn {region, method} ->
        {image_mat, _offset} = crop_to_region(frame, region)
        {{region, method}, detect_scene_features(method, image_mat)}
      end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.into(%{}, fn {:ok, entry} -> entry end)
  end

  defp search_region(%Hook{method: method, region: region}) when method in @cluster_detectors, do: region
  defp search_region(%Hook{method: :grayscale_detector, region: region}), do: region
  defp search_region(%Hook{scan_region: scan}) when not is_nil(scan), do: scan
  defp search_region(%Hook{region: region}), do: region

  defp crop_to_region(%Frame{mat: mat}, nil) when mat != nil, do: {mat, {0, 0}}
  defp crop_to_region(frame, {rx, ry, _rw, _rh} = region), do: {Frame.region(frame, region), {rx, ry}}

  defp add_offset({x, y, w, h}, {ox, oy}), do: {x + ox, y + oy, w, h}

  defp run_match(image_mat, %Hook{method: method} = hook, confidence, mode) when method in @cluster_detectors do
    color_cluster_match(image_mat, hook, confidence, mode)
  end

  defp run_match(image_mat, %Hook{method: :grayscale_detector} = hook, confidence, mode) do
    grayscale_match(image_mat, hook, confidence, mode)
  end

  defp run_match(image_mat, %Hook{} = hook, confidence, mode) do
    results = do_match(image_mat, hook.mat, hook.gray_mat, hook.mask_mat, hook.keypoints, hook.descriptors, hook.method, confidence, mode)

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

  defp do_match(image_mat, tmpl_mat, tmpl_gray_mat, mask_mat, keypoints, descriptors, method, confidence, mode) do
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

      method when method in @feature_methods ->
        feature_matches(image_mat, keypoints, descriptors, tmpl_gray_mat, method, confidence)
    end
  end

  defp match_template(image, tmpl, method_const, mask_mat) when not is_nil(mask_mat),
    do: Evision.matchTemplate(image, tmpl, method_const, mask: mask_mat)
  defp match_template(image, tmpl, method_const, nil),
    do: Evision.matchTemplate(image, tmpl, method_const)

  defp extract_matches(result_mat, tmpl_mat, confidence, :first) do
    {max_val, {cx, cy}} = max_loc(result_mat)
    if max_val >= confidence do
      {tw, th} = mat_wh(tmpl_mat)
      [{cx, cy, tw, th}]
    else
      []
    end
  end

  defp extract_matches(result_mat, tmpl_mat, confidence, :all) do
    result_mat
    |> extract_matches(tmpl_mat, confidence, :all_scored)
    |> Enum.map(fn {rect, _score} -> rect end)
  end

  defp extract_matches(result_mat, tmpl_mat, confidence, :all_scored) do
    {tw, th} = mat_wh(tmpl_mat)
    {_rows, cols} = result_dims(result_mat)

    result_mat
    |> scores()
    |> Enum.with_index()
    |> Enum.filter(fn {v, _} -> v >= confidence end)
    |> Enum.map(fn {v, i} -> {v, rem(i, cols), div(i, cols)} end)
    |> Enum.sort(:desc)
    |> greedy_nms(tw, th, [])
  end

  defp greedy_nms([], _tw, _th, acc), do: Enum.reverse(acc)
  defp greedy_nms([{v, cx, cy} | rest], tw, th, acc) do
    remaining = Enum.reject(rest, fn {_, ox, oy} ->
      abs(ox - cx) < tw and abs(oy - cy) < th
    end)
    greedy_nms(remaining, tw, th, [{{cx, cy, tw, th}, v} | acc])
  end

  defp scored_matches(_image_mat, %Hook{method: method, color: nil}, _confidence) when method in @cluster_detectors, do: []

  defp scored_matches(image_mat, %Hook{method: method} = hook, confidence) when method in @cluster_detectors do
    tolerance = confidence_to_hsv_tolerance(confidence)
    min_area = scaled_min_cluster_size(hook, image_mat)

    image_mat
    |> color_cluster_rects(method, hook.color, tolerance)
    |> Enum.filter(fn {area, _rect} -> area >= min_area end)
    |> Enum.sort_by(fn {area, _rect} -> area end, :desc)
    |> Enum.map(fn {area, rect} ->
      {rect, if(min_area <= 0, do: 1.0, else: min(area / min_area, 1.0))}
    end)
  end

  defp scored_matches(image_mat, %Hook{method: :grayscale_detector}, confidence) do
    score = grayscale_score(image_mat)
    {h, w} = mat_hw(image_mat)
    if score >= confidence, do: [{{0, 0, w, h}, score}], else: []
  end

  defp scored_matches(_image_mat, %Hook{method: method, keypoints: keypoints}, _confidence)
       when method in @feature_methods and keypoints in [nil, []], do: []

  defp scored_matches(image_mat, %Hook{method: method} = hook, confidence) when method in @feature_methods do
    case feature_score_and_rect(image_mat, hook.keypoints, hook.descriptors, hook.gray_mat, method) do
      {score, rect} when score >= confidence and rect != nil -> [{rect, score}]
      _ -> []
    end
  end

  defp scored_matches(image_mat, %Hook{} = hook, confidence) do
    do_match(image_mat, hook.mat, hook.gray_mat, hook.mask_mat, hook.keypoints, hook.descriptors, hook.method, confidence, :all_scored)
  rescue
    e in ArgumentError ->
      Logger.warning("Matcher: #{hook.name} raised #{Exception.message(e)} during match — treating as not found",
        module: __MODULE__)

      []
  end

  defp feature_matches(_image_mat, keypoints, _descriptors, _tmpl_gray_mat, _method, _confidence)
       when keypoints in [nil, []], do: []

  defp feature_matches(image_mat, keypoints, descriptors, tmpl_gray_mat, method, confidence) do
    {score, rect} = feature_score_and_rect(image_mat, keypoints, descriptors, tmpl_gray_mat, method)
    if score >= confidence and rect != nil, do: [rect], else: []
  end

  defp feature_score_and_rect(image_mat, keypoints, descriptors, tmpl_gray_mat, method) do
    scene_features = detect_scene_features(method, image_mat)
    match_scene_features(scene_features, keypoints, descriptors, tmpl_gray_mat)
  rescue
    _ -> {0.0, nil}
  end

  defp channel_mat(bgr_mat, :sift_saturation) do
    hsv = Evision.cvtColor(bgr_mat, @color_bgr2hsv)
    [_h, s, _v] = Evision.split(hsv)
    s
  end

  defp channel_mat(bgr_mat, :sift), do: Evision.cvtColor(bgr_mat, @color_bgr2gray)

  defp match_scene_features(_scene_features, keypoints, _descriptors, _tmpl_gray_mat)
       when keypoints in [nil, []], do: {0.0, nil}

  defp match_scene_features({kp2, _des2}, _keypoints, _descriptors, _tmpl_gray_mat)
       when length(kp2) < 2, do: {0.0, nil}

  defp match_scene_features({kp2, des2}, keypoints, descriptors, tmpl_gray_mat) do
    good =
      bf_matcher()
      |> Evision.BFMatcher.knnMatch(descriptors, des2, 2)
      |> Enum.filter(fn
        [m, n] -> Evision.DMatch.get_distance(m) < @sift_ratio_test * Evision.DMatch.get_distance(n)
        _ -> false
      end)

    if length(good) < @min_good_matches do
      {0.0, nil}
    else
      affine_score_and_rect(good, keypoints, kp2, tmpl_gray_mat)
    end
  rescue
    _ -> {0.0, nil}
  end

  defp detect_scene_features(method, image_mat),
    do: Evision.SIFT.detectAndCompute(sift_scene_detector(), clahe_apply(channel_mat(image_mat, method)), Evision.Mat.empty())

  # defp clahe_apply(gray), do: gray
  defp clahe_apply(gray) do
    clahe = Evision.createCLAHE(clipLimit: @clahe_clip_limit, tileGridSize: @clahe_tile_grid_size)
    Evision.CLAHE.apply(clahe, gray)
  end

  defp sift_scene_detector do
    case :persistent_term.get({__MODULE__, :sift_scene_detector}, nil) do
      nil ->
        detector =
          Evision.SIFT.create(contrastThreshold: @sift_contrast_threshold, nfeatures: @scene_sift_max_features)

        :persistent_term.put({__MODULE__, :sift_scene_detector}, detector)
        detector

      detector ->
        detector
    end
  end

  defp bf_matcher do
    case :persistent_term.get({__MODULE__, :bf_matcher}, nil) do
      nil ->
        matcher = Evision.BFMatcher.create(normType: @norm_l2)
        :persistent_term.put({__MODULE__, :bf_matcher}, matcher)
        matcher

      matcher ->
        matcher
    end
  end

  defp affine_score_and_rect(good, kp1, kp2, tmpl_gray_mat) do
    kp1_tuple = List.to_tuple(kp1)
    kp2_tuple = List.to_tuple(kp2)

    src_pts = Enum.map(good, fn [m, _n] -> Evision.KeyPoint.get_pt(elem(kp1_tuple, Evision.DMatch.get_queryIdx(m))) end)
    dst_pts = Enum.map(good, fn [m, _n] -> Evision.KeyPoint.get_pt(elem(kp2_tuple, Evision.DMatch.get_trainIdx(m))) end)

    src_tensor = Nx.tensor(Enum.map(src_pts, fn {x, y} -> [x, y] end), type: :f32)
    dst_tensor = Nx.tensor(Enum.map(dst_pts, fn {x, y} -> [x, y] end), type: :f32)

    case Evision.estimateAffinePartial2D(src_tensor, dst_tensor, method: @ransac_method, ransacReprojThreshold: @ransac_reproj_threshold) do
      {:error, _reason} ->
        {0.0, nil}

      {affine_mat, inlier_mat} ->
        inliers =
          inlier_mat
          |> Evision.Mat.to_nx()
          |> Nx.to_flat_list()
          |> Enum.count(&(&1 != 0))

        good_count = length(good)
        score = inliers / good_count * min(inliers / @target_inliers, 1.0)

        {tw, th} = mat_wh(tmpl_gray_mat)
        rect = affine_bounding_rect(affine_mat, tw, th)

        if plausible_rect?(rect, tw, th), do: {score, rect}, else: {0.0, nil}
    end
  end

  defp affine_bounding_rect(affine_mat, tw, th) do
    [a, b, tx, c, d, ty] = affine_mat |> Evision.Mat.to_nx() |> Nx.to_flat_list()

    transformed =
      Enum.map([{0, 0}, {tw, 0}, {tw, th}, {0, th}], fn {x, y} ->
        {a * x + b * y + tx, c * x + d * y + ty}
      end)

    xs = Enum.map(transformed, fn {x, _y} -> x end)
    ys = Enum.map(transformed, fn {_x, y} -> y end)
    {min_x, max_x} = Enum.min_max(xs)
    {min_y, max_y} = Enum.min_max(ys)

    {round(min_x), round(min_y), round(max_x - min_x), round(max_y - min_y)}
  end

  defp plausible_rect?({_x, _y, w, h}, tw, th) do
    w > 0 and h > 0 and
      w / tw >= @min_match_scale_ratio and w / tw <= @max_match_scale_ratio and
      h / th >= @min_match_scale_ratio and h / th <= @max_match_scale_ratio
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
        {max_val, _} = max_loc(mat)
        max_val
    end
  rescue
    _ -> 0.0
  end

  defp max_loc(result_mat) do
    {_rows, cols} = result_dims(result_mat)
    values = scores(result_mat)

    case values do
      [] ->
        {0.0, {0, 0}}

      _ ->
        {max_val, max_idx} = values |> Enum.with_index() |> Enum.max_by(fn {v, _i} -> v end)
        {max_val, {rem(max_idx, cols), div(max_idx, cols)}}
    end
  end

  defp scores(result_mat) do
    for <<cell::binary-4 <- Evision.Mat.to_binary(result_mat, 0)>> do
      case cell do
        <<v::float-32-little>> -> v
        _ -> 0.0
      end
    end
  end

  defp color_cluster_match(_image_mat, %Hook{color: nil}, _confidence, :first), do: :not_found
  defp color_cluster_match(_image_mat, %Hook{color: nil}, _confidence, :all), do: []

  defp color_cluster_match(image_mat, %Hook{} = hook, confidence, mode) do
    tolerance = confidence_to_hsv_tolerance(confidence)
    min_area = scaled_min_cluster_size(hook, image_mat)

    clusters =
      image_mat
      |> color_cluster_rects(hook.method, hook.color, tolerance)
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

    case color_cluster_rects(image_mat, hook.method, hook.color, tolerance) do
      [] ->
        0.0

      clusters ->
        max_area = clusters |> Enum.map(fn {area, _rect} -> area end) |> Enum.max()
        if min_area <= 0, do: 1.0, else: min(max_area / min_area, 1.0)
    end
  rescue
    _ -> 0.0
  end

  defp grayscale_match(image_mat, _hook, confidence, mode) do
    found? = grayscale_score(image_mat) >= confidence
    {h, w} = mat_hw(image_mat)

    case mode do
      :first -> if found?, do: {:ok, {0, 0, w, h}}, else: :not_found
      :all -> if found?, do: [{0, 0, w, h}], else: []
    end
  end

  defp grayscale_score(image_mat) do
    hsv = Evision.cvtColor(image_mat, @color_bgr2hsv)
    {mean, _stddev} = Evision.meanStdDev(hsv)
    [_h, s, _v] = mean |> Evision.Mat.to_nx() |> Nx.to_flat_list()
    1.0 - s / 255.0
  rescue
    _ -> 0.0
  end

  def color_cluster_rects(image_mat, color, tolerance), do: color_cluster_rects(image_mat, :color_detector, color, tolerance)

  def color_cluster_rects(image_mat, method, {h, s, v}, tolerance) do
    hsv = Evision.cvtColor(image_mat, @color_bgr2hsv)
    mask = cluster_mask(hsv, method, {h, s, v}, tolerance)
    {contours, _hierarchy} = Evision.findContours(mask, @retr_external, @chain_approx_simple)

    Enum.map(contours, fn contour ->
      {Evision.contourArea(contour), Evision.boundingRect(contour)}
    end)
  end

  defp cluster_mask(hsv_mat, :color_detector, {h, s, v}, tolerance), do: color_mask(hsv_mat, h, s, v, tolerance)

  defp cluster_mask(hsv_mat, :value_detector, {_h, _s, v}, tolerance),
    do: Evision.inRange(hsv_mat, {0, 0, max(v - tolerance, 0)}, {@hue_max, 255, min(v + tolerance, 255)})

  defp cluster_mask(hsv_mat, :saturation_detector, {_h, s, _v}, tolerance),
    do: Evision.inRange(hsv_mat, {0, max(s - tolerance, 0), 0}, {@hue_max, min(s + tolerance, 255), 255})

  defp color_mask(hsv_mat, h, s, v, tolerance) do
    s_lo = max(s - tolerance, 0)
    s_hi = min(s + tolerance, 255)
    v_lo = max(v - tolerance, 0)
    v_hi = min(v + tolerance, 255)

    hsv_range_mask(hsv_mat, h, tolerance, s_lo, s_hi, v_lo, v_hi)
  end

  defp hsv_range_mask(hsv_mat, h, h_tolerance, s_lo, s_hi, v_lo, v_hi) do
    h_lo = h - h_tolerance
    h_hi = h + h_tolerance

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

  def hue_range_mask(hsv_mat, hue, hue_tolerance, s_lo, s_hi, v_lo, v_hi) do
    # NIF-backed Mat resources can't be precomputed as a module attribute (no stable
    # literal representation across VM restarts), so the kernel is built per call.
    kernel = Evision.getStructuringElement(@morph_ellipse, {3, 3})

    hsv_mat
    |> hsv_range_mask(hue, hue_tolerance, s_lo, s_hi, v_lo, v_hi)
    |> Evision.morphologyEx(@morph_close, kernel)
  end

  def confidence_to_hsv_tolerance(confidence) do
    round((1.0 - confidence) * @hsv_tolerance_max)
  end

  def inner_ring_mask(mask, kernel_px \\ 3) do
    kernel = Evision.getStructuringElement(@morph_ellipse, {kernel_px, kernel_px})
    # OpenCV's default erode border treats pixels outside the mat as already
    # matched, so a mask touching the crop edge wouldn't shrink there at all.
    # Explicitly treat outside-the-crop as unmatched instead.
    eroded = Evision.erode(mask, kernel, borderType: @border_constant, borderValue: 0)
    Evision.Mat.subtract(mask, eroded)
  end

  def top_right_wedge_mask(w, h, bulge_pct \\ 0.0) do
    big = (max(w, h) + 1) * 4
    cx = div(w, 2)
    drop = round(h * bulge_pct)
    mask = Evision.Mat.zeros({h, w}, {:u, 8})
    poly = point_mat([{cx, 0}, {cx, drop}, {cx + round(big * 1.20), drop + big}, {cx + big, 0}])
    Evision.fillPoly(mask, [poly], 255)
  end

  def top_right_corner_mask(w, h, pct) when pct <= 0, do: Evision.Mat.zeros({h, w}, {:u, 8})

  def top_right_corner_mask(w, h, pct) do
    leg = round(w * pct)
    mask = Evision.Mat.zeros({h, w}, {:u, 8})
    poly = point_mat([{w - leg, 0}, {w - 1, 0}, {w - 1, leg}])
    Evision.fillPoly(mask, [poly], 255)
  end

  def fill_holes_mask(mask, close_kernel_px \\ @fill_holes_close_kernel_px, min_defect_depth_px \\ @deep_defect_min_depth_px) do
    kernel = Evision.getStructuringElement(@morph_ellipse, {close_kernel_px, close_kernel_px})

    closed =
      mask
      |> fill_deep_defects_mask(min_defect_depth_px)
      |> Evision.morphologyEx(@morph_close, kernel)

    {contours, _hierarchy} = Evision.findContours(closed, @retr_external, @chain_approx_simple)
    filled = Evision.Mat.zeros(Evision.Mat.shape(mask), {:u, 8})
    Evision.drawContours(filled, contours, -1, 255, thickness: -1)
  end

  def fill_deep_defects_mask(mask, min_defect_depth_px \\ @deep_defect_min_depth_px) do
    {contours, _hierarchy} = Evision.findContours(mask, @retr_external, @chain_approx_simple)
    Enum.reduce(contours, mask, &patch_deep_defects(&2, &1, min_defect_depth_px))
  end

  defp patch_deep_defects(mask, contour, min_defect_depth_px) do
    case contour_defects(contour) do
      {:ok, points, defects} ->
        Enum.reduce(defects, mask, fn {start_idx, end_idx, depth_fixpt}, acc ->
          if depth_fixpt / 256.0 >= min_defect_depth_px do
            fill_defect(acc, points, start_idx, end_idx)
          else
            acc
          end
        end)

      :error ->
        mask
    end
  end

  defp contour_defects(contour) do
    hull = Evision.convexHull(contour, returnPoints: false)

    case Evision.convexityDefects(contour, hull) do
      {:error, _} ->
        {:ok, {}, []}

      defects ->
        points =
          contour
          |> Evision.Mat.to_nx()
          |> Nx.to_flat_list()
          |> Enum.chunk_every(2)
          |> Enum.map(fn [x, y] -> {x, y} end)
          |> List.to_tuple()

        rows =
          defects
          |> Evision.Mat.to_nx()
          |> Nx.to_flat_list()
          |> Enum.chunk_every(4)
          |> Enum.map(fn [start_idx, end_idx, _far_idx, depth] -> {start_idx, end_idx, depth} end)

        {:ok, points, rows}
    end
  rescue
    _ -> :error
  end

  defp fill_defect(mask, points, start_idx, end_idx) do
    num_points = tuple_size(points)

    indices =
      if end_idx >= start_idx,
        do: start_idx..end_idx,
        else: Enum.to_list(start_idx..(num_points - 1)) ++ Enum.to_list(0..end_idx)

    poly = indices |> Enum.map(&elem(points, &1)) |> point_mat()
    Evision.fillPoly(mask, [poly], 255)
  end

  defp point_mat(points) do
    binary = for {x, y} <- points, into: <<>>, do: <<x::32-signed-little, y::32-signed-little>>
    Evision.Mat.from_binary(binary, {:s, 32}, length(points), 1, 2)
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
